"""Microphone from an external audio engine over a Unix socket (``--audio-input-socket``)."""

import logging
import threading
from collections import deque
from typing import Callable, Deque, Dict, Optional, Tuple

import numpy as np

from .helper_protocol import MIC_FORMAT, Connection, FrameType, HandshakeError, ProtocolError, parse_mic_pcm

_LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 16000


class HelperSource:
    """
    Reads the ``mic`` role: 16 kHz mono s16 frames, each message numbered
    with the index of its first sample.

    It has the surface of a soundcard microphone (``name``, ``channels``,
    ``recorder()`` returning an object with ``record(numframes)``), so
    process_audio uses it unchanged. A reader thread keeps the connection
    open and reconnects with backoff; while disconnected, record() returns
    silence in real time. When the engine pauses capture on purpose
    (``capture_paused``), record() blocks until ``capture_resumed``, then the
    first 300 ms are dropped while the engine's processing settles and
    pop_resumed() tells the caller to reset its streaming features.
    """

    RESUME_DROP_SAMPLES = SAMPLE_RATE * 3 // 10
    MAX_BUFFERED_SAMPLES = SAMPLE_RATE * 2

    def __init__(
        self,
        path: str,
        on_event: Optional[Callable[[str, Dict], None]] = None,
        backoff: Tuple[float, float] = (1.0, 30.0),
        connect_timeout: float = 5.0,
    ) -> None:
        self.path = path
        self.name = f"audio engine at {path}"
        self.channels = 1
        self.processing: Tuple[str, ...] = ()
        self.on_event = on_event
        self.last_error: Optional[str] = None
        self._backoff = backoff
        self._connect_timeout = connect_timeout

        self._cond = threading.Condition()
        self._chunks: Deque[np.ndarray] = deque()
        self._buffered = 0
        self._connection: Optional[Connection] = None
        self._paused = False
        self._drop = 0
        self._resumed = False
        self._expected_index: Optional[int] = None
        self._overflowing = False
        self._closed = threading.Event()
        self._connected_once = threading.Event()
        self._thread: Optional[threading.Thread] = None

    # -------- lifecycle --------

    @property
    def connected(self) -> bool:
        return self._connection is not None

    @property
    def paused(self) -> bool:
        return self._paused

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="helper-mic", daemon=True)
        self._thread.start()

    def wait_connected(self, timeout: float) -> bool:
        """Wait for the first accepted handshake."""
        return self._connected_once.wait(timeout)

    def close(self) -> None:
        self._closed.set()
        with self._cond:
            connection = self._connection
            self._cond.notify_all()
        if connection is not None:
            connection.close()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(2.0)

    def send_event(self, code: str, **fields) -> bool:
        """Send an EVENT to the engine on the mic connection (e.g. sleep_ready)."""
        connection = self._connection
        if connection is None:
            return False
        try:
            connection.send_json(FrameType.EVENT, {"code": code, **fields})
        except OSError:
            _LOGGER.warning("Could not send %s to the audio engine", code)
            return False
        return True

    # -------- soundcard microphone surface --------

    def recorder(self, samplerate: int = SAMPLE_RATE, channels: int = 1, blocksize: Optional[int] = None) -> "HelperSource":
        if samplerate != SAMPLE_RATE or channels != 1:
            raise ValueError(f"the audio engine delivers {SAMPLE_RATE} Hz mono, not {samplerate} Hz with {channels} channel(s)")
        return self

    def __enter__(self) -> "HelperSource":
        return self

    def __exit__(self, *exc) -> None:
        return None

    def record(self, numframes: int) -> np.ndarray:
        """Return numframes float32 samples shaped (numframes, 1)."""
        with self._cond:
            while not self._closed.is_set():
                if self._connection is None:
                    break
                if not self._paused and self._buffered >= numframes:
                    return self._take(numframes)
                self._cond.wait(0.5)
            else:
                return np.zeros((numframes, 1), dtype=np.float32)

        # Disconnected: silence at the real-time pace
        self._closed.wait(numframes / SAMPLE_RATE)
        return np.zeros((numframes, 1), dtype=np.float32)

    def pop_resumed(self) -> bool:
        """True once after capture resumed or the connection was re-established."""
        with self._cond:
            resumed, self._resumed = self._resumed, False
            return resumed

    def _take(self, numframes: int) -> np.ndarray:
        parts = []
        needed = numframes
        while needed:
            chunk = self._chunks[0]
            if len(chunk) <= needed:
                parts.append(self._chunks.popleft())
                needed -= len(chunk)
            else:
                parts.append(chunk[:needed])
                self._chunks[0] = chunk[needed:]
                needed = 0
        self._buffered -= numframes
        return np.concatenate(parts).reshape(-1, 1)

    # -------- reader thread --------

    def _run(self) -> None:
        delay = self._backoff[0]
        failing = False
        while not self._closed.is_set():
            try:
                connection, reply = Connection.open(self.path, {"role": "mic"}, timeout=self._connect_timeout)
                try:
                    self._check_reply(reply)
                except HandshakeError:
                    connection.close()
                    raise
            except (OSError, HandshakeError, ProtocolError, ValueError) as err:
                self.last_error = str(err) or type(err).__name__
                if not failing:
                    _LOGGER.warning("Audio engine microphone unavailable at %s: %s (retrying)", self.path, self.last_error)
                    failing = True
                else:
                    _LOGGER.debug("Audio engine microphone still unavailable: %s", self.last_error)
                self._closed.wait(delay)
                delay = min(delay * 2, self._backoff[1])
                continue

            failing = False
            delay = self._backoff[0]
            self.last_error = None
            self._serve(connection)

    def _check_reply(self, reply: Dict) -> None:
        offered = {key: reply.get(key) for key in MIC_FORMAT}
        if offered != MIC_FORMAT:
            raise HandshakeError(f"unsupported microphone format {offered}")
        self.processing = tuple(str(name) for name in reply.get("processing") or ())
        if reply.get("mic_authorized") is False:
            _LOGGER.error("The audio engine has no microphone access: grant it in System Settings > Privacy & Security > Microphone")

    def _serve(self, connection: Connection) -> None:
        with self._cond:
            self._connection = connection
            self._chunks.clear()
            self._buffered = 0
            self._expected_index = None
            self._paused = False
            self._drop = 0
            self._resumed = True
            self._cond.notify_all()
        self._connected_once.set()
        _LOGGER.info("Microphone connected to the audio engine (processing: %s)", ", ".join(self.processing) or "none")

        connection.settimeout(None)
        try:
            while True:
                frame = connection.read()
                if frame is None:
                    break
                if frame.type == FrameType.PCM:
                    self._on_pcm(frame.payload)
                elif frame.type == FrameType.EVENT:
                    self._on_event(frame.json())
                else:
                    _LOGGER.debug("Ignoring %s frame on the mic connection", frame.type.name)
        except ProtocolError as err:
            _LOGGER.error("Audio engine protocol error (%s): %s", err.code, err)
        except (OSError, ValueError) as err:
            if not self._closed.is_set():
                _LOGGER.warning("Audio engine microphone connection failed: %s", err)
        finally:
            with self._cond:
                self._connection = None
                self._chunks.clear()
                self._buffered = 0
                self._cond.notify_all()
            connection.close()
            if not self._closed.is_set():
                _LOGGER.warning("Microphone disconnected from the audio engine, streaming silence until it is back")

    def _on_pcm(self, payload: bytes) -> None:
        index, samples = parse_mic_pcm(payload)
        with self._cond:
            if self._expected_index is not None and index != self._expected_index:
                missing = index - self._expected_index
                if missing > 0:
                    _LOGGER.warning("Microphone gap: %d samples (%.0f ms) lost", missing, 1000 * missing / SAMPLE_RATE)
                else:
                    _LOGGER.warning("Microphone frames out of order (index %d, expected %d)", index, self._expected_index)
            self._expected_index = index + len(samples)
            if self._paused:
                return

            data = samples.astype(np.float32) / 32767.0
            if self._drop:
                dropped = min(self._drop, len(data))
                data = data[dropped:]
                self._drop -= dropped
            if data.size == 0:
                return

            self._chunks.append(data)
            self._buffered += len(data)
            while self._buffered > self.MAX_BUFFERED_SAMPLES:
                oldest = self._chunks.popleft()
                self._buffered -= len(oldest)
                if not self._overflowing:
                    _LOGGER.warning("Audio processing is falling behind the microphone, dropping old audio")
                    self._overflowing = True
            if self._buffered < self.MAX_BUFFERED_SAMPLES // 2:
                self._overflowing = False
            self._cond.notify_all()

    def _on_event(self, event: Dict) -> None:
        code = str(event.get("code", ""))
        if code == "capture_paused":
            with self._cond:
                self._paused = True
                self._chunks.clear()
                self._buffered = 0
                self._expected_index = None
                self._cond.notify_all()
            _LOGGER.info("Audio engine paused capture")
        elif code == "capture_resumed":
            with self._cond:
                self._paused = False
                self._drop = self.RESUME_DROP_SAMPLES
                self._resumed = True
                self._expected_index = None
                self._cond.notify_all()
            _LOGGER.info("Audio engine resumed capture")
        elif code == "overrun":
            _LOGGER.warning("Audio engine dropped %s samples (overrun)", event.get("dropped", "some"))
        elif code == "permission_denied":
            _LOGGER.error("Audio engine has no microphone access: %s", event.get("msg", ""))
        elif code == "no_input_device":
            _LOGGER.warning("Audio engine has no input device")
        elif code == "protocol_error":
            _LOGGER.error("Audio engine reported a protocol error: %s %s", event.get("error", ""), event.get("msg", ""))
        else:
            _LOGGER.debug("Audio engine event: %s", event)

        if self.on_event is not None:
            try:
                self.on_event(code, event)
            except Exception:  # pylint: disable=broad-except
                _LOGGER.exception("Error handling audio engine event %s", code)
