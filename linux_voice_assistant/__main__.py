#!/usr/bin/env python3
import argparse
import asyncio
import errno
import json
import logging
import sys
import threading
import time
from pathlib import Path
from queue import Queue
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

import numpy as np
import soundcard as sc
from aioesphomeapi.api_pb2 import NumberStateResponse  # type: ignore  # pylint: disable=no-name-in-module
from getmac import get_mac_address  # type: ignore
from pymicro_wakeword import MicroWakeWord, MicroWakeWordFeatures
from pyopen_wakeword import OpenWakeWord, OpenWakeWordFeatures

from . import network
from .models import Preferences, ServerState, WakeWordType, initial_stop_word_threshold
from .monitor import NetworkMonitor
from .mpv_player import MpvMediaPlayer
from .peripheral_api import LVAEvent, PeripheralAPIServer
from .satellite import VoiceSatelliteProtocol
from .shutdown import Shutdown
from .util import get_esphome_version, get_version
from .wake_word import find_available_wake_words, load_stop_model, load_wake_models
from .webrtc import WebRTCProcessor
from .zeroconf import HomeAssistantZeroconf

_LOGGER = logging.getLogger(__name__)
_MODULE_DIR = Path(__file__).parent
_REPO_DIR = _MODULE_DIR.parent
_WAKEWORDS_DIR = _REPO_DIR / "wakewords"
_SOUNDS_DIR = _REPO_DIR / "sounds"


# -----------------------------------------------------------------------------


async def main() -> Optional[Shutdown]:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--name",
        help="Real name for the device",
    )
    parser.add_argument(
        "--audio-input-device",
        help="Name for the audio input device (see --list-input-devices)",
    )
    parser.add_argument(
        "--list-input-devices",
        action="store_true",
        help="List audio input devices and exit",
    )
    parser.add_argument(
        "--audio-input-block-size",
        type=int,
        default=1024,
    )
    parser.add_argument(
        "--audio-output-device",
        help="Name for the audio output device (see --list-output-devices)",
    )
    parser.add_argument(
        "--music-output-device",
        help="mpv name for the music/media output device (defaults to --audio-output-device)",
    )
    parser.add_argument(
        "--list-output-devices",
        action="store_true",
        help="List audio output devices and exit",
    )
    parser.add_argument("--mic-volume", type=int, default=100, choices=list(range(1, 101)), help="Microphone volume level (1 to 100)")
    parser.add_argument("--mic-auto-gain", type=int, default=0, choices=list(range(32)))
    parser.add_argument("--mic-noise-suppression", type=int, default=0, choices=(0, 1, 2, 3, 4))
    parser.add_argument(
        "--audio-input-channels",
        type=int,
        default=1,
        choices=(1, 2),
        help="Number of mic channels to capture and stream (1=mono, 2=dual-channel voice)",
    )
    parser.add_argument(
        "--wake-word-dir",
        default=[_WAKEWORDS_DIR],
        action="append",
        help="Directory with wake word models (.tflite) and configuration (.json)",
    )
    parser.add_argument(
        "--wake-model",
        default="okay_nabu",
        help="File name of the first active wake model",
    )
    parser.add_argument(
        "--stop-model",
        default="stop",
        help="File name of the stop model",
    )
    parser.add_argument(
        "--download-dir",
        default=_REPO_DIR / "local",
        help="Directory to download custom wake word models to",
    )
    parser.add_argument(
        "--refractory-seconds",
        default=2.0,
        type=float,
        help="Seconds before wake word can be activated again",
    )
    parser.add_argument(
        "--continue-conversation-delay",
        type=float,
        default=0.5,
        help="Seconds to wait after TTS finishes before opening the mic for continued conversation (default: 0.5)",
    )
    parser.add_argument(
        "--wakeup-sound",
        default=str(_SOUNDS_DIR / "wake_word_triggered.flac"),
        help="Directory and file name for wake sound (when you say the wake word)",
    )
    parser.add_argument(
        "--start-listening-sound",
        default=str(_SOUNDS_DIR / "start_listening_button.flac"),
        help="Directory and file name and sound for start listening button (when you press button to talk)",
    )
    parser.add_argument(
        "--timer-finished-sound",
        default=str(_SOUNDS_DIR / "timer_finished.flac"),
        help="Directory and file name for timer finished sound",
    )
    parser.add_argument(
        "--processing-sound",
        default=str(_SOUNDS_DIR / "processing.wav"),
        help="Short sound to play while assistant is processing (thinking)",
    )
    parser.add_argument(
        "--mute-sound",
        default=str(_SOUNDS_DIR / "mute_switch_on.flac"),
        help="Sound to play when muting the assistant",
    )
    parser.add_argument(
        "--unmute-sound",
        default=str(_SOUNDS_DIR / "mute_switch_off.flac"),
        help="Sound to play when unmuting the assistant",
    )
    parser.add_argument(
        "--button-double-press-sound",
        default=str(_SOUNDS_DIR / "button_double_press.flac"),
        help="Sound to play for button double press",
    )
    parser.add_argument(
        "--button-triple-press-sound",
        default=str(_SOUNDS_DIR / "button_triple_press.flac"),
        help="Sound to play for button triple press",
    )
    parser.add_argument(
        "--button-long-press-sound",
        default=str(_SOUNDS_DIR / "button_long_press.flac"),
        help="Sound to play for button long press",
    )
    parser.add_argument(
        "--preferences-file",
        default=_REPO_DIR / "preferences.json",
        help="Directory and file name for the preferences JSON file",
    )
    parser.add_argument(
        "--host",
        help="Optional host IP address to bind to (default: auto-detected by network interface)",
    )
    parser.add_argument(
        "--network-interface",
        help="Network interface the application listens on (default: auto-detected by gateway)",
    )
    parser.add_argument(
        "--follow-network",
        action="store_true",
        help="Follow address changes and system sleep: reconnect Home Assistant and announce again over mDNS (addresses are followed with --host 0.0.0.0)",
    )
    parser.add_argument(
        "--mac-address",
        type=_mac_address,
        help="MAC address that identifies the device in Home Assistant (default: the network interface's)",
    )
    # Note that default port is also set in docker-entrypoint.sh
    parser.add_argument(
        "--port",
        type=int,
        default=6053,
        help="Port the application is listening on (default: 6053)",
    )
    parser.add_argument(
        "--enable-thinking-sound",
        action="store_true",
        help="Enable thinking sound on startup",
    )
    # ------------------------------------------------------------------
    # Peripheral API (LEDs, buttons, HAT boards)
    # ------------------------------------------------------------------
    parser.add_argument(
        "--peripheral-host",
        default="0.0.0.0",
        help="Bind address for the peripheral WebSocket API (default: 0.0.0.0)",
    )
    parser.add_argument(
        "--peripheral-port",
        type=int,
        default=6055,
        help="Port for the peripheral WebSocket API (default: 6055)",
    )
    parser.add_argument(
        "--peripheral-volume-step",
        type=float,
        default=PeripheralAPIServer.DEFAULT_VOLUME_STEP,
        metavar="STEP",
        help="Volume change per button press, 0.0–1.0 (default: %(default)s)",
    )
    parser.add_argument(
        "--disable-peripheral-api",
        action="store_true",
        help="Disable the peripheral WebSocket API entirely",
    )
    parser.add_argument(
        "--peripheral-startup-wait",
        type=float,
        default=2.0,
        metavar="SECONDS",
        help="Seconds to wait for peripherals to connect and register their entities before HA enumerates the ESPHome API (default: %(default)s; set 0 to skip).",
    )
    # ------------------------------------------------------------------
    parser.add_argument(
        "--timer-max-ring-seconds",
        type=float,
        default=900.0,  # 15 minutes
        help="Seconds before a ringing timer auto-stops (default: 900)",
    )
    parser.add_argument(
        "--listen-during-wake-sound",
        action="store_true",
        help="Start listening immediately after wake word detection, without waiting for the wake sound to finish",
    )
    # ------------------------------------------------------------------
    # External audio engine over a Unix socket (the macOS app)
    # ------------------------------------------------------------------
    parser.add_argument(
        "--audio-input-socket",
        metavar="PATH",
        help="Read the microphone from an audio engine on this Unix socket instead of a sound device",
    )
    parser.add_argument(
        "--audio-output-socket",
        metavar="PATH",
        help="Play TTS, announcements and sounds through an audio engine on this Unix socket (music stays on mpv)",
    )
    parser.add_argument(
        "--control-socket",
        metavar="PATH",
        help="Share state and take commands (mute, talk) through an audio engine on this Unix socket; exits when it is gone for 30 s",
    )
    parser.add_argument(
        "--persist-mute",
        action="store_true",
        help="Remember the mute switch in the preferences file across restarts",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Add this to enable debug logging",
    )
    parser.add_argument(
        "--colored-debug",
        action="store_true",
        help="Add this to enable colored debug logging",
    )
    parser.add_argument(
        "--output-only",
        action="store_true",
        help="Enable output only mode",
    )
    args = parser.parse_args()

    if args.colored_debug:
        args.debug = True
        _setup_logging(args)
    else:
        log_format, date_format = _log_format(args)
        logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO, format=log_format, datefmt=date_format)

    _LOGGER.debug(args)
    if args.list_input_devices:
        print("Audio Input devices:")
        print("=" * 13)
        for idx, mic in enumerate(sc.all_microphones()):
            print(f"[{idx}]", mic.name)
        return None

    if args.list_output_devices:
        from .player.libmpv import import_mpv

        player = import_mpv().MPV()
        print("Audio output devices:")
        print("=" * 14)

        for speaker in player.audio_device_list:  # type: ignore
            print(speaker["name"] + ":", speaker["description"])
        return None

    # Resolve network interface for mac-address detection
    if not args.network_interface:
        print("No network interface specified, try to detect default interface")
        network_interface = await network.wait_for_default_interface()
        print(f"Default interface detected: {network_interface}")
        if network_interface is None and network.uses_route_backend():
            _LOGGER.error("No usable network address found")
            sys.exit(1)
    else:
        print("Network interface specified")
        network_interface = args.network_interface
        print(f"Using network interface: {network_interface}")

    # Resolve ip_address where the application will be listening
    if not args.host:
        print("No host (ip-address) specified, try to detect IP-Address")
        host_ip_address = network.interface_ipv4(network_interface)
        print(f"IP-Address detected: {host_ip_address}")
    else:
        print("Host specified")
        print(f"Using host: {args.host}")
        host_ip_address = args.host

    # Resolve the address announced over mDNS (the bind address unless it is 0.0.0.0)
    advertised_ip_address = _advertised_address(host_ip_address, network_interface)

    # Resolve mac
    if args.mac_address:
        mac_address = args.mac_address
        print(f"Using MAC address: {mac_address}")
    elif not (mac_address := get_mac_address(interface=network_interface)):
        print("No Mac address was found, app stopped.")
        sys.exit(1)
    mac_address_clean = mac_address.replace(":", "").lower()

    # Resolve name
    if not args.name:
        print("No friendly name specified, try to autogenerate name")
        friendly_name = f"LVA - {mac_address_clean}"
        print(f"Friendly name autogenerated: {friendly_name}")
    else:
        print("Friendly name specified")
        print(f"Using friendly name: {args.name}")
        friendly_name = args.name

    device_name = f"lva-{mac_address_clean}"

    print(f"Device name: {device_name}")

    # Resolve version
    version = get_version()
    print(f"Version: {version}")

    # Resolve esphome version
    esphome_version = get_esphome_version()
    print(f"ESPHome api version: {esphome_version}")

    # Resolve download dir
    args.download_dir = Path(args.download_dir)
    args.download_dir.mkdir(parents=True, exist_ok=True)

    loop = asyncio.get_running_loop()

    # Resolve microphone
    engine_mic = None
    engine_monitor: Dict[str, Any] = {}
    if args.audio_input_socket:
        engine_mic = _start_engine_microphone(args, loop, engine_monitor)
        mic = engine_mic
    else:
        if args.audio_input_device is not None:
            try:
                args.audio_input_device = int(args.audio_input_device)
            except ValueError:
                pass

            mic = sc.get_microphone(args.audio_input_device)
        else:
            mic = sc.default_microphone()

        args.audio_input_channels = _input_channels(args.audio_input_channels, mic)

        if sys.platform == "darwin":
            _LOGGER.warning("No echo cancellation: the satellite hears its own playback (see --audio-input-socket)")

    # Load available wake words
    wake_word_dirs = [Path(ww_dir) for ww_dir in args.wake_word_dir]

    # If the operator explicitly pointed --wake-word-dir (or the WAKE_WORD_DIR
    # env var) at the openWakeWord subdirectory, prefer resolving --wake-model
    # to an openWakeWord model of the same name instead of a same-named
    # microWakeWord one. Checked before the automatic dirs below are appended,
    # since those always include the openWakeWord path and would otherwise
    # make every configuration look like an openWakeWord preference.
    preferred_wake_word_type = WakeWordType.OPEN_WAKE_WORD if any("openwakeword" in str(ww_dir).lower() for ww_dir in wake_word_dirs) else None

    # openWakeWord models ship in their own subdirectory under the default
    # wakewords dir. find_available_wake_words() only globs the top level of
    # each directory it's given, so this must be added explicitly or the OWW
    # models never get discovered (and never show up in the HA dropdown).
    # Appended after the user-specified dirs so OWW entries are inserted
    # (and therefore displayed) after the microWakeWord ones.
    oww_dir = _WAKEWORDS_DIR / "openWakeWord"
    if oww_dir not in wake_word_dirs:
        wake_word_dirs.append(oww_dir)

    wake_word_dirs.append(args.download_dir / "external_wake_words")
    available_wake_words = find_available_wake_words(wake_word_dirs, args.stop_model)

    # Load preferences
    preferences_path = Path(args.preferences_file)
    if preferences_path.exists():
        _LOGGER.debug("Loading preferences: %s", preferences_path)
        with open(preferences_path, "r", encoding="utf-8") as preferences_file:
            preferences_dict = json.load(preferences_file)
            preferences = Preferences(**preferences_dict)
    else:
        preferences = Preferences()

    # Load volume from preferences on startup, and ensure it's between 0.0 and 1.0
    initial_volume = preferences.volume if preferences.volume is not None else 1.0
    initial_volume = max(0.0, min(1.0, float(initial_volume)))
    preferences.volume = initial_volume

    # Load stop word sensitivity from preferences on startup, and ensure it's between 0.0 and 1.0
    initial_threshold = initial_stop_word_threshold(preferences.stop_word_sensitivity)
    preferences.stop_word_sensitivity = initial_threshold

    # Load button-lock state from preferences on startup. This must happen
    # before ServerState is constructed (and therefore before the peripheral
    # WebSocket server can accept any connection), because the very first
    # snapshot sent to a (re)connecting peripheral must already reflect the
    # persisted value — peripherals only learn the lock state from that
    # snapshot or a later button_lock_changed event, and nothing re-sends
    # a corrected snapshot after the fact.
    initial_button_controls_locked = bool(preferences.button_controls_locked)

    if args.enable_thinking_sound:
        preferences.thinking_sound = 1

    if args.persist_mute and preferences.muted is None:
        preferences.muted = False

    if args.mic_auto_gain or args.mic_noise_suppression:
        _require_webrtc()

    if args.mic_volume > 0.0:
        preferences.mic_volume = args.mic_volume
    if args.mic_auto_gain > 0:
        preferences.mic_auto_gain = args.mic_auto_gain

    if args.mic_noise_suppression > 0:
        preferences.mic_noise_suppression = args.mic_noise_suppression

    engine_player = None
    if args.audio_output_socket:
        from .player.helper import HelperPlayer

        engine_player = HelperPlayer(args.audio_output_socket)

    # Load wake/stop models
    wake_models, active_wake_words, fallback_used = load_wake_models(
        available_wake_words,
        [word for word in preferences.active_wake_words if word is not None],
        args.wake_model,
        preferred_type=preferred_wake_word_type,
    )

    # TODO: allow openWakeWord for "stop"
    stop_model = load_stop_model(wake_word_dirs, args.stop_model)
    assert stop_model is not None

    state = ServerState(
        name=device_name,
        friendly_name=friendly_name,
        network_interface=network_interface,  # type: ignore[arg-type]
        mac_address=mac_address,
        ip_address=advertised_ip_address,  # type: ignore[arg-type]
        version=version,
        esphome_version=esphome_version,
        audio_queue=Queue(),
        entities=[],
        available_wake_words=available_wake_words,
        wake_words=wake_models,
        active_wake_words=active_wake_words,
        stop_word=stop_model,
        music_player=MpvMediaPlayer(device=args.music_output_device or args.audio_output_device),
        tts_player=MpvMediaPlayer(player=engine_player) if engine_player is not None else MpvMediaPlayer(device=args.audio_output_device),
        wakeup_sound=args.wakeup_sound,
        start_listening_sound=args.start_listening_sound,
        timer_finished_sound=args.timer_finished_sound,
        processing_sound=args.processing_sound,
        mute_sound=args.mute_sound,
        unmute_sound=args.unmute_sound,
        button_double_press_sound=args.button_double_press_sound,
        button_triple_press_sound=args.button_triple_press_sound,
        button_long_press_sound=args.button_long_press_sound,
        preferences=preferences,
        preferences_path=preferences_path,
        refractory_seconds=args.refractory_seconds,
        continue_conversation_delay=args.continue_conversation_delay,
        output_only=args.output_only,
        download_dir=args.download_dir,
        volume=initial_volume,
        stop_word_threshold=initial_threshold,
        button_controls_locked=initial_button_controls_locked,
        mic_volume=preferences.mic_volume,
        mic_auto_gain=preferences.mic_auto_gain,
        mic_noise_suppression=preferences.mic_noise_suppression,
        audio_input_channels=args.audio_input_channels,
        timer_max_ring_seconds=args.timer_max_ring_seconds,
        listen_during_wake_sound=args.listen_during_wake_sound or _engine_cancels_echo(args),
        listen_during_start_sound=_engine_cancels_echo(args),
    )

    if engine_mic is not None:
        state.input_processing = engine_mic.processing
    if args.persist_mute:
        state.persist_mute = True
        state.muted = bool(preferences.muted)

    if fallback_used:
        # Fallback to the default model was used, save as active wake words
        _LOGGER.debug("Fallback was used, save default wake words in Preferences.")
        state.preferences.active_wake_words = list(active_wake_words)
        state.active_wake_words = active_wake_words
        state.wake_words = wake_models
        state.save_preferences()
        state.wake_words_changed = True

    if args.enable_thinking_sound or args.mic_auto_gain or args.mic_noise_suppression:
        state.save_preferences()

    initial_volume_percent = int(round(initial_volume * 100))
    state.music_player.set_volume(initial_volume_percent)
    state.tts_player.set_volume(initial_volume_percent)

    # ------------------------------------------------------------------
    # Peripheral API (optional – LEDs, buttons, HAT boards)
    # ------------------------------------------------------------------
    peripheral_api: Optional[PeripheralAPIServer] = None
    if not args.disable_peripheral_api:
        peripheral_api = PeripheralAPIServer(
            host=args.peripheral_host,
            port=args.peripheral_port,
            volume_step=args.peripheral_volume_step,
        )
        peripheral_api.set_state(state)
        state.peripheral_api = peripheral_api

    # ------------------------------------------------------------------
    # ESPHome TCP server (with retry on EADDRINUSE)
    # ------------------------------------------------------------------
    shutdown = Shutdown(loop)
    shutdown.install()
    max_attempts = 15
    attempt = 1
    server = None

    # Validate VoiceSatelliteProtocol initialization BEFORE starting server
    # This catches errors like missing imports or broken initialization immediately
    # instead of failing silently only when first client connects
    _LOGGER.debug("Validating VoiceSatelliteProtocol initialization...")
    try:
        # Create test instance to run complete __init__ code path
        test_protocol = VoiceSatelliteProtocol(state)
        # Cleanup state reference
        test_protocol.state.satellite = None
        del test_protocol
        _LOGGER.debug("✅ VoiceSatelliteProtocol validation successful")
    except Exception:
        _LOGGER.critical("❌ FATAL ERROR in VoiceSatelliteProtocol initialization!", exc_info=True)
        _LOGGER.critical("Program will exit immediately - fix the error above first!")
        sys.exit(1)

    def create_protocol() -> VoiceSatelliteProtocol:
        protocol = VoiceSatelliteProtocol(state)
        if args.follow_network:
            protocol.tcp_keepalive = True
        return protocol

    while attempt <= max_attempts:
        try:
            server = await loop.create_server(
                create_protocol,
                host=host_ip_address,
                port=args.port,
            )
            break  # connection successful, exit the loop
        except OSError as err:
            message = err.strerror or str(err)
            if err.errno == errno.EADDRINUSE:
                message = "address already in use"
            if attempt < max_attempts:
                _LOGGER.warning(
                    "Attempt %d/%d failed to bind on address (%s, %s): %s. Retrying in 1 second...",
                    attempt,
                    max_attempts,
                    host_ip_address,
                    args.port,
                    message,
                )
                await asyncio.sleep(1)
                attempt += 1
            else:
                _LOGGER.exception(
                    "All %d attempts failed to bind on address (%s, %s): %s",
                    max_attempts,
                    host_ip_address,
                    args.port,
                    message,
                )
                sys.exit(1)

    # ------------------------------------------------------------------
    # Audio processing thread
    # ------------------------------------------------------------------
    audio_stop = threading.Event()
    audio_kwargs: Dict[str, Any] = {"stop": audio_stop, "on_error": lambda: shutdown.request_exit_threadsafe(1)}
    if engine_mic is not None:
        audio_kwargs["resumed"] = engine_mic.pop_resumed
    process_audio_thread = threading.Thread(
        target=process_audio,
        args=(state, mic, args.audio_input_block_size),
        kwargs=audio_kwargs,
        daemon=True,
    )
    process_audio_thread.start()

    # Auto discovery (zeroconf, mDNS)
    discovery = HomeAssistantZeroconf(
        port=args.port,
        name=state.name,
        mac_address=state.mac_address,
        host_ip_address=advertised_ip_address,  # type: ignore[arg-type]
        interfaces=(network.physical_ipv4_addresses() or None) if args.follow_network else None,
        friendly_name=friendly_name if args.follow_network else None,
    )
    await discovery.register_server()

    monitor: Optional[NetworkMonitor] = None
    monitor_task: Optional[asyncio.Task] = None
    if args.follow_network:
        follow_address = host_ip_address == "0.0.0.0"
        if not follow_address:
            _LOGGER.warning("--follow-network follows address changes only with --host 0.0.0.0, it will only announce again after sleep")
        monitor = NetworkMonitor(
            discovery,
            connections=lambda: state.connections,
            find_address=lambda: network.interface_ipv4(args.network_interface or network.default_interface()),
            address=advertised_ip_address,
            follow_address=follow_address,
            on_address=lambda ip: setattr(state, "ip_address", ip),
        )
        if engine_mic is not None:
            # The engine reports sleep and wake itself while it is connected
            monitor.engine_events = lambda: engine_mic.connected
        engine_monitor["monitor"] = monitor
        monitor_task = asyncio.create_task(monitor.run())

    # ------------------------------------------------------------------
    # Start peripheral API and signal "getting started" to peripherals
    # ------------------------------------------------------------------
    if peripheral_api is not None:
        await peripheral_api.start()
        await peripheral_api.emit_event(LVAEvent.ZEROCONF, {"status": "getting_started"})

        # Give peripherals a window to connect and register their Light
        # entities before HA enumerates over the ESPHome native API. The
        # ESPHome server is bound but not yet serving (serve_forever runs
        # below), so any HA connection sits queued in the kernel for the
        # duration of this wait. Peripherals that register later still
        # work, but the new entities only show up in HA after the
        # integration reconnects.
        if args.peripheral_startup_wait > 0:
            _LOGGER.info(
                "Waiting %.1fs for peripherals to register entities…",
                args.peripheral_startup_wait,
            )
            await asyncio.sleep(args.peripheral_startup_wait)

    control_channel = None
    if args.control_socket:
        from .control import ControlChannel

        control_channel = ControlChannel(args.control_socket, state, on_lost=lambda: shutdown.request_exit(0), lva_version=version)
        state.control_channel = control_channel
        await control_channel.start()

    _LOGGER.info("Server started (host=%s, port=%s)", host_ip_address, args.port)
    await shutdown.wait()

    async def stop_monitor() -> None:
        if monitor_task is not None:
            monitor_task.cancel()
        if monitor is not None:
            await monitor.stop()

    async def close_server() -> None:
        server.close()  # type: ignore[union-attr]

    async def stop_audio() -> None:
        audio_stop.set()
        state.audio_queue.put_nowait(None)
        await asyncio.to_thread(process_audio_thread.join, 2.0)

    async def stop_peripheral_api() -> None:
        if peripheral_api is not None:
            await peripheral_api.stop()

    async def stop_control() -> None:
        if control_channel is not None:
            await control_channel.stop()

    async def close_engine_microphone() -> None:
        # Wakes the audio thread if it waits on a paused capture
        if engine_mic is not None:
            await asyncio.to_thread(engine_mic.close)

    async def close_engine_player() -> None:
        if engine_player is not None:
            await asyncio.to_thread(engine_player.close)

    steps = [
        ("network monitor", stop_monitor),
        ("zeroconf", discovery.async_close),
        ("server", close_server),
        ("peripheral API", stop_peripheral_api),
    ]
    if control_channel is not None:
        steps.append(("control", stop_control))
    if engine_mic is not None:
        steps.append(("audio engine microphone", close_engine_microphone))
    steps.append(("audio thread", stop_audio))
    if engine_player is not None:
        steps.append(("audio engine playback", close_engine_player))
    await shutdown.cleanup(steps)
    _LOGGER.debug("Server stopped")
    return shutdown


# -----------------------------------------------------------------------------
def _setup_logging(args: argparse.Namespace) -> None:
    COLORS = {
        logging.DEBUG: "\033[36m",
        logging.INFO: "\033[32m",
        logging.WARNING: "\033[33m",
        logging.ERROR: "\033[31m",
        logging.CRITICAL: "\033[35m",
    }
    RESET = "\033[0m"

    original_format = logging.Formatter.format

    def colored_format(self, record: logging.LogRecord) -> str:
        color = COLORS.get(record.levelno, RESET)
        return f"{color}{original_format(self, record)}{RESET}"

    logging.Formatter.format = colored_format  # type: ignore

    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)s %(name)s: %(message)s",
            datefmt="%H:%M:%S",
        )
    )
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        handlers=[handler],
    )


# -----------------------------------------------------------------------------


def _advertised_address(bind_address: Optional[str], network_interface: Optional[str]) -> Optional[str]:
    """Return the address to announce: the bind address, or the detected one when bound to all interfaces."""
    if bind_address != "0.0.0.0":
        return bind_address

    detected = network.interface_ipv4(network_interface)
    if not detected:
        _LOGGER.warning("Bound to 0.0.0.0 but no address was detected on %s, advertising 0.0.0.0", network_interface)
        return bind_address

    print(f"Advertising IP-Address: {detected}")
    return detected


def _log_format(args: argparse.Namespace) -> Tuple[str, Optional[str]]:
    """Timestamped lines (to the millisecond) under the audio engine, whose log file has no time of its own; logging's default otherwise."""
    if not (args.audio_input_socket or args.audio_output_socket or args.control_socket):
        return logging.BASIC_FORMAT, None
    return "%(asctime)s.%(msecs)03d %(levelname)s:%(name)s:%(message)s", "%Y-%m-%d %H:%M:%S"


def _engine_cancels_echo(args: argparse.Namespace) -> bool:
    """True when the audio engine both plays the sounds and removes them from the microphone.

    Its voice processing cancels the satellite's own playback, so streaming
    can start with the wake or start-listening sound instead of after it,
    and the first words are not lost.
    """
    return bool(args.audio_input_socket and args.audio_output_socket)


def _mac_address(value: str) -> str:
    """Parse aa:bb:cc:dd:ee:ff, AA-BB-CC-DD-EE-FF or aabbccddeeff into lower-case colon form."""
    digits = value.strip().replace(":", "").replace("-", "").lower()
    if len(digits) != 12 or any(char not in "0123456789abcdef" for char in digits):
        raise argparse.ArgumentTypeError(f"invalid MAC address: {value!r}")
    return ":".join(digits[i : i + 2] for i in range(0, 12, 2))


def _start_engine_microphone(args: argparse.Namespace, loop: asyncio.AbstractEventLoop, engine_monitor: Dict[str, Any]):
    """Connect the microphone to the audio engine, or exit when it does not answer."""
    from .audio_source import HelperSource

    if args.audio_input_device is not None:
        _LOGGER.warning("--audio-input-device is ignored with --audio-input-socket")
    if args.audio_input_channels != 1:
        _LOGGER.warning("--audio-input-channels is ignored with --audio-input-socket, the audio engine sends one channel")
    args.audio_input_channels = 1

    def on_event(code: str, _event: Dict[str, Any]) -> None:
        if code in ("will_sleep", "did_wake", "network_changed"):
            asyncio.run_coroutine_threadsafe(_engine_power_event(code, source, engine_monitor.get("monitor")), loop)

    source = HelperSource(args.audio_input_socket, on_event=on_event)
    source.start()
    if not source.wait_connected(10.0):
        _LOGGER.error("No audio engine at %s: %s", args.audio_input_socket, source.last_error)
        source.close()
        sys.exit(1)
    return source


async def _engine_power_event(code: str, source, monitor: Optional[NetworkMonitor]) -> None:
    """Handle sleep and wake reported by the audio engine; answer will_sleep with sleep_ready."""
    try:
        if monitor is not None:
            if code == "will_sleep":
                # The engine lets the system sleep 2 s after will_sleep at the latest
                await asyncio.wait({asyncio.ensure_future(monitor.will_sleep())}, timeout=1.5)
            elif code == "did_wake":
                await monitor.did_wake()
            else:
                await monitor.network_changed()
        elif code == "will_sleep":
            _LOGGER.info("System going to sleep")
    finally:
        if code == "will_sleep":
            source.send_event("sleep_ready")


def _require_webrtc() -> None:
    """Exit when mic auto gain or noise suppression is requested without webrtc-noise-gain."""
    try:
        import webrtc_noise_gain  # type: ignore[import-untyped] # noqa: F401
    except ImportError:
        if sys.platform == "darwin":
            _LOGGER.error("--mic-auto-gain and --mic-noise-suppression are not available on this platform")
        else:
            _LOGGER.exception("Extras for webrtc are not installed")
        sys.exit(1)


def _input_channels(requested: int, mic) -> int:
    """Return the number of channels to capture, at most what the microphone has."""
    available = getattr(mic, "channels", None)
    if isinstance(available, int) and 0 < available < requested:
        _LOGGER.warning("%s has %d channel(s), capturing %d instead of %d", mic.name, available, available, requested)
        return available
    return requested


def _device_blocksize(block_size: int) -> Optional[int]:
    """Return the soundcard recorder buffer size for the frames read per block.

    On CoreAudio, soundcard's blocksize is the device buffer in frames at the
    device rate, capped at 512, not the number of 16 kHz frames read per block:
    let the device choose it there and keep the explicit size elsewhere.
    """
    return None if sys.platform == "darwin" else block_size


def process_audio(
    state: ServerState,
    mic,
    block_size: int,
    stop: Optional[threading.Event] = None,
    on_error: Optional[Callable[[], None]] = None,
    resumed: Optional[Callable[[], bool]] = None,
):
    """Process audio chunks from the microphone until stop is set.

    A failure outside the per-block handler calls on_error, so the caller can
    end the process instead of keeping a satellite that no longer hears.
    When resumed() returns True (an audio engine resumed capture after a
    pause), the streaming wake word features start over, so no window spans
    the pause.
    """
    n_channels = state.audio_input_channels

    wake_words: List[Union[MicroWakeWord, OpenWakeWord]] = []
    micro_features: Optional[MicroWakeWordFeatures] = None
    micro_inputs: List[np.ndarray] = []

    oww_features: Optional[OpenWakeWordFeatures] = None
    oww_inputs: List[np.ndarray] = []
    has_oww = False

    last_active: Optional[float] = None
    webrtc: Optional[WebRTCProcessor] = None
    webrtc_usable = True

    try:
        _LOGGER.debug("Opening audio input device: %s", mic.name)
        with mic.recorder(samplerate=16000, channels=n_channels, blocksize=_device_blocksize(block_size)) as mic_in:
            while (stop is None) or (not stop.is_set()):
                # Shape: (block_size, n_channels) for stereo, (block_size, 1) for mono.
                raw = mic_in.record(block_size)  # float32, range [-1, 1]
                if resumed is not None and resumed() and micro_features is not None:
                    micro_features = MicroWakeWordFeatures()
                    if oww_features is not None:
                        oww_features = OpenWakeWordFeatures.from_builtin()
                mic_vol_scalar = max(0.1, min(1.0, state.mic_volume / 100.0))

                # Build per-channel byte arrays.  Channel 0 is the primary
                # microphone; channel 1 (when present) is the reference/speaker
                # feed used for server-side AEC.
                channel_chunks: list[bytes] = []
                for ch in range(n_channels):
                    col = raw[:, ch] if n_channels > 1 else raw.reshape(-1)
                    chunk = (np.clip(col * mic_vol_scalar, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
                    channel_chunks.append(chunk)

                # Primary channel drives WebRTC and wake-word detection.
                audio_chunk = channel_chunks[0]
                agc = state.preferences.mic_auto_gain or 0
                ns = state.preferences.mic_noise_suppression or 0

                if (agc > 0 or ns > 0) and webrtc_usable and not state.input_processing:
                    try:
                        if webrtc is None:
                            webrtc = WebRTCProcessor(agc_level=agc, ns_level=ns)
                        else:
                            webrtc.update_settings(agc, ns)
                    except ImportError:
                        _LOGGER.warning("webrtc-noise-gain is not installed, ignoring mic auto gain and noise suppression")
                        webrtc_usable = False
                    else:
                        audio_chunk = webrtc.process(audio_chunk)
                        if not audio_chunk:
                            continue

                if state.satellite is None or not hasattr(state.satellite, "_is_streaming_audio"):
                    continue

                # WAKE WORD
                if (not wake_words) or (state.wake_words_changed and state.wake_words):
                    # Update list of wake word models to process
                    state.wake_words_changed = False
                    wake_words = [ww for ww in state.wake_words.values() if ww.id in state.active_wake_words]

                    # TODO: Load default stop word value from json into state and preferences missing.

                    has_oww = False
                    for idx, wake_word in enumerate(wake_words):

                        # Load default threshold from model json
                        wake_word_id = wake_word.id if hasattr(wake_word, "id") else next(iter(state.wake_words.keys()))
                        available_word = state.available_wake_words.get(wake_word_id)
                        # _LOGGER.debug("word= %s", state.available_wake_words.get(wake_word_id))
                        default_threshold = available_word.probability_cutoff if available_word else 0.7
                        _LOGGER.debug("Using default threshold %.3f for wake word '%s' from model config", default_threshold, wake_word_id)
                        # Check preferences override
                        if idx == 0:
                            old_val = state.wake_word_1_threshold
                            if state.preferences.wake_word_1_sensitivity is not None:
                                state.wake_word_1_threshold = state.preferences.wake_word_1_sensitivity
                            else:
                                state.wake_word_1_threshold = default_threshold
                            _LOGGER.debug("Wake Word 1 threshold set to %.3f (was %.3f, preferences: %s)", state.wake_word_1_threshold, old_val, state.preferences.wake_word_1_sensitivity)
                        elif idx == 1:
                            old_val = state.wake_word_2_threshold
                            if state.preferences.wake_word_2_sensitivity is not None:
                                state.wake_word_2_threshold = state.preferences.wake_word_2_sensitivity
                            else:
                                state.wake_word_2_threshold = default_threshold
                            _LOGGER.debug("Wake Word 2 threshold set to %.3f (was %.3f, preferences: %s)", state.wake_word_2_threshold, old_val, state.preferences.wake_word_2_sensitivity)

                        if isinstance(wake_word, OpenWakeWord):
                            has_oww = True

                    # Sync entity states after threshold values were updated
                    if state.satellite is not None:
                        _LOGGER.debug("Updating WebUI entities with new threshold values")

                        # Wake Word 1
                        if state.satellite.state.sensitivity_1_number_entity is not None:
                            _LOGGER.debug("  → Syncing Wake Word 1 entity to value %.3f", state.wake_word_1_threshold)
                            state.satellite.state.sensitivity_1_number_entity.sync_with_state()
                            _LOGGER.debug("  ✅ Wake Word 1 entity now has value %.3f", state.satellite.state.sensitivity_1_number_entity.value)

                        # Wake Word 2
                        if state.satellite.state.sensitivity_2_number_entity is not None:
                            _LOGGER.debug("  → Syncing Wake Word 2 entity to value %.3f", state.wake_word_2_threshold)
                            state.satellite.state.sensitivity_2_number_entity.sync_with_state()
                            _LOGGER.debug("  ✅ Wake Word 2 entity now has value %.3f", state.satellite.state.sensitivity_2_number_entity.value)

                        # Stop Word
                        if state.satellite.state.stop_sensitivity_number_entity is not None:
                            _LOGGER.debug("  → Syncing Stop Word entity to value %.3f", state.stop_word_threshold)
                            state.satellite.state.stop_sensitivity_number_entity.sync_with_state()
                            _LOGGER.debug("  ✅ Stop Word entity now has value %.3f", state.satellite.state.stop_sensitivity_number_entity.value)

                        _LOGGER.debug("All sensitivity entities synced successfully")

                        # Force push new state to connected Home Assistant instance
                        if state.satellite is not None:
                            try:
                                _LOGGER.debug("Pushing updated state values to Home Assistant")
                                for entity in [
                                    state.satellite.state.sensitivity_1_number_entity,
                                    state.satellite.state.sensitivity_2_number_entity,
                                    state.satellite.state.stop_sensitivity_number_entity,
                                ]:
                                    if entity is not None:
                                        state.satellite.send_messages([NumberStateResponse(key=entity.key, state=entity.value)])  # type: ignore[attr-defined]
                                        _LOGGER.debug("  → Pushed value %.3f for entity %d", entity.value, entity.key)
                            except Exception as e:
                                _LOGGER.debug("Could not push state (no client connected yet): %s", e)

                    # TODO: Save settings: At this moment settings are only saved when changed in the UI. Means that the default value can change while updating since its not saved in preferences.

                    if micro_features is None:
                        micro_features = MicroWakeWordFeatures()

                    if has_oww and (oww_features is None):
                        oww_features = OpenWakeWordFeatures.from_builtin()

                try:
                    # Both channels travel in one message: data=ch0 (enhanced), data2=ch1 (raw reference)
                    audio_chunk_2 = channel_chunks[1] if n_channels >= 2 else None
                    state.satellite.handle_audio(audio_chunk, audio_chunk_2)

                    assert micro_features is not None
                    micro_inputs.clear()
                    micro_inputs.extend(micro_features.process_streaming(audio_chunk))

                    if has_oww:
                        assert oww_features is not None
                        oww_inputs.clear()
                        oww_inputs.extend(oww_features.process_streaming(audio_chunk))

                    for wake_word_index, wake_word in enumerate(wake_words):
                        activated = False

                        # Set dynamic threshold depending on wake word index
                        if wake_word_index == 0:
                            threshold = state.wake_word_1_threshold
                            # _LOGGER.debug("Set wake word %d probability cutoff to %.3f", wake_word_index+1, state.wake_word_1_threshold)
                        elif wake_word_index == 1:
                            threshold = state.wake_word_2_threshold
                            # _LOGGER.debug("Set wake word %d probability cutoff to %.3f", wake_word_index+1, state.wake_word_2_threshold)
                        else:
                            threshold = 0.7
                            # _LOGGER.debug("Set wake word %d probability cutoff to fallback value 0.7", wake_word_index+1)

                        if isinstance(wake_word, MicroWakeWord):
                            # No debugging when no detection
                            wake_word.debug_probabilities = False

                            # set microWakeWord cutoff
                            wake_word.probability_cutoff = threshold

                            for micro_input in micro_inputs:
                                if wake_word.process_streaming(micro_input):
                                    wake_word.debug_probabilities = True
                                    activated = True
                        elif isinstance(wake_word, OpenWakeWord):
                            for oww_input in oww_inputs:
                                for prob in wake_word.process_streaming(oww_input):
                                    if prob > threshold:
                                        _LOGGER.debug("Wake word '%s' activated (probability %.3f exceeded threshold %.3f)", wake_word.wake_word, prob, threshold)  # type: ignore[attr-defined]
                                        activated = True

                        if activated and not state.muted:
                            # Check refractory
                            now = time.monotonic()
                            if (last_active is None) or ((now - last_active) > state.refractory_seconds):
                                state.satellite.wakeup(wake_word)
                                last_active = now

                    # Always process to keep state correct
                    stopped = False

                    # No debugging when no detection
                    state.stop_word.debug_probabilities = False

                    # Apply stop word sensitivity threshold
                    state.stop_word.probability_cutoff = state.stop_word_threshold
                    # _LOGGER.debug("Set stop word probability cutoff to %.3f", state.stop_word_threshold)
                    for micro_input in micro_inputs:
                        if state.stop_word.process_streaming(micro_input):
                            state.stop_word.debug_probabilities = True
                            stopped = True

                    if stopped and (state.stop_word.id in state.active_wake_words) and not (state.muted and not state.mute_override):
                        _LOGGER.debug("Stop word detected")
                        state.satellite.stop()
                except Exception:  # pylint: disable=broad-except
                    _LOGGER.exception("Unexpected error handling audio")
    except Exception:  # pylint: disable=broad-except
        _LOGGER.exception("Unexpected error processing audio")
        if on_error is None:
            sys.exit(1)
        on_error()


# -----------------------------------------------------------------------------


def run():
    shutdown = asyncio.run(main())
    if shutdown is not None:
        shutdown.exit()


if __name__ == "__main__":
    run()
