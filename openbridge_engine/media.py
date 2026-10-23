from __future__ import annotations

from pathlib import Path
import os
import sys
import time
import shutil
import subprocess
import wave
from urllib.parse import urlparse

from .common import trim_command_output


ASR_AUDIO_RATE = 16000
ASR_PREPROCESS_FILTER = "highpass=f=85,lowpass=f=7800"
ASR_NOISY_PREPROCESS_FILTER = "highpass=f=85,lowpass=f=7800,acompressor=threshold=0.05:ratio=8"
YTDLP_AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio/best"
YTDLP_PLAYER_CLIENTS = [
    None,
    "youtube:player_client=ios,android,web_safari",
    "youtube:player_client=tv,ios",
]
YOUTUBE_FAILURE_FALLBACK = (
    "Try downloading the audio or video in a browser and use Transcribe File instead. "
    "Some YouTube videos require sign-in, browser cookies, region access, or a format yt-dlp cannot currently fetch."
)
COMMON_FFMPEG_PATHS = (
    Path("/opt/homebrew/bin/ffmpeg"),
    Path("/usr/local/bin/ffmpeg"),
    Path("/usr/bin/ffmpeg"),
)
TRANSCRIPTION_CHUNK_SECONDS = 30.0


class YouTubeExtractionError(RuntimeError):
    pass


def _candidate_ffmpeg_paths() -> list[Path]:
    candidates: list[Path] = []

    explicit_path = os.environ.get("OPENBRIDGE_FFMPEG_PATH")
    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    # Release builds place helper binaries next to the app executable.
    executable_path = Path(sys.executable).resolve()
    candidates.append(executable_path.with_name("ffmpeg"))

    # Source files live at Contents/Resources/python/openbridge_engine inside
    # the app bundle, so this reaches Contents/MacOS/ffmpeg.
    module_path = Path(__file__).resolve()
    for parent in module_path.parents:
        if parent.name == "Contents":
            candidates.append(parent / "MacOS" / "ffmpeg")
            break

    which_result = shutil.which("ffmpeg")
    if which_result:
        candidates.append(Path(which_result))

    candidates.extend(COMMON_FFMPEG_PATHS)
    return candidates


def resolve_ffmpeg_executable() -> str | None:
    seen: set[str] = set()
    for candidate in _candidate_ffmpeg_paths():
        candidate_path = str(candidate)
        if candidate_path in seen:
            continue
        seen.add(candidate_path)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate_path
    return None


def ffmpeg_status() -> dict[str, object]:
    executable = resolve_ffmpeg_executable()
    return {
        "available": executable is not None,
        "path": executable,
        "searchedPaths": [str(path) for path in _candidate_ffmpeg_paths()],
    }


def require_ffmpeg() -> str:
    executable = resolve_ffmpeg_executable()
    if executable is None:
        raise RuntimeError(
            "OpenBridge could not find ffmpeg, which is required for file and YouTube transcription. "
            "Install it with `brew install ffmpeg`, or use a release build that bundles ffmpeg."
        )
    return executable


def _candidate_ffprobe_paths() -> list[Path]:
    candidates: list[Path] = []

    explicit_path = os.environ.get("OPENBRIDGE_FFPROBE_PATH")
    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    ffmpeg = resolve_ffmpeg_executable()
    if ffmpeg:
        candidates.append(Path(ffmpeg).with_name("ffprobe"))

    which_result = shutil.which("ffprobe")
    if which_result:
        candidates.append(Path(which_result))

    candidates.extend(path.with_name("ffprobe") for path in COMMON_FFMPEG_PATHS)
    return candidates


def resolve_ffprobe_executable() -> str | None:
    seen: set[str] = set()
    for candidate in _candidate_ffprobe_paths():
        candidate_path = str(candidate)
        if candidate_path in seen:
            continue
        seen.add(candidate_path)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate_path
    return None


def media_duration_seconds(path: Path) -> float | None:
    if path.suffix.lower() == ".wav":
        try:
            with wave.open(str(path), "rb") as audio:
                frame_rate = audio.getframerate()
                if frame_rate > 0:
                    return audio.getnframes() / frame_rate
        except Exception:
            pass

    ffprobe = resolve_ffprobe_executable()
    if ffprobe is None:
        return None
    try:
        proc = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return float(proc.stdout.strip())
    except Exception:
        return None


def media_chunk_count(duration_seconds: float | None) -> int | None:
    if duration_seconds is None:
        return None
    return max(1, int((duration_seconds + TRANSCRIPTION_CHUNK_SECONDS - 0.001) // TRANSCRIPTION_CHUNK_SECONDS))


def run_command_capture(cmd: list[str]) -> tuple[bool, str]:
    try:
        proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
        return True, trim_command_output(f"{proc.stdout}\n{proc.stderr}")
    except subprocess.CalledProcessError as exc:
        return False, trim_command_output(f"{exc.stdout}\n{exc.stderr}")


def is_supported_web_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def extract_local_media_audio(source_path: Path, temp_dir: Path, *, noisy: bool = False) -> Path:
    if not source_path.exists():
        raise FileNotFoundError(f"Input file not found: {source_path}")
    if source_path.is_dir():
        raise RuntimeError(f"Input path is a folder, not an audio or video file: {source_path}")

    ffmpeg = require_ffmpeg()
    audio_filter = ASR_NOISY_PREPROCESS_FILTER if noisy else ASR_PREPROCESS_FILTER
    audio_path = temp_dir / f"{source_path.stem or 'openbridge-media'}.openbridge.wav"
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(source_path),
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
        str(audio_path),
    ]

    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        output = trim_command_output(f"{exc.stdout}\n{exc.stderr}")
        if output:
            raise RuntimeError(f"ffmpeg failed:\n{output}") from exc
        raise RuntimeError("ffmpeg failed with no additional output.") from exc

    if not audio_path.exists():
        raise RuntimeError(f"ffmpeg output not found: {audio_path}")
    return audio_path


def extract_youtube_audio(
    url: str,
    temp_dir: Path,
    *,
    cookies_from_browser: str | None = None,
    python_executable: str | None = None,
) -> tuple[Path, str]:
    if not is_supported_web_url(url):
        raise YouTubeExtractionError("Enter a valid http or https YouTube URL.")

    ffmpeg = require_ffmpeg()
    executable = python_executable or sys.executable
    start = time.time()
    output_template = str(temp_dir / "%(title)s.%(ext)s")
    last_error_output = ""

    for player_clients in YTDLP_PLAYER_CLIENTS:
        cmd = [
            executable,
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
            "--ffmpeg-location",
            ffmpeg,
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
        details = _youtube_failure_details(last_error_output, cookies_from_browser)
        raise YouTubeExtractionError(details)

    candidates = [
        path
        for path in temp_dir.iterdir()
        if path.is_file()
        and path.suffix.lower() in {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg"}
        and path.stat().st_mtime >= start - 1.0
    ]
    if not candidates:
        raise YouTubeExtractionError(f"yt-dlp did not create an audio file. {YOUTUBE_FAILURE_FALLBACK}")

    audio_path = sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)[0]
    return audio_path, audio_path.stem


def _youtube_failure_details(last_error_output: str, cookies_from_browser: str | None) -> str:
    message = trim_command_output(last_error_output, max_lines=8)
    if not message:
        message = "yt-dlp could not fetch audio from this URL."

    lower_message = message.lower()
    if "playlist" in lower_message:
        return "Playlists are not supported in this beta. Open one video and try again."
    if "unsupported url" in lower_message:
        return "OpenBridge could not recognize this YouTube URL. Open the video page and copy its full URL."
    if "login_required" in lower_message or "sign in" in lower_message:
        return f"This video appears to require sign-in. {YOUTUBE_FAILURE_FALLBACK}"
    if "private video" in lower_message or "members-only" in lower_message:
        return f"This video is not publicly available. {YOUTUBE_FAILURE_FALLBACK}"
    if "http error 403" in lower_message:
        if cookies_from_browser:
            return f"YouTube returned HTTP 403 even with browser cookies. {YOUTUBE_FAILURE_FALLBACK}"
        return f"YouTube returned HTTP 403. {YOUTUBE_FAILURE_FALLBACK}"

    return f"{message}\n{YOUTUBE_FAILURE_FALLBACK}"
