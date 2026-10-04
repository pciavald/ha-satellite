import AVFoundation
import Foundation
import SatelliteCore

enum CLI {
  static func status() {
    let paths = Paths.standard()
    var object: [String: Any] = [
      "version": AppInfo.fullVersion,
      "bundle_id": Bundle.main.bundleIdentifier ?? "none",
      "login_item": LoginItem.status.rawValue,
      "microphone": MicPermission.current.rawValue,
      "config": paths.config.path,
      "logs": paths.logs.path,
    ]
    do {
      if let config = try SatelliteConfig.load(paths.config) {
        object["configured"] = true
        object["socket"] = config.socket ?? paths.socket.path
        object["python"] = config.python
      } else {
        object["configured"] = false
        object["socket"] = paths.socket.path
      }
    } catch {
      object["configured"] = false
      object["config_error"] = "\(error)"
    }
    if let text = try? String(contentsOf: paths.pidFile, encoding: .utf8) {
      let parts = text.split(whereSeparator: \.isWhitespace)
      if parts.count == 2, let pid = Int32(parts[0]), let start = UInt64(parts[1]) {
        object["satellite_pid"] = pid
        object["satellite_running"] = ProcessInfoReader.startTime(pid) == start
      }
    }
    let siri = SiriStatus.current
    object["siri"] = siri.siriEnabled.map { $0 ? "on" : "off" } ?? "unknown"
    object["dictation"] = siri.dictationEnabled.map { $0 ? "on" : "off" } ?? "unknown"
    if let keyboard = Keyboard.builtIn() {
      object["keyboard"] = String(format: "0x%x/0x%x", keyboard.vendor, keyboard.product)
    }
    if let input = Devices.defaultInput() { object["input_device"] = "\(input.name) \(Int(input.rate)) Hz" }
    if let output = Devices.defaultOutput() { object["output_device"] = "\(output.name) \(Int(output.rate)) Hz" }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
  }

  static func unregister() -> Int32 {
    var failed = false
    do {
      try LoginItem.set(false)
    } catch {
      print("login item: \(error.localizedDescription)")
      failed = LoginItem.status == .enabled
    }
    if let error = KeyRemapper().apply(enabled: false) {
      print("Dictation key remap: \(error)")
    }
    print("login item: \(LoginItem.status.rawValue)")
    return failed ? 1 : 0
  }

  /// Captures 1.5 s through voice processing (16 kHz frames and level), then
  /// plays a 0.3 s tone at -30 dBFS through the same engine and waits for it
  /// to be rendered. Needs the microphone permission.
  static func selftest(play: Bool) -> Int32 {
    print("microphone: \(MicPermission.current.rawValue)")
    print("input: \(Devices.defaultInput().map { "\($0.name), \(Int($0.rate)) Hz" } ?? "none")")
    print("output: \(Devices.defaultOutput().map { "\($0.name), \(Int($0.rate)) Hz" } ?? "none")")
    guard MicPermission.current == .authorized else {
      print("FAIL: the microphone is not authorized")
      return 1
    }
    let lock = NSLock()
    var buffers = 0
    var channels: AVAudioChannelCount = 0
    var samples = 0
    var energy = 0.0
    var converter: CaptureConverter?
    let engine: AudioEngine
    do {
      engine = try AVEngineFactory().make(kind: .voice, agc: false, capture: { buffer in
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        channels = buffer.format.channelCount
        converter?.process(buffer) { out in
          samples += out.count
          for v in out { energy += Double(v) * Double(v) }
        }
      }, configurationChanged: {})
      converter = engine.inputRate.flatMap { CaptureConverter(inputRate: $0) }
      try engine.start()
    } catch {
      print("FAIL: voice-processing engine: \(error)")
      return 1
    }
    Thread.sleep(forTimeInterval: 1.5)
    lock.lock()
    let rms = samples > 0 ? (energy / Double(samples)).squareRoot() / 32768 : 0
    print(String(format: "capture: %d tap buffers, %d channels at %d Hz, %d samples at 16 kHz (%.2f s), level %.1f dBFS",
                 buffers, channels, Int(engine.inputRate ?? 0), samples, Double(samples) / 16000, 20 * log10(max(rms, 1e-9))))
    lock.unlock()
    var result: Int32 = samples > 16000 ? 0 : 1
    if result != 0 { print("FAIL: too few samples captured") }

    if play {
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
      let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 14400)!
      tone.frameLength = 14400
      let amplitude = Float(pow(10, -30.0 / 20))
      for i in 0..<14400 {
        tone.floatChannelData![0][i] = amplitude * sin(2 * .pi * 880 * Float(i) / 48000)
      }
      let done = DispatchSemaphore(value: 0)
      let start = Date()
      if let player = engine.makePlayer(format: format) {
        player.schedule(tone, playedBack: true) { done.signal() }
        if done.wait(timeout: .now() + 3) == .success {
          print(String(format: "playback: 0.30 s tone rendered through voice processing in %.2f s", Date().timeIntervalSince(start)))
        } else {
          print("FAIL: playback did not complete")
          result = 1
        }
        player.detach()
      } else {
        print("FAIL: no player node")
        result = 1
      }
    }
    engine.stop()
    print(result == 0 ? "OK" : "FAILED")
    return result
  }

  /// The measurement that chose voice processing: the microphone level in a
  /// quiet room, then while 3 s of white noise at -20 dBFS play through the
  /// same engine, once without and once with voice processing. The echo
  /// removed is the difference of the levels while playing; fails below 15 dB.
  static func echoTest() -> Int32 {
    print("microphone: \(MicPermission.current.rawValue)")
    print("output: \(Devices.defaultOutput().map { "\($0.name), \(Int($0.rate)) Hz" } ?? "none")")
    guard MicPermission.current == .authorized else {
      print("FAIL: the microphone is not authorized")
      return 1
    }
    print("keep the room quiet; the noise plays twice")
    guard let raw = EchoRun.measure(voiceProcessing: false), let voice = EchoRun.measure(voiceProcessing: true) else {
      print("FAILED")
      return 1
    }
    for (label, run) in [("no voice processing", raw), ("voice processing", voice)] {
      print(String(format: "%@: ambient %.1f dBFS, playing %.1f dBFS, echo above the floor %+.1f dB", label, run.ambient, run.playing, run.playing - run.ambient))
    }
    let removed = raw.playing - voice.playing
    print(String(format: "echo removed by voice processing: %.1f dB", removed))
    if raw.playing - raw.ambient < 10 {
      print("FAIL: the noise was barely heard without voice processing: turn the output volume up and run again")
      return 1
    }
    guard removed >= 15 else {
      print("FAIL: less than 15 dB removed")
      return 1
    }
    print("OK")
    return 0
  }
}

/// One mode of the echo test: levels of channel 0 of the captured signal.
private final class EchoRun: @unchecked Sendable {
  private let lock = NSLock()
  private var energy = 0.0
  private var count = 0

  var ambient = 0.0
  var playing = 0.0

  static func measure(voiceProcessing: Bool) -> EchoRun? {
    let run = EchoRun()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
      if voiceProcessing {
        // The app's settings (Engine.swift).
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        input.isVoiceProcessingAGCEnabled = false
      }
      input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in run.add(buffer) }
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      try engine.start()
      defer {
        player.stop()
        input.removeTap(onBus: 0)
        engine.stop()
      }
      Thread.sleep(forTimeInterval: 1)
      run.ambient = run.window(1.5)
      player.scheduleBuffer(noise(format: format, seconds: 3, dBFS: -20))
      player.play()
      Thread.sleep(forTimeInterval: 0.3)
      run.playing = run.window(2.5)
      return run
    } catch {
      print("FAIL: \(voiceProcessing ? "voice-processing" : "plain") engine: \(error)")
      return nil
    }
  }

  private func add(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData?[0] else { return }
    var sum = 0.0
    for i in 0..<Int(buffer.frameLength) { sum += Double(data[i]) * Double(data[i]) }
    lock.lock()
    energy += sum
    count += Int(buffer.frameLength)
    lock.unlock()
  }

  /// Level in dBFS over the next `seconds`.
  private func window(_ seconds: TimeInterval) -> Double {
    lock.lock()
    energy = 0
    count = 0
    lock.unlock()
    Thread.sleep(forTimeInterval: seconds)
    lock.lock()
    defer { lock.unlock() }
    let rms = count > 0 ? (energy / Double(count)).squareRoot() : 0
    return 20 * log10(max(rms, 1e-9))
  }

  /// Uniform white noise with the given RMS level.
  private static func noise(format: AVAudioFormat, seconds: Double, dBFS: Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let amplitude = Float(pow(10, dBFS / 20) * 3.0.squareRoot())
    for i in 0..<Int(frames) {
      buffer.floatChannelData![0][i] = Float.random(in: -amplitude...amplitude)
    }
    return buffer
  }
}
