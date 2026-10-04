"""Tests for --mac-address and how main() resolves the device identity."""

import argparse
import asyncio
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import linux_voice_assistant.__main__ as lva_main
from tests.unit.test_audio_input import FakeMicrophone

_REPO_DIR = Path(__file__).resolve().parents[2]


class _StateBuilt(Exception):
    def __init__(self, kwargs: dict) -> None:
        super().__init__()
        self.kwargs = kwargs


def resolve_state(monkeypatch, tmp_path, argv: list, **patches) -> dict:
    """Run main() until ServerState is built and return its arguments."""

    def capture(**kwargs):
        raise _StateBuilt(kwargs)

    monkeypatch.setattr(sys, "argv", ["linux-voice-assistant", "--preferences-file", str(tmp_path / "prefs.json"), "--download-dir", str(tmp_path / "dl"), *argv])
    defaults = {
        "ServerState": capture,
        "MpvMediaPlayer": MagicMock(),
        "get_mac_address": MagicMock(return_value="DC:A6:32:01:02:03"),
    }
    defaults.update(patches)
    for name, value in defaults.items():
        monkeypatch.setattr(lva_main, name, value)
    monkeypatch.setattr(lva_main.network, "default_interface", lambda: "eth0")
    monkeypatch.setattr(lva_main.network, "interface_ipv4", lambda interface: "192.168.1.20")
    monkeypatch.setattr(lva_main.sc, "default_microphone", lambda: FakeMicrophone())

    with pytest.raises(_StateBuilt) as built:
        asyncio.run(lva_main.main())
    return built.value.kwargs


class TestMacAddressOption:
    @pytest.mark.parametrize("value", ["aa:bb:cc:dd:ee:ff", "AA-BB-CC-DD-EE-FF", "aabbccddeeff", " AA:bb:CC:dd:EE:ff "])
    def test_accepted_forms_are_normalised(self, value):
        assert lva_main._mac_address(value) == "aa:bb:cc:dd:ee:ff"

    @pytest.mark.parametrize("value", ["", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "gg:bb:cc:dd:ee:ff", "aabbccddeefg"])
    def test_invalid_values_are_refused(self, value):
        with pytest.raises(argparse.ArgumentTypeError):
            lva_main._mac_address(value)

    def test_invalid_value_exits_with_usage_error(self, monkeypatch, capsys):
        monkeypatch.setattr(sys, "argv", ["linux-voice-assistant", "--mac-address", "nope"])
        with pytest.raises(SystemExit) as exited:
            asyncio.run(lva_main.main())

        assert exited.value.code == 2
        assert "invalid MAC address" in capsys.readouterr().err


class TestIdentityResolution:
    def test_default_reads_the_interface_mac(self, monkeypatch, tmp_path):
        get_mac_address = MagicMock(return_value="DC:A6:32:01:02:03")
        kwargs = resolve_state(monkeypatch, tmp_path, [], get_mac_address=get_mac_address)

        get_mac_address.assert_called_once_with(interface="eth0")
        assert kwargs["mac_address"] == "DC:A6:32:01:02:03"
        assert kwargs["name"] == "lva-dca632010203"
        assert kwargs["network_interface"] == "eth0"
        assert kwargs["ip_address"] == "192.168.1.20"

    def test_mac_address_option_replaces_the_lookup(self, monkeypatch, tmp_path):
        get_mac_address = MagicMock()
        kwargs = resolve_state(monkeypatch, tmp_path, ["--mac-address", "BC-D0-74-AC-01-6A"], get_mac_address=get_mac_address)

        get_mac_address.assert_not_called()
        assert kwargs["mac_address"] == "bc:d0:74:ac:01:6a"
        assert kwargs["name"] == "lva-bcd074ac016a"
        assert kwargs["friendly_name"] == "LVA - bcd074ac016a"


def _entrypoint_args(tmp_path, env: dict) -> list:
    script_dir = tmp_path / "script"
    script_dir.mkdir(exist_ok=True)
    run = script_dir / "run"
    run.write_text('#!/bin/sh\nfor arg in "$@"; do echo "$arg"; done\n', encoding="utf-8")
    run.chmod(0o755)
    clean = {key: value for key, value in os.environ.items() if key not in ("MAC_ADDRESS", "HOST", "NETWORK_INTERFACE")}
    result = subprocess.run(
        ["bash", str(_REPO_DIR / "docker-entrypoint.sh")],
        cwd=tmp_path,
        env={**clean, "SKIP_PULSE_AUDIO_WAIT": "1", "PULSE_COOKIE": "DISABLED", **env},
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.splitlines()


class TestDockerEntrypoint:
    def test_mac_address_not_passed_when_unset(self, tmp_path):
        assert "--mac-address" not in _entrypoint_args(tmp_path, {})

    def test_mac_address_passed_when_set(self, tmp_path):
        args = _entrypoint_args(tmp_path, {"MAC_ADDRESS": "aa:bb:cc:dd:ee:ff"})
        assert args[args.index("--mac-address") + 1] == "aa:bb:cc:dd:ee:ff"


class TestAdvertisedAddress:
    def test_specific_bind_address_is_advertised_as_is(self, monkeypatch):
        interface_ipv4 = MagicMock()
        monkeypatch.setattr(lva_main.network, "interface_ipv4", interface_ipv4)

        assert lva_main._advertised_address("192.168.1.20", "eth0") == "192.168.1.20"
        interface_ipv4.assert_not_called()

    def test_all_interfaces_advertise_the_detected_address(self, monkeypatch):
        monkeypatch.setattr(lva_main.network, "interface_ipv4", MagicMock(return_value="10.1.1.198"))
        assert lva_main._advertised_address("0.0.0.0", "en13") == "10.1.1.198"

    def test_nothing_detected_keeps_the_old_advertisement(self, monkeypatch, caplog):
        monkeypatch.setattr(lva_main.network, "interface_ipv4", MagicMock(return_value=None))
        assert lva_main._advertised_address("0.0.0.0", "eth0") == "0.0.0.0"
        assert "advertising 0.0.0.0" in caplog.text

    def test_state_holds_the_detected_address_when_bound_to_all(self, monkeypatch, tmp_path):
        kwargs = resolve_state(monkeypatch, tmp_path, ["--host", "0.0.0.0"])
        assert kwargs["ip_address"] == "192.168.1.20"

    def test_state_holds_the_detected_address_by_default(self, monkeypatch, tmp_path):
        kwargs = resolve_state(monkeypatch, tmp_path, [])
        assert kwargs["ip_address"] == "192.168.1.20"

    def test_state_holds_an_explicit_address(self, monkeypatch, tmp_path):
        kwargs = resolve_state(monkeypatch, tmp_path, ["--host", "192.168.7.7"])
        assert kwargs["ip_address"] == "192.168.7.7"
