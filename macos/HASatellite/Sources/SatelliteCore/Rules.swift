import Foundation

/// Everything that decides whether the mic is captured and which engine runs
/// (plans/swift-helper.md section 9, plans/audio.md 6.2).
public struct AudioInputs: Equatable, Sendable {
  public var micClient = false
  public var controlConnected = false
  public var muted = false
  public var ptt = false
  public var pendingTalk = false
  public var micAuthorized = true
  public var sleeping = false
  public var noInputDevice = false
  public var playActive = false

  public init() {}

  /// A `mic` client reads, and LVA listens (or no control role, the safe
  /// default, or a push-to-talk is in progress).
  public var captureWanted: Bool {
    micClient && (!controlConnected || !muted || ptt || pendingTalk)
  }

  /// Python is told `capture_paused`: nothing to capture, or not allowed to.
  public var clientPaused: Bool {
    !captureWanted || !micAuthorized
  }

  /// The voice-processing engine with capture is needed.
  public var voiceWanted: Bool {
    captureWanted && micAuthorized && !sleeping && !noInputDevice
  }
}

public enum EngineDecision: Equatable, Sendable {
  case keep
  case build(EngineKind)
  case stop
  /// Keep the engine until this time, then decide again.
  case linger(until: TimeInterval)
}

public enum EngineRules {
  /// Seconds an idle engine is kept after the last activity, so the mute
  /// chime and announcements while muted do not cycle the engine per sound.
  public static let linger: TimeInterval = 5

  /// `idleSince` is when capture stopped being wanted and nothing played.
  public static func decide(_ inputs: AudioInputs, current: EngineKind?, idleSince: TimeInterval?, now: TimeInterval) -> EngineDecision {
    if inputs.sleeping {
      return current == nil ? .keep : .stop
    }
    if inputs.voiceWanted {
      return current == .voice ? .keep : .build(.voice)
    }
    if inputs.playActive {
      return current == nil ? .build(.outputOnly) : .keep
    }
    guard current != nil else { return .keep }
    let since = idleSince ?? now
    return now - since >= linger ? .stop : .linger(until: since + linger)
  }

  /// Delay before retrying a failed engine start: 1, 2, 5, 10, 30 s, then
  /// every 60 s. The app never exits on audio failures.
  public static func retryDelay(failures: Int) -> TimeInterval {
    let delays: [TimeInterval] = [1, 2, 5, 10, 30]
    return failures >= 1 && failures <= delays.count ? delays[failures - 1] : 60
  }
}

/// Queue accounting of one `play:<name>` connection. Pure; the caller holds
/// the lock. Completions carry the generation they were scheduled in, so a
/// late callback after `FLUSH`, `END` or an engine rebuild is ignored.
public struct PlayQueue: Equatable, Sendable {
  public enum EndAction: Equatable, Sendable {
    case drainedNow
    case scheduleMarker(generation: Int)
  }

  public private(set) var generation = 0
  /// Frames scheduled on the node and not consumed yet.
  public private(set) var queued = 0
  /// An item started (PCM received) and has not been drained.
  public private(set) var active = false
  /// The rest of the item is dropped; `DRAINED` is sent at its `END`.
  public private(set) var interrupted = false
  /// The `END` marker is scheduled.
  public private(set) var ending = false

  public init() {}

  /// Called for every PCM; returns true when this starts an item.
  public mutating func begin() -> Bool {
    if active { return false }
    active = true
    return true
  }

  public mutating func scheduled(_ frames: Int) {
    queued += frames
  }

  public mutating func consumed(generation: Int, frames: Int) {
    guard generation == self.generation else { return }
    queued = max(0, queued - frames)
  }

  public func canAccept(bufferFrames: Int) -> Bool {
    queued < bufferFrames
  }

  /// `END`: drained at once when nothing is queued for this item.
  public mutating func end(hasOutput: Bool) -> EndAction {
    if !active || interrupted || !hasOutput {
      finish()
      return .drainedNow
    }
    ending = true
    return .scheduleMarker(generation: generation)
  }

  /// The `END` marker was rendered; returns true when `DRAINED` is due.
  public mutating func markerPlayed(generation: Int) -> Bool {
    guard generation == self.generation, ending else { return false }
    finish()
    return true
  }

  /// `FLUSH`: always answered with `DRAINED`.
  public mutating func flush() {
    finish()
  }

  public enum InterruptResult: Equatable, Sendable {
    case none
    /// The item was cut: the rest is dropped, `DRAINED` follows its `END`.
    case cut
    /// The item was cut after its `END`: `DRAINED` is due now.
    case drainedNow
  }

  /// The engine went away under the item (rebuild, kind switch, no output in
  /// time).
  public mutating func interrupt() -> InterruptResult {
    generation += 1
    queued = 0
    guard active, !interrupted else { return .none }
    if ending {
      finish()
      return .drainedNow
    }
    interrupted = true
    return .cut
  }

  private mutating func finish() {
    generation += 1
    queued = 0
    active = false
    interrupted = false
    ending = false
  }
}
