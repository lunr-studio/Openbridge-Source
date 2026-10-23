from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import json
import os
from pathlib import Path
import re
from typing import Any

from .config import (
    DEFAULT_CORRECTION_MODEL,
    DEFAULT_LLM_PROVIDER,
    DEFAULT_TRANSCRIPTION_LANGUAGE,
    DEFAULT_VOCAB_PATH,
    HF_CACHE_ROOT,
    MODEL_ROOT,
    REPO_MODEL_ROOT,
    SPEECH_RUNTIME_MLX_WHISPER,
    SPEECH_RUNTIME_PARAKEET_MLX,
    SPEECH_RUNTIME_PARAKEET_TRANSFORMERS,
)
from .local_llm import generate_local_text
from . import model_integrity


CORRECTION_TIMEOUT_SECONDS = 30
FAST_CORRECTION_TIMEOUT_SECONDS = 12
MAX_FAST_CORRECTION_SEGMENTS = 6
MAX_FAST_CORRECTION_SEGMENT_CHARS = 220
ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CURSOR_CLEAR_PATTERN = re.compile(r"([A-Za-z]{1,64})\x1b\[(\d+)D\x1b\[K\s*\n?([A-Za-z][^\n]*)")
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
TRANSCRIPT_WORD_PATTERN = re.compile(r"[A-Za-z0-9']+")


@dataclass(frozen=True)
class AudioTranscriptionResult:
    text: str
    low_confidence_segments: list[str]
    segments: list[dict[str, Any]]
    language: str | None = None


@dataclass(frozen=True)
class RepetitionLoop:
    phrase: str
    repetitions: int


def getenv_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "t", "yes", "y", "on"}


def getenv_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def trim_command_output(text: str, max_lines: int = 30) -> str:
    lines = [line for line in text.strip().splitlines() if line.strip()]
    if not lines:
        return ""
    return "\n".join(lines[-max_lines:])


def iter_model_spec_candidates(model_spec: str) -> list[str]:
    cleaned = model_spec.strip()
    if not cleaned:
        return []
    candidates = [cleaned]
    if "/" not in cleaned and not cleaned.startswith((".", "~")):
        candidates.append(f"mlx-community/{cleaned}")
    return candidates


def find_local_hf_snapshot(repo_id: str) -> Path | None:
    snapshots_dir = HF_CACHE_ROOT / f"models--{repo_id.replace('/', '--')}" / "snapshots"
    if not snapshots_dir.exists():
        return None
    key = model_integrity.model_key(repo_id)
    if key is not None:
        path = snapshots_dir / model_integrity.model_spec(key)["revision"]
        return path if path.is_dir() else None
    snapshots = [path for path in snapshots_dir.iterdir() if path.is_dir()]
    if not snapshots:
        return None
    return sorted(snapshots, key=lambda path: path.stat().st_mtime, reverse=True)[0]


def resolve_local_model(
    explicit_model: str | None,
    fallback_candidates: list[str],
    *,
    local_model_roots: list[Path] | None = None,
    missing_help: str | None = None,
) -> tuple[str, str]:
    attempted: list[str] = []
    if local_model_roots is not None:
        model_roots = local_model_roots
    else:
        model_roots = [MODEL_ROOT, REPO_MODEL_ROOT]
    candidates = list(iter_model_spec_candidates(explicit_model or ""))
    for fallback in fallback_candidates:
        for candidate in iter_model_spec_candidates(fallback):
            if candidate not in candidates:
                candidates.append(candidate)

    for candidate in candidates:
        local_path = Path(candidate).expanduser()
        if local_path.exists():
            return str(local_path), str(local_path)

        for model_root in model_roots:
            local_named_dir = model_root / candidate.split("/")[-1]
            if local_named_dir.exists():
                return str(local_named_dir), str(local_named_dir)

        snapshot = find_local_hf_snapshot(candidate)
        if snapshot is not None:
            return str(snapshot), candidate

        attempted.append(candidate)

    attempted_text = ", ".join(attempted) if attempted else "no model candidates"
    guidance = (
        missing_help
        or "Set an explicit model path or install a curated model into the app support directory."
    )
    raise RuntimeError(
        "No local Whisper model was found. "
        f"Tried: {attempted_text}. "
        f"{guidance}"
    )


def load_vocab_corrections(path: Path, *, strict: bool = True) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        if not strict:
            return {}
        raise RuntimeError(f"Failed to read vocabulary corrections at {path}: {exc}") from exc

    items: dict[str, str] = {}
    if isinstance(data, dict):
        for wrong, right in data.items():
            if not isinstance(wrong, str) or not isinstance(right, str):
                continue
            wrong = wrong.strip()
            right = right.strip()
            if wrong:
                items[wrong.lower()] = right
    return items


def load_combined_vocab_corrections(
    vocab_path: Path,
    custom_vocab_path: Path | None = None,
    *,
    strict: bool = True,
) -> dict[str, str]:
    corrections = load_vocab_corrections(vocab_path, strict=strict)
    if custom_vocab_path is not None:
        corrections.update(load_vocab_corrections(custom_vocab_path, strict=strict))
    return corrections


def apply_vocab_corrections(text: str, corrections: dict[str, str]) -> str:
    if not corrections or not text:
        return text
    fixed = text
    for wrong, right in sorted(corrections.items(), key=lambda kv: len(kv[0]), reverse=True):
        pattern = re.compile(rf"\b{re.escape(wrong)}\b", flags=re.IGNORECASE)
        fixed = pattern.sub(lambda _: right, fixed)
    return fixed


def normalize_transcript_formatting(text: str) -> str:
    if not text:
        return text

    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([.,!?;:])", r"\1", text)
    text = re.sub(r"([.,!?;:])([A-Za-z0-9])", r"\1 \2", text)
    text = re.sub(r"\bi\b", "I", text)
    if not text:
        return text

    text = text[0].upper() + text[1:]
    text = re.sub(r"([.!?]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), text)
    return text


def remove_cursor_clear_artifacts(text: str) -> str:
    def replace(match: re.Match[str]) -> str:
        word_before_cursor = match.group(1)
        moved_characters = int(match.group(2))
        replacement_tail = match.group(3)
        if moved_characters <= len(word_before_cursor):
            overwritten = word_before_cursor[-moved_characters:]
            if replacement_tail.lower().startswith(overwritten.lower()):
                return word_before_cursor[:-moved_characters] + replacement_tail
        return word_before_cursor + replacement_tail

    previous = None
    cleaned = text
    while previous != cleaned:
        previous = cleaned
        cleaned = CURSOR_CLEAR_PATTERN.sub(replace, cleaned)
    return cleaned


def strip_terminal_control_sequences(text: str) -> str:
    text = remove_cursor_clear_artifacts(text)
    text = ANSI_ESCAPE_PATTERN.sub("", text)
    text = CONTROL_CHARACTER_PATTERN.sub("", text)
    return text.replace("\r\n", "\n").replace("\r", "\n")


def remove_thinking_sections(text: str) -> str:
    text = re.sub(r"(?is)<think>.*?</think>", "", text)
    thinking_marker = re.search(r"(?is)\.\.\.\s*done thinking\.?", text)
    if thinking_marker:
        tail = text[thinking_marker.end():].strip()
        if tail:
            return tail
    return text


def clean_ollama_response(raw: str) -> str:
    text = remove_thinking_sections(strip_terminal_control_sequences(raw)).strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if len(lines) > 1 and lines[-1].strip() == "```":
            return "\n".join(lines[1:-1]).strip()
    return text


def _replace_once(text: str, old: str, new: str) -> str:
    if not old or not new or old == new:
        return text
    index = text.find(old)
    if index < 0:
        return text
    return text[:index] + new + text[index + len(old):]


def _parse_segment_corrections(raw: str, expected_count: int) -> list[str] | None:
    cleaned = clean_ollama_response(raw)
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError:
        match = re.search(r"(\{[\s\S]*\}|\[[\s\S]*\])", cleaned)
        if not match:
            return None
        try:
            payload = json.loads(match.group(0))
        except json.JSONDecodeError:
            return None

    if isinstance(payload, dict):
        corrections_payload = payload.get("corrections")
        if corrections_payload is None and expected_count == 1:
            corrections_payload = payload.get("corrected_string")
        payload = corrections_payload

    if isinstance(payload, str) and expected_count == 1:
        payload = [payload]

    if not isinstance(payload, list) or len(payload) != expected_count:
        return None

    corrections = [item.strip() for item in payload if isinstance(item, str)]
    return corrections if len(corrections) == expected_count else None


def correct_low_confidence_segments_with_ollama(
    text: str,
    low_confidence_chunks: list[str],
    model: str,
    *,
    provider: str = DEFAULT_LLM_PROVIDER,
    verbose: bool = False,
) -> str:
    segments: list[str] = []
    seen: set[str] = set()
    for chunk in low_confidence_chunks:
        segment = re.sub(r"\s+", " ", chunk).strip()
        if not segment or segment in seen:
            continue
        seen.add(segment)
        segments.append(segment[:MAX_FAST_CORRECTION_SEGMENT_CHARS])
        if len(segments) >= MAX_FAST_CORRECTION_SEGMENTS:
            break

    if not segments:
        return text

    prompt = (
        "You are correcting short speech-recognition segments.\n"
        "Return only JSON with this exact shape: {\"corrections\":[\"corrected segment\"]}.\n"
        "Use exactly one corrections item for each input string.\n"
        "Fix obvious ASR errors, punctuation, capitalization, and names when clear.\n"
        "Do not paraphrase or add new facts.\n\n"
        f"Segments JSON:\n{json.dumps(segments, ensure_ascii=False)}"
    )
    try:
        result = generate_local_text(
            prompt,
            provider=provider,
            model=model,
            max_tokens=260,
            timeout_seconds=FAST_CORRECTION_TIMEOUT_SECONDS,
            json_mode=True,
        )
    except Exception as exc:
        if verbose:
            print(f"Local AI fast correction failed ({exc}). Skipping second-pass.")
        return text

    corrections = _parse_segment_corrections(result.text, len(segments))
    if corrections is None:
        if verbose:
            print("Local AI fast correction returned invalid JSON. Skipping second-pass.")
        return text

    corrected_text = text
    for original, corrected in zip(segments, corrections):
        corrected_text = _replace_once(corrected_text, original, corrected)
    return corrected_text


def correct_with_ollama(
    text: str,
    low_confidence_chunks: list[str],
    model: str = DEFAULT_CORRECTION_MODEL,
    *,
    cleanup_mode: str = "fast",
    provider: str = DEFAULT_LLM_PROVIDER,
    verbose: bool = False,
) -> str:
    if not low_confidence_chunks:
        return text

    if cleanup_mode == "fast":
        return correct_low_confidence_segments_with_ollama(
            text,
            low_confidence_chunks,
            model,
            provider=provider,
            verbose=verbose,
        )

    prompt = (
        "You are a transcription clean-up assistant. "
        "Return only corrected plain text with no explanations.\n"
        "Treat the whole transcript as ASR output and only fix likely OCR/ASR mistakes.\n"
        "Keep sentence meaning and punctuation largely unchanged.\n"
        f"Focus especially on these low-confidence segments: {', '.join(low_confidence_chunks)}\n\n"
        f"Transcript:\n{text}"
    )
    try:
        result = generate_local_text(
            prompt,
            provider=provider,
            model=model,
            max_tokens=max(256, len(text.split()) + 80),
            timeout_seconds=CORRECTION_TIMEOUT_SECONDS,
        )
    except Exception as exc:
        if verbose:
            print(f"Local AI correction failed ({exc}). Skipping second-pass.")
        return text

    corrected = clean_ollama_response(result.text)
    return corrected if corrected else text


def post_process_transcript(
    text: str,
    low_confidence_chunks: list[str],
    *,
    vocab_path: Path = DEFAULT_VOCAB_PATH,
    custom_vocab_path: Path | None = None,
    vocab_enabled: bool = True,
    formatting_enabled: bool = True,
    ollama_enabled: bool = False,
    ollama_model: str = DEFAULT_CORRECTION_MODEL,
    ollama_cleanup_mode: str = "fast",
    llm_provider: str = DEFAULT_LLM_PROVIDER,
    strict_vocab: bool = True,
    verbose: bool = False,
) -> str:
    vocabulary: dict[str, str] = {}
    if vocab_enabled:
        vocabulary = load_combined_vocab_corrections(
            vocab_path,
            custom_vocab_path,
            strict=strict_vocab,
        )
        text = apply_vocab_corrections(text, vocabulary)

    if ollama_enabled and low_confidence_chunks:
        text = correct_with_ollama(
            text,
            low_confidence_chunks,
            ollama_model,
            cleanup_mode=ollama_cleanup_mode,
            provider=llm_provider,
            verbose=verbose,
        )
        if vocabulary:
            text = apply_vocab_corrections(text, vocabulary)

    if formatting_enabled:
        text = normalize_transcript_formatting(text)

    return text


def _load_whisper_runtime() -> tuple[Any, Any, Any]:
    try:
        import mlx.core as mx
        from mlx_whisper import transcribe as mlx_transcribe
        from mlx_whisper.transcribe import ModelHolder
    except Exception as exc:
        raise RuntimeError(
            "mlx-whisper could not load from the Python runtime. "
            "If you are running from source, activate the repo venv and install requirements.txt. "
            f"Details: {exc}"
        ) from exc
    return mx, mlx_transcribe, ModelHolder


def warm_model_cache(model_path: str) -> None:
    mx, _, model_holder = _load_whisper_runtime()
    model_holder.get_model(model_path, mx.float16)


@lru_cache(maxsize=2)
def _load_parakeet_transformers_pipeline(model_path: str) -> Any:
    try:
        import torch
        from transformers import pipeline
    except Exception as exc:
        raise RuntimeError(
            "Parakeet Transformers runtime could not load from the Python runtime. "
            "Install and validate torch plus transformers before enabling Parakeet locally. "
            f"Details: {exc}"
        ) from exc

    device: str | int = -1
    try:
        if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
            device = "mps"
    except Exception:
        device = -1

    try:
        return pipeline("automatic-speech-recognition", model=model_path, device=device)
    except Exception as exc:
        raise RuntimeError(
            "Parakeet Transformers pipeline could not be initialized. "
            "Confirm the model files, transformers version, torch build, and Apple silicon runtime support. "
            f"Details: {exc}"
        ) from exc


@lru_cache(maxsize=2)
def _load_parakeet_mlx_model(model_path: str) -> Any:
    model_integrity.authenticate("parakeet", Path(model_path))
    try:
        import mlx.core as mx
        from parakeet_mlx import from_pretrained
    except Exception as exc:
        raise RuntimeError(
            "Parakeet MLX runtime could not load from the Python runtime. "
            "Install and validate parakeet-mlx plus mlx before enabling Parakeet MLX locally. "
            f"Details: {exc}"
        ) from exc

    try:
        return from_pretrained(model_path, dtype=mx.bfloat16)
    except Exception as exc:
        raise RuntimeError(
            "Parakeet MLX model could not be initialized. "
            "Confirm the model files, parakeet-mlx version, MLX build, and Apple silicon runtime support. "
            f"Details: {exc}"
        ) from exc


def warm_model_cache_for_runtime(model_path: str, runtime: str) -> None:
    if runtime == SPEECH_RUNTIME_MLX_WHISPER:
        warm_model_cache(model_path)
        return
    if runtime == SPEECH_RUNTIME_PARAKEET_TRANSFORMERS:
        _load_parakeet_transformers_pipeline(model_path)
        return
    if runtime == SPEECH_RUNTIME_PARAKEET_MLX:
        _load_parakeet_mlx_model(model_path)
        return
    raise RuntimeError(f"Unsupported speech runtime: {runtime}")


def transcribe_audio(
    audio_path: Path,
    model: str,
    low_confidence_threshold: float,
    *,
    language: str = DEFAULT_TRANSCRIPTION_LANGUAGE,
    condition_on_previous_text: bool = True,
) -> tuple[str, list[str]]:
    result = transcribe_audio_detailed(
        audio_path,
        model,
        low_confidence_threshold,
        language=language,
        condition_on_previous_text=condition_on_previous_text,
    )
    return result.text, result.low_confidence_segments


def transcribe_audio_for_runtime(
    audio_path: Path,
    model: str,
    low_confidence_threshold: float,
    *,
    runtime: str,
    language: str = DEFAULT_TRANSCRIPTION_LANGUAGE,
    condition_on_previous_text: bool = True,
) -> tuple[str, list[str]]:
    result = transcribe_audio_detailed_for_runtime(
        audio_path,
        model,
        low_confidence_threshold,
        runtime=runtime,
        language=language,
        condition_on_previous_text=condition_on_previous_text,
    )
    return result.text, result.low_confidence_segments


def transcribe_audio_detailed(
    audio_path: Path,
    model: str,
    low_confidence_threshold: float,
    *,
    language: str = DEFAULT_TRANSCRIPTION_LANGUAGE,
    condition_on_previous_text: bool = True,
) -> AudioTranscriptionResult:
    _, mlx_transcribe, _ = _load_whisper_runtime()
    try:
        result = mlx_transcribe(
            str(audio_path),
            path_or_hf_repo=model,
            language=language,
            verbose=False,
            condition_on_previous_text=condition_on_previous_text,
        )
    except TypeError:
        result = mlx_transcribe(
            str(audio_path),
            model=model,
            language=language,
            verbose=False,
            condition_on_previous_text=condition_on_previous_text,
        )

    if isinstance(result, str):
        return AudioTranscriptionResult(text=result.strip(), low_confidence_segments=[], segments=[])

    if isinstance(result, dict):
        if "text" in result and isinstance(result["text"], str):
            text = result["text"].strip()
            low_conf: list[str] = []
            segments = result.get("segments", [])
            if isinstance(segments, list):
                for seg in segments:
                    if not isinstance(seg, dict):
                        continue
                    seg_text = str(seg.get("text", "")).strip()
                    if not seg_text:
                        continue
                    score = seg.get("avg_logprob")
                    if isinstance(score, (int, float)) and score < low_confidence_threshold:
                        low_conf.append(seg_text)
            return AudioTranscriptionResult(
                text=text,
                low_confidence_segments=low_conf,
                segments=segments if isinstance(segments, list) else [],
                language=str(result.get("language")) if result.get("language") else None,
            )
        if "segments" in result and isinstance(result["segments"], list):
            parts: list[str] = []
            low_conf = []
            for seg in result["segments"]:
                if not isinstance(seg, dict):
                    continue
                text = str(seg.get("text", "")).strip()
                if text:
                    parts.append(text)
                    score = seg.get("avg_logprob")
                    if isinstance(score, (int, float)) and score < low_confidence_threshold:
                        low_conf.append(text)
            return AudioTranscriptionResult(
                text=" ".join(parts).strip(),
                low_confidence_segments=low_conf,
                segments=result["segments"],
                language=str(result.get("language")) if result.get("language") else None,
            )

    return AudioTranscriptionResult(text=str(result).strip(), low_confidence_segments=[], segments=[])


def _segment_from_transformers_chunk(chunk: object) -> dict[str, Any] | None:
    if not isinstance(chunk, dict):
        return None
    text = str(chunk.get("text", "")).strip()
    if not text:
        return None

    segment: dict[str, Any] = {"text": text}
    timestamp = chunk.get("timestamp")
    if isinstance(timestamp, (list, tuple)) and len(timestamp) >= 2:
        start, end = timestamp[0], timestamp[1]
        if isinstance(start, (int, float)):
            segment["start"] = float(start)
        if isinstance(end, (int, float)):
            segment["end"] = float(end)
    return segment


def transcribe_audio_detailed_parakeet_transformers(
    audio_path: Path,
    model: str,
    low_confidence_threshold: float,
    *,
    language: str = DEFAULT_TRANSCRIPTION_LANGUAGE,
    condition_on_previous_text: bool = True,
) -> AudioTranscriptionResult:
    _ = low_confidence_threshold, language, condition_on_previous_text
    pipe = _load_parakeet_transformers_pipeline(model)
    try:
        result = pipe(str(audio_path), return_timestamps=True)
    except TypeError:
        result = pipe(str(audio_path))
    except Exception as exc:
        raise RuntimeError(f"Parakeet transcription failed: {exc}") from exc

    if isinstance(result, str):
        return AudioTranscriptionResult(text=result.strip(), low_confidence_segments=[], segments=[])

    if isinstance(result, dict):
        text = str(result.get("text", "")).strip()
        chunks = result.get("chunks", [])
        segments: list[dict[str, Any]] = []
        if isinstance(chunks, list):
            segments = [
                segment
                for chunk in chunks
                if (segment := _segment_from_transformers_chunk(chunk)) is not None
            ]
        if not text and segments:
            text = " ".join(str(segment.get("text", "")).strip() for segment in segments).strip()
        return AudioTranscriptionResult(
            text=text,
            low_confidence_segments=[],
            segments=segments,
            language=str(result.get("language")) if result.get("language") else None,
        )

    return AudioTranscriptionResult(text=str(result).strip(), low_confidence_segments=[], segments=[])


def transcribe_audio_detailed_parakeet_mlx(
    audio_path: Path,
    model: str,
    low_confidence_threshold: float,
    *,
    language: str = DEFAULT_TRANSCRIPTION_LANGUAGE,
    condition_on_previous_text: bool = True,
) -> AudioTranscriptionResult:
    _ = low_confidence_threshold, language, condition_on_previous_text
    parakeet_model = _load_parakeet_mlx_model(model)
    try:
        result = parakeet_model.transcribe(str(audio_path))
    except Exception as exc:
        raise RuntimeError(f"Parakeet MLX transcription failed: {exc}") from exc

    # `parakeet-mlx` returns an AlignedResult whose explicit `text` is an
    # empty string when a chunk contains no speech.  Preserve that semantic
    # empty value: falling back to `str(result)` would leak the diagnostic
    # representation (for example, "AlignedResult(text='', sentences=[])")
    # into the user's transcript.
    raw_text = getattr(result, "text", None)
    text = str(raw_text).strip() if raw_text is not None else ""
    segments: list[dict[str, Any]] = []
    sentences = getattr(result, "sentences", None)
    if isinstance(sentences, list):
        for sentence in sentences:
            sentence_text = str(getattr(sentence, "text", "")).strip()
            if not sentence_text:
                continue
            segment: dict[str, Any] = {"text": sentence_text}
            start = getattr(sentence, "start", None)
            end = getattr(sentence, "end", None)
            if isinstance(start, (int, float)):
                segment["start"] = float(start)
            if isinstance(end, (int, float)):
                segment["end"] = float(end)
            segments.append(segment)

    if not text and segments:
        text = " ".join(str(segment.get("text", "")).strip() for segment in segments).strip()
    if not text and raw_text is None:
        text = str(result).strip()

    return AudioTranscriptionResult(text=text, low_confidence_segments=[], segments=segments)


def transcribe_audio_detailed_for_runtime(
    audio_path: Path,
    model: str,
    low_confidence_threshold: float,
    *,
    runtime: str,
    language: str = DEFAULT_TRANSCRIPTION_LANGUAGE,
    condition_on_previous_text: bool = True,
) -> AudioTranscriptionResult:
    if runtime == SPEECH_RUNTIME_MLX_WHISPER:
        return transcribe_audio_detailed(
            audio_path,
            model,
            low_confidence_threshold,
            language=language,
            condition_on_previous_text=condition_on_previous_text,
        )
    if runtime == SPEECH_RUNTIME_PARAKEET_TRANSFORMERS:
        return transcribe_audio_detailed_parakeet_transformers(
            audio_path,
            model,
            low_confidence_threshold,
            language=language,
            condition_on_previous_text=condition_on_previous_text,
        )
    if runtime == SPEECH_RUNTIME_PARAKEET_MLX:
        return transcribe_audio_detailed_parakeet_mlx(
            audio_path,
            model,
            low_confidence_threshold,
            language=language,
            condition_on_previous_text=condition_on_previous_text,
        )
    raise RuntimeError(f"Unsupported speech runtime: {runtime}")


def detect_repetition_loop(text: str) -> RepetitionLoop | None:
    words = [match.group(0).lower() for match in TRANSCRIPT_WORD_PATTERN.finditer(text)]
    if len(words) < 24:
        return None

    thresholds = {
        1: 24,
        2: 14,
        3: 10,
        4: 8,
        5: 7,
    }
    best_loop: RepetitionLoop | None = None
    for phrase_size, threshold in thresholds.items():
        index = 0
        while index + phrase_size <= len(words):
            phrase = tuple(words[index : index + phrase_size])
            repetitions = 1
            next_index = index + phrase_size
            while next_index + phrase_size <= len(words) and tuple(words[next_index : next_index + phrase_size]) == phrase:
                repetitions += 1
                next_index += phrase_size
            if repetitions >= threshold:
                loop = RepetitionLoop(phrase=" ".join(phrase), repetitions=repetitions)
                if best_loop is None or loop.repetitions * phrase_size > best_loop.repetitions * len(best_loop.phrase.split()):
                    best_loop = loop
            index = max(index + 1, next_index if repetitions > 1 else index + 1)
    return best_loop


def raise_if_repetition_loop(text: str) -> None:
    loop = detect_repetition_loop(text)
    if loop is None:
        return
    raise RuntimeError(
        "The transcript appears incomplete because the speech model entered a repetition loop "
        f"around \"{loop.phrase}\" ({loop.repetitions} repeats). "
        "Try a shorter clip, or download the audio/video and transcribe the file."
    )
