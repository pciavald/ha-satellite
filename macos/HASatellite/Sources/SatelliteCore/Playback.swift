import AVFoundation
import Foundation

/// One `play:<name>` connection: PCM scheduled on a player node of the running
/// engine, paced by `buffer_ms` (the connection is only read while the node's
/// queue is below it), `END` answered by `DRAINED` once a marker after the
/// item has been rendered, `FLUSH` by `DRAINED` at once.
public final class PlaySession: @unchecked Sendable {
  /// Time a PCM waits for an engine before its item is dropped.
  public static let outputTimeout: TimeInterval = 3

  public let name: String
  public let format: PlayFormat
  public let avFormat: AVAudioFormat
  public let bufferFrames: Int
  private let send: (Frame) -> Void
  private let activity: (PlaySession, Bool) -> Void
  private let cond = NSCondition()
  private var output: PlayerOutput?
  private var queue = PlayQueue()
  private var closed = false

  /// `activity` is told when an item starts and when it is drained, from any
  /// thread; it must not call back into the session synchronously.
  public init?(name: String, format: PlayFormat, send: @escaping (Frame) -> Void, activity: @escaping (PlaySession, Bool) -> Void) {
    guard let avFormat = PlayConverter.format(format) else { return nil }
    self.name = name
    self.format = format
    self.avFormat = avFormat
    bufferFrames = format.rate * Hello.bufferMs / 1000
    self.send = send
    self.activity = activity
  }

  public var state: PlayQueue {
    cond.lock()
    defer { cond.unlock() }
    return queue
  }

  // MARK: connection thread

  public func handle(_ frame: Frame) throws {
    switch frame.type {
    case .pcm: pcm(frame.payload)
    case .end: end()
    case .flush: flush()
    default: throw ProtocolError.unexpected(frame.type)
    }
  }

  func pcm(_ payload: Data) {
    guard payload.count % format.bytesPerFrame == 0 else {
      send(.event("bad_pcm", ["msg": "PCM of \(payload.count) bytes is not whole frames"]))
      return
    }
    cond.lock()
    if queue.interrupted || closed {
      cond.unlock()
      return
    }
    let started = queue.begin()
    cond.unlock()
    if started { activity(self, true) }

    cond.lock()
    let deadline = Date().addingTimeInterval(Self.outputTimeout)
    while !closed, !queue.interrupted, output == nil || !queue.canAccept(bufferFrames: bufferFrames) {
      if output == nil, Date() >= deadline {
        let result = queue.interrupt()
        cond.unlock()
        report(result)
        return
      }
      cond.wait(until: Date().addingTimeInterval(0.25))
    }
    guard !closed, !queue.interrupted, let output, let buffer = PlayConverter.buffer(payload, format: format, avFormat: avFormat) else {
      cond.unlock()
      return
    }
    let generation = queue.generation
    let frames = Int(buffer.frameLength)
    queue.scheduled(frames)
    output.schedule(buffer, playedBack: false) { [weak self] in self?.consumed(generation, frames) }
    cond.unlock()
  }

  func end() {
    cond.lock()
    let action = queue.end(hasOutput: output != nil)
    switch action {
    case .drainedNow:
      cond.unlock()
      drained()
    case .scheduleMarker(let generation):
      // A short silence after the item: its "played back" completion means
      // everything before it has been rendered.
      if let output, let marker = PlayConverter.silence(frames: max(1, format.rate / 1000), avFormat: avFormat) {
        output.schedule(marker, playedBack: true) { [weak self] in self?.markerPlayed(generation) }
        cond.unlock()
      } else {
        queue.flush()
        cond.unlock()
        drained()
      }
    }
  }

  // Player resets and detaches run outside the lock: stopping a node fires
  // the completions of what it drops, which take the lock (and are then
  // ignored by their generation).

  func flush() {
    cond.lock()
    queue.flush()
    let output = self.output
    cond.broadcast()
    cond.unlock()
    output?.reset()
    drained()
  }

  /// The connection is gone.
  public func close() {
    cond.lock()
    closed = true
    let wasActive = queue.active
    _ = queue.interrupt()
    let output = self.output
    self.output = nil
    cond.broadcast()
    cond.unlock()
    output?.detach()
    if wasActive { activity(self, false) }
  }

  // MARK: controller

  /// A new engine provides an output (nil while none runs).
  public func bind(_ output: PlayerOutput?) {
    cond.lock()
    self.output = closed ? nil : output
    cond.broadcast()
    cond.unlock()
    if closed { output?.detach() }
  }

  /// The engine is being torn down: an item in progress is cut.
  public func unbind() {
    cond.lock()
    let result = queue.interrupt()
    let output = self.output
    self.output = nil
    cond.broadcast()
    cond.unlock()
    output?.detach()
    report(result)
  }

  // MARK: callbacks

  private func consumed(_ generation: Int, _ frames: Int) {
    cond.lock()
    queue.consumed(generation: generation, frames: frames)
    cond.broadcast()
    cond.unlock()
  }

  private func markerPlayed(_ generation: Int) {
    cond.lock()
    let due = queue.markerPlayed(generation: generation)
    cond.broadcast()
    cond.unlock()
    if due { drained() }
  }

  private func report(_ result: PlayQueue.InterruptResult) {
    switch result {
    case .none:
      break
    case .cut:
      send(.event("interrupted", ["msg": "playback cut by an audio engine change"]))
    case .drainedNow:
      send(.event("interrupted", ["msg": "playback cut by an audio engine change"]))
      drained()
    }
  }

  private func drained() {
    send(Frame(.drained))
    activity(self, false)
  }
}
