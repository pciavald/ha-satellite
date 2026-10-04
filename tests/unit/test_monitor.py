"""Tests for --follow-network: sleep and address monitoring, zeroconf updates, keepalive."""

import asyncio
import socket
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from linux_voice_assistant import monitor as monitor_module
from linux_voice_assistant import network
from linux_voice_assistant.api_server import APIServer
from linux_voice_assistant.monitor import NetworkMonitor

_REPO_DIR = Path(__file__).resolve().parents[2]

linux_only = pytest.mark.skipif(not sys.platform.startswith("linux"), reason="Linux clocks")
darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS clocks")


class Clocks:
    """time.monotonic stops during sleep; the wall clock keeps counting."""

    def __init__(self) -> None:
        self.monotonic = 1000.0
        self.wall = 5000.0

    def advance(self, seconds: float, slept: float = 0.0) -> None:
        self.monotonic += seconds
        self.wall += seconds + slept


@pytest.fixture
def clocks():
    return Clocks()


def make_monitor(clocks, addresses, **kwargs):
    """Monitor with fake clocks, a scripted address source and instant sleeps."""
    discovery = MagicMock()
    discovery.async_update_interfaces = AsyncMock()
    discovery.async_update_address = AsyncMock()
    discovery.async_announce = AsyncMock()
    connection = MagicMock()
    answers = iter(addresses)
    last = {"value": None}

    def find_address():
        last["value"] = next(answers, last["value"])
        return last["value"]

    async def no_sleep(_seconds):
        await asyncio.sleep(0)

    options = {
        "discovery": discovery,
        "connections": lambda: [connection],
        "find_address": find_address,
        "address": "10.1.1.198",
        "interfaces": lambda: ["10.1.1.198"],
        "clock": lambda: clocks.monotonic,
        "wall_clock": lambda: clocks.wall,
        "sleep": no_sleep,
    }
    options.update(kwargs)
    return NetworkMonitor(**options), discovery, connection


class TestChecks:
    async def test_steady_state_does_nothing(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 3)
        clocks.advance(5)
        await monitor.check()

        discovery.async_update_interfaces.assert_not_awaited()
        discovery.async_announce.assert_not_awaited()
        connection.abort.assert_not_called()

    async def test_long_sleep_drops_connections_and_announces(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 5)
        clocks.advance(5, slept=600)
        await monitor.check()
        await monitor._reannounce

        connection.abort.assert_called_once_with()
        discovery.async_update_interfaces.assert_awaited_once_with(["10.1.1.198"])
        discovery.async_update_address.assert_not_awaited()
        assert discovery.async_announce.await_count == 2  # now, then again a few seconds later

    async def test_short_sleep_announces_without_dropping(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 5)
        clocks.advance(5, slept=15)
        await monitor.check()

        connection.abort.assert_not_called()
        discovery.async_announce.assert_awaited()

    async def test_address_change_moves_the_service(self, clocks):
        on_address = MagicMock()
        monitor, discovery, connection = make_monitor(clocks, ["192.168.1.30"] * 5, on_address=on_address)
        clocks.advance(5)
        await monitor.check()

        connection.abort.assert_called_once_with()
        discovery.async_update_address.assert_awaited_once_with("192.168.1.30")
        on_address.assert_called_once_with("192.168.1.30")
        assert monitor.address == "192.168.1.30"

    async def test_flapping_address_settles_once(self, clocks):
        monitor, discovery, _ = make_monitor(clocks, ["192.168.1.30", "192.168.1.30", "10.1.1.198", None, "192.168.1.30", "192.168.1.30"])
        clocks.advance(5)
        await monitor.check()

        discovery.async_update_address.assert_awaited_once_with("192.168.1.30")

    async def test_no_stable_address_changes_nothing(self, clocks, caplog):
        flapping = ["192.168.1.30", "10.1.1.7", "192.168.1.31", "10.1.1.8"] * 10
        monitor, discovery, connection = make_monitor(clocks, flapping, settle_timeout=5)
        clocks.advance(5)
        await monitor.check()

        connection.abort.assert_not_called()
        discovery.async_update_address.assert_not_awaited()
        assert "No stable network address" in caplog.text

    async def test_lost_address_is_not_a_change(self, clocks):
        monitor, discovery, _ = make_monitor(clocks, [None])
        clocks.advance(5)
        await monitor.check()
        discovery.async_update_interfaces.assert_not_awaited()

    async def test_fixed_address_still_announces_after_sleep(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["192.168.1.30"] * 5, follow_address=False)
        clocks.advance(5)
        await monitor.check()
        discovery.async_update_interfaces.assert_not_awaited()

        clocks.advance(5, slept=600)
        await monitor.check()
        connection.abort.assert_called_once_with()
        discovery.async_update_address.assert_not_awaited()
        discovery.async_announce.assert_awaited()

    async def test_run_survives_a_failing_check(self, clocks, caplog):
        calls = []

        async def sleep(_seconds):
            calls.append(_seconds)
            if len(calls) > 2:
                raise asyncio.CancelledError()

        monitor, discovery, _ = make_monitor(clocks, ["192.168.1.30"] * 5, sleep=sleep)
        discovery.async_update_interfaces.side_effect = RuntimeError("boom")
        clocks.advance(5)

        with pytest.raises(asyncio.CancelledError):
            await monitor.run()
        assert "Network check failed" in caplog.text

    async def test_stop_cancels_the_second_announcement(self, clocks):
        monitor, discovery, _ = make_monitor(clocks, ["10.1.1.198"] * 5, sleep=asyncio.sleep, reannounce_delay=10, settle_poll=0)
        clocks.advance(5, slept=600)
        await monitor.check()
        await monitor.stop()
        await asyncio.sleep(0)
        assert discovery.async_announce.await_count == 1


class TestSleepClock:
    @linux_only
    def test_linux_counts_suspend_with_boottime(self):
        assert monitor_module.SLEEP_CLOCK_ID == time.CLOCK_BOOTTIME  # pylint: disable=no-member

    @darwin_only
    def test_macos_counts_sleep_with_clock_monotonic(self):
        assert monitor_module.SLEEP_CLOCK_ID == time.CLOCK_MONOTONIC

    def test_sleep_clock_advances(self):
        first = monitor_module.sleep_clock()
        assert monitor_module.sleep_clock() >= first

    def test_fallback_without_a_clock_id(self, monkeypatch):
        monkeypatch.setattr(monitor_module, "SLEEP_CLOCK_ID", None)
        assert monitor_module.sleep_clock() > 0


def make_zeroconf(**kwargs):
    with patch("linux_voice_assistant.zeroconf.AsyncZeroconf") as zeroconf_cls:
        from linux_voice_assistant.zeroconf import HomeAssistantZeroconf

        instance = HomeAssistantZeroconf(port=6053, mac_address="aa:bb:cc:dd:ee:ff", host_ip_address="10.1.1.198", name="lva-test", **kwargs)
    return instance, zeroconf_cls


class TestZeroconfUpdates:
    def test_default_constructor_without_interfaces(self):
        _, zeroconf_cls = make_zeroconf()
        zeroconf_cls.assert_called_once_with()

    def test_interfaces_are_passed_on(self):
        _, zeroconf_cls = make_zeroconf(interfaces=["10.1.1.198"])
        zeroconf_cls.assert_called_once_with(interfaces=["10.1.1.198"])

    async def test_address_update_says_goodbye_then_registers(self):
        zc, _ = make_zeroconf()
        zc._aiozc = MagicMock(async_register_service=AsyncMock(), async_unregister_service=AsyncMock())
        await zc.register_server()
        old_info = zc._service_info

        await zc.async_update_address("192.168.1.30")

        zc._aiozc.async_unregister_service.assert_awaited_once_with(old_info)
        assert zc._aiozc.async_register_service.await_count == 2
        assert zc._service_info.parsed_addresses() == ["192.168.1.30"]

    async def test_announce_updates_the_registered_service(self):
        zc, _ = make_zeroconf()
        zc._aiozc = MagicMock(async_register_service=AsyncMock(), async_update_service=AsyncMock())
        await zc.async_announce()
        zc._aiozc.async_update_service.assert_not_awaited()

        await zc.register_server()
        await zc.async_announce()
        zc._aiozc.async_update_service.assert_awaited_once_with(zc._service_info)

    async def test_same_interfaces_change_nothing(self):
        zc, _ = make_zeroconf(interfaces=["10.1.1.198"])
        zc._aiozc = MagicMock(async_update_interfaces=AsyncMock())
        await zc.async_update_interfaces(["10.1.1.198"])
        zc._aiozc.async_update_interfaces.assert_not_awaited()

    async def test_interfaces_switched_in_place(self):
        zc, _ = make_zeroconf(interfaces=["10.1.1.198"])
        zc._aiozc = MagicMock(async_update_interfaces=AsyncMock())
        await zc.async_update_interfaces(["192.168.1.30"])
        zc._aiozc.async_update_interfaces.assert_awaited_once_with(["192.168.1.30"])

    async def test_failed_switch_recreates_zeroconf(self):
        zc, _ = make_zeroconf(interfaces=["10.1.1.198"])
        old = MagicMock(async_register_service=AsyncMock(), async_update_interfaces=AsyncMock(side_effect=OSError("no such address")), async_close=AsyncMock())
        zc._aiozc = old
        await zc.register_server()
        new = MagicMock(async_register_service=AsyncMock())

        with patch("linux_voice_assistant.zeroconf.AsyncZeroconf", return_value=new) as zeroconf_cls:
            await zc.async_update_interfaces(["192.168.1.30"])

        old.async_close.assert_awaited_once_with()
        zeroconf_cls.assert_called_once_with(interfaces=["192.168.1.30"])
        new.async_register_service.assert_awaited_once()


class _Server(APIServer):
    def handle_message(self, msg):
        return []


class TestKeepalive:
    def test_real_socket_options(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            network.enable_keepalive(sock, idle=30, interval=10, count=3)
            assert sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE) != 0
            idle_option = getattr(socket, "TCP_KEEPIDLE", None) or getattr(socket, "TCP_KEEPALIVE")
            assert sock.getsockopt(socket.IPPROTO_TCP, idle_option) == 30

    def test_no_socket_is_ignored(self):
        network.enable_keepalive(None)

    def test_connections_keep_their_options_by_default(self):
        transport = MagicMock()
        _Server("lva-test").connection_made(transport)
        transport.get_extra_info.assert_not_called()

    def test_follow_network_connections_get_keepalive(self):
        transport = MagicMock()
        server = _Server("lva-test")
        server.tcp_keepalive = True
        with patch("linux_voice_assistant.api_server.enable_keepalive") as enable:
            server.connection_made(transport)
        enable.assert_called_once_with(transport.get_extra_info.return_value)
        transport.get_extra_info.assert_called_once_with("socket")

    def test_abort_drops_the_transport(self):
        transport = MagicMock()
        server = _Server("lva-test")
        server.abort()
        server.connection_made(transport)
        server.abort()
        transport.abort.assert_called_once_with()


class TestPhysicalAddresses:
    def test_virtual_and_loopback_are_left_out(self, monkeypatch):
        from tests.unit.test_network import MAC_ADAPTERS

        monkeypatch.setattr(network.ifaddr, "get_adapters", lambda: MAC_ADAPTERS)
        assert network.physical_ipv4_addresses() == ["192.168.1.30", "10.1.1.198"]


def _harness_zeroconf_line(tmp_path, *args):
    process = subprocess.Popen(  # pylint: disable=consider-using-with
        [sys.executable, "-m", "tests.harness.run_main", "serve", str(tmp_path), *args],
        cwd=_REPO_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert process.stdout is not None
        for line in process.stdout:
            if line.startswith("zeroconf "):
                return line.strip()
        raise AssertionError(process.stderr.read() if process.stderr else "")
    finally:
        process.terminate()
        process.wait(timeout=10)


class TestMainWiring:
    def test_default_start_keeps_zeroconf_defaults(self, tmp_path):
        assert _harness_zeroconf_line(tmp_path) == "zeroconf interfaces=None"

    def test_follow_network_limits_zeroconf_to_physical_interfaces(self, tmp_path):
        line = _harness_zeroconf_line(tmp_path, "--follow-network")
        expected = network.physical_ipv4_addresses() or None
        assert line == f"zeroconf interfaces={expected!r}"


class TestEngineEvents:
    """Sleep and wake reported by the audio engine (--audio-input-socket with --follow-network)."""

    async def test_will_sleep_withdraws_and_drops_connections(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 5)
        discovery.async_withdraw = AsyncMock()

        await monitor.will_sleep()

        discovery.async_withdraw.assert_awaited_once()
        connection.abort.assert_called_once_with()

    async def test_did_wake_announces_again(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 5)
        discovery.async_withdraw = AsyncMock()
        await monitor.will_sleep()

        await monitor.did_wake()

        discovery.async_announce.assert_awaited()
        connection.abort.assert_called_once_with()  # only at will_sleep

    async def test_did_wake_without_will_sleep_drops_stale_connections(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 5)

        await monitor.did_wake()

        connection.abort.assert_called_once_with()
        discovery.async_announce.assert_awaited()

    async def test_checks_wait_while_asleep(self, clocks):
        monitor, discovery, _connection = make_monitor(clocks, ["10.1.1.198"] * 5)
        discovery.async_withdraw = AsyncMock()
        await monitor.will_sleep()

        clocks.advance(5, slept=600)
        await monitor.check()

        discovery.async_announce.assert_not_awaited()

    async def test_clock_gap_ignored_while_the_engine_reports(self, clocks):
        monitor, discovery, connection = make_monitor(clocks, ["10.1.1.198"] * 5, engine_events=lambda: True)

        clocks.advance(5, slept=600)
        await monitor.check()

        discovery.async_announce.assert_not_awaited()
        connection.abort.assert_not_called()

    async def test_clock_gap_still_used_without_the_engine(self, clocks):
        monitor, discovery, _connection = make_monitor(clocks, ["10.1.1.198"] * 5, engine_events=lambda: False)

        clocks.advance(5, slept=600)
        await monitor.check()

        discovery.async_announce.assert_awaited()

    async def test_wake_without_address_is_retried(self, clocks):
        monitor, discovery, _connection = make_monitor(clocks, [None, None, None, None, "10.1.1.198"], settle_timeout=2.0)

        await monitor.did_wake()
        discovery.async_announce.assert_not_awaited()

        await monitor.check()
        discovery.async_announce.assert_awaited()

    async def test_network_changed_resyncs(self, clocks):
        monitor, discovery, _connection = make_monitor(clocks, ["10.1.1.199"] * 5)

        await monitor.network_changed()

        discovery.async_update_address.assert_awaited_once_with("10.1.1.199")
