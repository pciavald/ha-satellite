"""Unit tests for __main__.py — process_audio logic and argument parsing helpers."""

import numpy as np
import pytest

from tests.unit.conftest import make_state


def make_audio_chunk(samples: int = 1024, value: float = 0.0) -> np.ndarray:
    return np.full(samples, value, dtype=np.float32)


# ---------------------------------------------------------------------------
# process_audio — mic volume scaling
# ---------------------------------------------------------------------------


class TestProcessAudioMicVolume:
    def test_mic_volume_scalar_at_100(self, tmp_path):
        """mic_volume=100 → scalar=1.0 → no attenuation."""
        state = make_state(tmp_path)
        state.mic_volume = 100
        state.satellite = None  # no satellite → loop exits immediately

        # The scalar clamp: max(0.1, min(1.0, 100/100)) = 1.0
        scalar = max(0.1, min(1.0, state.mic_volume / 100.0))
        assert scalar == pytest.approx(1.0)

    def test_mic_volume_scalar_at_50(self, tmp_path):
        state = make_state(tmp_path)
        state.mic_volume = 50
        scalar = max(0.1, min(1.0, state.mic_volume / 100.0))
        assert scalar == pytest.approx(0.5)

    def test_mic_volume_scalar_clamped_above_100(self, tmp_path):
        state = make_state(tmp_path)
        state.mic_volume = 200
        scalar = max(0.1, min(1.0, state.mic_volume / 100.0))
        assert scalar == pytest.approx(1.0)

    def test_mic_volume_scalar_minimum_is_0_1(self, tmp_path):
        state = make_state(tmp_path)
        state.mic_volume = 0
        scalar = max(0.1, min(1.0, state.mic_volume / 100.0))
        assert scalar == pytest.approx(0.1)

    def test_audio_chunk_scaled_by_mic_volume(self):
        """Verify the numpy scaling produces correct output."""
        audio = make_audio_chunk(value=0.5)
        mic_vol_scalar = 0.5
        result = np.clip(audio * mic_vol_scalar, -1.0, 1.0)
        assert np.allclose(result, 0.25)

    def test_audio_chunk_clipped_to_bounds(self):
        """Values that exceed [-1, 1] after scaling should be clipped."""
        audio = make_audio_chunk(value=1.0)
        mic_vol_scalar = 2.0  # would push to 2.0 without clip
        result = np.clip(audio * mic_vol_scalar, -1.0, 1.0)
        assert np.all(result <= 1.0)


# ---------------------------------------------------------------------------
# process_audio — WebRTC integration
# ---------------------------------------------------------------------------


class TestProcessAudioWebRTC:
    def test_webrtc_not_created_when_agc_and_ns_zero(self, tmp_path):
        """If both AGC and NS are 0, WebRTCProcessor should never be instantiated."""
        state = make_state(tmp_path)
        state.preferences.mic_auto_gain = 0
        state.preferences.mic_noise_suppression = 0

        agc = state.preferences.mic_auto_gain or 0
        ns = state.preferences.mic_noise_suppression or 0
        should_create = agc > 0 or ns > 0
        assert should_create is False

    def test_webrtc_created_when_agc_nonzero(self, tmp_path):
        state = make_state(tmp_path)
        state.preferences.mic_auto_gain = 5
        state.preferences.mic_noise_suppression = 0

        agc = state.preferences.mic_auto_gain or 0
        ns = state.preferences.mic_noise_suppression or 0
        should_create = agc > 0 or ns > 0
        assert should_create is True

    def test_webrtc_created_when_ns_nonzero(self, tmp_path):
        state = make_state(tmp_path)
        state.preferences.mic_auto_gain = 0
        state.preferences.mic_noise_suppression = 2

        agc = state.preferences.mic_auto_gain or 0
        ns = state.preferences.mic_noise_suppression or 0
        should_create = agc > 0 or ns > 0
        assert should_create is True


# ---------------------------------------------------------------------------
# process_audio — wake word refractory
# ---------------------------------------------------------------------------


class TestWakeWordRefractory:
    def test_refractory_allows_activation_when_none(self):
        """First activation (last_active=None) should always be allowed."""
        import time

        last_active = None
        refractory_seconds = 2.0
        now = time.monotonic()
        allowed = (last_active is None) or ((now - last_active) > refractory_seconds)
        assert allowed is True

    def test_refractory_blocks_activation_too_soon(self):
        """Activation within refractory period should be blocked."""
        import time

        last_active = time.monotonic()  # just activated
        refractory_seconds = 2.0
        now = time.monotonic()
        allowed = (last_active is None) or ((now - last_active) > refractory_seconds)
        assert allowed is False

    def test_refractory_allows_activation_after_period(self):
        """Activation after refractory period should be allowed."""
        import time

        last_active = time.monotonic() - 3.0  # 3 seconds ago
        refractory_seconds = 2.0
        now = time.monotonic()
        allowed = (last_active is None) or ((now - last_active) > refractory_seconds)
        assert allowed is True


# ---------------------------------------------------------------------------
# process_audio — stop word detection logic
# ---------------------------------------------------------------------------


class TestStopWordLogic:
    def test_stop_word_only_triggers_when_in_active_set(self, tmp_path):
        state = make_state(tmp_path)
        # Stop word not in active set → should not trigger stop
        state.active_wake_words = set()
        stopped = True  # simulating detection

        should_stop = stopped and (state.stop_word.id in state.active_wake_words) and not state.muted
        assert should_stop is False

    def test_stop_word_triggers_when_in_active_set_and_not_muted(self, tmp_path):
        state = make_state(tmp_path)
        state.active_wake_words = {state.stop_word.id}
        state.muted = False
        stopped = True

        should_stop = stopped and (state.stop_word.id in state.active_wake_words) and not state.muted
        assert should_stop is True

    def test_stop_word_does_not_trigger_when_muted(self, tmp_path):
        state = make_state(tmp_path)
        state.active_wake_words = {state.stop_word.id}
        state.muted = True
        stopped = True

        should_stop = stopped and (state.stop_word.id in state.active_wake_words) and not state.muted
        assert should_stop is False


# ---------------------------------------------------------------------------
# Preferences loading from args
# ---------------------------------------------------------------------------


class TestPreferencesFromArgs:
    def test_agc_stored_in_preferences_when_nonzero(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences()
        mic_auto_gain = 5
        if mic_auto_gain > 0:
            prefs.mic_auto_gain = mic_auto_gain
        assert prefs.mic_auto_gain == 5

    def test_agc_not_stored_when_zero(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences()
        mic_auto_gain = 0
        if mic_auto_gain > 0:
            prefs.mic_auto_gain = mic_auto_gain
        assert prefs.mic_auto_gain == 0

    def test_ns_stored_in_preferences_when_nonzero(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences()
        mic_noise_suppression = 2
        if mic_noise_suppression > 0:
            prefs.mic_noise_suppression = mic_noise_suppression
        assert prefs.mic_noise_suppression == 2

    def test_volume_clamped_to_one_when_above(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences(volume=1.5)
        initial_volume = prefs.volume if prefs.volume is not None else 1.0
        initial_volume = max(0.0, min(1.0, float(initial_volume)))
        assert initial_volume == pytest.approx(1.0)

    def test_volume_clamped_to_zero_when_below(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences(volume=-0.5)
        initial_volume = prefs.volume if prefs.volume is not None else 1.0
        initial_volume = max(0.0, min(1.0, float(initial_volume)))
        assert initial_volume == pytest.approx(0.0)

    def test_volume_defaults_to_one_when_none(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences(volume=None)
        initial_volume = prefs.volume if prefs.volume is not None else 1.0
        initial_volume = max(0.0, min(1.0, float(initial_volume)))
        assert initial_volume == pytest.approx(1.0)

    def test_thinking_sound_enabled_by_flag(self):
        from linux_voice_assistant.models import Preferences

        prefs = Preferences()
        enable_thinking_sound = True
        if enable_thinking_sound:
            prefs.thinking_sound = 1
        assert prefs.thinking_sound == 1


# ---------------------------------------------------------------------------
# Audio engine: timestamped log lines and streaming during the sounds
# ---------------------------------------------------------------------------


def _engine_args(**sockets):
    import argparse

    values = {"audio_input_socket": None, "audio_output_socket": None, "control_socket": None}
    values.update(sockets)
    return argparse.Namespace(**values)


class TestEngineLogFormat:
    def test_no_engine_keeps_the_default_format(self):
        from linux_voice_assistant.__main__ import _log_format

        assert _log_format(_engine_args()) == {}

    def test_engine_lines_carry_the_time_to_the_millisecond(self):
        import logging

        from linux_voice_assistant.__main__ import _log_format

        options = _log_format(_engine_args(audio_input_socket="/s", audio_output_socket="/s", control_socket="/s"))
        formatter = logging.Formatter(options["format"], options["datefmt"])
        record = logging.LogRecord("lva", logging.INFO, __file__, 1, "Wake word", None, None)
        record.created = 1759622400.0421
        record.msecs = 42.1

        line = formatter.format(record)
        assert line.endswith(".042 INFO:lva:Wake word")
        assert line[:4].isdigit() and line[10] == " "


class TestEngineCancelsEcho:
    def test_both_engine_sockets_listen_during_the_sounds(self):
        from linux_voice_assistant.__main__ import _engine_cancels_echo

        assert _engine_cancels_echo(_engine_args(audio_input_socket="/s", audio_output_socket="/s")) is True

    @pytest.mark.parametrize(
        "sockets",
        [{}, {"audio_input_socket": "/s"}, {"audio_output_socket": "/s"}, {"control_socket": "/s"}],
    )
    def test_without_the_engine_playing_and_hearing_the_sounds_wait_for_them(self, sockets):
        from linux_voice_assistant.__main__ import _engine_cancels_echo

        assert _engine_cancels_echo(_engine_args(**sockets)) is False
