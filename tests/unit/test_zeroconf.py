"""Unit tests for HomeAssistantZeroconf."""

import errno
import logging
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def make_zeroconf(**kwargs):
    defaults = dict(
        port=6053,
        mac_address="aa:bb:cc:dd:ee:ff",
        host_ip_address="192.168.1.100",
        name="lva-test",
    )
    defaults.update(kwargs)

    with patch("linux_voice_assistant.zeroconf.AsyncZeroconf") as mock_zc_cls:
        mock_zc = MagicMock()
        mock_zc_cls.return_value = mock_zc
        from linux_voice_assistant.zeroconf import HomeAssistantZeroconf

        instance = HomeAssistantZeroconf(**defaults)
        instance._mock_zc = mock_zc
        instance._mock_zc_cls = mock_zc_cls
        return instance


# ---------------------------------------------------------------------------
# __init__
# ---------------------------------------------------------------------------


class TestInit:
    def test_name_stored(self):
        zc = make_zeroconf(name="my-lva")
        assert zc.name == "my-lva"

    def test_port_stored(self):
        zc = make_zeroconf(port=1234)
        assert zc.port == 1234

    def test_mac_address_stored(self):
        zc = make_zeroconf(mac_address="11:22:33:44:55:66")
        assert zc.mac_address == "11:22:33:44:55:66"

    def test_host_ip_stored(self):
        zc = make_zeroconf(host_ip_address="10.0.0.1")
        assert zc.host_ip_address == "10.0.0.1"

    def test_name_defaults_to_mac_when_not_provided(self):
        with patch("linux_voice_assistant.zeroconf.AsyncZeroconf"):
            from linux_voice_assistant.zeroconf import HomeAssistantZeroconf

            zc = HomeAssistantZeroconf(
                port=6053,
                mac_address="aa:bb:cc:dd:ee:ff",
                host_ip_address="192.168.1.1",
                name=None,
            )
        assert zc.name == "aa:bb:cc:dd:ee:ff"

    def test_async_zeroconf_instantiated(self):
        with patch("linux_voice_assistant.zeroconf.AsyncZeroconf") as mock_cls:
            mock_cls.return_value = MagicMock()
            from linux_voice_assistant.zeroconf import HomeAssistantZeroconf

            HomeAssistantZeroconf(
                port=6053,
                mac_address="aa:bb:cc:dd:ee:ff",
                host_ip_address="192.168.1.1",
            )
            mock_cls.assert_called_once()


# ---------------------------------------------------------------------------
# register_server()
# ---------------------------------------------------------------------------


class TestRegisterServer:
    @pytest.mark.asyncio
    async def test_register_service_called(self):
        zc = make_zeroconf()
        zc._mock_zc.async_register_service = AsyncMock()

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo"):
            await zc.register_server()

        zc._mock_zc.async_register_service.assert_called_once()

    @pytest.mark.asyncio
    async def test_service_name_contains_device_name(self):
        zc = make_zeroconf(name="lva-aabbccddee")
        zc._mock_zc.async_register_service = AsyncMock()

        captured = {}

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
            mock_info_cls.side_effect = lambda *a, **kw: captured.update({"args": a, "kwargs": kw}) or MagicMock()
            await zc.register_server()

        # First positional arg is service type, second is full service name
        assert "lva-aabbccddee" in captured["args"][1]

    @pytest.mark.asyncio
    async def test_service_type_is_esphomelib(self):
        zc = make_zeroconf()
        zc._mock_zc.async_register_service = AsyncMock()

        captured = {}

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
            mock_info_cls.side_effect = lambda *a, **kw: captured.update({"args": a, "kwargs": kw}) or MagicMock()
            await zc.register_server()

        assert captured["args"][0] == "_esphomelib._tcp.local."

    @pytest.mark.asyncio
    async def test_service_properties_contain_mac(self):
        zc = make_zeroconf(mac_address="aa:bb:cc:dd:ee:ff")
        zc._mock_zc.async_register_service = AsyncMock()

        captured = {}

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
            mock_info_cls.side_effect = lambda *a, **kw: captured.update({"args": a, "kwargs": kw}) or MagicMock()
            await zc.register_server()

        props = captured["kwargs"].get("properties", {})
        assert "mac" in props
        assert props["mac"] == "aa:bb:cc:dd:ee:ff"

    @pytest.mark.asyncio
    async def test_service_properties_contain_version(self):
        zc = make_zeroconf()
        zc._mock_zc.async_register_service = AsyncMock()

        captured = {}

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
            mock_info_cls.side_effect = lambda *a, **kw: captured.update({"args": a, "kwargs": kw}) or MagicMock()
            await zc.register_server()

        props = captured["kwargs"].get("properties", {})
        assert "version" in props

    @pytest.mark.asyncio
    async def test_service_port_matches(self):
        zc = make_zeroconf(port=9999)
        zc._mock_zc.async_register_service = AsyncMock()

        captured = {}

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
            mock_info_cls.side_effect = lambda *a, **kw: captured.update({"args": a, "kwargs": kw}) or MagicMock()
            await zc.register_server()

        assert captured["kwargs"].get("port") == 9999

    @pytest.mark.asyncio
    async def test_service_address_matches_host_ip(self):
        import socket

        zc = make_zeroconf(host_ip_address="10.0.0.5")
        zc._mock_zc.async_register_service = AsyncMock()

        captured = {}

        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
            mock_info_cls.side_effect = lambda *a, **kw: captured.update({"args": a, "kwargs": kw}) or MagicMock()
            await zc.register_server()

        addresses = captured["kwargs"].get("addresses", [])
        assert socket.inet_aton("10.0.0.5") in addresses


class TestClose:
    @pytest.mark.asyncio
    async def test_close_sends_goodbyes_through_zeroconf(self):
        zc = make_zeroconf()
        zc._mock_zc.async_close = AsyncMock()

        await zc.async_close()

        zc._mock_zc.async_close.assert_awaited_once_with()


# ---------------------------------------------------------------------------
# friendly_name and withdrawal (--follow-network)
# ---------------------------------------------------------------------------


async def _registered_properties(zc):
    zc._mock_zc.async_register_service = AsyncMock()
    captured = {}
    with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo") as mock_info_cls:
        mock_info_cls.side_effect = lambda *a, **kw: captured.update(kw) or MagicMock()
        await zc.register_server()
    return captured["properties"]


class TestFriendlyName:
    async def test_not_announced_by_default(self):
        assert "friendly_name" not in await _registered_properties(make_zeroconf())

    async def test_announced_when_given(self):
        properties = await _registered_properties(make_zeroconf(friendly_name="Mac bureau"))
        assert properties["friendly_name"] == "Mac bureau"


class TestWithdraw:
    async def test_withdraw_then_announce_registers_again(self):
        zc = make_zeroconf()
        zc._mock_zc.async_register_service = AsyncMock()
        zc._mock_zc.async_unregister_service = AsyncMock()
        zc._mock_zc.async_update_service = AsyncMock()
        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo"):
            await zc.register_server()
            await zc.async_withdraw()
            await zc.async_withdraw()
            await zc.async_announce()

        zc._mock_zc.async_unregister_service.assert_awaited_once()
        assert zc._mock_zc.async_register_service.await_count == 2
        zc._mock_zc.async_update_service.assert_not_awaited()

    async def test_announce_updates_a_registered_service(self):
        zc = make_zeroconf()
        zc._mock_zc.async_register_service = AsyncMock()
        zc._mock_zc.async_update_service = AsyncMock()
        with patch("linux_voice_assistant.zeroconf.AsyncServiceInfo"):
            await zc.register_server()
            await zc.async_announce()

        zc._mock_zc.async_update_service.assert_awaited_once()


# ---------------------------------------------------------------------------
# macOS Local Network refusals
# ---------------------------------------------------------------------------


class TestLocalNetworkFilter:
    def record(self, error):
        msg = "Error with socket 12 (('10.1.1.198', 5353))): %s"
        return logging.LogRecord("zeroconf", logging.WARNING, __file__, 1, msg, (error,), (type(error), error, None))

    def test_no_route_to_host_becomes_one_line(self):
        from linux_voice_assistant.zeroconf import LocalNetworkFilter

        record = self.record(OSError(errno.EHOSTUNREACH, "No route to host"))

        assert LocalNetworkFilter().filter(record)
        assert record.exc_info is None
        expected = "mDNS send refused on 12 (('10.1.1.198', 5353)) (no route to host): HA Satellite has no Local Network access yet; allow it in System Settings > Privacy & Security > Local Network"
        assert record.getMessage() == expected

    def test_other_errors_are_kept(self):
        from linux_voice_assistant.zeroconf import LocalNetworkFilter

        record = self.record(OSError(errno.EADDRNOTAVAIL, "Can't assign requested address"))

        assert LocalNetworkFilter().filter(record)
        assert record.exc_info is not None
        assert record.getMessage().startswith("Error with socket")

    def test_installed_only_on_macos(self):
        from linux_voice_assistant.zeroconf import LocalNetworkFilter

        installed = any(isinstance(f, LocalNetworkFilter) for f in logging.getLogger("zeroconf").filters)
        assert installed == (sys.platform == "darwin")
