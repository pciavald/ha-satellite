"""Loads every native part of the bundled satellite (macos/build.sh check).

Run with the bundle's interpreter, isolated (-I -B), LVA_LIBMPV_DIR set as the
app sets it: imports LVA and its dependencies, opens libmpv, loads a
microWakeWord and an openWakeWord model and calls a ctypes callback. Nothing
is advertised and no socket is opened.
"""

import ctypes
import sys
from pathlib import Path

import av
import numpy
import soundcard  # noqa: F401  (CoreAudio through cffi)
import zeroconf
from aioesphomeapi import APIClient  # noqa: F401
from chacha20poly1305_reuseable import ChaCha20Poly1305Reusable  # noqa: F401

import linux_voice_assistant.__main__  # noqa: F401
from linux_voice_assistant.player.libmpv import import_mpv
from linux_voice_assistant.wake_word import find_available_wake_words

lva = Path(linux_voice_assistant.__main__.__file__).resolve().parent.parent
bundle = Path(sys.executable).resolve().parents[2]
assert str(lva).startswith(str(bundle)), f"LVA comes from {lva}, outside {bundle}"
assert sys.flags.isolated and sys.dont_write_bytecode, "run with -I -B"

callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int)(lambda value: value + 1)
assert callback(41) == 42

mpv = import_mpv()
player = mpv.MPV(ao="null", vo="null", video=False)
mpv_version = player.mpv_version
player.terminate()

words = find_available_wake_words([lva / "wakewords", lva / "wakewords" / "openWakeWord"], "stop")
types = set()
for word_id in ("okay_nabu", "ok_nabu_v0.1"):
    word = words[word_id]
    word.load()
    types.add(word.type.value)

print(f"python {sys.version.split()[0]} at {sys.executable}")
print(f"{mpv_version}, numpy {numpy.__version__}, av {av.__version__}, zeroconf {zeroconf.__version__}")
print(f"wake word models loaded: {', '.join(sorted(types))}")
print("smoke test OK")
