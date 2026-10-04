"""Graceful shutdown on signals and fatal errors."""

import asyncio
import logging
import os
import signal
import sys
from typing import Awaitable, Callable, Iterable, Optional, Tuple

_LOGGER = logging.getLogger(__name__)

SHUTDOWN_SIGNALS = (signal.SIGTERM, signal.SIGINT)

CleanupStep = Tuple[str, Callable[[], Awaitable[None]]]


class Shutdown:
    """
    Records the first reason to stop and runs the cleanup once.

    A signal or a fatal error only sets an event; the cleanup runs on the
    event loop with an overall time budget. After it, the process exits with
    the same status as before: killed by the same signal, or the error's code.
    """

    def __init__(self, loop: Optional[asyncio.AbstractEventLoop] = None) -> None:
        self.code: Optional[int] = None
        self.signal: Optional[int] = None
        self._event = asyncio.Event()
        self._loop = loop

    @property
    def requested(self) -> bool:
        return self._event.is_set()

    def install(self, signals: Iterable[int] = SHUTDOWN_SIGNALS) -> None:
        """Handle the given signals on the event loop."""
        assert self._loop is not None
        for sig in signals:
            self._loop.add_signal_handler(sig, self.request_signal, sig)

    def request_signal(self, sig: int) -> None:
        if self.requested:
            _LOGGER.debug("Ignoring %s, already shutting down", signal.Signals(sig).name)
            return
        _LOGGER.info("Received %s, shutting down", signal.Signals(sig).name)
        self.signal = sig
        self._event.set()

    def request_exit(self, code: int) -> None:
        if self.requested:
            return
        self.code = code
        self._event.set()

    def request_exit_threadsafe(self, code: int) -> None:
        """Request an exit from another thread (e.g. the audio thread)."""
        if self._loop is None:
            self.request_exit(code)
            return
        try:
            self._loop.call_soon_threadsafe(self.request_exit, code)
        except RuntimeError:
            # Loop already closed: the process is exiting anyway
            pass

    async def wait(self) -> None:
        await self._event.wait()

    async def cleanup(self, steps: Iterable[CleanupStep], budget: float = 5.0) -> None:
        """Run each step in order; a failing step is logged, a slow cleanup is cut at the budget."""

        async def run_steps() -> None:
            for name, step in steps:
                try:
                    await step()
                except Exception:  # pylint: disable=broad-except
                    _LOGGER.exception("Shutdown step failed: %s", name)

        try:
            await asyncio.wait_for(run_steps(), timeout=budget)
        except asyncio.TimeoutError:
            _LOGGER.warning("Shutdown took longer than %.1fs, exiting anyway", budget)

    def exit(self) -> None:
        """Exit the process with the status the shutdown reason calls for."""
        if self.signal is not None:
            # Die by the signal itself, so the status seen by systemd, Docker
            # or a shell is the same as without a handler.
            signal.signal(self.signal, signal.SIG_DFL)
            os.kill(os.getpid(), self.signal)
        if self.code:
            sys.exit(self.code)
