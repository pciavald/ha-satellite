"""HelperPlayer (--audio-output-socket) against a fake audio engine."""

import functools
import http.server
import importlib.util
import io
import threading
import time
import wave
from pathlib import Path
from unittest.mock import MagicMock

import numpy as np
import pytest
from aioesphomeapi.api_pb2 import VoiceAssistantAnnounceFinished  # type: ignore[attr-defined]
from aioesphomeapi.model import VoiceAssistantEventType

from linux_voice_assistant.helper_protocol import FrameType
from linux_voice_assistant.mpv_player import MpvMediaPlayer
from linux_voice_assistant.player.helper import CHUNK_SAMPLES, HelperPlayer, decode_pcm
from linux_voice_assistant.player.state import PlayerState
from tests.unit.conftest import install_requirements, make_satellite
from tests.unit.fake_engine import FakeEngine, fixture_json, wait_until

_SOUNDS_DIR = Path(__file__).resolve().parents[2] / "sounds"

needs_av = pytest.mark.skipif(importlib.util.find_spec("av") is None, reason="PyAV is only installed on macOS")


def fake_decoder(items):
    """Decoder returning items[url]: a list of int16 arrays, or an exception to raise."""

    def decode(url, _cancelled):
        result = items[url]
        if isinstance(result, Exception):
            raise result
        for samples in result:
            yield np.asarray(samples, dtype=np.int16)

    return decode


def pcm(connection) -> np.ndarray:
    frames = connection.of_type(FrameType.PCM)
    if not frames:
        return np.zeros(0, dtype=np.int16)
    return np.concatenate([np.frombuffer(frame.payload, dtype="<i2") for frame in frames])


@pytest.fixture
def engine():
    fake = FakeEngine()
    yield fake
    fake.close()


@pytest.fixture
def player_factory(engine):
    players = []

    def make(items, **kwargs):
        player = HelperPlayer(engine.path, decode=fake_decoder(items), backoff=(0.05, 0.1), **kwargs)
        players.append(player)
        assert player.wait_connected(5.0)
        return player

    yield make
    for player in players:
        player.close()


class TestDependency:
    def test_pyav_only_on_macos(self):
        assert "av" in install_requirements("darwin")
        assert "av" not in install_requirements("linux")


class TestHandshake:
    def test_declares_its_format(self, engine, player_factory):
        player = player_factory({})

        assert engine.role("play:tts").hello == fixture_json("hello_play_tts")
        assert player.buffer_ms == 200


class TestPlayback:
    def test_end_then_drained_calls_back_once(self, engine, player_factory):
        done = []
        player = player_factory({"a": [np.arange(1000), np.arange(500)]})

        player.play("a", done_callback=lambda: done.append(1))

        wait_until(lambda: done)
        connection = engine.role("play:tts")
        assert pcm(connection).tolist() == list(range(1000)) + list(range(500))
        assert max(len(frame.payload) for frame in connection.of_type(FrameType.PCM)) <= CHUNK_SAMPLES * 2
        assert [frame.type for frame in connection.frames][-1] == FrameType.END
        assert done == [1]
        assert player.state() == PlayerState.IDLE

    def test_callback_waits_for_drained(self, engine, player_factory):
        engine.auto_drain = False
        done = []
        player = player_factory({"a": [np.zeros(100)]})

        player.play("a", done_callback=lambda: done.append(1))
        connection = engine.role("play:tts")
        wait_until(lambda: connection.of_type(FrameType.END))
        threading.Event().wait(0.2)
        assert not done

        connection.send(FrameType.DRAINED)
        wait_until(lambda: done)

    def test_volume_and_ducking_scale_the_samples(self, engine, player_factory):
        done = []
        player = player_factory({"a": [np.full(10, 10000)]})
        player.set_volume(50)
        player.duck(0.5)

        player.play("a", done_callback=lambda: done.append(1))
        wait_until(lambda: done)

        assert pcm(engine.role("play:tts")).tolist() == [2500] * 10

        player.unduck()
        player.set_volume(100)
        player.play("a", done_callback=lambda: done.append(2))
        wait_until(lambda: len(done) == 2)
        assert pcm(engine.role("play:tts")).tolist()[-10:] == [10000] * 10


class TestStop:
    def test_stop_flushes_without_callback(self, engine, player_factory):
        engine.auto_drain = False
        done = []
        player = player_factory({"a": [np.zeros(100)]})
        player.play("a", done_callback=lambda: done.append(1))
        connection = engine.role("play:tts")
        wait_until(lambda: connection.of_type(FrameType.END))
        engine.auto_drain = True

        player.stop()

        wait_until(lambda: connection.of_type(FrameType.FLUSH))
        assert player.state() == PlayerState.IDLE
        threading.Event().wait(0.2)
        connection.send(FrameType.DRAINED)
        threading.Event().wait(0.2)
        assert not done

    def test_replacement_plays_the_next_item_after_the_flush(self, engine, player_factory):
        engine.auto_drain = False
        done = []
        player = player_factory({"a": [np.full(100, 1)], "b": [np.full(100, 2)]})
        player.play("a", done_callback=lambda: done.append("a"))
        connection = engine.role("play:tts")
        wait_until(lambda: connection.of_type(FrameType.END))
        engine.auto_drain = True

        player.play("b", done_callback=lambda: done.append("b"))

        wait_until(lambda: done)
        assert done == ["b"]
        types = [frame.type for frame in connection.frames]
        assert types.index(FrameType.FLUSH) < len(types) - 1 - types[::-1].index(FrameType.PCM)

    def test_media_player_stop_calls_back_once(self, engine, player_factory):
        engine.auto_drain = False
        done = []
        media = MpvMediaPlayer(player=player_factory({"a": [np.zeros(100)]}))
        media.play("a", done_callback=lambda: done.append(1))
        wait_until(lambda: engine.role("play:tts").of_type(FrameType.END))
        engine.auto_drain = True

        media.stop()
        threading.Event().wait(0.3)

        assert done == [1]

    def test_media_player_playlist(self, engine, player_factory):
        done = []
        media = MpvMediaPlayer(player=player_factory({"a": [np.full(5, 1)], "b": [np.full(5, 2)]}))

        media.play(["a", "b"], done_callback=lambda: done.append(1))

        wait_until(lambda: done)
        assert pcm(engine.role("play:tts")).tolist() == [1] * 5 + [2] * 5
        assert done == [1]


class TestPause:
    def test_pause_flushes_and_resume_continues(self, engine):
        gate = threading.Event()

        def decode(_url, _cancelled):
            yield np.full(10, 1, dtype=np.int16)
            gate.wait(5.0)
            yield np.full(10, 2, dtype=np.int16)

        done = []
        player = HelperPlayer(engine.path, decode=decode, backoff=(0.05, 0.1))
        try:
            assert player.wait_connected(5.0)
            player.play("a", done_callback=lambda: done.append(1))
            connection = engine.role("play:tts")
            wait_until(lambda: connection.of_type(FrameType.PCM))

            player.pause()
            gate.set()
            wait_until(lambda: connection.of_type(FrameType.FLUSH))
            assert player.state() == PlayerState.PAUSED
            assert len(connection.of_type(FrameType.PCM)) == 1

            player.resume()
            wait_until(lambda: done)
            assert pcm(connection).tolist() == [1] * 10 + [2] * 10
        finally:
            player.close()


class TestErrors:
    def test_decode_error_leaves_error_state_without_callback(self, engine, player_factory):
        done = []
        player = player_factory({"bad": OSError("404 Not Found")})

        player.play("bad", done_callback=lambda: done.append(1))

        wait_until(lambda: player.state() == PlayerState.ERROR)
        assert not done
        assert player.connected and len(engine.connections) == 1

    def test_play_without_engine_fails_fast(self):
        done = []
        player = HelperPlayer("/tmp/lva-no-such-engine.sock", decode=fake_decoder({"a": [np.zeros(10)]}), backoff=(0.05, 0.1))
        try:
            player.play("a", done_callback=lambda: done.append(1))
            wait_until(lambda: player.state() == PlayerState.ERROR, timeout=1.0)
            assert not done
        finally:
            player.close()

    def test_engine_lost_while_waiting_for_drained(self, engine, player_factory):
        engine.auto_drain = False
        done = []
        player = player_factory({"a": [np.zeros(10)]})
        player.play("a", done_callback=lambda: done.append(1))
        connection = engine.role("play:tts")
        wait_until(lambda: connection.of_type(FrameType.END))

        connection.close()

        wait_until(lambda: player.state() == PlayerState.ERROR)
        assert not done
        wait_until(lambda: player.connected)


@needs_av
class TestPyAV:
    def test_bundled_sound_decodes_to_48k_mono_s16(self):
        samples = np.concatenate(list(decode_pcm(str(_SOUNDS_DIR / "wake_word_triggered.flac"))))

        assert samples.dtype == np.int16
        assert 0.1 < len(samples) / 48000 < 5
        assert np.abs(samples).max() > 1000

    def test_missing_file_raises(self, tmp_path):
        with pytest.raises(Exception):
            list(decode_pcm(str(tmp_path / "missing.flac")))

    def test_http_404_gives_error_state(self, tmp_path, engine):
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(tmp_path))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        player = HelperPlayer(engine.path, backoff=(0.05, 0.1))
        done = []
        try:
            assert player.wait_connected(5.0)
            player.play(f"http://127.0.0.1:{server.server_address[1]}/missing.mp3", done_callback=lambda: done.append(1))
            wait_until(lambda: player.state() == PlayerState.ERROR, timeout=20.0)
            assert not done
        finally:
            player.close()
            server.shutdown()

    def test_bundled_sound_through_the_engine(self, engine):
        player = HelperPlayer(engine.path, backoff=(0.05, 0.1))
        done = []
        try:
            assert player.wait_connected(5.0)
            player.play(str(_SOUNDS_DIR / "wake_word_triggered.flac"), done_callback=lambda: done.append(1))
            wait_until(lambda: done, timeout=10.0)
        finally:
            player.close()
        assert len(pcm(engine.connections[0])) > 4800


def wav_bytes(seconds: float, rate: int = 16000) -> bytes:
    """A 440 Hz tone as a 16-bit mono WAV file."""
    t = np.arange(int(seconds * rate)) / rate
    samples = (np.sin(2 * np.pi * 440 * t) * 16000).astype("<i2")
    out = io.BytesIO()
    with wave.open(out, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(samples.tobytes())
    return out.getvalue()


class SlowTTSServer:
    """Loopback stand-in for Home Assistant's tts_proxy: answers after `delay` seconds, as a TTS engine still synthesizing."""

    def __init__(self, body: bytes, delay: float) -> None:
        self.requests = 0
        self.release = threading.Event()
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                server.requests += 1
                server.release.wait(delay)
                self.send_response(200)
                self.send_header("Content-Type", "audio/x-wav")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.http.daemon_threads = True
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.http.server_address[1]}/api/tts_proxy/test.wav"

    def close(self) -> None:
        self.release.set()
        self.http.shutdown()
        self.http.server_close()


@needs_av
class TestSlowTTS:
    """The first live test: tts_proxy took longer than PyAV's 5 s open timeout, which cancelled with AVERROR_EXIT."""

    def test_tts_answered_late_plays_to_the_end_after_run_end(self, tmp_path, engine):
        server = SlowTTSServer(wav_bytes(0.5), delay=6.0)
        player = HelperPlayer(engine.path, backoff=(0.05, 0.1))
        try:
            assert player.wait_connected(5.0)
            sat = make_satellite(tmp_path, {"tts_player": MpvMediaPlayer(player=player)})
            sat.send_messages = MagicMock()

            sat.handle_voice_event(VoiceAssistantEventType.VOICE_ASSISTANT_RUN_START, {"url": server.url})
            sat.handle_voice_event(VoiceAssistantEventType.VOICE_ASSISTANT_TTS_END, {"url": server.url})
            sat.handle_voice_event(VoiceAssistantEventType.VOICE_ASSISTANT_RUN_END, {})

            def announced():
                return any(isinstance(m, VoiceAssistantAnnounceFinished) for call in sat.send_messages.call_args_list for m in call.args[0])

            wait_until(announced, timeout=20.0)
            assert player.state() == PlayerState.IDLE
            samples = pcm(engine.role("play:tts"))
            assert abs(len(samples) - 24000) < 2400, len(samples)
            assert np.abs(samples).max() > 8000
            assert server.requests == 1
            assert not sat._pipeline_active
        finally:
            player.close()
            server.close()

    def test_stop_while_waiting_for_the_server_lets_the_next_sound_play(self, engine):
        server = SlowTTSServer(wav_bytes(0.5), delay=30.0)
        player = HelperPlayer(engine.path, backoff=(0.05, 0.1))
        done = []
        try:
            assert player.wait_connected(5.0)
            media = MpvMediaPlayer(player=player)
            media.play(server.url, done_callback=lambda: done.append("tts"))
            wait_until(lambda: server.requests == 1)

            media.stop()
            assert done == ["tts"]
            started = time.monotonic()
            media.play(str(_SOUNDS_DIR / "wake_word_triggered.flac"), done_callback=lambda: done.append("wake"))

            wait_until(lambda: "wake" in done, timeout=10.0)
            assert time.monotonic() - started < 5.0
            assert player.state() == PlayerState.IDLE
        finally:
            player.close()
            server.close()
