import AVFoundation
import XCTest

@testable import SatelliteCore

final class RingTests: XCTestCase {
  func push(_ ring: SampleRing, _ values: [Int16]) {
    values.withUnsafeBufferPointer { ring.push($0) }
  }

  func pop(_ ring: SampleRing, _ count: Int) -> [Int16]? {
    var out = [Int16](repeating: 0, count: count)
    let ok = out.withUnsafeMutableBufferPointer { ring.pop(into: $0.baseAddress!, count: count) }
    return ok ? out : nil
  }

  func testWrapAround() {
    let ring = SampleRing(capacity: 8)
    XCTAssertEqual(ring.capacity, 8)
    for round in 0..<10 {
      let values = (0..<5).map { Int16(round * 10 + $0) }
      push(ring, values)
      XCTAssertEqual(pop(ring, 5), values)
    }
    XCTAssertEqual(ring.available, 0)
    XCTAssertNil(pop(ring, 1))
  }

  func testCapacityRoundsUp() {
    XCTAssertEqual(SampleRing(capacity: 16000).capacity, 16384)
  }

  func testOverrunDropsBacklogToRealTime() {
    let ring = SampleRing(capacity: 8)
    push(ring, [1, 2, 3, 4, 5, 6])
    push(ring, [7, 8, 9])  // does not fit: dropped
    XCTAssertEqual(ring.available, 6)
    XCTAssertEqual(ring.takeOverrun(), 3 + 6)
    XCTAssertEqual(ring.available, 0)
    XCTAssertEqual(ring.takeOverrun(), 0)
    push(ring, [10, 11])
    XCTAssertEqual(pop(ring, 2), [10, 11])
  }

  func testDiscardUpToPosition() {
    let ring = SampleRing(capacity: 16)
    push(ring, [1, 2, 3])
    let mark = ring.position
    push(ring, [4, 5])
    XCTAssertEqual(ring.discard(upTo: mark), 3)
    XCTAssertEqual(pop(ring, 2), [4, 5])
    XCTAssertEqual(ring.discard(upTo: mark), 0)
  }
}

final class ConverterTests: XCTestCase {
  /// 1 kHz sine in buffers of 10 ms at the device rate; checks the 16 kHz
  /// output length over 100 s (no drift) and its frequency.
  func convert(rate: Double, channels: AVAudioChannelCount = 1, seconds: Int = 100) throws -> [Int16] {
    let converter = try XCTUnwrap(CaptureConverter(inputRate: rate))
    // Voice processing reports 9 discrete channels here (DiscreteInOrder).
    let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    let frames = AVAudioFrameCount(rate / 100)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    var output: [Int16] = []
    output.reserveCapacity(seconds * 16000 + 1000)
    var phase = 0.0
    for _ in 0..<(seconds * 100) {
      for i in 0..<Int(frames) {
        let v = Float(0.5 * sin(phase))
        phase += 2 * .pi * 1000 / rate
        buffer.floatChannelData![0][i] = v
        // Other channels carry garbage: only channel 0 may be used.
        for c in 1..<Int(channels) { buffer.floatChannelData![c][i] = 0.9 }
      }
      converter.process(buffer) { output.append(contentsOf: $0) }
    }
    return output
  }

  func checkSine(_ samples: [Int16], seconds: Int) {
    XCTAssertLessThanOrEqual(abs(samples.count - seconds * 16000), 64, "length \(samples.count)")
    // Zero crossings over the last 10 s: 2 per period at 1 kHz.
    let tail = samples.suffix(160_000)
    var crossings = 0
    var previous = tail.first!
    for v in tail.dropFirst() {
      if (previous < 0) != (v < 0) { crossings += 1 }
      previous = v
    }
    XCTAssertEqual(Double(crossings), 20000, accuracy: 20)
    let peak = tail.map { abs(Int($0)) }.max()!
    XCTAssertEqual(Double(peak), 0.5 * 32767, accuracy: 600)
  }

  func testResample44100() throws {
    checkSine(try convert(rate: 44100), seconds: 100)
  }

  func testResample48000() throws {
    checkSine(try convert(rate: 48000), seconds: 100)
  }

  func testTakesChannelZeroOfNine() throws {
    checkSine(try convert(rate: 44100, channels: 9, seconds: 12), seconds: 12)
  }

  func testPlayConverterS16AndF32() throws {
    let s16 = PlayFormat(sample: .s16le, rate: 48000, channels: 2)
    let avFormat = try XCTUnwrap(PlayConverter.format(s16))
    var payload = Data()
    for v: Int16 in [0, 16384, -32768, 32767] {
      withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) }
    }
    let buffer = try XCTUnwrap(PlayConverter.buffer(payload, format: s16, avFormat: avFormat))
    XCTAssertEqual(buffer.frameLength, 2)
    XCTAssertEqual(buffer.floatChannelData![0][0], 0)
    XCTAssertEqual(buffer.floatChannelData![1][0], 0.5)
    XCTAssertEqual(buffer.floatChannelData![0][1], -1)
    XCTAssertEqual(buffer.floatChannelData![1][1], 32767.0 / 32768, accuracy: 1e-6)

    let f32 = PlayFormat(sample: .f32le, rate: 24000, channels: 1)
    var floats = Data()
    for v: Float in [0.25, -0.75] {
      withUnsafeBytes(of: v.bitPattern.littleEndian) { floats.append(contentsOf: $0) }
    }
    let mono = try XCTUnwrap(PlayConverter.buffer(floats, format: f32, avFormat: XCTUnwrap(PlayConverter.format(f32))))
    XCTAssertEqual(mono.floatChannelData![0][0], 0.25)
    XCTAssertEqual(mono.floatChannelData![0][1], -0.75)
  }
}

final class RulesTests: XCTestCase {
  func inputs(mic: Bool = true, control: Bool = true, muted: Bool = false, ptt: Bool = false, talk: Bool = false,
              authorized: Bool = true, play: Bool = false) -> AudioInputs {
    var i = AudioInputs()
    i.micClient = mic
    i.controlConnected = control
    i.muted = muted
    i.ptt = ptt
    i.pendingTalk = talk
    i.micAuthorized = authorized
    i.playActive = play
    return i
  }

  func testCaptureWanted() {
    XCTAssertTrue(inputs().captureWanted)
    XCTAssertTrue(inputs(control: false, muted: true).captureWanted, "no control role: safe default")
    XCTAssertFalse(inputs(muted: true).captureWanted)
    XCTAssertTrue(inputs(muted: true, ptt: true).captureWanted)
    XCTAssertTrue(inputs(muted: true, talk: true).captureWanted)
    XCTAssertFalse(inputs(mic: false).captureWanted, "nobody reads")
    XCTAssertFalse(inputs(mic: false, control: false).captureWanted)
    XCTAssertFalse(inputs(authorized: false).voiceWanted)
    XCTAssertTrue(inputs(authorized: false).clientPaused)
  }

  func testDecisions() {
    XCTAssertEqual(EngineRules.decide(inputs(), current: nil, idleSince: nil, now: 0), .build(.voice))
    XCTAssertEqual(EngineRules.decide(inputs(), current: .voice, idleSince: nil, now: 0), .keep)
    XCTAssertEqual(EngineRules.decide(inputs(), current: .outputOnly, idleSince: nil, now: 0), .build(.voice))
    // Muted with an announcement: output only, never the mic.
    XCTAssertEqual(EngineRules.decide(inputs(muted: true, play: true), current: nil, idleSince: nil, now: 0), .build(.outputOnly))
    XCTAssertEqual(EngineRules.decide(inputs(authorized: false, play: true), current: nil, idleSince: nil, now: 0), .build(.outputOnly))
    // Muted during VP playback: the item finishes on the VP engine.
    XCTAssertEqual(EngineRules.decide(inputs(muted: true, play: true), current: .voice, idleSince: nil, now: 0), .keep)
    // Linger, then stop.
    XCTAssertEqual(EngineRules.decide(inputs(muted: true), current: .voice, idleSince: 10, now: 12), .linger(until: 15))
    XCTAssertEqual(EngineRules.decide(inputs(muted: true), current: .voice, idleSince: 10, now: 15), .stop)
    XCTAssertEqual(EngineRules.decide(inputs(muted: true), current: nil, idleSince: 10, now: 15), .keep)
    var asleep = inputs()
    asleep.sleeping = true
    XCTAssertEqual(EngineRules.decide(asleep, current: .voice, idleSince: nil, now: 0), .stop)
  }

  func testRetryDelays() {
    XCTAssertEqual((1...7).map(EngineRules.retryDelay(failures:)), [1, 2, 5, 10, 30, 60, 60])
  }

  func testPlayQueueEndAndStaleCompletions() {
    var q = PlayQueue()
    XCTAssertTrue(q.begin())
    XCTAssertFalse(q.begin())
    q.scheduled(4800)
    XCTAssertFalse(q.canAccept(bufferFrames: 4800))
    let gen = q.generation
    q.consumed(generation: gen, frames: 4800)
    XCTAssertTrue(q.canAccept(bufferFrames: 4800))
    guard case .scheduleMarker(let markerGen) = q.end(hasOutput: true) else { return XCTFail() }
    XCTAssertFalse(q.markerPlayed(generation: markerGen - 1))
    XCTAssertTrue(q.markerPlayed(generation: markerGen))
    XCTAssertFalse(q.active)
    XCTAssertFalse(q.markerPlayed(generation: markerGen), "one DRAINED per END")
  }

  func testPlayQueueFlushIgnoresLateCallbacks() {
    var q = PlayQueue()
    _ = q.begin()
    q.scheduled(100)
    let gen = q.generation
    q.flush()
    q.consumed(generation: gen, frames: 100)
    XCTAssertEqual(q.queued, 0)
    XCTAssertFalse(q.active)
    XCTAssertEqual(q.end(hasOutput: true), .drainedNow, "END without an item")
  }

  func testPlayQueueInterrupt() {
    var q = PlayQueue()
    XCTAssertEqual(q.interrupt(), .none)
    _ = q.begin()
    q.scheduled(100)
    XCTAssertEqual(q.interrupt(), .cut)
    XCTAssertTrue(q.interrupted)
    XCTAssertEqual(q.interrupt(), .none)
    XCTAssertEqual(q.end(hasOutput: true), .drainedNow)
    XCTAssertFalse(q.active)

    _ = q.begin()
    guard case .scheduleMarker = q.end(hasOutput: true) else { return XCTFail() }
    XCTAssertEqual(q.interrupt(), .drainedNow, "END already received")
  }
}
