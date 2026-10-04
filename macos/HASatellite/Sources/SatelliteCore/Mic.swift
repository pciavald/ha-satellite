import Foundation
import Synchronization

/// Flags shared between the tap thread, the controller queue and the writer.
public final class CaptureFlags: @unchecked Sendable {
  /// Tap buffers go into the ring.
  public let forwarding = Atomic<Bool>(false)
  /// The next tap buffer is reported to the controller (capture start).
  public let armed = Atomic<Bool>(false)
  /// The writer sends silence with advancing indices (engine starting or
  /// being rebuilt, no input device).
  public let fillSilence = Atomic<Bool>(false)
  /// Uptime in nanoseconds of the last tap buffer, for the watchdog.
  public let lastBuffer = Atomic<UInt64>(0)

  public init() {}
}

/// Sends a `mic` connection's frames from one writer thread: PCM from the
/// ring, silence when asked, and events in order with the samples around
/// them (`capture_paused` follows the samples captured before it,
/// `capture_resumed` precedes the ones after it).
public final class MicLink: @unchecked Sendable {
  public static let frameSamples = 160
  public static let maxFramesPerMessage = 10

  public enum EventKind: Sendable {
    case plain
    case paused
    case resumed
  }

  public let connection: Connection
  private let ring: SampleRing
  private let flags: CaptureFlags
  private let lock = NSLock()
  private var events: [(frame: Frame, kind: EventKind, position: Int)] = []
  private let started = DispatchTime.now().uptimeNanoseconds
  /// Index of the next sample sent; starts at 0 when the client connects.
  public private(set) var index: UInt64 = 0
  private var paused: Bool
  private var silenceStart: (time: UInt64, index: UInt64)?

  public init(connection: Connection, ring: SampleRing, flags: CaptureFlags, paused: Bool) {
    self.connection = connection
    self.ring = ring
    self.flags = flags
    self.paused = paused
    ring.discard()
  }

  public func enqueue(_ frame: Frame, kind: EventKind = .plain) {
    lock.lock()
    events.append((frame, kind, ring.position))
    lock.unlock()
  }

  /// Writer loop; returns when the connection closes.
  public func run() {
    var buffer = [Int16](repeating: 0, count: Self.frameSamples * Self.maxFramesPerMessage)
    while !connection.isClosed {
      if !step(&buffer) {
        // Fewer wakeups while paused (wake word off, Mac allowed to sleep).
        usleep(paused ? 50_000 : 5_000)
      }
    }
  }

  /// One iteration; returns true when something was sent.
  @discardableResult
  public func step(_ buffer: inout [Int16]) -> Bool {
    lock.lock()
    let pending = events
    events.removeAll()
    lock.unlock()
    var sent = false
    for event in pending {
      switch event.kind {
      case .paused:
        sendUpTo(event.position, &buffer)
        ring.discard(upTo: event.position)
        paused = true
        silenceStart = nil
      case .resumed:
        ring.discard(upTo: event.position)
        index = max(index, wallIndex())
        paused = false
        silenceStart = nil
      case .plain:
        break
      }
      connection.send(event.frame)
      sent = true
    }
    if paused {
      ring.discard()
      _ = ring.takeOverrun()
      return sent
    }
    let lost = ring.takeOverrun()
    if lost > 0 {
      index += UInt64(lost)
      connection.send(.event("overrun", ["dropped": lost]))
      sent = true
    }
    if sendAvailable(&buffer, limit: nil) {
      silenceStart = nil
      return true
    }
    if flags.fillSilence.load(ordering: .relaxed), !flags.forwarding.load(ordering: .relaxed) {
      return sendSilence(&buffer) || sent
    }
    silenceStart = nil
    return sent
  }

  private func wallIndex() -> UInt64 {
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    let samples = elapsed / 1_000_000_000 * 16000 + (elapsed % 1_000_000_000) * 16000 / 1_000_000_000
    return samples / UInt64(Self.frameSamples) * UInt64(Self.frameSamples)
  }

  /// Sends whole frames from the ring, up to `limit` (a ring position).
  private func sendAvailable(_ buffer: inout [Int16], limit: Int?) -> Bool {
    var frames = ring.available / Self.frameSamples
    if let limit {
      frames = min(frames, max(0, limit - (ring.position - ring.available)) / Self.frameSamples)
    }
    frames = min(frames, Self.maxFramesPerMessage)
    guard frames > 0 else { return false }
    let count = frames * Self.frameSamples
    let popped = buffer.withUnsafeMutableBufferPointer { ring.pop(into: $0.baseAddress!, count: count) }
    guard popped else { return false }
    let frame = buffer.withUnsafeBufferPointer { Wire.micPCM(index: index, samples: UnsafeBufferPointer(rebasing: $0[0..<count])) }
    index += UInt64(count)
    connection.send(frame)
    return true
  }

  private func sendUpTo(_ position: Int, _ buffer: inout [Int16]) {
    while sendAvailable(&buffer, limit: position) {}
  }

  /// Silence paced by the clock, so the index keeps advancing in real time.
  private func sendSilence(_ buffer: inout [Int16]) -> Bool {
    let now = DispatchTime.now().uptimeNanoseconds
    guard let start = silenceStart else {
      silenceStart = (now, index)
      return false
    }
    let due = start.index + (now - start.time) * 16000 / 1_000_000_000
    guard due >= index + UInt64(Self.frameSamples) else { return false }
    let frames = min(Int((due - index) / UInt64(Self.frameSamples)), Self.maxFramesPerMessage)
    let count = frames * Self.frameSamples
    for i in 0..<count { buffer[i] = 0 }
    let frame = buffer.withUnsafeBufferPointer { Wire.micPCM(index: index, samples: UnsafeBufferPointer(rebasing: $0[0..<count])) }
    index += UInt64(count)
    connection.send(frame)
    return true
  }
}
