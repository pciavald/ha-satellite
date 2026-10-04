import Foundation

public enum LoginItemStatus: String, Sendable {
  case enabled
  case notRegistered = "not registered"
  case requiresApproval = "requires approval"
  case notFound = "not found"
}

/// "Talk now" shortcut presets: each includes ⌃ or ⌘, since Option-only
/// combinations are not delivered since macOS 15.
public enum Shortcut: String, CaseIterable, Sendable {
  case controlOptionSpace
  case controlOptionCommandSpace
  case controlShiftSpace
  /// F19, which the Dictation key (F5) is remapped to.
  case dictationKey
  case none

  public static let `default` = Shortcut.controlOptionSpace

  public var title: String {
    switch self {
    case .controlOptionSpace: return "⌃⌥Space"
    case .controlOptionCommandSpace: return "⌃⌥⌘Space"
    case .controlShiftSpace: return "⌃⇧Space"
    case .dictationKey: return "Dictation Key (F5)"
    case .none: return "None"
    }
  }
}

public enum StatusIcon: String, Sendable {
  case listening = "waveform"
  case active = "waveform.circle.fill"
  case muted = "mic.slash"
  case timer = "bell"
  case problem = "exclamationmark.triangle"
}

/// Everything the menu depends on.
public struct AppState: Equatable, Sendable {
  public var name: String
  public var hub = HubState()
  public var supervisor: SupervisorStatus = .stopped
  public var runSatellite = true
  public var micPermission: MicPermission = .authorized
  public var loginItem: LoginItemStatus = .notRegistered
  public var shortcut: Shortcut = .default
  public var shortcutError: String?
  /// A problem of the app itself (socket, login item).
  public var appNotice: String?
  public var now = Date()

  public init(name: String) {
    self.name = name
  }
}

/// The menu's text and flags, computed without AppKit.
public struct MenuModel: Equatable, Sendable {
  public static let haGrace: TimeInterval = 30

  public var icon: StatusIcon
  public var accessibilityLabel: String
  public var title: String
  public var homeAssistant: String
  public var microphone: String
  public var satellite: String
  public var notice: String?
  public var listeningChecked: Bool
  public var listeningEnabled: Bool
  public var talkEnabled: Bool
  public var stopVisible: Bool
  public var loginChecked: Bool
  public var loginTitle: String
  public var shortcutTitle: String
  public var restartEnabled: Bool

  public init(_ state: AppState) {
    let hub = state.hub
    let snapshot = hub.controlConnected ? hub.snapshot : nil
    title = "HA Satellite: \(state.name)"

    if !hub.controlConnected {
      homeAssistant = "Home Assistant: satellite not connected"
    } else if let snapshot {
      homeAssistant = snapshot.haConnected ? "Home Assistant: connected" : "Home Assistant: waiting for Home Assistant"
    } else {
      homeAssistant = "Home Assistant: waiting for the satellite"
    }

    switch state.micPermission {
    case .denied, .restricted:
      microphone = "Microphone: not authorized"
    case .notDetermined:
      microphone = "Microphone: access not requested yet"
    case .authorized:
      if hub.audio.noInputDevice {
        microphone = "Microphone: no input device"
      } else if hub.audio.failure != nil {
        microphone = "Microphone: audio engine failing"
      } else if hub.audio.capturing {
        microphone = "Microphone: listening, echo cancellation on"
      } else if snapshot?.muted == true {
        microphone = "Microphone: wake word off"
      } else if !hub.micClient {
        microphone = "Microphone: off (satellite not reading)"
      } else {
        microphone = "Microphone: starting"
      }
    }

    var satelliteProblem = false
    switch state.supervisor {
    case .notConfigured(nil):
      satellite = "Satellite: not configured (no satellite.json)"
      satelliteProblem = state.runSatellite
    case .notConfigured(let error?):
      satellite = "Satellite: invalid satellite.json (\(error))"
      satelliteProblem = state.runSatellite
    case .disabled:
      satellite = hub.controlConnected ? "Satellite: started by hand" : "Satellite: not started by the app"
    case .running:
      satellite = hub.controlConnected ? "Satellite: running" : "Satellite: starting"
    case .restarting(let delay, _, let failing):
      satellite = failing ? "Satellite failing, see logs" : "Satellite: restarting in \(Int(delay.rounded())) s"
      satelliteProblem = true
    case .stopped:
      satellite = "Satellite: stopped"
      satelliteProblem = state.runSatellite
    }

    notice = hub.notice ?? state.appNotice ?? state.shortcutError

    listeningEnabled = snapshot != nil
    listeningChecked = snapshot.map { !$0.muted } ?? false
    stopVisible = snapshot?.pipelineActive ?? false
    talkEnabled = snapshot.map { $0.pipelineActive || $0.haConnected } ?? false
    restartEnabled = state.runSatellite
    shortcutTitle = state.shortcut == .none ? "" : state.shortcut.title

    switch state.loginItem {
    case .enabled:
      loginChecked = true
      loginTitle = "Open at Login"
    case .requiresApproval:
      loginChecked = false
      loginTitle = "Open at Login (approve in System Settings)"
    case .notFound, .notRegistered:
      loginChecked = false
      loginTitle = "Open at Login"
    }

    let haDown = hub.haDisconnectedSince.map { state.now.timeIntervalSince($0) > Self.haGrace } ?? false
    let micProblem = state.micPermission == .denied || state.micPermission == .restricted
      || hub.audio.failure != nil || hub.audio.noInputDevice
    var reasons: [String] = []
    if micProblem { reasons.append(microphone) }
    if satelliteProblem { reasons.append(satellite) }
    if haDown { reasons.append("Home Assistant disconnected") }

    if !reasons.isEmpty {
      icon = .problem
      accessibilityLabel = "HA Satellite: " + reasons.joined(separator: "; ")
    } else if snapshot?.phase == "timer" {
      icon = .timer
      accessibilityLabel = "HA Satellite: timer ringing"
    } else if snapshot?.pipelineActive == true {
      icon = .active
      accessibilityLabel = "HA Satellite: \(snapshot!.phase)"
    } else if snapshot?.muted == true {
      icon = .muted
      accessibilityLabel = "HA Satellite: wake word off"
    } else {
      icon = .listening
      accessibilityLabel = hub.audio.capturing ? "HA Satellite: listening" : "HA Satellite: idle"
    }
  }
}
