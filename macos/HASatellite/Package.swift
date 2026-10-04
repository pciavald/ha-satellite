// swift-tools-version:6.0
import Foundation
import PackageDescription

// The Info.plist is also embedded in the executable, so the binary run from a
// terminal (--status, --selftest) has the same identity as the bundle.
let infoPlist = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("Resources/Info.plist").path

let package = Package(
  name: "HASatellite",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "HASatellite", targets: ["HASatellite"]),
  ],
  targets: [
    .target(
      name: "SatelliteCore",
      linkerSettings: [
        .linkedFramework("AVFAudio"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("IOKit"),
      ]
    ),
    .executableTarget(
      name: "HASatellite",
      dependencies: ["SatelliteCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Carbon"),
        .linkedFramework("ServiceManagement"),
        .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
      ]
    ),
    .testTarget(
      name: "SatelliteCoreTests",
      dependencies: ["SatelliteCore"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
