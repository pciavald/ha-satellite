"""Guards that keep the Linux behaviour of LVA intact while other platforms are added."""

import argparse
import asyncio
import json
import subprocess
import sys
import tomllib
from pathlib import Path
from unittest.mock import ANY, MagicMock, call, patch

import pytest
from packaging.requirements import Requirement

import linux_voice_assistant.__main__ as lva_main
from linux_voice_assistant.mpv_player import MpvMediaPlayer

_REPO_DIR = Path(__file__).resolve().parents[2]

_LINUX_ENV = {"sys_platform": "linux", "platform_system": "Linux", "os_name": "posix"}

_LINUX_AUDIO_STACK = {
    "python-mpv",
    "soundcard",
    "webrtc-noise-gain",
    "pymicro-wakeword",
    "pyopen-wakeword",
    "netifaces2",
    "zeroconf",
    "aioesphomeapi",
}

_MACOS_ONLY_MODULES = (
    "av",
    "objc",
    "PyObjCTools",
    "AppKit",
    "Foundation",
    "AVFoundation",
    "CoreAudio",
    "CoreFoundation",
    "CoreMedia",
    "Quartz",
)

linux_only = pytest.mark.skipif(not sys.platform.startswith("linux"), reason="checks the real Linux import graph and audio backend, runs on Linux only")


class _ParsedArgs(Exception):
    def __init__(self, namespace: argparse.Namespace) -> None:
        super().__init__()
        self.namespace = namespace


def _linux_requirements() -> dict:
    project = tomllib.loads((_REPO_DIR / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    requirements = {}
    for line in project["dependencies"]:
        requirement = Requirement(line)
        if requirement.marker is None or requirement.marker.evaluate(_LINUX_ENV):
            requirements[requirement.name.lower()] = requirement
    return requirements


def _parse_cli(monkeypatch, argv: list) -> argparse.Namespace:
    original = argparse.ArgumentParser.parse_args

    def capture(self, args=None, namespace=None):
        raise _ParsedArgs(original(self, args, namespace))

    monkeypatch.setattr(sys, "argv", ["linux-voice-assistant", *argv])
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(argparse.ArgumentParser, "parse_args", capture)
    with pytest.raises(_ParsedArgs) as parsed:
        asyncio.run(lva_main.main())
    return parsed.value.namespace


class TestLinuxDependencies:
    def test_linux_install_keeps_the_full_audio_stack(self):
        assert _LINUX_AUDIO_STACK <= set(_linux_requirements())

    def test_linux_install_pulls_no_pyobjc(self):
        assert not [name for name in _linux_requirements() if name.startswith("pyobjc")]

    def test_linux_install_pulls_no_pyav(self):
        assert "av" not in _linux_requirements()


class TestLinuxCliDefaults:
    def test_linux_cli_defaults_match_upstream(self, monkeypatch):
        args = _parse_cli(monkeypatch, [])

        assert args.audio_input_channels == 1
        assert args.audio_input_block_size == 1024
        assert args.audio_input_device is None
        assert args.audio_output_device is None
        assert args.music_output_device is None
        assert args.mic_volume == 100
        assert args.mic_auto_gain == 0
        assert args.mic_noise_suppression == 0
        assert args.port == 6053
        assert args.peripheral_host == "0.0.0.0"
        assert args.peripheral_port == 6055
        assert args.disable_peripheral_api is False
        assert args.wake_model == "okay_nabu"
        assert args.stop_model == "stop"
        assert args.output_only is False
        assert args.mac_address is None
        assert args.follow_network is False
        assert args.audio_input_socket is None
        assert args.audio_output_socket is None
        assert args.control_socket is None
        assert args.persist_mute is False

    def test_linux_waits_for_the_wake_and_start_sounds_and_logs_like_upstream(self, monkeypatch):
        args = _parse_cli(monkeypatch, [])

        assert args.listen_during_wake_sound is False
        assert lva_main._engine_cancels_echo(args) is False
        assert lva_main._log_format(args) == {}

    def test_linux_cli_still_accepts_dual_channel_capture(self, monkeypatch):
        assert _parse_cli(monkeypatch, ["--audio-input-channels", "2"]).audio_input_channels == 2


class TestLinuxAudioBackends:
    def test_list_input_devices_goes_through_soundcard(self, monkeypatch, capsys):
        microphone = MagicMock()
        microphone.name = "Built-in Mic"
        monkeypatch.setattr(sys, "argv", ["linux-voice-assistant", "--list-input-devices"])

        with patch.object(lva_main.sc, "all_microphones", return_value=[microphone]) as all_microphones:
            asyncio.run(lva_main.main())

        all_microphones.assert_called_once_with()
        assert "[0] Built-in Mic" in capsys.readouterr().out

    def test_list_output_devices_goes_through_mpv(self, monkeypatch, capsys):
        player = MagicMock()
        player.audio_device_list = [{"name": "pulse/sink", "description": "Speaker"}]
        monkeypatch.setattr(sys, "argv", ["linux-voice-assistant", "--list-output-devices"])

        with patch("mpv.MPV", return_value=player) as mpv_cls:
            asyncio.run(lva_main.main())

        mpv_cls.assert_called_once_with()
        assert "pulse/sink: Speaker" in capsys.readouterr().out

    def test_media_player_is_libmpv_with_the_given_device(self):
        with patch("linux_voice_assistant.player.libmpv.mpv.MPV") as mpv_cls:
            MpvMediaPlayer(device="pulse/sink")

        mpv_cls.assert_called_once()
        mpv_cls.return_value.__setitem__.assert_any_call("audio-device", "pulse/sink")

    def test_media_player_without_device_keeps_mpv_default(self):
        with patch("linux_voice_assistant.player.libmpv.mpv.MPV") as mpv_cls:
            MpvMediaPlayer(device=None)

        assert call("audio-device", ANY) not in mpv_cls.return_value.__setitem__.call_args_list


_IMPORT_ALL = """
import json, pkgutil, sys, importlib
import linux_voice_assistant
names = [m.name for m in pkgutil.walk_packages(linux_voice_assistant.__path__, "linux_voice_assistant.")]
# player has no __init__.py, so walk_packages does not enter it
names += [m.name for m in pkgutil.iter_modules([linux_voice_assistant.__path__[0] + "/player"], "linux_voice_assistant.player.")]
for name in names:
    importlib.import_module(name)
import soundcard
print(json.dumps({"imported": names, "modules": sorted(sys.modules), "soundcard": soundcard.default_microphone.__module__}))
"""


@linux_only
class TestLinuxImportGraph:
    @pytest.fixture(scope="class")
    def import_report(self):
        result = subprocess.run([sys.executable, "-c", _IMPORT_ALL, "lva-import-check"], cwd=_REPO_DIR, capture_output=True, text=True, check=False)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_every_module_imports_on_linux(self, import_report):
        assert "linux_voice_assistant.__main__" in import_report["imported"]

    def test_linux_import_loads_no_macos_package(self, import_report):
        loaded = [name for name in import_report["modules"] if name.split(".")[0] in _MACOS_ONLY_MODULES]
        assert loaded == []

    def test_linux_soundcard_uses_pulseaudio_backend(self, import_report):
        assert import_report["soundcard"] == "soundcard.pulseaudio"

    def test_engine_modules_import_without_pyav(self, import_report):
        assert {"linux_voice_assistant.audio_source", "linux_voice_assistant.control", "linux_voice_assistant.player.helper"} <= set(import_report["imported"])

    def test_webrtc_noise_gain_stays_lazy(self, import_report):
        assert "webrtc_noise_gain" not in import_report["modules"]

    def test_webrtc_processor_runs_natively_on_linux(self):
        from linux_voice_assistant.webrtc import WebRTCProcessor

        processor = WebRTCProcessor(agc_level=1, ns_level=1)

        assert len(processor.process(bytes(processor.FRAME_SIZE_BYTES * 3))) == processor.FRAME_SIZE_BYTES * 3
