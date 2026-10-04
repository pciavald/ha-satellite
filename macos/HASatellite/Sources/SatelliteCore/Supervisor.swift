import Darwin
import Foundation

/// Restart policy of the Python child (plans/network-service-upstream.md 3.1):
/// 2, 5, 10, then 30 s; reset after 5 minutes up; "failing" after 5 exits
/// within 2 minutes.
public struct Backoff: Equatable, Sendable {
  public var delays: [TimeInterval]
  public var resetAfter: TimeInterval
  public var failWindow: TimeInterval
  public var failLimit: Int
  public private(set) var attempt = 0
  private var exits: [TimeInterval] = []

  public init(delays: [TimeInterval] = [2, 5, 10, 30], resetAfter: TimeInterval = 300, failWindow: TimeInterval = 120, failLimit: Int = 5) {
    self.delays = delays
    self.resetAfter = resetAfter
    self.failWindow = failWindow
    self.failLimit = failLimit
  }

  /// The child exited on its own after `uptime` seconds; returns the delay
  /// before the next start.
  public mutating func exited(uptime: TimeInterval, now: TimeInterval) -> TimeInterval {
    if uptime >= resetAfter {
      attempt = 0
      exits = []
    }
    let delay = delays[min(attempt, delays.count - 1)]
    attempt += 1
    exits.append(now)
    exits.removeAll { now - $0 > failWindow }
    return delay
  }

  public var failing: Bool { exits.count >= failLimit }

  public mutating func reset() {
    attempt = 0
    exits = []
  }
}

public enum SupervisorStatus: Equatable, Sendable {
  /// No `satellite.json` (nil), or an invalid one (the error).
  case notConfigured(String?)
  /// "Run Satellite Process" is off (development).
  case disabled
  case running(pid: Int32)
  case restarting(in: TimeInterval, lastExit: String, failing: Bool)
  case stopped
}

public enum ExitStatus {
  public static func describe(_ status: Int32) -> String {
    let signal = status & 0x7f
    if signal == 0 { return "exit code \((status >> 8) & 0xff)" }
    let name = String(cString: strsignal(signal))
    return "signal \(signal) (\(name))"
  }
}

public enum ProcessInfoReader {
  /// Start time of a process in microseconds since the epoch, nil if it does
  /// not exist.
  public static func startTime(_ pid: pid_t) -> UInt64? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
  }
}

/// Starts the Python satellite as a child (same process group, stdin
/// /dev/null, stdout and stderr appended to the log file), restarts it with
/// backoff, stops it with SIGTERM then SIGKILL. All work runs on `queue`.
public final class Supervisor: @unchecked Sendable {
  public static let logLimit: UInt64 = 10 << 20
  public static let logTruncateLimit: UInt64 = 50 << 20

  public let queue = DispatchQueue(label: "io.iostud.ha-satellite.supervisor")
  public private(set) var status: SupervisorStatus = .stopped {
    didSet { if status != oldValue { onStatus?(status) } }
  }
  /// Called on the supervisor queue.
  public var onStatus: ((SupervisorStatus) -> Void)?
  public var log: (String) -> Void = { _ in }

  private let pidFile: URL
  private let logFile: URL
  private let grace: TimeInterval
  private var backoff: Backoff
  private var config: SatelliteConfig?
  private var wanted = false
  private var child: (pid: pid_t, started: TimeInterval, source: DispatchSourceProcess)?
  private var stopping: [() -> Void] = []
  private var restartToken = 0
  private var killToken = 0
  private var logTimer: DispatchSourceTimer?

  public init(pidFile: URL, logFile: URL, grace: TimeInterval = 10, backoff: Backoff = Backoff()) {
    self.pidFile = pidFile
    self.logFile = logFile
    self.grace = grace
    self.backoff = backoff
  }

  public var pid: pid_t? { queue.sync { child?.pid } }

  // MARK: public API (any thread)

  public func start(_ config: SatelliteConfig) {
    queue.async { [self] in
      self.config = config
      wanted = true
      backoff.reset()
      startLogTimer()
      if child == nil { spawn() }
    }
  }

  public func setStatus(_ status: SupervisorStatus) {
    queue.async { [self] in self.status = status }
  }

  /// Stops the child (SIGTERM, then SIGKILL after the grace period) and calls
  /// `completion` on the supervisor queue once it has exited.
  public func stop(_ completion: @escaping () -> Void = {}) {
    queue.async { [self] in
      wanted = false
      restartToken += 1
      guard let child else {
        status = .stopped
        completion()
        return
      }
      stopping.append(completion)
      log("stopping the satellite (pid \(child.pid))")
      kill(child.pid, SIGTERM)
      killToken += 1
      let token = killToken
      queue.asyncAfter(deadline: .now() + grace) { [weak self] in
        guard let self, token == self.killToken, let child = self.child else { return }
        self.log("satellite still running after \(Int(self.grace)) s, sending SIGKILL")
        kill(child.pid, SIGKILL)
      }
    }
  }

  /// Stop, then start again without backoff.
  public func restart() {
    stop { [weak self] in
      guard let self, let config = self.config else { return }
      self.start(config)
    }
  }

  /// Stops a satellite left by a previous run of the app: only when both
  /// the pid and its start time match the pid file, so a reused pid is never
  /// signalled. Blocks up to the grace period.
  public func stopOrphan() {
    queue.sync {
      guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
      let parts = text.split(whereSeparator: \.isWhitespace)
      try? FileManager.default.removeItem(at: pidFile)
      guard parts.count == 2, let pid = pid_t(parts[0]), let start = UInt64(parts[1]),
            ProcessInfoReader.startTime(pid) == start
      else { return }
      log("stopping a satellite left by a previous run (pid \(pid))")
      kill(pid, SIGTERM)
      let deadline = Date().addingTimeInterval(grace)
      while Date() < deadline, ProcessInfoReader.startTime(pid) == start {
        usleep(100_000)
      }
      if ProcessInfoReader.startTime(pid) == start { kill(pid, SIGKILL) }
    }
  }

  // MARK: queue

  private func spawn() {
    guard wanted, let config else { return }
    rotate(limit: Self.logLimit)
    let pid: pid_t
    do {
      pid = try Self.spawn(config, logFile: logFile)
    } catch {
      log("cannot start the satellite: \(error)")
      scheduleRestart(uptime: 0, lastExit: "\(error)")
      return
    }
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    source.setEventHandler { [weak self] in self?.reap(pid) }
    child = (pid, ProcessInfo.processInfo.systemUptime, source)
    source.resume()
    if let start = ProcessInfoReader.startTime(pid) {
      try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? "\(pid) \(start)\n".write(to: pidFile, atomically: true, encoding: .utf8)
    }
    log("started the satellite (pid \(pid)): \(config.python) \(config.args.joined(separator: " "))")
    status = .running(pid: pid)
    // The child may have exited before the source was registered.
    var raw: Int32 = 0
    if waitpid(pid, &raw, WNOHANG) == pid { exited(pid, raw) }
  }

  private func reap(_ pid: pid_t) {
    var raw: Int32 = 0
    guard waitpid(pid, &raw, WNOHANG) == pid else { return }
    exited(pid, raw)
  }

  private func exited(_ pid: pid_t, _ raw: Int32) {
    guard let current = child, current.pid == pid else { return }
    current.source.cancel()
    child = nil
    killToken += 1
    try? FileManager.default.removeItem(at: pidFile)
    let description = ExitStatus.describe(raw)
    let uptime = ProcessInfo.processInfo.systemUptime - current.started
    log("satellite exited: \(description) after \(Int(uptime)) s")
    if !stopping.isEmpty || !wanted {
      status = .stopped
      let callbacks = stopping
      stopping = []
      callbacks.forEach { $0() }
      return
    }
    scheduleRestart(uptime: uptime, lastExit: description)
  }

  private func scheduleRestart(uptime: TimeInterval, lastExit: String) {
    let delay = backoff.exited(uptime: uptime, now: ProcessInfo.processInfo.systemUptime)
    status = .restarting(in: delay, lastExit: lastExit, failing: backoff.failing)
    log("restarting the satellite in \(Int(delay)) s")
    restartToken += 1
    let token = restartToken
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, token == self.restartToken else { return }
      self.spawn()
    }
  }

  private func startLogTimer() {
    guard logTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 3600, repeating: 3600)
    timer.setEventHandler { [weak self] in self?.truncateIfHuge() }
    timer.resume()
    logTimer = timer
  }

  private func size(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  /// At each start: above 10 MB the log becomes `.1`.
  private func rotate(limit: UInt64) {
    guard size(logFile) > limit else { return }
    let old = logFile.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: logFile, to: old)
  }

  /// Hourly: above 50 MB, copy to `.1` and truncate (the child appends).
  private func truncateIfHuge() {
    guard size(logFile) > Self.logTruncateLimit else { return }
    let old = logFile.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.copyItem(at: logFile, to: old)
    truncate(logFile.path, 0)
  }

  // MARK: spawning

  public struct SpawnError: Error, CustomStringConvertible {
    public var description: String
  }

  static func spawn(_ config: SatelliteConfig, logFile: URL) throws -> pid_t {
    try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let logFD = open(logFile.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard logFD >= 0 else { throw SpawnError(description: "cannot open \(logFile.path): \(String(cString: strerror(errno)))") }
    defer { close(logFD) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, logFD, 1)
    posix_spawn_file_actions_adddup2(&actions, logFD, 2)
    posix_spawn_file_actions_addchdir_np(&actions, config.cwd)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    var defaults = sigset_t()
    sigfillset(&defaults)
    posix_spawnattr_setsigdefault(&attributes, &defaults)

    var environment = ProcessInfo.processInfo.environment
    for (key, value) in config.env { environment[key] = value }
    let argv = ([config.python] + config.args).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, config.python, &actions, &attributes, argv, envp)
    guard result == 0 else {
      throw SpawnError(description: "posix_spawn \(config.python): \(String(cString: strerror(result)))")
    }
    return pid
  }
}
