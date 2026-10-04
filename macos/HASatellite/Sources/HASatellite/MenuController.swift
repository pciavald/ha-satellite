import AppKit
import SatelliteCore

protocol MenuActions: AnyObject {
  func menuWillOpen()
  func toggleListening()
  func talkNow()
  func stopPipeline()
  func chooseShortcut(_ shortcut: Shortcut)
  func replaceSiri()
  func toggleOpenAtLogin()
  func openLogs()
  func microphoneAccess()
  func restartSatellite()
  func toggleRunSatellite()
  func about()
}

/// The status item and its menu, updated in place from `MenuModel`.
final class MenuController: NSObject, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private weak var actions: MenuActions?

  private let titleItem = NSMenuItem()
  private let homeAssistantItem = NSMenuItem()
  private let microphoneItem = NSMenuItem()
  private let satelliteItem = NSMenuItem()
  private let noticeItem = NSMenuItem()
  private let listeningItem = NSMenuItem(title: "Listen for Wake Word", action: #selector(toggleListening), keyEquivalent: "")
  private let talkItem = NSMenuItem(title: "Talk Now", action: #selector(talkNow), keyEquivalent: "")
  private let stopItem = NSMenuItem(title: "Stop", action: #selector(stopPipeline), keyEquivalent: "")
  private let shortcutItem = NSMenuItem(title: "Talk Now Shortcut", action: nil, keyEquivalent: "")
  private let shortcutMenu = NSMenu()
  private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
  private let runItem = NSMenuItem(title: "Run Satellite Process", action: #selector(toggleRunSatellite), keyEquivalent: "")
  private let restartItem = NSMenuItem(title: "Restart Satellite", action: #selector(restartSatellite), keyEquivalent: "")
  private var current: MenuModel?

  init(actions: MenuActions) {
    self.actions = actions
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    for item in [titleItem, homeAssistantItem, microphoneItem, satelliteItem, noticeItem] {
      item.isEnabled = false
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(listeningItem)
    menu.addItem(talkItem)
    menu.addItem(stopItem)
    menu.addItem(.separator())
    for shortcut in Shortcut.allCases {
      let item = NSMenuItem(title: shortcut.title, action: #selector(chooseShortcut(_:)), keyEquivalent: "")
      item.representedObject = shortcut.rawValue
      item.target = self
      shortcutMenu.addItem(item)
    }
    shortcutItem.submenu = shortcutMenu
    menu.addItem(shortcutItem)
    menu.addItem(item("Replace Siri…", #selector(replaceSiri)))
    menu.addItem(loginItem)
    menu.addItem(.separator())
    let troubleshooting = NSMenu()
    troubleshooting.autoenablesItems = false
    troubleshooting.addItem(item("Open Logs", #selector(openLogs)))
    troubleshooting.addItem(item("Microphone Access…", #selector(microphoneAccess)))
    troubleshooting.addItem(restartItem)
    troubleshooting.addItem(runItem)
    let troubleshootingItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
    troubleshootingItem.submenu = troubleshooting
    menu.addItem(troubleshootingItem)
    menu.addItem(item("About HA Satellite", #selector(about)))
    menu.addItem(NSMenuItem(title: "Quit HA Satellite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    for item in [listeningItem, talkItem, stopItem, loginItem, runItem, restartItem] {
      item.target = self
    }
    statusItem.menu = menu
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  /// Opens the menu (a second launch asks the running app to show itself).
  /// From the run loop, not from a main-queue block: the menu's tracking
  /// loop would otherwise hold the main queue until it closes.
  func open() {
    perform(#selector(performOpen), with: nil, afterDelay: 0, inModes: [.default])
  }

  @objc private func performOpen() {
    statusItem.button?.performClick(nil)
  }

  /// Returns true when something visible changed.
  @discardableResult
  func render(_ model: MenuModel, state: AppState) -> Bool {
    let changed = model != current
    current = model
    if let button = statusItem.button {
      let image = NSImage(systemSymbolName: model.icon.rawValue, accessibilityDescription: model.accessibilityLabel)
      image?.isTemplate = true
      button.image = image
      button.setAccessibilityLabel(model.accessibilityLabel)
      button.toolTip = model.accessibilityLabel
    }
    titleItem.title = model.title
    homeAssistantItem.title = model.homeAssistant
    microphoneItem.title = model.microphone
    satelliteItem.title = model.satellite
    noticeItem.title = model.notice ?? ""
    noticeItem.isHidden = model.notice == nil
    listeningItem.state = model.listeningChecked ? .on : .off
    listeningItem.isEnabled = model.listeningEnabled
    talkItem.isEnabled = model.talkEnabled
    talkItem.title = model.shortcutTitle.isEmpty ? "Talk Now" : "Talk Now (\(model.shortcutTitle))"
    stopItem.isHidden = !model.stopVisible
    loginItem.state = model.loginChecked ? .on : .off
    loginItem.title = model.loginTitle
    runItem.state = state.runSatellite ? .on : .off
    restartItem.isEnabled = model.restartEnabled
    for item in shortcutMenu.items {
      item.state = (item.representedObject as? String) == state.shortcut.rawValue ? .on : .off
    }
    return changed
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    actions?.menuWillOpen()
  }

  @objc private func toggleListening() { actions?.toggleListening() }
  @objc private func talkNow() { actions?.talkNow() }
  @objc private func stopPipeline() { actions?.stopPipeline() }
  @objc private func replaceSiri() { actions?.replaceSiri() }
  @objc private func toggleOpenAtLogin() { actions?.toggleOpenAtLogin() }
  @objc private func openLogs() { actions?.openLogs() }
  @objc private func microphoneAccess() { actions?.microphoneAccess() }
  @objc private func restartSatellite() { actions?.restartSatellite() }
  @objc private func toggleRunSatellite() { actions?.toggleRunSatellite() }
  @objc private func about() { actions?.about() }

  @objc private func chooseShortcut(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let shortcut = Shortcut(rawValue: raw) else { return }
    actions?.chooseShortcut(shortcut)
  }
}
