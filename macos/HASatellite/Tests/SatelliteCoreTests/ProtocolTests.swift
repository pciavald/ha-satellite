import Foundation
import XCTest

@testable import SatelliteCore

enum Fixtures {
  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tests/fixtures/helper_protocol")

  static func load(_ name: String, _ key: String) throws -> [[String: Any]] {
    let data = try Data(contentsOf: directory.appendingPathComponent(name))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return object[key] as! [[String: Any]]
  }

  static func frames() throws -> [String: [String: Any]] {
    Dictionary(uniqueKeysWithValues: try load("frames.json", "frames").map { ($0["name"] as! String, $0) })
  }

  static func frame(_ name: String) throws -> Frame {
    let entry = try XCTUnwrap(try frames()[name], name)
    return try decode(entry["hex"] as! String)
  }
}

func bytes(_ hex: String) -> Data {
  var data = Data()
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    data.append(UInt8(hex[index..<next], radix: 16)!)
    index = next
  }
  return data
}

func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

func decode(_ hexString: String) throws -> Frame {
  var parser = FrameParser()
  parser.append(bytes(hexString))
  let frame = try XCTUnwrap(try parser.next())
  XCTAssertEqual(parser.buffered, 0)
  return frame
}

final class ProtocolTests: XCTestCase {
  func testFixtureFramesRoundTrip() throws {
    let entries = try Fixtures.load("frames.json", "frames")
    XCTAssertGreaterThan(entries.count, 30)
    for entry in entries {
      let name = entry["name"] as! String
      let expected = entry["hex"] as! String
      let type = try XCTUnwrap(FrameType(name: entry["type"] as! String), name)
      let frame = try decode(expected)
      XCTAssertEqual(frame.type, type, name)
      if let json = entry["json"] as? [String: Any] {
        XCTAssertEqual(hex(Wire.encode(.json(type, json))), expected, "canonical encoding of \(name)")
        XCTAssertEqual(try frame.object() as NSDictionary, json as NSDictionary, name)
      } else if let payload = entry["payload_hex"] as? String {
        XCTAssertEqual(hex(frame.payload), payload, name)
      } else if let samples = entry["samples"] as? [Int] {
        let (index, decoded) = try Wire.parseMicPCM(frame.payload)
        XCTAssertEqual(index, UInt64(entry["index"] as! Int))
        XCTAssertEqual(decoded.map(Int.init), samples)
        let encoded = decoded.withUnsafeBufferPointer { Wire.micPCM(index: index, samples: $0) }
        XCTAssertEqual(hex(Wire.encode(encoded)), expected)
      } else {
        XCTAssertTrue(frame.payload.isEmpty, name)
        XCTAssertEqual(hex(Wire.encode(Frame(type))), expected, name)
      }
    }
  }

  func testFixtureErrors() throws {
    for entry in try Fixtures.load("errors.json", "errors") {
      let name = entry["name"] as! String
      var parser = FrameParser()
      parser.append(bytes(entry["hex"] as! String))
      do {
        while try parser.next() != nil {}
        try parser.finish()
        XCTFail("\(name) accepted")
      } catch let error as ProtocolError {
        XCTAssertEqual(error.code, entry["error"] as? String, name)
        XCTAssertEqual(error.frame.type, .event)
        XCTAssertEqual(try error.frame.object()["code"] as? String, "protocol_error")
      }
    }
  }

  func testFixtureHellos() throws {
    for entry in try Fixtures.load("hello.json", "hello") {
      let name = entry["name"] as! String
      let frame = Frame.json(.hello, entry["json"] as! [String: Any])
      if let refusal = entry["refusal"] as? String {
        XCTAssertThrowsError(try Hello.parse(frame), name) { error in
          XCTAssertEqual((error as? HelloRefusal)?.reason, refusal, name)
        }
        continue
      }
      let hello = try Hello.parse(frame)
      XCTAssertEqual(hello.role.name, entry["role"] as? String, name)
      if let format = entry["format"] as? [String: Any] {
        XCTAssertEqual(hello.format?.sample.rawValue, format["format"] as? String)
        XCTAssertEqual(hello.format?.rate, format["rate"] as? Int)
        XCTAssertEqual(hello.format?.channels, format["channels"] as? Int)
      } else {
        XCTAssertNil(hello.format)
      }
    }
  }

  func testRepliesMatchFixtures() throws {
    let frames = try Fixtures.frames()
    let mic = MicHelloInfo(micAuthorized: true, agc: false, capturing: true, inputDevice: "MacBook Pro Microphone",
                           outputDevice: "MacBook Pro Speakers", rateIn: 44100, helperVersion: "0.1.0")
    XCTAssertEqual(hex(Wire.encode(mic.reply)), frames["hello_mic_reply"]!["hex"] as? String)
    let denied = MicHelloInfo(micAuthorized: false, agc: true, capturing: false, inputDevice: nil, outputDevice: nil, rateIn: nil, helperVersion: "0.1.0")
    XCTAssertEqual(hex(Wire.encode(denied.reply)), frames["hello_mic_reply_unauthorized"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(Hello.playReply())), frames["hello_play_reply"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(Hello.controlReply(helperVersion: "0.1.0"))), frames["hello_control_reply"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(HelloRefusal(reason: "unsupported_proto").reply)), frames["hello_refused_proto"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(ControlMessage.command(.muteMic, id: 7))), frames["control_mute_mic"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(ControlMessage.command(.startListening, id: 9, data: ["allow_muted": true]))), frames["control_start_listening"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(ControlMessage.ack(4, ok: false, reason: "unknown_command"))), frames["control_unknown_ack"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(.event("overrun", ["dropped": 480]))), frames["event_overrun"]!["hex"] as? String)
    XCTAssertEqual(hex(Wire.encode(ProtocolError.unknownType(9).frame)), frames["event_protocol_error"]!["hex"] as? String)
  }

  func testControlFixturesParse() throws {
    XCTAssertEqual(try ControlMessage.parse(Fixtures.frame("control_state")),
                   .state(Snapshot(rev: 42, haConnected: true, muted: false, ptt: false, phase: "idle", media: "idle", error: nil)))
    XCTAssertEqual(try ControlMessage.parse(Fixtures.frame("control_state_error")),
                   .state(Snapshot(rev: 43, haConnected: true, muted: true, ptt: true, phase: "listening", media: "paused", error: "stt-no-text-recognized")))
    XCTAssertEqual(try ControlMessage.parse(Fixtures.frame("control_ack_refused")), .ack(id: 9, ok: false, reason: "pipeline_active"))
    XCTAssertEqual(try ControlMessage.parse(Fixtures.frame("control_client_command")), .command(name: "self_destruct", id: 4))
    XCTAssertEqual(try ControlMessage.parse(.json(.control, ["something": 1])), .unknown)
    XCTAssertThrowsError(try ControlMessage.parse(.json(.control, ["state": ["phase": "idle"]])))
    XCTAssertThrowsError(try ControlMessage.parse(Frame(.event, Data("{}".utf8))))
  }

  func testSessionsReferenceFixtureFrames() throws {
    let frames = try Fixtures.frames()
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.directory.appendingPathComponent("sessions.json"))) as! [String: Any]
    for session in object["sessions"] as! [[String: Any]] {
      for step in session["steps"] as! [[String]] {
        let entry = try XCTUnwrap(frames[step[1]], step[1])
        XCTAssertEqual(entry["from"] as? String, step[0], step[1])
      }
    }
  }

  func testParserIsIncremental() throws {
    let stream = Wire.encode(.json(.hello, ["proto": 1, "role": "mic"])) + Wire.encode(Frame(.end)) + Wire.encode(Frame(.flush))
    var parser = FrameParser()
    var frames: [Frame] = []
    for byte in stream {
      parser.append(Data([byte]))
      while let frame = try parser.next() { frames.append(frame) }
    }
    try parser.finish()
    XCTAssertEqual(frames.map(\.type), [.hello, .end, .flush])
  }

  func testMaximumPayloadIsAccepted() throws {
    let frame = Frame(.pcm, Data(count: Wire.maxPayload))
    XCTAssertEqual(try decode(hex(Wire.encode(frame))), frame)
  }

  func testRoles() {
    XCTAssertEqual(Role("mic"), .mic)
    XCTAssertEqual(Role("control"), .control)
    XCTAssertEqual(Role("play:tts"), .play("tts"))
    XCTAssertNil(Role("play:"))
    XCTAssertNil(Role("speaker"))
    XCTAssertEqual(Role.play("music").name, "play:music")
  }

  func testMicPCMRejectsBadPayloads() {
    XCTAssertThrowsError(try Wire.parseMicPCM(Data(count: 7)))
    XCTAssertThrowsError(try Wire.parseMicPCM(Data(count: 9)))
  }
}
