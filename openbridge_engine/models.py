from __future__ import annotations

from dataclasses import asdict
import importlib
import importlib.util
import os
from pathlib import Path
import shutil

from .common import find_local_hf_snapshot, resolve_local_model
from . import model_integrity
from .config import (
    CURATED_MODELS,
    CuratedModel,
    DEFAULT_PARAKEET_CANDIDATE_MODEL_ID,
    DEFAULT_MODEL_ID,
    DEFAULT_WHISPER_FALLBACK_MODEL_ID,
    MODEL_ROOT,
    HF_CACHE_ROOT,
    PARAKEET_VALIDATION_CANDIDATES,
    SPEECH_RUNTIME_MLX_WHISPER,
    SPEECH_RUNTIME_PARAKEET_MLX,
    SPEECH_RUNTIME_PARAKEET_TRANSFORMERS,
    ensure_app_support_dirs,
)


def model_dir_is_complete(path: Path) -> bool:
    return path.is_dir() and (path / "config.json").is_file()


def _repo_basename(repo_id: str) -> str:
    return repo_id.split("/")[-1]


def _repo_basename_fallback_allowed(model_id: str, identifier: str) -> bool:
    repo_basename = _repo_basename(model_id)
    return repo_basename == identifier or repo_basename not in CURATED_MODELS


def _installed_curated_model_path(model: CuratedModel) -> Path | None:
    key = model_integrity.model_key(model.identifier) or model_integrity.model_key(model.repo_id)
    if key is not None:
        preferred = model_integrity.installed_path(key, MODEL_ROOT)
        if model_dir_is_complete(preferred):
            return preferred
    model_dir = MODEL_ROOT / model.identifier
    if model_dir_is_complete(model_dir):
        return model_dir

    if _repo_basename_fallback_allowed(model.repo_id, model.identifier):
        repo_dir = MODEL_ROOT / _repo_basename(model.repo_id)
        if model_dir_is_complete(repo_dir):
            return repo_dir

    return None


def curated_model_metadata() -> list[dict[str, object]]:
    return [model.to_dict() for model in CURATED_MODELS.values()]


def parakeet_validation_candidates() -> list[dict[str, object]]:
    dependencies = dependency_status()
    installed_models = {
        str(model.get("identifier")): model
        for model in list_installed_models()
        if model.get("identifier") is not None
    }
    candidates: list[dict[str, object]] = []
    for candidate in PARAKEET_VALIDATION_CANDIDATES.values():
        installed_model = installed_models.get(candidate.identifier)
        curated_model = CURATED_MODELS.get(candidate.identifier)
        runtime = curated_model.runtime if curated_model is not None else None
        if runtime == SPEECH_RUNTIME_PARAKEET_TRANSFORMERS:
            runtime_supported = bool(dependencies.get("parakeet_transformers"))
        elif runtime == SPEECH_RUNTIME_PARAKEET_MLX:
            runtime_supported = bool(dependencies.get("parakeet_mlx"))
        else:
            runtime_supported = None
        candidates.append(
            {
                **candidate.to_dict(),
                "curatedModel": curated_model is not None,
                "installed": bool(installed_model and installed_model.get("installed")),
                "path": installed_model.get("path") if installed_model else None,
                "runtime": runtime,
                "runtimeSupported": runtime_supported,
                "autoManage": curated_model.auto_manage if curated_model is not None else None,
                "userSelectableWhenReady": candidate.identifier == DEFAULT_PARAKEET_CANDIDATE_MODEL_ID,
            }
        )
    return candidates


def parakeet_validation_plan() -> dict[str, object]:
    dependencies = dependency_status()
    candidates = parakeet_validation_candidates()
    primary = next(
        candidate
        for candidate in candidates
        if candidate["identifier"] == DEFAULT_PARAKEET_CANDIDATE_MODEL_ID
    )
    primary_ready = bool(primary.get("installed") and primary.get("runtimeSupported"))
    return {
        "releaseDefaultApproved": True,
        "recommendedCandidate": DEFAULT_PARAKEET_CANDIDATE_MODEL_ID,
        "recommendedCandidateStatus": (
            "approved-default-ready"
            if primary_ready
            else "approved-default-fallback-active"
        ),
        "workingFallback": DEFAULT_WHISPER_FALLBACK_MODEL_ID,
        "fallbackPolicy": "Normal transcription may fall back to Whisper Base; benchmarks stay strict so Parakeet timing is never confused with fallback timing.",
        "approvalGate": "Trishan approved Parakeet TDT v3 MLX BF16 as the V2 shipped default on 2026-07-10. Keep Whisper Base as the release fallback and rollback path.",
        "dependencies": {
            "transformers": dependencies.get("transformers"),
            "torch": dependencies.get("torch"),
            "parakeet_transformers": dependencies.get("parakeet_transformers"),
            "parakeet_mlx": dependencies.get("parakeet_mlx"),
        },
        "candidates": candidates,
        "nextValidationSteps": [
            "Build the V2 release candidate with parakeet-mlx in the locked Python runtime.",
            "Run packaged-app readiness with --load-check and --inference-check for the selected Parakeet default.",
            "Smoke test real microphone dictation, noisy/short audio, local media files, and silence samples.",
            "Confirm missing or failed Parakeet falls back to Whisper Base without transcript/audio loss.",
        ],
    }


def unsupported_runtime_message(model_id_or_path: str | None) -> str | None:
    model = CURATED_MODELS.get(model_id_or_path or DEFAULT_MODEL_ID)
    if model is None or model.runtime == SPEECH_RUNTIME_MLX_WHISPER:
        return None
    return (
        f"{model.display_name} is registered for the {model.runtime} runtime, "
        "but that runtime must be installed and validated before it can be used. "
        "OpenBridge will use Whisper Base as the fallback if the Parakeet default is not ready."
    )


def model_runtime_for(model_id_or_path: str | None) -> str:
    model = CURATED_MODELS.get(model_id_or_path or DEFAULT_MODEL_ID)
    return model.runtime if model is not None else SPEECH_RUNTIME_MLX_WHISPER


def list_installed_models() -> list[dict[str, object]]:
    ensure_app_support_dirs()
    installed: list[dict[str, object]] = []
    for model in CURATED_MODELS.values():
        existing = _installed_curated_model_path(model)
        installed.append(
            {
                **asdict(model),
                "installed": existing is not None,
                "path": str(existing) if existing is not None else None,
            }
        )
    return installed


def install_curated_model(model_id: str, force: bool = False) -> dict[str, object]:
    ensure_app_support_dirs()
    model = CURATED_MODELS.get(model_id)
    if model is None:
        raise RuntimeError(f"Unknown curated model: {model_id}")

    key = model_integrity.model_key(model.identifier) or model_integrity.model_key(model.repo_id)
    if key is not None:
        destination = model_integrity.installed_path(key, MODEL_ROOT)
        already_present = destination.is_dir()
        destination = model_integrity.install(key, MODEL_ROOT, force=force,
            local_sources=model_integrity.cached_sources(key, (HF_CACHE_ROOT,)))
        return {**asdict(model), "installed": True, "path": str(destination), "downloaded": not already_present}

    destination = MODEL_ROOT / model.identifier
    if model_dir_is_complete(destination) and not force:
        return {
            **asdict(model),
            "installed": True,
            "path": str(destination),
            "downloaded": False,
        }

    try:
        from huggingface_hub import snapshot_download
    except Exception as exc:
        raise RuntimeError(
            "huggingface_hub could not load from the Python runtime. "
            "If you are running from source, install requirements.txt first. "
            f"Details: {exc}"
        ) from exc

    destination.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        repo_id=model.repo_id,
        local_dir=str(destination),
        resume_download=True,
    )
    return {
        **asdict(model),
        "installed": True,
        "path": str(destination),
        "downloaded": True,
    }


def remove_curated_model(model_id: str) -> dict[str, object]:
    ensure_app_support_dirs()
    model = CURATED_MODELS.get(model_id)
    if model is None:
        raise RuntimeError(f"Unknown curated model: {model_id}")

    destination = MODEL_ROOT / model.identifier
    key = model_integrity.model_key(model.identifier) or model_integrity.model_key(model.repo_id)
    # Removal is an explicit model-management action, never a repair step.
    # Only these two owned model paths may be removed; shared HF caches remain.
    targets = [destination]
    if key is not None:
        targets.append(model_integrity.installed_path(key, MODEL_ROOT))
    for target in targets:
        if any(parent.is_symlink() for parent in target.parents):
            raise model_integrity.ModelIntegrityError("Model removal path contains a symlink")
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            for child in target.rglob("*"):
                if child.is_dir() and not child.is_symlink():
                    child.chmod(0o700)
            target.chmod(0o700)
            shutil.rmtree(target)

    return {
        **asdict(model),
        "installed": False,
        "path": str(destination),
    }


def resolve_engine_model(model_id_or_path: str | None) -> tuple[str, str]:
    if not model_id_or_path:
        model_id_or_path = DEFAULT_MODEL_ID

    model = CURATED_MODELS.get(model_id_or_path)
    if model is not None:
        key = model_integrity.model_key(model.identifier) or model_integrity.model_key(model.repo_id)
        if key is not None:
            # The loader authenticates once immediately before loading. Do not
            # rehash gigabytes during every status poll or transcript chunk.
            try:
                path = model_integrity.resolve(key, MODEL_ROOT,
                    legacy=[MODEL_ROOT / model.identifier], verify=False)
            except model_integrity.ModelIntegrityError:
                path = model_integrity.install(key, MODEL_ROOT, download_allowed=False,
                    local_sources=model_integrity.cached_sources(key, (HF_CACHE_ROOT,)))
            return str(path), model.display_name
        fallback_candidates = [str(MODEL_ROOT / model.identifier)]
        if _repo_basename_fallback_allowed(model.repo_id, model.identifier):
            fallback_candidates.append(model.repo_id)
        try:
            model_path, _ = resolve_local_model("", fallback_candidates)
            return model_path, model.display_name
        except RuntimeError as exc:
            if not _repo_basename_fallback_allowed(model.repo_id, model.identifier):
                snapshot = find_local_hf_snapshot(model.repo_id)
                if snapshot is not None:
                    return str(snapshot), model.display_name
            if model.runtime == SPEECH_RUNTIME_MLX_WHISPER:
                raise
            raise RuntimeError(
                f"No local {model.display_name} model was found. "
                f"Install {model.display_name} before benchmarking it, or use {DEFAULT_WHISPER_FALLBACK_MODEL_ID} as the fallback path. "
                f"Details: {exc}"
            ) from exc

    if Path(model_id_or_path).expanduser().exists():
        path = str(Path(model_id_or_path).expanduser())
        return path, path

    return resolve_local_model(model_id_or_path, [])


def _module_available(module_name: str) -> bool:
    return importlib.util.find_spec(module_name) is not None


def _parakeet_transformers_runtime_available() -> bool:
    if not _module_available("torch") or not _module_available("transformers"):
        return False

    try:
        transformers = importlib.import_module("transformers")
        importlib.import_module("torch")
    except Exception:
        return False

    for attribute in ("AutoModelForTDT", "AutoProcessor", "pipeline"):
        try:
            getattr(transformers, attribute)
        except Exception:
            return False
    return True


def _parakeet_mlx_runtime_available() -> bool:
    if not _module_available("parakeet_mlx") or not _module_available("mlx"):
        return False

    try:
        parakeet_mlx = importlib.import_module("parakeet_mlx")
        importlib.import_module("mlx.core")
    except Exception:
        return False

    return hasattr(parakeet_mlx, "from_pretrained")


def dependency_status() -> dict[str, object]:
    python_bin = os.environ.get("OPENBRIDGE_ENGINE_PYTHON", "python3")
    mlx_whisper_available = _module_available("mlx_whisper")
    mlx_lm_available = _module_available("mlx_lm")
    huggingface_hub_available = _module_available("huggingface_hub")
    transformers_available = _module_available("transformers")
    torch_available = _module_available("torch")

    return {
        "python": python_bin,
        "mlx_whisper": mlx_whisper_available,
        "mlx_lm": mlx_lm_available,
        "huggingface_hub": huggingface_hub_available,
        "transformers": transformers_available,
        "torch": torch_available,
        "parakeet_transformers": _parakeet_transformers_runtime_available(),
        "parakeet_mlx": _parakeet_mlx_runtime_available(),
    }
