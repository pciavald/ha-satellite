"""A fake audio engine (the macOS app side of the socket contract) for tests."""

import json
import os
import shutil
import socket
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from linux_voice_assistant.helper_protocol import Frame, FrameDecoder, FrameType, ProtocolError, encode_frame, encode_json

FIXTURES_DIR = Path(__file__).resolve().parents[1] / "fixtures" / "helper_protocol"


def fixture(name: str) -> Dict[str, Any]:
    """A frame of frames.json by name."""
    frames = json.loads((FIXTURES_DIR / "frames.json").read_text(encoding="utf-8"))["frames"]
    for frame in frames:
        if frame["name"] == name:
            return dict(frame)
    raise KeyError(name)


def fixture_json(name: str) -> Dict[str, Any]:
    return dict(fixture(name)["json"])


def socket_dir() -> str:
    # AF_UNIX paths are limited to 104 bytes on macOS, pytest's tmp_path is often longer
    return tempfile.mkdtemp(prefix="lva-", dir="/tmp")


def wait_until(predicate: Callable[[], Any], timeout: float = 5.0) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError("condition not met in time")


class EngineConnection:
    def __init__(self, engine: "FakeEngine", sock: socket.socket) -> None:
        self.engine = engine
        self.sock = sock
        self.role: Optional[str] = None
        self.hello: Optional[Dict[str, Any]] = None
        self.frames: List[Frame] = []
        self.closed = False
        self._send_lock = threading.Lock()

    def send(self, frame_type: FrameType, payload: bytes = b"") -> None:
        with self._send_lock:
            self.sock.sendall(encode_frame(frame_type, payload))

    def send_json(self, frame_type: FrameType, value: Dict[str, Any]) -> None:
        self.send(frame_type, encode_json(value))

    def send_raw(self, data: bytes) -> None:
        with self._send_lock:
            self.sock.sendall(data)

    def of_type(self, frame_type: FrameType) -> List[Frame]:
        return [frame for frame in list(self.frames) if frame.type == frame_type]

    def json_of_type(self, frame_type: FrameType) -> List[Dict[str, Any]]:
        return [frame.json() for frame in self.of_type(frame_type)]

    def close(self) -> None:
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class FakeEngine:
    """
    Unix socket server speaking the helper protocol. Replies to each HELLO
    with ``replies[role]`` (default: the fixture replies), records every frame
    and answers END and FLUSH with DRAINED unless ``auto_drain`` is False.
    """

    def __init__(self, replies: Optional[Dict[str, Dict[str, Any]]] = None, auto_drain: bool = True) -> None:
        self.dir = socket_dir()
        self.path = os.path.join(self.dir, "audio.sock")
        self.replies = {
            "mic": fixture_json("hello_mic_reply"),
            "play:tts": fixture_json("hello_play_reply"),
            "control": fixture_json("hello_control_reply"),
            **(replies or {}),
        }
        self.auto_drain = auto_drain
        self.drain_delay = 0.0
        self.connections: List[EngineConnection] = []
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.path)
        self._server.listen(8)
        self._running = True
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()

    def _accept(self) -> None:
        while self._running:
            try:
                sock, _ = self._server.accept()
            except OSError:
                return
            connection = EngineConnection(self, sock)
            self.connections.append(connection)
            threading.Thread(target=self._serve, args=(connection,), daemon=True).start()

    def _serve(self, connection: EngineConnection) -> None:
        decoder = FrameDecoder()
        try:
            while True:
                data = connection.sock.recv(65536)
                if not data:
                    break
                for frame in decoder.feed(data):
                    self._on_frame(connection, frame)
        except (OSError, ProtocolError):
            pass
        connection.closed = True

    def _on_frame(self, connection: EngineConnection, frame: Frame) -> None:
        if connection.hello is None and frame.type == FrameType.HELLO:
            connection.hello = frame.json()
            connection.role = connection.hello.get("role")
            reply = self.replies.get(str(connection.role), {"proto": 1, "accepted": False, "reason": "unknown_role"})
            connection.send_json(FrameType.HELLO, reply)
            return
        connection.frames.append(frame)
        if self.auto_drain and frame.type in (FrameType.END, FrameType.FLUSH):
            if self.drain_delay:
                time.sleep(self.drain_delay)
            connection.send(FrameType.DRAINED)

    def role(self, role: str, timeout: float = 5.0) -> EngineConnection:
        """The latest open connection with that role, waiting for it."""

        def find() -> Optional[EngineConnection]:
            for connection in reversed(self.connections):
                if connection.role == role and not connection.closed:
                    return connection
            return None

        connection: EngineConnection = wait_until(find, timeout)
        return connection

    def close(self) -> None:
        self._running = False
        try:
            self._server.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self._server.close()
        for connection in self.connections:
            connection.close()
        shutil.rmtree(self.dir, ignore_errors=True)
