import AppKit
import Carbon
import IOKit.pwr_mgt
import Network
import SatelliteCore
import ServiceManagement

enum AppInfo {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }

  /// Git commit written into the bundle's Info.plist by `macos/build.sh`.
  static var commit: String? {
    Bundle.main.object(forInfoDictionaryKey: "HASatelliteCommit") as? String
  }

  static var fullVersion: String {
    commit.map { "\(version) (\($0))" } ?? version
  }
}

enum LoginItem {
  static var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    default: return .notRegistered
    }
  }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  static func openSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// Global "Talk now" shortcut with Carbon's `RegisterEventHotKey`: no
/// Accessibility or Input Monitoring permission. Main thread only.
final class Hotkey {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let onPress: () -> Void

  init(onPress: @escaping () -> Void) {
    self.onPress = onPress
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
      guard let context else { return noErr }
      let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
      hotkey.onPress()
      return noErr
    }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  deinit {
    unregister()
    if let handler { RemoveEventHandler(handler) }
  }

  /// Returns an error message when the shortcut is taken.
  func register(_ shortcut: Shortcut) -> String? {
    unregister()
    let key: (code: Int, modifiers: Int)
    switch shortcut {
    case .controlOptionSpace: key = (kVK_Space, controlKey | optionKey)
    case .controlOptionCommandSpace: key = (kVK_Space, controlKey | optionKey | cmdKey)
    case .controlShiftSpace: key = (kVK_Space, controlKey | shiftKey)
    case .dictationKey: key = (kVK_F19, 0)
    case .none: return nil
    }
    let id = EventHotKeyID(signature: OSType(0x4841_5374), id: 1)  // "HASt"
    let status = RegisterEventHotKey(UInt32(key.code), UInt32(key.modifiers), id, GetApplicationEventTarget(), 0, &reference)
    if status != noErr {
      reference = nil
      return "\(shortcut.title) is used by another app (\(status))"
    }
    return nil
  }

  func unregister() {
    if let reference { UnregisterEventHotKey(reference) }
    reference = nil
  }
}

/// Sleep and wake, network changes and session switches, forwarded to the hub
/// (plans/network-service-upstream.md 3.6).
final class PowerMonitor {
  // iokit_common_msg values from IOKit/IOMessage.h (macros Swift cannot import).
  private static let canSystemSleep: UInt32 = 0xE000_0270
  private static let systemWillSleep: UInt32 = 0xE000_0280

  private let hub: Hub
  private let onWake: () -> Void
  private var rootPort: io_connect_t = 0
  private var notifier: io_object_t = 0
  private var port: IONotificationPortRef?
  private let pathMonitor = NWPathMonitor()
  private var pathSeen = false
  private var observers: [NSObjectProtocol] = []

  init(hub: Hub, onWake: @escaping () -> Void) {
    self.hub = hub
    self.onWake = onWake
    rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, type, argument in
      guard let context else { return }
      let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
      monitor.power(type, argument)
    }, &notifier)
    if let port { IONotificationPortSetDispatchQueue(port, DispatchQueue.main) }

    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.hub.didWake()
      self?.onWake()
    })
    observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.onWake()
    })
    pathMonitor.pathUpdateHandler = { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.pathSeen { self.hub.networkChanged() }
        self.pathSeen = true
      }
    }
    pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
  }

  deinit {
    pathMonitor.cancel()
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    if notifier != 0 { IODeregisterForSystemPower(&notifier) }
    if let port { IONotificationPortDestroy(port) }
    if rootPort != 0 { IOServiceClose(rootPort) }
  }

  private func power(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
    let id = Int(bitPattern: argument)
    switch type {
    case Self.canSystemSleep:
      IOAllowPowerChange(rootPort, id)
    case Self.systemWillSleep:
      let root = rootPort
      hub.willSleep { IOAllowPowerChange(root, id) }
    default:
      break
    }
  }
}
