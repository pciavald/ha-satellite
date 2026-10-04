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
End-to-end checks with Home Assistant are in [TESTING.md](TESTING.md).

## Requirements

- Apple Silicon Mac, macOS 15 or later (the wake word models need macOS 15)
- Xcode (for `swift build` and `swift test`); no Xcode project is used
- `uv` (or Python 3.13) to create the satellite's virtual environment
- libmpv for music, for example `brew install mpv` or nixpkgs `mpv-unwrapped`
- A "Developer ID Application" signing identity in the keychain (or see Signing)

## Install

```sh
just mac-install            # or: macos/build.sh install
```

This:

1. builds the app and signs it with the keychain's Developer ID Application
   identity (hardened runtime, microphone entitlement);
2. creates `.venv/` at the repository root with Python 3.13 if it is missing and
   installs the exact versions of [`requirements.txt`](requirements.txt) and LVA
   itself (editable) into it; packages already there, such as the dev tools of
   `./script/setup --dev`, are kept;
3. copies the app to `~/Applications/HA Satellite.app`, after checking that no
   other copy of `io.iostud.ha-satellite` exists (duplicates confuse the login
   item);
4. writes `~/Library/Application Support/ha-satellite/satellite.json` from
   [`satellite.json.example`](satellite.json.example) if it does not exist yet;
5. opens the app, but only once `satellite.json` has no placeholder left.

`satellite.json` keeps three placeholders for values only you know, and the
command prints how to find them:

| Placeholder | Value |
| --- | --- |
| `@NAME@` | the satellite's name in Home Assistant, for example `MacBook` |
| `@MAC@` | the built-in Wi-Fi MAC address: `networksetup -listallhardwareports \| grep -A 2 'Wi-Fi'`, line "Ethernet Address". It pins the device identity, so Home Assistant keeps the same device when the Mac moves between Wi-Fi and a dock |
| `@LIBMPV@` | the directory holding `libmpv.dylib`: `$(brew --prefix)/lib`, or the `lib` of nixpkgs `mpv-unwrapped`; filled from `LVA_LIBMPV_DIR` when it is set |

Set them by editing the file, or with
`just mac-config --force --name MacBook --mac aa:bb:cc:dd:ee:ff --libmpv /opt/homebrew/lib`,
then `open ~/Applications/HA\ Satellite.app`. The app refuses a file that still
has a placeholder and says which one in its menu.

Reinstalling over the same path keeps the permissions and the login item.
The other commands: `just mac-build`, `mac-test` (Swift tests), `mac-venv`,
`mac-config`, `mac-status`, `mac-selftest`, `mac-echo-test`, `mac-logs`,
`mac-uninstall` (`macos/build.sh help` lists them).

**Signing.** The identity is `LVA_SIGN_IDENTITY` when set, otherwise the first
"Developer ID Application" identity of the keychain. With a Developer ID the
designated requirement is the bundle id plus the team, so rebuilds keep the
microphone permission. `LVA_SIGN_IDENTITY=-` signs ad hoc: it works, but every
rebuild is a new app for macOS, which asks for the microphone again, and the
login item may not register reliably; `install` refuses ad hoc unless it is set
explicitly. The app is not notarized: it is built locally and never quarantined.
The scripts use Apple's toolchain even inside the Nix dev shell (they drop the Nix
`DEVELOPER_DIR`, `SDKROOT` and `xcrun`).

## Configuration

`satellite.json` says how to start the Python satellite:

| Key | Meaning |
| --- | --- |
| `python` | absolute path of the interpreter, `<repo>/.venv/bin/python` |
| `cwd` | absolute working directory, the repository |
| `args` | the full argument list; the app adds nothing, so the same command runs by hand |
| `env` | extra environment (`LVA_LIBMPV_DIR`, `PYTHONUNBUFFERED`) |
| `socket` | socket path, default `~/Library/Application Support/ha-satellite/audio.sock` |
| `agc` | voice-processing automatic gain, default `false`; read at app start (quit and reopen to compare) |

The example's arguments: `--name`, `--mac-address` (pinned identity), `--host
0.0.0.0` (listen on every interface, advertise the detected address),
`--follow-network` (reconnect and announce again after sleep or an address
change), `--audio-input-socket`, `--audio-output-socket` and `--control-socket`
(all three on the app's socket), `--persist-mute` (Listening off survives
restarts), `--disable-peripheral-api`, and the preferences and downloads in the
support directory. A test parses them with LVA's own parser, so they stay valid.

Paths must be absolute: at login the app gets a minimal environment, without the
Nix shell. Without `satellite.json` the app only serves the socket.

## First run and permissions

- **Microphone**: asked at the first start, after a dialog explaining why. The app
  captures the microphone itself; Python never opens it. If it was refused,
  Troubleshooting > Microphone Access… opens the right System Settings pane. To
  ask again from scratch: `tccutil reset Microphone io.iostud.ha-satellite`.
- **Local Network**: asked the first time the satellite announces itself to Home
  Assistant (mDNS). It is attributed to HA Satellite, the parent of the Python
  process, so Python upgrades need no new permission. Then add the satellite in
  Home Assistant (Settings > Devices & services, discovered ESPHome device).
- **Open at Login**: offered at the first start, then in the menu. It appears in
  System Settings > General > Login Items & Extensions > Open at Login.
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
Home Assistant disconnected for more than 30 s, `satellite.json` invalid).

## Listening, sleep, lid and battery

- **While listening, the Mac never goes to sleep on its own.** macOS keeps the
  system awake while any app records audio, and the satellite always records to
  hear the wake word. The display still turns off as usual, and the orange
  microphone indicator stays on.
- **Battery**: on battery this drains it like any recording app would, all day.
  Turn listening off when you do not need the satellite.
- **Turn off Listen for Wake Word** to let it sleep again. The microphone is
  released five seconds later, the orange indicator goes away and the Mac sleeps
  on its own again. The satellite stays connected to Home Assistant and still plays
  announcements (through an output-only engine, without opening the microphone),
  and Talk Now still works. The setting is kept across restarts (`--persist-mute`).
- **Sleeping on purpose** (Apple menu, power button, `pmset sleepnow`) or **closing
  the lid** puts the Mac to sleep as usual. The satellite is told first, sends its
  mDNS goodbye and shows as unavailable in Home Assistant while the Mac sleeps; it
  is back within a few seconds of waking.
- **Lid closed with an external display** (clamshell mode): the Mac stays awake but
  the built-in microphone is switched off by the hardware, so the satellite hears
  nothing until the lid opens.
- **Dock and Wi-Fi**: the pinned MAC address keeps one device in Home Assistant;
  with `--follow-network` the satellite announces its new address and Home
  Assistant reconnects.

## Talk Now, the Dictation key and Siri

macOS has no setting or API that makes another app the voice assistant, in the EU
or elsewhere. What works instead:

1. Turn Siri off in System Settings > Apple Intelligence & Siri, so one assistant
   answers. The app only reads this setting (Replace Siri… shows it and opens the
   pane); it never changes it.
2. Use the wake word for hands-free requests.
3. Use **Talk Now** (⌃⌥Space by default), which works even with the wake word off:
   the Mac can then sleep, and a key starts a conversation, like Siri's shortcut.
4. Optionally, choose **Dictation Key (F5)** as the shortcut. The app then remaps
   the Dictation key of the built-in keyboard to F19 with `hidutil` (user level, no
   administrator rights, gone after a reboot, so the app applies it again at start
   and after wake) and listens for F19. While the option is on, the key no longer
   starts macOS Dictation; choosing another shortcut, quitting or uninstalling
   gives it back. Other key remaps are kept. Off by default and not yet tried on
   every keyboard.

Not possible or rejected: the Globe (fn) key (consumed by the system), Siri's own
shortcut (needs Input Monitoring or Accessibility), Shortcuts and Spotlight actions
(App Intents need an Xcode project build).

## Logs and files

| Path | Content |
| --- | --- |
| `~/Library/Application Support/ha-satellite/` | `satellite.json`, `audio.sock`, `audio.lock`, `run/satellite.pid`, the satellite's preferences and downloads (directory mode 0700) |
| `~/Library/Logs/HA Satellite/satellite.log` | the Python satellite's output (rotated above 10 MB, one `.1` kept) |
| `~/Library/Logs/HA Satellite/app.log` | the app: engine starts, connections, child exits and restarts, menu state |

`just mac-logs` follows both; Troubleshooting > Open Logs opens the folder;
`log stream --predicate 'subsystem == "io.iostud.ha-satellite"'` shows the app's
log live. For development, `HA_SATELLITE_HOME` and `HA_SATELLITE_LOGS` move these
directories (the first-run dialog is then skipped), and Troubleshooting > Run
Satellite Process off lets you start the Python satellite by hand against the
running app (the `args` of `satellite.json`, from the repository).

## Uninstall

```sh
just mac-uninstall           # unregister the login item, quit, delete the app
just mac-uninstall --purge   # also delete the configuration, preferences and logs
```

The Dictation key remap is removed too. Deleting the app without `uninstall`
leaves a stale Login Items entry. The command prints how to forget the
permissions (`tccutil reset Microphone io.iostud.ha-satellite`; Local Network in
System Settings). `.venv/` is left in the repository.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Menu says the configuration is invalid | the message names the key or placeholder; `just mac-status` shows the same |
| Satellite not running, restarting | `satellite.log`: a wrong `python` path, a missing libmpv (`LVA_LIBMPV_DIR`), an invalid MAC; the app restarts it after 2, 5, 10, then 30 s |
| Microphone not authorized | Troubleshooting > Microphone Access…; after an ad hoc rebuild the grant is gone |
| Home Assistant never finds it | Local Network permission for HA Satellite; same network; Wi-Fi client isolation; `satellite.log` shows the advertised address |
| Two devices in Home Assistant | the MAC changed: set `--mac-address` to the Wi-Fi MAC and delete the extra device |
| The satellite answers itself | TTS must go through the app (`--audio-output-socket`); run `just mac-echo-test` (quit the app first) |
| The Mac does not sleep | expected while listening; turn off Listen for Wake Word, then `pmset -g assertions` should show no `coreaudiod` hold after 5 s |
| No sound after a device change | the engine is rebuilt 1.5 s after a device change; `app.log` shows it; Troubleshooting > Restart Satellite |
| Leftover satellite after a crash | the next app start stops it through `run/satellite.pid`; without the app, the satellite exits 30 s after losing the control connection |

Device checks, with the app quit (they open their own audio engine):

- `just mac-selftest [--no-play]`: captures 1.5 s through voice processing and
  prints the formats and level, then plays a 0.3 s tone at -30 dBFS through the
  same engine.
- `just mac-echo-test`: in a quiet room, at your usual volume, plays 3 s of white
  noise at -20 dBFS through the engine twice, without and then with voice
  processing, prints the ambient level and the level while playing for each, and
  the echo removed (the levels while playing). It fails below 15 dB, or when the
  noise was barely heard without voice processing (volume too low). On the
  development Mac, at 50 % volume, about 32 dB was removed.

## Known limitations

- Music is played by libmpv, outside the echo canceller: it is reduced (about
  24 dB) but not removed from what the microphone hears.
- Pausing a text-to-speech item drops what the app had queued, so up to 200 ms
  are skipped when it resumes.
- The app does not relaunch itself after a crash (`SMAppService` login items are
  not kept alive); the satellite then exits after 30 s, so Home Assistant shows it
  unavailable rather than deaf.
- The first voice-processing start takes about two seconds; the socket handshakes
  are answered at once, and audio waits for the engine (up to 3 s).

## Command line

`HA Satellite.app/Contents/MacOS/HASatellite`:

- no option: the menu bar app
- `--status`: JSON with the login item, permissions, configuration, devices and
  satellite pid
- `--unregister`: remove the login item and the Dictation key remap
- `--selftest [--no-play]`, `--echo-test`: the device checks above
- `--version`

## Socket protocol

One Unix socket, one connection per role: `mic` (16 kHz mono s16, numbered 10 ms
frames), `play:<name>` (TTS and sounds, paced by the app's `buffer_ms` of 200 ms)
and `control` (state snapshots from Python, explicit commands from the app:
`mute_mic`, `unmute_mic`, `start_listening` with `allow_muted`, `stop_pipeline`).
Frames have an 8-byte header and a 64 KiB cap; the HELLO `proto` is 1. The shared
fixtures in [`tests/fixtures/helper_protocol/`](../tests/fixtures/helper_protocol/)
are read by the Swift tests and the Python tests, so both sides encode the same
bytes.

Details both sides rely on:
- `mic` HELLO reply: `vp`, `agc`, `capturing`, `input_device`, `output_device`,
  `rate_in`, `helper_version`; every HELLO reply has `accepted`, and a refused one
  has `reason` (`unsupported_proto`, `unknown_role`, `unsupported_format`)
- `mic` events: `capture_paused`, `capture_resumed`, `overrun`, `permission_denied`,
  `no_input_device`, `engine_restarted`, `device_changed` (with `device`),
  `will_sleep`, `did_wake`, `network_changed`; Python answers `will_sleep` with
  `EVENT sleep_ready` (the app waits at most 2 s)
- `protocol_error` EVENT (with `error` and `msg`) before closing a connection on a
  malformed frame
- `control`: the app defines no command for Python; any command Python sends is
  answered with `{"ack": id, "ok": false, "reason": "unknown_command"}`
- a play item cut by an audio engine change gets `EVENT interrupted`; the rest of
  the item is dropped and `DRAINED` follows its `END`
- a play connection may go unread for up to 3 s while an engine starts; both sides
  close a connection whose sends stay blocked for 5 s

## Development

```sh
cd macos/HASatellite
swift build
swift test
```

`Sources/SatelliteCore` holds everything testable without a device (protocol,
audio rules, playback accounting, supervisor, configuration, menu model, key
remap); `Sources/HASatellite` is the AppKit shell (menu, hotkey, login item, power
events, command line). The tests use a fake audio engine behind a real Unix
socket, and `/bin/sh` scripts as the supervised child. CI runs them on
`macos-latest` together with the Python suite installed from `requirements.txt`.
