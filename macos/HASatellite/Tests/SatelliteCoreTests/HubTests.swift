import AVFoundation
import XCTest

@testable import SatelliteCore

/// Timers fired by the test (on the hub's queue) instead of the clock.
final class ManualScheduler: Scheduler, @unchecked Sendable {
  private var offset: TimeInterval = 0
  private var pending: [(at: TimeInterval, block: () -> Void)] = []

  var now: TimeInterval { ProcessInfo.processInfo.systemUptime + offset }

  func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
    pending.append((now + delay, block))
  }

  /// Moves time forward and runs what is due. Call on the hub's queue.
  func advance(_ seconds: TimeInterval) {
    offset += seconds
    let due = pending.filter { $0.at <= now }
    pending.removeAll { $0.at <= now }
    due.forEach { $0.block() }
  }
}

/// Plays in real time: completions fire when the buffer would have been heard.
final class FakePlayer: PlayerOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var playhead = DispatchTime.now()
  private var pending: [Int: () -> Void] = [:]
  private var nextId = 0
  private(set) var scheduledFrames = 0
  private(set) var detached = false

  func schedule(_ buffer: AVAudioPCMBuffer, playedBack: Bool, completion: @escaping @Sendable () -> Void) {
    lock.lock()
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    playhead = max(playhead, DispatchTime.now()) + duration
    let id = nextId
    nextId += 1
    pending[id] = completion
    scheduledFrames += Int(buffer.frameLength)
    let at = playhead
    lock.unlock()
    DispatchQueue.global().asyncAfter(deadline: at) { [weak self] in self?.fire(id) }
  }

  private func fire(_ id: Int) {
    lock.lock()
    let completion = pending.removeValue(forKey: id)
    lock.unlock()
    completion?()
  }

  /// Like AVAudioPlayerNode.stop(): pending completions fire at once.
  func reset() {
    lock.lock()
    let all = pending.values
    pending = [:]
    playhead = DispatchTime.now()
    lock.unlock()
    all.forEach { $0() }
  }

  func detach() {
    lock.lock()
    detached = true
    lock.unlock()
    reset()
  }
}

final class FakeEngine: AudioEngine, @unchecked Sendable {
  let kind: EngineKind
  let inputRate: Double?
  let capture: (AVAudioPCMBuffer) -> Void
  let configurationChanged: () -> Void
  private(set) var started = false
  private(set) var stopped = false
  private(set) var agc: Bool
  private(set) var players: [FakePlayer] = []

  init(kind: EngineKind, agc: Bool, capture: @escaping (AVAudioPCMBuffer) -> Void, configurationChanged: @escaping () -> Void) {
    self.kind = kind
    self.agc = agc
    // The output-only engine never reads the input.
    inputRate = kind == .voice ? 48000 : nil
    self.capture = capture
    self.configurationChanged = configurationChanged
  }

  func start() throws { started = true }
  func stop() { stopped = true }
  func setAGC(_ on: Bool) { agc = on }

  func makePlayer(format: AVAudioFormat) -> PlayerOutput? {
    let player = FakePlayer()
    players.append(player)
    return player
  }

  /// Delivers `seconds` of a 440 Hz tone at 48 kHz in 10 ms tap buffers.
  func feed(seconds: Double) {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    for _ in 0..<Int(seconds * 100) {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
      buffer.frameLength = 480
      for i in 0..<480 { buffer.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 48000) }
      capture(buffer)
    }
  }
}

final class FakeFactory: EngineFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var engines: [FakeEngine] = []
  var failures = 0

  var made: [FakeEngine] {
    lock.lock()
    defer { lock.unlock() }
    return engines
  }

  var current: FakeEngine? { made.last.flatMap { $0.stopped ? nil : $0 } }

  func make(kind: EngineKind, agc: Bool, capture: @escaping (AVAudioPCMBuffer) -> Void, configurationChanged: @escaping () -> Void) throws -> AudioEngine {
    lock.lock()
    defer { lock.unlock() }
    if failures > 0 {
      failures -= 1
      throw EngineError.startFailed("simulated")
    }
    let engine = FakeEngine(kind: kind, agc: agc, capture: capture, configurationChanged: configurationChanged)
    engines.append(engine)
    return engine
  }
}

/// A client of the hub's socket, like the Python side.
final class Client {
  let connection: Connection

  init(_ path: String, hello: [String: Any]) throws {
    connection = try Connection.connect(path: path)
    connection.send(.json(.hello, hello))
  }

  func next(_ timeout: TimeInterval = 2) -> Frame? {
    try? connection.read(timeout: timeout)
  }

  /// Next frame that is not mic PCM.
  func nextEvent(_ timeout: TimeInterval = 2) -> Frame? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      guard let frame = next(deadline.timeIntervalSinceNow) else { return nil }
      if frame.type != .pcm { return frame }
    }
    return nil
  }

  func code(_ frame: Frame?) -> String? {
    (try? frame?.object())?["code"] as? String
  }

  func send(_ frame: Frame) {
    connection.send(frame)
  }

  deinit {
    connection.close()
  }
}

final class HubTests: XCTestCase {
  var directory: URL!
  var factory: FakeFactory!
  var scheduler: ManualScheduler!
  var hub: Hub!
  var path: String { directory.appendingPathComponent("audio.sock").path }

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: "/tmp/hub-\(UUID().uuidString.prefix(8))")
    factory = FakeFactory()
    scheduler = ManualScheduler()
    hub = Hub(socketPath: directory.appendingPathComponent("audio.sock").path, helperVersion: "test", factory: factory, scheduler: scheduler)
    try hub.start()
  }

  override func tearDownWithError() throws {
    hub.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  func wait(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return XCTFail("timed out: \(what)") }
      usleep(10_000)
    }
  }

  /// The engine is built and started (the hub publishes it afterwards).
  func waitForEngine(_ kind: EngineKind) {
    wait("\(kind.rawValue) engine") { hub.state.audio.engine == kind && factory.current?.kind == kind }
  }

  func advance(_ seconds: TimeInterval) {
    hub.queue.sync { scheduler.advance(seconds) }
  }

  func state(rev: Int, muted: Bool, ptt: Bool = false, phase: String = "idle") -> Frame {
    .json(.control, ["state": ["rev": rev, "ha_connected": true, "muted": muted, "ptt": ptt, "phase": phase, "media": "idle", "error": NSNull()]])
  }

  func connectControl(muted: Bool) throws -> Client {
    let control = try Client(path, hello: ["proto": 1, "role": "control", "lva_version": "1.2.0"])
    XCTAssertEqual(try control.next()?.object()["accepted"] as? Bool, true)
    control.send(state(rev: 1, muted: muted))
    wait("snapshot") { hub.state.snapshot?.muted == muted }
    return control
  }

  /// Reads mic PCM until `samples` have arrived; checks the indices are contiguous.
  func readPCM(_ mic: Client, samples: Int, from start: UInt64? = nil) throws -> [Int16] {
    var all: [Int16] = []
    var expected = start
    while all.count < samples {
      let frame = try XCTUnwrap(mic.next(), "PCM")
      guard frame.type == .pcm else { continue }
      let (index, values) = try Wire.parseMicPCM(frame.payload)
      if let expected { XCTAssertEqual(index, expected, "contiguous indices") }
      XCTAssertEqual(values.count % 160, 0)
      expected = index + UInt64(values.count)
      all += values
    }
    return all
  }

  func testMicHandshakeAndFrames() throws {
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    let reply = try XCTUnwrap(mic.next()).object()
    XCTAssertEqual(reply["rate"] as? Int, 16000)
    XCTAssertEqual(reply["frame_samples"] as? Int, 160)
    XCTAssertEqual(reply["mic_authorized"] as? Bool, true)
    XCTAssertEqual(reply["capturing"] as? Bool, true)
    XCTAssertEqual(reply["processing"] as? [String], ["aec", "ns"])
    waitForEngine(.voice)
    let engine = factory.current!
    XCTAssertTrue(engine.started)
    engine.feed(seconds: 0.1)
    wait("forwarding") { hub.state.audio.capturing }
    engine.feed(seconds: 1)
    let samples = try readPCM(mic, samples: 12000, from: 0)
    XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max()!, 8000, "the tone, not silence")
  }

  func testMuteReleasesTheEngineAndUnmuteResumes() throws {
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = mic.next()
    let control = try connectControl(muted: false)
    waitForEngine(.voice)
    factory.current!.feed(seconds: 0.1)
    wait("forwarding") { hub.state.audio.capturing }

    control.send(state(rev: 2, muted: true))
    XCTAssertEqual(mic.code(mic.nextEvent()), "capture_paused")
    let voice = factory.current!
    voice.feed(seconds: 0.5)
    XCTAssertNil(mic.next(0.3), "nothing after capture_paused")
    XCTAssertFalse(voice.stopped, "kept for the linger")
    advance(EngineRules.linger)
    XCTAssertTrue(voice.stopped)
    XCTAssertNil(factory.current)

    control.send(state(rev: 3, muted: false))
    waitForEngine(.voice)
    factory.current!.feed(seconds: 0.2)
    XCTAssertEqual(mic.code(mic.nextEvent()), "capture_resumed")
    factory.current!.feed(seconds: 0.2)
    _ = try readPCM(mic, samples: 1600)
  }

  func testStaleSnapshotIgnored() throws {
    let control = try connectControl(muted: false)
    control.send(state(rev: 5, muted: true))
    wait("rev 5") { hub.state.snapshot?.rev == 5 }
    control.send(state(rev: 4, muted: false))
    control.send(state(rev: 6, muted: true, phase: "listening"))
    wait("rev 6") { hub.state.snapshot?.rev == 6 }
    XCTAssertEqual(hub.state.snapshot?.muted, true)
  }

  func testToggleSendsCommandAndAckClearsIt() throws {
    let control = try connectControl(muted: false)
    hub.toggleListening()
    let command = try XCTUnwrap(control.next()).object()
    XCTAssertEqual(command["command"] as? String, "mute_mic")
    let id = try XCTUnwrap(command["id"] as? Int)
    control.send(ControlMessage.ack(id, ok: false, reason: "busy"))
    wait("notice") { hub.state.notice == "mute_mic not applied: busy" }
  }

  func testTalkNowWhileMutedStartsCaptureThenListening() throws {
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = mic.next()
    let control = try connectControl(muted: true)
    XCTAssertEqual(mic.code(mic.nextEvent()), "capture_paused")
    advance(EngineRules.linger)
    XCTAssertNil(factory.current)
    hub.talkNow()
    waitForEngine(.voice)
    factory.current!.feed(seconds: 0.1)
    let command = try XCTUnwrap(control.next()).object()
    XCTAssertEqual(command["command"] as? String, "start_listening")
    XCTAssertEqual((command["data"] as? [String: Any])?["allow_muted"] as? Bool, true)
    XCTAssertEqual(mic.code(mic.nextEvent()), "capture_resumed")
    // LVA takes over with ptt, then ends the pipeline: capture pauses again.
    control.send(state(rev: 2, muted: true, ptt: true, phase: "listening"))
    wait("ptt") { hub.state.snapshot?.ptt == true && !hub.state.pendingTalk }
    hub.talkNow()
    XCTAssertEqual(try control.next()?.object()["command"] as? String, "stop_pipeline")
    control.send(state(rev: 3, muted: true))
    XCTAssertEqual(mic.code(mic.nextEvent()), "capture_paused")
  }

  func testPlayWhileMutedUsesOutputOnlyEngine() throws {
    let play = try Client(path, hello: ["proto": 1, "role": "play:tts", "format": "s16le", "rate": 48000, "channels": 1])
    let reply = try XCTUnwrap(play.next()).object()
    XCTAssertEqual(reply["buffer_ms"] as? Int, 200)
    XCTAssertEqual(reply["accepted"] as? Bool, true)
    XCTAssertNil(factory.current)

    // 0.5 s in 50 ms chunks (2400 frames), sent as fast as the app reads.
    let start = Date()
    for _ in 0..<10 { play.send(Frame(.pcm, Data(count: 4800))) }
    play.send(Frame(.end))
    let drained = try XCTUnwrap(play.next(3))
    XCTAssertEqual(drained.type, .drained)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertGreaterThan(elapsed, 0.45, "DRAINED after playback, not on receipt")
    XCTAssertLessThan(elapsed, 1.5)
    XCTAssertEqual(factory.made.map(\.kind), [.outputOnly])
    XCTAssertNil(factory.made[0].inputRate)
    XCTAssertEqual(factory.made[0].players.first?.scheduledFrames ?? 0, 24000 + 48, "item plus the END marker")
    advance(EngineRules.linger)
    XCTAssertTrue(factory.made[0].stopped)
  }

  func testPacingKeepsTheQueueShort() throws {
    let play = try Client(path, hello: ["proto": 1, "role": "play:tts", "format": "s16le", "rate": 48000, "channels": 1])
    _ = play.next()
    let sent = Date()
    let sender = Thread {
      for _ in 0..<20 { play.send(Frame(.pcm, Data(count: 9600))) }  // 2 s in 100 ms chunks
    }
    sender.start()
    wait("engine") { factory.current != nil }
    usleep(500_000)
    // After 0.5 s at most 0.5 s played plus the 200 ms buffer and one chunk.
    let scheduled = Double(factory.current!.players[0].scheduledFrames) / 48000
    XCTAssertLessThan(scheduled, Date().timeIntervalSince(sent) + 0.35)
  }

  func testFlushAnswersDrainedAtOnce() throws {
    let play = try Client(path, hello: ["proto": 1, "role": "play:tts", "format": "s16le", "rate": 48000, "channels": 1])
    _ = play.next()
    for _ in 0..<4 { play.send(Frame(.pcm, Data(count: 9600))) }
    usleep(100_000)
    let start = Date()
    play.send(Frame(.flush))
    XCTAssertEqual(play.next()?.type, .drained)
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    play.send(Frame(.end))
    XCTAssertEqual(play.next()?.type, .drained, "END without an item")
  }

  func testUnmuteDuringOutputOnlyPlaybackCutsTheItem() throws {
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = mic.next()
    let control = try connectControl(muted: true)
    advance(EngineRules.linger)
    let play = try Client(path, hello: ["proto": 1, "role": "play:tts", "format": "s16le", "rate": 48000, "channels": 1])
    _ = play.next()
    for _ in 0..<5 { play.send(Frame(.pcm, Data(count: 9600))) }
    waitForEngine(.outputOnly)
    control.send(state(rev: 2, muted: false))
    XCTAssertEqual(play.code(play.next()), "interrupted")
    waitForEngine(.voice)
    play.send(Frame(.end))
    XCTAssertEqual(play.next()?.type, .drained)
  }

  func testUnauthorizedMicPausesAndReportsIt() throws {
    hub.setMicAuthorized(false)
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    let reply = try XCTUnwrap(mic.next()).object()
    XCTAssertEqual(reply["mic_authorized"] as? Bool, false)
    XCTAssertEqual(reply["capturing"] as? Bool, false)
    let codes = [mic.code(mic.nextEvent()), mic.code(mic.nextEvent())]
    XCTAssertEqual(Set(codes.compactMap { $0 }), ["capture_paused", "permission_denied"])
    XCTAssertTrue(factory.made.isEmpty)
  }

  func testEngineFailureRetriesWithSilence() throws {
    factory.failures = 1
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = mic.next()
    wait("failure") { hub.state.audio.failure != nil }
    // Silence with advancing indices meanwhile.
    let silence = try readPCM(mic, samples: 800, from: 0)
    XCTAssertEqual(silence.max(), 0)
    advance(1)
    waitForEngine(.voice)
  }

  func testPowerEvents() throws {
    let mic = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = mic.next()
    waitForEngine(.voice)
    let allowed = expectation(description: "sleep allowed")
    hub.willSleep { allowed.fulfill() }
    XCTAssertEqual(mic.code(mic.nextEvent()), "will_sleep")
    mic.send(.event("sleep_ready"))
    wait(for: [allowed], timeout: 1)
    wait("engine stopped") { factory.current == nil }
    hub.didWake()
    XCTAssertEqual(mic.code(mic.nextEvent()), "did_wake")
    hub.networkChanged()
    XCTAssertEqual(mic.code(mic.nextEvent()), "network_changed")
  }

  func testCommandsFromTheSatelliteAreRefused() throws {
    let control = try connectControl(muted: false)
    control.send(.json(.control, ["command": "set_agc", "id": 3, "data": ["on": true]]))
    XCTAssertEqual(try control.next()?.object() as NSDictionary?, ["ack": 3, "ok": false, "reason": "unknown_command"] as NSDictionary)
    XCTAssertFalse(hub.state.audio.agc)
  }

  func testProtocolErrorsCloseTheConnection() throws {
    let bad = try Client(path, hello: ["proto": 2, "role": "mic"])
    XCTAssertEqual(try bad.next()?.object()["reason"] as? String, "unsupported_proto")
    XCTAssertNil(bad.next(0.5))

    let control = try Client(path, hello: ["proto": 1, "role": "control"])
    _ = control.next()
    control.send(Frame(.pcm, Data(count: 4)))
    let error = try XCTUnwrap(control.next()).object()
    XCTAssertEqual(error["code"] as? String, "protocol_error")
    XCTAssertEqual(error["error"] as? String, "unexpected_frame")

    let raw = try Connection.connect(path: path)
    var garbage = Data([9, 1, 0, 0, 0, 0, 0, 0])
    raw.send(.json(.hello, ["proto": 1, "role": "play:tts", "format": "s16le", "rate": 48000, "channels": 1]))
    _ = try raw.read(timeout: 2)
    garbage.withUnsafeMutableBytes { _ = Darwin.send(raw.fd, $0.baseAddress!, 8, 0) }
    XCTAssertEqual(try raw.read(timeout: 2)?.object()["error"] as? String, "unknown_type")
    XCTAssertNil(try raw.read(timeout: 2))
  }

  func testNewConnectionReplacesTheOldOne() throws {
    let first = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = first.next()
    let second = try Client(path, hello: ["proto": 1, "role": "mic"])
    _ = second.next()
    // The first one keeps receiving frames until the hub closes it.
    var closed = false
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if first.next(1) == nil {
        closed = true
        break
      }
    }
    XCTAssertTrue(closed)
    XCTAssertTrue(hub.state.micClient)
  }

  func testSocketPermissions() throws {
    var info = stat()
    XCTAssertEqual(stat(path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(stat(directory.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
  }
}
