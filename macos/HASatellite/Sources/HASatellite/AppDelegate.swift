import AppKit
import SatelliteCore

// Main-thread confined; callbacks hop back to the main queue.
final class AppDelegate: NSObject, NSApplicationDelegate, MenuActions, @unchecked Sendable {
  static let showNotification = Notification.Name("io.iostud.ha-satellite.show")

  private enum Key {
    static let shortcut = "TalkNowShortcut"
    static let runSatellite = "RunSatelliteProcess"
    static let firstRunDone = "FirstRunDone"
  }

  private let paths = Paths.standard()
  private lazy var log = AppLog(url: paths.appLog)
  private let defaults = UserDefaults.standard
  private var lock: InstanceLock?
  private var hub: Hub!
  private var supervisor: Supervisor!
  private var config = SatelliteConfig()
  private var configError: String?
  private var builtIn: NetworkInterface?
  private var menu: MenuController!
  private var hotkey: Hotkey!
  private let remapper = KeyRemapper()
  private var power: PowerMonitor?
  private var deviceWatch: AnyObject?
  private var state = AppState(name: SatelliteName.fallback(Machine.computerName))
  private var lifeActivity: NSObjectProtocol?
  private var engineActivity: NSObjectProtocol?
  private var timer: Timer?
  private var signalSources: [DispatchSourceSignal] = []

  // MARK: launch

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      lock = try InstanceLock(url: paths.lock)
    } catch {
      log("cannot take the instance lock: \(error)")
    }
    if lock == nil {
      log("another instance is running, asking it to show its menu")
      DistributedNotificationCenter.default().postNotificationName(Self.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
      exit(0)
    }
    log("HA Satellite \(AppInfo.fullVersion) starting")
    // Against App Nap, without blocking idle sleep (.userInitiated would).
    lifeActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Home Assistant satellite")
    DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { [weak self] _ in
      self?.menu.open()
    }
    // `kill` and `pkill` stop the satellite like Quit does (logout and
    // shutdown quit with an Apple event), without the main thread, which an
    // open menu holds.
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in self?.shutdown(signal: number) }
      source.resume()
      signalSources.append(source)
    }

    loadConfig()
    state.runSatellite = defaults.object(forKey: Key.runSatellite) as? Bool ?? true
    state.shortcut = defaults.string(forKey: Key.shortcut).flatMap(Shortcut.init(rawValue:)) ?? .default
    state.micPermission = MicPermission.current
    state.loginItem = LoginItem.status

    menu = MenuController(actions: self)
    hotkey = Hotkey { [weak self] in self?.talkNow() }

    let socket = config.socket ?? paths.socket.path
    hub = Hub(socketPath: socket, helperVersion: AppInfo.fullVersion)
    hub.log = { [log] in log($0) }
    hub.onChange = { [weak self] hubState in
      DispatchQueue.main.async { self?.hubChanged(hubState) }
    }
    hub.setAGC(config.agc)
    hub.setMicAuthorized(state.micPermission == .authorized)
    do {
      try hub.start()
    } catch {
      log("cannot listen on \(socket): \(error)")
      state.appNotice = "Socket unavailable: \(error)"
    }
    deviceWatch = Devices.watch(queue: hub.queue) { [weak hub] in hub?.devicesChanged() }
    power = PowerMonitor(hub: hub) { [weak self] in self?.applyRemap() }

    supervisor = Supervisor(pidFile: paths.pidFile, logFile: paths.satelliteLog)
    supervisor.log = { [log] in log($0) }
    supervisor.onStatus = { [weak self] status in
      DispatchQueue.main.async {
        self?.state.supervisor = status
        self?.render()
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      supervisor.stopOrphan()
      DispatchQueue.main.async { self.startSatellite() }
    }

    // A leftover remap from a crash is removed, then re-added if chosen.
    applyRemap()
    registerShortcut()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    render()

    // Skipped in development (HA_SATELLITE_HOME set): it registers the login item.
    let development = ProcessInfo.processInfo.environment["HA_SATELLITE_HOME"] != nil
    if !development, state.micPermission == .notDetermined || !defaults.bool(forKey: Key.firstRunDone) {
      DispatchQueue.main.async { self.firstRun() }
    }
  }

  /// Reads satellite.json and detects the built-in interface again; the
  /// name and network lines of the menu follow.
  private func loadConfig() {
    do {
      config = try SatelliteConfig.load(paths.config)
      configError = nil
    } catch {
      configError = "\(error)"
      log("satellite.json: \(error)")
    }
    builtIn = Machine.builtInInterface
    state.name = config.resolvedName(computerName: Machine.computerName)
    state.network = config.macSource(builtIn: builtIn)
  }

  /// nil, with the reason shown in the menu, when the satellite cannot start.
  private func launchCommand() -> LaunchCommand? {
    loadConfig()
    render()
    if let configError {
      supervisor.setStatus(.notConfigured("invalid satellite.json: \(configError)"))
      return nil
    }
    let bundle = Machine.bundle
    if config.python == nil, !bundle.hasPython {
      supervisor.setStatus(.notConfigured("no bundled Python at \(bundle.python.path)"))
      return nil
    }
    return config.command(bundle: bundle, paths: paths, computerName: Machine.computerName, builtIn: builtIn)
  }

  private func startSatellite() {
    guard state.runSatellite else {
      supervisor.setStatus(.disabled)
      return
    }
    guard let command = launchCommand() else { return }
    supervisor.start(command)
  }

  // MARK: quit

  private func shutdown(signal number: Int32) {
    log("quitting on signal \(number)")
    let removeRemap = state.shortcut == .dictationKey
    supervisor.stop { [hub, remapper, log] in
      hub?.stop()
      if removeRemap { remapper.apply(enabled: false) }
      log("stopped")
      exit(0)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    log("quitting")
    timer?.invalidate()
    hotkey.unregister()
    supervisor.stop { [self] in
      DispatchQueue.main.async { [self] in
        hub.stop()
        if state.shortcut == .dictationKey { remapper.apply(enabled: false) }
        log("stopped")
        NSApp.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }

  // MARK: state

  private func hubChanged(_ hubState: HubState) {
    let wasRunning = state.hub.audio.engine != nil
    state.hub = hubState
    let running = hubState.audio.engine != nil
    if running != wasRunning {
      // Latency-critical only while audio runs: it costs energy.
      if running {
        engineActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "audio engine running")
      } else if let engineActivity {
        ProcessInfo.processInfo.endActivity(engineActivity)
        self.engineActivity = nil
      }
    }
    render()
  }

  private func tick() {
    refreshPermission()
    render()
  }

  private func refreshPermission() {
    let permission = MicPermission.current
    if permission != state.micPermission {
      log("microphone permission: \(permission.rawValue)")
      state.micPermission = permission
      hub.setMicAuthorized(permission == .authorized)
    }
  }

  private func render() {
    state.now = Date()
    let model = MenuModel(state)
    if menu.render(model, state: state) {
      log("menu: \(model.icon.rawValue) | \(model.homeAssistant) | \(model.microphone) | \(model.satellite)\(model.notice.map { " | \($0)" } ?? "")")
    }
  }

  // MARK: menu actions

  func menuWillOpen() {
    refreshPermission()
    state.loginItem = LoginItem.status
    render()
  }

  func toggleListening() {
    hub.toggleListening()
  }

  func talkNow() {
    hub.talkNow()
  }

  func stopPipeline() {
    hub.stopPipeline()
  }

  func chooseShortcut(_ shortcut: Shortcut) {
    if shortcut == .dictationKey, state.shortcut != .dictationKey {
      let alert = NSAlert()
      alert.messageText = "Use the Dictation key (F5) for Talk Now?"
      alert.informativeText = "While HA Satellite runs, the Dictation key on the built-in keyboard starts a conversation with Home Assistant instead of macOS Dictation. The key is given back when you choose another shortcut or quit."
      alert.addButton(withTitle: "Use the Dictation Key")
      alert.addButton(withTitle: "Cancel")
      NSApp.activate()
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    state.shortcut = shortcut
    defaults.set(shortcut.rawValue, forKey: Key.shortcut)
    applyRemap()
    registerShortcut()
    render()
  }

  private func registerShortcut() {
    state.shortcutError = hotkey.register(state.shortcut)
    if let error = state.shortcutError {
      log("shortcut: \(error)")
    }
  }

  /// Idempotent: re-applied after wake and session switches, which can drop
  /// user key mappings.
  private func applyRemap() {
    let enabled = state.shortcut == .dictationKey
    if let error = remapper.apply(enabled: enabled) {
      log("Dictation key remap: \(error)")
      if enabled { state.shortcutError = "Dictation key: \(error)" }
    }
  }

  func replaceSiri() {
    let siri = SiriStatus.current
    func describe(_ value: Bool?) -> String { value.map { $0 ? "on" : "off" } ?? "unknown" }
    let alert = NSAlert()
    alert.messageText = "Replace Siri"
    alert.informativeText = """
    Siri is \(describe(siri.siriEnabled)), Dictation is \(describe(siri.dictationEnabled)).

    macOS has no setting to make another app the voice assistant. What HA Satellite offers instead: the wake word for hands-free use, and the Talk Now shortcut (\(state.shortcut.title)), which starts a conversation with Home Assistant even when the wake word is off.

    To have only one assistant answering, turn Siri off in System Settings > Apple Intelligence & Siri. HA Satellite never changes that setting itself.
    """
    alert.addButton(withTitle: "Open Siri Settings")
    alert.addButton(withTitle: "Close")
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(SiriStatus.settingsURL)
    }
  }

  func toggleOpenAtLogin() {
    let status = LoginItem.status
    if status == .requiresApproval {
      LoginItem.openSettings()
      return
    }
    do {
      try LoginItem.set(status != .enabled)
    } catch {
      log("login item: \(error)")
      state.appNotice = "Open at Login: \(error.localizedDescription)"
    }
    state.loginItem = LoginItem.status
    log("login item: \(state.loginItem.rawValue)")
    render()
  }

  func openLogs() {
    try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    NSWorkspace.shared.open(paths.logs)
  }

  func microphoneAccess() {
    switch MicPermission.current {
    case .notDetermined:
      NSApp.activate()
      MicPermission.request { _ in
        DispatchQueue.main.async { self.tick() }
      }
    case .authorized:
      let alert = NSAlert()
      alert.messageText = "Microphone access is granted"
      alert.informativeText = "HA Satellite can use the microphone."
      NSApp.activate()
      alert.runModal()
    case .denied, .restricted:
      let alert = NSAlert()
      alert.messageText = "Microphone access is off"
      alert.informativeText = "Turn on HA Satellite in System Settings > Privacy & Security > Microphone. The satellite stays connected meanwhile but hears nothing."
      alert.addButton(withTitle: "Open System Settings")
      alert.addButton(withTitle: "Cancel")
      NSApp.activate()
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(MicPermission.settingsURL)
      }
    }
  }

  func restartSatellite() {
    restart(reason: "from the menu")
  }

  private func restart(reason: String) {
    guard state.runSatellite else { return }
    guard let command = launchCommand() else {
      supervisor.stop { DispatchQueue.main.async { [weak self] in self?.startSatellite() } }
      return
    }
    log("restarting the satellite \(reason)")
    supervisor.stop { [weak self] in
      DispatchQueue.main.async { self?.supervisor.start(command) }
    }
  }

  func chooseName() {
    let alert = NSAlert()
    alert.messageText = "Satellite Name"
    alert.informativeText = "The name of this Mac in Home Assistant. The satellite restarts to announce it; Home Assistant keeps the same device."
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: state.name)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate()
    while alert.runModal() == .alertFirstButtonReturn {
      do {
        let name = try SatelliteName.validate(field.stringValue)
        guard name != state.name || config.name == nil else { return }
        try ConfigFile.setName(name, at: paths.config)
        log("satellite name: \(name)")
        restart(reason: "with the name \(name)")
        if !state.runSatellite {
          loadConfig()
          render()
        }
        return
      } catch {
        alert.informativeText = "Not renamed: \(error)."
      }
    }
  }

  func toggleRunSatellite() {
    state.runSatellite.toggle()
    defaults.set(state.runSatellite, forKey: Key.runSatellite)
    log("run satellite process: \(state.runSatellite)")
    if state.runSatellite {
      startSatellite()
    } else {
      supervisor.stop { [weak self] in self?.supervisor.setStatus(.disabled) }
    }
    render()
  }

  func about() {
    let alert = NSAlert()
    alert.messageText = "HA Satellite \(AppInfo.fullVersion)"
    var lines = ["A Home Assistant voice satellite for this Mac, built on linux-voice-assistant."]
    if let lva = state.hub.lvaVersion { lines.append("Satellite (LVA) \(lva).") }
    lines.append("Name: \(state.name)")
    lines.append("Configuration: \(paths.config.path)")
    lines.append("Logs: \(paths.logs.path)")
    alert.informativeText = lines.joined(separator: "\n")
    NSApp.activate()
    alert.runModal()
  }

  // MARK: first run

  private func firstRun() {
    let alert = NSAlert()
    alert.messageText = "HA Satellite"
    alert.informativeText = """
    HA Satellite makes this Mac a Home Assistant voice satellite. It listens for the wake word with echo cancellation, so it does not hear its own answers.

    While it listens, the orange microphone indicator stays on and the Mac does not go to sleep on its own. Turn off "Listen for Wake Word" in the menu bar to release the microphone and let the Mac sleep; Talk Now (\(state.shortcut.title)) still works.

    macOS asks next for the microphone.
    """
    alert.addButton(withTitle: "Continue")
    let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    login.state = .on
    alert.accessoryView = login
    NSApp.activate()
    alert.runModal()
    defaults.set(true, forKey: Key.firstRunDone)
    if login.state == .on, LoginItem.status != .enabled {
      do {
        try LoginItem.set(true)
      } catch {
        log("login item: \(error)")
      }
      state.loginItem = LoginItem.status
    }
    if MicPermission.current == .notDetermined {
      NSApp.activate()
      MicPermission.request { granted in
        DispatchQueue.main.async {
          self.log("microphone access \(granted ? "granted" : "denied")")
          self.tick()
        }
      }
    }
    render()
  }
}
