"""Run the real main() with fake audio, players, network and zeroconf.

Used by subprocess tests: ``python -m tests.harness.run_main MODE DIR``.
MODE is ``serve`` (a working microphone) or ``audio-fail`` (the microphone
fails to open). Nothing is advertised and nothing leaves the loopback.
"""

import sys
import time
from unittest.mock import MagicMock, patch

import numpy as np

import linux_voice_assistant.__main__ as lva_main


def say(line: str) -> None:
    print(line, flush=True)


class FakeMicrophone:
    name = "Harness Mic"
    channels = 1

    def __init__(self, fail: bool) -> None:
        self.fail = fail

    def recorder(self, **_kwargs):
        if self.fail:
            raise RuntimeError("harness: microphone unavailable")
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def record(self, numframes):
        time.sleep(0.01)
        return np.zeros((numframes, 1), dtype=np.float32)


class FakeZeroconf:
    def __init__(self, **kwargs) -> None:
        self.kwargs = kwargs

    async def register_server(self) -> None:
        say("registered")

    async def async_close(self) -> None:
        say("goodbye")


def main() -> None:
    mode, work_dir = sys.argv[1], sys.argv[2]
    argv = [
        "linux-voice-assistant",
        "--host",
        "127.0.0.1",
        "--port",
        "0",
        "--disable-peripheral-api",
        "--preferences-file",
        f"{work_dir}/preferences.json",
        "--download-dir",
        f"{work_dir}/downloads",
    ]
    with (
        patch.object(sys, "argv", argv),
        patch.object(lva_main.sc, "default_microphone", return_value=FakeMicrophone(fail=mode == "audio-fail")),
        patch.object(lva_main, "MpvMediaPlayer", MagicMock()),
        patch.object(lva_main, "HomeAssistantZeroconf", FakeZeroconf),
        patch.object(lva_main.network, "default_interface", return_value="lo"),
        patch.object(lva_main, "get_mac_address", return_value="02:00:00:00:00:01"),
    ):
        lva_main.run()


if __name__ == "__main__":
    main()
