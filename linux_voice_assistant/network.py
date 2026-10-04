"""Local network address detection.

Two backends:

- netifaces2 (Linux): the unmodified ``util.get_default_interface`` and
  ``util.get_default_ipv4``, so the interface, and therefore the MAC address
  and device id, are exactly what they always were.
- route (where netifaces2 is not installed or cannot read the routing table,
  e.g. macOS): the kernel picks the source address of a route to a
  documentation address, which is mapped back to its interface with ifaddr.
"""

import asyncio
import ipaddress
import logging
import socket
from dataclasses import dataclass
from typing import List, Optional

import ifaddr

from . import util

_LOGGER = logging.getLogger(__name__)

# TEST-NET-1 (RFC 5737): connect() on a UDP socket only selects a route, nothing is sent
_PROBE_ADDRESS = ("192.0.2.1", 9)

# Interfaces that never carry the LAN Home Assistant is on: loopback, VPN
# tunnels, container and VM bridges, Apple's peer-to-peer links
VIRTUAL_PREFIXES = (
    "lo",
    "utun",
    "tun",
    "tap",
    "ppp",
    "ipsec",
    "wg",
    "tailscale",
    "zt",
    "docker",
    "veth",
    "br-",
    "virbr",
    "vmnet",
    "vboxnet",
    "awdl",
    "llw",
    "anpi",
    "bridge",
)

_PRIVATE_NETWORKS = tuple(ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))

STARTUP_RETRY_SECONDS = 2.0
STARTUP_TIMEOUT_SECONDS = 60.0

_route_backend = util.netifaces is None


@dataclass(frozen=True)
class LocalAddress:
    interface: str
    ip: str
    prefix: Optional[int] = None


def uses_route_backend() -> bool:
    return _route_backend


def default_interface() -> Optional[str]:
    """Return the interface of the default route, or None."""
    global _route_backend

    if not _route_backend:
        try:
            interface: Optional[str] = util.get_default_interface()
            return interface
        except NotImplementedError:
            # netifaces2 has no routing table reader on this platform
            _LOGGER.debug("netifaces2 cannot read the default gateway here, using the route lookup")
            _route_backend = True

    found = find_local_address()
    return found.interface if found else None


def interface_ipv4(interface: Optional[str]) -> Optional[str]:
    """Return the IPv4 address to use on the interface, or None."""
    if not _route_backend:
        ip: Optional[str] = util.get_default_ipv4(interface)  # type: ignore[arg-type]
        return ip

    if not interface:
        return None
    found = find_local_address()
    if found and found.interface == interface:
        return found.ip
    found = find_local_address(interface)
    return found.ip if found else None


async def wait_for_default_interface(timeout: float = STARTUP_TIMEOUT_SECONDS, retry: float = STARTUP_RETRY_SECONDS) -> Optional[str]:
    """Return the default interface, waiting for the network at startup on the route backend."""
    interface = default_interface()
    if not _route_backend:
        return interface

    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while interface is None and loop.time() < deadline:
        _LOGGER.warning("No usable network address yet, retrying in %.0fs", retry)
        await asyncio.sleep(retry)
        interface = default_interface()
    return interface


def find_local_address(interface: Optional[str] = None) -> Optional[LocalAddress]:
    """Find the local IPv4 address on the route backend.

    With an interface, its first usable IPv4 address. Otherwise the source
    address the kernel uses for the default route, unless it belongs to a
    virtual interface (a VPN taking the default route, for example); then
    the first private address of a physical interface.
    """
    addresses = _ipv4_addresses()

    if interface:
        return next((address for address in addresses if address.interface == interface and _is_usable(address.ip)), None)

    source_ip = _route_source_ip()
    if source_ip and _is_usable(source_ip):
        for address in addresses:
            if address.ip == source_ip and not is_virtual(address.interface):
                return address

    for address in addresses:
        if not is_virtual(address.interface) and _is_private(address.ip):
            _LOGGER.warning("Default route is not usable, using %s on %s; pass --network-interface to choose", address.ip, address.interface)
            return address

    return None


def is_virtual(interface: str) -> bool:
    return interface.lower().startswith(VIRTUAL_PREFIXES)


def _route_source_ip() -> Optional[str]:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(_PROBE_ADDRESS)
            return str(sock.getsockname()[0])
    except OSError as err:
        _LOGGER.debug("No route to %s: %s", _PROBE_ADDRESS[0], err)
        return None


def _ipv4_addresses() -> List[LocalAddress]:
    adapters = sorted(ifaddr.get_adapters(), key=lambda adapter: adapter.index or 0)
    return [LocalAddress(interface=adapter.name, ip=ip.ip, prefix=ip.network_prefix) for adapter in adapters for ip in adapter.ips if ip.is_IPv4 and isinstance(ip.ip, str)]


def _is_usable(ip: str) -> bool:
    address = ipaddress.ip_address(ip)
    return not (address.is_loopback or address.is_link_local or address.is_unspecified)


def _is_private(ip: str) -> bool:
    address = ipaddress.ip_address(ip)
    return any(address in network for network in _PRIVATE_NETWORKS)


def physical_ipv4_addresses() -> List[str]:
    """IPv4 addresses of every non-virtual interface (for zeroconf with --follow-network)."""
    return [address.ip for address in _ipv4_addresses() if not is_virtual(address.interface) and _is_usable(address.ip)]


def enable_keepalive(sock: Optional[socket.socket], idle: int = 30, interval: int = 10, count: int = 3) -> None:
    """Turn on TCP keepalive so a peer that vanished (e.g. during sleep) is noticed."""
    if sock is None:
        return
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    # TCP_KEEPIDLE on Linux, TCP_KEEPALIVE (same meaning) on macOS
    idle_option = getattr(socket, "TCP_KEEPIDLE", None) or getattr(socket, "TCP_KEEPALIVE", None)
    if idle_option is not None:
        sock.setsockopt(socket.IPPROTO_TCP, idle_option, idle)
    if hasattr(socket, "TCP_KEEPINTVL"):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, interval)
    if hasattr(socket, "TCP_KEEPCNT"):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, count)
