from __future__ import annotations

import os
from pathlib import Path
import platform
import shutil
import tempfile
import wave

from .common import (
    transcribe_audio_detailed_for_runtime,
    warm_model_cache_for_runtime,
)
from .config import (
    APP_SUPPORT_ROOT,
    CURATED_MODELS,
    DEFAULT_MODEL_ID,
    DEFAULT_MLX_LLM_CAREFUL_MODEL,
    DEFAULT_MLX_LLM_MODEL,
    DEFAULT_WHISPER_FALLBACK_MODEL_ID,
    MODEL_ROOT,
    SPEECH_RUNTIME_MLX_WHISPER,
    SPEECH_RUNTIME_PARAKEET_MLX,
    SPEECH_RUNTIME_PARAKEET_TRANSFORMERS,
)
from .local_llm import (
    local_llm_status,
    mlx_model_cache_present,
)
from .models import dependency_status, list_installed_models, resolve_engine_model


MIN_FREE_DISK_BYTES = 2 * 1024 * 1024 * 1024
MIN_MEMORY_BYTES = 4 * 1024 * 1024 * 1024


def _check(
    identifier: str,
    title: str,
    state: str,
    message: str,
    *,
    recovery: str | None = None,
    blocking: bool = True,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "id": identifier,
        "title": title,
        "state": state,
        "message": message,
        "blocking": blocking,
    }
    if recovery:
        payload["recovery"] = recovery
    return payload


def _system_memory_bytes() -> int | None:
    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        page_count = os.sysconf("SC_PHYS_PAGES")
    except (AttributeError, OSError, ValueError):
        return None
    if isinstance(page_size, int) and isinstance(page_count, int):
        return page_size * page_count
    return None


def _free_disk_bytes() -> int | None:
    base = MODEL_ROOT if MODEL_ROOT.exists() else APP_SUPPORT_ROOT
    try:
        base.mkdir(parents=True, exist_ok=True)
        return shutil.disk_usage(base).free
    except OSError:
        return None


def _installed_model(model_identifier: str) -> dict[str, object] | None:
    for model in list_installed_models():
        if model.get("identifier") == model_identifier and model.get("installed"):
            return model
    return None


def _write_silent_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b"\0\0" * 4000)


def _cleanup_model_for_mode(cleanup_mode: str) -> str | None:
    if cleanup_mode == "fast":
        return DEFAULT_MLX_LLM_MODEL
    if cleanup_mode == "careful":
        return DEFAULT_MLX_LLM_CAREFUL_MODEL
    return None


def check_readiness(
    *,
    model_identifier: str,
    cleanup_mode: str,
    run_load_check: bool = False,
    run_inference_check: bool = False,
) -> dict[str, object]:
    checks: list[dict[str, object]] = []
    dependencies = dependency_status()
    local_ai = local_llm_status()
    system_name = platform.system()
    machine = platform.machine().lower()
    is_apple_silicon_mac = system_name == "Darwin" and machine in {"arm64", "aarch64"}
    known_model = CURATED_MODELS.get(model_identifier)
    model_runtime = known_model.runtime if known_model is not None else SPEECH_RUNTIME_MLX_WHISPER
    is_parakeet_runtime = model_runtime in {
        SPEECH_RUNTIME_PARAKEET_TRANSFORMERS,
        SPEECH_RUNTIME_PARAKEET_MLX,
    }
    if model_runtime == SPEECH_RUNTIME_MLX_WHISPER:
        runtime_supported = dependencies.get("mlx_whisper")
    elif model_runtime == SPEECH_RUNTIME_PARAKEET_TRANSFORMERS:
        runtime_supported = dependencies.get("parakeet_transformers")
    elif model_runtime == SPEECH_RUNTIME_PARAKEET_MLX:
        runtime_supported = dependencies.get("parakeet_mlx")
    else:
        runtime_supported = False
    fallback_model = CURATED_MODELS.get(DEFAULT_WHISPER_FALLBACK_MODEL_ID)
    fallback_installed_model = _installed_model(DEFAULT_WHISPER_FALLBACK_MODEL_ID)
    fallback_ready = bool(
        fallback_model is not None
        and fallback_installed_model is not None
        and dependencies.get("mlx_whisper")
    )

    if is_apple_silicon_mac:
        checks.append(
            _check(
                "machine_compatibility",
                "Mac compatibility",
                "pass",
                "This Mac can run the local MLX transcription path.",
            )
        )
    else:
        checks.append(
            _check(
                "machine_compatibility",
                "Mac compatibility",
                "fail",
                "This build expects Apple silicon macOS for local transcription.",
                recovery="Use an Apple silicon Mac running macOS 14 or later.",
            )
        )

    if model_runtime == SPEECH_RUNTIME_MLX_WHISPER and dependencies.get("mlx_whisper"):
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "pass",
                "mlx-whisper is available in the Python runtime.",
            )
        )
    elif model_runtime == SPEECH_RUNTIME_MLX_WHISPER:
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "fail",
                "mlx-whisper is missing from the Python runtime.",
                recovery="Install the bundled/runtime Python dependencies before dictating.",
            )
        )
    elif model_runtime == SPEECH_RUNTIME_PARAKEET_TRANSFORMERS and runtime_supported:
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "pass",
                "A Parakeet-capable Transformers runtime is available for local validation.",
            )
        )
    elif model_runtime == SPEECH_RUNTIME_PARAKEET_TRANSFORMERS:
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "warn" if fallback_ready else "fail",
                "Parakeet is the approved V2 default, but it needs torch and a Transformers build with TDT support before it can run locally.",
                recovery="Install the Parakeet validation dependencies from the current source/new-enough Transformers path or use the Whisper Base fallback.",
                blocking=not fallback_ready,
            )
        )
    elif model_runtime == SPEECH_RUNTIME_PARAKEET_MLX and runtime_supported:
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "pass",
                "A Parakeet MLX runtime is available for Apple silicon validation.",
            )
        )
    elif model_runtime == SPEECH_RUNTIME_PARAKEET_MLX:
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "warn" if fallback_ready else "fail",
                "Parakeet MLX is the approved V2 default, but it needs parakeet-mlx and MLX before it can run locally.",
                recovery="Install the Parakeet MLX validation dependencies or use the Whisper Base fallback.",
                blocking=not fallback_ready,
            )
        )
    else:
        checks.append(
            _check(
                "speech_runtime",
                "Speech runtime",
                "fail",
                f"The selected model uses an unsupported runtime: {model_runtime}.",
                recovery="Choose a Whisper model while this runtime is added to OpenBridge.",
            )
        )

    installed_model = _installed_model(model_identifier)
    direct_model_path = Path(model_identifier).expanduser()
    direct_model_exists = direct_model_path.exists()
    model_installed = installed_model is not None or direct_model_exists
    model_display_name = (
        known_model.display_name
        if known_model is not None
        else (model_identifier if model_identifier else "Unknown model")
    )
    model_path = str(installed_model.get("path")) if installed_model and installed_model.get("path") else None
    if direct_model_exists:
        model_path = str(direct_model_path)

    if known_model is None and not direct_model_exists:
        checks.append(
            _check(
                "selected_model_known",
                "Selected speech model",
                "fail",
                f"{model_identifier} is not a curated model or local model path.",
                recovery="Choose Whisper Base, Whisper Tiny, Whisper Large v3, or a valid local model path.",
            )
        )
    elif model_installed:
        checks.append(
            _check(
                "selected_model_installed",
                "Selected speech model",
                "pass",
                f"{model_display_name} is installed locally.",
            )
        )
    else:
        checks.append(
            _check(
                "selected_model_installed",
                "Selected speech model",
                "warn" if is_parakeet_runtime and fallback_ready else "fail",
                f"{model_display_name} is not installed locally.",
                recovery=f"Install {model_display_name} before the first dictation.",
                blocking=not (is_parakeet_runtime and fallback_ready),
            )
        )

    model_path_for_runtime: str | None = None
    if model_installed and runtime_supported:
        try:
            model_path_for_runtime, _ = resolve_engine_model(model_identifier)
        except Exception as exc:
            checks.append(
                _check(
                    "selected_model_resolves",
                    "Speech model path",
                    "fail",
                    "The selected model could not be resolved for the engine.",
                    recovery=str(exc),
                )
            )
    elif not model_installed:
        checks.append(
            _check(
                "selected_model_load",
                "Speech model load",
                "notRun",
                "Load check was skipped because the selected speech model is missing.",
            )
        )
    elif model_runtime != SPEECH_RUNTIME_MLX_WHISPER:
        checks.append(
            _check(
                "selected_model_load",
                "Speech model load",
                "notRun",
                "Load check was skipped because the selected model runtime is not available in this Python environment.",
                blocking=False,
            )
        )

    fallback_load_checked = False
    fallback_load_ok: bool | None = None
    fallback_load_error: str | None = None
    if is_parakeet_runtime and fallback_ready and (run_load_check or run_inference_check):
        fallback_load_checked = True
        try:
            fallback_path, _ = resolve_engine_model(DEFAULT_WHISPER_FALLBACK_MODEL_ID)
            warm_model_cache_for_runtime(fallback_path, SPEECH_RUNTIME_MLX_WHISPER)
            fallback_load_ok = True
        except Exception as exc:
            fallback_load_ok = False
            fallback_ready = False
            fallback_load_error = str(exc)

    if is_parakeet_runtime:
        if fallback_ready:
            fallback_message = (
                "Whisper Base fallback loaded successfully and can take over if Parakeet cannot run."
                if fallback_load_checked
                else "Whisper Base fallback is installed and available if Parakeet cannot run."
            )
            checks.append(
                _check(
                    "fallback_model_available",
                    "Whisper fallback",
                    "pass",
                    fallback_message,
                    blocking=False,
                )
            )
        else:
            checks.append(
                _check(
                    "fallback_model_available",
                    "Whisper fallback",
                    "fail",
                    (
                        "Whisper Base fallback could not load."
                        if fallback_load_checked
                        else "Whisper Base fallback is not ready."
                    ),
                    recovery=(
                        fallback_load_error
                        or "Install Whisper Base so OpenBridge can fall back without losing the transcription workflow."
                    ),
                    blocking=not (model_installed and runtime_supported),
                )
            )

    load_ok: bool | None = None
    if model_path_for_runtime is not None:
        if run_load_check or run_inference_check:
            try:
                warm_model_cache_for_runtime(model_path_for_runtime, model_runtime)
                load_ok = True
                checks.append(
                    _check(
                        "selected_model_load",
                        "Speech model load",
                        "pass",
                        f"{model_display_name} loaded successfully.",
                    )
                )
            except Exception as exc:
                load_ok = False
                checks.append(
                    _check(
                        "selected_model_load",
                        "Speech model load",
                        "warn" if is_parakeet_runtime and fallback_ready else "fail",
                        f"{model_display_name} could not load.",
                        recovery=str(exc),
                        blocking=not (is_parakeet_runtime and fallback_ready),
                    )
                )
        else:
            checks.append(
                _check(
                    "selected_model_load",
                    "Speech model load",
                    "notRun",
                    "Load check has not run yet.",
                    recovery="Use Check model to load the selected speech model before dictating.",
                    blocking=False,
                )
            )

    inference_ok: bool | None = None
    if run_inference_check and model_path_for_runtime is not None and load_ok is not False:
        try:
            with tempfile.TemporaryDirectory() as td:
                audio_path = Path(td) / "readiness.wav"
                _write_silent_wav(audio_path)
                transcribe_audio_detailed_for_runtime(
                    audio_path,
                    model_path_for_runtime,
                    -0.85,
                    runtime=model_runtime,
                )
            inference_ok = True
            checks.append(
                _check(
                    "selected_model_test_inference",
                    "Speech test inference",
                    "pass",
                    f"{model_display_name} completed a tiny local transcription test.",
                )
            )
        except Exception as exc:
            inference_ok = False
            checks.append(
                _check(
                    "selected_model_test_inference",
                    "Speech test inference",
                    "warn" if is_parakeet_runtime and fallback_ready else "fail",
                    "The selected model loaded but could not complete a tiny transcription test.",
                    recovery=str(exc),
                    blocking=not (is_parakeet_runtime and fallback_ready),
                )
            )
    elif model_installed:
        checks.append(
            _check(
                "selected_model_test_inference",
                "Speech test inference",
                "notRun",
                "Tiny transcription test has not run yet.",
                recovery="Use a full model check before release QA if dictation still fails after install.",
                blocking=False,
            )
        )

    cleanup_model = _cleanup_model_for_mode(cleanup_mode)
    cleanup_available = False
    cleanup_model_present = False
    if cleanup_model is None:
        checks.append(
            _check(
                "cleanup_model",
                "Local cleanup",
                "notRun",
                "Local cleanup is off.",
                blocking=False,
            )
        )
    else:
        cleanup_model_present = mlx_model_cache_present(cleanup_model)
        if local_ai.get("mlxAvailable") and cleanup_model_present:
            cleanup_available = True
            checks.append(
                _check(
                    "cleanup_model",
                    "Local cleanup model",
                    "pass",
                    "Fast local cleanup is available on this Mac.",
                    blocking=False,
                )
            )
        elif local_ai.get("mlxAvailable"):
            checks.append(
                _check(
                    "cleanup_model",
                    "Local cleanup model",
                    "warn",
                    "Fast local cleanup is selected, but the MLX text model is not cached yet.",
                    recovery="OpenBridge can download the local cleanup model on first use. Dictation still keeps the original transcript if cleanup is unavailable.",
                    blocking=False,
                )
            )
        elif local_ai.get("ollamaAvailable"):
            cleanup_available = True
            checks.append(
                _check(
                    "cleanup_model",
                    "Local cleanup model",
                    "pass",
                    "Ollama fallback is available for local cleanup.",
                    blocking=False,
                )
            )
        else:
            checks.append(
                _check(
                    "cleanup_model",
                    "Local cleanup model",
                    "warn",
                    "No local cleanup provider is available right now.",
                    recovery="Install mlx-lm in the Python runtime or switch cleanup Off. Dictation will still return the original transcript.",
                    blocking=False,
                )
            )

    free_disk_bytes = _free_disk_bytes()
    if free_disk_bytes is None:
        checks.append(
            _check(
                "disk_space",
                "Disk space",
                "warn",
                "OpenBridge could not inspect free disk space.",
                blocking=False,
            )
        )
    elif free_disk_bytes >= MIN_FREE_DISK_BYTES:
        checks.append(
            _check(
                "disk_space",
                "Disk space",
                "pass",
                "There is enough free disk space for local models.",
            )
        )
    else:
        checks.append(
            _check(
                "disk_space",
                "Disk space",
                "fail",
                "Free disk space is low for local model setup.",
                recovery="Free at least 2 GB before installing or warming speech models.",
            )
        )

    total_memory_bytes = _system_memory_bytes()
    if total_memory_bytes is None:
        checks.append(
            _check(
                "system_memory",
                "Memory",
                "warn",
                "OpenBridge could not inspect system memory.",
                blocking=False,
            )
        )
    elif total_memory_bytes >= MIN_MEMORY_BYTES:
        checks.append(
            _check(
                "system_memory",
                "Memory",
                "pass",
                "System memory is within the expected range for local transcription.",
            )
        )
    else:
        checks.append(
            _check(
                "system_memory",
                "Memory",
                "warn",
                "System memory is low for local transcription.",
                recovery="Use Whisper Tiny or close other apps if transcription fails.",
                blocking=False,
            )
        )

    blocking_failures = [
        check for check in checks
        if check["state"] == "fail" and check.get("blocking", True)
    ]
    ready = not blocking_failures
    if ready and is_parakeet_runtime and (
        not model_installed
        or not runtime_supported
        or load_ok is False
        or inference_ok is False
    ):
        summary = f"{model_display_name} is not ready yet; Whisper Base fallback is ready."
    else:
        summary = (
            f"{model_display_name} is ready for first dictation."
            if ready
            else str(blocking_failures[0]["message"])
        )

    return {
        "ready": ready,
        "summary": summary,
        "checks": checks,
        "speechModel": {
            "identifier": model_identifier,
            "displayName": model_display_name,
            "runtime": model_runtime,
            "runtimeSupported": bool(runtime_supported),
            "fallbackIdentifier": DEFAULT_WHISPER_FALLBACK_MODEL_ID if is_parakeet_runtime else None,
            "fallbackReady": fallback_ready if is_parakeet_runtime else None,
            "installed": model_installed,
            "path": model_path,
            "loadChecked": run_load_check or run_inference_check,
            "loadOK": load_ok,
            "inferenceChecked": run_inference_check,
            "inferenceOK": inference_ok,
        },
        "cleanup": {
            "mode": cleanup_mode,
            "enabled": cleanup_model is not None,
            "model": cleanup_model,
            "available": cleanup_available,
            "modelPresent": cleanup_model_present,
            "provider": local_ai.get("defaultProvider"),
        },
        "resources": {
            "freeDiskBytes": free_disk_bytes,
            "requiredDiskBytes": MIN_FREE_DISK_BYTES,
            "totalMemoryBytes": total_memory_bytes,
            "recommendedMemoryBytes": MIN_MEMORY_BYTES,
        },
    }
