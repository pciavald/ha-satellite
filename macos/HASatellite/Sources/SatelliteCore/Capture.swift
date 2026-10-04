import AVFoundation

/// Converts tap buffers to 16 kHz mono s16: channel 0 only (voice processing
/// reports several identical channels), one persistent `AVAudioConverter` per
/// engine build so the resampler state carries over and nothing drifts.
public final class CaptureConverter {
  public static let outputRate: Double = 16000

  public let inputRate: Double
  private let monoFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private var mono: AVAudioPCMBuffer
  private var output: AVAudioPCMBuffer
  private var scratch: [Int16]

  public init?(inputRate: Double) {
    guard inputRate > 0,
          let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
          let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: monoFormat, to: outputFormat),
          let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 4096),
          let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
    else { return nil }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    self.inputRate = inputRate
    self.monoFormat = monoFormat
    self.outputFormat = outputFormat
    self.converter = converter
    self.mono = mono
    self.output = output
    scratch = [Int16](repeating: 0, count: 4096)
  }

  /// Converts channel 0 of `buffer` and hands the s16 samples to `sink`.
  public func process(_ buffer: AVAudioPCMBuffer, sink: (UnsafeBufferPointer<Int16>) -> Void) {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    let frames = buffer.frameLength
    if mono.frameCapacity < frames {
      guard let bigger = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else { return }
      mono = bigger
    }
    let needed = AVAudioFrameCount((Double(frames) * Self.outputRate / inputRate).rounded(.up)) + 64
    if output.frameCapacity < needed {
      guard let bigger = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: needed) else { return }
      output = bigger
    }
    if scratch.count < Int(needed) {
      scratch = [Int16](repeating: 0, count: Int(needed))
    }
    let stride = buffer.stride
    let source = channels[0]
    let target = mono.floatChannelData![0]
    if stride == 1 {
      target.update(from: source, count: Int(frames))
    } else {
      for i in 0..<Int(frames) { target[i] = source[i * stride] }
    }
    mono.frameLength = frames

    var given = false
    let input = mono
    output.frameLength = 0
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if given {
        outStatus.pointee = .noDataNow
        return nil
      }
      given = true
      outStatus.pointee = .haveData
      return input
    }
    guard status != .error, output.frameLength > 0 else { return }
    let count = Int(output.frameLength)
    let samples = output.floatChannelData![0]
    scratch.withUnsafeMutableBufferPointer { out in
      for i in 0..<count {
        let v = max(-1, min(1, samples[i])) * 32767
        out[i] = Int16(v.rounded())
      }
      sink(UnsafeBufferPointer(start: out.baseAddress, count: count))
    }
  }
}

/// Converts PCM received on a `play:<name>` connection into float32
/// non-interleaved buffers for the player node.
public enum PlayConverter {
  public static func format(_ format: PlayFormat) -> AVAudioFormat? {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(format.rate), channels: AVAudioChannelCount(format.channels), interleaved: false)
  }

  public static func buffer(_ payload: Data, format: PlayFormat, avFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frames = payload.count / format.bytesPerFrame
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let out = buffer.floatChannelData!
    payload.withUnsafeBytes { raw in
      for frame in 0..<frames {
        for channel in 0..<format.channels {
          let offset = (frame * format.channels + channel) * format.sample.bytes
          switch format.sample {
          case .s16le:
            let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
            out[channel][frame] = Float(v) / 32768
          case .f32le:
            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            out[channel][frame] = Float(bitPattern: bits)
          }
        }
      }
    }
    return buffer
  }

  public static func silence(frames: Int, avFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(avFormat.channelCount) {
      buffer.floatChannelData![channel].update(repeating: 0, count: frames)
    }
    return buffer
  }
}
