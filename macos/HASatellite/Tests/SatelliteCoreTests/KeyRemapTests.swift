import Foundation
import XCTest

@testable import SatelliteCore

final class KeyRemapTests: XCTestCase {
  final class FakeRunner: CommandRunner {
    var output: String
    var calls: [[String]] = []
    var setStatus: Int32 = 0

    init(output: String) {
      self.output = output
    }

    func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
      XCTAssertEqual(path, "/usr/bin/hidutil")
      calls.append(arguments)
      return arguments.contains("--set") ? (setStatus, "") : (0, output)
    }
  }

  let other = "(\n    {\n        HIDKeyboardModifierMappingDst = 30064771300;\n        HIDKeyboardModifierMappingSrc = 30064771129;\n    }\n)"

  func testParseFormats() {
    XCTAssertEqual(KeyRemap.parse("(null)"), [])
    XCTAssertEqual(KeyRemap.parse("RegistryID  Key                   Value\n100000ac4   UserKeyMapping   (null)\n100000adc   UserKeyMapping   (null)\n"), [])
    XCTAssertEqual(KeyRemap.parse(other), [KeyMapping(src: 30_064_771_129, dst: 30_064_771_300)])
    let table = "RegistryID  Key                   Value\n100000ac4   UserKeyMapping   " + other + "\n100000adc   UserKeyMapping   (null)\n"
    XCTAssertEqual(KeyRemap.parse(table), [KeyMapping(src: 30_064_771_129, dst: 30_064_771_300)])
    XCTAssertNil(KeyRemap.parse("garbage {"))
  }

  func testMergeKeepsOtherMappings() {
    let caps = KeyMapping(src: 1, dst: 2)
    XCTAssertEqual(KeyRemap.merged([caps], enabled: true), [caps, KeyRemap.ours])
    XCTAssertEqual(KeyRemap.merged([caps, KeyRemap.ours], enabled: true), [caps, KeyRemap.ours])
    XCTAssertEqual(KeyRemap.merged([KeyRemap.ours, caps], enabled: false), [caps])
    XCTAssertEqual(KeyRemap.setArgument([KeyRemap.ours]),
                   #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":51539607759,"HIDKeyboardModifierMappingDst":30064771182}]}"#)
  }

  func testApplyAddsOnceAndRemovesOnlyOurs() {
    let runner = FakeRunner(output: other)
    let remapper = KeyRemapper(runner: runner) { Keyboard(vendor: 0x5AC, product: 0x343) }
    XCTAssertNil(remapper.apply(enabled: true))
    XCTAssertEqual(runner.calls.count, 2)
    XCTAssertEqual(runner.calls[1], ["property", "--matching", #"{"VendorID":1452,"ProductID":835}"#, "--set",
                                     #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771300},{"HIDKeyboardModifierMappingSrc":51539607759,"HIDKeyboardModifierMappingDst":30064771182}]}"#])

    // Already applied: nothing is set again (idempotent).
    runner.output = "(\n{HIDKeyboardModifierMappingDst = 30064771300; HIDKeyboardModifierMappingSrc = 30064771129;},\n{HIDKeyboardModifierMappingDst = 30064771182; HIDKeyboardModifierMappingSrc = 51539607759;}\n)"
    runner.calls = []
    XCTAssertNil(remapper.apply(enabled: true))
    XCTAssertEqual(runner.calls.count, 1)

    // Leftover after a crash, option off: removed, the other mapping kept.
    runner.calls = []
    XCTAssertNil(remapper.apply(enabled: false))
    XCTAssertEqual(runner.calls.last?.last, #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771300}]}"#)
  }

  func testFailures() {
    let runner = FakeRunner(output: "(null)")
    runner.setStatus = 1
    XCTAssertEqual(KeyRemapper(runner: runner) { Keyboard(vendor: 1, product: 2) }.apply(enabled: true), "hidutil failed with status 1")
    XCTAssertEqual(KeyRemapper(runner: runner) { nil }.apply(enabled: true), "no built-in keyboard")
    XCTAssertNil(KeyRemapper(runner: runner) { nil }.apply(enabled: false))
    runner.output = "garbage {"
    XCTAssertEqual(KeyRemapper(runner: runner) { Keyboard(vendor: 1, product: 2) }.apply(enabled: true), "hidutil cannot read the key mapping")
  }
}
