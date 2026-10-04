"""Playback through an external audio engine over a Unix socket (``--audio-output-socket``).

TTS, announcements and sounds are decoded here with PyAV to 48 kHz mono s16
and streamed on a ``play:<name>`` connection, so the engine renders them
through the same path its echo canceller uses as a reference. PyAV is only
imported when something is decoded: it is not installed on Linux.
"""

import logging
import queue
import socket
import threading
import urllib.request
from typing import Callable, Dict, Iterable, Iterator, Optional, Tuple

import numpy as np

from linux_voice_assistant.helper_protocol import Connection, FrameType, HandshakeError, ProtocolError
from linux_voice_assistant.player.base import AudioPlayer
from linux_voice_assistant.player.state import PlayerState

_LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 48000
OUTPUT_FORMAT = {"format": "s16le", "rate": SAMPLE_RATE, "channels": 1}
CHUNK_SAMPLES = SAMPLE_RATE // 50  # 20 ms between cancel checks

# Seconds without any byte from the server, as mpv's network-timeout: Home
# Assistant's tts_proxy answers only once the TTS engine has produced audio,
# which takes several seconds with a local TTS or a streaming conversation agent
NETWORK_TIMEOUT = 60.0
HTTP_CHUNK = 16384
HTTP_BUFFER = 1 << 20  # read ahead at most 1 MiB of a stream

Decoder = Callable[[str, threading.Event], Iterable[np.ndarray]]


class Cancelled(Exception):
    """The item was stopped while its source was being read."""


class HttpSource:
    """
    Readable, non-seekable file object over an HTTP(S) URL for av.open().

    A daemon thread downloads ahead; read() waits for data in 50 ms steps and
    raises Cancelled as soon as ``cancelled`` is set, so stop() never waits
    for a slow server. PyAV's own timeouts are not used: they cancel with
    AVERROR_EXIT ("Immediate exit requested") however long the server is
    legitimately busy.
    """

    def __init__(self, url: str, cancelled: threading.Event, timeout: float = NETWORK_TIMEOUT) -> None:
        self.url = url
        self._cancelled = cancelled
        self._timeout = timeout
        self._buffer = bytearray()
        self._done = False
        self._error: Optional[BaseException] = None
        self._closed = False
        self._condition = threading.Condition()
        threading.Thread(target=self._download, name="helper-http", daemon=True).start()

    def _download(self) -> None:
        try:
            with urllib.request.urlopen(self.url, timeout=self._timeout) as response:  # nosec B310 (Home Assistant URLs)
                while True:
                    with self._condition:
                        while len(self._buffer) >= HTTP_BUFFER and not self._closed:
                            self._condition.wait(0.05)
                        if self._closed:
                            return
                    data = response.read1(HTTP_CHUNK)
                    with self._condition:
                        if not data:
                            break
                        self._buffer += data
                        self._condition.notify_all()
        except Exception as err:  # pylint: disable=broad-except
            with self._condition:
                self._error = err
        finally:
            with self._condition:
                self._done = True
                self._condition.notify_all()

    def read(self, size: int = -1) -> bytes:
        with self._condition:
            while not self._buffer and not self._done:
                if self._cancelled.is_set():
                    raise Cancelled()
                self._condition.wait(0.05)
            if self._cancelled.is_set():
                raise Cancelled()
            if not self._buffer and self._error is not None:
                raise self._error
            size = len(self._buffer) if size is None or size < 0 else size
            data = bytes(self._buffer[:size])
            del self._buffer[:size]
            self._condition.notify_all()
            return data

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._condition.notify_all()


def decode_pcm(url: str, cancelled: Optional[threading.Event] = None) -> Iterator[np.ndarray]:
    """Yield 48 kHz mono s16 sample arrays of a local file or an HTTP(S) URL."""
    import av  # pylint: disable=import-error

    source = None
    if url.startswith(("http://", "https://")):
        source = HttpSource(url, cancelled if cancelled is not None else threading.Event())
    try:
        with av.open(source if source is not None else url, mode="r") as container:
            stream = container.streams.audio[0]
            resampler = av.AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)
            for frame in container.decode(stream):
                for resampled in resampler.resample(frame):
                    yield resampled.to_ndarray().reshape(-1)
            for resampled in resampler.resample(None):
                yield resampled.to_ndarray().reshape(-1)
    finally:
        if source is not None:
            source.close()


class _Item:
    def __init__(self, url: str, done_callback: Optional[Callable[[], None]], paused: bool) -> None:
        self.url = url
        self.done_callback = done_callback
        self.cancelled = threading.Event()
        self.paused = paused


class _DecodeError(Exception):
    pass


def _decoded(decode: Decoder, item: _Item) -> Iterator[np.ndarray]:
    """Decoder output; a failure is Cancelled once the item is stopped, else _DecodeError (PyAV raises OSError subclasses)."""
    try:
        iterator = iter(decode(item.url, item.cancelled))
        while True:
            try:
                samples = next(iterator)
            except StopIteration:
                return
            yield samples
    except GeneratorExit:
        raise
    except Exception as err:  # pylint: disable=broad-except
        if item.cancelled.is_set():
            raise Cancelled() from err
        raise _DecodeError(str(err) or type(err).__name__) from err


class HelperPlayer(AudioPlayer):
    """
    Same surface as LibMpvPlayer, so MpvMediaPlayer wraps it unchanged.

    One worker thread plays items in order: decode, scale by volume and
    ducking, send in 20 ms chunks (the engine reads only while its queue is
    short, which paces the decoding), then END and wait for DRAINED, which
    means the engine has rendered the last sample; only then the done
    callback runs. stop() cancels the item: FLUSH, wait for its DRAINED, no
    callback. Errors (missing file, HTTP error, engine gone) leave the player
    in ERROR without a callback, as libmpv does. A connection thread keeps the
    socket open and reconnects with backoff; play() while it is down fails at
    once instead of blocking the pipeline.

    pause() flushes what the engine has queued, up to its ``buffer_ms``
    (200 ms with the macOS app), and resume() goes on with the first chunk
    not yet sent, so up to 200 ms of the item are skipped across a pause.
    """

    def __init__(
        self,
        path: str,
        name: str = "tts",
        decode: Decoder = decode_pcm,
        backoff: Tuple[float, float] = (1.0, 30.0),
        connect_timeout: float = 5.0,
        send_timeout: float = 5.0,
        flush_timeout: float = 0.5,
    ) -> None:
        self._log = logging.getLogger(self.__class__.__name__)
        self.path = path
        self.role = f"play:{name}"
        self.buffer_ms: Optional[int] = None
        self._decode = decode
        self._backoff = backoff
        self._connect_timeout = connect_timeout
        self._send_timeout = send_timeout
        self._flush_timeout = flush_timeout

        self._state = PlayerState.IDLE
        self._lock = threading.Lock()
        self._user_volume = 100.0
        self._duck_factor = 1.0

        self._items: "queue.Queue[Optional[_Item]]" = queue.Queue()
        self._current: Optional[_Item] = None
        self._connection: Optional[Connection] = None
        self._connected = threading.Event()
        self._drained = threading.Event()
        self._closed = threading.Event()

        self._connection_thread = threading.Thread(target=self._run_connection, name=f"helper-{self.role}", daemon=True)
        self._worker_thread = threading.Thread(target=self._run_worker, name=f"helper-{self.role}-worker", daemon=True)
        self._connection_thread.start()
        self._worker_thread.start()

    # -------- AudioPlayer surface --------

    def play(
        self,
        url: str,
        done_callback: Optional[Callable[[], None]] = None,
        stop_first: bool = False,
    ) -> None:
        """Play url, replacing the current item without calling its callback."""
        item = _Item(url, done_callback, paused=stop_first)
        with self._lock:
            if self._current is not None:
                self._current.cancelled.set()
            self._current = item
            self._state = PlayerState.LOADING
        self._items.put(item)

    def pause(self) -> None:
        with self._lock:
            if self._current is not None:
                self._current.paused = True
                self._state = PlayerState.PAUSED

    def resume(self) -> None:
        with self._lock:
            if self._current is not None and self._current.paused:
                self._current.paused = False
                self._state = PlayerState.PLAYING

    def stop(self, for_replacement: bool = False) -> None:
        """Drop what is queued in the engine; the done callback is never called (MpvMediaPlayer calls it)."""
        with self._lock:
            if self._current is not None:
                self._current.cancelled.set()
                self._current = None
            self._state = PlayerState.IDLE

    def state(self) -> PlayerState:
        with self._lock:
            return self._state

    def set_volume(self, volume: float) -> None:
        with self._lock:
            self._user_volume = max(0.0, min(100.0, float(volume)))

    def duck(self, factor: float = 0.5) -> None:
        with self._lock:
            self._duck_factor = max(0.0, min(1.0, float(factor)))

    def unduck(self) -> None:
        with self._lock:
            self._duck_factor = 1.0

    def close(self) -> None:
        self._closed.set()
        self.stop()
        self._items.put(None)
        connection = self._connection
        if connection is not None:
            connection.close()
        for thread in (self._worker_thread, self._connection_thread):
            if thread is not threading.current_thread():
                thread.join(2.0)

    @property
    def connected(self) -> bool:
        return self._connection is not None

    def wait_connected(self, timeout: float) -> bool:
        return self._connected.wait(timeout)

    # -------- worker --------

    def _gain(self) -> float:
        with self._lock:
            return self._user_volume / 100.0 * self._duck_factor

    def _run_worker(self) -> None:
        while True:
            item = self._items.get()
            if item is None or self._closed.is_set():
                return
            if item.cancelled.is_set():
                continue
            self._play_item(item)

    def _play_item(self, item: _Item) -> None:
        connection = self._connection
        if connection is None:
            self._log.error("Audio engine is not connected (%s), cannot play %s", self.path, item.url)
            self._finish(item, PlayerState.ERROR)
            return

        self._drained.clear()
        try:
            for samples in _decoded(self._decode, item):
                for start in range(0, len(samples), CHUNK_SAMPLES):
                    self._wait_while_paused(item, connection)
                    if item.cancelled.is_set():
                        raise Cancelled()
                    self._send_pcm(connection, samples[start : start + CHUNK_SAMPLES])
                    self._set_playing(item)
            while True:
                if item.cancelled.is_set():
                    raise Cancelled()
                self._drained.clear()
                connection.send(FrameType.END)
                if self._wait_drained(item, connection):
                    break
        except Cancelled:
            self._flush(connection)
            self._finish(item, None)
        except _DecodeError as err:
            self._log.error("Cannot play %s: %s", item.url, err)
            self._flush(connection)
            self._finish(item, PlayerState.ERROR)
        except (OSError, ProtocolError) as err:
            self._log.error("Audio engine connection failed while playing %s: %s", item.url, err)
            connection.close()
            self._finish(item, PlayerState.ERROR)
        else:
            self._finish(item, PlayerState.IDLE, call_back=True)

    def _send_pcm(self, connection: Connection, samples: np.ndarray) -> None:
        gain = self._gain()
        if gain != 1.0:
            samples = np.clip(np.rint(samples.astype(np.float32) * gain), -32768, 32767)
        connection.send(FrameType.PCM, np.asarray(samples, dtype="<i2").tobytes())

    def _set_playing(self, item: _Item) -> None:
        with self._lock:
            if self._current is item and self._state == PlayerState.LOADING:
                self._state = PlayerState.PLAYING

    def _wait_while_paused(self, item: _Item, connection: Connection) -> bool:
        """Block while the item is paused (after dropping what the engine queued); True if it was."""
        if not item.paused:
            return False
        self._flush(connection)
        while item.paused and not item.cancelled.wait(0.05):
            self._check_connection(connection)
        return True

    def _wait_drained(self, item: _Item, connection: Connection) -> bool:
        """Wait for the DRAINED of an END; False if a pause dropped the audio and END must be sent again."""
        while not self._drained.wait(0.05):
            if item.cancelled.is_set():
                raise Cancelled()
            if self._wait_while_paused(item, connection):
                return False
            self._check_connection(connection)
        return True

    def _check_connection(self, connection: Connection) -> None:
        if self._connection is not connection:
            raise ConnectionError("audio engine disconnected")

    def _flush(self, connection: Connection) -> None:
        if self._connection is not connection:
            return
        self._drained.clear()
        try:
            connection.send(FrameType.FLUSH)
        except OSError as err:
            self._log.warning("Could not flush the audio engine: %s", err)
            connection.close()
            return
        if not self._drained.wait(self._flush_timeout):
            self._log.warning("Audio engine did not confirm the flush within %.1fs", self._flush_timeout)

    def _finish(self, item: _Item, state: Optional[PlayerState], call_back: bool = False) -> None:
        callback = None
        with self._lock:
            if self._current is item:
                self._current = None
                if state is not None:
                    self._state = state
                if call_back and not item.cancelled.is_set():
                    callback = item.done_callback
        if callback is not None:
            try:
                callback()
            except Exception:  # pylint: disable=broad-except
                self._log.exception("Error in playback done callback")

    # -------- connection --------

    def _run_connection(self) -> None:
        delay = self._backoff[0]
        failing = False
        while not self._closed.is_set():
            try:
                connection, reply = Connection.open(self.path, {"role": self.role, **OUTPUT_FORMAT}, timeout=self._connect_timeout)
            except (OSError, HandshakeError, ProtocolError, ValueError) as err:
                if not failing:
                    self._log.warning("Audio engine playback unavailable at %s: %s (retrying)", self.path, err)
                    failing = True
                self._closed.wait(delay)
                delay = min(delay * 2, self._backoff[1])
                continue

            failing = False
            delay = self._backoff[0]
            self.buffer_ms = reply.get("buffer_ms")
            self._serve(connection)

    def _serve(self, connection: Connection) -> None:
        # Bounds sendall, so a stuck engine surfaces as an error instead of a
        # hang; the engine itself waits up to 3 s for an output without reading
        # and uses the same 5 s limit for its own sends
        connection.settimeout(self._send_timeout)
        self._connection = connection
        self._connected.set()
        self._log.info("Playback (%s) connected to the audio engine", self.role)
        try:
            while True:
                try:
                    frame = connection.read()
                except socket.timeout:
                    continue
                if frame is None:
                    break
                if frame.type == FrameType.DRAINED:
                    self._drained.set()
                elif frame.type == FrameType.EVENT:
                    self._on_event(frame.json())
                else:
                    self._log.debug("Ignoring %s frame on the %s connection", frame.type.name, self.role)
        except ProtocolError as err:
            self._log.error("Audio engine protocol error (%s): %s", err.code, err)
        except (OSError, ValueError) as err:
            if not (self._closed.is_set() or connection.closed):
                self._log.warning("Audio engine playback connection failed: %s", err)
        finally:
            self._connection = None
            self._connected.clear()
            connection.close()
            if not self._closed.is_set():
                self._log.warning("Playback (%s) disconnected from the audio engine", self.role)

    def _on_event(self, event: Dict) -> None:
        code = event.get("code")
        if code in ("interrupted", "protocol_error"):
            self._log.warning("Audio engine event on %s: %s", self.role, event)
        else:
            self._log.debug("Audio engine event on %s: %s", self.role, event)
