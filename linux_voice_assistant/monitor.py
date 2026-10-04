"""Follow address changes and system sleep (--follow-network)."""

import asyncio
import logging
import time
from typing import Awaitable, Callable, Iterable, List, Optional

from . import network

_LOGGER = logging.getLogger(__name__)

# A clock that keeps counting while the system sleeps: CLOCK_BOOTTIME on
# Linux; on macOS CLOCK_MONOTONIC counts sleep while time.monotonic() does not
SLEEP_CLOCK_ID = getattr(time, "CLOCK_BOOTTIME", getattr(time, "CLOCK_MONOTONIC", None))


def sleep_clock() -> float:
    if SLEEP_CLOCK_ID is None:
        return time.monotonic()
    return time.clock_gettime(SLEEP_CLOCK_ID)


class NetworkMonitor:
    """
    Polls the local address and notices system sleep.

    After a wake (a gap between the two clocks) or an address change, it
    waits until the address is stable, drops Home Assistant connections when
    they cannot have survived, points zeroconf at the current interfaces and
    announces the service again, so Home Assistant reconnects at once.

    An audio engine can also report sleep and wake (will_sleep, did_wake,
    network_changed). While it is connected (``engine_events`` returns True)
    its events replace the clock comparison, which also fires on dark wakes.
    """

    def __init__(
        self,
        discovery,
        connections: Callable[[], Iterable],
        find_address: Callable[[], Optional[str]],
        address: Optional[str],
        follow_address: bool = True,
        on_address: Optional[Callable[[str], None]] = None,
        interfaces: Callable[[], List[str]] = network.physical_ipv4_addresses,
        interval: float = 5.0,
        sleep_gap: float = 10.0,
        abort_gap: float = 30.0,
        settle_poll: float = 1.0,
        settle_timeout: float = 60.0,
        reannounce_delay: float = 5.0,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = sleep_clock,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        engine_events: Callable[[], bool] = lambda: False,
    ) -> None:
        self.discovery = discovery
        self.connections = connections
        self.find_address = find_address
        self.address = address
        self.follow_address = follow_address
        self.on_address = on_address
        self.interfaces = interfaces
        self.interval = interval
        self.sleep_gap = sleep_gap
        self.abort_gap = abort_gap
        self.settle_poll = settle_poll
        self.settle_timeout = settle_timeout
        self.reannounce_delay = reannounce_delay
        self._clock = clock
        self._wall_clock = wall_clock
        self._sleep = sleep
        self.engine_events = engine_events
        self._last = (clock(), wall_clock())
        self._reannounce: Optional[asyncio.Task] = None
        self._asleep = False
        self._retry_gap: Optional[float] = None

    async def run(self) -> None:
        while True:
            await self._sleep(self.interval)
            try:
                await self.check()
            except Exception:  # pylint: disable=broad-except
                _LOGGER.exception("Network check failed")

    async def check(self) -> None:
        """One poll: resync after a sleep gap or an address change."""
        gap = self._sleep_gap()
        address = self.find_address() if self.follow_address else self.address
        if self._asleep:
            return
        if self._retry_gap is not None:
            # A resync after an engine wake found no address yet
            if await self.resync(self._retry_gap):
                self._retry_gap = None
            return
        if gap > self.sleep_gap and not self.engine_events():
            _LOGGER.info("System slept for about %.0fs", gap)
            await self.resync(gap)
        elif address is not None and address != self.address:
            _LOGGER.info("Local address changed from %s to %s", self.address, address)
            await self.resync(0.0)

    async def resync(self, gap: float) -> bool:
        """Announce again on the current address; False if no stable address was found."""
        address = await self._stable_address() if self.follow_address else self.address
        if address is None:
            _LOGGER.warning("No stable network address, will retry")
            return False

        changed = address != self.address
        if changed or gap >= self.abort_gap:
            # Home Assistant only follows a new address while the device is unavailable
            for connection in list(self.connections()):
                connection.abort()

        await self.discovery.async_update_interfaces(self.interfaces())
        if changed:
            await self.discovery.async_update_address(address)
            self.address = address
            if self.on_address is not None:
                self.on_address(address)
        else:
            await self.discovery.async_announce()

        if self._reannounce is not None:
            self._reannounce.cancel()
        self._reannounce = asyncio.create_task(self._announce_later())
        self._last = (self._clock(), self._wall_clock())
        return True

    async def will_sleep(self) -> None:
        """The system is about to sleep: say goodbye over mDNS and drop the Home Assistant connections."""
        _LOGGER.info("System going to sleep, withdrawing the service")
        self._asleep = True
        if self._reannounce is not None:
            self._reannounce.cancel()
        await self.discovery.async_withdraw()
        for connection in list(self.connections()):
            connection.abort()

    async def did_wake(self) -> None:
        """The system woke up: announce again (connections are dropped unless will_sleep already did)."""
        _LOGGER.info("System woke up")
        gap = 0.0 if self._asleep else self.abort_gap
        self._asleep = False
        if not await self.resync(gap):
            self._retry_gap = gap

    async def network_changed(self) -> None:
        """A hint that the network path changed: check the address now."""
        if not self._asleep:
            await self.resync(0.0)

    async def stop(self) -> None:
        if self._reannounce is not None:
            self._reannounce.cancel()

    def _sleep_gap(self) -> float:
        now = (self._clock(), self._wall_clock())
        gap = (now[1] - self._last[1]) - (now[0] - self._last[0])
        self._last = now
        return gap

    async def _stable_address(self) -> Optional[str]:
        """Wait until two consecutive polls return the same usable address."""
        previous = self.find_address()
        waited = 0.0
        while waited < self.settle_timeout:
            await self._sleep(self.settle_poll)
            waited += self.settle_poll
            current = self.find_address()
            if current is not None and current == previous:
                return current
            previous = current
        return None

    async def _announce_later(self) -> None:
        await self._sleep(self.reannounce_delay)
        await self.discovery.async_announce()
