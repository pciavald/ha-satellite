"""Tests for the graceful shutdown on signals and audio failures."""

import asyncio
import os
import queue
import signal
import subprocess
import sys
import threading
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import linux_voice_assistant.__main__ as lva_main
from linux_voice_assistant.shutdown import Shutdown
from tests.unit.conftest import make_state
from tests.unit.test_audio_input import FakeMicrophone, _StopRecording

_REPO_DIR = Path(__file__).resolve().parents[2]


class TestShutdown:
    async def test_first_reason_wins(self):
        shutdown = Shutdown(asyncio.get_running_loop())
        shutdown.request_signal(signal.SIGTERM)
        shutdown.request_exit(1)
        shutdown.request_signal(signal.SIGINT)

        await asyncio.wait_for(shutdown.wait(), 1)
        assert shutdown.signal == signal.SIGTERM
        assert shutdown.code is None

    async def test_exit_code_from_another_thread(self):
        shutdown = Shutdown(asyncio.get_running_loop())
        thread = threading.Thread(target=shutdown.request_exit_threadsafe, args=(1,))
        thread.start()
        thread.join()

        await asyncio.wait_for(shutdown.wait(), 1)
        assert shutdown.code == 1
        assert shutdown.signal is None

    def test_exit_request_without_loop(self):
        shutdown = Shutdown()
        shutdown.request_exit_threadsafe(1)
        assert shutdown.requested
        assert shutdown.code == 1

    def test_exit_request_after_loop_closed_is_ignored(self):
        loop = asyncio.new_event_loop()
        loop.close()
        Shutdown(loop).request_exit_threadsafe(1)

    async def test_cleanup_runs_every_step_in_order(self, caplog):
        calls = []

        async def step(name):
            calls.append(name)
            if name == "b":
                raise RuntimeError("boom")

        await Shutdown().cleanup([(name, lambda name=name: step(name)) for name in ("a", "b", "c")])

        assert calls == ["a", "b", "c"]
        assert "Shutdown step failed: b" in caplog.text

    async def test_cleanup_is_cut_at_the_budget(self, caplog):
        async def stuck():
            await asyncio.sleep(10)

        loop = asyncio.get_running_loop()
        started = loop.time()
        await Shutdown().cleanup([("stuck", stuck)], budget=0.1)

        assert loop.time() - started < 2
        assert "longer than 0.1s" in caplog.text

    async def test_install_handles_the_signals(self):
        loop = asyncio.get_running_loop()
        shutdown = Shutdown(loop)
        with patch.object(loop, "add_signal_handler") as add_signal_handler:
            shutdown.install()

        add_signal_handler.assert_any_call(signal.SIGTERM, shutdown.request_signal, signal.SIGTERM)
        add_signal_handler.assert_any_call(signal.SIGINT, shutdown.request_signal, signal.SIGINT)

    def test_exit_reraises_the_signal(self):
        shutdown = Shutdown()
        shutdown.signal = signal.SIGTERM
        with patch("signal.signal") as set_handler, patch("os.kill") as kill:
            shutdown.exit()

        set_handler.assert_called_once_with(signal.SIGTERM, signal.SIG_DFL)
        kill.assert_called_once_with(os.getpid(), signal.SIGTERM)

    def test_exit_with_error_code(self):
        shutdown = Shutdown()
        shutdown.code = 1
        with pytest.raises(SystemExit) as exited:
            shutdown.exit()
        assert exited.value.code == 1

    def test_clean_exit_returns(self):
        Shutdown().exit()


class _FailingRecorder:
    name = "Broken Mic"

    def recorder(self, **kwargs):
        raise RuntimeError("device gone")


class TestAudioThreadFailure:
    def test_failure_requests_the_exit(self, tmp_path):
        on_error = MagicMock()
        lva_main.process_audio(make_state(tmp_path), _FailingRecorder(), 1024, on_error=on_error)
        on_error.assert_called_once_with()

    def test_failure_without_callback_ends_the_thread_as_before(self, tmp_path):
        with pytest.raises(SystemExit):
            lva_main.process_audio(make_state(tmp_path), _FailingRecorder(), 1024)

    def test_error_in_one_block_keeps_the_thread_running(self, tmp_path):
        state = make_state(tmp_path)
        state.satellite = MagicMock()
        state.satellite.handle_audio.side_effect = ValueError("bad block")
        on_error = MagicMock()

        with pytest.raises(_StopRecording):
            lva_main.process_audio(state, FakeMicrophone(blocks=3), 1024, on_error=on_error)

        assert state.satellite.handle_audio.call_count == 3
        on_error.assert_not_called()

    def test_stop_event_ends_the_loop(self, tmp_path):
        stop = threading.Event()
        state = make_state(tmp_path)
        state.satellite = None
        mic = FakeMicrophone(blocks=1000)
        original = mic.record

        def record(numframes):
            if len(mic.record_calls) == 2:
                stop.set()
            return original(numframes)

        mic.record = record
        lva_main.process_audio(state, mic, 1024, stop=stop)

        assert len(mic.record_calls) == 3


def _start_harness(mode, tmp_path):
    process = subprocess.Popen(  # pylint: disable=consider-using-with
        [sys.executable, "-m", "tests.harness.run_main", mode, str(tmp_path)],
        cwd=_REPO_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    lines: "queue.Queue[str]" = queue.Queue()

    def pump():
        assert process.stdout is not None
        for line in process.stdout:
            lines.put(line.strip())

    threading.Thread(target=pump, daemon=True).start()
    return process, lines


def _wait_for(lines, expected, timeout=60.0):
    seen = []
    while True:
        line = lines.get(timeout=timeout)
        seen.append(line)
        if line == expected:
            return seen


def _drain(lines):
    seen = []
    while not lines.empty():
        seen.append(lines.get_nowait())
    return seen


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX signals")
class TestProcessExit:
    @pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
    def test_signal_sends_goodbye_and_dies_by_the_signal(self, tmp_path, sig):
        process, lines = _start_harness("serve", tmp_path)
        try:
            _wait_for(lines, "registered")
            process.send_signal(sig)
            process.wait(timeout=6)
        finally:
            process.kill()
        stderr = process.stderr.read() if process.stderr else ""

        assert process.returncode == -sig, stderr
        assert "goodbye" in _drain(lines)
        assert "Traceback" not in stderr

    def test_second_signal_during_shutdown_is_ignored(self, tmp_path):
        process, lines = _start_harness("serve", tmp_path)
        try:
            _wait_for(lines, "registered")
            process.send_signal(signal.SIGTERM)
            _wait_for(lines, "goodbye", timeout=6)
            process.send_signal(signal.SIGINT)
            process.wait(timeout=6)
        finally:
            process.kill()

        assert process.returncode == -signal.SIGTERM

    def test_audio_failure_exits_with_status_1(self, tmp_path):
        process, lines = _start_harness("audio-fail", tmp_path)
        try:
            process.wait(timeout=60)
        finally:
            process.kill()
        stderr = process.stderr.read() if process.stderr else ""

        assert process.returncode == 1, stderr
        assert "Unexpected error processing audio" in stderr
        assert "goodbye" in _drain(lines)
