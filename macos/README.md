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
- To run: nothing else. The app is self-contained: Python, the satellite and its
  dependencies, and libmpv are inside it.
- To build: Xcode (for `swift build` and `swift test`; no Xcode project is used),
  libmpv and its FFmpeg (`brew install mpv pkgconf`, or a directory holding
  `libmpv.dylib` in `LVA_LIBMPV_DIR` with the `pkg-config` directory of the
  FFmpeg it links in `LVA_FFMPEG_PKGCONFIG`), network access for the first
  build, and a "Developer ID
  Application" signing identity in the keychain (or see Signing)

## Download a build from GitHub

Every push runs the macOS job of the
[Test matrix workflow](https://github.com/pciavald/ha-satellite/actions/workflows/test.yml),
which builds the app and keeps it 30 days as the artifact
`HA-Satellite-macos-arm64.zip`:

1. open the run (Actions > Test matrix > the run of your commit), scroll to
   **Artifacts** and download `HA-Satellite-macos-arm64.zip` (signed in to GitHub);
2. unzip it and move `HA Satellite.app` to `~/Applications` or `/Applications`.

These builds are signed ad hoc, not with a Developer ID, and not notarized, so
macOS refuses the first opening. Either remove the quarantine before opening it:

```sh
xattr -dr com.apple.quarantine ~/Applications/HA\ Satellite.app
```

or open it once, then allow it in System Settings > Privacy & Security ("Open
Anyway"; right-click > Open does the same on older macOS). An ad hoc signature
identifies one build only: the microphone permission and the login item are tied
to that build, and each new download asks for the microphone again (System
Settings may keep a stale HA Satellite entry; `tccutil reset Microphone
io.iostud.ha-satellite` clears it).

## Install from the repository

```sh
just mac-install            # or: macos/build.sh install
```

This:

1. builds the self-contained app (see Bundle) and signs it with the keychain's
   Developer ID Application identity (hardened runtime);
2. checks it (`just mac-check`, below);
3. copies it to `~/Applications/HA Satellite.app`, after checking that no other
   copy of `io.iostud.ha-satellite` exists (duplicates confuse the login item);
4. opens it.

Nothing needs configuring: the satellite is named after the Mac (change it with
Name… in the menu) and the network values are detected (Configuration). The
other commands: `just mac-build`, `mac-check`, `mac-test` (Swift tests),
`mac-status`, `mac-selftest`, `mac-echo-test`, `mac-logs`, `mac-uninstall`
(`macos/build.sh help` lists them).

Reinstalling over the same path keeps the permissions and the login item.

**Signing.** The identity is `LVA_SIGN_IDENTITY` when set, otherwise the first
"Developer ID Application" identity of the keychain. Every nested binary is
signed first, inside-out (the libraries and Python extension modules, then the
interpreter), then the app with the microphone entitlement; with a Developer ID
all of them use the hardened runtime. No other entitlement is needed: library
validation only asks that the libraries the interpreter loads (ctypes, libmpv)
have the same team, which they do. With a Developer ID the designated
requirement is the bundle id plus the team, so rebuilds keep the microphone
permission. `LVA_SIGN_IDENTITY=-` signs ad hoc, as CI does: ad hoc signatures
have no team, so the nested code is then signed without the hardened runtime.
It works, but every rebuild is a new app for macOS, which asks for the
microphone again, and the login item may not register reliably; `install`
refuses ad hoc unless it is set explicitly. Local builds are not notarized: they
are never quarantined. The scripts use Apple's toolchain even inside the Nix dev
shell (they drop the Nix `DEVELOPER_DIR`, `SDKROOT` and `xcrun`).

## Bundle

`just mac-build` assembles `macos/HASatellite/.build/HA Satellite.app`:

| Path in `Contents/` | Content |
| --- | --- |
| `MacOS/HASatellite` | the menu bar app |
| `Resources/python/` | [python-build-standalone](https://github.com/astral-sh/python-build-standalone) CPython 3.13, pinned by release and SHA-256 in `build.sh` (downloaded once into `~/Library/Caches/ha-satellite-build`), with the exact versions of [`requirements.txt`](requirements.txt) in its `site-packages` (binary wheels, except PyAV); pip, headers, Tk and IDLE are removed |
| `Resources/lva/` | `linux_voice_assistant`, `wakewords` and `sounds` from the repository, found through `site-packages/lva.pth` |
| `Frameworks/` | `libmpv.dylib` and every library it needs, from `LVA_LIBMPV_DIR` or Homebrew, rewritten by [`bundle.py`](bundle.py) to load each other through `@loader_path`, without rpaths; PyAV's modules load the same FFmpeg from here |

PyAV (which decodes TTS and sounds for the app) is built from source against
the FFmpeg libmpv links, and its modules are relinked to `Frameworks/`. Its
binary wheel carries a private FFmpeg: next to libmpv's, one process would load
two copies (macOS warns about duplicate Objective-C classes, and the two can
disagree). Building against the copy already bundled keeps the decoder that the
tests run, without relinking a binary to libraries it was not built against
(the wheel's FFmpeg is often a newer minor version), and without a second
decoding path through libmpv. The build fails when the bundle holds two copies
of an FFmpeg library.

Everything is compiled to bytecode at build time (unchecked hashes), and the
satellite runs with `-B`, so nothing is ever written into the signed bundle. The
build fails when a binary of the bundle is not arm64 or loads a library from
outside the bundle and the system (`bundle.py check`). `just mac-check` runs that
check again, then [`smoke.py`](smoke.py) with the bundled interpreter as the app
starts it: it imports LVA and its native dependencies, opens libmpv, checks
that every FFmpeg library is loaded once, from `Frameworks/`, decodes a bundled
sound with PyAV, loads a
microWakeWord and an openWakeWord model and calls a ctypes callback (nothing is
advertised, no socket is opened), and runs `-m linux_voice_assistant --help`.
The app is about 300 MB. To update a pin: `requirements.txt` (regenerated with
the command at its top), or `python_version`, `python_release` and
`python_sha256` in `build.sh` (the release's `SHA256SUMS`).

## Configuration

The app starts the bundled interpreter itself:

```
Contents/Resources/python/bin/python3 -I -B -u -m linux_voice_assistant
  --name NAME --host 0.0.0.0 --mac-address WIFI_MAC --follow-network
  --audio-input-socket SOCKET --audio-output-socket SOCKET --control-socket SOCKET
  --persist-mute --disable-peripheral-api
  --preferences-file SUPPORT/preferences.json --download-dir SUPPORT/downloads
```

with `LVA_LIBMPV_DIR` set to `Contents/Frameworks`, the working directory
`~/Library/Application Support/ha-satellite` (SUPPORT) and the socket
`SUPPORT/audio.sock`. `-I` isolates it from the environment (no `PYTHONPATH`,
no user site-packages). `app.log` and `just mac-status` show the exact command.

- **Name**: the Mac's computer name until one is chosen with Name… in the menu.
- **MAC address**: the permanent address of the built-in Wi-Fi (SystemConfiguration,
  the lowest numbered Wi-Fi interface; on a Mac without Wi-Fi, the built-in
  Ethernet `en0`; never a dock or adapter). Pinning it keeps one device in Home
  Assistant when the Mac moves between Wi-Fi and a dock. The menu shows it
  ("Network: Wi-Fi en0, aa:bb:…"). Without a built-in interface the option is
  left out and LVA uses the active interface's address.
- `--host 0.0.0.0` listens on every interface and advertises the detected
  address; `--follow-network` reconnects and announces again after sleep or an
  address change.

`~/Library/Application Support/ha-satellite/satellite.json` is optional, and
every key in it is optional:

| Key | Meaning |
| --- | --- |
| `name` | the satellite's name in Home Assistant, written by Name… (1 to 64 characters, no control characters) |
| `mac_address` | overrides the detected address |
| `host` | overrides `0.0.0.0` |
| `follow_network` | `false` leaves out `--follow-network` |
| `extra_args` | more LVA flags, appended (for example `["--debug"]`) |
| `env` | extra environment, over the app's |
| `python`, `cwd` | development: another interpreter (a repository's venv, without `-I -B`) and working directory |
| `socket` | socket path |
| `agc` | voice-processing automatic gain, default `false`; read at app start (quit and reopen to compare) |

Keys starting with `_` are ignored. An invalid file stops the satellite and the
menu says why. A test parses the app's arguments with LVA's own parser
(`tests/fixtures/macos_app/command.json`, shared by the Swift and Python tests),
so they stay valid.

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

- Title and status lines: the satellite's name, Home Assistant connection,
  microphone, satellite process, and the network identity (interface and MAC
  address the satellite announces).
- **Listen for Wake Word**: the satellite's mute switch in Home Assistant, inverted,
  kept in sync both ways. Turning it off releases the microphone (see Sleep).
- **Talk Now** (default ⌃⌥Space): starts a conversation even when the wake word is
  off; pressed during a conversation or a ringing timer, it stops it. **Stop**
  appears while a conversation or timer runs.
- **Talk Now Shortcut**: ⌃⌥Space, ⌃⌥⌘Space, ⌃⇧Space, the Dictation key (F5), or none.
- **Name…**: the satellite's name in Home Assistant. It is saved in
  `satellite.json` and the satellite restarts to announce it; Home Assistant
  keeps the same device (same MAC address) under the new name.
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
- **Dock and Wi-Fi**: the pinned Wi-Fi MAC address keeps one device in Home Assistant;
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
| `~/Library/Application Support/ha-satellite/` | `satellite.json` (optional), `audio.sock`, `audio.lock`, `run/satellite.pid`, the satellite's preferences and downloads (directory mode 0700) |
| `~/Library/Logs/HA Satellite/satellite.log` | the Python satellite's output (rotated above 10 MB, one `.1` kept) |
| `~/Library/Logs/HA Satellite/app.log` | the app: engine starts, connections, child exits and restarts, menu state |

`just mac-logs` follows both; Troubleshooting > Open Logs opens the folder;
`log stream --predicate 'subsystem == "io.iostud.ha-satellite"'` shows the app's
log live. For development, `HA_SATELLITE_HOME` and `HA_SATELLITE_LOGS` move these
directories (the first-run dialog is then skipped), and Troubleshooting > Run
Satellite Process off lets you start the Python satellite by hand against the
running app (the command of `just mac-status`, or from a repository's venv).

## Uninstall

```sh
just mac-uninstall           # unregister the login item, quit, delete the app
just mac-uninstall --purge   # also delete the configuration, preferences and logs
```

The Dictation key remap is removed too. Deleting the app without `uninstall`
leaves a stale Login Items entry. The command prints how to forget the
permissions (`tccutil reset Microphone io.iostud.ha-satellite`; Local Network in
System Settings).

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Menu says the configuration is invalid | the message names the key; `just mac-status` shows the same |
| Satellite not running, restarting | `satellite.log`; `just mac-check` checks the bundle; the app restarts it after 2, 5, 10, then 30 s |
| "Damaged" or "cannot be opened" for a downloaded build | the quarantine of an ad hoc build: see Download a build from GitHub |
| Microphone not authorized | Troubleshooting > Microphone Access…; after an ad hoc rebuild the grant is gone |
| Home Assistant never finds it | Local Network permission for HA Satellite (`satellite.log` says "mDNS send refused" without it); same network; Wi-Fi client isolation; `satellite.log` shows the advertised address |
| Two devices in Home Assistant | the MAC changed: check the menu's Network line (or set `mac_address` in `satellite.json`) and delete the extra device |
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
- `play:tts` carries everything the satellite plays except music: TTS,
  announcements, and the wake, timer and mute sounds, so the echo canceller
  hears them all; music stays on libmpv. TTS URLs are read with up to 60 s
  without data (mpv's default network timeout): Home Assistant's `tts_proxy`
  answers only once the TTS engine has audio. A TTS keeps playing after the
  pipeline's RUN_END; stop, the stop word or a new item cancels it at once,
  even while it is still waiting for Home Assistant
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
`macos-latest` together with the Python suite installed from `requirements.txt`,
then builds the app ad hoc signed, runs `macos/build.sh check` on it and uploads
it (Download a build from GitHub).
