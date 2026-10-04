"""The control role (--control-socket) against a fake audio engine."""

import asyncio
import json
from unittest.mock import MagicMock

import pytest
from aioesphomeapi.api_pb2 import SwitchCommandRequest, SwitchStateResponse  # type: ignore[attr-defined]  # pylint: disable=no-name-in-module
from aioesphomeapi.model import VoiceAssistantEventType

from linux_voice_assistant.control import ControlChannel
from linux_voice_assistant.helper_protocol import FrameType
from linux_voice_assistant.peripheral_api import LVAEvent, PeripheralAPIServer
from tests.unit.conftest import make_satellite
from tests.unit.fake_engine import FakeEngine, fixture_json


async def eventually(predicate, timeout: float = 5.0):
    for _attempt in range(int(timeout * 100)):
        if result := predicate():
            return result
        await asyncio.sleep(0.01)
    raise AssertionError("condition not met in time")


async def settle():
    """Let the loop flush what the channel wrote and the engine read it."""
    await asyncio.sleep(0.2)


def snapshots(connection):
    return [message["state"] for message in connection.json_of_type(FrameType.CONTROL) if "state" in message]


def acks(connection):
    return [message for message in connection.json_of_type(FrameType.CONTROL) if "ack" in message]


@pytest.fixture
def engine():
    fake = FakeEngine()
    yield fake
    fake.close()


@pytest.fixture
def satellite(tmp_path):
    satellite = make_satellite(tmp_path)
    satellite.send_messages = MagicMock()
    satellite.state.connected = True
    return satellite


@pytest.fixture
async def control(engine, satellite):
    lost = []
    channel = ControlChannel(engine.path, satellite.state, on_lost=lambda: lost.append(1), lva_version="1.2.0", backoff=(0.05, 0.1), poll_interval=0.05)
    channel.lost = lost  # type: ignore[attr-defined]
    satellite.state.control_channel = channel
    await channel.start()
    connection = await asyncio.to_thread(engine.role, "control")
    await eventually(lambda: snapshots(connection))
    yield channel, connection
    await channel.stop()


async def command(connection, name):
    connection.send_json(FrameType.CONTROL, fixture_json(name))
    command_id = fixture_json(name)["id"]
    return await eventually(lambda: [ack for ack in acks(connection) if ack["ack"] == command_id])


class TestSnapshots:
    async def test_handshake_and_first_snapshot(self, control):
        _channel, connection = control

        assert connection.hello == fixture_json("hello_control")
        assert snapshots(connection)[0] == {"rev": 1, "ha_connected": True, "muted": False, "ptt": False, "phase": "idle", "media": "idle", "error": None}

    async def test_snapshot_layout_matches_the_fixture(self, control):
        _channel, connection = control

        assert set(snapshots(connection)[0]) == set(fixture_json("control_state")["state"])

    async def test_phases_follow_the_pipeline_events(self, control, satellite):
        _channel, connection = control
        for event in (LVAEvent.WAKE_WORD_DETECTED, LVAEvent.LISTENING, LVAEvent.THINKING, LVAEvent.TTS_SPEAKING, LVAEvent.TTS_FINISHED, LVAEvent.TIMER_RINGING, LVAEvent.IDLE):
            satellite._emit(event)
        await settle()

        phases = [snapshot["phase"] for snapshot in snapshots(connection)]
        assert phases == ["idle", "wake", "listening", "thinking", "speaking", "idle", "timer", "idle"]
        revs = [snapshot["rev"] for snapshot in snapshots(connection)]
        assert revs == sorted(revs) and len(set(revs)) == len(revs)

    async def test_unchanged_state_sends_nothing(self, control, satellite):
        _channel, connection = control
        satellite._emit(LVAEvent.IDLE)
        await asyncio.sleep(0.2)

        assert len(snapshots(connection)) == 1

    async def test_changes_without_events_are_polled(self, control, satellite):
        _channel, connection = control
        satellite.state.connected = False

        assert (await eventually(lambda: snapshots(connection)[1:]))[0]["ha_connected"] is False

    async def test_pipeline_error_then_cleared_by_listening(self, control, satellite):
        _channel, connection = control

        satellite.handle_voice_event(VoiceAssistantEventType.VOICE_ASSISTANT_ERROR, {"code": "stt-no-text-recognized"})
        await settle()
        error_snapshot = snapshots(connection)[-1]
        satellite._emit(LVAEvent.LISTENING)
        await settle()

        assert error_snapshot["error"] == {"reason": "stt-no-text-recognized", "rev": error_snapshot["rev"]}
        assert snapshots(connection)[-1]["error"] is None

    async def test_new_connection_gets_the_current_state(self, control, engine, satellite):
        _channel, connection = control
        satellite.state.muted = True
        connection.close()

        second = await asyncio.to_thread(engine.role, "control")
        first_rev = snapshots(connection)[-1]["rev"]
        snapshot = (await eventually(lambda: snapshots(second)))[0]

        assert snapshot["muted"] is True
        assert snapshot["rev"] > first_rev


class TestMute:
    async def test_mute_from_the_menu_reaches_ha_and_the_snapshot(self, control, satellite):
        _channel, connection = control

        assert await command(connection, "control_mute_mic") == [{"ack": 7, "ok": True}]

        assert satellite.state.muted is True
        satellite.send_messages.assert_called_with([SwitchStateResponse(key=satellite.state.mute_switch_entity.key, state=True)])
        satellite.state.tts_player.play.assert_called_once_with(satellite.state.mute_sound)
        await settle()
        assert snapshots(connection)[-1]["muted"] is True

    async def test_mute_twice_is_idempotent(self, control, satellite):
        _channel, connection = control

        await command(connection, "control_mute_mic")
        connection.send_json(FrameType.CONTROL, {"command": "mute_mic", "id": 70})
        await eventually(lambda: [ack for ack in acks(connection) if ack["ack"] == 70])
        await settle()

        assert [ack["ok"] for ack in acks(connection)] == [True, True]
        assert satellite.state.tts_player.play.call_count == 1
        assert [snapshot["muted"] for snapshot in snapshots(connection)] == [False, True]

    async def test_unmute(self, control, satellite):
        _channel, connection = control
        await command(connection, "control_mute_mic")

        await command(connection, "control_unmute_mic")
        await settle()

        assert satellite.state.muted is False
        assert snapshots(connection)[-1]["muted"] is False

    async def test_ha_switch_reaches_the_snapshot(self, control, satellite):
        _channel, connection = control
        entity = satellite.state.mute_switch_entity

        list(entity.handle_message(SwitchCommandRequest(key=entity.key, state=True)))
        await settle()

        assert snapshots(connection)[-1]["muted"] is True

    async def test_ha_and_menu_interleaved_end_in_agreement(self, control, satellite):
        _channel, connection = control
        entity = satellite.state.mute_switch_entity

        list(entity.handle_message(SwitchCommandRequest(key=entity.key, state=True)))
        await command(connection, "control_unmute_mic")
        list(entity.handle_message(SwitchCommandRequest(key=entity.key, state=True)))
        await settle()

        assert satellite.state.muted is True
        assert entity._switch_state is True
        assert snapshots(connection)[-1]["muted"] is True

    async def test_mute_without_home_assistant(self, control, satellite):
        _channel, connection = control
        state = satellite.state
        state.satellite = None

        await command(connection, "control_mute_mic")

        assert state.muted is True
        state.tts_player.play.assert_called_once_with(state.mute_sound)
        await settle()
        assert snapshots(connection)[-1]["muted"] is True


class TestTalk:
    async def test_push_to_talk_while_muted(self, control, satellite):
        _channel, connection = control
        state = satellite.state
        state.muted = True

        assert await command(connection, "control_start_listening") == [{"ack": 9, "ok": True}]

        assert state.mute_override is True
        await settle()
        assert snapshots(connection)[-1]["ptt"] is True
        assert state.tts_player.play.call_args.args[0] == state.start_listening_sound
        state.tts_player.play.call_args.kwargs["done_callback"]()
        satellite.send_messages.reset_mock()
        satellite.handle_audio(b"\x00\x01")
        assert satellite.send_messages.called

        satellite._tts_finished()
        satellite.send_messages.reset_mock()
        satellite.handle_audio(b"\x00\x01")
        assert not satellite.send_messages.called
        assert state.mute_override is False
        await settle()
        assert snapshots(connection)[-1]["ptt"] is False

    async def test_start_listening_refused_while_muted_without_allow_muted(self, control, satellite):
        _channel, connection = control
        satellite.state.muted = True
        connection.send_json(FrameType.CONTROL, {"command": "start_listening", "id": 5})

        assert (await eventually(lambda: acks(connection))) == [{"ack": 5, "ok": False, "reason": "muted"}]
        assert satellite.state.mute_override is False

    async def test_refused_while_a_pipeline_runs(self, control, satellite):
        _channel, connection = control
        satellite._pipeline_active = True

        assert await command(connection, "control_start_listening") == [{"ack": 9, "ok": False, "reason": "pipeline_active"}]

    async def test_refused_without_home_assistant(self, control, satellite):
        _channel, connection = control
        satellite.state.satellite = None

        assert await command(connection, "control_start_listening") == [{"ack": 9, "ok": False, "reason": "not_connected"}]

    async def test_stop_pipeline(self, control, satellite):
        _channel, connection = control
        satellite.stop = MagicMock()

        assert await command(connection, "control_stop_pipeline") == [{"ack": 10, "ok": True}]
        satellite.stop.assert_called_once_with()

    async def test_unknown_command(self, control):
        _channel, connection = control
        connection.send_json(FrameType.CONTROL, {"command": "self_destruct", "id": 4})

        assert (await eventually(lambda: acks(connection))) == [{"ack": 4, "ok": False, "reason": "unknown_command"}]

    async def test_acks_from_the_engine_are_ignored(self, control):
        _channel, connection = control
        connection.send_json(FrameType.CONTROL, fixture_json("control_unknown_ack"))
        await asyncio.sleep(0.2)

        assert acks(connection) == []

    async def test_peripheral_websocket_cannot_override_mute(self, satellite):
        state = satellite.state
        state.muted = True
        api = PeripheralAPIServer()
        api.set_state(state)
        satellite.start_listening = MagicMock()

        await api._dispatch_command(json.dumps({"command": "start_listening", "data": {"allow_muted": True}}))

        satellite.start_listening.assert_not_called()


class TestLost:
    async def test_exits_when_the_engine_never_answers(self, satellite):
        lost = []
        channel = ControlChannel("/tmp/lva-no-such-engine.sock", satellite.state, on_lost=lambda: lost.append(1), lost_after=0.2, backoff=(0.05, 0.1), poll_interval=0.05)
        await channel.start()
        try:
            await eventually(lambda: lost)
        finally:
            await channel.stop()
        assert lost == [1]

    async def test_exits_when_the_connection_stays_closed(self, satellite):
        engine = FakeEngine()
        lost = []
        channel = ControlChannel(engine.path, satellite.state, on_lost=lambda: lost.append(1), lost_after=0.3, backoff=(0.05, 0.1), poll_interval=0.05)
        await channel.start()
        try:
            await eventually(lambda: channel.connected)
            await asyncio.sleep(0.5)
            assert lost == []
            engine.close()
            await eventually(lambda: lost)
        finally:
            await channel.stop()

    async def test_reconnecting_in_time_does_not_exit(self, control, engine):
        channel, connection = control
        channel.lost_after = 0.5
        connection.close()
        await asyncio.to_thread(engine.role, "control")
        await asyncio.sleep(0.7)

        assert channel.lost == []
