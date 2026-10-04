import Foundation

// The `control` role (plans/audio.md 6.2): Python sends full state snapshots
// and acks, the app sends explicit commands. LVA's state is the only source of
// truth; the app keeps the last snapshot and never a copy of its own.

public struct Snapshot: Equatable, Sendable {
  public var rev: Int
  public var haConnected: Bool
  public var muted: Bool
  public var ptt: Bool
  public var phase: String
  public var media: String
  public var error: String?

  public init(rev: Int, haConnected: Bool, muted: Bool, ptt: Bool = false, phase: String = "idle", media: String = "idle", error: String? = nil) {
    self.rev = rev
    self.haConnected = haConnected
    self.muted = muted
    self.ptt = ptt
    self.phase = phase
    self.media = media
    self.error = error
  }

  /// A pipeline (or a ringing timer) is running: "Talk now" stops it.
  public var pipelineActive: Bool {
    ["wake", "listening", "thinking", "speaking", "timer"].contains(phase)
  }

  public init?(_ object: [String: Any]) {
    guard let rev = object["rev"] as? Int, let muted = object["muted"] as? Bool else { return nil }
    self.rev = rev
    self.muted = muted
    haConnected = object["ha_connected"] as? Bool ?? false
    ptt = object["ptt"] as? Bool ?? false
    phase = object["phase"] as? String ?? "idle"
    media = object["media"] as? String ?? "idle"
    if let error = object["error"] as? [String: Any] {
      self.error = error["reason"] as? String ?? "error"
    } else {
      self.error = object["error"] as? String
    }
  }
}

public enum ControlCommand: String, Sendable {
  case muteMic = "mute_mic"
  case unmuteMic = "unmute_mic"
  case startListening = "start_listening"
  case stopPipeline = "stop_pipeline"
}

public enum ControlInbound: Equatable {
  case state(Snapshot)
  case ack(id: Int, ok: Bool, reason: String?)
  /// A command from Python to the app (`set_agc`).
  case command(name: String, id: Int?, data: [String: Bool])
  case unknown
}

public enum ControlMessage {
  public static func parse(_ frame: Frame) throws -> ControlInbound {
    guard frame.type == .control else { throw ProtocolError.unexpected(frame.type) }
    let object = try frame.object()
    if let state = object["state"] as? [String: Any] {
      guard let snapshot = Snapshot(state) else { throw ProtocolError.badPayload("state without rev or muted") }
      return .state(snapshot)
    }
    if let id = object["ack"] as? Int {
      return .ack(id: id, ok: object["ok"] as? Bool ?? false, reason: object["reason"] as? String)
    }
    if let name = object["command"] as? String {
      let data = (object["data"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
      return .command(name: name, id: object["id"] as? Int, data: data)
    }
    return .unknown
  }

  public static func command(_ command: ControlCommand, id: Int, data: [String: Any]? = nil) -> Frame {
    var object: [String: Any] = ["command": command.rawValue, "id": id]
    if let data { object["data"] = data }
    return .json(.control, object)
  }

  public static func ack(_ id: Int, ok: Bool, reason: String? = nil) -> Frame {
    var object: [String: Any] = ["ack": id, "ok": ok]
    if let reason { object["reason"] = reason }
    return .json(.control, object)
  }
}

/// What "Talk now" does given the state shown.
public enum TalkAction: Equatable {
  /// Start capture if needed, then send `start_listening` with `allow_muted`.
  case start
  /// A pipeline or a timer is running: `stop_pipeline`.
  case stop
  /// No satellite connected or Home Assistant not connected.
  case unavailable(String)
}

/// The app's view of the control connection. Not thread-safe: used on one queue.
public final class ControlModel {
  public static let ackTimeout: TimeInterval = 2
  public static let talkTimeout: TimeInterval = 10

  public private(set) var connected = false
  public private(set) var snapshot: Snapshot?
  public private(set) var lvaVersion: String?
  /// A short problem shown in the menu ("not applied: pipeline_active").
  public private(set) var notice: String?
  /// The app asked for "Talk now" and LVA has not taken it over yet.
  public private(set) var pendingTalk = false

  private var nextId = 1
  private var pending: [Int: (command: ControlCommand, sent: Date)] = [:]
  private var talkSince: Date?

  public init() {}

  public func connect(lvaVersion: String?) {
    connected = true
    snapshot = nil
    self.lvaVersion = lvaVersion
    pending = [:]
    notice = nil
  }

  public func disconnect() {
    connected = false
    pending = [:]
    pendingTalk = false
    talkSince = nil
  }

  /// Returns false for a stale snapshot (lower `rev` than the last one).
  @discardableResult
  public func apply(_ new: Snapshot) -> Bool {
    if let old = snapshot, new.rev < old.rev { return false }
    snapshot = new
    if new.ptt || new.pipelineActive {
      pendingTalk = false
      talkSince = nil
    }
    return true
  }

  public func ack(id: Int, ok: Bool, reason: String?) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    if ok {
      notice = nil
    } else {
      notice = "\(entry.command.rawValue) not applied: \(reason ?? "refused")"
      if entry.command == .startListening {
        pendingTalk = false
        talkSince = nil
      }
    }
  }

  /// Registers an outgoing command and returns its frame.
  public func send(_ command: ControlCommand, data: [String: Any]? = nil, now: Date = Date()) -> Frame {
    let id = nextId
    nextId += 1
    pending[id] = (command, now)
    return ControlMessage.command(command, id: id, data: data)
  }

  /// The explicit command for the Listening toggle, from the state shown.
  public func toggleListening(now: Date = Date()) -> Frame? {
    guard connected, let snapshot else { return nil }
    return send(snapshot.muted ? .unmuteMic : .muteMic, now: now)
  }

  public func talkAction() -> TalkAction {
    guard connected, let snapshot else { return .unavailable("satellite not running") }
    if snapshot.pipelineActive { return .stop }
    guard snapshot.haConnected else { return .unavailable("Home Assistant not connected") }
    return .start
  }

  public func beginTalk(now: Date = Date()) {
    pendingTalk = true
    talkSince = now
  }

  public func cancelTalk() {
    pendingTalk = false
    talkSince = nil
  }

  /// Times out commands without an ack and a "Talk now" never taken over.
  /// Returns true when something changed.
  @discardableResult
  public func expire(now: Date = Date()) -> Bool {
    var changed = false
    for (id, entry) in pending where now.timeIntervalSince(entry.sent) >= Self.ackTimeout {
      pending.removeValue(forKey: id)
      notice = "\(entry.command.rawValue) not applied: no answer"
      changed = true
    }
    if let talkSince, now.timeIntervalSince(talkSince) >= Self.talkTimeout {
      pendingTalk = false
      self.talkSince = nil
      changed = true
    }
    return changed
  }

  public var hasPending: Bool { !pending.isEmpty || pendingTalk }
}
