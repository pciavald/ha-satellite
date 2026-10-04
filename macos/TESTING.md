# End-to-end checks on a Mac

Manual checks of the macOS app against a real Home Assistant, to run after an
install or a change of the app, the socket protocol or the audio path. The unit
tests (Swift and Python, run by CI on Linux and macOS) cover the logic; these
cover what only the hardware, macOS and Home Assistant show.

Write the result of each step (ok, or what happened, with timestamps) next to it.

## Before starting

- An Assist pipeline in Home Assistant (wake word on the device, speech-to-text,
  conversation agent, text-to-speech) and a media player volume you can hear.
- Built-in speakers at the usual volume, a quiet room.
- Two terminals: `just mac-logs`, and one for the commands below.
- `pmset -g assertions` and `pmset -g log | tail` at hand for the sleep steps.

## Install and identity

1. **Echo test**, app not running yet: `just mac-build && just mac-echo-test`
   (allow the microphone for the terminal's run if asked). Expect at least 15 dB
   removed (about 32 dB at 50 % volume during development) and "OK". Repeat at
   80 % volume.
2. **Install**: `just mac-install`. It signs with the Developer ID (the output
   shows `signing with: Developer ID Application: …` and a designated requirement
   with the team), the check prints the bundled Python, mpv and the wake word
   models with "smoke test OK", and the app opens with no configuration.
   `otool -L` on `Contents/Frameworks/libmpv.dylib` lists only `@loader_path`
   and system libraries.
3. **First run**: the explanation dialog, then the microphone prompt naming
   HA Satellite; accept "Open at Login" and check System Settings > General >
   Login Items. The Local Network prompt names HA Satellite (write down the exact
   name shown). One app (`pgrep -x HASatellite`), one Python child
   (`pgrep -fl linux_voice_assistant`) running the bundled interpreter
   (`Contents/Resources/python/bin/python3`), with no brew or Nix path in its
   open libraries (`vmmap <pid> | grep -E 'homebrew|/nix/'` prints nothing).
4. **Discovery**: Home Assistant discovers the satellite under the Mac's name;
   adopt it. The device's MAC is the built-in Wi-Fi's, as the menu's Network line
   shows and `networksetup -listallhardwareports` confirms ("Ethernet Address"
   under Wi-Fi). `just mac-status` shows the login item enabled, the microphone
   authorized and the satellite running.
5. **Name**: menu Name…: an empty name and one of 65 characters are refused with
   the reason; a valid one is written to `satellite.json`, the title line shows
   it, the satellite restarts and Home Assistant shows the same device under the
   new name after it reconnects.
6. **Downloaded build** (optional, on a second account or after uninstalling):
   download `HA-Satellite-macos-arm64.zip` from the latest CI run, follow
   [Download a build from GitHub](README.md#download-a-build-from-github), and
   check that it starts and is discovered like the local build.

## Voice

7. **Wake word**: say it; the wake sound plays, the request is transcribed and the
   answer is spoken on the built-in speakers. The menu icon fills during the
   conversation. Start speaking at once, over the wake sound, and again with
   Talk Now over its sound: the first word is in the transcript (Home
   Assistant's debug view of the pipeline run, or `STT_END` in `satellite.log`).
   With **Finished speaking detection** set to Relaxed on the device page, a
   pause of about one second mid-sentence does not end the command; a command
   longer than 15 s is still cut (Home Assistant's limit, see the README).
8. **Echo**: ask something with a long answer and say nothing: the answer is not
   transcribed as a new request, and a continued conversation does not hear the
   end of its own answer. Say the wake word, then the stop word, during a long
   answer: it stops.
9. **Announce**: `assist_satellite.announce` with a message: it plays, with the
   preannounce sound.
10. **Start conversation**: `assist_satellite.start_conversation`: the message
   plays, then the satellite listens for the answer without a wake word.
11. **Ask question**: `assist_satellite.ask_question` with answers: the reply is
   matched and returned to the action.
12. **Timers**: set a one-minute timer by voice; it rings with the timer sound,
    the bell icon shows; the stop word, Talk Now and Stop in the menu each stop it
    (one try each).
13. **Volume and music**: change the media player volume from Home Assistant;
    TTS follows. Play music through the media player, say the wake word over it:
    note how often it triggers (music is only partly cancelled).

## Listening switch and Talk Now

14. **Mute sync**: turn off Listen for Wake Word in the menu: the satellite's mute
    switch turns on in Home Assistant, the mute sound plays, the orange indicator
    goes away within about 5 s. Turn the switch off in Home Assistant: the menu
    item is checked again and the indicator comes back. Repeat during a
    conversation, and while Home Assistant is restarting (the switch catches up on
    reconnect).
15. **Persisted mute**: with listening off, Troubleshooting > Restart Satellite,
    then quit and reopen the app: listening stays off.
16. **Talk Now**: press ⌃⌥Space with listening on, then off: a conversation starts
    each time, and the microphone is released again afterwards when listening is
    off. Press it during an answer: it stops. With listening off, an announcement
    plays without the orange indicator.
17. **Dictation key** (optional): choose Dictation Key (F5) as the shortcut; F5
    starts a conversation instead of Dictation. Choose ⌃⌥Space again, quit, and
    after a reboot: F5 starts Dictation again (`hidutil property --get
    UserKeyMapping` has no entry left from the app).

## Sleep, wake and networks

18. **Idle sleep**: listening on: `pmset -g assertions` shows the audio hold and
    the Mac does not idle-sleep. Listening off: no hold from the app after 5 s,
    and the Mac idle-sleeps at its usual time.
19. **Sleep and wake**: `pmset sleepnow`, then the lid closed for 2 and for 30
    minutes. Home Assistant shows the satellite unavailable within seconds; after
    wake it is back in under 10 s and the wake word works (timestamps from
    `satellite.log` and Home Assistant's history).
20. **Dark wakes**: overnight with Power Nap on, Home Assistant's history shows no
    availability flapping.
21. **Clamshell**: lid closed with an external display: `no_input_device` in
    `app.log`, the satellite stays connected and deaf; opening the lid restores
    it.
22. **Dock and Wi-Fi**: unplug the dock (wired network to Wi-Fi) and plug it back:
    one device in Home Assistant, which reconnects within 30 s each time; the wake
    word works on both. With a VPN on, the advertised address stays the LAN one.
23. **Audio devices**: plug headphones, then a Bluetooth headset, then unplug: the
    engine is rebuilt (`app.log`), the satellite keeps working on the built-in
    microphone or the new device.

## Supervision and removal

24. **Child crash**: `kill -9` the Python child: restarted within 2 s, Home
    Assistant reconnects.
25. **App crash**: `kill -9` the app: the satellite exits about 30 s later and Home
    Assistant shows it unavailable (the app is not relaunched by macOS). Open the
    app: one new child, the old one is gone.
26. **Quit**: menu Quit: app and child gone within 10 s, goodbye in the log, Home
    Assistant shows unavailable; nothing restarts until the next login. Log out
    and in: back without prompts.
27. **Soak**: 24 hours running: CPU and memory of both processes, log sizes and
    rotation, the number of reconnects.
28. **Uninstall**: turn Open at Login off, `just mac-uninstall`: nothing left
    running, no Login Items entry.
