"""The helper protocol framing against the fixtures shared with the macOS app."""

import json

import numpy as np
import pytest

from linux_voice_assistant.helper_protocol import (
    MAX_PAYLOAD,
    Connection,
    FrameDecoder,
    FrameType,
    HandshakeError,
    ProtocolError,
    encode_frame,
    json_frame,
    mic_pcm_payload,
    parse_mic_pcm,
)
from tests.unit.fake_engine import FIXTURES_DIR, FakeEngine, fixture

_FRAMES = json.loads((FIXTURES_DIR / "frames.json").read_text(encoding="utf-8"))["frames"]
_ERRORS = json.loads((FIXTURES_DIR / "errors.json").read_text(encoding="utf-8"))["errors"]
_SESSIONS = json.loads((FIXTURES_DIR / "sessions.json").read_text(encoding="utf-8"))["sessions"]


def _encode(frame: dict) -> bytes:
    frame_type = FrameType[frame["type"]]
    if "json" in frame:
        return json_frame(frame_type, frame["json"])
    if "samples" in frame:
        return encode_frame(frame_type, mic_pcm_payload(frame["index"], np.array(frame["samples"])))
    return encode_frame(frame_type, bytes.fromhex(frame.get("payload_hex", "")))


class TestFixtures:
    @pytest.mark.parametrize("frame", _FRAMES, ids=[frame["name"] for frame in _FRAMES])
    def test_encoding_matches_the_app_byte_for_byte(self, frame):
        assert _encode(frame).hex() == frame["hex"]

    @pytest.mark.parametrize("frame", _FRAMES, ids=[frame["name"] for frame in _FRAMES])
    def test_decoding(self, frame):
        decoded = FrameDecoder().feed(bytes.fromhex(frame["hex"]))[0]

        assert decoded.type == FrameType[frame["type"]]
        if "json" in frame:
            assert decoded.json() == frame["json"]

    @pytest.mark.parametrize("error", _ERRORS, ids=[error["name"] for error in _ERRORS])
    def test_malformed_streams_are_refused(self, error):
        decoder = FrameDecoder()
        with pytest.raises(ProtocolError) as raised:
            decoder.feed(bytes.fromhex(error["hex"]))
            decoder.finish()
        assert raised.value.code == error["error"]

    @pytest.mark.parametrize("session", _SESSIONS, ids=[session["name"] for session in _SESSIONS])
    def test_sessions_parse_as_one_stream_per_direction(self, session):
        by_name = {frame["name"]: frame for frame in _FRAMES}
        for sender in ("client", "helper"):
            names = [name for side, name in session["steps"] if side == sender]
            stream = b"".join(bytes.fromhex(by_name[name]["hex"]) for name in names)
            decoder = FrameDecoder()
            frames = [frame for i in range(0, len(stream), 7) for frame in decoder.feed(stream[i : i + 7])]
            decoder.finish()
            assert [frame.type.name for frame in frames] == [by_name[name]["type"] for name in names]

    def test_mic_pcm(self):
        frame = fixture("pcm_mic")
        decoded = FrameDecoder().feed(bytes.fromhex(frame["hex"]))[0]

        index, samples = parse_mic_pcm(decoded.payload)

        assert index == frame["index"]
        assert samples.tolist() == frame["samples"]


class TestFraming:
    def test_frames_split_across_reads_are_reassembled(self):
        data = json_frame(FrameType.EVENT, {"code": "overrun"}) + encode_frame(FrameType.DRAINED)
        decoder = FrameDecoder()

        frames = [frame for byte in data for frame in decoder.feed(bytes([byte]))]

        assert [frame.type for frame in frames] == [FrameType.EVENT, FrameType.DRAINED]
        assert frames[0].json() == {"code": "overrun"}

    def test_payload_limit(self):
        assert len(encode_frame(FrameType.PCM, bytes(MAX_PAYLOAD))) == MAX_PAYLOAD + 8
        with pytest.raises(ValueError):
            encode_frame(FrameType.PCM, bytes(MAX_PAYLOAD + 1))

    def test_odd_mic_payload_is_refused(self):
        with pytest.raises(ValueError):
            parse_mic_pcm(bytes(9))

    def test_json_must_be_an_object(self):
        frame = FrameDecoder().feed(encode_frame(FrameType.CONTROL, b"[1]"))[0]
        with pytest.raises(ValueError):
            frame.json()


class TestHandshake:
    def test_hello_and_reply(self):
        engine = FakeEngine()
        try:
            connection, reply = Connection.open(engine.path, {"role": "mic"})
            connection.close()
        finally:
            engine.close()

        assert reply == fixture("hello_mic_reply")["json"]
        assert engine.connections[0].hello == fixture("hello_mic")["json"]

    def test_refusal(self):
        engine = FakeEngine(replies={"mic": fixture("hello_refused_proto")["json"]})
        try:
            with pytest.raises(HandshakeError, match="unsupported_proto"):
                Connection.open(engine.path, {"role": "mic"})
        finally:
            engine.close()

    def test_other_protocol_version(self):
        engine = FakeEngine(replies={"mic": {"proto": 2, "accepted": True}})
        try:
            with pytest.raises(HandshakeError, match="protocol version"):
                Connection.open(engine.path, {"role": "mic"})
        finally:
            engine.close()

    def test_no_engine(self, tmp_path):
        with pytest.raises(OSError):
            Connection.open(str(tmp_path / "missing.sock"), {"role": "mic"}, timeout=1.0)
