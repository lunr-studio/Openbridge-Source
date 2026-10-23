#!/usr/bin/env python3
"""Transcribe a YouTube URL or local MP4 file to a .txt transcript using mlx-whisper."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import shutil
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

from openbridge_engine.common import (
    getenv_bool,
    getenv_float,
    post_process_transcript,
    resolve_local_model,
    transcribe_audio,
    trim_command_output,
)
from openbridge_engine.config import MODEL_ROOT, REPO_MODEL_ROOT


CORRECTION_DICT_PATH = Path(__file__).with_name("vocab_corrections.json")
DEFAULT_CORRECTION_MODEL = "gemma4:e2b"
YTDLP_AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio/best"
ASR_AUDIO_RATE = 16000
ASR_PREPROCESS_FILTER = "highpass=f=85,lowpass=f=7800"
ASR_NOISY_PREPROCESS_FILTER = "highpass=f=85,lowpass=f=7800,acompressor=threshold=0.05:ratio=8"
VIDEO_PRESET_DEFAULT = os.environ.get("LUNR_WHISPR_VIDEO_PRESET", "balanced")
VIDEO_PRESETS = {
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
    "fast": {
        "model_candidates": ["mlx-community/whisper-tiny"],
        "low_confidence_threshold": -1.0,
        "audio_preprocess": False,
    },
}
YTDLP_PLAYER_CLIENTS = [
    None,
    "youtube:player_client=ios,android,web_safari",
    "youtube:player_client=tv,ios",
]
SCRIPT_MODEL_ROOTS = (
    [MODEL_ROOT]
    if os.environ.get("LUNR_WHISPR_LOCAL_MODEL_DIR")
    else [REPO_MODEL_ROOT]
)


def require_command(name: str, install_hint: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"Missing required command '{name}'. Install it with: {install_hint}")


def run_command_capture(cmd: list[str]) -> tuple[bool, str]:
    try:
        proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
        return True, trim_command_output(f"{proc.stdout}\n{proc.stderr}")
    except subprocess.CalledProcessError as exc:
        return False, trim_command_output(f"{exc.stdout}\n{exc.stderr}")


def sanitize_filename(value: str) -> str:
    """Make a filesystem-safe file stem."""
    value = re.sub(r'[\\/*?:"<>|]', "_", value)
    value = re.sub(r"\s+", " ", value).strip()
    value = value.strip(".")
    return value[:180] or "transcript"


def is_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def pick_output_path(base_name: str) -> Path:
    base = sanitize_filename(base_name)
    base_dir = Path.cwd()
    path = base_dir / f"{base}.txt"
    if not path.exists():
        return path

    counter = 1
    while True:
        candidate = base_dir / f"{base}_{counter}.txt"
        if not candidate.exists():
            return candidate
        counter += 1


def extract_audio_from_youtube(
    url: str, temp_dir: Path, cookies_from_browser: str | None
) -> tuple[Path, str]:
    require_command("ffmpeg", "brew install ffmpeg")
    start = time.time()
    output_template = str(temp_dir / "%(title)s.%(ext)s")
    print(f"Downloading/ extracting audio with yt-dlp: {url}")
    last_error_output = ""

    for player_clients in YTDLP_PLAYER_CLIENTS:
        cmd = [
            sys.executable,
            "-m",
            "yt_dlp",
            "--restrict-filenames",
            "-f",
            YTDLP_AUDIO_FORMAT,
            "-x",
            "--audio-format",
            "wav",
            "--audio-quality",
            "0",
            "-o",
            output_template,
            "--no-playlist",
        ]
        if player_clients:
            cmd.extend(["--extractor-args", player_clients])
        if cookies_from_browser:
            cmd.extend(["--cookies-from-browser", cookies_from_browser])
        cmd.append(url)

        ok, output = run_command_capture(cmd)
        if ok:
            break
        last_error_output = output
    else:
        hint = ""
        if "HTTP Error 403" in last_error_output and not cookies_from_browser:
            hint = (
                "\nHint: this video likely requires browser cookies. Try rerunning with "
                "--cookies-from-browser chrome"
            )
        if last_error_output:
            raise RuntimeError(f"yt-dlp failed:\n{last_error_output}{hint}")
        raise RuntimeError(f"yt-dlp failed with no additional output.{hint}")

    candidates = [
        p
        for p in temp_dir.iterdir()
        if p.is_file()
        and p.suffix.lower() in {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg"}
        and p.stat().st_mtime >= start - 1.0
    ]
    if not candidates:
        raise RuntimeError("yt-dlp did not create an audio file in temp dir.")

    audio_path = sorted(candidates, key=lambda p: p.stat().st_mtime, reverse=True)[0]
    return audio_path, audio_path.stem


def extract_audio_from_mp4(path: Path, temp_dir: Path) -> tuple[Path, str]:
    require_command("ffmpeg", "brew install ffmpeg")
    audio_path = temp_dir / f"{path.stem}.wav"
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(path),
        "-vn",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-f",
        "wav",
        str(audio_path),
    ]
    print(f"Extracting audio with ffmpeg: {path}")
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        output = trim_command_output(f"{exc.stdout}\n{exc.stderr}")
        if output:
            raise RuntimeError(f"ffmpeg failed:\n{output}") from exc
        raise RuntimeError("ffmpeg failed with no additional output.") from exc
    if not audio_path.exists():
        raise RuntimeError(f"ffmpeg output not found: {audio_path}")
    return audio_path, path.stem


def normalize_audio_for_asr(
    audio_path: Path, temp_dir: Path, noisy: bool = False
) -> Path:
    """Normalize and standardize audio for Whisper transcription."""
    normalized_path = temp_dir / f"{audio_path.stem}.asr.wav"
    audio_filter = ASR_NOISY_PREPROCESS_FILTER if noisy else ASR_PREPROCESS_FILTER
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(audio_path),
        "-vn",
        "-af",
        audio_filter,
        "-ac",
        "1",
        "-ar",
        str(ASR_AUDIO_RATE),
        "-acodec",
        "pcm_s16le",
        "-f",
        "wav",
        str(normalized_path),
    ]
    try:
        proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        output = trim_command_output(f"{exc.stdout}\n{exc.stderr}")
        if output:
            raise RuntimeError(f"ffmpeg preprocessing failed:\n{output}") from exc
        raise RuntimeError("ffmpeg preprocessing failed with no additional output.") from exc
    if not normalized_path.exists():
        raise RuntimeError(f"Preprocessed audio file not found: {normalized_path}")
    if proc.stderr:
        print(trim_command_output(proc.stderr))
    return normalized_path


def run(args: argparse.Namespace) -> None:
    source = args.source.strip()
    preset = args.preset
    preset_cfg = VIDEO_PRESETS.get(preset, VIDEO_PRESETS["balanced"])
    explicit_model = os.environ.get("LUNR_WHISPR_VIDEO_MODEL", "").strip()
    if args.model:
        explicit_model = args.model.strip() or explicit_model
    model_path, model_label = resolve_local_model(
        explicit_model,
        preset_cfg["model_candidates"],
        local_model_roots=SCRIPT_MODEL_ROOTS,
        missing_help=(
            "Set --model or LUNR_WHISPR_VIDEO_MODEL to a local model path, "
            "or place model folders under ./models."
        ),
    )
    low_confidence_threshold = (
        args.low_confidence_threshold
        if args.low_confidence_threshold is not None
        else getenv_float(
            "LUNR_WHISPR_VIDEO_LOW_CONFIDENCE_THRESHOLD",
            preset_cfg["low_confidence_threshold"],
        )
    )
    skip_ollama = args.no_ollama
    skip_vocab = args.no_vocab
    correction_model = args.correction_model
    use_noisy_filter = args.noisy_mic
    audio_preprocess = (
        preset_cfg["audio_preprocess"] and not args.no_audio_preprocess
    )
    apply_formatting = not (
        args.no_formatting or getenv_bool("LUNR_WHISPR_NO_FORMATTING", False)
    )

    with tempfile.TemporaryDirectory(prefix="transcribe_video_") as td:
        temp_dir = Path(td)

        if is_url(source):
            audio_path, title = extract_audio_from_youtube(
                source,
                temp_dir,
                args.cookies_from_browser,
            )
        else:
            input_path = Path(source).expanduser()
            if not input_path.exists():
                raise FileNotFoundError(f"Input file not found: {input_path}")
            if input_path.suffix.lower() != ".mp4":
                print("Warning: input is not .mp4; attempting audio extraction anyway.")
            audio_path, title = extract_audio_from_mp4(input_path, temp_dir)
        if audio_preprocess:
            audio_path = normalize_audio_for_asr(
                audio_path,
                temp_dir,
                noisy=use_noisy_filter,
            )

        print(
            f"Profile: preset={preset}, model={model_label}, "
            f"audio_preprocess={audio_preprocess}, noisy_filter={use_noisy_filter}"
        )
        out_txt = pick_output_path(title)
        print(f"Transcribing with model: {model_label}")
        text, low_confidence = transcribe_audio(
            audio_path,
            model_path,
            low_confidence_threshold,
        )
        if low_confidence and not skip_ollama:
            print(f"Running second-pass correction using model: {correction_model}")
        text = post_process_transcript(
            text,
            low_confidence,
            vocab_path=Path(args.vocab_dict),
            vocab_enabled=not skip_vocab,
            formatting_enabled=apply_formatting,
            ollama_enabled=not skip_ollama,
            ollama_model=correction_model,
            strict_vocab=False,
            verbose=True,
        )
        out_txt.write_text(text, encoding="utf-8")

        try:
            audio_path.unlink()
        except Exception:
            pass

    print(f"Transcript saved to: {out_txt}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Transcribe a YouTube URL or local .mp4 file and save output to a .txt file."
        )
    )
    parser.add_argument("source", help="YouTube URL or local .mp4 path")
    parser.add_argument(
        "--cookies-from-browser",
        default=None,
        help="Browser name for yt-dlp cookies, e.g. chrome, safari, edge, firefox",
    )
    parser.add_argument(
        "--vocab-dict",
        default=str(CORRECTION_DICT_PATH),
        help="Path to vocab_corrections.json file",
    )
    parser.add_argument(
        "--no-vocab",
        action="store_true",
        help="Disable vocab correction pass",
    )
    parser.add_argument(
        "--no-ollama",
        action="store_true",
        help="Skip second-pass correction with ollama",
    )
    parser.add_argument(
        "--correction-model",
        default=DEFAULT_CORRECTION_MODEL,
        help="Ollama model to use for second-pass correction",
    )
    parser.add_argument(
        "--low-confidence-threshold",
        type=float,
        default=None,
        help="Average log-probability threshold for low-confidence segments",
    )
    parser.add_argument(
        "--no-audio-preprocess",
        action="store_true",
        help="Skip ASR audio preprocessing pass (faster runtime, potentially lower quality).",
    )
    parser.add_argument(
        "--preset",
        choices=tuple(VIDEO_PRESETS),
        default=VIDEO_PRESET_DEFAULT,
        help="Transcription profile for speed/quality tradeoff.",
    )
    parser.add_argument(
        "--noisy-mic",
        action="store_true",
        help="Use a stronger preprocessing chain for noisy audio before ASR.",
    )
    parser.add_argument(
        "--no-formatting",
        action="store_true",
        help="Skip punctuation/sentence capitalization normalization.",
    )
    parser.add_argument(
        "--model",
        default="",
        help="mlx-whisper model id (overrides preset)",
    )
    run(parser.parse_args())


if __name__ == "__main__":
    main()
