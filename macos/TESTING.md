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
   with the team), creates `.venv`, and stops at the placeholders. Set them
   (`just mac-config --force --name … --mac … --libmpv …`) and open the app.
3. **First run**: the explanation dialog, then the microphone prompt naming
   HA Satellite; accept "Open at Login" and check System Settings > General >
   Login Items. The Local Network prompt names HA Satellite (write down the exact
   name shown). One app (`pgrep -x HASatellite`), one Python child
   (`pgrep -fl linux_voice_assistant`).
4. **Discovery**: Home Assistant discovers the satellite under the chosen name;
   adopt it. The device's MAC is the Wi-Fi MAC given in `satellite.json`.
   `just mac-status` shows the login item enabled, the microphone authorized and
   the satellite running.

## Voice

5. **Wake word**: say it; the wake sound plays, the request is transcribed and the
   answer is spoken on the built-in speakers. The menu icon fills during the
   conversation.
6. **Echo**: ask something with a long answer and say nothing: the answer is not
   transcribed as a new request, and a continued conversation does not hear the
   end of its own answer. Say the wake word, then the stop word, during a long
   answer: it stops.
7. **Announce**: `assist_satellite.announce` with a message: it plays, with the
   preannounce sound.
8. **Start conversation**: `assist_satellite.start_conversation`: the message
   plays, then the satellite listens for the answer without a wake word.
9. **Ask question**: `assist_satellite.ask_question` with answers: the reply is
   matched and returned to the action.
10. **Timers**: set a one-minute timer by voice; it rings with the timer sound,
    the bell icon shows; the stop word, Talk Now and Stop in the menu each stop it
    (one try each).
11. **Volume and music**: change the media player volume from Home Assistant;
    TTS follows. Play music through the media player, say the wake word over it:
    note how often it triggers (music is only partly cancelled).

## Listening switch and Talk Now

12. **Mute sync**: turn off Listen for Wake Word in the menu: the satellite's mute
    switch turns on in Home Assistant, the mute sound plays, the orange indicator
    goes away within about 5 s. Turn the switch off in Home Assistant: the menu
    item is checked again and the indicator comes back. Repeat during a
    conversation, and while Home Assistant is restarting (the switch catches up on
    reconnect).
13. **Persisted mute**: with listening off, Troubleshooting > Restart Satellite,
    then quit and reopen the app: listening stays off.
14. **Talk Now**: press ⌃⌥Space with listening on, then off: a conversation starts
    each time, and the microphone is released again afterwards when listening is
    off. Press it during an answer: it stops. With listening off, an announcement
    plays without the orange indicator.
15. **Dictation key** (optional): choose Dictation Key (F5) as the shortcut; F5
    starts a conversation instead of Dictation. Choose ⌃⌥Space again, quit, and
    after a reboot: F5 starts Dictation again (`hidutil property --get
    UserKeyMapping` has no entry left from the app).

## Sleep, wake and networks

16. **Idle sleep**: listening on: `pmset -g assertions` shows the audio hold and
    the Mac does not idle-sleep. Listening off: no hold from the app after 5 s,
    and the Mac idle-sleeps at its usual time.
17. **Sleep and wake**: `pmset sleepnow`, then the lid closed for 2 and for 30
    minutes. Home Assistant shows the satellite unavailable within seconds; after
    wake it is back in under 10 s and the wake word works (timestamps from
    `satellite.log` and Home Assistant's history).
18. **Dark wakes**: overnight with Power Nap on, Home Assistant's history shows no
    availability flapping.
19. **Clamshell**: lid closed with an external display: `no_input_device` in
    `app.log`, the satellite stays connected and deaf; opening the lid restores
    it.
20. **Dock and Wi-Fi**: unplug the dock (wired network to Wi-Fi) and plug it back:
    one device in Home Assistant, which reconnects within 30 s each time; the wake
    word works on both. With a VPN on, the advertised address stays the LAN one.
21. **Audio devices**: plug headphones, then a Bluetooth headset, then unplug: the
    engine is rebuilt (`app.log`), the satellite keeps working on the built-in
    microphone or the new device.

## Supervision and removal

22. **Child crash**: `kill -9` the Python child: restarted within 2 s, Home
    Assistant reconnects.
23. **App crash**: `kill -9` the app: the satellite exits about 30 s later and Home
    Assistant shows it unavailable (the app is not relaunched by macOS). Open the
    app: one new child, the old one is gone.
24. **Quit**: menu Quit: app and child gone within 10 s, goodbye in the log, Home
    Assistant shows unavailable; nothing restarts until the next login. Log out
    and in: back without prompts.
25. **Soak**: 24 hours running: CPU and memory of both processes, log sizes and
    rotation, the number of reconnects.
26. **Uninstall**: turn Open at Login off, `just mac-uninstall`: nothing left
    running, no Login Items entry.
