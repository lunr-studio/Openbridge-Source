#!/usr/bin/env python3
"""Global key dictation tool for macOS.

Press Right Option once to start recording from the built-in mic.
Press Right Option again to stop recording, transcribe, and paste.
"""

from __future__ import annotations

import argparse
import subprocess
import os
import tempfile
import threading
import shutil
import time
from pathlib import Path
from typing import Optional

import pyperclip
import sounddevice as sd
import soundfile as sf
from pynput import keyboard

from openbridge_engine.common import (
    getenv_bool,
    getenv_float,
    post_process_transcript,
    resolve_local_model,
    transcribe_audio,
    trim_command_output,
    warm_model_cache,
)
from openbridge_engine.config import MODEL_ROOT, REPO_MODEL_ROOT


DICTATE_PRESET_DEFAULT = os.environ.get("LUNR_WHISPR_DICTATE_PRESET", "balanced").strip().lower()
DICTATE_PRESETS = {
    "quality": {
        "model_candidates": ["mlx-community/whisper-large-v3-mlx"],
        "low_confidence_threshold": -0.75,
        "audio_preprocess": True,
    },
    "balanced": {
        "model_candidates": [
            "mlx-community/whisper-base",
            "mlx-community/whisper-large-v3-mlx",
            "mlx-community/whisper-tiny",
        ],
        "low_confidence_threshold": -0.85,
        "audio_preprocess": True,
    },
    "speed": {
        "model_candidates": ["mlx-community/whisper-tiny"],
        "low_confidence_threshold": -1.0,
        "audio_preprocess": False,
    },
}
CORRECTION_DICT_PATH = Path(__file__).with_name("vocab_corrections.json")
OLLAMA_MODEL = "gemma4:e2b"
SAMPLE_RATES = [16000, 22050, 32000, 44100, 48000]
DICTATE_PREPROCESS_FILTER = os.environ.get(
    "LUNR_WHISPR_DICTATE_PREPROCESS_FILTER",
    "highpass=f=85,lowpass=f=7800",
)
DICTATE_NOISY_PREPROCESS_FILTER = os.environ.get(
    "LUNR_WHISPR_DICTATE_NOISY_PREPROCESS_FILTER",
    "highpass=f=85,lowpass=f=7800,acompressor=threshold=0.05:ratio=8",
)
RUNTIME_CONFIG: dict[str, str | float | bool] = {}
SCRIPT_MODEL_ROOTS = (
    [MODEL_ROOT]
    if os.environ.get("LUNR_WHISPR_LOCAL_MODEL_DIR")
    else [REPO_MODEL_ROOT]
)


def resolve_runtime_config(args: argparse.Namespace) -> dict[str, str | float | bool]:
    preset = (args.preset or DICTATE_PRESET_DEFAULT).strip().lower()
    preset_cfg = DICTATE_PRESETS.get(preset, DICTATE_PRESETS["balanced"])
    explicit_model = os.environ.get("LUNR_WHISPR_DICTATE_MODEL", "").strip()
    if args.model:
        explicit_model = args.model.strip() or explicit_model
    resolved_model, resolved_model_label = resolve_local_model(
        explicit_model,
        preset_cfg["model_candidates"],
        local_model_roots=SCRIPT_MODEL_ROOTS,
        missing_help=(
            "Set --model or LUNR_WHISPR_DICTATE_MODEL to a local model path, "
            "or place model folders under ./models."
        ),
    )

    low_confidence_threshold = (
        getenv_float(
            "LUNR_WHISPR_DICTATE_LOW_CONFIDENCE_THRESHOLD",
            preset_cfg["low_confidence_threshold"],
        )
        if args.low_confidence_threshold is None
        else args.low_confidence_threshold
    )
    use_audio_preprocess = getenv_bool(
        "LUNR_WHISPR_DICTATE_PREPROCESS",
        preset_cfg["audio_preprocess"],
    )
    if args.no_audio_preprocess:
        use_audio_preprocess = False
    noisy_preprocess = getenv_bool(
        "LUNR_WHISPR_DICTATE_NOISY_PREPROCESS",
        False,
    )
    if args.noisy_mic:
        noisy_preprocess = True
    formatting_enabled = getenv_bool(
        "LUNR_WHISPR_DICTATE_FORMATTING",
        True,
    )
    if args.no_formatting:
        formatting_enabled = False
    ollama_enabled = getenv_bool(
        "LUNR_WHISPR_DICTATE_OLLAMA",
        True,
    )
    if args.no_ollama:
        ollama_enabled = False

    return {
        "preset": preset,
        "model": resolved_model,
        "model_label": resolved_model_label,
        "low_confidence_threshold": low_confidence_threshold,
        "use_audio_preprocess": use_audio_preprocess,
        "noisy_preprocess": noisy_preprocess,
        "formatting_enabled": formatting_enabled,
        "ollama_enabled": ollama_enabled,
    }


class MicRecorder:
    """Capture mic audio into a temporary WAV while stream is running."""

    def __init__(self, output_path: Path):
        self.output_path = output_path
        self.samplerate = SAMPLE_RATES[0]
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._started = False

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._record_loop, daemon=True)
        self._thread.start()
        self._started = True

    def stop(self) -> Path:
        if not self._started:
            return self.output_path

        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)
        self._started = False
        return self.output_path

    def _record_loop(self) -> None:
        last_error: Optional[Exception] = None

        for rate in SAMPLE_RATES:
            try:
                self._start_stream_with_rate(rate)
                return
            except Exception as exc:
                last_error = exc
                continue

        raise RuntimeError(f"Could not open mic stream: {last_error}") from last_error

    def _start_stream_with_rate(self, rate: int) -> None:
        self.samplerate = rate
        with sf.SoundFile(
            self.output_path,
            mode="w",
            samplerate=rate,
            channels=1,
            subtype="PCM_16",
        ) as wav_file:
            print(f"Listening... (recording at {rate} Hz)")

            def callback(indata, frames, time_info, status):
                if status:
                    print(f"[status] {status}")
                wav_file.write(indata.copy())

            with sd.InputStream(
                samplerate=rate,
                channels=1,
                dtype="int16",
                callback=callback,
            ):
                while not self._stop_event.wait(0.1):
                    pass


def normalize_audio_for_asr(audio_path: Path, use_noisy_filter: bool = False) -> Path:
    output_path = audio_path.with_name(f"{audio_path.stem}.asr.wav")
    if shutil.which("ffmpeg") is None:
        raise RuntimeError(
            "Missing required command 'ffmpeg'. Install with 'brew install ffmpeg'."
        )

    filter_chain = (
        DICTATE_NOISY_PREPROCESS_FILTER
        if use_noisy_filter
        else DICTATE_PREPROCESS_FILTER
    )
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(audio_path),
        "-vn",
        "-af",
        filter_chain,
        "-ac",
        "1",
        "-ar",
        "16000",
        "-acodec",
        "pcm_s16le",
        "-f",
        "wav",
        str(output_path),
    ]
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    if proc.stderr:
        print(trim_command_output(proc.stderr))
    if not output_path.exists():
        raise RuntimeError(f"Preprocessed audio file not found: {output_path}")
    return output_path


def paste_text(text: str) -> None:
    if not text:
        print("No text was produced; nothing to paste.")
        return

    pyperclip.copy(text)
    time.sleep(0.1)

    applescript = """
    tell application "System Events"
        keystroke "v" using {command down}
    end tell
    """
    try:
        subprocess.run(
            ["osascript", "-e", applescript],
            check=True,
            capture_output=True,
            text=True,
        )
        return
    except Exception as exc:
        # Optional fallback if AppleScript is unavailable in your setup.
        print(f"AppleScript paste failed ({exc}). Trying pyautogui fallback...")

    try:
        import pyautogui

        pyautogui.hotkey("command", "v")
    except Exception as fallback_exc:
        raise RuntimeError(
            "Paste failed. Make sure Accessibility/Input Monitoring permissions are granted."
        ) from fallback_exc


state_lock = threading.Lock()
is_recording = False
is_transcribing = False
current_recorder: Optional[MicRecorder] = None
right_option_triggered = False

RIGHT_OPTION_KEYS = {getattr(keyboard.Key, "alt_r", keyboard.Key.alt)}


def is_right_option_key(key) -> bool:
    return key in RIGHT_OPTION_KEYS


def on_hotkey() -> None:
    global is_recording, is_transcribing, current_recorder

    with state_lock:
        if is_transcribing:
            print("Busy transcribing. Please wait.")
            return

        if not is_recording:
            try:
                temp_path = Path(tempfile.gettempdir()) / f"dictate_{int(time.time() * 1000)}.wav"
                current_recorder = MicRecorder(temp_path)
                current_recorder.start()
                is_recording = True
                print("Hotkey pressed: start recording.")
            except Exception as e:
                print(f"Failed to start recording: {e}")
                current_recorder = None
            return

        # Stop path
        recorder = current_recorder
        current_recorder = None
        is_recording = False
        is_transcribing = True

    if recorder is None:
        print("No active recorder found.")
        with state_lock:
            is_transcribing = False
        return

    print("Hotkey pressed: stop recording.")
    audio_path = recorder.stop()

    def worker(path: Path) -> None:
        global is_transcribing
        cfg = RUNTIME_CONFIG
        files_to_cleanup = [path]
        try:
            print("Transcribing...")
            transcribe_path = path
            if cfg.get("use_audio_preprocess"):
                try:
                    transcribe_path = normalize_audio_for_asr(
                        path,
                        bool(cfg.get("noisy_preprocess")),
                    )
                    files_to_cleanup.append(transcribe_path)
                except Exception as exc:
                    print(
                        "Audio preprocessing failed; using raw recording for this pass "
                        f"({exc})."
                    )
                    transcribe_path = path
            transcript, low_confidence = transcribe_audio(
                transcribe_path,
                str(cfg["model"]),
                float(cfg["low_confidence_threshold"]),
            )
            if low_confidence and bool(cfg.get("ollama_enabled")):
                print("Running second-pass correction on low-confidence phrases...")
            transcript = post_process_transcript(
                transcript,
                low_confidence,
                vocab_path=CORRECTION_DICT_PATH,
                formatting_enabled=bool(cfg.get("formatting_enabled")),
                ollama_enabled=bool(cfg.get("ollama_enabled")),
                ollama_model=OLLAMA_MODEL,
                strict_vocab=False,
                verbose=True,
            )
            print("Pasting...")
            paste_text(transcript)
            print("Pasted!")
        except Exception as e:
            print(f"Error: {e}")
        finally:
            for file_path in files_to_cleanup:
                if file_path.exists():
                    try:
                        file_path.unlink()
                    except Exception:
                        print(f"Could not delete temp file: {file_path}")
            with state_lock:
                is_transcribing = False

    threading.Thread(target=worker, args=(audio_path,), daemon=True).start()


def main() -> None:
    parser = argparse.ArgumentParser(description="Global macOS dictation via mlx-whisper.")
    parser.add_argument(
        "--preset",
        choices=tuple(DICTATE_PRESETS),
        default=DICTATE_PRESET_DEFAULT,
        help="Transcription profile for speed/quality tradeoff.",
    )
    parser.add_argument(
        "--model",
        default="",
        help="mlx-whisper model id (overrides preset/environment).",
    )
    parser.add_argument(
        "--low-confidence-threshold",
        type=float,
        default=None,
        help="Average log-probability threshold for low-confidence segments.",
    )
    parser.add_argument(
        "--no-audio-preprocess",
        action="store_true",
        help="Skip ASR audio preprocessing pass (faster runtime, potentially lower quality).",
    )
    parser.add_argument(
        "--noisy-mic",
        action="store_true",
        help="Use a stronger preprocessing chain for noisy input before ASR.",
    )
    parser.add_argument(
        "--no-formatting",
        action="store_true",
        help="Skip punctuation/sentence capitalization normalization.",
    )
    parser.add_argument(
        "--no-ollama",
        action="store_true",
        help="Skip the Ollama second-pass correction for lower latency.",
    )
    args = parser.parse_args()

    global RUNTIME_CONFIG
    RUNTIME_CONFIG = resolve_runtime_config(args)

    print("Global dictation started.")
    print(
        f"Profile: preset={RUNTIME_CONFIG['preset']}, model={RUNTIME_CONFIG['model_label']}, "
        f"audio-preprocess={RUNTIME_CONFIG['use_audio_preprocess']}, "
        f"noisy-preprocess={RUNTIME_CONFIG['noisy_preprocess']}, "
        f"fmt={RUNTIME_CONFIG['formatting_enabled']}, "
        f"ollama={RUNTIME_CONFIG['ollama_enabled']}"
    )
    print("Loading Whisper model into memory...")
    warm_model_cache(str(RUNTIME_CONFIG["model"]))
    print("Model ready.")
    print("Press Right Option to start recording, then press again to stop and paste.")
    print("Press Ctrl+C in terminal to exit.")

    def on_press(key) -> None:
        global right_option_triggered

        if is_right_option_key(key) and not right_option_triggered:
            right_option_triggered = True
            print("Right Option detected.")
            on_hotkey()

    def on_release(key) -> None:
        global right_option_triggered

        if is_right_option_key(key):
            right_option_triggered = False

    listener = keyboard.Listener(on_press=on_press, on_release=on_release)
    listener.start()
    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        print("Exiting...")
    finally:
        listener.stop()
        with state_lock:
            active = current_recorder
            if active is not None:
                try:
                    active.stop()
                except Exception:
                    pass


if __name__ == "__main__":
    main()
