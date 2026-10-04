import AVFoundation
import CoreAudio

public enum EngineKind: String, Sendable {
  /// Input and output with voice processing: capture plus echo reference.
  case voice
  /// Output only, no voice processing: the input node is never touched.
  case outputOnly = "output-only"
}

public enum EngineError: Error, Equatable {
  case noInputDevice
  case badFormat(String)
  case startFailed(String)
}

/// One output of a `play:<name>` connection: a player node on the engine.
public protocol PlayerOutput: AnyObject {
  /// `playedBack` asks for the completion once the data has been rendered
  /// (the `END` marker), otherwise once it has been consumed.
  func schedule(_ buffer: AVAudioPCMBuffer, playedBack: Bool, completion: @escaping @Sendable () -> Void)
  /// Drops everything scheduled and keeps the node ready to play.
  func reset()
  func detach()
}

public protocol AudioEngine: AnyObject {
  var kind: EngineKind { get }
  /// Device sample rate of the captured signal (voice engines).
  var inputRate: Double? { get }
  func start() throws
  func stop()
  func setAGC(_ on: Bool)
  func makePlayer(format: AVAudioFormat) -> PlayerOutput?
}

public protocol EngineFactory: AnyObject {
  /// `capture` receives tap buffers of a voice engine; `configurationChanged`
  /// is called from any thread when the engine's configuration changes.
  func make(kind: EngineKind, agc: Bool, capture: @escaping (AVAudioPCMBuffer) -> Void, configurationChanged: @escaping () -> Void) throws -> AudioEngine
}

// MARK: - AVAudioEngine implementation

public final class AVEngineFactory: EngineFactory {
  public init() {}

  public func make(kind: EngineKind, agc: Bool, capture: @escaping (AVAudioPCMBuffer) -> Void, configurationChanged: @escaping () -> Void) throws -> AudioEngine {
    try AVEngine(kind: kind, agc: agc, capture: capture, configurationChanged: configurationChanged)
  }
}

final class AVEngine: AudioEngine {
  let kind: EngineKind
  private(set) var inputRate: Double?
  private let engine = AVAudioEngine()
  private var observer: NSObjectProtocol?

  init(kind: EngineKind, agc: Bool, capture: @escaping (AVAudioPCMBuffer) -> Void, configurationChanged: @escaping () -> Void) throws {
    self.kind = kind
    if kind == .voice {
      guard Devices.defaultInput() != nil else { throw EngineError.noInputDevice }
      let input = engine.inputNode
      // Enabled before connecting anything and before start, never toggled on
      // a running engine; formats are read only afterwards.
      try input.setVoiceProcessingEnabled(true)
      input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
      input.isVoiceProcessingAGCEnabled = agc
      let format = input.outputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else {
        throw EngineError.badFormat("input \(format)")
      }
      inputRate = format.sampleRate
      input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in capture(buffer) }
    }
    _ = engine.mainMixerNode
    engine.prepare()
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
      configurationChanged()
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func start() throws {
    do {
      try engine.start()
    } catch {
      throw EngineError.startFailed("\(error)")
    }
  }

  func stop() {
    if kind == .voice { engine.inputNode.removeTap(onBus: 0) }
    engine.stop()
  }

  func setAGC(_ on: Bool) {
    if kind == .voice { engine.inputNode.isVoiceProcessingAGCEnabled = on }
  }

  func makePlayer(format: AVAudioFormat) -> PlayerOutput? {
    let node = AVAudioPlayerNode()
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    if engine.isRunning { node.play() }
    return NodePlayer(engine: engine, node: node)
  }
}

final class NodePlayer: PlayerOutput {
  private weak var engine: AVAudioEngine?
  private let node: AVAudioPlayerNode

  init(engine: AVAudioEngine, node: AVAudioPlayerNode) {
    self.engine = engine
    self.node = node
  }

  func schedule(_ buffer: AVAudioPCMBuffer, playedBack: Bool, completion: @escaping @Sendable () -> Void) {
    if !node.isPlaying, engine?.isRunning == true { node.play() }
    node.scheduleBuffer(buffer, completionCallbackType: playedBack ? .dataPlayedBack : .dataConsumed) { _ in completion() }
  }

  func reset() {
    node.stop()
    if engine?.isRunning == true { node.play() }
  }

  func detach() {
    node.stop()
    engine?.detach(node)
  }
}

// MARK: - Devices

public struct DeviceInfo: Equatable, Sendable {
  public var id: AudioObjectID
  public var name: String
  public var rate: Double
}

public enum Devices {
  public static func defaultInput() -> DeviceInfo? { info(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) }
  public static func defaultOutput() -> DeviceInfo? { info(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) }

  static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
  }

  static func info(_ id: AudioObjectID) -> DeviceInfo? {
    guard id != kAudioObjectUnknown else { return nil }
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let nameStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
    address.mSelector = kAudioDevicePropertyNominalSampleRate
    var rate: Float64 = 0
    size = UInt32(MemoryLayout<Float64>.size)
    _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
    let text = nameStatus == noErr ? (name?.takeRetainedValue() as String?) ?? "unknown" : "unknown"
    return DeviceInfo(id: id, name: text, rate: rate)
  }

  /// Calls `changed` on `queue` when the default input or output device
  /// changes. Returns a token that removes the listeners when released.
  public static func watch(queue: DispatchQueue, changed: @escaping () -> Void) -> AnyObject {
    DeviceWatch(queue: queue, changed: changed)
  }
}

private final class DeviceWatch {
  private let queue: DispatchQueue
  private let block: AudioObjectPropertyListenerBlock
  private var addresses = [
    AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
    AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
  ]

  init(queue: DispatchQueue, changed: @escaping () -> Void) {
    self.queue = queue
    block = { _, _ in changed() }
    for i in addresses.indices {
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], queue, block)
    }
  }

  deinit {
    for i in addresses.indices {
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], queue, block)
    }
  }
}
