import Foundation

// Socket contract between the app and the Python satellite (plans/audio.md
// section 6): 8-byte little-endian header `type u8, version u8, reserved u16,
// length u32`, then `length` bytes of payload.

public enum FrameType: UInt8, CaseIterable, Sendable {
  case hello = 1
  case pcm = 2
  case end = 3
  case drained = 4
  case flush = 5
  case event = 6
  case control = 7

  public var name: String {
    switch self {
    case .hello: return "HELLO"
    case .pcm: return "PCM"
    case .end: return "END"
    case .drained: return "DRAINED"
    case .flush: return "FLUSH"
    case .event: return "EVENT"
    case .control: return "CONTROL"
    }
  }

  public init?(name: String) {
    guard let type = FrameType.allCases.first(where: { $0.name == name }) else { return nil }
    self = type
  }
}

public struct Frame: Equatable, Sendable {
  public var type: FrameType
  public var payload: Data

  public init(_ type: FrameType, _ payload: Data = Data()) {
    self.type = type
    self.payload = payload
  }

  public static func json(_ type: FrameType, _ object: [String: Any]) -> Frame {
    Frame(type, JSON.encode(object))
  }

  public static func event(_ code: String, _ extra: [String: Any] = [:]) -> Frame {
    var object = extra
    object["code"] = code
    return json(.event, object)
  }

  public func object() throws -> [String: Any] {
    try JSON.decode(payload)
  }
}

public enum ProtocolError: Error, Equatable, Sendable {
  case badVersion(UInt8)
  case unknownType(UInt8)
  case oversize(Int)
  case truncated
  case badJSON
  case unexpected(FrameType)
  case badPayload(String)

  public var code: String {
    switch self {
    case .badVersion: return "bad_version"
    case .unknownType: return "unknown_type"
    case .oversize: return "oversize"
    case .truncated: return "truncated"
    case .badJSON: return "bad_json"
    case .unexpected: return "unexpected_frame"
    case .badPayload: return "bad_payload"
    }
  }

  public var message: String {
    switch self {
    case .badVersion(let v): return "frame version \(v), expected \(Wire.version)"
    case .unknownType(let t): return "unknown frame type \(t)"
    case .oversize(let n): return "payload of \(n) bytes exceeds \(Wire.maxPayload)"
    case .truncated: return "connection closed inside a frame"
    case .badJSON: return "payload is not a JSON object"
    case .unexpected(let t): return "\(t.name) is not valid here"
    case .badPayload(let why): return why
    }
  }

  /// The EVENT sent before closing a connection on this error.
  public var frame: Frame {
    .event("protocol_error", ["error": code, "msg": message])
  }
}

public enum Wire {
  public static let version: UInt8 = 1
  public static let proto = 1
  public static let headerSize = 8
  public static let maxPayload = 65536

  public static func encode(_ frame: Frame) -> Data {
    precondition(frame.payload.count <= maxPayload, "payload too large")
    var data = Data(capacity: headerSize + frame.payload.count)
    data.append(frame.type.rawValue)
    data.append(version)
    data.append(contentsOf: [0, 0])
    withUnsafeBytes(of: UInt32(frame.payload.count).littleEndian) { data.append(contentsOf: $0) }
    data.append(frame.payload)
    return data
  }

  /// Validates a header and returns the frame type and payload length.
  public static func header(_ bytes: Data) throws -> (FrameType, Int) {
    precondition(bytes.count >= headerSize)
    let base = bytes.startIndex
    let rawType = bytes[base]
    let v = bytes[base + 1]
    let length = Int(bytes[base + 4]) | Int(bytes[base + 5]) << 8 | Int(bytes[base + 6]) << 16 | Int(bytes[base + 7]) << 24
    guard v == version else { throw ProtocolError.badVersion(v) }
    guard let type = FrameType(rawValue: rawType) else { throw ProtocolError.unknownType(rawType) }
    guard length <= maxPayload else { throw ProtocolError.oversize(length) }
    return (type, length)
  }

  /// `mic` PCM payload: u64 index of the first sample, then s16le samples.
  public static func micPCM(index: UInt64, samples: UnsafeBufferPointer<Int16>) -> Frame {
    var data = Data(capacity: 8 + samples.count * 2)
    withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
    for sample in samples {
      withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return Frame(.pcm, data)
  }

  public static func parseMicPCM(_ payload: Data) throws -> (UInt64, [Int16]) {
    guard payload.count >= 8, (payload.count - 8) % 2 == 0 else {
      throw ProtocolError.badPayload("mic PCM payload of \(payload.count) bytes")
    }
    let bytes = [UInt8](payload)
    var index: UInt64 = 0
    for i in 0..<8 { index |= UInt64(bytes[i]) << (8 * UInt64(i)) }
    var samples = [Int16]()
    samples.reserveCapacity((bytes.count - 8) / 2)
    var i = 8
    while i < bytes.count {
      samples.append(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
      i += 2
    }
    return (index, samples)
  }
}

/// Incremental parser for a byte stream.
public struct FrameParser {
  private var buffer = Data()

  public init() {}

  public var buffered: Int { buffer.count }

  public mutating func append(_ data: Data) {
    buffer.append(data)
  }

  /// Returns the next complete frame, nil when more bytes are needed.
  public mutating func next() throws -> Frame? {
    guard buffer.count >= Wire.headerSize else { return nil }
    let (type, length) = try Wire.header(buffer.prefix(Wire.headerSize))
    guard buffer.count >= Wire.headerSize + length else { return nil }
    let start = buffer.startIndex + Wire.headerSize
    let payload = Data(buffer[start..<(start + length)])
    buffer = Data(buffer[(start + length)...])
    return Frame(type, payload)
  }

  /// Called at end of stream: leftover bytes mean a truncated frame.
  public func finish() throws {
    if !buffer.isEmpty { throw ProtocolError.truncated }
  }
}

/// Canonical JSON: sorted keys, no whitespace, slashes unescaped. The Python
/// side encodes with `json.dumps(obj, sort_keys=True, separators=(",", ":"),
/// ensure_ascii=False)`, so both produce the same bytes for the fixtures.
public enum JSON {
  public static func encode(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
  }

  public static func decode(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
      throw ProtocolError.badJSON
    }
    return dict
  }
}

// MARK: - Roles and HELLO

public enum SampleFormat: String, Sendable {
  case s16le
  case f32le

  public var bytes: Int { self == .s16le ? 2 : 4 }
}

public struct PlayFormat: Equatable, Sendable {
  public var sample: SampleFormat
  public var rate: Int
  public var channels: Int

  public init(sample: SampleFormat, rate: Int, channels: Int) {
    self.sample = sample
    self.rate = rate
    self.channels = channels
  }

  public var bytesPerFrame: Int { sample.bytes * channels }
}

public enum Role: Equatable, Sendable {
  case mic
  case play(String)
  case control

  public init?(_ name: String) {
    if name == "mic" {
      self = .mic
    } else if name == "control" {
      self = .control
    } else if name.hasPrefix("play:"), name.count > 5 {
      self = .play(String(name.dropFirst(5)))
    } else {
      return nil
    }
  }

  public var name: String {
    switch self {
    case .mic: return "mic"
    case .control: return "control"
    case .play(let n): return "play:\(n)"
    }
  }
}

public struct ClientHello: Equatable, Sendable {
  public var role: Role
  public var format: PlayFormat?
  public var lvaVersion: String?
}

public struct HelloRefusal: Error, Equatable, Sendable {
  public var reason: String

  public var reply: Frame {
    .json(.hello, ["proto": Wire.proto, "accepted": false, "reason": reason])
  }
}

public enum Hello {
  public static let bufferMs = 200

  public static func parse(_ frame: Frame) throws -> ClientHello {
    guard frame.type == .hello else { throw ProtocolError.unexpected(frame.type) }
    let object = try frame.object()
    guard (object["proto"] as? Int) == Wire.proto else { throw HelloRefusal(reason: "unsupported_proto") }
    guard let name = object["role"] as? String, let role = Role(name) else { throw HelloRefusal(reason: "unknown_role") }
    var hello = ClientHello(role: role, format: nil, lvaVersion: object["lva_version"] as? String)
    if case .play = role {
      guard let raw = object["format"] as? String, let sample = SampleFormat(rawValue: raw),
            let rate = object["rate"] as? Int, (8000...192_000).contains(rate),
            let channels = object["channels"] as? Int, (1...2).contains(channels)
      else { throw HelloRefusal(reason: "unsupported_format") }
      hello.format = PlayFormat(sample: sample, rate: rate, channels: channels)
    }
    return hello
  }

  public static func playReply() -> Frame {
    .json(.hello, ["proto": Wire.proto, "accepted": true, "buffer_ms": bufferMs])
  }

  public static func controlReply(helperVersion: String) -> Frame {
    .json(.hello, ["proto": Wire.proto, "accepted": true, "helper_version": helperVersion])
  }
}

public struct MicHelloInfo: Equatable, Sendable {
  public var micAuthorized: Bool
  public var agc: Bool
  public var capturing: Bool
  public var inputDevice: String?
  public var outputDevice: String?
  public var rateIn: Int?
  public var helperVersion: String

  public init(micAuthorized: Bool, agc: Bool, capturing: Bool, inputDevice: String?, outputDevice: String?, rateIn: Int?, helperVersion: String) {
    self.micAuthorized = micAuthorized
    self.agc = agc
    self.capturing = capturing
    self.inputDevice = inputDevice
    self.outputDevice = outputDevice
    self.rateIn = rateIn
    self.helperVersion = helperVersion
  }

  public var reply: Frame {
    var object: [String: Any] = [
      "proto": Wire.proto,
      "accepted": true,
      "format": "s16le",
      "rate": 16000,
      "channels": 1,
      "frame_samples": 160,
      "processing": agc ? ["aec", "ns", "agc"] : ["aec", "ns"],
      "mic_authorized": micAuthorized,
      "vp": true,
      "agc": agc,
      "capturing": capturing,
      "helper_version": helperVersion,
    ]
    if let inputDevice {
      object["device"] = inputDevice
      object["input_device"] = inputDevice
    }
    if let outputDevice { object["output_device"] = outputDevice }
    if let rateIn { object["rate_in"] = rateIn }
    return .json(.hello, object)
  }
}
