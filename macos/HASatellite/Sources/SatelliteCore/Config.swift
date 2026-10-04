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

/// The satellite's name in Home Assistant (ESPHome friendly name).
public enum SatelliteName {
  public static let maxLength = 64

  /// The trimmed name, or a ConfigError saying what is wrong with it.
  public static func validate(_ raw: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { throw ConfigError("the name cannot be empty") }
    if name.count > maxLength { throw ConfigError("the name is longer than \(maxLength) characters") }
    if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
      throw ConfigError("the name cannot contain control characters")
    }
    return name
  }

  /// The Mac's own name made valid, for a satellite.json without a name.
  public static func fallback(_ computerName: String?) -> String {
    let cleaned = String((computerName ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let short = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    return short.isEmpty ? "Mac" : short
  }
}

/// A network interface as SystemConfiguration lists it.
public struct NetworkInterface: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case other
  }

  public var bsdName: String
  public var kind: Kind
  public var mac: String

  public init(bsdName: String, kind: Kind, mac: String) {
    self.bsdName = bsdName
    self.kind = kind
    self.mac = mac
  }
}

/// Where the MAC address that identifies the device in Home Assistant comes
/// from: pinned to the built-in Wi-Fi, it stays the same device when the Mac
/// moves between Wi-Fi and a dock.
public enum MacSource: Equatable, Sendable {
  case configured(String)
  case detected(NetworkInterface)
  /// No built-in interface found: LVA uses the active interface's address.
  case active
}

public enum NetworkIdentity {
  /// `aa:bb:cc:dd:ee:ff`, `AA-BB-CC-DD-EE-FF` or `aabbccddeeff` in lower-case
  /// colon form; nil when it is not a MAC address or is all zeros.
  public static func normalize(_ raw: String) -> String? {
    let digits = raw.trimmingCharacters(in: .whitespaces).lowercased().filter { $0 != ":" && $0 != "-" }
    guard digits.count == 12, digits.allSatisfy(\.isHexDigit), digits != String(repeating: "0", count: 12) else { return nil }
    var pairs: [String] = []
    var index = digits.startIndex
    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 2)
      pairs.append(String(digits[index..<next]))
      index = next
    }
    return pairs.joined(separator: ":")
  }

  /// The built-in Wi-Fi (the lowest numbered one), else the built-in
  /// Ethernet of desktop Macs (en0); dock and USB adapters are never chosen.
  public static func builtIn(_ interfaces: [NetworkInterface]) -> NetworkInterface? {
    let valid = interfaces.compactMap { interface -> NetworkInterface? in
      guard let mac = normalize(interface.mac) else { return nil }
      return NetworkInterface(bsdName: interface.bsdName, kind: interface.kind, mac: mac)
    }
    func number(_ name: String) -> Int { Int(name.drop { !$0.isNumber }) ?? Int.max }
    if let wifi = valid.filter({ $0.kind == .wifi }).min(by: { number($0.bsdName) < number($1.bsdName) }) {
      return wifi
    }
    return valid.first { $0.kind == .ethernet && $0.bsdName == "en0" }
  }
}

/// Where the bundled interpreter and libraries are inside the app.
public struct BundleLayout: Equatable, Sendable {
  public var contents: URL

  public init(contents: URL) {
    self.contents = contents
  }

  public var python: URL { contents.appendingPathComponent("Resources/python/bin/python3") }
  public var frameworks: URL { contents.appendingPathComponent("Frameworks") }
  public var hasPython: Bool { FileManager.default.isExecutableFile(atPath: python.path) }
}

/// What the supervisor starts.
public struct LaunchCommand: Equatable, Sendable {
  public var python: String
  public var cwd: String
  public var args: [String]
  public var env: [String: String]

  public init(python: String, cwd: String, args: [String], env: [String: String] = [:]) {
    self.python = python
    self.cwd = cwd
    self.args = args
    self.env = env
  }

  /// The command line as written in the logs.
  public var line: String { ([python] + args).joined(separator: " ") }
}

/// `satellite.json`, optional, every key optional: the app builds the
/// satellite's command itself (bundled Python, name, detected MAC address,
/// `--host 0.0.0.0 --follow-network`, the app's socket); the file only holds
/// the name chosen in the menu and overrides.
///
/// ```json
/// {"name": "MacBook", "mac_address": "aa:bb:cc:dd:ee:ff", "host": "0.0.0.0",
///  "follow_network": true, "extra_args": ["--debug"], "env": {"A": "1"},
///  "python": "/abs/.venv/bin/python", "cwd": "/abs/repo",
///  "socket": "/abs/audio.sock", "agc": false}
/// ```
public struct SatelliteConfig: Equatable, Sendable {
  public var name: String?
  /// Overrides the detected built-in Wi-Fi address.
  public var macAddress: String?
  /// Default `0.0.0.0`: listen on every interface, advertise the detected address.
  public var host: String?
  public var followNetwork: Bool
  /// Appended to the app's arguments.
  public var extraArgs: [String]
  public var env: [String: String]
  /// Another interpreter (a repository's venv, development); default the bundled one.
  public var python: String?
  /// Working directory, default the support directory.
  public var cwd: String?
  /// Socket path, default `<support>/audio.sock`.
  public var socket: String?
  /// Voice-processing AGC at start (off: wake word models prefer stable levels).
  public var agc: Bool

  public init(name: String? = nil, macAddress: String? = nil, host: String? = nil, followNetwork: Bool = true, extraArgs: [String] = [],
              env: [String: String] = [:], python: String? = nil, cwd: String? = nil, socket: String? = nil, agc: Bool = false) {
    self.name = name
    self.macAddress = macAddress
    self.host = host
    self.followNetwork = followNetwork
    self.extraArgs = extraArgs
    self.env = env
    self.python = python
    self.cwd = cwd
    self.socket = socket
    self.agc = agc
  }

  public static func parse(_ data: Data) throws -> SatelliteConfig {
    guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
      throw ConfigError("satellite.json is not a JSON object")
    }
    if dict["args"] != nil {
      throw ConfigError("\"args\" is no longer used: the app builds the command, put additional flags in \"extra_args\"")
    }
    let known: Set = ["name", "mac_address", "host", "follow_network", "extra_args", "env", "python", "cwd", "socket", "agc"]
    if let unknown = dict.keys.filter({ !known.contains($0) && !$0.hasPrefix("_") }).sorted().first {
      throw ConfigError("unknown key \"\(unknown)\" in satellite.json")
    }
    func string(_ key: String) throws -> String? {
      guard let raw = dict[key] else { return nil }
      guard let value = raw as? String else { throw ConfigError("\"\(key)\" must be a string") }
      return value
    }
    func path(_ key: String) throws -> String? {
      guard let raw = dict[key] else { return nil }
      guard let value = raw as? String, value.hasPrefix("/") else { throw ConfigError("\"\(key)\" must be an absolute path") }
      return value
    }
    func flag(_ key: String, _ fallback: Bool) throws -> Bool {
      guard let raw = dict[key] else { return fallback }
      guard let value = raw as? Bool, CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() else {
        throw ConfigError("\"\(key)\" must be true or false")
      }
      return value
    }

    var config = SatelliteConfig()
    if let raw = try string("name") {
      do {
        config.name = try SatelliteName.validate(raw)
      } catch let error as ConfigError {
        throw ConfigError("\"name\": \(error.message)")
      }
    }
    if let raw = try string("mac_address") {
      guard let mac = NetworkIdentity.normalize(raw) else { throw ConfigError("\"mac_address\" must be a MAC address such as aa:bb:cc:dd:ee:ff") }
      config.macAddress = mac
    }
    if let host = try string("host") {
      guard !host.isEmpty else { throw ConfigError("\"host\" cannot be empty") }
      config.host = host
    }
    config.followNetwork = try flag("follow_network", true)
    if let raw = dict["extra_args"] {
      guard let list = raw as? [Any], let strings = list as? [String], strings.count == list.count else {
        throw ConfigError("\"extra_args\" must be a list of strings")
      }
      config.extraArgs = strings
    }
    if let raw = dict["env"] {
      guard let map = raw as? [String: Any], let strings = map as? [String: String], strings.count == map.count else {
        throw ConfigError("\"env\" must map names to strings")
      }
      config.env = strings
    }
    config.python = try path("python")
    config.cwd = try path("cwd")
    config.socket = try path("socket")
    config.agc = try flag("agc", false)
    return config
  }

  /// The defaults when the file does not exist.
  public static func load(_ url: URL) throws -> SatelliteConfig {
    guard FileManager.default.fileExists(atPath: url.path) else { return SatelliteConfig() }
    do {
      return try parse(Data(contentsOf: url))
    } catch let error as ConfigError {
      throw error
    } catch {
      throw ConfigError("cannot read \(url.path): \(error.localizedDescription)")
    }
  }

  public func resolvedName(computerName: String?) -> String {
    name ?? SatelliteName.fallback(computerName)
  }

  public func macSource(builtIn: NetworkInterface?) -> MacSource {
    if let macAddress { return .configured(macAddress) }
    return builtIn.map { .detected($0) } ?? .active
  }

  /// The satellite's command. The bundled interpreter runs isolated (`-I`:
  /// no user site, no PYTHON* variables, LVA found through a `.pth` file),
  /// without writing bytecode into the signed bundle (`-B`).
  public func command(bundle: BundleLayout, paths: Paths, computerName: String?, builtIn: NetworkInterface?) -> LaunchCommand {
    let socket = self.socket ?? paths.socket.path
    var args = python == nil ? ["-I", "-B", "-u"] : []
    args += ["-m", "linux_voice_assistant", "--name", resolvedName(computerName: computerName), "--host", host ?? "0.0.0.0"]
    switch macSource(builtIn: builtIn) {
    case .configured(let mac): args += ["--mac-address", mac]
    case .detected(let interface): args += ["--mac-address", interface.mac]
    case .active: break
    }
    if followNetwork { args.append("--follow-network") }
    args += [
      "--audio-input-socket", socket,
      "--audio-output-socket", socket,
      "--control-socket", socket,
      "--persist-mute",
      "--disable-peripheral-api",
      "--preferences-file", paths.support.appendingPathComponent("preferences.json").path,
      "--download-dir", paths.support.appendingPathComponent("downloads").path,
    ]
    args += extraArgs
    var environment = [
      "PYTHONUNBUFFERED": "1",
      "PYTHONDONTWRITEBYTECODE": "1",
      "LVA_LIBMPV_DIR": bundle.frameworks.path,
    ]
    for (key, value) in env { environment[key] = value }
    return LaunchCommand(python: python ?? bundle.python.path, cwd: cwd ?? paths.support.path, args: args, env: environment)
  }
}

/// Changes made from the menu, keeping every other key of the file.
public enum ConfigFile {
  public static func setName(_ raw: String, at url: URL) throws {
    let name = try SatelliteName.validate(raw)
    var object: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
      guard let data = try? Data(contentsOf: url), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ConfigError("\(url.path) is not a JSON object: fix or remove it first")
      }
      object = parsed
    }
    object["name"] = name
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0a)
    try data.write(to: url, options: .atomic)
  }
}
