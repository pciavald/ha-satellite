import Foundation
import XCTest

@testable import SatelliteCore

final class ControlModelTests: XCTestCase {
  func testStaleSnapshotsFixture() throws {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.directory.appendingPathComponent("sessions.json"))) as! [String: Any]
    for sequence in object["snapshots"] as! [[String: Any]] {
      let model = ControlModel()
      model.connect(lvaVersion: nil)
      let revs = sequence["revs"] as! [Int]
      let accepted = sequence["accepted"] as! [Bool]
      for (rev, expected) in zip(revs, accepted) {
        XCTAssertEqual(model.apply(Snapshot(rev: rev, haConnected: true, muted: false)), expected, "rev \(rev)")
      }
    }
  }

  func testRevResetsOnNewConnection() {
    let model = ControlModel()
    model.connect(lvaVersion: "1")
    model.apply(Snapshot(rev: 40, haConnected: true, muted: false))
    model.disconnect()
    model.connect(lvaVersion: "1")
    XCTAssertTrue(model.apply(Snapshot(rev: 1, haConnected: true, muted: true)))
  }

  func testToggleSendsExplicitCommandFromShownState() throws {
    let model = ControlModel()
    XCTAssertNil(model.toggleListening(), "not connected")
    model.connect(lvaVersion: nil)
    XCTAssertNil(model.toggleListening(), "no snapshot yet")
    model.apply(Snapshot(rev: 1, haConnected: true, muted: false))
    var frame = try XCTUnwrap(model.toggleListening())
    XCTAssertEqual(try frame.object()["command"] as? String, "mute_mic")
    model.apply(Snapshot(rev: 2, haConnected: true, muted: true))
    frame = try XCTUnwrap(model.toggleListening())
    XCTAssertEqual(try frame.object()["command"] as? String, "unmute_mic")
    XCTAssertNotEqual(try frame.object()["id"] as? Int, nil)
  }

  func testAckFailureAndTimeoutSurface() throws {
    let model = ControlModel()
    model.connect(lvaVersion: nil)
    model.apply(Snapshot(rev: 1, haConnected: true, muted: false))
    let start = Date()
    let first = try XCTUnwrap(model.toggleListening(now: start))
    let id = try XCTUnwrap(try first.object()["id"] as? Int)
    model.ack(id: id, ok: false, reason: "busy")
    XCTAssertEqual(model.notice, "mute_mic not applied: busy")
    model.ack(id: id, ok: true, reason: nil)  // unknown id now: ignored
    XCTAssertEqual(model.notice, "mute_mic not applied: busy")

    _ = model.toggleListening(now: start)
    XCTAssertFalse(model.expire(now: start.addingTimeInterval(1.9)))
    XCTAssertTrue(model.expire(now: start.addingTimeInterval(2)))
    XCTAssertEqual(model.notice, "mute_mic not applied: no answer")
  }

  func testTalkActions() {
    let model = ControlModel()
    XCTAssertEqual(model.talkAction(), .unavailable("satellite not running"))
    model.connect(lvaVersion: nil)
    model.apply(Snapshot(rev: 1, haConnected: false, muted: true))
    XCTAssertEqual(model.talkAction(), .unavailable("Home Assistant not connected"))
    model.apply(Snapshot(rev: 2, haConnected: true, muted: true))
    XCTAssertEqual(model.talkAction(), .start)
    model.apply(Snapshot(rev: 3, haConnected: true, muted: true, phase: "speaking"))
    XCTAssertEqual(model.talkAction(), .stop)
    model.apply(Snapshot(rev: 4, haConnected: true, muted: true, phase: "timer"))
    XCTAssertEqual(model.talkAction(), .stop)
  }

  func testPendingTalkClearsWhenLVATakesOver() {
    let model = ControlModel()
    model.connect(lvaVersion: nil)
    model.apply(Snapshot(rev: 1, haConnected: true, muted: true))
    let start = Date()
    model.beginTalk(now: start)
    XCTAssertTrue(model.pendingTalk)
    model.apply(Snapshot(rev: 2, haConnected: true, muted: true, ptt: true, phase: "listening"))
    XCTAssertFalse(model.pendingTalk)

    model.beginTalk(now: start)
    let frame = model.send(.startListening, data: ["allow_muted": true], now: start)
    let id = (try? frame.object()["id"] as? Int) ?? nil
    model.ack(id: id!, ok: false, reason: "pipeline_active")
    XCTAssertFalse(model.pendingTalk)

    model.beginTalk(now: start)
    XCTAssertTrue(model.expire(now: start.addingTimeInterval(10)))
    XCTAssertFalse(model.pendingTalk)
  }
}

final class MenuModelTests: XCTestCase {
  func state(_ snapshot: Snapshot? = Snapshot(rev: 1, haConnected: true, muted: false), capturing: Bool = true) -> AppState {
    var state = AppState(name: "Mac bureau")
    state.supervisor = .running(pid: 42)
    state.hub.controlConnected = snapshot != nil
    state.hub.snapshot = snapshot
    state.hub.micClient = true
    state.hub.audio.capturing = capturing
    state.hub.audio.engine = capturing ? .voice : nil
    return state
  }

  func testListening() {
    let model = MenuModel(state())
    XCTAssertEqual(model.title, "HA Satellite: Mac bureau")
    XCTAssertEqual(model.icon, .listening)
    XCTAssertEqual(model.homeAssistant, "Home Assistant: connected")
    XCTAssertEqual(model.microphone, "Microphone: listening, echo cancellation on")
    XCTAssertEqual(model.satellite, "Satellite: running")
    XCTAssertTrue(model.listeningChecked)
    XCTAssertTrue(model.listeningEnabled)
    XCTAssertTrue(model.talkEnabled)
    XCTAssertFalse(model.stopVisible)
    XCTAssertEqual(model.shortcutTitle, "⌃⌥Space")
  }

  func testWakeWordOff() {
    let model = MenuModel(state(Snapshot(rev: 1, haConnected: true, muted: true), capturing: false))
    XCTAssertEqual(model.icon, .muted)
    XCTAssertEqual(model.microphone, "Microphone: wake word off")
    XCTAssertFalse(model.listeningChecked)
    XCTAssertTrue(model.talkEnabled, "Talk now works with the wake word off")
  }

  func testPipelineAndTimer() {
    var model = MenuModel(state(Snapshot(rev: 1, haConnected: true, muted: false, phase: "thinking")))
    XCTAssertEqual(model.icon, .active)
    XCTAssertTrue(model.stopVisible)
    model = MenuModel(state(Snapshot(rev: 1, haConnected: true, muted: true, phase: "timer")))
    XCTAssertEqual(model.icon, .timer)
    XCTAssertTrue(model.stopVisible)
  }

  func testNoSatellite() {
    var s = state(nil, capturing: false)
    s.hub.micClient = false
    s.supervisor = .restarting(in: 5, lastExit: "exit code 1", failing: false)
    var model = MenuModel(s)
    XCTAssertEqual(model.homeAssistant, "Home Assistant: satellite not connected")
    XCTAssertEqual(model.satellite, "Satellite: restarting in 5 s")
    XCTAssertFalse(model.listeningEnabled)
    XCTAssertFalse(model.talkEnabled)
    XCTAssertEqual(model.icon, .problem)
    s.supervisor = .restarting(in: 30, lastExit: "exit code 1", failing: true)
    model = MenuModel(s)
    XCTAssertEqual(model.satellite, "Satellite failing, see logs")
    s.supervisor = .notConfigured(nil)
    XCTAssertEqual(MenuModel(s).satellite, "Satellite: not configured (no satellite.json)")
    s.supervisor = .disabled
    model = MenuModel(s)
    XCTAssertEqual(model.satellite, "Satellite: not started by the app")
    XCTAssertNotEqual(model.icon, .problem, "development mode is not a problem")
  }

  func testMicrophoneProblems() {
    var s = state()
    s.micPermission = .denied
    var model = MenuModel(s)
    XCTAssertEqual(model.microphone, "Microphone: not authorized")
    XCTAssertEqual(model.icon, .problem)
    XCTAssertTrue(model.accessibilityLabel.contains("not authorized"))
    s = state()
    s.hub.audio.noInputDevice = true
    XCTAssertEqual(MenuModel(s).microphone, "Microphone: no input device")
    s = state()
    s.hub.audio.failure = "start failed"
    XCTAssertEqual(MenuModel(s).icon, .problem)
  }

  func testHomeAssistantDisconnectedAfterGrace() {
    let now = Date()
    var s = state(Snapshot(rev: 1, haConnected: false, muted: false))
    s.now = now
    s.hub.haDisconnectedSince = now.addingTimeInterval(-10)
    var model = MenuModel(s)
    XCTAssertEqual(model.homeAssistant, "Home Assistant: waiting for Home Assistant")
    XCTAssertEqual(model.icon, .listening)
    XCTAssertFalse(model.talkEnabled)
    s.hub.haDisconnectedSince = now.addingTimeInterval(-31)
    model = MenuModel(s)
    XCTAssertEqual(model.icon, .problem)
  }

  func testLoginItemAndNotice() {
    var s = state()
    s.loginItem = .enabled
    XCTAssertTrue(MenuModel(s).loginChecked)
    s.loginItem = .requiresApproval
    XCTAssertEqual(MenuModel(s).loginTitle, "Open at Login (approve in System Settings)")
    s.shortcutError = "⌃⌥Space is used by another app (-9878)"
    XCTAssertEqual(MenuModel(s).notice, s.shortcutError)
    s.hub.notice = "mute_mic not applied: no answer"
    XCTAssertEqual(MenuModel(s).notice, "mute_mic not applied: no answer")
    s.shortcut = .none
    XCTAssertEqual(MenuModel(s).shortcutTitle, "")
  }
}
