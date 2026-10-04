"""Control role of an external audio engine (``--control-socket``).

The engine's menu shows LVA's state and sends commands; LVA's ServerState stays
the only source of truth. Every change produces one full state snapshot with a
higher ``rev``; commands are explicit (``mute_mic``/``unmute_mic``, never a
toggle) and acknowledged with their ``id``. Mute goes through the same path as
the Home Assistant switch, so the switch and the menu always agree.
"""

import asyncio
import logging
import threading
from typing import TYPE_CHECKING, Any, Callable, Dict, Optional, Tuple

from .helper_protocol import PROTO, FrameDecoder, FrameType, HandshakeError, ProtocolError, json_frame
from .peripheral_api import LVAEvent, push_mute_switch

if TYPE_CHECKING:
    from .models import ServerState

_LOGGER = logging.getLogger(__name__)

_PHASES = {
    LVAEvent.IDLE: "idle",
    LVAEvent.TTS_FINISHED: "idle",
    LVAEvent.DISCONNECTED: "idle",
    LVAEvent.WAKE_WORD_DETECTED: "wake",
    LVAEvent.LISTENING: "listening",
    LVAEvent.THINKING: "thinking",
    LVAEvent.TTS_SPEAKING: "speaking",
    LVAEvent.TIMER_RINGING: "timer",
}

_MEDIA_STATES = {"PLAYING": "playing", "PAUSED": "paused"}


class ControlChannel:
    """
    Client of the engine's ``control`` role: state snapshots out, commands in.

    If the connection stays closed for ``lost_after`` seconds (including at
    start), ``on_lost`` is called so the process exits instead of staying
    available in Home Assistant without the app that owns its microphone.
    """

    def __init__(
        self,
        path: str,
        state: "ServerState",
        on_lost: Callable[[], None],
        lva_version: str = "",
        lost_after: float = 30.0,
        backoff: Tuple[float, float] = (0.5, 5.0),
        poll_interval: float = 1.0,
    ) -> None:
        self.path = path
        self.state = state
        self.on_lost = on_lost
        self.lva_version = lva_version
        self.lost_after = lost_after
        self.backoff = backoff
        self.poll_interval = poll_interval

        self.rev = 0
        self.phase = "idle"
        self._error_reason: Optional[str] = None
        self._error_rev: Optional[int] = None
        self._last_sent: Optional[Dict[str, Any]] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._loop_thread: Optional[int] = None
        self._down_since: Optional[float] = None
        self._tasks: list = []

    # -------- lifecycle --------

    @property
    def connected(self) -> bool:
        return self._writer is not None

    async def start(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._loop_thread = threading.get_ident()
        self._down_since = self._loop.time()
        self._tasks = [asyncio.create_task(task) for task in (self._run(), self._watch())]

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        self._tasks = []
        self._close()

    # -------- state from LVA (any thread) --------

    def on_event(self, event: LVAEvent, data: Optional[Dict[str, Any]] = None) -> None:
        self._call(self._apply_event, event)

    def pipeline_error(self, reason: str) -> None:
        self._call(self._apply_error, reason)

    def _call(self, func: Callable, *args) -> None:
        loop = self._loop
        if loop is None or self._loop_thread == threading.get_ident():
            func(*args)
            return
        try:
            loop.call_soon_threadsafe(func, *args)
        except RuntimeError:
            pass  # loop closed: shutting down

    def _apply_event(self, event: LVAEvent) -> None:
        phase = _PHASES.get(event)
        if phase is not None:
            self.phase = phase
        if event == LVAEvent.MUTED and self.state.muted:
            self.phase = "idle"
        if event == LVAEvent.LISTENING:
            self._error_reason = None
            self._error_rev = None
        self.push()

    def _apply_error(self, reason: str) -> None:
        self._error_reason = reason
        self._error_rev = None
        self.push()

    def snapshot(self) -> Dict[str, Any]:
        """The current state, without ``rev``."""
        media_entity = self.state.media_player_entity
        media_state = getattr(getattr(media_entity, "state", None), "name", "IDLE")
        error = None
        if self._error_reason is not None:
            error = {"reason": self._error_reason, "rev": self._error_rev}
        return {
            "ha_connected": bool(self.state.connected),
            "muted": bool(self.state.muted),
            "ptt": bool(self.state.mute_override),
            "phase": self.phase,
            "media": _MEDIA_STATES.get(media_state, "idle"),
            "error": error,
        }

    def push(self, force: bool = False) -> None:
        """Send a new snapshot if anything changed since the last one (or always with force)."""
        if self._writer is None:
            return
        snapshot = self.snapshot()
        if self._error_reason is not None and self._error_rev is None:
            # The error carries the rev of the first snapshot that shows it
            self._error_rev = self.rev + 1
            snapshot["error"] = {"reason": self._error_reason, "rev": self._error_rev}
        if not force and snapshot == self._last_sent:
            return
        self.rev += 1
        self._last_sent = snapshot
        self._send({"state": {"rev": self.rev, **snapshot}})

    # -------- connection --------

    def _send(self, value: Dict[str, Any]) -> None:
        writer = self._writer
        if writer is None:
            return
        try:
            writer.write(json_frame(FrameType.CONTROL, value))
        except (OSError, RuntimeError) as err:
            _LOGGER.debug("Control message not sent: %s", err)

    def _close(self) -> None:
        writer, self._writer = self._writer, None
        if writer is not None:
            writer.close()
        if self._loop is not None and self._down_since is None:
            self._down_since = self._loop.time()

    async def _run(self) -> None:
        delay = self.backoff[0]
        failing = False
        while True:
            try:
                reader, writer = await asyncio.open_unix_connection(self.path)
            except OSError as err:
                if not failing:
                    _LOGGER.warning("Audio engine control unavailable at %s: %s (retrying)", self.path, err)
                    failing = True
                await asyncio.sleep(delay)
                delay = min(delay * 2, self.backoff[1])
                continue

            failing = False
            delay = self.backoff[0]
            try:
                await self._serve(reader, writer)
            except (OSError, ProtocolError, HandshakeError, ValueError) as err:
                _LOGGER.warning("Audio engine control connection failed: %s", err)
            finally:
                writer.close()
                self._close()
            await asyncio.sleep(delay)

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        decoder = FrameDecoder()
        writer.write(json_frame(FrameType.HELLO, {"proto": PROTO, "role": "control", "lva_version": self.lva_version}))
        pending: list = []
        while not pending:
            data = await reader.read(65536)
            if not data:
                decoder.finish()
                raise HandshakeError("connection closed before the HELLO reply")
            pending = decoder.feed(data)
        first = pending.pop(0)
        if first.type != FrameType.HELLO:
            raise HandshakeError(f"expected a HELLO reply, got {first.type.name}")
        reply = first.json()
        if reply.get("accepted") is False:
            raise HandshakeError(f"refused: {reply.get('reason', 'no reason given')}")
        if reply.get("proto") != PROTO:
            raise HandshakeError(f"unsupported protocol version {reply.get('proto')!r}")

        self._writer = writer
        self._down_since = None
        _LOGGER.info("Control connected to the audio engine")
        self.push(force=True)

        while True:
            for frame in pending:
                if frame.type == FrameType.CONTROL:
                    await self._handle(frame.json())
                elif frame.type == FrameType.EVENT:
                    _LOGGER.debug("Audio engine control event: %s", frame.json())
                else:
                    _LOGGER.debug("Ignoring %s frame on the control connection", frame.type.name)
            data = await reader.read(65536)
            if not data:
                decoder.finish()
                _LOGGER.warning("Control disconnected from the audio engine")
                return
            pending = decoder.feed(data)

    async def _handle(self, message: Dict[str, Any]) -> None:
        command = message.get("command")
        if command is None:
            # Acks of commands LVA sent, or anything newer: nothing to do
            return
        reason = self._run_command(str(command), message.get("data") or {})
        ack: Dict[str, Any] = {"ack": message.get("id"), "ok": reason is None}
        if reason is not None:
            ack["reason"] = reason
            _LOGGER.info("Control command %s refused: %s", command, reason)
        self._send(ack)
        self.push()

    def _run_command(self, command: str, data: Dict[str, Any]) -> Optional[str]:
        """Run a command from the engine; return why it was refused, or None."""
        state = self.state
        satellite = state.satellite

        if command in ("mute_mic", "unmute_mic"):
            muted = command == "mute_mic"
            if state.muted == muted:
                return None
            if satellite is not None:
                satellite._set_muted(muted)  # pylint: disable=protected-access
                push_mute_switch(state, satellite, muted)
            else:
                # Not connected to Home Assistant: the switch shows it on reconnect
                state.muted = muted
                state.mute_override = False
                if state.persist_mute:
                    state.preferences.muted = muted
                    state.save_preferences()
                state.tts_player.play(state.mute_sound if muted else state.unmute_sound)
                self._apply_event(LVAEvent.MUTED)
            return None

        if command == "start_listening":
            if satellite is None or not state.connected:
                return "not_connected"
            allow_muted = bool(data.get("allow_muted"))
            if state.muted and not allow_muted:
                return "muted"
            if not satellite.start_listening(allow_muted=allow_muted):
                return "pipeline_active"
            return None

        if command == "stop_pipeline":
            if satellite is None:
                return "not_connected"
            satellite.stop()
            return None

        return "unknown_command"

    async def _watch(self) -> None:
        loop = asyncio.get_running_loop()
        while True:
            await asyncio.sleep(self.poll_interval)
            if self._writer is not None:
                # Catches changes that emit no event (media state, HA connection)
                self.push()
            elif self._down_since is not None and loop.time() - self._down_since >= self.lost_after:
                _LOGGER.error("No control connection to the audio engine for %.0fs, exiting", self.lost_after)
                self._down_since = None
                self.on_lost()
