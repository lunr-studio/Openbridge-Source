from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from .config import (
    DEFAULT_CORRECTION_MODEL,
    DEFAULT_LLM_PROVIDER,
    DEFAULT_MLX_LLM_CAREFUL_MODEL,
    DEFAULT_MLX_LLM_MODEL,
    LLM_CACHE_ROOT,
    MODEL_ROOT,
    ensure_app_support_dirs,
)
from . import model_integrity


VALID_LLM_PROVIDERS = {"auto", "mlx", "ollama"}
COMMAND_TIMEOUT_SECONDS = 60
OLLAMA_STARTUP_TIMEOUT_SECONDS = 8
COMMON_OLLAMA_PATHS = (
    Path("/opt/homebrew/bin/ollama"),
    Path("/usr/local/bin/ollama"),
    Path("/Applications/Ollama.app/Contents/Resources/ollama"),
)
OLLAMA_UNAVAILABLE_MARKERS = (
    "could not connect",
    "connection refused",
    "failed to connect",
    "server closed",
    "server not responding",
    "no connection",
)
MLX_MODEL_ALIASES = {
    "gemma4:e2b": DEFAULT_MLX_LLM_MODEL,
    "gemma4:e2b-mlx-bf16": DEFAULT_MLX_LLM_MODEL,
    "gemma4:e4b": DEFAULT_MLX_LLM_CAREFUL_MODEL,
    "gemma4:e4b-mlx-bf16": DEFAULT_MLX_LLM_CAREFUL_MODEL,
}
OLLAMA_MODEL_ALIASES = {DEFAULT_MLX_LLM_MODEL: DEFAULT_CORRECTION_MODEL}
if DEFAULT_MLX_LLM_CAREFUL_MODEL != DEFAULT_MLX_LLM_MODEL:
    OLLAMA_MODEL_ALIASES[DEFAULT_MLX_LLM_CAREFUL_MODEL] = "gemma4:e4b"


class LocalLLMError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        details: str | None = None,
        code: str = "local_llm_failed",
        exit_code: int = 1,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.details = details
        self.code = code
        self.exit_code = exit_code


@dataclass(frozen=True)
class LocalLLMResult:
    text: str
    provider: str
    model: str


def normalize_provider(provider: str | None) -> str:
    normalized = (provider or DEFAULT_LLM_PROVIDER or "auto").strip().lower()
    if normalized not in VALID_LLM_PROVIDERS:
        raise LocalLLMError(
            "Local AI provider is invalid.",
            details=f"Use one of: {', '.join(sorted(VALID_LLM_PROVIDERS))}.",
            code="invalid_llm_provider",
            exit_code=2,
        )
    return normalized


def mlx_lm_available() -> bool:
    return importlib.util.find_spec("mlx_lm") is not None


def local_llm_status() -> dict[str, object]:
    default_mlx_model_present = mlx_model_cache_present(DEFAULT_MLX_LLM_MODEL)
    careful_mlx_model_present = mlx_model_cache_present(DEFAULT_MLX_LLM_CAREFUL_MODEL)
    return {
        "defaultProvider": DEFAULT_LLM_PROVIDER,
        "mlxAvailable": mlx_lm_available(),
        "mlxDefaultModel": DEFAULT_MLX_LLM_MODEL,
        "mlxDefaultModelPresent": default_mlx_model_present,
        "mlxCarefulModel": DEFAULT_MLX_LLM_CAREFUL_MODEL,
        "mlxCarefulModelPresent": careful_mlx_model_present,
        "ollamaAvailable": resolve_ollama_executable() is not None,
        "ollamaDefaultModel": DEFAULT_CORRECTION_MODEL,
        "cacheRoot": str(LLM_CACHE_ROOT),
    }


def mlx_model_cache_present(model: str | None) -> bool:
    resolved = model_for_provider(model, "mlx")
    key = model_integrity.model_key(resolved)
    if key is not None:
        candidates = [model_integrity.installed_path(key, MODEL_ROOT), *mlx_pinned_sources(key)]
        return any((path / "config.json").is_file() for path in candidates)
    cache_stem = f"models--{resolved.replace('/', '--')}"
    candidates = [
        LLM_CACHE_ROOT / "hub" / cache_stem,
        LLM_CACHE_ROOT / cache_stem,
        Path.home() / ".cache" / "huggingface" / "hub" / cache_stem,
    ]

    for candidate in candidates:
        snapshots = candidate / "snapshots"
        if snapshots.is_dir() and any(snapshots.iterdir()):
            return True
        if candidate.is_dir() and any(candidate.iterdir()):
            return True
    return False


def mlx_pinned_sources(key: str) -> tuple[Path, ...]:
    return model_integrity.cached_sources(key, (
        LLM_CACHE_ROOT / "hub", LLM_CACHE_ROOT,
        Path.home() / ".cache" / "huggingface" / "hub",
    ))


def provider_candidates(provider: str | None) -> list[str]:
    normalized = normalize_provider(provider)
    if normalized == "auto":
        return ["mlx", "ollama"]
    return [normalized]


def model_for_provider(model: str | None, provider: str) -> str:
    cleaned = (model or "").strip()
    if provider == "mlx":
        if not cleaned:
            return DEFAULT_MLX_LLM_MODEL
        return MLX_MODEL_ALIASES.get(cleaned, cleaned)
    if provider == "ollama":
        if not cleaned:
            return DEFAULT_CORRECTION_MODEL
        return OLLAMA_MODEL_ALIASES.get(cleaned, cleaned)
    raise LocalLLMError(
        "Local AI provider is invalid.",
        details=provider,
        code="invalid_llm_provider",
        exit_code=2,
    )


def trim_command_output(text: str, max_lines: int = 30) -> str:
    lines = [line for line in text.strip().splitlines() if line.strip()]
    if not lines:
        return ""
    return "\n".join(lines[-max_lines:])


def remove_thinking_sections(text: str) -> str:
    text = re.sub(r"(?is)<think>.*?</think>", "", text)
    thinking_marker = re.search(r"(?is)\.\.\.\s*done thinking\.?", text)
    if thinking_marker:
        tail = text[thinking_marker.end():].strip()
        if tail:
            return tail
    return text


def clean_local_llm_response(raw: str) -> str:
    return remove_thinking_sections(raw).strip()


def resolve_ollama_executable() -> str | None:
    executable = shutil.which("ollama")
    if executable:
        return executable

    for candidate in COMMON_OLLAMA_PATHS:
        if candidate.exists() and candidate.is_file():
            return str(candidate)
    return None


def ensure_ollama_available() -> str:
    executable = resolve_ollama_executable()
    if executable is None:
        raise LocalLLMError(
            "Local AI fallback requires Ollama.",
            details="Install Ollama, then pull the local rewrite model with: ollama pull gemma4:e2b",
            code="ollama_missing",
        )
    return executable


def ollama_output_indicates_unavailable(output: str) -> bool:
    normalized = output.lower()
    return any(marker in normalized for marker in OLLAMA_UNAVAILABLE_MARKERS)


def start_ollama_server(ollama_path: str) -> None:
    try:
        subprocess.Popen(
            [ollama_path, "serve"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as exc:
        raise LocalLLMError(
            "Local AI fallback could not start Ollama.",
            details="Open the Ollama app or run `ollama serve` in Terminal, then try again.",
            code="ollama_unavailable",
        ) from exc


def run_ollama_show(ollama_path: str, model: str, timeout_seconds: float) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [ollama_path, "show", model],
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )


def wait_for_ollama_model(
    ollama_path: str,
    model: str,
    *,
    timeout_seconds: float = OLLAMA_STARTUP_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess[str]:
    deadline = time.monotonic() + timeout_seconds
    last_proc: subprocess.CompletedProcess[str] | None = None
    last_timeout: subprocess.TimeoutExpired | None = None

    while time.monotonic() < deadline:
        try:
            proc = run_ollama_show(ollama_path, model, timeout_seconds=2)
        except subprocess.TimeoutExpired as exc:
            last_timeout = exc
            time.sleep(0.4)
            continue

        if proc.returncode == 0:
            return proc

        last_proc = proc
        output = trim_command_output(f"{proc.stdout}\n{proc.stderr}")
        if not ollama_output_indicates_unavailable(output):
            return proc

        time.sleep(0.4)

    if last_proc is not None:
        return last_proc

    raise LocalLLMError(
        "Local AI fallback could not reach Ollama in time.",
        details=(
            "Open the Ollama app or run `ollama serve` in Terminal, then try again."
            if last_timeout is not None
            else "Ollama did not become ready in time."
        ),
        code="ollama_unavailable",
    )


def ensure_ollama_model(
    model: str = DEFAULT_CORRECTION_MODEL,
    *,
    timeout_seconds: float = 10,
    ollama_path: str | None = None,
) -> str:
    ollama_path = ollama_path or ensure_ollama_available()
    try:
        proc = run_ollama_show(ollama_path, model, timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        start_ollama_server(ollama_path)
        try:
            proc = wait_for_ollama_model(ollama_path, model)
        except LocalLLMError as retry_error:
            raise retry_error from exc
    except Exception as exc:
        raise LocalLLMError(
            "Local AI fallback could not reach Ollama.",
            details=f"{exc}. Open the Ollama app or run `ollama serve` in Terminal, then try again.",
            code="ollama_unavailable",
        ) from exc

    if proc.returncode == 0:
        return ollama_path

    output = trim_command_output(f"{proc.stdout}\n{proc.stderr}")
    if ollama_output_indicates_unavailable(output):
        start_ollama_server(ollama_path)
        proc = wait_for_ollama_model(ollama_path, model)
        if proc.returncode == 0:
            return ollama_path
        output = trim_command_output(f"{proc.stdout}\n{proc.stderr}")
        if ollama_output_indicates_unavailable(output):
            raise LocalLLMError(
                "Local AI fallback could not reach Ollama.",
                details=(
                    f"{output}\n\n"
                    "Open the Ollama app or run `ollama serve` in Terminal, then try again."
                ),
                code="ollama_unavailable",
            )

    if "not found" in output.lower():
        raise LocalLLMError(
            "Local AI fallback model is not available.",
            details=f"Install the local fallback model with: ollama pull {model}",
            code="command_model_missing",
        )

    raise LocalLLMError(
        "Local AI fallback could not reach Ollama.",
        details=(
            output
            or f"`ollama show {model}` exited with code {proc.returncode}. "
            "Open the Ollama app or run `ollama serve` in Terminal, then try again."
        ),
        code="ollama_unavailable",
    )


@lru_cache(maxsize=2)
def _load_mlx_model(model: str, expected_model_key: str | None = None):
    key = expected_model_key or model_integrity.model_key(model)
    if key is not None and not Path(model).is_absolute():
        try:
            model = str(model_integrity.resolve(key, MODEL_ROOT))
        except model_integrity.ModelIntegrityError:
            # Preserve the existing explicit MLX setup/download behavior, but
            # never let mlx_lm select or download an unpinned repository.
            model = str(model_integrity.install(key, MODEL_ROOT, local_sources=mlx_pinned_sources(key)))
    if key is not None:
        model_integrity.authenticate(key, Path(model))
    try:
        from mlx_lm import load
    except Exception as exc:
        raise LocalLLMError(
            "MLX local AI could not load.",
            details=f"Install mlx-lm into the Python runtime. Details: {exc}",
            code="mlx_lm_missing",
        ) from exc

    ensure_app_support_dirs()
    os.environ.setdefault("HF_HOME", str(LLM_CACHE_ROOT))
    try:
        return load(model)
    except Exception as exc:
        raise LocalLLMError(
            "MLX local AI model could not load.",
            details=f"{model}: {exc}",
            code="mlx_model_load_failed",
        ) from exc


def _generate_with_mlx(prompt: str, model: str, *, max_tokens: int,
                       expected_model_key: str | None = None) -> str:
    try:
        from mlx_lm import generate
    except Exception as exc:
        raise LocalLLMError(
            "MLX local AI could not generate text.",
            details=f"Install mlx-lm into the Python runtime. Details: {exc}",
            code="mlx_lm_missing",
        ) from exc

    model_obj, tokenizer = (_load_mlx_model(model, expected_model_key)
                           if expected_model_key else _load_mlx_model(model))
    mlx_prompt = prompt
    if hasattr(tokenizer, "apply_chat_template"):
        try:
            mlx_prompt = tokenizer.apply_chat_template(
                [{"role": "user", "content": prompt}],
                tokenize=False,
                add_generation_prompt=True,
            )
        except Exception:
            mlx_prompt = prompt
    try:
        return generate(model_obj, tokenizer, prompt=mlx_prompt, verbose=False, max_tokens=max_tokens)
    except Exception as exc:
        raise LocalLLMError(
            "MLX local AI generation failed.",
            details=str(exc),
            code="mlx_generation_failed",
        ) from exc


def _generate_with_ollama(
    prompt: str,
    model: str,
    *,
    timeout_seconds: float,
    json_mode: bool,
) -> str:
    ollama_path = ensure_ollama_model(model)
    command = [ollama_path, "run", model]
    if json_mode:
        command.extend(
            [
                "--format",
                "json",
                "--think",
                "false",
                "--hidethinking",
                "--nowordwrap",
                "--keepalive",
                "10m",
            ]
        )

    try:
        proc = subprocess.run(
            command,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise LocalLLMError(
            "Local AI fallback timed out.",
            details=f"Ollama did not return within {timeout_seconds:g} seconds.",
            code="local_llm_timeout",
        ) from exc
    except Exception as exc:
        raise LocalLLMError(
            "Local AI fallback failed.",
            details=str(exc),
            code="ollama_generation_failed",
        ) from exc

    if proc.returncode != 0:
        output = trim_command_output(f"{proc.stdout}\n{proc.stderr}")
        raise LocalLLMError(
            "Local AI fallback failed.",
            details=output or f"`ollama run {model}` exited with code {proc.returncode}.",
            code="command_model_missing" if "not found" in output.lower() else "ollama_generation_failed",
        )

    return proc.stdout


def generate_local_text(
    prompt: str,
    *,
    provider: str | None = None,
    model: str | None = None,
    max_tokens: int = 256,
    timeout_seconds: float = COMMAND_TIMEOUT_SECONDS,
    json_mode: bool = False,
    expected_model_key: str | None = None,
) -> LocalLLMResult:
    errors: list[LocalLLMError] = []
    for candidate_provider in provider_candidates(provider):
        candidate_model = model_for_provider(model, candidate_provider)
        try:
            if candidate_provider == "mlx":
                if not mlx_lm_available():
                    raise LocalLLMError(
                        "MLX local AI is not installed.",
                        details="Install mlx-lm into the Python runtime.",
                        code="mlx_lm_missing",
                    )
                integrity_options = {"expected_model_key": expected_model_key} if expected_model_key else {}
                text = _generate_with_mlx(prompt, candidate_model, max_tokens=max_tokens, **integrity_options)
            else:
                text = _generate_with_ollama(
                    prompt,
                    candidate_model,
                    timeout_seconds=timeout_seconds,
                    json_mode=json_mode,
                )
            return LocalLLMResult(
                text=clean_local_llm_response(text),
                provider=candidate_provider,
                model=candidate_model,
            )
        except LocalLLMError as exc:
            errors.append(exc)
            if normalize_provider(provider) != "auto":
                raise

    last = errors[-1] if errors else None
    detail_lines = [error.details or error.message for error in errors]
    raise LocalLLMError(
        "No local AI provider could generate text.",
        details="\n".join(detail_lines) if detail_lines else None,
        code=last.code if last else "local_llm_unavailable",
    )
