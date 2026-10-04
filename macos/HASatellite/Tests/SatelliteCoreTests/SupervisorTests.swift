import Foundation
import XCTest

@testable import SatelliteCore

final class BackoffTests: XCTestCase {
  func testSequenceAndReset() {
    var backoff = Backoff()
    XCTAssertEqual((0..<5).map { backoff.exited(uptime: 1, now: Double($0) * 100) }, [2, 5, 10, 30, 30])
    XCTAssertEqual(backoff.exited(uptime: 300, now: 1000), 2, "reset after 5 minutes up")
    XCTAssertEqual(backoff.exited(uptime: 1, now: 1001), 5)
  }

  func testFailingAfterFiveExitsInTwoMinutes() {
    var backoff = Backoff()
    for i in 0..<4 { _ = backoff.exited(uptime: 1, now: Double(i * 10)) }
    XCTAssertFalse(backoff.failing)
    _ = backoff.exited(uptime: 1, now: 40)
    XCTAssertTrue(backoff.failing)
    _ = backoff.exited(uptime: 1, now: 200)
    XCTAssertFalse(backoff.failing, "older exits leave the window")
  }

  func testExitStatusDescriptions() {
    XCTAssertEqual(ExitStatus.describe(3 << 8), "exit code 3")
    XCTAssertTrue(ExitStatus.describe(9).hasPrefix("signal 9"))
  }
}

final class SupervisorTests: XCTestCase {
  var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("sup-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func makeSupervisor(grace: TimeInterval = 10, backoff: Backoff = Backoff(delays: [0.2, 0.4])) -> (Supervisor, StatusLog) {
    let supervisor = Supervisor(pidFile: directory.appendingPathComponent("run/satellite.pid"),
                                logFile: directory.appendingPathComponent("logs/satellite.log"), grace: grace, backoff: backoff)
    let statuses = StatusLog()
    supervisor.onStatus = { statuses.append($0) }
    return (supervisor, statuses)
  }

  final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SupervisorStatus] = []

    func append(_ status: SupervisorStatus) {
      lock.lock()
      items.append(status)
      lock.unlock()
    }

    var all: [SupervisorStatus] {
      lock.lock()
      defer { lock.unlock() }
      return items
    }
  }

  func shell(_ script: String, env: [String: String] = [:]) -> SatelliteConfig {
    SatelliteConfig(python: "/bin/sh", cwd: directory.path, args: ["-c", script], env: env)
  }

  func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return XCTFail("timed out: \(what)") }
      usleep(20_000)
    }
  }

  func log() -> String {
    (try? String(contentsOf: directory.appendingPathComponent("logs/satellite.log"), encoding: .utf8)) ?? ""
  }

  func testChildGetsConfigEnvironmentAndLogFile() {
    let (supervisor, _) = makeSupervisor()
    supervisor.start(shell("pwd; echo \"FOO=$FOO\"; read x || echo stdin-empty; sleep 30", env: ["FOO": "bar"]))
    wait("output") { log().contains("stdin-empty") }
    let output = log()
    XCTAssertTrue(output.contains(directory.lastPathComponent), output)
    XCTAssertTrue(output.contains("FOO=bar"), output)
    let pid = supervisor.pid!
    let pidFile = try? String(contentsOf: directory.appendingPathComponent("run/satellite.pid"), encoding: .utf8)
    XCTAssertEqual(pidFile, "\(pid) \(ProcessInfoReader.startTime(pid)!)\n")
    let stopped = expectation(description: "stopped")
    supervisor.stop { stopped.fulfill() }
    wait(for: [stopped], timeout: 5)
    XCTAssertNil(ProcessInfoReader.startTime(pid))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run/satellite.pid").path))
  }

  func testRestartsWithBackoff() {
    let (supervisor, statuses) = makeSupervisor()
    supervisor.start(shell("echo run; exit 3"))
    func restarts() -> [TimeInterval] {
      statuses.all.compactMap { status -> TimeInterval? in
        if case .restarting(let delay, let exit, _) = status {
          XCTAssertEqual(exit, "exit code 3")
          return delay
        }
        return nil
      }
    }
    wait("three restarts") { restarts().count >= 3 }
    XCTAssertEqual(Array(restarts().prefix(3)), [0.2, 0.4, 0.4])
    XCTAssertGreaterThanOrEqual(log().components(separatedBy: "run\n").count - 1, 3)
    let stopped = expectation(description: "stopped")
    supervisor.stop { stopped.fulfill() }
    wait(for: [stopped], timeout: 5)
    let count = log().components(separatedBy: "run\n").count
    usleep(600_000)
    XCTAssertEqual(log().components(separatedBy: "run\n").count, count, "no restart after stop")
    XCTAssertEqual(statuses.all.last, .stopped)
  }

  func testStopSendsTermThenKill() {
    let (supervisor, _) = makeSupervisor(grace: 0.5)
    supervisor.start(shell("trap 'echo got-term' TERM; echo ready; while :; do sleep 0.05; done"))
    wait("ready") { log().contains("ready") }
    let pid = supervisor.pid!
    let start = Date()
    let stopped = expectation(description: "stopped")
    supervisor.stop { stopped.fulfill() }
    wait(for: [stopped], timeout: 5)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5)
    XCTAssertTrue(log().contains("got-term"))
    XCTAssertNil(ProcessInfoReader.startTime(pid))
  }

  func testOrphanStoppedOnlyWhenStartTimeMatches() throws {
    let orphan = Process()
    orphan.executableURL = URL(fileURLWithPath: "/bin/sleep")
    orphan.arguments = ["30"]
    try orphan.run()
    defer { orphan.terminate() }
    let pid = orphan.processIdentifier
    let start = try XCTUnwrap(ProcessInfoReader.startTime(pid))
    let pidFile = directory.appendingPathComponent("run/satellite.pid")
    try FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)

    let (supervisor, _) = makeSupervisor(grace: 1)
    try "\(pid) \(start + 1)\n".write(to: pidFile, atomically: true, encoding: .utf8)
    supervisor.stopOrphan()
    XCTAssertTrue(orphan.isRunning, "reused pid: not signalled")

    try "\(pid) \(start)\n".write(to: pidFile, atomically: true, encoding: .utf8)
    supervisor.stopOrphan()
    orphan.waitUntilExit()
    XCTAssertEqual(orphan.terminationReason, .uncaughtSignal)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
  }

  func testSpawnFailureIsRetried() {
    let (supervisor, statuses) = makeSupervisor()
    supervisor.start(SatelliteConfig(python: "/nonexistent/python", cwd: directory.path, args: []))
    wait("restarting") { statuses.all.contains { if case .restarting = $0 { return true } else { return false } } }
    supervisor.stop()
  }
}

final class InstanceLockTests: XCTestCase {
  func testSecondInstanceIsRefused() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString.prefix(8))/audio.lock")
    var first = try InstanceLock(url: url)
    XCTAssertNotNil(first)
    XCTAssertNil(try InstanceLock(url: url))
    first = nil
    XCTAssertNotNil(try InstanceLock(url: url))
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}

final class ConfigTests: XCTestCase {
  func parse(_ text: String) throws -> SatelliteConfig {
    try SatelliteConfig.parse(Data(text.utf8))
  }

  func testValid() throws {
    let config = try parse("""
    {"python": "/repo/.venv/bin/python", "cwd": "/repo", "args": ["-m", "linux_voice_assistant", "--name", "Mac"],
     "env": {"PYTHONUNBUFFERED": "1"}, "socket": "/tmp/s.sock", "agc": true, "_comment": "ignored"}
    """)
    XCTAssertEqual(config, SatelliteConfig(python: "/repo/.venv/bin/python", cwd: "/repo", args: ["-m", "linux_voice_assistant", "--name", "Mac"],
                                           env: ["PYTHONUNBUFFERED": "1"], socket: "/tmp/s.sock", agc: true))
    let minimal = try parse(#"{"python": "/p", "cwd": "/c", "args": []}"#)
    XCTAssertEqual(minimal.env, [:])
    XCTAssertNil(minimal.socket)
    XCTAssertFalse(minimal.agc)
  }

  func testExampleFileParses() throws {
    let example = Fixtures.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("macos/satellite.json.example")
    var text = try String(contentsOf: example, encoding: .utf8)
    for (placeholder, value) in ["@REPO@": "/repo", "@SUPPORT@": "/support", "@NAME@": "Mac", "@MAC@": "00:11:22:33:44:55", "@LIBMPV@": "/mpv/lib"] {
      text = text.replacingOccurrences(of: placeholder, with: value)
    }
    XCTAssertFalse(text.contains("@"))
    let config = try SatelliteConfig.parse(Data(text.utf8))
    XCTAssertTrue(config.args.contains("--control-socket"))
  }

  func testInvalid() {
    let cases: [(String, String)] = [
      ("[]", "satellite.json is not a JSON object"),
      (#"{"python": "python3", "cwd": "/c", "args": []}"#, "\"python\" must be an absolute path"),
      (#"{"python": "/p", "args": []}"#, "\"cwd\" must be an absolute path"),
      (#"{"python": "/p", "cwd": "/c", "args": ["a", 1]}"#, "\"args\" must be a list of strings"),
      (#"{"python": "/p", "cwd": "/c", "args": [], "env": {"A": 1}}"#, "\"env\" must map names to strings"),
      (#"{"python": "/p", "cwd": "/c", "args": [], "socket": "rel"}"#, "\"socket\" must be an absolute path"),
      (#"{"python": "/p", "cwd": "/c", "args": [], "agc": 1}"#, "\"agc\" must be true or false"),
      (#"{"python": "/p", "cwd": "/c", "args": [], "pythn": "/x"}"#, "unknown key \"pythn\" in satellite.json"),
      (#"{"python": "/p", "cwd": "/c", "args": ["--name", "@NAME@"]}"#, "satellite.json still has the placeholder @NAME@: replace it with your value"),
      (#"{"python": "/p", "cwd": "/c", "args": [], "env": {"LVA_LIBMPV_DIR": "@LIBMPV@"}}"#, "satellite.json still has the placeholder @LIBMPV@: replace it with your value"),
    ]
    for (text, message) in cases {
      XCTAssertThrowsError(try parse(text), text) { error in
        XCTAssertEqual((error as? ConfigError)?.message, message)
      }
    }
  }

  func testMissingFileIsNotConfigured() throws {
    XCTAssertNil(try SatelliteConfig.load(URL(fileURLWithPath: "/nonexistent/satellite.json")))
  }

  func testPathsOverride() {
    let paths = Paths.standard(environment: ["HA_SATELLITE_HOME": "/tmp/h", "HA_SATELLITE_LOGS": "/tmp/l"])
    XCTAssertEqual(paths.socket.path, "/tmp/h/audio.sock")
    XCTAssertEqual(paths.config.path, "/tmp/h/satellite.json")
    XCTAssertEqual(paths.pidFile.path, "/tmp/h/run/satellite.pid")
    XCTAssertEqual(paths.satelliteLog.path, "/tmp/l/satellite.log")
    let standard = Paths.standard(environment: [:])
    XCTAssertTrue(standard.socket.path.hasSuffix("Library/Application Support/ha-satellite/audio.sock"))
    XCTAssertTrue(standard.logs.path.hasSuffix("Library/Logs/HA Satellite"))
  }
}
