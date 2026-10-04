# HA Satellite for macOS

`HA Satellite.app` makes a Mac a Home Assistant voice satellite with the built-in
microphone and speakers. It is a menu bar app (no Dock icon) that:

- captures the microphone through Apple's voice processing (echo cancellation and
  noise suppression), so the satellite does not hear its own answers;
- plays text-to-speech, announcements and sounds through the same audio engine,
  which is what lets the echo canceller remove them;
- serves both to the Python satellite (`linux_voice_assistant`) over a Unix socket;
- starts that Python satellite as a child process and restarts it when it stops;
- shows the satellite's state in the menu bar, with a Listening switch and Talk Now.

Everything here is macOS-only and opt-in: Linux builds and runs exactly as before.

## Requirements

- Apple Silicon Mac, macOS 15 or later (the wake word models need macOS 15)
- Xcode (for `swift build` and `swift test`); no Xcode project is used
- The Python satellite in `.venv/` at the repository root, with the socket backends
  (`--audio-input-socket`, `--audio-output-socket`, `--control-socket`)
- libmpv for music (`LVA_LIBMPV_DIR`, for example nixpkgs `mpv-unwrapped`)

## Build, sign, install

```sh
macos/build.sh test        # Swift unit tests
macos/build.sh build       # macos/HASatellite/.build/HA Satellite.app
macos/build.sh install     # build, copy to ~/Applications, write satellite.json, open
macos/build.sh status      # login item, permissions, configuration, satellite pid
```

The script uses Apple's toolchain even inside the Nix dev shell (it drops the Nix
`DEVELOPER_DIR`, `SDKROOT` and `xcrun`).

**Signing.** Set `LVA_SIGN_IDENTITY` to a code signing identity:

```sh
export LVA_SIGN_IDENTITY="Developer ID Application: Pierre-Alexis Ciavaldini (FM89677QBG)"
macos/build.sh install
```

The app is signed with the hardened runtime and the
`com.apple.security.device.audio-input` entitlement. With a Developer ID the
designated requirement is the bundle id plus the team, so rebuilds keep the
microphone permission. Without `LVA_SIGN_IDENTITY` the app is signed ad hoc: it
works, but every rebuild is a new app for macOS, which asks for the microphone
again, and the login item may not register reliably. Without a certificate, a
self-signed "Code Signing" certificate from Keychain Access is a stable alternative.
The app is not notarized: it is built locally and never quarantined.

**Install location.** `install` copies the app to `~/Applications/HA Satellite.app`
(the login item expects `/Applications` or `~/Applications`) and refuses when
Spotlight finds another copy of `io.iostud.ha-satellite` elsewhere: duplicate copies
confuse the login item. Reinstalling over the same path keeps the permissions.

## Configuration

`~/Library/Application Support/ha-satellite/satellite.json` says how to start the
Python satellite. `macos/build.sh config [--name NAME] [--force]` writes it from
[`satellite.json.example`](satellite.json.example) with this repository's path, the
Wi-Fi MAC address, the computer name and `LVA_LIBMPV_DIR`:

| Key | Meaning |
| --- | --- |
| `python` | absolute path of the interpreter, usually `<repo>/.venv/bin/python` |
| `cwd` | absolute working directory, usually the repository |
| `args` | the full argument list; the app adds nothing, so the same command runs by hand |
| `env` | extra environment (`LVA_LIBMPV_DIR`, `PYTHONUNBUFFERED`) |
| `socket` | socket path, default `~/Library/Application Support/ha-satellite/audio.sock` |
| `agc` | voice-processing automatic gain at start, default `false` |

Paths must be absolute: at login the app gets a minimal environment, without the
Nix shell. Without `satellite.json` the app only serves the socket.

Files:

| Path | Content |
| --- | --- |
| `~/Library/Application Support/ha-satellite/` | `satellite.json`, `audio.sock`, `audio.lock`, `run/satellite.pid`, the satellite's preferences (directory mode 0700) |
| `~/Library/Logs/HA Satellite/satellite.log` | the Python satellite's output (rotated above 10 MB, one `.1` kept) |
| `~/Library/Logs/HA Satellite/app.log` | the app: engine starts, connections, child exits and restarts, menu state |

`log stream --predicate 'subsystem == "io.iostud.ha-satellite"'` shows the app's
log live. For development, `HA_SATELLITE_HOME` and `HA_SATELLITE_LOGS` move these
directories (the first-run dialog is then skipped), and Troubleshooting > Run
Satellite Process off lets you start the Python satellite by hand against the
running app.

## Permissions

- **Microphone**: asked at the first start (the app shows what it does first).
  The app captures the microphone itself; Python never opens it. If it was
  refused, Troubleshooting > Microphone Access… opens the right System Settings
  pane. To ask again from scratch: `tccutil reset Microphone io.iostud.ha-satellite`.
- **Local Network**: asked the first time the satellite announces itself to Home
  Assistant (mDNS). It is attributed to HA Satellite, the parent of the Python
  process, so Python upgrades need no new permission.
- **Open at Login**: offered at the first start, then in the menu. It appears in
  System Settings > General > Login Items & Extensions > Open at Login. The app
  does not relaunch itself after a crash; the Python satellite started with
  `--control-socket` is meant to exit 30 s after losing the app, so Home Assistant
  shows it unavailable rather than deaf, and the next start stops any leftover
  satellite through `run/satellite.pid`.
- No Accessibility or Input Monitoring permission is needed: the Talk Now shortcut
  uses a system hotkey registration.

## Menu

- Status lines: Home Assistant connection, microphone, satellite process.
- **Listen for Wake Word**: the satellite's mute switch in Home Assistant, inverted,
  kept in sync both ways. Turning it off releases the microphone (see Sleep).
- **Talk Now** (default ⌃⌥Space): starts a conversation even when the wake word is
  off; pressed during a conversation or a ringing timer, it stops it. **Stop**
  appears while a conversation or timer runs.
- **Talk Now Shortcut**: ⌃⌥Space, ⌃⌥⌘Space, ⌃⇧Space, the Dictation key (F5), or none.
- **Replace Siri…**: what can and cannot be done (below).
- **Open at Login**.
- **Troubleshooting**: Open Logs, Microphone Access…, Restart Satellite, Run
  Satellite Process.
- **About**, **Quit** (stops the satellite first; Quit does not change Open at Login).

The icon: `waveform` idle or listening, filled during a conversation, `mic.slash`
with the wake word off, a bell for a ringing timer, a warning triangle for a
problem (microphone not authorized, audio engine failing, satellite not running,
Home Assistant disconnected for more than 30 s).

## Sleep, lid and battery

- **While listening, the Mac does not go to sleep on its own.** macOS keeps the
  system awake while any app records audio, and the satellite always records to
  hear the wake word. The display still turns off as usual. On battery this drains
  it: stop listening when you do not need the satellite.
- **Turn off Listen for Wake Word** to let it sleep again. The microphone is
  released five seconds later, the orange indicator goes away and the Mac sleeps
  on its own again. The satellite stays connected to Home Assistant and still plays
  announcements (without opening the microphone), and Talk Now still works. The
  setting is kept across restarts.
- **Sleeping on purpose** (Apple menu, power button, `pmset sleepnow`) or **closing
  the lid** puts the Mac to sleep as usual. The satellite is told first, and shows
  as unavailable in Home Assistant while the Mac sleeps; it is back within a few
  seconds of waking.
- **Lid closed with an external display** (clamshell mode): the Mac stays awake but
  the built-in microphone is switched off by the hardware, so the satellite hears
  nothing until the lid opens.
- Music is played by libmpv outside the echo canceller: it is reduced but not
  removed from what the microphone hears.

## Replacing Siri

macOS has no setting or API that makes another app the voice assistant, in the EU
or elsewhere. What works instead:

1. Turn Siri off in System Settings > Apple Intelligence & Siri, so one assistant
   answers. The app only reads this setting (Replace Siri… shows it and opens the
   pane); it never changes it.
2. Use the wake word for hands-free requests.
3. Use the Talk Now shortcut, which works even with the wake word off: the Mac can
   then sleep, and a key starts a conversation, like Siri's keyboard shortcut.
4. Optionally, choose **Dictation Key (F5)** as the shortcut. The app then remaps
   the Dictation key of the built-in keyboard to F19 with `hidutil` (user level, no
   administrator rights, gone after a reboot, so the app applies it again at start
   and after wake) and listens for F19. While the option is on, the key no longer
   starts macOS Dictation; choosing another shortcut or quitting gives it back.
   Other key remaps are kept. Not yet tried on every keyboard.

Not possible or rejected: the Globe (fn) key (consumed by the system), Siri's own
shortcut (needs Input Monitoring or Accessibility), Shortcuts and Spotlight actions
(App Intents need an Xcode project build).

## Uninstall

```sh
macos/build.sh uninstall           # unregister the login item, quit, delete the app
macos/build.sh uninstall --purge   # also delete the configuration, preferences and logs
```

Deleting the app without `uninstall` leaves a stale Login Items entry. The command
prints how to forget the permissions (`tccutil reset Microphone
io.iostud.ha-satellite`; Local Network in System Settings).

## Command line

`HA Satellite.app/Contents/MacOS/HASatellite`:

- no option: the menu bar app
- `--status`: JSON with the login item, permissions, configuration, devices and
  satellite pid
- `--unregister`: remove the login item and the Dictation key remap
- `--selftest [--no-play]`: capture 1.5 s through voice processing and print the
  formats and level, then play a 0.3 s tone at -30 dBFS through the same engine
- `--version`

## Socket protocol

The contract is in `plans/audio.md` section 6 (roles `mic`, `play:<name>` and
`control`, 8-byte frame header, `HELLO` version `proto` 1). The shared fixtures in
[`tests/fixtures/helper_protocol/`](../tests/fixtures/helper_protocol/) are read by
the Swift tests and the Python tests, so both sides encode the same bytes.

Additions to the contract made by the app, all optional for the client:
- `mic` HELLO reply: `vp`, `agc`, `capturing`, `input_device`, `output_device`,
  `rate_in`, `helper_version`; every HELLO reply has `accepted`, and a refused one
  has `reason` (`unsupported_proto`, `unknown_role`, `unsupported_format`)
- `mic` events: `no_input_device`, `engine_restarted`, `device_changed` (with
  `device`), `will_sleep`, `did_wake`, `network_changed`; Python answers
  `will_sleep` with `EVENT sleep_ready` (the app waits at most 2 s)
- `protocol_error` EVENT (with `error` and `msg`) before closing a connection on a
  malformed frame
- `control`: Python may send `{"command": "set_agc", "id": n, "data": {"on": bool}}`;
  the app answers with an ack
- a play item cut by an audio engine change gets `EVENT interrupted`; the rest of
  the item is dropped and `DRAINED` follows its `END`

## Development

```sh
cd macos/HASatellite
swift build
swift test
```

`Sources/SatelliteCore` holds everything testable without a device (protocol,
audio rules, playback accounting, supervisor, configuration, menu model, key
remap); `Sources/HASatellite` is the AppKit shell (menu, hotkey, login item, power
events). The tests use a fake audio engine behind a real Unix socket, and
`/bin/sh` scripts as the supervised child.
