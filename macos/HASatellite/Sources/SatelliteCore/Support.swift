import AVFoundation
import Darwin
import Foundation
import os

/// App log: unified logging plus `app.log` next to the satellite's log.
public final class AppLog: @unchecked Sendable {
  private let logger = Logger(subsystem: "io.iostud.ha-satellite", category: "app")
  private let url: URL?
  private let lock = NSLock()
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  public init(url: URL?) {
    self.url = url
    if let url {
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
  }

  public func callAsFunction(_ message: String) {
    logger.info("\(message, privacy: .public)")
    guard let url else { return }
    lock.lock()
    defer { lock.unlock() }
    let line = "\(formatter.string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }
}

/// Single instance: an exclusive `flock` on `audio.lock`, held for the life
/// of the process.
public final class InstanceLock {
  private let fd: Int32

  /// nil when another instance holds the lock.
  public init?(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(url.deletingLastPathComponent().path, 0o700)
    let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SocketError.system("open \(url.path)", errno) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return nil
    }
    self.fd = fd
  }

  deinit {
    flock(fd, LOCK_UN)
    close(fd)
  }
}

public enum MicPermission: String, Sendable {
  case authorized
  case denied
  case restricted
  case notDetermined = "not determined"

  public static var current: MicPermission {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .authorized
    case .denied: return .denied
    case .restricted: return .restricted
    default: return .notDetermined
    }
  }

  public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
  }

  public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}

/// Siri and Dictation state, read only from the preferences (never written).
public struct SiriStatus: Equatable, Sendable {
  public var siriEnabled: Bool?
  public var dictationEnabled: Bool?

  public static var current: SiriStatus {
    let domain = "com.apple.assistant.support" as CFString
    func flag(_ key: String) -> Bool? {
      (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.boolValue
    }
    return SiriStatus(siriEnabled: flag("Assistant Enabled"), dictationEnabled: flag("Dictation Enabled"))
  }

  public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
}
