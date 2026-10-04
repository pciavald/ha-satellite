import AVFoundation
import Foundation

/// Time source and timers of the controller's queue; replaced in tests.
public protocol Scheduler: AnyObject {
  var now: TimeInterval { get }
  /// Runs `block` on the controller's queue after `delay` seconds.
  func after(_ delay: TimeInterval, _ block: @escaping () -> Void)
}

public final class QueueScheduler: Scheduler {
  private let queue: DispatchQueue

  public init(queue: DispatchQueue) {
    self.queue = queue
  }

  public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  public func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
    queue.asyncAfter(deadline: .now() + delay, execute: block)
  }
}

public struct AudioStatus: Equatable, Sendable {
  public var engine: EngineKind?
  public var capturing = false
  public var failure: String?
  public var noInputDevice = false
  public var micAuthorized = true
  public var agc = false
  public var inputDevice: String?
  public var outputDevice: String?

  public init() {}
}

/// Owns the engine and decides, from `AudioInputs`, which one runs and whether
/// the mic is captured. Every method runs on one serial queue (the hub's);
/// tap buffers reach it through `CaptureFlags` and `firstBuffer()`.
public final class AudioController {
  public static let watchdog: TimeInterval = 2
  public static let rebuildDebounce: TimeInterval = 1.5

  public private(set) var inputs = AudioInputs()
  public private(set) var status = AudioStatus()
  public let ring = SampleRing(capacity: 16000)
  public let flags = CaptureFlags()

  private let factory: EngineFactory
  private let scheduler: Scheduler
  /// Hops a block onto the controller's queue from any thread.
  private let hop: (@escaping () -> Void) -> Void
  private var engine: AudioEngine?
  private var converter: CaptureConverter?
  private var idleSince: TimeInterval?
  private var failures = 0
  private var retryAt: TimeInterval?
  private var lingerToken = 0
  private var rebuildToken = 0
  private var watchdogRunning = false
  private var sessions: [ObjectIdentifier: PlaySession] = [:]
  private var activeSessions = Set<ObjectIdentifier>()
  private var mic: MicLink?
  private var clientPaused = false
  private var permissionReported = false

  /// Engine and capture changes, for the menu and the App Nap activity.
  public var onStatus: ((AudioStatus) -> Void)?
  /// Engine (re)starts, for logs.
  public var log: ((String) -> Void)?

  public init(factory: EngineFactory, scheduler: Scheduler, hop: @escaping (@escaping () -> Void) -> Void) {
    self.factory = factory
    self.scheduler = scheduler
    self.hop = hop
  }

  public var engineKind: EngineKind? { engine?.kind }

  // MARK: inputs

  public func update(_ change: (inout AudioInputs) -> Void) {
    var next = inputs
    change(&next)
    guard next != inputs else { return }
    let wasBusy = inputs.voiceWanted || inputs.playActive
    inputs = next
    let busy = inputs.voiceWanted || inputs.playActive
    if wasBusy, !busy { idleSince = scheduler.now }
    if busy { idleSince = nil }
    evaluate()
  }

  public func setAGC(_ on: Bool) {
    guard status.agc != on else { return }
    status.agc = on
    engine?.setAGC(on)
    publish()
  }

  // MARK: mic client

  public func attachMic(_ link: MicLink) {
    mic?.connection.close()
    mic = link
    clientPaused = false
    permissionReported = false
    update { $0.micClient = true }
    syncCapture()
  }

  public func detachMic(_ link: MicLink) {
    guard mic === link else { return }
    mic = nil
    update { $0.micClient = false }
  }

  public func micEvent(_ frame: Frame) {
    mic?.enqueue(frame)
  }

  // MARK: play sessions

  public func attachPlay(_ session: PlaySession) {
    sessions[ObjectIdentifier(session)] = session
    if let engine { session.bind(engine.makePlayer(format: session.avFormat)) }
  }

  public func detachPlay(_ session: PlaySession) {
    let id = ObjectIdentifier(session)
    sessions.removeValue(forKey: id)
    activeSessions.remove(id)
    update { $0.playActive = !activeSessions.isEmpty }
  }

  public func playActivity(_ session: PlaySession, active: Bool) {
    let id = ObjectIdentifier(session)
    guard sessions[id] != nil else { return }
    if active { activeSessions.insert(id) } else { activeSessions.remove(id) }
    update { $0.playActive = !activeSessions.isEmpty }
  }

  // MARK: engine events

  /// The first tap buffer after capture was armed.
  public func firstBuffer() {
    guard engine?.kind == .voice else { return }
    failures = 0
    status.failure = nil
    syncCapture(bufferSeen: true)
  }

  /// Configuration change, default device change or wake: rebuild after a
  /// debounce, since Bluetooth profile switches take time to settle.
  public func deviceChanged(reason: String) {
    rebuildToken += 1
    let token = rebuildToken
    scheduler.after(Self.rebuildDebounce) { [weak self] in
      guard let self, token == self.rebuildToken else { return }
      self.rebuild(reason: reason)
    }
  }

  public func rebuild(reason: String) {
    let previous = (Devices.defaultInput(), status.inputDevice)
    let noInput = previous.0 == nil
    if inputs.noInputDevice != noInput {
      update { $0.noInputDevice = noInput }
      if noInput { mic?.enqueue(.event("no_input_device")) }
    }
    guard let kind = engine?.kind else {
      evaluate()
      return
    }
    log?("rebuilding the \(kind.rawValue) engine: \(reason)")
    teardown()
    retryAt = nil
    evaluate()
    if let name = previous.0?.name, name != previous.1 {
      mic?.enqueue(.event("device_changed", ["device": name]))
    }
    mic?.enqueue(.event("engine_restarted", ["reason": reason]))
  }

  // MARK: decisions

  public func evaluate() {
    let now = scheduler.now
    let decision = EngineRules.decide(inputs, current: engine?.kind, idleSince: idleSince, now: now)
    switch decision {
    case .keep:
      break
    case .stop:
      teardown()
    case .linger(let until):
      lingerToken += 1
      let token = lingerToken
      scheduler.after(max(0, until - now)) { [weak self] in
        guard let self, token == self.lingerToken else { return }
        self.evaluate()
      }
    case .build(let kind):
      if let retryAt, now < retryAt { break }
      if engine != nil { teardown() }
      build(kind)
    }
    syncCapture()
    publish()
  }

  private func build(_ kind: EngineKind) {
    let flags = self.flags
    let ring = self.ring
    var converter: CaptureConverter?
    let capture: (AVAudioPCMBuffer) -> Void = { [hop] buffer in
      flags.lastBuffer.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
      if flags.armed.exchange(false, ordering: .relaxed) {
        hop { [weak self] in self?.firstBuffer() }
      }
      if flags.forwarding.load(ordering: .relaxed), let converter {
        converter.process(buffer) { ring.push($0) }
      }
    }
    do {
      let made = try factory.make(kind: kind, agc: status.agc, capture: { capture($0) }, configurationChanged: { [hop] in
        hop { [weak self] in self?.deviceChanged(reason: "configuration change") }
      })
      if kind == .voice {
        guard let rate = made.inputRate, let built = CaptureConverter(inputRate: rate) else {
          throw EngineError.badFormat("no converter for the input rate")
        }
        converter = built
      }
      self.converter = converter
      for session in sessions.values {
        session.bind(made.makePlayer(format: session.avFormat))
      }
      flags.armed.store(kind == .voice, ordering: .relaxed)
      flags.lastBuffer.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
      try made.start()
      engine = made
      status.engine = kind
      status.inputDevice = Devices.defaultInput()?.name
      status.outputDevice = Devices.defaultOutput()?.name
      retryAt = nil
      log?("started the \(kind.rawValue) engine (in \(status.inputDevice ?? "none") \(made.inputRate.map { "\(Int($0)) Hz" } ?? ""), out \(status.outputDevice ?? "none"))")
      if kind == .voice { startWatchdog() }
    } catch EngineError.noInputDevice {
      flags.armed.store(false, ordering: .relaxed)
      for session in sessions.values { session.unbind() }
      log?("no input device")
      if !inputs.noInputDevice {
        update { $0.noInputDevice = true }
        mic?.enqueue(.event("no_input_device"))
      }
    } catch {
      flags.armed.store(false, ordering: .relaxed)
      for session in sessions.values { session.unbind() }
      failures += 1
      let delay = EngineRules.retryDelay(failures: failures)
      status.failure = "\(error)"
      retryAt = scheduler.now + delay
      log?("\(kind.rawValue) engine failed (\(error)), retrying in \(Int(delay)) s")
      scheduler.after(delay) { [weak self] in self?.evaluate() }
    }
  }

  private func teardown() {
    guard let current = engine else { return }
    flags.forwarding.store(false, ordering: .relaxed)
    flags.armed.store(false, ordering: .relaxed)
    for session in sessions.values { session.unbind() }
    current.stop()
    engine = nil
    converter = nil
    status.engine = nil
    status.capturing = false
    log?("stopped the \(current.kind.rawValue) engine")
  }

  /// Aligns forwarding, silence filling and the client's paused state.
  private func syncCapture(bufferSeen: Bool = false) {
    let wantPaused = inputs.clientPaused
    if wantPaused {
      if flags.forwarding.exchange(false, ordering: .relaxed) || (!clientPaused && mic != nil) {
        if let mic, !clientPaused {
          mic.enqueue(.event("capture_paused"), kind: .paused)
          clientPaused = true
        }
      }
      if inputs.captureWanted, !inputs.micAuthorized, let mic, !permissionReported {
        mic.enqueue(.event("permission_denied", ["msg": "microphone access not granted to HA Satellite"]))
        permissionReported = true
      }
      flags.fillSilence.store(false, ordering: .relaxed)
    } else if engine?.kind == .voice, inputs.voiceWanted {
      if !flags.forwarding.load(ordering: .relaxed) {
        if bufferSeen {
          if let mic, clientPaused {
            mic.enqueue(.event("capture_resumed"), kind: .resumed)
          }
          clientPaused = false
          flags.forwarding.store(true, ordering: .relaxed)
        } else {
          flags.armed.store(true, ordering: .relaxed)
        }
      }
      flags.fillSilence.store(!flags.forwarding.load(ordering: .relaxed), ordering: .relaxed)
    } else {
      // Capture wanted but no engine delivering yet: starting, failing,
      // asleep or without an input device.
      flags.forwarding.store(false, ordering: .relaxed)
      flags.fillSilence.store(true, ordering: .relaxed)
    }
    let capturing = flags.forwarding.load(ordering: .relaxed)
    if status.capturing != capturing {
      status.capturing = capturing
      publish()
    }
  }

  private func startWatchdog() {
    guard !watchdogRunning else { return }
    watchdogRunning = true
    scheduler.after(1) { [weak self] in self?.watchdogTick() }
  }

  private func watchdogTick() {
    guard let engine, engine.kind == .voice else {
      watchdogRunning = false
      return
    }
    let last = flags.lastBuffer.load(ordering: .relaxed)
    let silentFor = Double(DispatchTime.now().uptimeNanoseconds &- last) / 1e9
    if inputs.voiceWanted, silentFor > Self.watchdog {
      watchdogRunning = false
      rebuild(reason: "no input for \(Int(silentFor)) s")
      return
    }
    scheduler.after(1) { [weak self] in self?.watchdogTick() }
  }

  private func publish() {
    status.micAuthorized = inputs.micAuthorized
    status.noInputDevice = inputs.noInputDevice
    onStatus?(status)
  }

  /// Stops everything (Quit).
  public func shutdown() {
    teardown()
    publish()
  }
}
