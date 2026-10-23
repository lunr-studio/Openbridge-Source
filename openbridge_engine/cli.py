from __future__ import annotations

import argparse
import contextlib
import importlib.metadata
import json
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from .common import (
    AudioTranscriptionResult,
    post_process_transcript,
    raise_if_repetition_loop,
    transcribe_audio,
    transcribe_audio_detailed,
    transcribe_audio_detailed_for_runtime,
    warm_model_cache_for_runtime,
)
from .command_mode import (
    COMMAND_MODE_TIMEOUT_SECONDS,
    DEFAULT_COMMAND_MODE_MAX_INPUT_CHARS,
    CommandModeError,
    transform_text_with_local_llm,
)
from .config import (
    APP_SUPPORT_ROOT,
    CURATED_MODELS,
    DEFAULT_CORRECTION_MODEL,
    DEFAULT_LLM_PROVIDER,
    DEFAULT_WHISPER_FALLBACK_MODEL_ID,
    DEFAULT_MODEL_ID,
    DEFAULT_MLX_LLM_MODEL,
    DEFAULT_TRANSCRIPTION_LANGUAGE,
    DEFAULT_VOCAB_PATH,
    ENGINE_VERSION,
    MODEL_ROOT,
    SPEECH_RUNTIME_MLX_WHISPER,
    SPEECH_RUNTIME_PARAKEET_MLX,
    SPEECH_RUNTIME_PARAKEET_TRANSFORMERS,
)
from .local_llm import local_llm_status
from .meeting_cleanup import cleanup_meeting_segments
from .meeting_cleanup_benchmark import CleanupBenchmarkError
from .media import (
    YouTubeExtractionError,
    extract_local_media_audio,
    extract_youtube_audio,
    ffmpeg_status,
    media_chunk_count,
    media_duration_seconds,
)
from .models import (
    curated_model_metadata,
    dependency_status,
    install_curated_model,
    list_installed_models,
    model_runtime_for,
    parakeet_validation_plan,
    remove_curated_model,
    resolve_engine_model,
)
from .readiness import check_readiness


SCHEMA_VERSION = 1


class EngineCLIError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        details: str | None = None,
        code: str = "engine_error",
        exit_code: int = 1,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.details = details
        self.code = code
        self.exit_code = exit_code


class EngineArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise EngineCLIError(
            "Invalid command arguments.",
            details=message,
            code="invalid_arguments",
            exit_code=2,
        )


def _emit(payload: dict[str, object], *, stream=None) -> int:
    if stream is None:
        stream = sys.stdout
    print(json.dumps(payload, indent=2, sort_keys=True), file=stream)
    return 0


def _ok(**payload: object) -> int:
    return _emit({"ok": True, "schemaVersion": SCHEMA_VERSION, **payload})


def _error(
    message: str,
    *,
    details: str | None = None,
    code: str = "engine_error",
    exit_code: int = 1,
) -> int:
    payload: dict[str, object] = {
        "ok": False,
        "schemaVersion": SCHEMA_VERSION,
        "error": message,
        "code": code,
    }
    if details:
        payload["details"] = details
    _emit(payload, stream=sys.stderr)
    return exit_code


def _optional_path(raw_path: str | None) -> Path | None:
    if raw_path is None:
        return None
    cleaned = raw_path.strip()
    if not cleaned:
        return None
    return Path(cleaned).expanduser()


def _resolve_model_with_runtime(model_id_or_path: str | None) -> dict[str, object]:
    model_path, model_label = resolve_engine_model(model_id_or_path)
    return {
        "requested": model_id_or_path or DEFAULT_MODEL_ID,
        "label": model_label,
        "path": model_path,
        "runtime": model_runtime_for(model_id_or_path),
        "fallbackUsed": False,
        "fallbackReason": None,
    }


def _resolve_transcription_model_or_fallback(model_id_or_path: str | None) -> dict[str, object]:
    try:
        return _resolve_model_with_runtime(model_id_or_path)
    except Exception as exc:
        requested_runtime = model_runtime_for(model_id_or_path)
        if requested_runtime not in {SPEECH_RUNTIME_PARAKEET_TRANSFORMERS, SPEECH_RUNTIME_PARAKEET_MLX}:
            raise
        fallback = _resolve_model_with_runtime(DEFAULT_WHISPER_FALLBACK_MODEL_ID)
        fallback["requested"] = model_id_or_path or DEFAULT_MODEL_ID
        fallback["requestedRuntime"] = requested_runtime
        fallback["fallbackUsed"] = True
        fallback["fallbackReason"] = str(exc)
        return fallback


def _transcribe_detailed_with_optional_fallback(
    audio_path: Path,
    model_id_or_path: str | None,
    low_confidence_threshold: float,
    *,
    language: str,
    condition_on_previous_text: bool,
) -> tuple[AudioTranscriptionResult, dict[str, object]]:
    model = _resolve_transcription_model_or_fallback(model_id_or_path)
    try:
        if model["runtime"] == SPEECH_RUNTIME_MLX_WHISPER:
            if condition_on_previous_text:
                text, low_confidence = transcribe_audio(
                    audio_path,
                    str(model["path"]),
                    low_confidence_threshold,
                    language=language,
                )
                transcription = AudioTranscriptionResult(
                    text=text,
                    low_confidence_segments=low_confidence,
                    segments=[],
                )
            else:
                transcription = transcribe_audio_detailed(
                    audio_path,
                    str(model["path"]),
                    low_confidence_threshold,
                    language=language,
                    condition_on_previous_text=condition_on_previous_text,
                )
        else:
            transcription = transcribe_audio_detailed_for_runtime(
                audio_path,
                str(model["path"]),
                low_confidence_threshold,
                runtime=str(model["runtime"]),
                language=language,
                condition_on_previous_text=condition_on_previous_text,
            )
        return transcription, model
    except Exception as exc:
        if (
            model.get("runtime") not in {SPEECH_RUNTIME_PARAKEET_TRANSFORMERS, SPEECH_RUNTIME_PARAKEET_MLX}
            or model.get("fallbackUsed") is True
        ):
            raise
        fallback = _resolve_model_with_runtime(DEFAULT_WHISPER_FALLBACK_MODEL_ID)
        fallback["requested"] = model_id_or_path or DEFAULT_MODEL_ID
        fallback["requestedRuntime"] = model.get("runtime")
        fallback["requestedLabel"] = model.get("label")
        fallback["fallbackUsed"] = True
        fallback["fallbackReason"] = str(exc)
        if condition_on_previous_text:
            text, low_confidence = transcribe_audio(
                audio_path,
                str(fallback["path"]),
                low_confidence_threshold,
                language=language,
            )
            transcription = AudioTranscriptionResult(
                text=text,
                low_confidence_segments=low_confidence,
                segments=[],
            )
        else:
            transcription = transcribe_audio_detailed(
                audio_path,
                str(fallback["path"]),
                low_confidence_threshold,
                language=language,
                condition_on_previous_text=condition_on_previous_text,
            )
        return transcription, fallback


def _transcript_model_payload(model: dict[str, object]) -> dict[str, object]:
    payload: dict[str, object] = {
        "modelLabel": model["label"],
        "modelPath": model["path"],
        "modelRuntime": model["runtime"],
        "requestedModel": model["requested"],
        "fallbackUsed": model.get("fallbackUsed") is True,
    }
    if model.get("requestedRuntime"):
        payload["requestedRuntime"] = model["requestedRuntime"]
    if model.get("requestedLabel"):
        payload["requestedModelLabel"] = model["requestedLabel"]
    if model.get("fallbackReason"):
        payload["fallbackReason"] = model["fallbackReason"]
    return payload


def command_doctor(_: argparse.Namespace) -> int:
    return _ok(
        engineVersion=ENGINE_VERSION,
        appSupportRoot=str(APP_SUPPORT_ROOT),
        modelRoot=str(MODEL_ROOT),
        defaultModelId=DEFAULT_MODEL_ID,
        defaultTranscriptionLanguage=DEFAULT_TRANSCRIPTION_LANGUAGE,
        curatedModels=curated_model_metadata(),
        installedModels=list_installed_models(),
        dependencies=dependency_status(),
        localLlm=local_llm_status(),
        commands={
            "ffmpeg": ffmpeg_status()["available"],
            "ollama": shutil.which("ollama") is not None,
        },
    )


def command_models(args: argparse.Namespace) -> int:
    try:
        if args.models_command == "list":
            return _ok(curatedModels=curated_model_metadata(), installedModels=list_installed_models())
        if args.models_command == "install":
            installed = install_curated_model(args.model, force=args.force)
            return _ok(model=installed)
        if args.models_command == "remove":
            removed = remove_curated_model(args.model)
            return _ok(model=removed)
    except Exception as exc:
        return _error("Model command failed.", details=str(exc), code="model_command_failed")
    return _error("Unknown models command.", code="unknown_models_command")


def command_parakeet_plan(_: argparse.Namespace) -> int:
    return _ok(parakeetValidation=parakeet_validation_plan())


def command_warm_model(args: argparse.Namespace) -> int:
    try:
        model = _resolve_model_with_runtime(args.model)
        warm_model_cache_for_runtime(str(model["path"]), str(model["runtime"]))
        return _ok(model=_transcript_model_payload(model))
    except Exception as exc:
        return _error("Model warm-up failed.", details=str(exc), code="model_warm_failed")


def command_readiness(args: argparse.Namespace) -> int:
    try:
        return _ok(
            readiness=check_readiness(
                model_identifier=args.model,
                cleanup_mode=args.cleanup_mode,
                run_load_check=args.load_check,
                run_inference_check=args.inference_check,
            )
        )
    except Exception as exc:
        return _error("Readiness check failed.", details=str(exc), code="readiness_check_failed")


def _rounded(value: float | None, digits: int = 3) -> float | None:
    if value is None:
        return None
    return round(value, digits)


def _mean(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def _sysctl_value(name: str) -> str | None:
    try:
        proc = subprocess.run(
            ["sysctl", "-n", name],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except Exception:
        return None
    value = proc.stdout.strip()
    return value or None


def _distribution_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except Exception:
        return None


def _mlx_default_device() -> str | None:
    try:
        import mlx.core as mx

        return str(mx.default_device())
    except Exception:
        return None


def _machine_context() -> dict[str, object]:
    mac_version, _, _ = platform.mac_ver()
    memory_raw = _sysctl_value("hw.memsize")
    memory_bytes: int | None = None
    if memory_raw is not None:
        try:
            memory_bytes = int(memory_raw)
        except ValueError:
            memory_bytes = None

    return {
        "platform": platform.platform(),
        "macOSVersion": mac_version or None,
        "machine": platform.machine(),
        "processor": platform.processor() or None,
        "cpuBrand": _sysctl_value("machdep.cpu.brand_string"),
        "memoryBytes": memory_bytes,
        "pythonVersion": platform.python_version(),
        "pythonExecutable": sys.executable,
    }


def _runtime_context(runtime: str = "mlx-whisper") -> dict[str, object]:
    dependencies = dependency_status()
    return {
        "engineVersion": ENGINE_VERSION,
        "runtime": runtime,
        "python": dependencies["python"],
        "mlxWhisperAvailable": dependencies["mlx_whisper"],
        "mlxLmAvailable": dependencies["mlx_lm"],
        "huggingFaceHubAvailable": dependencies["huggingface_hub"],
        "transformersAvailable": dependencies.get("transformers"),
        "torchAvailable": dependencies.get("torch"),
        "parakeetTransformersAvailable": dependencies.get("parakeet_transformers"),
        "parakeetMlxAvailable": dependencies.get("parakeet_mlx"),
        "mlxVersion": _distribution_version("mlx"),
        "mlxWhisperVersion": _distribution_version("mlx-whisper"),
        "parakeetMlxVersion": _distribution_version("parakeet-mlx"),
        "transformersVersion": _distribution_version("transformers"),
        "torchVersion": _distribution_version("torch"),
        "mlxMetalVersion": _distribution_version("mlx-metal"),
        "mlxDefaultDevice": _mlx_default_device(),
    }


def _markdown_cell(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ").strip()


def _benchmark_markdown_row(
    *,
    label: str,
    duration_seconds: float,
    model_label: str,
    model_path: str,
    machine: dict[str, object],
    runtime: dict[str, object],
    summary: dict[str, object],
    notes: str,
    warm_model_first: bool,
) -> str:
    machine_label = machine.get("cpuBrand") or machine.get("machine") or "Unknown Mac"
    runtime_name = runtime.get("runtime")
    runtime_label = (
        runtime.get("mlxDefaultDevice")
        if runtime_name == "mlx_whisper"
        else runtime_name
    ) or "mlx-whisper"
    rtf = summary.get("meanRealTimeFactor")
    wall_time = summary.get("meanWallTimeSeconds")
    generated_notes = "; ".join(
        part
        for part in [
            "warm model first" if warm_model_first else "cold/current cache",
            notes.strip(),
            "resolved model path captured in JSON" if model_path else "",
        ]
        if part
    )
    return (
        f"| {time.strftime('%Y-%m-%d')} "
        f"| {_markdown_cell(machine_label)} "
        f"| {_markdown_cell(label)} "
        f"| {duration_seconds:.1f}s "
        f"| {_markdown_cell(model_label)} "
        f"| {_markdown_cell(runtime_label)} "
        f"| {wall_time}s "
        f"| {rtf} "
        f"| {_markdown_cell(generated_notes)} |"
    )


def _benchmark_transcript_payload(
    transcription: AudioTranscriptionResult,
    *,
    include_text: bool,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "textIncluded": include_text,
        "textCharacterCount": len(transcription.text),
        "lowConfidenceSegmentCount": len(transcription.low_confidence_segments),
        "segmentCount": len(transcription.segments),
        "language": transcription.language,
    }
    if include_text:
        payload["text"] = transcription.text
    return payload


def command_benchmark(args: argparse.Namespace) -> int:
    if args.runs < 1:
        return _error("Benchmark runs must be at least 1.", code="invalid_arguments", exit_code=2)

    audio_path = Path(args.audio_path).expanduser()
    if not audio_path.exists():
        return _error("Audio file does not exist.", details=str(audio_path), code="audio_file_missing")
    if audio_path.is_dir():
        return _error("Audio input must be a file.", details=str(audio_path), code="audio_input_not_file")

    duration_seconds = media_duration_seconds(audio_path)
    if duration_seconds is None or duration_seconds <= 0:
        return _error(
            "Audio duration could not be measured.",
            details="Use a valid WAV/audio file or install ffprobe/ffmpeg so OpenBridge can calculate real-time factor.",
            code="audio_duration_unavailable",
        )

    try:
        model_resolve_started = time.perf_counter()
        model_path, model_label = resolve_engine_model(args.model)
        model_runtime = model_runtime_for(args.model)
        model_resolve_wall_time = time.perf_counter() - model_resolve_started

        model_warm_wall_time: float | None = None
        if args.warm_model_first:
            warm_started = time.perf_counter()
            with contextlib.redirect_stdout(sys.stderr):
                warm_model_cache_for_runtime(model_path, model_runtime)
            model_warm_wall_time = time.perf_counter() - warm_started

        runs: list[dict[str, object]] = []
        latest_transcription: AudioTranscriptionResult | None = None
        for run_number in range(1, args.runs + 1):
            run_started = time.perf_counter()
            with contextlib.redirect_stdout(sys.stderr):
                if model_runtime == SPEECH_RUNTIME_MLX_WHISPER:
                    transcription = transcribe_audio_detailed(
                        audio_path,
                        model_path,
                        args.low_confidence_threshold,
                        language=args.language,
                        condition_on_previous_text=args.condition_on_previous_text,
                    )
                else:
                    transcription = transcribe_audio_detailed_for_runtime(
                        audio_path,
                        model_path,
                        args.low_confidence_threshold,
                        runtime=model_runtime,
                        language=args.language,
                        condition_on_previous_text=args.condition_on_previous_text,
                    )
            wall_time = time.perf_counter() - run_started
            latest_transcription = transcription
            runs.append(
                {
                    "run": run_number,
                    "wallTimeSeconds": _rounded(wall_time),
                    "realTimeFactor": _rounded(wall_time / duration_seconds),
                    "transcript": _benchmark_transcript_payload(
                        transcription,
                        include_text=args.include_transcript_text,
                    ),
                }
            )

        wall_times = [float(run["wallTimeSeconds"]) for run in runs if isinstance(run["wallTimeSeconds"], float)]
        real_time_factors = [
            float(run["realTimeFactor"])
            for run in runs
            if isinstance(run["realTimeFactor"], float)
        ]
        summary: dict[str, object] = {
            "runs": len(runs),
            "meanWallTimeSeconds": _rounded(_mean(wall_times)),
            "bestWallTimeSeconds": _rounded(min(wall_times)) if wall_times else None,
            "meanRealTimeFactor": _rounded(_mean(real_time_factors)),
            "bestRealTimeFactor": _rounded(min(real_time_factors)) if real_time_factors else None,
        }
        label = args.label or audio_path.name
        machine = _machine_context()
        runtime = _runtime_context(model_runtime)
        benchmark: dict[str, object] = {
            "input": {
                "path": str(audio_path),
                "label": label,
                "durationSeconds": _rounded(duration_seconds),
            },
            "model": {
                "requested": args.model,
                "label": model_label,
                "path": model_path,
                "runtime": model_runtime,
                "resolveWallTimeSeconds": _rounded(model_resolve_wall_time),
                "warmModelFirst": args.warm_model_first,
                "warmWallTimeSeconds": _rounded(model_warm_wall_time),
            },
            "settings": {
                "language": args.language,
                "lowConfidenceThreshold": args.low_confidence_threshold,
                "conditionOnPreviousText": args.condition_on_previous_text,
                "includeTranscriptText": args.include_transcript_text,
            },
            "runtime": runtime,
            "machine": machine,
            "runs": runs,
            "summary": summary,
            "markdownTableRow": _benchmark_markdown_row(
                label=label,
                duration_seconds=duration_seconds,
                model_label=model_label,
                model_path=model_path,
                machine=machine,
                runtime=runtime,
                summary=summary,
                notes=args.notes,
                warm_model_first=args.warm_model_first,
            ),
        }
        if latest_transcription is not None:
            benchmark["latestTranscript"] = _benchmark_transcript_payload(
                latest_transcription,
                include_text=args.include_transcript_text,
            )

        return _ok(benchmark=benchmark)
    except Exception as exc:
        details = str(exc)
        if "No local Whisper model was found" in details:
            return _error(
                "Benchmark model is not installed.",
                details=details,
                code="benchmark_model_missing",
            )
        if "No local Parakeet" in details:
            return _error(
                "Benchmark model is not installed.",
                details=details,
                code="benchmark_model_missing",
            )
        if "mlx-whisper could not load" in details or "Parakeet Transformers runtime could not load" in details:
            return _error(
                "Benchmark runtime is not available.",
                details=details,
                code="benchmark_runtime_missing",
            )
        return _error("Benchmark failed.", details=details, code="benchmark_failed")


def command_transcribe_audio(args: argparse.Namespace) -> int:
    audio_path = Path(args.audio_path).expanduser()
    if not audio_path.exists():
        return _error("Audio file does not exist.", details=str(audio_path), code="audio_file_missing")

    try:
        with contextlib.redirect_stdout(sys.stderr):
            transcription, model = _transcribe_detailed_with_optional_fallback(
                audio_path,
                args.model,
                args.low_confidence_threshold,
                language=args.language,
                condition_on_previous_text=not getattr(args, "detailed_timestamps", False),
            )
        transcript = transcription.text
        low_confidence = transcription.low_confidence_segments
        vocab_path = Path(args.vocab_path).expanduser()
        custom_vocab_path = _optional_path(args.custom_vocab_path)
        transcript = post_process_transcript(
            transcript,
            low_confidence,
            vocab_path=vocab_path,
            custom_vocab_path=custom_vocab_path,
            vocab_enabled=args.vocab_enabled,
            formatting_enabled=args.formatting_enabled,
            ollama_enabled=args.ollama_enabled,
            ollama_model=args.ollama_model,
            ollama_cleanup_mode=args.ollama_cleanup_mode,
            llm_provider=args.llm_provider,
        )

        return _ok(
            transcript={
                "text": transcript,
                "lowConfidenceSegments": low_confidence,
                "spans": _timestamped_span_payload(transcription) if transcript == transcription.text else [],
                **_transcript_model_payload(model),
            }
        )
    except Exception as exc:
        return _error("Audio transcription failed.", details=str(exc), code="audio_transcription_failed")


def _timestamped_span_payload(transcription: AudioTranscriptionResult) -> list[dict[str, object]]:
    """Return only stable, JSON-safe timing fields from model-specific segments."""
    spans: list[dict[str, object]] = []
    for segment in transcription.segments:
        if not isinstance(segment, dict):
            continue
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        span: dict[str, object] = {"text": text}
        start = _segment_float(segment, "start")
        end = _segment_float(segment, "end")
        if start is not None:
            span["startOffset"] = max(0.0, start)
        if end is not None:
            span["endOffset"] = max(0.0, end)
        spans.append(span)
    return spans


def _segment_float(segment: dict[str, object], key: str) -> float | None:
    value = segment.get(key)
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _log_media_diagnostics(
    *,
    source_label: str,
    source_duration: float | None,
    normalized_duration: float | None,
    transcription: AudioTranscriptionResult,
) -> dict[str, object]:
    chunk_count = media_chunk_count(normalized_duration)
    print(
        "OpenBridge media input: "
        f"source={source_label}, "
        f"sourceDuration={source_duration if source_duration is not None else 'unknown'}s, "
        f"normalizedDuration={normalized_duration if normalized_duration is not None else 'unknown'}s, "
        f"chunks={chunk_count if chunk_count is not None else 'unknown'}",
        file=sys.stderr,
    )

    segments = [segment for segment in transcription.segments if isinstance(segment, dict)]
    if chunk_count is not None and normalized_duration is not None:
        for index in range(chunk_count):
            start = index * 30.0
            end = min(normalized_duration, start + 30.0)
            chunk_segments = [
                segment
                for segment in segments
                if (_segment_float(segment, "end") or 0) > start
                and (_segment_float(segment, "start") or 0) < end
            ]
            chunk_chars = sum(len(str(segment.get("text", ""))) for segment in chunk_segments)
            print(
                "OpenBridge media chunk "
                f"{index + 1}/{chunk_count}: {start:.1f}-{end:.1f}s, "
                f"segments={len(chunk_segments)}, chars={chunk_chars}",
                file=sys.stderr,
            )
    else:
        print(
            f"OpenBridge media chunks: duration unknown, segments={len(segments)}",
            file=sys.stderr,
        )

    covered_until = max((_segment_float(segment, "end") or 0.0 for segment in segments), default=0.0)
    print(
        "OpenBridge media transcript: "
        f"segments={len(segments)}, coveredUntil={covered_until:.1f}s, "
        f"chars={len(transcription.text)}",
        file=sys.stderr,
    )

    return {
        "sourceDurationSeconds": source_duration,
        "audioDurationSeconds": normalized_duration,
        "chunkCount": chunk_count,
        "transcribedSegmentCount": len(segments),
        "transcribedThroughSeconds": covered_until,
    }


def _transcribe_media_audio(
    audio_path: Path,
    *,
    source_label: str,
    source_duration: float | None,
    model_id_or_path: str | None,
    low_confidence_threshold: float,
    language: str,
) -> tuple[AudioTranscriptionResult, dict[str, object], dict[str, object]]:
    normalized_duration = media_duration_seconds(audio_path)
    transcription, model = _transcribe_detailed_with_optional_fallback(
        audio_path,
        model_id_or_path,
        low_confidence_threshold,
        language=language,
        condition_on_previous_text=False,
    )
    raise_if_repetition_loop(transcription.text)
    diagnostics = _log_media_diagnostics(
        source_label=source_label,
        source_duration=source_duration,
        normalized_duration=normalized_duration,
        transcription=transcription,
    )
    return transcription, diagnostics, model


def command_transcribe_media(args: argparse.Namespace) -> int:
    media_path = Path(args.media_path).expanduser()
    if not media_path.exists():
        return _error("Media file does not exist.", details=str(media_path), code="media_file_missing")
    if media_path.is_dir():
        return _error("Media input must be a file.", details=str(media_path), code="media_input_not_file")

    try:
        with tempfile.TemporaryDirectory(prefix="openbridge_media_") as td:
            temp_dir = Path(td)
            source_duration = media_duration_seconds(media_path)
            audio_path = extract_local_media_audio(media_path, temp_dir, noisy=args.noisy_mic)
            with contextlib.redirect_stdout(sys.stderr):
                transcription, diagnostics, model = _transcribe_media_audio(
                    audio_path,
                    source_label=media_path.name,
                    source_duration=source_duration,
                    model_id_or_path=args.model,
                    low_confidence_threshold=args.low_confidence_threshold,
                    language=args.language,
                )
        vocab_path = Path(args.vocab_path).expanduser()
        custom_vocab_path = _optional_path(args.custom_vocab_path)
        transcript = post_process_transcript(
            transcription.text,
            transcription.low_confidence_segments,
            vocab_path=vocab_path,
            custom_vocab_path=custom_vocab_path,
            vocab_enabled=args.vocab_enabled,
            formatting_enabled=args.formatting_enabled,
            ollama_enabled=args.ollama_enabled,
            ollama_model=args.ollama_model,
            ollama_cleanup_mode=args.ollama_cleanup_mode,
            llm_provider=args.llm_provider,
        )

        return _ok(
            transcript={
                "text": transcript,
                "originalText": transcription.text,
                "lowConfidenceSegments": transcription.low_confidence_segments,
                **_transcript_model_payload(model),
            },
            media={
                "sourcePath": str(media_path),
                "sourceName": media_path.name,
                **diagnostics,
            },
        )
    except Exception as exc:
        return _error("Media transcription failed.", details=str(exc), code="media_transcription_failed")


def command_transcribe_url(args: argparse.Namespace) -> int:
    url = args.url.strip()
    if not url:
        return _error("YouTube URL is required.", code="youtube_url_missing")

    try:
        with tempfile.TemporaryDirectory(prefix="openbridge_youtube_") as td:
            temp_dir = Path(td)
            audio_path, title = extract_youtube_audio(
                url,
                temp_dir,
                cookies_from_browser=args.cookies_from_browser,
            )
            source_duration = media_duration_seconds(audio_path)
            normalized_audio_path = extract_local_media_audio(audio_path, temp_dir, noisy=args.noisy_mic)
            with contextlib.redirect_stdout(sys.stderr):
                transcription, diagnostics, model = _transcribe_media_audio(
                    normalized_audio_path,
                    source_label=title or "YouTube transcript",
                    source_duration=source_duration,
                    model_id_or_path=args.model,
                    low_confidence_threshold=args.low_confidence_threshold,
                    language=args.language,
                )
        vocab_path = Path(args.vocab_path).expanduser()
        custom_vocab_path = _optional_path(args.custom_vocab_path)
        transcript = post_process_transcript(
            transcription.text,
            transcription.low_confidence_segments,
            vocab_path=vocab_path,
            custom_vocab_path=custom_vocab_path,
            vocab_enabled=args.vocab_enabled,
            formatting_enabled=args.formatting_enabled,
            ollama_enabled=args.ollama_enabled,
            ollama_model=args.ollama_model,
            ollama_cleanup_mode=args.ollama_cleanup_mode,
            llm_provider=args.llm_provider,
        )

        return _ok(
            transcript={
                "text": transcript,
                "originalText": transcription.text,
                "lowConfidenceSegments": transcription.low_confidence_segments,
                **_transcript_model_payload(model),
            },
            media={
                "sourcePath": url,
                "sourceName": title or "YouTube transcript",
                **diagnostics,
            },
        )
    except YouTubeExtractionError as exc:
        return _error("YouTube transcription failed.", details=str(exc), code="youtube_transcription_failed")
    except Exception as exc:
        return _error("YouTube transcription failed.", details=str(exc), code="youtube_transcription_failed")


def command_command_mode(args: argparse.Namespace) -> int:
    try:
        if args.command_mode_command == "transform":
            result = transform_text_with_local_llm(
                args.selected_text,
                args.instruction,
                args.app_context,
                model=args.model,
                provider=args.provider,
                max_input_chars=args.max_input_chars,
                timeout_seconds=args.timeout_seconds,
            )
            return _ok(
                transformedText=result.text,
                commandMode={
                    "provider": result.provider,
                    "model": result.model,
                    "inputCharacters": result.input_characters,
                },
            )
    except CommandModeError as exc:
        return _error(
            exc.message,
            details=exc.details,
            code=exc.code,
            exit_code=exc.exit_code,
        )
    return _error("Unknown Command Mode command.", code="unknown_command_mode_command")


def command_meeting_cleanup(_args: argparse.Namespace) -> int:
    """Read private transcript JSON from stdin, never from process arguments."""

    maximum_request_bytes = 5 * 1024 * 1024
    raw_request = sys.stdin.buffer.read(maximum_request_bytes + 1)
    if len(raw_request) > maximum_request_bytes:
        raise EngineCLIError(
            "Meeting cleanup request is too large.",
            code="meeting_cleanup_request_too_large",
        )
    try:
        request = json.loads(raw_request)
        cleanup = cleanup_meeting_segments(request)
    except (CleanupBenchmarkError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EngineCLIError(
            "Meeting cleanup request failed.",
            details=str(exc),
            code="meeting_cleanup_failed",
        ) from exc
    return _ok(cleanup=cleanup)


def build_parser() -> argparse.ArgumentParser:
    parser = EngineArgumentParser(description="Internal JSON CLI for the OpenBridge macOS app.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="Inspect runtime and installed models.")
    doctor.set_defaults(handler=command_doctor)

    models = subparsers.add_parser("models", help="Manage curated Whisper models.")
    models_subparsers = models.add_subparsers(dest="models_command", required=True)

    models_list = models_subparsers.add_parser("list", help="List curated and installed models.")
    models_list.set_defaults(handler=command_models)

    models_install = models_subparsers.add_parser("install", help="Install a curated model.")
    models_install.add_argument("--model", choices=tuple(CURATED_MODELS), default=DEFAULT_MODEL_ID)
    models_install.add_argument("--force", action="store_true")
    models_install.set_defaults(handler=command_models)

    models_remove = models_subparsers.add_parser("remove", help="Remove a curated model.")
    models_remove.add_argument("--model", choices=tuple(CURATED_MODELS), required=True)
    models_remove.set_defaults(handler=command_models)

    parakeet_plan = subparsers.add_parser(
        "parakeet-plan",
        help="Print the Parakeet V2 default evidence and local validation gate.",
    )
    parakeet_plan.set_defaults(handler=command_parakeet_plan)

    warm_model = subparsers.add_parser("warm-model", help="Load a model into the mlx-whisper cache.")
    warm_model.add_argument("--model", default=DEFAULT_MODEL_ID)
    warm_model.set_defaults(handler=command_warm_model)

    readiness = subparsers.add_parser("readiness", help="Report first-dictation model readiness.")
    readiness.add_argument("--model", default=DEFAULT_MODEL_ID)
    readiness.add_argument("--cleanup-mode", choices=["off", "fast", "careful"], default="fast")
    readiness.add_argument("--load-check", action="store_true")
    readiness.add_argument("--inference-check", action="store_true")
    readiness.set_defaults(handler=command_readiness)

    meeting_cleanup = subparsers.add_parser(
        "meeting-cleanup",
        help="Clean a finalized meeting transcript with the exact local Gemma snapshot.",
    )
    meeting_cleanup.set_defaults(handler=command_meeting_cleanup)

    benchmark = subparsers.add_parser(
        "benchmark",
        help="Benchmark a local transcription model on an audio file.",
    )
    benchmark.add_argument("--audio-path", required=True)
    benchmark.add_argument("--model", default=DEFAULT_MODEL_ID)
    benchmark.add_argument("--runs", type=int, default=1)
    benchmark.add_argument("--warm-model-first", action="store_true")
    benchmark.add_argument("--low-confidence-threshold", type=float, default=-0.85)
    benchmark.add_argument("--language", default=DEFAULT_TRANSCRIPTION_LANGUAGE)
    benchmark.add_argument("--label", default=None)
    benchmark.add_argument("--notes", default="")
    benchmark.add_argument("--include-transcript-text", action="store_true")
    benchmark.add_argument(
        "--no-condition-on-previous-text",
        action="store_false",
        dest="condition_on_previous_text",
        default=True,
    )
    benchmark.set_defaults(handler=command_benchmark)

    transcribe = subparsers.add_parser("transcribe-audio", help="Transcribe a mono WAV file.")
    transcribe.add_argument("--audio-path", required=True)
    transcribe.add_argument("--model", default=DEFAULT_MODEL_ID)
    transcribe.add_argument("--low-confidence-threshold", type=float, default=-0.85)
    transcribe.add_argument("--language", default=DEFAULT_TRANSCRIPTION_LANGUAGE)
    transcribe.add_argument("--vocab-path", default=str(DEFAULT_VOCAB_PATH))
    transcribe.add_argument("--custom-vocab-path", default=None)
    transcribe.add_argument("--no-vocab", action="store_false", dest="vocab_enabled", default=True)
    transcribe.add_argument("--formatting-enabled", action="store_true", default=False)
    transcribe.add_argument(
        "--detailed-timestamps",
        action="store_true",
        help="Return timestamped model spans for source-aware meeting transcription.",
    )
    transcribe.add_argument("--llm-enabled", "--ollama-enabled", action="store_true", dest="ollama_enabled", default=False)
    transcribe.add_argument("--llm-provider", choices=["auto", "mlx", "ollama"], default=DEFAULT_LLM_PROVIDER)
    transcribe.add_argument("--ollama-model", default=DEFAULT_CORRECTION_MODEL)
    transcribe.add_argument("--ollama-cleanup-mode", choices=["fast", "careful"], default="fast")
    transcribe.set_defaults(handler=command_transcribe_audio)

    transcribe_media = subparsers.add_parser(
        "transcribe-media",
        help="Transcribe a local audio or video file.",
    )
    transcribe_media.add_argument("--media-path", required=True)
    transcribe_media.add_argument("--model", default=DEFAULT_MODEL_ID)
    transcribe_media.add_argument("--low-confidence-threshold", type=float, default=-0.85)
    transcribe_media.add_argument("--language", default=DEFAULT_TRANSCRIPTION_LANGUAGE)
    transcribe_media.add_argument("--vocab-path", default=str(DEFAULT_VOCAB_PATH))
    transcribe_media.add_argument("--custom-vocab-path", default=None)
    transcribe_media.add_argument("--no-vocab", action="store_false", dest="vocab_enabled", default=True)
    transcribe_media.add_argument("--formatting-enabled", action="store_true", default=False)
    transcribe_media.add_argument("--llm-enabled", "--ollama-enabled", action="store_true", dest="ollama_enabled", default=False)
    transcribe_media.add_argument("--llm-provider", choices=["auto", "mlx", "ollama"], default=DEFAULT_LLM_PROVIDER)
    transcribe_media.add_argument("--ollama-model", default=DEFAULT_CORRECTION_MODEL)
    transcribe_media.add_argument("--ollama-cleanup-mode", choices=["fast", "careful"], default="fast")
    transcribe_media.add_argument(
        "--noisy-mic",
        action="store_true",
        help="Use a stronger preprocessing chain for noisy source audio.",
    )
    transcribe_media.set_defaults(handler=command_transcribe_media)

    transcribe_url = subparsers.add_parser(
        "transcribe-url",
        help="Transcribe audio from a supported web URL.",
    )
    transcribe_url.add_argument("--url", required=True)
    transcribe_url.add_argument("--model", default=DEFAULT_MODEL_ID)
    transcribe_url.add_argument("--low-confidence-threshold", type=float, default=-0.85)
    transcribe_url.add_argument("--language", default=DEFAULT_TRANSCRIPTION_LANGUAGE)
    transcribe_url.add_argument("--vocab-path", default=str(DEFAULT_VOCAB_PATH))
    transcribe_url.add_argument("--custom-vocab-path", default=None)
    transcribe_url.add_argument("--no-vocab", action="store_false", dest="vocab_enabled", default=True)
    transcribe_url.add_argument("--formatting-enabled", action="store_true", default=False)
    transcribe_url.add_argument("--llm-enabled", "--ollama-enabled", action="store_true", dest="ollama_enabled", default=False)
    transcribe_url.add_argument("--llm-provider", choices=["auto", "mlx", "ollama"], default=DEFAULT_LLM_PROVIDER)
    transcribe_url.add_argument("--ollama-model", default=DEFAULT_CORRECTION_MODEL)
    transcribe_url.add_argument("--ollama-cleanup-mode", choices=["fast", "careful"], default="fast")
    transcribe_url.add_argument(
        "--cookies-from-browser",
        default=None,
        help="Advanced: browser name for yt-dlp cookies, e.g. chrome, safari, edge, firefox.",
    )
    transcribe_url.add_argument(
        "--noisy-mic",
        action="store_true",
        help="Use a stronger preprocessing chain for noisy source audio.",
    )
    transcribe_url.set_defaults(handler=command_transcribe_url)

    command_mode = subparsers.add_parser(
        "command-mode",
        help="Transform selected text with a spoken instruction using local AI.",
    )
    command_mode_subparsers = command_mode.add_subparsers(
        dest="command_mode_command",
        required=True,
    )

    command_mode_transform = command_mode_subparsers.add_parser(
        "transform",
        help="Return replacement text for selected text and an instruction.",
    )
    command_mode_transform.add_argument("--selected-text", required=True)
    command_mode_transform.add_argument("--instruction", required=True)
    command_mode_transform.add_argument("--app-context", default="")
    command_mode_transform.add_argument("--provider", choices=["auto", "mlx", "ollama"], default=DEFAULT_LLM_PROVIDER)
    command_mode_transform.add_argument("--model", default=DEFAULT_MLX_LLM_MODEL)
    command_mode_transform.add_argument(
        "--max-input-chars",
        type=int,
        default=DEFAULT_COMMAND_MODE_MAX_INPUT_CHARS,
    )
    command_mode_transform.add_argument(
        "--timeout-seconds",
        type=float,
        default=COMMAND_MODE_TIMEOUT_SECONDS,
    )
    command_mode_transform.set_defaults(handler=command_command_mode)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        return args.handler(args)
    except EngineCLIError as exc:
        return _error(
            exc.message,
            details=exc.details,
            code=exc.code,
            exit_code=exc.exit_code,
        )
    except Exception as exc:
        return _error("Engine command failed.", details=str(exc), code="unhandled_exception")
