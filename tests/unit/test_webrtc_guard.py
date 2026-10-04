"""Tests for running with and without webrtc-noise-gain (installed on Linux only)."""

import logging
import sys
from unittest.mock import MagicMock, patch

import pytest

import linux_voice_assistant.__main__ as lva_main
from linux_voice_assistant import webrtc
from tests.unit.conftest import install_requirements, make_satellite, make_state
from tests.unit.test_audio_input import FakeMicrophone, run_process_audio

linux_only = pytest.mark.skipif(not sys.platform.startswith("linux"), reason="webrtc-noise-gain is installed on Linux only")
darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="checks the macOS install, runs on macOS only")

# Entities of a satellite with webrtc-noise-gain, as upstream b49fd8d creates
# them: (class, key, object_id); the three sensitivity numbers are mocked.
_UPSTREAM_ENTITIES = [
    ("MediaPlayerEntity", 0, "linux_voice_assistant_media_player"),
    ("MuteSwitchEntity", 1, "mute"),
    ("ThinkingSoundEntity", 2, "thinking_sound"),
    ("MicSettingEntity", 6, "mic_gain"),
    ("MicSettingEntity", 7, "mic_noise"),
    ("MicSettingEntity", 8, "mic_volume"),
]


def _entities(satellite) -> list:
    return [(type(entity).__name__, entity.key, entity.object_id) for entity in satellite.state.entities if not isinstance(entity, MagicMock)]


class TestDependencyMarkers:
    def test_linux_installs_webrtc_noise_gain(self):
        assert "webrtc-noise-gain" in install_requirements("linux")

    def test_macos_does_not_install_webrtc_noise_gain(self):
        assert "webrtc-noise-gain" not in install_requirements("darwin")


class TestEntities:
    def test_entities_unchanged_with_webrtc(self, tmp_path):
        with patch("linux_voice_assistant.webrtc.AVAILABLE", True):
            satellite = make_satellite(tmp_path)

        assert _entities(satellite) == _UPSTREAM_ENTITIES

    def test_gain_and_noise_hidden_without_webrtc(self, tmp_path):
        with patch("linux_voice_assistant.webrtc.AVAILABLE", False):
            satellite = make_satellite(tmp_path)

        assert satellite.state.mic_gain_entity is None
        assert satellite.state.mic_noise_suppression_entity is None
        assert [object_id for _, _, object_id in _entities(satellite)] == ["linux_voice_assistant_media_player", "mute", "thinking_sound", "mic_volume"]


class TestProcessAudioWithoutWebrtc:
    def test_audio_keeps_flowing_when_webrtc_is_missing(self, tmp_path, caplog):
        state = make_state(tmp_path, audio_input_channels=1)
        state.preferences.mic_auto_gain = 5
        state.satellite = MagicMock()
        mic = FakeMicrophone(blocks=3)

        with patch.object(lva_main, "WebRTCProcessor", side_effect=ImportError("no webrtc_noise_gain")) as processor, caplog.at_level(logging.WARNING):
            run_process_audio(state, mic)

        processor.assert_called_once_with(agc_level=5, ns_level=0)
        assert state.satellite.handle_audio.call_count == 3
        assert caplog.text.count("webrtc-noise-gain is not installed") == 1

    def test_webrtc_applied_when_available(self, tmp_path):
        state = make_state(tmp_path, audio_input_channels=1)
        state.preferences.mic_noise_suppression = 2
        state.satellite = MagicMock()
        mic = FakeMicrophone(blocks=2)
        processed = b"\x01\x00" * 1024

        with patch.object(lva_main, "WebRTCProcessor") as processor:
            processor.return_value.process.return_value = processed
            run_process_audio(state, mic)

        processor.assert_called_once_with(agc_level=0, ns_level=2)
        processor.return_value.update_settings.assert_called_once_with(0, 2)
        assert state.satellite.handle_audio.call_args.args[0] == processed

    def test_webrtc_not_built_when_disabled(self, tmp_path):
        state = make_state(tmp_path, audio_input_channels=1)
        state.satellite = MagicMock()

        with patch.object(lva_main, "WebRTCProcessor") as processor:
            run_process_audio(state, FakeMicrophone(blocks=2))

        processor.assert_not_called()


class TestRequireWebrtc:
    def test_missing_package_exits_with_platform_message_on_darwin(self, monkeypatch, caplog):
        monkeypatch.setattr(sys, "platform", "darwin")
        with patch.dict(sys.modules, {"webrtc_noise_gain": None}), pytest.raises(SystemExit) as exited:
            lva_main._require_webrtc()

        assert exited.value.code == 1
        assert "not available on this platform" in caplog.text

    def test_missing_package_exits_on_linux(self, monkeypatch, caplog):
        monkeypatch.setattr(sys, "platform", "linux")
        with patch.dict(sys.modules, {"webrtc_noise_gain": None}), pytest.raises(SystemExit) as exited:
            lva_main._require_webrtc()

        assert exited.value.code == 1
        assert "Extras for webrtc are not installed" in caplog.text

    def test_installed_package_passes(self):
        with patch.dict(sys.modules, {"webrtc_noise_gain": MagicMock()}):
            lva_main._require_webrtc()


class TestAvailability:
    @linux_only
    def test_webrtc_available_on_linux(self):
        assert webrtc.AVAILABLE is True

    @darwin_only
    def test_webrtc_absent_on_macos(self):
        assert webrtc.AVAILABLE is False
