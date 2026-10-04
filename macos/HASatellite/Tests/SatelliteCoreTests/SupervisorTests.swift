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

  func shell(_ script: String, env: [String: String] = [:]) -> LaunchCommand {
    LaunchCommand(python: "/bin/sh", cwd: directory.path, args: ["-c", script], env: env)
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
    supervisor.start(LaunchCommand(python: "/nonexistent/python", cwd: directory.path, args: []))
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
    {"name": "  Salon  ", "mac_address": "AA-BB-CC-DD-EE-FF", "host": "192.168.1.5", "follow_network": false,
     "extra_args": ["--debug"], "env": {"A": "1"}, "python": "/repo/.venv/bin/python", "cwd": "/repo",
     "socket": "/tmp/s.sock", "agc": true, "_comment": "ignored"}
    """)
    XCTAssertEqual(config, SatelliteConfig(name: "Salon", macAddress: "aa:bb:cc:dd:ee:ff", host: "192.168.1.5", followNetwork: false,
                                           extraArgs: ["--debug"], env: ["A": "1"], python: "/repo/.venv/bin/python", cwd: "/repo",
                                           socket: "/tmp/s.sock", agc: true))
    XCTAssertEqual(try parse("{}"), SatelliteConfig())
    XCTAssertTrue(SatelliteConfig().followNetwork)
  }

  func testInvalid() {
    let cases: [(String, String)] = [
      ("[]", "satellite.json is not a JSON object"),
      (#"{"python": "python3"}"#, "\"python\" must be an absolute path"),
      (#"{"cwd": "repo"}"#, "\"cwd\" must be an absolute path"),
      (#"{"extra_args": ["a", 1]}"#, "\"extra_args\" must be a list of strings"),
      (#"{"env": {"A": 1}}"#, "\"env\" must map names to strings"),
      (#"{"socket": "rel"}"#, "\"socket\" must be an absolute path"),
      (#"{"agc": 1}"#, "\"agc\" must be true or false"),
      (#"{"follow_network": "yes"}"#, "\"follow_network\" must be true or false"),
      (#"{"pythn": "/x"}"#, "unknown key \"pythn\" in satellite.json"),
      (#"{"args": ["-m", "linux_voice_assistant"]}"#, "\"args\" is no longer used: the app builds the command, put additional flags in \"extra_args\""),
      (#"{"name": " "}"#, "\"name\": the name cannot be empty"),
      (#"{"name": 3}"#, "\"name\" must be a string"),
      (#"{"mac_address": "aa:bb"}"#, "\"mac_address\" must be a MAC address such as aa:bb:cc:dd:ee:ff"),
      (#"{"host": ""}"#, "\"host\" cannot be empty"),
    ]
    for (text, message) in cases {
      XCTAssertThrowsError(try parse(text), text) { error in
        XCTAssertEqual((error as? ConfigError)?.message, message)
      }
    }
  }

  func testMissingFileGivesDefaults() throws {
    XCTAssertEqual(try SatelliteConfig.load(URL(fileURLWithPath: "/nonexistent/satellite.json")), SatelliteConfig())
  }

  func testNames() throws {
    XCTAssertEqual(try SatelliteName.validate(" Bureau de Pierre-Alexis "), "Bureau de Pierre-Alexis")
    XCTAssertEqual(try SatelliteName.validate(String(repeating: "é", count: 64)).count, 64)
    for (raw, message) in [("", "the name cannot be empty"), ("\n", "the name cannot be empty"),
                           (String(repeating: "a", count: 65), "the name is longer than 64 characters"),
                           ("a\tb", "the name cannot contain control characters")] {
      XCTAssertThrowsError(try SatelliteName.validate(raw), raw) { error in
        XCTAssertEqual((error as? ConfigError)?.message, message)
      }
    }
    XCTAssertEqual(SatelliteName.fallback("MacBook Pro de Pierre"), "MacBook Pro de Pierre")
    XCTAssertEqual(SatelliteName.fallback(nil), "Mac")
    XCTAssertEqual(SatelliteName.fallback(" \t "), "Mac")
    XCTAssertEqual(SatelliteName.fallback(String(repeating: "b", count: 80)).count, 64)
    XCTAssertEqual(SatelliteConfig(name: "Salon").resolvedName(computerName: "Mac"), "Salon")
  }

  func testSetNameKeepsOtherKeys() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("support/satellite.json")
    try ConfigFile.setName(" Cuisine ", at: url)
    XCTAssertEqual(try SatelliteConfig.load(url), SatelliteConfig(name: "Cuisine"))
    let mode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o700)

    try Data(#"{"name": "Old", "agc": true, "_note": "kept"}"#.utf8).write(to: url)
    try ConfigFile.setName("Salon", at: url)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    XCTAssertEqual(object["name"] as? String, "Salon")
    XCTAssertEqual(object["agc"] as? Bool, true)
    XCTAssertEqual(object["_note"] as? String, "kept")

    XCTAssertThrowsError(try ConfigFile.setName("", at: url))
    XCTAssertEqual(try SatelliteConfig.load(url).name, "Salon", "an invalid name leaves the file alone")
    try Data("not json".utf8).write(to: url)
    XCTAssertThrowsError(try ConfigFile.setName("Salon", at: url))
  }

  func testBuiltInInterface() {
    let wifi = NetworkInterface(bsdName: "en1", kind: .wifi, mac: "A4:83:E7:00:00:01")
    let dock = NetworkInterface(bsdName: "en5", kind: .ethernet, mac: "00:e0:4c:00:00:02")
    let builtInEthernet = NetworkInterface(bsdName: "en0", kind: .ethernet, mac: "3c:22:fb:00:00:03")
    let bridge = NetworkInterface(bsdName: "bridge0", kind: .other, mac: "36:00:00:00:00:04")
    XCTAssertEqual(NetworkIdentity.builtIn([dock, bridge, wifi]), NetworkInterface(bsdName: "en1", kind: .wifi, mac: "a4:83:e7:00:00:01"))
    XCTAssertEqual(NetworkIdentity.builtIn([dock, builtInEthernet, wifi])?.bsdName, "en1", "Wi-Fi first")
    XCTAssertEqual(NetworkIdentity.builtIn([dock, builtInEthernet])?.bsdName, "en0", "desktop Macs without Wi-Fi")
    XCTAssertNil(NetworkIdentity.builtIn([dock, bridge]), "never a dock or adapter")
    XCTAssertNil(NetworkIdentity.builtIn([NetworkInterface(bsdName: "en0", kind: .wifi, mac: "00:00:00:00:00:00")]))
    XCTAssertEqual(NetworkIdentity.builtIn([NetworkInterface(bsdName: "en2", kind: .wifi, mac: "02:00:00:00:00:02"), wifi])?.bsdName, "en1")
    XCTAssertEqual(NetworkIdentity.normalize("aabbccddeeff"), "aa:bb:cc:dd:ee:ff")
    XCTAssertNil(NetworkIdentity.normalize("aa:bb:cc:dd:ee:gg"))

    XCTAssertEqual(SatelliteConfig().macSource(builtIn: wifi), .detected(wifi))
    XCTAssertEqual(SatelliteConfig(macAddress: "aa:bb:cc:dd:ee:ff").macSource(builtIn: wifi), .configured("aa:bb:cc:dd:ee:ff"))
    XCTAssertEqual(SatelliteConfig().macSource(builtIn: nil), .active)
  }

  /// The fixture shared with tests/unit/test_engine_wiring.py, which parses
  /// these arguments with LVA's parser.
  func testDefaultCommandMatchesSharedFixture() throws {
    let url = Fixtures.directory.deletingLastPathComponent().appendingPathComponent("macos_app/command.json")
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let interfaces = (fixture["interfaces"] as! [[String: String]]).map {
      NetworkInterface(bsdName: $0["bsd_name"]!, kind: $0["kind"] == "wifi" ? .wifi : .ethernet, mac: $0["mac"]!)
    }
    let paths = Paths(support: URL(fileURLWithPath: fixture["support"] as! String), logs: URL(fileURLWithPath: "/tmp/logs"))
    let bundle = BundleLayout(contents: URL(fileURLWithPath: fixture["contents"] as! String))
    let command = SatelliteConfig().command(bundle: bundle, paths: paths, computerName: fixture["computer_name"] as? String,
                                            builtIn: NetworkIdentity.builtIn(interfaces))
    XCTAssertEqual(command, LaunchCommand(python: fixture["python"] as! String, cwd: fixture["cwd"] as! String,
                                          args: fixture["args"] as! [String], env: fixture["env"] as! [String: String]))
  }

  func testOverrides() {
    let paths = Paths(support: URL(fileURLWithPath: "/s"), logs: URL(fileURLWithPath: "/l"))
    let bundle = BundleLayout(contents: URL(fileURLWithPath: "/A.app/Contents"))
    let config = SatelliteConfig(name: "Salon", macAddress: "aa:bb:cc:dd:ee:ff", host: "10.0.0.2", followNetwork: false, extraArgs: ["--debug"],
                                 env: ["LVA_LIBMPV_DIR": "/opt/lib"], python: "/repo/.venv/bin/python", cwd: "/repo", socket: "/t/a.sock")
    let command = config.command(bundle: bundle, paths: paths, computerName: "Mac", builtIn: NetworkInterface(bsdName: "en0", kind: .wifi, mac: "11:22:33:44:55:66"))
    XCTAssertEqual(command.python, "/repo/.venv/bin/python")
    XCTAssertEqual(command.cwd, "/repo")
    XCTAssertEqual(Array(command.args.prefix(8)), ["-m", "linux_voice_assistant", "--name", "Salon", "--host", "10.0.0.2", "--mac-address", "aa:bb:cc:dd:ee:ff"])
    XCTAssertFalse(command.args.contains("--follow-network"))
    XCTAssertFalse(command.args.contains("-I"))
    XCTAssertEqual(command.args.last, "--debug")
    XCTAssertEqual(command.args[command.args.firstIndex(of: "--control-socket")! + 1], "/t/a.sock")
    XCTAssertEqual(command.env["LVA_LIBMPV_DIR"], "/opt/lib")
    let active = SatelliteConfig().command(bundle: bundle, paths: paths, computerName: nil, builtIn: nil)
    XCTAssertFalse(active.args.contains("--mac-address"))
    XCTAssertEqual(active.args[active.args.firstIndex(of: "--name")! + 1], "Mac")
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
