import AppKit
import SatelliteCore

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
case "--version":
  print("HA Satellite \(AppInfo.fullVersion)")
case "--status":
  CLI.status()
case "--unregister":
  exit(CLI.unregister())
case "--selftest":
  exit(CLI.selftest(play: !arguments.contains("--no-play")))
case "--echo-test":
  exit(CLI.echoTest())
default:
  FileHandle.standardError.write(Data("""
  usage: HASatellite [--status | --unregister | --selftest [--no-play] | --echo-test | --version]
    (no option)   run the menu bar app
    --status      print the configuration, permissions and login item state as JSON
    --unregister  remove the login item and the Dictation key remap
    --selftest    capture 1.5 s through voice processing and play a short tone
    --echo-test   play noise with and without voice processing and print the echo removed

  """.utf8))
  exit(2)
}
