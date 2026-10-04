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
}
