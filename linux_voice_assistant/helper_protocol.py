"""Framing of the Unix socket shared with an external audio engine.

The engine (the macOS app, or any process implementing the same contract) is
the server; LVA opens one connection per role: ``mic`` (microphone frames in),
``play:<name>`` (PCM out) and ``control`` (state snapshots out, commands in).

Every frame is an 8-byte little-endian header ``type: u8, version: u8,
reserved: u16, length: u32`` followed by ``length`` bytes. JSON payloads are
encoded canonically (sorted keys, no spaces) so both sides produce the same
bytes.
"""

import json
import socket
import struct
import threading
from enum import IntEnum
from typing import Any, Dict, List, NamedTuple, Optional, Tuple

import numpy as np

PROTO = 1
VERSION = 1
MAX_PAYLOAD = 65536
HEADER = struct.Struct("<BBHI")
MIC_INDEX = struct.Struct("<Q")

MIC_FORMAT = {"format": "s16le", "rate": 16000, "channels": 1}


class FrameType(IntEnum):
    HELLO = 1
    PCM = 2
    END = 3
    DRAINED = 4
    FLUSH = 5
    EVENT = 6
    CONTROL = 7


_FRAME_TYPES = frozenset(int(frame_type) for frame_type in FrameType)


class ProtocolError(Exception):
    """A malformed stream: ``code`` is bad_version, unknown_type, oversize or truncated."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class HandshakeError(Exception):
    """The engine refused the HELLO, or answered with something LVA cannot use."""


class Frame(NamedTuple):
    type: FrameType
    payload: bytes

    def json(self) -> Dict[str, Any]:
        value = json.loads(self.payload.decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("JSON payload is not an object")
        return value


def encode_json(value: Dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def encode_frame(frame_type: FrameType, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload of {len(payload)} bytes is larger than {MAX_PAYLOAD}")
    return HEADER.pack(int(frame_type), VERSION, 0, len(payload)) + payload


def json_frame(frame_type: FrameType, value: Dict[str, Any]) -> bytes:
    return encode_frame(frame_type, encode_json(value))


def mic_pcm_payload(index: int, samples: np.ndarray) -> bytes:
    return MIC_INDEX.pack(index) + np.asarray(samples, dtype="<i2").tobytes()


def parse_mic_pcm(payload: bytes) -> Tuple[int, np.ndarray]:
    """Return the index of the first sample and the s16 samples of a ``mic`` PCM payload."""
    if len(payload) < MIC_INDEX.size or (len(payload) - MIC_INDEX.size) % 2:
        raise ValueError(f"mic PCM payload of {len(payload)} bytes")
    (index,) = MIC_INDEX.unpack_from(payload)
    return index, np.frombuffer(payload, dtype="<i2", offset=MIC_INDEX.size)


class FrameDecoder:
    """Incremental parser: feed it bytes, get whole frames back."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, data: bytes) -> List[Frame]:
        self._buffer.extend(data)
        frames: List[Frame] = []
        while len(self._buffer) >= HEADER.size:
            frame_type, version, _reserved, length = HEADER.unpack_from(self._buffer)
            if version != VERSION:
                raise ProtocolError("bad_version", f"frame version {version}")
            if frame_type not in _FRAME_TYPES:
                raise ProtocolError("unknown_type", f"unknown frame type {frame_type}")
            if length > MAX_PAYLOAD:
                raise ProtocolError("oversize", f"frame of {length} bytes")
            end = HEADER.size + length
            if len(self._buffer) < end:
                break
            frames.append(Frame(FrameType(frame_type), bytes(self._buffer[HEADER.size : end])))
            del self._buffer[:end]
        return frames

    def finish(self) -> None:
        """Call at end of stream: a partial frame left over is an error."""
        if self._buffer:
            raise ProtocolError("truncated", f"stream ended inside a frame ({len(self._buffer)} bytes)")


class Connection:
    """
    A blocking connection for one role, safe to read from one thread while
    other threads send.
    """

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self._decoder = FrameDecoder()
        self._pending: List[Frame] = []
        self._send_lock = threading.Lock()
        self.closed = False

    @classmethod
    def open(cls, path: str, hello: Dict[str, Any], timeout: float = 5.0) -> Tuple["Connection", Dict[str, Any]]:
        """Connect, send the HELLO and return the connection with the engine's HELLO reply."""
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection = cls(sock)
        try:
            sock.settimeout(timeout)
            sock.connect(path)
            connection.send(FrameType.HELLO, encode_json({"proto": PROTO, **hello}))
            frame = connection.read()
            if frame is None:
                raise HandshakeError("connection closed before the HELLO reply")
            if frame.type != FrameType.HELLO:
                raise HandshakeError(f"expected a HELLO reply, got {frame.type.name}")
            reply = frame.json()
            if reply.get("accepted") is False:
                raise HandshakeError(f"refused: {reply.get('reason', 'no reason given')}")
            if reply.get("proto") != PROTO:
                raise HandshakeError(f"unsupported protocol version {reply.get('proto')!r}")
        except BaseException:
            connection.close()
            raise
        return connection, reply

    def send(self, frame_type: FrameType, payload: bytes = b"") -> None:
        data = encode_frame(frame_type, payload)
        with self._send_lock:
            self.sock.sendall(data)

    def send_json(self, frame_type: FrameType, value: Dict[str, Any]) -> None:
        self.send(frame_type, encode_json(value))

    def read(self) -> Optional[Frame]:
        """Return the next frame, or None at end of stream; socket timeouts propagate."""
        while not self._pending:
            data = self.sock.recv(65536)
            if not data:
                self._decoder.finish()
                return None
            self._pending.extend(self._decoder.feed(data))
        return self._pending.pop(0)

    def settimeout(self, timeout: Optional[float]) -> None:
        self.sock.settimeout(timeout)

    def close(self) -> None:
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
