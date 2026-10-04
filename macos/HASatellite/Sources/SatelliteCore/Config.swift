import Foundation

/// Where the app keeps its files. `HA_SATELLITE_HOME` and `HA_SATELLITE_LOGS`
/// move them (development and tests).
public struct Paths: Sendable {
  public var support: URL
  public var logs: URL

  public init(support: URL, logs: URL) {
    self.support = support
    self.logs = logs
  }

  public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let support = environment["HA_SATELLITE_HOME"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent("Library/Application Support/ha-satellite")
    let logs = environment["HA_SATELLITE_LOGS"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent("Library/Logs/HA Satellite")
    return Paths(support: support, logs: logs)
  }

  public var config: URL { support.appendingPathComponent("satellite.json") }
  public var socket: URL { support.appendingPathComponent("audio.sock") }
  public var lock: URL { support.appendingPathComponent("audio.lock") }
  public var pidFile: URL { support.appendingPathComponent("run/satellite.pid") }
  public var satelliteLog: URL { logs.appendingPathComponent("satellite.log") }
  public var appLog: URL { logs.appendingPathComponent("app.log") }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}

/// `satellite.json`: how to start the Python satellite. The app adds no flag
/// of its own, so the same command can be run by hand.
///
/// ```json
/// {"python": "/abs/.venv/bin/python", "cwd": "/abs/repo",
///  "args": ["-m", "linux_voice_assistant", "--name", "Mac"],
///  "env": {"PYTHONUNBUFFERED": "1"}, "socket": "/abs/audio.sock", "agc": false}
/// ```
public struct SatelliteConfig: Equatable, Sendable {
  public var python: String
  public var cwd: String
  public var args: [String]
  public var env: [String: String]
  /// Socket path, default `<support>/audio.sock`.
  public var socket: String?
  /// Voice-processing AGC at start (off: wake word models prefer stable levels).
  public var agc: Bool

  public init(python: String, cwd: String, args: [String], env: [String: String] = [:], socket: String? = nil, agc: Bool = false) {
    self.python = python
    self.cwd = cwd
    self.args = args
    self.env = env
    self.socket = socket
    self.agc = agc
  }

  public static func parse(_ data: Data) throws -> SatelliteConfig {
    guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
      throw ConfigError("satellite.json is not a JSON object")
    }
    let known: Set = ["python", "cwd", "args", "env", "socket", "agc"]
    if let unknown = dict.keys.filter({ !known.contains($0) && !$0.hasPrefix("_") }).sorted().first {
      throw ConfigError("unknown key \"\(unknown)\" in satellite.json")
    }
    guard let python = dict["python"] as? String, python.hasPrefix("/") else {
      throw ConfigError("\"python\" must be an absolute path")
    }
    guard let cwd = dict["cwd"] as? String, cwd.hasPrefix("/") else {
      throw ConfigError("\"cwd\" must be an absolute path")
    }
    guard let args = dict["args"] as? [Any], let strings = args as? [String], strings.count == args.count else {
      throw ConfigError("\"args\" must be a list of strings")
    }
    var env: [String: String] = [:]
    if let raw = dict["env"] {
      guard let map = raw as? [String: Any], let strings = map as? [String: String], strings.count == map.count else {
        throw ConfigError("\"env\" must map names to strings")
      }
      env = strings
    }
    var socket: String?
    if let raw = dict["socket"] {
      guard let path = raw as? String, path.hasPrefix("/") else {
        throw ConfigError("\"socket\" must be an absolute path")
      }
      socket = path
    }
    var agc = false
    if let raw = dict["agc"] {
      guard let flag = raw as? Bool, CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() else {
        throw ConfigError("\"agc\" must be true or false")
      }
      agc = flag
    }
    // Left by `macos/build.sh config` for the values only the owner knows.
    for value in [python, cwd] + strings + env.values.sorted() + [socket ?? ""] {
      if let range = value.range(of: "@[A-Z_]+@", options: .regularExpression) {
        throw ConfigError("satellite.json still has the placeholder \(value[range]): replace it with your value")
      }
    }
    return SatelliteConfig(python: python, cwd: cwd, args: strings, env: env, socket: socket, agc: agc)
  }

  /// nil when the file does not exist (the satellite is not configured).
  public static func load(_ url: URL) throws -> SatelliteConfig? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try parse(Data(contentsOf: url))
    } catch let error as ConfigError {
      throw error
    } catch {
      throw ConfigError("cannot read \(url.path): \(error.localizedDescription)")
    }
  }
}
