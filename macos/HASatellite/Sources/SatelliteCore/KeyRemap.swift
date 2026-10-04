import Foundation
import IOKit
import IOKit.hid

/// Optional Dictation key (F5) → F19 remap with `hidutil`, so the key can be
/// the "Talk now" hotkey (plans/swift-helper.md section 11). User level, no
/// root, cleared by a reboot; the app only adds or removes its own entry and
/// keeps any other mapping.
public struct KeyMapping: Equatable, Sendable {
  public var src: UInt64
  public var dst: UInt64

  public init(src: UInt64, dst: UInt64) {
    self.src = src
    self.dst = dst
  }
}

public enum KeyRemap {
  /// Consumer page 0x0C, usage 0xCF (voice command / Dictation).
  public static let dictation: UInt64 = 0xC_0000_00CF
  /// Keyboard page 0x07, usage 0x6E (F19).
  public static let f19: UInt64 = 0x7_0000_006E
  public static let ours = KeyMapping(src: dictation, dst: f19)

  /// Parses `hidutil property [--matching …] --get UserKeyMapping`: either a
  /// bare property list or a table with one row per matching service (the
  /// first row is used: the app sets every service the same way). nil when
  /// the output cannot be read.
  public static func parse(_ output: String) -> [KeyMapping]? {
    var value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("RegistryID") {
      var rows: [String] = []
      for line in value.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
        let text = String(line)
        if let range = text.range(of: #"^[0-9a-fA-F]+\s+UserKeyMapping\s+"#, options: .regularExpression) {
          rows.append(String(text[range.upperBound...]))
        } else if !rows.isEmpty {
          rows[rows.count - 1] += "\n" + text
        }
      }
      guard let first = rows.first else { return [] }
      value = first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if value.isEmpty || value == "(null)" { return [] }
    guard let plist = try? PropertyListSerialization.propertyList(from: Data(value.utf8), format: nil),
          let entries = plist as? [Any]
    else { return nil }
    var mappings: [KeyMapping] = []
    for entry in entries {
      guard let dict = entry as? [String: Any],
            let src = number(dict["HIDKeyboardModifierMappingSrc"]),
            let dst = number(dict["HIDKeyboardModifierMappingDst"])
      else { return nil }
      mappings.append(KeyMapping(src: src, dst: dst))
    }
    return mappings
  }

  private static func number(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let text = value as? String {
      return text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
    return nil
  }

  /// `current` without the app's entry, plus it when `enabled`.
  public static func merged(_ current: [KeyMapping], enabled: Bool) -> [KeyMapping] {
    var result = current.filter { $0 != ours }
    if enabled { result.append(ours) }
    return result
  }

  public static func setArgument(_ mappings: [KeyMapping]) -> String {
    let entries = mappings.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
    return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
  }

  public static func matchingArgument(vendor: Int, product: Int) -> String {
    "{\"VendorID\":\(vendor),\"ProductID\":\(product)}"
  }
}

public protocol CommandRunner {
  /// Runs an executable, returns its exit status and standard output.
  func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)
}

public struct ProcessRunner: CommandRunner {
  public init() {}

  public func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

public struct Keyboard: Equatable, Sendable {
  public var vendor: Int
  public var product: Int

  public init(vendor: Int, product: Int) {
    self.vendor = vendor
    self.product = product
  }

  /// The built-in keyboard, looked up in the I/O Registry (properties only,
  /// no device is opened, so no Input Monitoring permission); nil in
  /// clamshell mode or on a Mac without one.
  public static func builtIn() -> Keyboard? {
    guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { return nil }
    matching[kIOPropertyMatchKey] = [
      kIOHIDBuiltInKey: true,
      kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
      kIOHIDPrimaryUsageKey: kHIDUsage_GD_Keyboard,
    ]
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
      defer {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }
      let vendor = IORegistryEntryCreateCFProperty(service, kIOHIDVendorIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
      let product = IORegistryEntryCreateCFProperty(service, kIOHIDProductIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
      if let vendor, let product { return Keyboard(vendor: vendor, product: product) }
    }
    return nil
  }
}

public final class KeyRemapper {
  public static let hidutil = "/usr/bin/hidutil"

  private let runner: CommandRunner
  private let keyboard: () -> Keyboard?

  public init(runner: CommandRunner = ProcessRunner(), keyboard: @escaping () -> Keyboard? = Keyboard.builtIn) {
    self.runner = runner
    self.keyboard = keyboard
  }

  /// Adds (or removes) the app's entry on the built-in keyboard, keeping the
  /// others. Idempotent; returns an error message on failure.
  @discardableResult
  public func apply(enabled: Bool) -> String? {
    guard let keyboard = keyboard() else {
      return enabled ? "no built-in keyboard" : nil
    }
    let matching = KeyRemap.matchingArgument(vendor: keyboard.vendor, product: keyboard.product)
    let get = runner.run(Self.hidutil, ["property", "--matching", matching, "--get", "UserKeyMapping"])
    guard get.status == 0, let current = KeyRemap.parse(get.output) else {
      return "hidutil cannot read the key mapping"
    }
    let next = KeyRemap.merged(current, enabled: enabled)
    if next == current { return nil }
    let set = runner.run(Self.hidutil, ["property", "--matching", matching, "--set", KeyRemap.setArgument(next)])
    return set.status == 0 ? nil : "hidutil failed with status \(set.status)"
  }
}
