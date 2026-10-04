"""Tests for local address detection (netifaces2 on Linux, route lookup elsewhere)."""

import ipaddress
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from linux_voice_assistant import network, util
from tests.unit.conftest import install_requirements

linux_only = pytest.mark.skipif(not sys.platform.startswith("linux"), reason="netifaces2 is installed and used on Linux only")
darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="the route lookup backend is what macOS uses")


def adapter(name, index, *ips):
    """ifaddr.Adapter stand-in; each ip is "a.b.c.d/prefix" or an IPv6 tuple."""
    entries = []
    for ip in ips:
        if isinstance(ip, tuple):
            entries.append(SimpleNamespace(ip=ip, network_prefix=64, is_IPv4=False))
        else:
            address, prefix = ip.split("/")
            entries.append(SimpleNamespace(ip=address, network_prefix=int(prefix), is_IPv4=True))
    return SimpleNamespace(name=name, index=index, ips=entries)


MAC_ADAPTERS = [
    adapter("utun4", 23, "100.96.0.2/32"),
    adapter("lo0", 1, "127.0.0.1/8", ("::1", 0, 0)),
    adapter("en0", 11, "192.168.1.30/24"),
    adapter("en13", 13, ("fe80::1", 0, 13), "10.1.1.198/24"),
    adapter("awdl0", 17, ("fe80::2", 0, 17)),
]


@pytest.fixture
def route_backend(monkeypatch):
    """Force the route backend with fake adapters and a fake kernel route lookup."""
    monkeypatch.setattr(network, "_route_backend", True)
    state = SimpleNamespace(adapters=list(MAC_ADAPTERS), source="10.1.1.198")

    def route_source_ip():
        if isinstance(state.source, Exception):
            return None
        return state.source

    monkeypatch.setattr(network.ifaddr, "get_adapters", lambda: state.adapters)
    monkeypatch.setattr(network, "_route_source_ip", route_source_ip)
    return state


class TestLegacyBackend:
    def test_calls_the_unmodified_util_functions(self, monkeypatch):
        monkeypatch.setattr(network, "_route_backend", False)
        with (
            patch.object(util, "get_default_interface", return_value="wlan0") as get_interface,
            patch.object(util, "get_default_ipv4", return_value="192.168.33.7") as get_ipv4,
            patch.object(network.ifaddr, "get_adapters") as get_adapters,
        ):
            assert network.default_interface() == "wlan0"
            assert network.interface_ipv4("wlan0") == "192.168.33.7"

        get_interface.assert_called_once_with()
        get_ipv4.assert_called_once_with("wlan0")
        get_adapters.assert_not_called()

    def test_results_are_returned_untouched(self, monkeypatch):
        monkeypatch.setattr(network, "_route_backend", False)
        with patch.object(util, "get_default_interface", return_value=None), patch.object(util, "get_default_ipv4", return_value=None):
            assert network.default_interface() is None
            assert network.interface_ipv4(None) is None
        assert network.uses_route_backend() is False

    async def test_no_retry_on_the_legacy_backend(self, monkeypatch):
        monkeypatch.setattr(network, "_route_backend", False)
        with patch.object(util, "get_default_interface", return_value=None) as get_interface:
            assert await network.wait_for_default_interface(retry=0) is None
        get_interface.assert_called_once_with()

    @pytest.mark.usefixtures("route_backend")
    def test_netifaces_without_gateway_support_falls_back(self, monkeypatch):
        monkeypatch.setattr(network, "_route_backend", False)
        with patch.object(util, "get_default_interface", side_effect=NotImplementedError("No implementation for `gateways()` yet")):
            assert network.default_interface() == "en13"
        assert network.uses_route_backend() is True

    @linux_only
    def test_linux_uses_netifaces2(self):
        assert util.netifaces is not None
        network.default_interface()
        assert network.uses_route_backend() is False


class TestRouteBackend:
    @pytest.mark.usefixtures("route_backend")
    def test_default_route_address(self):
        found = network.find_local_address()
        assert found == network.LocalAddress(interface="en13", ip="10.1.1.198", prefix=24)

    @pytest.mark.usefixtures("route_backend")
    def test_default_interface_and_its_address(self):
        assert network.default_interface() == "en13"
        assert network.interface_ipv4("en13") == "10.1.1.198"

    @pytest.mark.usefixtures("route_backend")
    def test_explicit_interface_uses_its_first_address(self):
        assert network.find_local_address("en0") == network.LocalAddress(interface="en0", ip="192.168.1.30", prefix=24)
        assert network.interface_ipv4("en0") == "192.168.1.30"

    @pytest.mark.usefixtures("route_backend")
    def test_unknown_interface(self):
        assert network.find_local_address("en99") is None
        assert network.interface_ipv4("en99") is None
        assert network.interface_ipv4(None) is None

    def test_vpn_default_route_is_skipped(self, route_backend, caplog):
        route_backend.source = "100.96.0.2"
        assert network.find_local_address().interface == "en0"
        assert "--network-interface" in caplog.text

    @pytest.mark.parametrize("source", ["127.0.0.1", "169.254.10.1", "0.0.0.0"])
    def test_unusable_source_falls_back_to_a_private_address(self, route_backend, source):
        route_backend.source = source
        assert network.find_local_address().ip == "192.168.1.30"

    @pytest.mark.usefixtures("route_backend")
    def test_no_route_falls_back(self):
        route_backend.source = OSError(51, "Network is unreachable")
        assert network.find_local_address().interface == "en0"

    @pytest.mark.usefixtures("route_backend")
    def test_fallback_order_is_the_interface_index(self):
        route_backend.source = OSError(51, "Network is unreachable")
        route_backend.adapters = [adapter("en5", 9, "172.16.0.5/16"), adapter("en1", 4, "192.168.2.2/24")]
        assert network.find_local_address().interface == "en1"

    @pytest.mark.usefixtures("route_backend")
    def test_public_only_addresses_are_not_guessed(self):
        route_backend.source = OSError(51, "Network is unreachable")
        route_backend.adapters = [adapter("en0", 4, "203.0.113.9/24"), adapter("utun0", 5, "10.8.0.2/24")]
        assert network.find_local_address() is None
        assert network.default_interface() is None

    @pytest.mark.usefixtures("route_backend")
    def test_route_source_on_an_unknown_interface_falls_back(self):
        route_backend.source = "10.9.9.9"
        assert network.find_local_address().ip == "192.168.1.30"

    async def test_startup_waits_for_the_network(self, route_backend):
        route_backend.source = OSError(51, "Network is unreachable")
        route_backend.adapters = []
        answers = iter([[], [], MAC_ADAPTERS])
        with patch.object(network.ifaddr, "get_adapters", side_effect=lambda: next(answers)):
            assert await network.wait_for_default_interface(retry=0) == "en0"

    async def test_startup_gives_up_after_the_timeout(self, route_backend):
        route_backend.source = OSError(51, "Network is unreachable")
        route_backend.adapters = []
        assert await network.wait_for_default_interface(timeout=0.05, retry=0.01) is None

    @pytest.mark.parametrize(
        "name", ["lo0", "utun3", "tun0", "wg0", "tailscale0", "docker0", "veth12", "br-1a2b", "virbr0", "vmnet8", "vboxnet0", "awdl0", "llw0", "anpi0", "bridge100", "ppp0", "ipsec0", "zt0", "tap0"]
    )
    def test_virtual_interfaces(self, name):
        assert network.is_virtual(name)

    @pytest.mark.parametrize("name", ["en0", "en13", "eth0", "wlan0", "wlp0s20f3", "enp3s0"])
    def test_physical_interfaces(self, name):
        assert not network.is_virtual(name)


class _FakeUdpSocket:
    source = "10.1.1.198"
    error = None

    def __init__(self, *args):
        self.args = args

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def connect(self, address):
        assert address == ("192.0.2.1", 9)
        if self.error is not None:
            raise self.error

    def getsockname(self):
        return (self.source, 54321)


class TestRouteProbe:
    def test_source_address_of_the_default_route(self, monkeypatch):
        monkeypatch.setattr(network.socket, "socket", _FakeUdpSocket)
        assert network._route_source_ip() == "10.1.1.198"

    def test_no_route(self, monkeypatch):
        monkeypatch.setattr(_FakeUdpSocket, "error", OSError(51, "Network is unreachable"))
        monkeypatch.setattr(network.socket, "socket", _FakeUdpSocket)
        assert network._route_source_ip() is None


class TestMain:
    async def test_route_backend_without_address_exits(self, monkeypatch, tmp_path):
        import linux_voice_assistant.__main__ as lva_main

        monkeypatch.setattr(sys, "argv", ["linux-voice-assistant", "--download-dir", str(tmp_path)])
        monkeypatch.setattr(network, "_route_backend", True)
        monkeypatch.setattr(network, "wait_for_default_interface", MagicMock(side_effect=self._none))

        with pytest.raises(SystemExit) as exited:
            await lva_main.main()
        assert exited.value.code == 1

    @staticmethod
    async def _none():
        return None


class TestDependencies:
    def test_netifaces2_on_linux_only(self):
        assert "netifaces2" in install_requirements("linux")
        assert "netifaces2" not in install_requirements("darwin")

    def test_ifaddr_everywhere(self):
        assert "ifaddr" in install_requirements("linux")
        assert "ifaddr" in install_requirements("darwin")


@darwin_only
class TestMacOS:
    def test_netifaces2_not_installed(self):
        assert util.netifaces is None
        assert network.uses_route_backend() is True

    def test_real_route_lookup_finds_a_lan_address(self):
        found = network.find_local_address()
        assert found is not None
        address = ipaddress.ip_address(found.ip)
        assert not address.is_loopback and not address.is_link_local
        assert not network.is_virtual(found.interface)
