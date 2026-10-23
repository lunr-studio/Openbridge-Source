"""Offline post-meeting cleanup benchmark for CLEAN-00.

This module deliberately does not persist cleanup results into meeting storage.
It proves (or rejects) a request/result contract using deterministic synthetic
Meeting schema-v2 segments and the exact local Gemma MLX snapshot.
"""

from __future__ import annotations

import importlib.metadata
import json
import os
import platform
import re
import socket
import subprocess
import threading
import time
from collections.abc import Callable, Iterable
from contextlib import AbstractContextManager
from dataclasses import asdict, dataclass
from hashlib import sha256
from itertools import pairwise
from pathlib import Path
from typing import ClassVar, Self

from .config import LLM_CACHE_ROOT, MODEL_ROOT
from . import model_integrity

CONTRACT_VERSION = 1
DEFAULT_CHUNK_SIZE = 8
EXACT_MODEL_ID = "mlx-community/gemma-3-4b-it-qat-4bit"
FIXTURE_DURATIONS_MINUTES = (15, 60)
SEGMENT_DURATION_SECONDS = 30.0
PERFORMANCE_GATE_SECONDS = 5 * 60
# Wall-clock measurements are not infinitely precise. The product owner accepted
# the observed 300.006-second run as equivalent to the five-minute boundary, so
# the automated decision allows only 50 milliseconds of measurement tolerance.
PERFORMANCE_GATE_TOLERANCE_SECONDS = 0.05
RSS_GROWTH_FLOOR_BYTES = 256 * 1024 * 1024
SWAP_GROWTH_FLOOR_BYTES = 128 * 1024 * 1024


class CleanupBenchmarkError(RuntimeError):
    """An actionable CLEAN-00 benchmark failure."""


class OfflineNetworkAttempt(CleanupBenchmarkError):
    """Raised whenever benchmarked inference attempts network access."""


@dataclass(frozen=True)
class CleanupSourceSegment:
    """Python mirror of the Swift MeetingTranscriptSegment contract."""

    id: str
    meetingID: str
    sequence: int
    startOffset: float
    endOffset: float
    sourceLabel: str
    text: str
    isFinal: bool = True


@dataclass(frozen=True)
class CleanupFixture:
    fixtureID: str
    meetingID: str
    durationSeconds: float
    segments: tuple[CleanupSourceSegment, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "fixtureID": self.fixtureID,
            "meetingID": self.meetingID,
            "durationSeconds": self.durationSeconds,
            "segments": [asdict(segment) for segment in self.segments],
        }


@dataclass(frozen=True)
class CleanedSegment:
    sourceSegmentID: str
    cleanedText: str


@dataclass(frozen=True)
class CleanupGenerationItem:
    """Untrusted model output before it is mapped to a trusted source ID."""

    index: int
    cleanedText: str


@dataclass(frozen=True)
class SnapshotFile:
    path: str
    sizeBytes: int
    sha256: str


@dataclass(frozen=True)
class SnapshotInspection:
    repository: str
    revision: str
    snapshotPath: str
    complete: bool
    missingFiles: tuple[str, ...]
    warnings: tuple[str, ...]
    config: SnapshotFile | None
    tokenizerFiles: tuple[SnapshotFile, ...]
    weightFiles: tuple[SnapshotFile, ...]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


_SYNTHETIC_LINES = (
    "okay so the customer pilot starts monday and the support rota needs one more owner",
    "the launch budget is forty two thousand dollars including the accessibility review",
    "we agreed that the canonical transcript stays unchanged even when cleanup is available",
    "please record the risk that offline model readiness must not trigger a hidden download",
    "the design review is thursday at ten thirty and the prototype uses synthetic data only",
    "we should keep the source segment identifiers stable for export retrieval and recovery",
    "the current estimate is three working days but that is complexity guidance not a promise",
    "alex will validate the benchmark report after the implementation handoff is reviewable",
    "the phrase open bridge sometimes appears as two words in raw parakeet style output",
    "we need a build revise or reject decision based on measured evidence from this mac",
    "the original text must remain available beside the cleaned revision for comparison",
    "if memory pressure or swap grows on every run we should revise the production approach",
)


def generate_synthetic_fixture(minutes: int) -> CleanupFixture:
    """Create a byte-for-byte deterministic Parakeet-style transcript fixture."""

    if minutes not in FIXTURE_DURATIONS_MINUTES:
        raise ValueError(
            f"Fixture duration must be one of {FIXTURE_DURATIONS_MINUTES}."
        )
    duration_seconds = float(minutes * 60)
    segment_count = int(duration_seconds / SEGMENT_DURATION_SECONDS)
    meeting_id = f"clean-00-{minutes}m-meeting"
    segments = tuple(
        CleanupSourceSegment(
            id=f"{meeting_id}-segment-{sequence:04d}",
            meetingID=meeting_id,
            sequence=sequence,
            startOffset=sequence * SEGMENT_DURATION_SECONDS,
            endOffset=(sequence + 1) * SEGMENT_DURATION_SECONDS,
            sourceLabel="Room",
            text=_SYNTHETIC_LINES[sequence % len(_SYNTHETIC_LINES)],
        )
        for sequence in range(segment_count)
    )
    return CleanupFixture(
        fixtureID=f"clean-00-synthetic-{minutes}m-v1",
        meetingID=meeting_id,
        durationSeconds=duration_seconds,
        segments=segments,
    )


def validate_fixture(fixture: CleanupFixture) -> list[str]:
    issues: list[str] = []
    seen_ids: set[str] = set()
    for expected_sequence, segment in enumerate(fixture.segments):
        if segment.id in seen_ids:
            issues.append(f"Duplicate segment ID: {segment.id}")
        seen_ids.add(segment.id)
        if segment.meetingID != fixture.meetingID:
            issues.append(f"Segment {segment.id} has the wrong meeting ID")
        if segment.sequence != expected_sequence:
            issues.append(
                f"Segment {segment.id} has non-canonical sequence {segment.sequence}"
            )
        if segment.endOffset <= segment.startOffset:
            issues.append(f"Segment {segment.id} has invalid offsets")
        if not segment.text.strip():
            issues.append(f"Segment {segment.id} has empty text")
        if not segment.isFinal:
            issues.append(f"Segment {segment.id} is not final")
    if not fixture.segments:
        issues.append("Fixture contains no segments")
    return issues


def write_fixture(fixture: CleanupFixture, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(fixture.to_dict(), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_cleanup_fixture(path: Path) -> CleanupFixture:
    payload = json.loads(path.read_text(encoding="utf-8"))
    fixture = CleanupFixture(
        fixtureID=str(payload["fixtureID"]),
        meetingID=str(payload["meetingID"]),
        durationSeconds=float(payload["durationSeconds"]),
        segments=tuple(CleanupSourceSegment(**item) for item in payload["segments"]),
    )
    issues = validate_fixture(fixture)
    if issues:
        raise CleanupBenchmarkError("Invalid cleanup fixture: " + "; ".join(issues))
    return fixture


def chunk_segments(
    segments: tuple[CleanupSourceSegment, ...],
    chunk_size: int,
) -> Iterable[tuple[CleanupSourceSegment, ...]]:
    if chunk_size <= 0:
        raise ValueError("Chunk size must be positive.")
    for start in range(0, len(segments), chunk_size):
        yield segments[start : start + chunk_size]


def build_cleanup_prompt(segments: tuple[CleanupSourceSegment, ...]) -> str:
    request = {
        "contractVersion": CONTRACT_VERSION,
        "segments": [
            {
                "index": index,
                "sourceText": segment.text,
            }
            for index, segment in enumerate(segments, start=1)
        ],
    }
    return (
        "You are a conservative editor of automatic speech-recognition transcript segments.\n"
        "Produce clean verbatim text, not a rewrite or summary. Fidelity is more important "
        "than fluency; when uncertain, make fewer changes.\n\n"
        "PRIORITIES\n"
        "1. Preserve every meaningful statement, clause, qualification, correction, "
        "comparison, and negation.\n"
        "2. Preserve every name, number, amount, date, and instance of profanity.\n"
        "3. Improve punctuation, capitalization, and readability.\n\n"
        "SEALED-SEGMENT RULES\n"
        "- Treat each numbered input item as a sealed container.\n"
        "- Return exactly one result for every input item, in the same order, and copy each "
        "numeric index exactly.\n"
        "- Edit only sourceText from that item. Never move, copy, borrow, or duplicate text "
        "across items.\n"
        "- Never add, omit, merge, or split items. Preserve boundaries even when an item "
        "begins or ends mid-sentence.\n"
        "- When an item ends mid-sentence, do not add words, an ellipsis, or terminal "
        "punctuation that makes the fragment appear complete.\n"
        "  Example: we stopped because must remain We stopped because, not We stopped "
        "because. or We stopped because...\n"
        "- Never return empty cleanedText or replace speech with an ellipsis.\n\n"
        "CONTENT RULES\n"
        "- Do not summarize, paraphrase, reorganize, improve the speaker's argument, add "
        "transitions, infer information, or invent facts.\n"
        "- Do not guess unclear words or names. No glossary is supplied, so retain every "
        "proper noun exactly as transcribed.\n"
        "- Preserve repetition used for emphasis, disagreement, or correction, such as "
        "no, no, no.\n\n"
        "ALLOWED EDITS\n"
        "- Correct punctuation and capitalization.\n"
        "- Remove an isolated filler such as um, uh, or er.\n"
        "- Remove an obvious abandoned word fragment.\n"
        "- Collapse a simple accidental stutter such as the the.\n"
        "- Make a small grammatical repair only when the intended wording is unambiguous.\n\n"
        "Before responding, silently compare each cleanedText with its own sourceText. "
        "Correct any loss, import, duplication, changed name, number, date, amount, negation, "
        "or profanity, empty value, ellipsis substitution, or boundary completion.\n"
        "Return JSON only. Use exactly this shape: "
        '{"contractVersion":1,"segments":[{"index":1,"cleanedText":"Cleaned speech."}]}.\n\n'
        f"Request JSON:\n{json.dumps(request, ensure_ascii=False, separators=(',', ':'))}"
    )


def _is_ellipsis_only(text: str) -> bool:
    """Return true only for a value made entirely from an ellipsis placeholder."""

    compact = re.sub(r"\s+", "", text)
    return re.fullmatch(r"(?:\.{3,}|…+)", compact) is not None


def _extract_json(raw: str) -> dict[str, object]:
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        cleaned = "\n".join(lines).strip()
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError as exc:
        match = re.search(r"\{[\s\S]*\}", cleaned)
        if match is None:
            reason = "cleanup_truncation" if "{" in cleaned else "cleanup_invalid_json"
            raise CleanupBenchmarkError(reason) from exc
        try:
            payload = json.loads(match.group(0))
        except json.JSONDecodeError as nested_exc:
            raise CleanupBenchmarkError("cleanup_invalid_json") from nested_exc
    if not isinstance(payload, dict):
        raise CleanupBenchmarkError("cleanup_invalid_json")
    return payload


def parse_cleanup_result(
    raw: str,
    source_segments: tuple[CleanupSourceSegment, ...],
) -> tuple[CleanedSegment, ...]:
    """Validate numbered model output, then attach trusted source IDs locally."""

    payload = _extract_json(raw)
    if payload.get("contractVersion") != CONTRACT_VERSION:
        raise CleanupBenchmarkError("cleanup_invalid_json")
    raw_segments = payload.get("segments")
    if not isinstance(raw_segments, list):
        raise CleanupBenchmarkError("cleanup_invalid_json")
    if len(raw_segments) != len(source_segments):
        raise CleanupBenchmarkError(
            "cleanup_wrong_count"
        )

    cleaned: list[CleanedSegment] = []
    for index, (source, item) in enumerate(zip(source_segments, raw_segments)):
        if not isinstance(item, dict):
            raise CleanupBenchmarkError("cleanup_invalid_index")
        generated_index = item.get("index")
        cleaned_text = item.get("cleanedText")
        if generated_index != index + 1:
            raise CleanupBenchmarkError("cleanup_invalid_index")
        if not isinstance(cleaned_text, str) or not cleaned_text.strip():
            raise CleanupBenchmarkError("cleanup_empty_text")
        if _is_ellipsis_only(cleaned_text):
            raise CleanupBenchmarkError("cleanup_placeholder_text")
        cleaned.append(CleanedSegment(source.id, cleaned_text.strip()))
    return tuple(cleaned)


def _hash_file(path: Path) -> SnapshotFile:
    digest = sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return SnapshotFile(
        path=path.name, sizeBytes=path.stat().st_size, sha256=digest.hexdigest()
    )


def _snapshot_roots(repo_id: str) -> tuple[Path, ...]:
    cache_name = f"models--{repo_id.replace('/', '--')}"
    candidates = (
        LLM_CACHE_ROOT / "hub" / cache_name,
        LLM_CACHE_ROOT / cache_name,
        Path.home() / ".cache" / "huggingface" / "hub" / cache_name,
    )
    unique: list[Path] = []
    for candidate in candidates:
        if candidate not in unique:
            unique.append(candidate)
    return tuple(unique)


def inspect_local_snapshot(
    repo_id: str = EXACT_MODEL_ID,
    *,
    cache_roots: tuple[Path, ...] | None = None,
) -> SnapshotInspection:
    """Resolve and verify every file required by an indexed safetensors model."""

    roots = cache_roots or _snapshot_roots(repo_id)
    revision = model_integrity.model_spec("gemma")["revision"]
    candidates: list[Path] = []
    if cache_roots is None:
        preferred = model_integrity.installed_path("gemma", MODEL_ROOT)
        if preferred.exists():
            candidates.append(preferred)
    for root in roots:
        snapshots = root / "snapshots"
        if (snapshots / revision).is_dir():
            candidates.append(snapshots / revision)
    if not candidates:
        return SnapshotInspection(
            repo_id, "", "", False, ("snapshot",), (), None, (), ()
        )
    snapshot = candidates[0]
    # Inspect only authenticated production bytes. Legacy HF blob links can
    # be materialized locally; cleanup never initiates a model download.
    if cache_roots is None:
        try:
            model_integrity.authenticate("gemma", snapshot)
        except model_integrity.ModelIntegrityError:
            snapshot = model_integrity.install("gemma", MODEL_ROOT,
                local_sources=tuple(root / "snapshots" / revision for root in roots),
                download_allowed=False)
    missing: list[str] = []
    warnings: list[str] = []

    config_path = snapshot / "config.json"
    config_file = _hash_file(config_path) if config_path.is_file() else None
    if config_file is None:
        missing.append("config.json")

    tokenizer_paths = sorted(
        path
        for name in ("tokenizer.json", "tokenizer.model", "tokenizer_config.json")
        if (path := snapshot / name).is_file()
    )
    if not tokenizer_paths:
        missing.append("tokenizer.json or tokenizer.model")

    weight_paths: list[Path] = []
    index_path = snapshot / "model.safetensors.index.json"
    single_weights = snapshot / "model.safetensors"
    if index_path.is_file():
        try:
            index_payload = json.loads(index_path.read_text(encoding="utf-8"))
            weight_map = index_payload.get("weight_map", {})
            expected_weights = (
                sorted(set(weight_map.values())) if isinstance(weight_map, dict) else []
            )
        except (OSError, json.JSONDecodeError, AttributeError, TypeError) as exc:
            expected_weights = []
            missing.append(f"readable model.safetensors.index.json ({exc})")
        missing_indexed_weights: list[str] = []
        for name in expected_weights:
            path = snapshot / str(name)
            if path.is_file() and path.stat().st_size > 0:
                weight_paths.append(path)
            else:
                missing_indexed_weights.append(str(name))
        if (
            missing_indexed_weights
            and single_weights.is_file()
            and single_weights.stat().st_size > 0
        ):
            weight_paths = [single_weights]
            warnings.append(
                "model.safetensors.index.json references absent shards; verified the repository's "
                "single model.safetensors artifact instead"
            )
        elif missing_indexed_weights:
            missing.extend(missing_indexed_weights)
        elif not expected_weights:
            if single_weights.is_file() and single_weights.stat().st_size > 0:
                weight_paths = [single_weights]
                warnings.append(
                    "Weight index is empty; verified model.safetensors instead"
                )
            else:
                missing.append("weight_map entries")
    else:
        if single_weights.is_file() and single_weights.stat().st_size > 0:
            weight_paths.append(single_weights)
        else:
            missing.append("model.safetensors or model.safetensors.index.json")

    return SnapshotInspection(
        repository=repo_id,
        revision=snapshot.name,
        snapshotPath=str(snapshot),
        complete=not missing,
        missingFiles=tuple(missing),
        warnings=tuple(warnings),
        config=config_file,
        tokenizerFiles=tuple(_hash_file(path) for path in tokenizer_paths),
        weightFiles=tuple(_hash_file(path) for path in weight_paths),
    )


class OfflineGuard(AbstractContextManager["OfflineGuard"]):
    """Fail closed and record any Python-level network attempt during inference."""

    _OFFLINE_ENV: ClassVar[dict[str, str]] = {
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
    }

    def __init__(self) -> None:
        self.attempts: list[str] = []
        self._original_env: dict[str, str | None] = {}
        self._original_connect = socket.socket.connect
        self._original_create_connection = socket.create_connection

    @staticmethod
    def _blocked_connect(_socket, address):  # type: ignore[no-untyped-def]
        guard: OfflineGuard = _ACTIVE_OFFLINE_GUARD[0]
        guard.attempts.append(repr(address))
        raise OfflineNetworkAttempt(
            f"Network access blocked during local benchmark: {address!r}"
        )

    @staticmethod
    def _blocked_create_connection(address, *args, **kwargs):  # type: ignore[no-untyped-def]
        guard: OfflineGuard = _ACTIVE_OFFLINE_GUARD[0]
        guard.attempts.append(repr(address))
        raise OfflineNetworkAttempt(
            f"Network access blocked during local benchmark: {address!r}"
        )

    def __enter__(self) -> Self:
        if _ACTIVE_OFFLINE_GUARD:
            raise RuntimeError("OfflineGuard cannot be nested.")
        _ACTIVE_OFFLINE_GUARD.append(self)
        for key, value in self._OFFLINE_ENV.items():
            self._original_env[key] = os.environ.get(key)
            os.environ[key] = value
        socket.socket.connect = self._blocked_connect  # type: ignore[method-assign]
        socket.create_connection = self._blocked_create_connection
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> bool:
        socket.socket.connect = self._original_connect  # type: ignore[method-assign]
        socket.create_connection = self._original_create_connection
        for key, previous in self._original_env.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous
        _ACTIVE_OFFLINE_GUARD.clear()
        return False


_ACTIVE_OFFLINE_GUARD: list[OfflineGuard] = []


def _command_output(command: list[str]) -> str:
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _swap_used_bytes() -> int | None:
    output = _command_output(["sysctl", "-n", "vm.swapusage"])
    match = re.search(r"used = ([0-9.]+)([MGT])", output)
    if match is None:
        return None
    multiplier = {"M": 1024**2, "G": 1024**3, "T": 1024**4}[match.group(2)]
    return int(float(match.group(1)) * multiplier)


def _memory_free_percent() -> float | None:
    output = _command_output(["memory_pressure", "-Q"])
    match = re.search(r"System-wide memory free percentage:\s*([0-9.]+)%", output)
    return float(match.group(1)) if match else None


def _rss_bytes() -> int | None:
    try:
        import psutil
    except ImportError:
        psutil = None
    if psutil is not None:
        try:
            return int(psutil.Process(os.getpid()).memory_info().rss)
        except psutil.Error:
            psutil = None
    output = _command_output(["ps", "-o", "rss=", "-p", str(os.getpid())])
    try:
        return int(output) * 1024
    except ValueError:
        return None


def _reset_mlx_peak_memory() -> None:
    try:
        import mlx.core as mx

        mx.reset_peak_memory()
    except (ImportError, AttributeError, RuntimeError):
        return


def _mlx_memory_metrics() -> dict[str, int | None]:
    try:
        import mlx.core as mx

        return {
            "mlxPeakMemoryBytes": int(mx.get_peak_memory()),
            "mlxActiveMemoryBytes": int(mx.get_active_memory()),
            "mlxCacheMemoryBytes": int(mx.get_cache_memory()),
        }
    except (ImportError, AttributeError, RuntimeError):
        return {
            "mlxPeakMemoryBytes": None,
            "mlxActiveMemoryBytes": None,
            "mlxCacheMemoryBytes": None,
        }


class PeakRSSSampler:
    def __init__(self, interval_seconds: float = 0.2) -> None:
        self.interval_seconds = interval_seconds
        self.peak_bytes = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self) -> None:
        while not self._stop.is_set():
            current = _rss_bytes()
            if current is not None:
                self.peak_bytes = max(self.peak_bytes, current)
            self._stop.wait(self.interval_seconds)

    def __enter__(self) -> Self:
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> bool:
        self._stop.set()
        self._thread.join(timeout=2)
        current = _rss_bytes()
        if current is not None:
            self.peak_bytes = max(self.peak_bytes, current)
        return False


Generator = Callable[[str, str, int], str]


def _mlx_generator(prompt: str, model_path: str, max_tokens: int) -> str:
    from .local_llm import generate_local_text

    result = generate_local_text(
        prompt,
        provider="mlx",
        model=model_path,
        max_tokens=max_tokens,
        json_mode=True,
        expected_model_key="gemma",
    )
    if result.provider != "mlx":
        raise CleanupBenchmarkError(f"Unexpected provider fallback: {result.provider}")
    return result.text


def run_fixture_once(
    fixture: CleanupFixture,
    *,
    model_path: str,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    generator: Generator = _mlx_generator,
) -> dict[str, object]:
    issues = validate_fixture(fixture)
    if issues:
        raise CleanupBenchmarkError("Invalid cleanup fixture: " + "; ".join(issues))

    started = time.monotonic()
    before_swap = _swap_used_bytes()
    before_pressure = _memory_free_percent()
    _reset_mlx_peak_memory()
    output_rows: list[dict[str, str]] = []
    chunks = tuple(chunk_segments(fixture.segments, chunk_size))
    guard = OfflineGuard()
    with PeakRSSSampler() as rss_sampler, guard:
        for chunk in chunks:
            prompt = build_cleanup_prompt(chunk)
            max_tokens = max(512, min(4096, sum(len(item.text) for item in chunk)))
            cleaned = parse_cleanup_result(
                generator(prompt, model_path, max_tokens), chunk
            )
            output_rows.extend(
                {
                    "sourceSegmentID": source.id,
                    "originalText": source.text,
                    "cleanedText": result.cleanedText,
                }
                for source, result in zip(chunk, cleaned)
            )
    elapsed = time.monotonic() - started
    after_swap = _swap_used_bytes()
    after_pressure = _memory_free_percent()
    return {
        "fixtureID": fixture.fixtureID,
        "durationSeconds": fixture.durationSeconds,
        "wallTimeSeconds": round(elapsed, 3),
        "peakResidentBytes": rss_sampler.peak_bytes,
        **_mlx_memory_metrics(),
        "memoryFreePercentBefore": before_pressure,
        "memoryFreePercentAfter": after_pressure,
        "swapUsedBytesBefore": before_swap,
        "swapUsedBytesAfter": after_swap,
        "swapGrowthBytes": (
            after_swap - before_swap
            if before_swap is not None and after_swap is not None
            else None
        ),
        "inputCharacters": sum(len(segment.text) for segment in fixture.segments),
        "outputCharacters": sum(len(row["cleanedText"]) for row in output_rows),
        "segmentCount": len(fixture.segments),
        "chunkSize": chunk_size,
        "chunkCount": len(chunks),
        "structurallyAligned": len(output_rows) == len(fixture.segments),
        "networkAttempts": list(guard.attempts),
        "segments": output_rows,
    }


def _progressively_worsening(values: list[int], floor: int) -> bool:
    if len(values) < 3:
        return False
    monotonic = all(current >= previous for previous, current in pairwise(values))
    proportional_floor = int(values[0] * 0.10)
    return monotonic and values[-1] - values[0] > max(floor, proportional_floor)


def evaluate_runs(runs: list[dict[str, object]]) -> dict[str, object]:
    sixty_minute_runs = [run for run in runs if run["durationSeconds"] == 3600.0]
    durations = sorted({float(run["durationSeconds"]) for run in runs})
    rss_progressive = any(
        _progressively_worsening(
            [
                int(run["peakResidentBytes"])
                for run in runs
                if float(run["durationSeconds"]) == duration
            ],
            RSS_GROWTH_FLOOR_BYTES,
        )
        for duration in durations
    )
    swap_progressive = any(
        _progressively_worsening(
            [
                int(value)
                for run in runs
                if float(run["durationSeconds"]) == duration
                and (value := run.get("swapUsedBytesAfter")) is not None
            ],
            SWAP_GROWTH_FLOOR_BYTES,
        )
        for duration in durations
    )
    strictly_under_budget = (
        all(
            float(run["wallTimeSeconds"]) < PERFORMANCE_GATE_SECONDS
            for run in sixty_minute_runs
        )
        if sixty_minute_runs
        else None
    )
    within_accepted_boundary = (
        all(
            float(run["wallTimeSeconds"])
            < PERFORMANCE_GATE_SECONDS + PERFORMANCE_GATE_TOLERANCE_SECONDS
            for run in sixty_minute_runs
        )
        if sixty_minute_runs
        else None
    )
    return {
        "sixtyMinuteStrictlyUnderFiveMinutes": strictly_under_budget,
        "sixtyMinutePerformanceGateAccepted": within_accepted_boundary,
        "allStructurallyAligned": all(bool(run["structurallyAligned"]) for run in runs),
        "noNetworkAttempts": all(not run["networkAttempts"] for run in runs),
        "progressivePeakRSSGrowth": rss_progressive,
        "progressiveSwapGrowth": swap_progressive,
    }


def environment_record() -> dict[str, object]:
    memory = _command_output(["sysctl", "-n", "hw.memsize"])
    cpu = _command_output(["sysctl", "-n", "machdep.cpu.brand_string"])
    package_versions: dict[str, str | None] = {}
    for package in ("mlx", "mlx-lm", "transformers", "huggingface-hub", "psutil"):
        try:
            package_versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            package_versions[package] = None
    return {
        "platform": platform.platform(),
        "macOSVersion": platform.mac_ver()[0],
        "machine": platform.machine(),
        "cpu": cpu,
        "physicalMemoryBytes": int(memory) if memory.isdigit() else None,
        "python": platform.python_version(),
        "pythonExecutable": os.sys.executable,
        "packages": package_versions,
        "osNetworkSandbox": os.environ.get("OPENBRIDGE_NETWORK_SANDBOX"),
    }


def benchmark_suite(
    fixtures: tuple[CleanupFixture, ...],
    *,
    runs_per_fixture: int,
    chunk_size: int,
    snapshot: SnapshotInspection,
    generator: Generator = _mlx_generator,
    progress: Callable[[str], None] | None = None,
) -> dict[str, object]:
    if not snapshot.complete:
        return {
            "benchmarkVersion": 1,
            "environment": environment_record(),
            "model": snapshot.to_dict(),
            "runs": [],
            "gates": {},
            "decision": "Reject",
            "decisionReasons": [
                "The exact local model snapshot is incomplete: "
                + ", ".join(snapshot.missingFiles)
            ],
        }
    if runs_per_fixture < 1:
        raise ValueError("runs_per_fixture must be positive.")

    all_runs: list[dict[str, object]] = []
    for run_number in range(1, runs_per_fixture + 1):
        for fixture in fixtures:
            try:
                run = run_fixture_once(
                    fixture,
                    model_path=snapshot.snapshotPath,
                    chunk_size=chunk_size,
                    generator=generator,
                )
            # Preserve arbitrary loader/generator failures as benchmark evidence.
            except Exception as exc:  # noqa: BLE001
                failure_type = type(exc).__name__
                decision = (
                    "Revise" if isinstance(exc, CleanupBenchmarkError) else "Reject"
                )
                return {
                    "benchmarkVersion": 1,
                    "environment": environment_record(),
                    "model": snapshot.to_dict(),
                    "recommendedChunkSizeSegments": chunk_size,
                    "runsPerFixture": runs_per_fixture,
                    "runs": all_runs,
                    "gates": {},
                    "decision": decision,
                    "decisionReasons": [
                        (
                            f"Real offline inference failed for {fixture.fixtureID}: "
                            f"{failure_type}: {exc}"
                        )
                    ],
                    "inferenceFailure": {
                        "fixtureID": fixture.fixtureID,
                        "repetition": run_number,
                        "type": failure_type,
                        "message": str(exc),
                    },
                }
            run["repetition"] = run_number
            all_runs.append(run)
            if progress is not None:
                progress(
                    f"Completed {fixture.fixtureID} repetition {run_number}/{runs_per_fixture}: "
                    f"{run['wallTimeSeconds']}s, peak RSS {int(run['peakResidentBytes']) / 1024**3:.2f} GiB, "
                    f"swap growth {int(run.get('swapGrowthBytes') or 0) / 1024**2:.0f} MiB"
                )
    gates = evaluate_runs(all_runs)
    measured_durations = {float(run["durationSeconds"]) for run in all_runs}
    coverage_complete = measured_durations == {900.0, 3600.0} and runs_per_fixture >= 3
    gates["coverageComplete"] = coverage_complete
    required_boolean_gates = (
        "sixtyMinutePerformanceGateAccepted",
        "allStructurallyAligned",
        "noNetworkAttempts",
    )
    failed = [name for name in required_boolean_gates if gates.get(name) is False]
    if gates.get("progressivePeakRSSGrowth"):
        failed.append("progressivePeakRSSGrowth")
    if gates.get("progressiveSwapGrowth"):
        failed.append("progressiveSwapGrowth")
    if not coverage_complete:
        decision = "Incomplete"
        failed = ["coverageComplete"] + [
            name for name in failed if name != "coverageComplete"
        ]
    else:
        decision = "Build" if not failed else "Revise"
    return {
        "benchmarkVersion": 1,
        "environment": environment_record(),
        "model": snapshot.to_dict(),
        "contract": {
            "version": CONTRACT_VERSION,
            "input": "ordered final MeetingTranscriptSegment records",
            "output": "one ordered sourceSegmentID + cleanedText record per input",
            "originalTextPreservedInBenchmarkRecord": True,
            "confidenceScoresRequired": False,
        },
        "performanceGate": {
            "targetSeconds": PERFORMANCE_GATE_SECONDS,
            "acceptedMeasurementToleranceSeconds": PERFORMANCE_GATE_TOLERANCE_SECONDS,
            "rawMeasurementsRetained": True,
        },
        "recommendedChunkSizeSegments": chunk_size,
        "runsPerFixture": runs_per_fixture,
        "runs": all_runs,
        "gates": gates,
        "decision": decision,
        "decisionReasons": [f"Failed gate: {name}" for name in failed],
    }


def write_report(report: dict[str, object], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
