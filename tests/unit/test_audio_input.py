"""Tests for the microphone side of process_audio on Linux and macOS."""

import sys

import numpy as np
import pytest

import linux_voice_assistant.__main__ as lva_main
from tests.unit.conftest import make_state


class _StopRecording(BaseException):
    """Ends process_audio from inside record(); not caught by its handlers."""


class FakeMicrophone:
    """soundcard microphone that returns a few silent blocks, then stops."""

    def __init__(self, channels: int = 1, blocks: int = 1, name: str = "Fake Mic") -> None:
        self.name = name
        self.channels = channels
        self.blocks = blocks
        self.recorder_kwargs: dict = {}
        self.record_calls: list = []

    def recorder(self, **kwargs):
        self.recorder_kwargs = kwargs
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def record(self, numframes):
        self.record_calls.append(numframes)
        if len(self.record_calls) > self.blocks:
            raise _StopRecording()
        return np.zeros((numframes, self.recorder_kwargs.get("channels", 1)), dtype=np.float32)


def run_process_audio(state, mic, block_size: int = 1024) -> None:
    with pytest.raises(_StopRecording):
        lva_main.process_audio(state, mic, block_size)


class TestDeviceBlocksize:
    def test_linux_keeps_the_block_size(self, monkeypatch):
        monkeypatch.setattr(sys, "platform", "linux")
        assert lva_main._device_blocksize(1024) == 1024

    def test_darwin_lets_coreaudio_choose(self, monkeypatch):
        monkeypatch.setattr(sys, "platform", "darwin")
        assert lva_main._device_blocksize(1024) is None

    def test_process_audio_soundcard_args(self, tmp_path):
        state = make_state(tmp_path, audio_input_channels=1)
        state.satellite = None
        mic = FakeMicrophone()

        run_process_audio(state, mic)

        expected_blocksize = None if sys.platform == "darwin" else 1024
        assert mic.recorder_kwargs == {"samplerate": 16000, "channels": 1, "blocksize": expected_blocksize}
        assert mic.record_calls == [1024, 1024]

    def test_read_size_is_independent_of_device_buffer(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sys, "platform", "darwin")
        state = make_state(tmp_path, audio_input_channels=1)
        state.satellite = None
        mic = FakeMicrophone()

        run_process_audio(state, mic, block_size=2048)

        assert mic.recorder_kwargs["blocksize"] is None
        assert mic.record_calls[0] == 2048
