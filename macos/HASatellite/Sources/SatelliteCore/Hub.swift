import Foundation

/// What the menu shows, published on every change.
public struct HubState: Equatable, Sendable {
  public var controlConnected = false
  public var snapshot: Snapshot?
  public var notice: String?
  public var pendingTalk = false
  public var lvaVersion: String?
  public var micClient = false
  public var audio = AudioStatus()
  /// Since when Home Assistant has been reported disconnected.
  public var haDisconnectedSince: Date?

  public init() {}
}

/// The socket server and its roles (plans/audio.md section 6) around the
/// audio controller. All state lives on `queue`; connection threads only read
/// their socket and hop onto it.
public final class Hub: @unchecked Sendable {
  public static let helloTimeout: TimeInterval = 5
  public static let sleepReadyTimeout: TimeInterval = 2
  public static let wakeDelay: TimeInterval = 2
  public static let talkCaptureTimeout: TimeInterval = 1.5

  public let queue: DispatchQueue
  public let audio: AudioController
  public let control = ControlModel()
  public let socketPath: String
  public let helperVersion: String

  /// Called on `queue` after every change.
  public var onChange: ((HubState) -> Void)?
  public var log: (String) -> Void = { _ in }

  private var server: SocketServer?
  private var micLink: MicLink?
  private var controlConnection: Connection?
  private var plays: [String: (connection: Connection, session: PlaySession)] = [:]
  private var sleepReply: (() -> Void)?
  private var talkWaiting = false
  private var haDownSince: Date?
  private var notice: String?

  public init(socketPath: String, helperVersion: String, factory: EngineFactory = AVEngineFactory(), scheduler: Scheduler? = nil, queue: DispatchQueue? = nil) {
    let queue = queue ?? DispatchQueue(label: "io.iostud.ha-satellite.hub")
    self.queue = queue
    self.socketPath = socketPath
    self.helperVersion = helperVersion
    audio = AudioController(factory: factory, scheduler: scheduler ?? QueueScheduler(queue: queue)) { block in queue.async(execute: block) }
    audio.onStatus = { [weak self] _ in self?.audioChanged() }
    audio.log = { [weak self] in self?.log($0) }
  }

  public func start() throws {
    let server = SocketServer(path: socketPath) { [weak self] connection in self?.serve(connection) }
    try server.start()
    self.server = server
    log("listening on \(socketPath)")
  }

  /// Closes every connection and stops the engine. Blocks until done.
  public func stop() {
    server?.stop()
    queue.sync {
      micLink?.connection.close()
      controlConnection?.close()
      for play in plays.values { play.connection.close() }
      audio.shutdown()
    }
  }

  public var state: HubState {
    queue.sync { makeState() }
  }

  // MARK: commands from the app (any thread)

  public func toggleListening() {
    queue.async { [self] in
      guard let frame = control.toggleListening() else { return }
      controlConnection?.send(frame)
      scheduleExpire(ControlModel.ackTimeout)
      publish()
    }
  }

  /// "Talk now": stop a running pipeline, or start capture if needed and ask
  /// LVA to listen even with the wake word off.
  public func talkNow() {
    queue.async { [self] in
      switch control.talkAction() {
      case .stop:
        controlConnection?.send(control.send(.stopPipeline))
        scheduleExpire(ControlModel.ackTimeout)
      case .unavailable(let why):
        notice = "Talk now unavailable: \(why)"
        publish()
      case .start:
        notice = nil
        control.beginTalk()
        audio.update { $0.pendingTalk = true }
        talkWaiting = true
        if audio.status.capturing || !audio.inputs.micAuthorized {
          sendStartListening()
        } else {
          audio.evaluate()
          queue.asyncAfter(deadline: .now() + Self.talkCaptureTimeout) { [weak self] in self?.sendStartListening() }
        }
        scheduleExpire(ControlModel.talkTimeout)
      }
      publish()
    }
  }

  public func stopPipeline() {
    queue.async { [self] in
      guard control.connected else { return }
      controlConnection?.send(control.send(.stopPipeline))
      scheduleExpire(ControlModel.ackTimeout)
      publish()
    }
  }

  public func setMicAuthorized(_ authorized: Bool) {
    queue.async { [self] in audio.update { $0.micAuthorized = authorized } }
  }

  public func setAGC(_ on: Bool) {
    queue.async { [self] in audio.setAGC(on) }
  }

  public func restartEngine(reason: String) {
    queue.async { [self] in audio.rebuild(reason: reason) }
  }

  public func devicesChanged() {
    queue.async { [self] in audio.deviceChanged(reason: "default device changed") }
  }

  // MARK: power (plans/network-service-upstream.md 3.6)

  /// System sleep: `will_sleep` to Python, wait for `sleep_ready` (at most
  /// 2 s), stop the engine, then `reply` (allow the power change).
  public func willSleep(reply: @escaping () -> Void) {
    queue.async { [self] in
      sleepReply?()
      sleepReply = reply
      if let micLink {
        micLink.enqueue(.event("will_sleep"))
        queue.asyncAfter(deadline: .now() + Self.sleepReadyTimeout) { [weak self] in self?.sleepReady() }
      } else {
        sleepReady()
      }
    }
  }

  public func didWake() {
    queue.async { [self] in
      micLink?.enqueue(.event("did_wake"))
      queue.asyncAfter(deadline: .now() + Self.wakeDelay) { [weak self] in
        self?.audio.update { $0.sleeping = false }
      }
    }
  }

  public func networkChanged() {
    queue.async { [self] in micLink?.enqueue(.event("network_changed")) }
  }

  private func sleepReady() {
    guard let reply = sleepReply else { return }
    sleepReply = nil
    audio.update { $0.sleeping = true }
    reply()
  }

  // MARK: connections (connection threads)

  private func serve(_ connection: Connection) {
    let hello: ClientHello
    do {
      guard let frame = try connection.read(timeout: Self.helloTimeout) else { return }
      hello = try Hello.parse(frame)
    } catch let refusal as HelloRefusal {
      connection.send(refusal.reply)
      connection.close()
      return
    } catch let error as ProtocolError {
      connection.send(error.frame)
      connection.close()
      return
    } catch {
      connection.close()
      return
    }
    switch hello.role {
    case .mic: serveMic(connection)
    case .control: serveControl(connection, hello)
    case .play(let name): servePlay(connection, name: name, format: hello.format!)
    }
  }

  private func serveMic(_ connection: Connection) {
    let link: MicLink = queue.sync {
      let link = MicLink(connection: connection, ring: audio.ring, flags: audio.flags, paused: false)
      micLink?.connection.close()
      micLink = link
      // The reply goes before the engine starts (the first voice-processing
      // start takes seconds); events and frames follow from the writer.
      var next = audio.inputs
      next.micClient = true
      let input = Devices.defaultInput()
      let info = MicHelloInfo(
        micAuthorized: next.micAuthorized,
        agc: audio.status.agc,
        capturing: !next.clientPaused,
        inputDevice: input?.name,
        outputDevice: Devices.defaultOutput()?.name,
        rateIn: input.map { Int($0.rate) },
        helperVersion: helperVersion
      )
      connection.send(info.reply)
      log("mic client connected")
      audio.attachMic(link)
      publish()
      return link
    }
    let writer = Thread { link.run() }
    writer.name = "mic-writer"
    writer.start()
    do {
      while let frame = try connection.read() {
        guard frame.type == .event else { throw ProtocolError.unexpected(frame.type) }
        let code = try frame.object()["code"] as? String
        if code == "sleep_ready" {
          queue.async { [weak self] in self?.sleepReady() }
        }
      }
    } catch let error as ProtocolError {
      connection.send(error.frame)
    } catch {}
    connection.close()
    queue.async { [self] in
      audio.detachMic(link)
      if micLink === link {
        micLink = nil
        log("mic client disconnected")
      }
      publish()
    }
  }

  private func servePlay(_ connection: Connection, name: String, format: PlayFormat) {
    guard let session = PlaySession(name: name, format: format, send: { connection.send($0) }, activity: { [weak self] session, active in
      self?.queue.async { self?.audio.playActivity(session, active: active) }
    }) else {
      connection.send(HelloRefusal(reason: "unsupported_format").reply)
      connection.close()
      return
    }
    queue.sync {
      plays[name]?.connection.close()
      plays[name] = (connection, session)
      connection.send(Hello.playReply())
      audio.attachPlay(session)
      log("play:\(name) connected (\(format.sample.rawValue), \(format.rate) Hz, \(format.channels) ch)")
    }
    do {
      while let frame = try connection.read() {
        try session.handle(frame)
      }
    } catch let error as ProtocolError {
      connection.send(error.frame)
    } catch {}
    connection.close()
    session.close()
    queue.async { [self] in
      audio.detachPlay(session)
      if plays[name]?.session === session {
        plays.removeValue(forKey: name)
        log("play:\(name) disconnected")
      }
    }
  }

  private func serveControl(_ connection: Connection, _ hello: ClientHello) {
    queue.sync {
      controlConnection?.close()
      controlConnection = connection
      control.connect(lvaVersion: hello.lvaVersion)
      connection.send(Hello.controlReply(helperVersion: helperVersion))
      audio.update { $0.controlConnected = true }
      log("control client connected (LVA \(hello.lvaVersion ?? "unknown"))")
      publish()
    }
    do {
      while let frame = try connection.read() {
        let message = try ControlMessage.parse(frame)
        queue.async { [weak self] in self?.handleControl(message, from: connection) }
      }
    } catch let error as ProtocolError {
      connection.send(error.frame)
    } catch {}
    connection.close()
    queue.async { [self] in
      guard controlConnection === connection else { return }
      controlConnection = nil
      control.disconnect()
      talkWaiting = false
      audio.update {
        $0.controlConnected = false
        $0.pendingTalk = false
        $0.ptt = false
      }
      log("control client disconnected")
      publish()
    }
  }

  private func handleControl(_ message: ControlInbound, from connection: Connection) {
    guard controlConnection === connection else { return }
    switch message {
    case .state(let snapshot):
      guard control.apply(snapshot) else { return }
      if snapshot.haConnected {
        haDownSince = nil
      } else if haDownSince == nil {
        haDownSince = Date()
      }
      audio.update {
        $0.muted = snapshot.muted
        $0.ptt = snapshot.ptt
        $0.pendingTalk = control.pendingTalk
      }
    case .ack(let id, let ok, let reason):
      control.ack(id: id, ok: ok, reason: reason)
      audio.update { $0.pendingTalk = control.pendingTalk }
    case .command(let name, let id):
      log("refused the satellite's unknown command \(name)")
      if let id { connection.send(ControlMessage.ack(id, ok: false, reason: "unknown_command")) }
    case .unknown:
      break
    }
    publish()
  }

  // MARK: helpers (queue)

  private func sendStartListening() {
    guard talkWaiting else { return }
    talkWaiting = false
    guard control.connected, control.pendingTalk else { return }
    controlConnection?.send(control.send(.startListening, data: ["allow_muted": true]))
    scheduleExpire(ControlModel.ackTimeout)
  }

  private func audioChanged() {
    if talkWaiting, audio.status.capturing {
      sendStartListening()
    }
    publish()
  }

  private func scheduleExpire(_ delay: TimeInterval) {
    queue.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
      guard let self else { return }
      if self.control.expire() {
        self.audio.update { $0.pendingTalk = self.control.pendingTalk }
        self.publish()
      }
    }
  }

  private func makeState() -> HubState {
    var state = HubState()
    state.controlConnected = control.connected
    state.snapshot = control.snapshot
    state.notice = notice ?? control.notice
    state.pendingTalk = control.pendingTalk
    state.lvaVersion = control.lvaVersion
    state.micClient = micLink != nil
    state.audio = audio.status
    state.haDisconnectedSince = haDownSince
    return state
  }

  private func publish() {
    onChange?(makeState())
  }
}
