"""How main() and process_audio use an external audio engine, and what stays the same without one."""

import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

import linux_voice_assistant.__main__ as lva_main
from linux_voice_assistant.helper_protocol import FrameType
from tests.unit.conftest import make_satellite, make_state
from tests.unit.fake_engine import FakeEngine, wait_until
from tests.unit.test_audio_input import FakeMicrophone, _StopRecording, run_process_audio
from tests.unit.test_linux_guard import _parse_cli

_REPO_DIR = Path(__file__).resolve().parents[2]

_ENGINE_MODULES = {
    "linux_voice_assistant.audio_source",
    "linux_voice_assistant.control",
    "linux_voice_assistant.helper_protocol",
    "linux_voice_assistant.player.helper",
}


def _streaming_satellite():
    satellite = MagicMock()
    satellite._is_streaming_audio = True
    satellite.state.sensitivity_1_number_entity = None
    satellite.state.sensitivity_2_number_entity = None
    satellite.state.stop_sensitivity_number_entity = None
    return satellite


class TestProcessAudio:
    def test_resumed_capture_restarts_the_wake_word_features(self, tmp_path):
        state = make_state(tmp_path)
        state.satellite = _streaming_satellite()
        answers = iter([False, True, False])

        with patch.object(lva_main, "MicroWakeWordFeatures") as features:
            features.return_value.process_streaming.return_value = []
            with pytest.raises(_StopRecording):
                lva_main.process_audio(state, FakeMicrophone(blocks=3), 160, resumed=lambda: next(answers))

        assert features.call_count == 2

    def test_without_resumed_the_features_are_kept(self, tmp_path):
        state = make_state(tmp_path)
        state.satellite = _streaming_satellite()

        with patch.object(lva_main, "MicroWakeWordFeatures") as features:
            features.return_value.process_streaming.return_value = []
            run_process_audio(state, FakeMicrophone(blocks=3), 160)

        assert features.call_count == 1

    def test_webrtc_skipped_when_the_source_already_processes(self, tmp_path):
        state = make_state(tmp_path, input_processing=("aec", "ns"))
        state.preferences.mic_auto_gain = 5
        state.satellite = None

        with patch.object(lva_main, "WebRTCProcessor") as processor:
            run_process_audio(state, FakeMicrophone(blocks=2), 160)

        processor.assert_not_called()

    def test_webrtc_still_used_with_soundcard(self, tmp_path):
        state = make_state(tmp_path)
        state.preferences.mic_auto_gain = 5
        state.satellite = None

        with patch.object(lva_main, "WebRTCProcessor") as processor:
            processor.return_value.process.return_value = b""
            run_process_audio(state, FakeMicrophone(blocks=2), 160)

        processor.assert_called_once_with(agc_level=5, ns_level=0)

    @pytest.mark.parametrize(("muted", "override", "stopped"), [(False, False, True), (True, False, False), (True, True, True)])
    def test_stop_word_gate(self, tmp_path, muted, override, stopped):
        state = make_state(tmp_path, muted=muted, mute_override=override)
        state.satellite = _streaming_satellite()
        state.active_wake_words.add("stop")
        state.stop_word.process_streaming.return_value = True

        with patch.object(lva_main, "MicroWakeWordFeatures") as features:
            features.return_value.process_streaming.return_value = [np.zeros(40)]
            run_process_audio(state, FakeMicrophone(blocks=1), 160)

        assert state.satellite.stop.called is stopped


class TestSatellite:
    def test_mic_processing_entities_hidden_when_the_source_processes(self, tmp_path):
        with patch("linux_voice_assistant.webrtc.AVAILABLE", True):
            plain = make_satellite(tmp_path)
            processed = make_satellite(tmp_path, state_overrides={"input_processing": ("aec", "ns")})

        assert plain.state.mic_gain_entity is not None and plain.state.mic_noise_suppression_entity is not None
        assert processed.state.mic_gain_entity is None and processed.state.mic_noise_suppression_entity is None
        assert processed.state.mic_volume_entity is not None

    def test_emit_without_control_channel_reaches_only_the_peripheral_api(self, tmp_path):
        satellite = make_satellite(tmp_path)
        satellite.state.peripheral_api = MagicMock()

        satellite._emit(lva_main.LVAEvent.IDLE, {"a": 1})

        satellite.state.peripheral_api.emit_event_sync.assert_called_once_with(lva_main.LVAEvent.IDLE, {"a": 1})

    def test_emit_fans_out_to_the_control_channel(self, tmp_path):
        satellite = make_satellite(tmp_path)
        satellite.state.control_channel = MagicMock()

        satellite._emit(lva_main.LVAEvent.IDLE)

        satellite.state.control_channel.on_event.assert_called_once_with(lva_main.LVAEvent.IDLE, None)

    def test_start_listening_refused_when_muted(self, tmp_path):
        satellite = make_satellite(tmp_path)
        satellite.state.muted = True

        assert satellite.start_listening() is False
        satellite.state.tts_player.play.assert_not_called()
        assert satellite.state.mute_override is False

    def test_muted_audio_is_dropped(self, tmp_path):
        satellite = make_satellite(tmp_path)
        satellite.send_messages = MagicMock()
        satellite._is_streaming_audio = True
        satellite.state.muted = True

        satellite.handle_audio(b"\x00\x00")

        satellite.send_messages.assert_not_called()

    def test_override_cleared_at_run_end_and_stop(self, tmp_path):
        from aioesphomeapi.model import VoiceAssistantEventType

        satellite = make_satellite(tmp_path)
        satellite.state.mute_override = True
        satellite.handle_voice_event(VoiceAssistantEventType.VOICE_ASSISTANT_RUN_END, {})
        assert satellite.state.mute_override is False

        satellite.state.mute_override = True
        satellite.stop()
        assert satellite.state.mute_override is False


class TestPersistMute:
    def test_not_persisted_by_default(self, tmp_path):
        satellite = make_satellite(tmp_path)
        satellite._set_muted(True)
        satellite.state.save_preferences()

        assert "muted" not in json.loads(satellite.state.preferences_path.read_text(encoding="utf-8"))

    def test_persisted_with_the_flag(self, tmp_path):
        satellite = make_satellite(tmp_path, state_overrides={"persist_mute": True})

        satellite._set_muted(True)

        assert json.loads(satellite.state.preferences_path.read_text(encoding="utf-8"))["muted"] is True


def _start_harness(tmp_path, *args):
    command = [sys.executable, "-m", "tests.harness.run_main", "serve", str(tmp_path), *args]
    return subprocess.Popen(command, cwd=_REPO_DIR, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)  # pylint: disable=consider-using-with


def _harness_modules(tmp_path, *args):
    process = _start_harness(tmp_path, *args)
    try:
        assert process.stdout is not None
        for line in process.stdout:
            if line.startswith("modules "):
                return set(json.loads(line[len("modules ") :]))
        raise AssertionError(process.stderr.read() if process.stderr else "")
    finally:
        process.terminate()
        process.wait(timeout=10)


class TestMain:
    def test_default_start_loads_no_engine_module_and_no_pyav(self, tmp_path):
        loaded = _harness_modules(tmp_path)

        assert "linux_voice_assistant.__main__" in loaded
        assert not loaded & _ENGINE_MODULES
        assert not [name for name in loaded if name.split(".")[0] == "av"]

    def test_engine_flags_connect_every_role(self, tmp_path):
        engine = FakeEngine()
        path = engine.path
        loaded = None
        try:
            process = _start_harness(tmp_path, "--audio-input-socket", path, "--audio-output-socket", path, "--control-socket", path, "--persist-mute")
            try:
                assert process.stdout is not None
                for line in process.stdout:
                    if line.startswith("modules "):
                        loaded = set(json.loads(line[len("modules ") :]))
                        break
                control = engine.role("control", timeout=15)
                wait_until(lambda: control.of_type(FrameType.CONTROL), timeout=15)
                snapshot = control.json_of_type(FrameType.CONTROL)[0]["state"]
                assert engine.role("mic").hello == {"proto": 1, "role": "mic"}
                assert engine.role("play:tts").hello["format"] == "s16le"
            finally:
                process.terminate()
                process.wait(timeout=10)
        finally:
            engine.close()

        # The control module is imported later, once the server runs
        assert loaded is not None and _ENGINE_MODULES - {"linux_voice_assistant.control"} <= loaded
        assert snapshot["muted"] is False and snapshot["rev"] == 1

    def test_missing_engine_stops_startup(self, tmp_path):
        process = _start_harness(tmp_path, "--audio-input-socket", "/tmp/lva-no-such-engine.sock")
        try:
            _out, err = process.communicate(timeout=30)
        finally:
            process.kill()

        assert process.returncode == 1
        assert "No audio engine at /tmp/lva-no-such-engine.sock" in err


class TestMacAppConfig:
    def test_example_arguments_are_lva_flags(self, monkeypatch, tmp_path):
        text = (_REPO_DIR / "macos" / "satellite.json.example").read_text(encoding="utf-8")
        values = {"REPO": str(_REPO_DIR), "SUPPORT": str(tmp_path), "NAME": "Mac", "MAC": "AA-BB-CC-DD-EE-FF", "LIBMPV": "/opt/lib"}
        for key, value in values.items():
            text = text.replace(f"@{key}@", value)
        config = json.loads(text)

        assert config["python"] == f"{_REPO_DIR}/.venv/bin/python"
        assert config["args"][:2] == ["-m", "linux_voice_assistant"]
        args = _parse_cli(monkeypatch, config["args"][2:])

        socket_path = f"{tmp_path}/audio.sock"
        assert args.audio_input_socket == socket_path
        assert args.audio_output_socket == socket_path
        assert args.control_socket == socket_path
        assert args.host == "0.0.0.0"
        assert args.mac_address == "aa:bb:cc:dd:ee:ff"
        assert args.name == "Mac"
        assert args.follow_network is True
        assert args.persist_mute is True
        assert args.disable_peripheral_api is True
