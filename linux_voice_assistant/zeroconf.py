"""Runs mDNS zeroconf service for Home Assistant discovery."""

import logging
import socket
from typing import List, Optional

_LOGGER = logging.getLogger(__name__)

try:
    from zeroconf.asyncio import AsyncServiceInfo, AsyncZeroconf
except ImportError:
    _LOGGER.fatal("zeroconf not installed. Please install it with: pip install zeroconf")
    raise

MDNS_TARGET_IP = "224.0.0.251"


class HomeAssistantZeroconf:
    def __init__(
        self,
        port: int,
        mac_address: str,
        host_ip_address: str,
        name: Optional[str] = None,
        interfaces: Optional[List[str]] = None,
    ) -> None:
        self.port = port
        self.mac_address = mac_address
        self.name = name or self.mac_address
        self.host_ip_address = host_ip_address
        self.interfaces = interfaces
        self._service_info: Optional[AsyncServiceInfo] = None

        self._aiozc = self._create()

    def _create(self) -> AsyncZeroconf:
        # Without an explicit list, zeroconf's own default (every interface), as always
        return AsyncZeroconf(interfaces=self.interfaces) if self.interfaces else AsyncZeroconf()

    async def register_server(self) -> None:

        service_info = AsyncServiceInfo(
            "_esphomelib._tcp.local.",
            f"{self.name}._esphomelib._tcp.local.",
            addresses=[socket.inet_aton(self.host_ip_address)],
            port=self.port,
            properties={
                "version": "2025.9.0",
                "mac": self.mac_address,
                "board": "host",
                "platform": "HOST",
                "network": "ethernet",  # or "wifi"
            },
            server=f"{self.name}.local.",
        )
        await self._aiozc.async_register_service(service_info)
        self._service_info = service_info
        _LOGGER.debug("Zeroconf discovery enabled: %s", service_info)

    async def async_announce(self) -> None:
        """Announce the registered service again (e.g. after the system woke up)."""
        if self._service_info is not None:
            await self._aiozc.async_update_service(self._service_info)

    async def async_update_address(self, host_ip_address: str) -> None:
        """Withdraw the service (mDNS goodbye), then register it with the new address."""
        if self._service_info is not None:
            await self._aiozc.async_unregister_service(self._service_info)
        self.host_ip_address = host_ip_address
        await self.register_server()

    async def async_update_interfaces(self, interfaces: List[str]) -> None:
        """Use these interface addresses from now on; recreate zeroconf if it cannot switch in place."""
        if interfaces == self.interfaces:
            return
        self.interfaces = interfaces
        try:
            await self._aiozc.async_update_interfaces(interfaces)
        except Exception:  # pylint: disable=broad-except
            _LOGGER.warning("Could not update the zeroconf interfaces in place, restarting zeroconf", exc_info=True)
            await self._aiozc.async_close()
            self._aiozc = self._create()
            if self._service_info is not None:
                await self.register_server()

    async def async_close(self) -> None:
        """Withdraw the service (mDNS goodbye) and close zeroconf."""
        await self._aiozc.async_close()
        _LOGGER.debug("Zeroconf discovery closed")
