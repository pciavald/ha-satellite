"""HelperSource (--audio-input-socket) against a fake audio engine."""

import logging
import threading

import numpy as np
import pytest

from linux_voice_assistant.audio_source import HelperSource
from linux_voice_assistant.helper_protocol import FrameType, mic_pcm_payload
from tests.unit.fake_engine import FakeEngine, fixture, fixture_json, wait_until


@pytest.fixture
def engine():
    fake = FakeEngine()
    yield fake
    fake.close()


@pytest.fixture
def source_factory(engine):
    sources = []

    def make(**kwargs):
        source = HelperSource(engine.path, backoff=(0.05, 0.1), **kwargs)
        source.start()
        sources.append(source)
        assert source.wait_connected(5.0)
        return source

    yield make
    for source in sources:
        source.close()


def send_pcm(connection, index, samples):
    connection.send(FrameType.PCM, mic_pcm_payload(index, np.asarray(samples, dtype=np.int16)))


def send_event(connection, name):
    connection.send_json(FrameType.EVENT, fixture_json(name))


class TestHandshake:
    def test_hello_and_processing(self, engine, source_factory):
        source = source_factory()

        assert engine.role("mic").hello == fixture_json("hello_mic")
        assert source.processing == ("aec", "ns")
        assert source.channels == 1
        assert source.connected

    def test_unauthorized_microphone_is_logged(self, caplog):
        engine = FakeEngine(replies={"mic": fixture_json("hello_mic_reply_unauthorized")})
        source = HelperSource(engine.path)
        try:
            with caplog.at_level(logging.ERROR):
                source.start()
                assert source.wait_connected(5.0)
            assert "no microphone access" in caplog.text
            assert source.processing == ("aec", "ns", "agc")
        finally:
            source.close()
            engine.close()

    @pytest.mark.parametrize(
        "reply",
        [
            {"proto": 1, "accepted": True, "format": "s16le", "rate": 48000, "channels": 1},
            {"proto": 1, "accepted": True, "format": "f32le", "rate": 16000, "channels": 1},
            {"proto": 1, "accepted": True, "format": "s16le", "rate": 16000, "channels": 2},
            {"proto": 2, "accepted": True, "format": "s16le", "rate": 16000, "channels": 1},
            {"proto": 1, "accepted": False, "reason": "unsupported_proto"},
        ],
    )
    def test_unusable_reply_is_refused(self, reply):
        engine = FakeEngine(replies={"mic": reply})
        source = HelperSource(engine.path, backoff=(0.05, 0.1))
        try:
            source.start()
            assert not source.wait_connected(0.5)
            assert source.last_error
        finally:
            source.close()
            engine.close()

    def test_recorder_accepts_only_16k_mono(self, source_factory):
        source = source_factory()
        assert source.recorder(samplerate=16000, channels=1, blocksize=None) is source
        with pytest.raises(ValueError):
            source.recorder(samplerate=16000, channels=2)


class TestFrames:
    def test_fixture_frame_scaled_to_float(self, engine, source_factory):
        source = source_factory()
        frame = fixture("pcm_mic")
        engine.role("mic").send_raw(bytes.fromhex(frame["hex"]))

        block = source.record(len(frame["samples"]))

        assert block.shape == (len(frame["samples"]), 1)
        assert block.dtype == np.float32
        np.testing.assert_allclose(block[:, 0], np.array(frame["samples"]) / 32767.0, rtol=1e-6)

    def test_blocks_span_frames(self, engine, source_factory):
        source = source_factory()
        connection = engine.role("mic")
        for i in range(10):
            send_pcm(connection, i * 160, np.full(160, i))

        block = source.record(1024)

        values = np.rint(block[:, 0] * 32767).astype(int)
        assert values.tolist() == [i for i in range(7) for _ in range(160)][:1024]

    def test_index_gap_is_logged(self, engine, source_factory, caplog):
        source = source_factory()
        connection = engine.role("mic")
        with caplog.at_level(logging.WARNING):
            send_pcm(connection, 0, np.zeros(160))
            send_pcm(connection, 480, np.zeros(160))
            source.record(320)
        assert "gap: 320 samples (20 ms)" in caplog.text

    def test_contiguous_frames_log_nothing(self, engine, source_factory, caplog):
        source = source_factory()
        connection = engine.role("mic")
        with caplog.at_level(logging.WARNING):
            for i in range(5):
                send_pcm(connection, 1600 + i * 160, np.zeros(160))
            source.record(800)
        assert "gap" not in caplog.text

    def test_overrun_event_is_logged(self, engine, source_factory, caplog):
        source_factory()
        with caplog.at_level(logging.WARNING):
            send_event(engine.role("mic"), "event_overrun")
            wait_until(lambda: "480 samples (overrun)" in caplog.text)


class TestPause:
    def test_paused_record_blocks_until_resumed_then_drops_300_ms(self, engine, source_factory, caplog):
        source = source_factory()
        source.pop_resumed()
        connection = engine.role("mic")
        send_event(connection, "event_capture_paused")
        wait_until(lambda: source.paused)

        result = {}
        reader = threading.Thread(target=lambda: result.setdefault("block", source.record(160)))
        reader.start()
        reader.join(0.3)
        assert reader.is_alive(), "record() returned while capture was paused"

        with caplog.at_level(logging.WARNING):
            send_event(connection, "event_capture_resumed")
            send_pcm(connection, 0, np.full(4800, 1))
            send_pcm(connection, 4800, np.full(160, 2))
            reader.join(5.0)

        assert not reader.is_alive()
        assert np.rint(result["block"][:, 0] * 32767).tolist() == [2] * 160
        assert source.pop_resumed()
        assert not source.pop_resumed()
        assert "gap" not in caplog.text

    def test_close_releases_a_paused_record(self, engine, source_factory):
        source = source_factory()
        send_event(engine.role("mic"), "event_capture_paused")
        wait_until(lambda: source.paused)
        result = {}
        reader = threading.Thread(target=lambda: result.setdefault("block", source.record(160)))
        reader.start()

        source.close()
        reader.join(5.0)

        assert not reader.is_alive()
        assert not result["block"].any()


class TestReconnect:
    def test_silence_while_disconnected(self, caplog):
        engine = FakeEngine()
        source = HelperSource(engine.path, backoff=(0.05, 0.1))
        source.start()
        try:
            assert source.wait_connected(5.0)
            with caplog.at_level(logging.WARNING):
                engine.close()
                wait_until(lambda: not source.connected)
                block = source.record(160)
            assert block.shape == (160, 1) and not block.any()
            assert "streaming silence" in caplog.text
        finally:
            source.close()

    def test_frames_again_after_reconnecting(self, engine, source_factory):
        source = source_factory()
        source.pop_resumed()
        first = engine.role("mic")

        first.close()
        second = wait_until(lambda: engine.role("mic") is not first and engine.role("mic"))
        wait_until(lambda: source.connected)
        send_pcm(second, 0, np.full(160, 3))

        assert np.rint(source.record(160)[:, 0] * 32767).tolist() == [3] * 160
        assert source.pop_resumed()

    def test_missing_engine_is_reported(self):
        source = HelperSource("/tmp/lva-no-such-engine.sock", backoff=(0.05, 0.1))
        source.start()
        try:
            assert not source.wait_connected(0.3)
            assert source.last_error
        finally:
            source.close()


class TestEvents:
    @pytest.mark.parametrize("name", ["event_will_sleep", "event_did_wake", "event_network_changed"])
    def test_power_events_reach_the_callback(self, engine, source_factory, name):
        events = []
        source_factory(on_event=lambda code, event: events.append(code))

        send_event(engine.role("mic"), name)

        assert wait_until(lambda: events) == [fixture_json(name)["code"]]

    def test_sleep_ready_is_sent_on_the_mic_connection(self, engine, source_factory):
        source = source_factory()

        assert source.send_event("sleep_ready")

        connection = engine.role("mic")
        wait_until(lambda: connection.of_type(FrameType.EVENT))
        assert connection.of_type(FrameType.EVENT)[0].payload.hex() == fixture("event_sleep_ready")["hex"][16:]

    def test_unknown_event_is_ignored(self, engine, source_factory):
        source = source_factory()
        engine.role("mic").send_json(FrameType.EVENT, {"code": "from_the_future"})
        send_pcm(engine.role("mic"), 0, np.zeros(160))

        assert source.record(160).shape == (160, 1)
        assert source.connected
