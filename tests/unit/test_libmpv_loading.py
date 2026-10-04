"""Tests for loading libmpv lazily and from LVA_LIBMPV_DIR."""

import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

from linux_voice_assistant.player import libmpv

_REPO_DIR = Path(__file__).resolve().parents[2]

_IMPORT_WITHOUT_MPV = """
import asyncio, importlib, json, pkgutil, sys

class BlockMpv:
    def find_spec(self, name, path=None, target=None):
        if name == "mpv" or name.startswith("mpv."):
            raise ImportError("mpv blocked by the test")
        return None

sys.meta_path.insert(0, BlockMpv())

import linux_voice_assistant
names = [m.name for m in pkgutil.walk_packages(linux_voice_assistant.__path__, "linux_voice_assistant.")]
for name in names:
    importlib.import_module(name)

from linux_voice_assistant.__main__ import main
sys.argv = ["linux-voice-assistant", "--help"]
try:
    asyncio.run(main())
except SystemExit as err:
    code = err.code
print(json.dumps({"imported": names, "help_exit": code, "mpv_loaded": "mpv" in sys.modules}))
"""


@pytest.fixture
def clean_env(monkeypatch):
    monkeypatch.delenv("LVA_LIBMPV_DIR", raising=False)
    monkeypatch.delenv("DYLD_FALLBACK_LIBRARY_PATH", raising=False)
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    return monkeypatch


class TestLazyImport:
    def test_every_module_and_help_work_without_mpv(self):
        result = subprocess.run([sys.executable, "-c", _IMPORT_WITHOUT_MPV, "lva-import-check"], cwd=_REPO_DIR, capture_output=True, text=True, check=False)
        assert result.returncode == 0, result.stderr

        report = json.loads(result.stdout.strip().splitlines()[-1])
        assert "linux_voice_assistant.__main__" in report["imported"]
        assert report["help_exit"] == 0
        assert report["mpv_loaded"] is False

    def test_libmpv_player_requires_mpv(self):
        with patch.dict(sys.modules, {"mpv": None}), pytest.raises(ImportError):
            libmpv.LibMpvPlayer()

    def test_module_attribute_resolves_to_python_mpv(self):
        fake_mpv = object()
        with patch.object(libmpv, "import_mpv", return_value=fake_mpv):
            assert libmpv.mpv is fake_mpv

    def test_unknown_module_attribute_raises(self):
        with pytest.raises(AttributeError):
            getattr(libmpv, "not_there")


class TestLibmpvDir:
    @pytest.mark.usefixtures("clean_env")
    def test_unset_leaves_the_environment_alone(self):
        with patch.dict(sys.modules, {"mpv": object()}):
            libmpv.import_mpv()

        assert "DYLD_FALLBACK_LIBRARY_PATH" not in os.environ
        assert "LD_LIBRARY_PATH" not in os.environ

    def test_darwin_prepends_the_directory_once(self, clean_env):
        clean_env.setattr(sys, "platform", "darwin")
        clean_env.setenv("LVA_LIBMPV_DIR", "/opt/libmpv/lib")
        clean_env.setenv("DYLD_FALLBACK_LIBRARY_PATH", "/usr/local/lib")

        with patch.dict(sys.modules, {"mpv": object()}):
            libmpv.import_mpv()
            libmpv.import_mpv()

        assert os.environ["DYLD_FALLBACK_LIBRARY_PATH"] == os.pathsep.join(["/opt/libmpv/lib", "/usr/local/lib"])

    def test_linux_ignores_the_directory(self, clean_env, caplog):
        clean_env.setattr(sys, "platform", "linux")
        clean_env.setenv("LVA_LIBMPV_DIR", "/opt/libmpv/lib")

        with patch.dict(sys.modules, {"mpv": object()}):
            libmpv.import_mpv()

        assert "LD_LIBRARY_PATH" not in os.environ
        assert "DYLD_FALLBACK_LIBRARY_PATH" not in os.environ
        assert "only used on macOS" in caplog.text
