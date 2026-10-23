"""Production adapter for the accepted CLEAN-00 meeting-cleanup contract.

The benchmark module remains the executable source of truth for prompt shape,
alignment validation, exact snapshot inspection, and Python-level network
denial. Production deliberately consumes those same functions so it cannot
silently diverge from the evidence accepted in issue #319.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .meeting_cleanup_benchmark import (
    CONTRACT_VERSION,
    DEFAULT_CHUNK_SIZE,
    EXACT_MODEL_ID,
    CleanedSegment,
    CleanupBenchmarkError,
    CleanupSourceSegment,
    OfflineGuard,
    SnapshotInspection,
    _mlx_generator,
    build_cleanup_prompt,
    chunk_segments,
    inspect_local_snapshot,
    parse_cleanup_result,
)

Generator = Callable[[str, str, int], str]


def _clean_chunk_with_single_segment_recovery(
    chunk: tuple[CleanupSourceSegment, ...],
    *,
    generator: Generator,
    snapshot_path: str,
    max_tokens: int,
) -> tuple[CleanedSegment, ...]:
    first_response = generator(build_cleanup_prompt(chunk), snapshot_path, max_tokens)
    try:
        return parse_cleanup_result(first_response, chunk)
    except CleanupBenchmarkError:
        # One batch attempt, then a bounded fallback of at most one request
        # per source segment. We do not feed rejected model output back into
        # the model and never guess which source ID a result belongs to.
        recovered: list[CleanedSegment] = []
        for segment in chunk:
            single = (segment,)
            response = generator(
                build_cleanup_prompt(single),
                snapshot_path,
                min(4096, max(256, len(segment.text) * 2)),
            )
            recovered.extend(parse_cleanup_result(response, single))
        return tuple(recovered)


def _parse_source_segments(payload: object) -> tuple[CleanupSourceSegment, ...]:
    if not isinstance(payload, list) or not payload:
        raise CleanupBenchmarkError("Cleanup request segments must be a non-empty list.")

    segments: list[CleanupSourceSegment] = []
    seen_ids: set[str] = set()
    previous_sequence: int | None = None
    meeting_id: str | None = None
    for index, item in enumerate(payload):
        if not isinstance(item, dict):
            raise CleanupBenchmarkError(f"Source segment {index} must be an object.")
        try:
            source_id = item["id"]
            item_meeting_id = item["meetingID"]
            sequence = item["sequence"]
            source_label = item["sourceLabel"]
            text = item["text"]
            is_final = item["isFinal"]
        except KeyError as exc:
            raise CleanupBenchmarkError(
                f"Source segment {index} is missing {exc.args[0]}."
            ) from exc

        if not isinstance(source_id, str) or not source_id:
            raise CleanupBenchmarkError(f"Source segment {index} has an invalid ID.")
        if source_id in seen_ids:
            raise CleanupBenchmarkError(f"Duplicate source segment ID: {source_id}")
        if not isinstance(item_meeting_id, str) or not item_meeting_id:
            raise CleanupBenchmarkError(f"Source segment {source_id} has no meeting ID.")
        if meeting_id is None:
            meeting_id = item_meeting_id
        elif item_meeting_id != meeting_id:
            raise CleanupBenchmarkError("All source segments must belong to one meeting.")
        if not isinstance(sequence, int) or isinstance(sequence, bool):
            raise CleanupBenchmarkError(f"Source segment {source_id} has an invalid sequence.")
        if previous_sequence is not None and sequence <= previous_sequence:
            raise CleanupBenchmarkError("Source segments must be in stable sequence order.")
        if not isinstance(source_label, str) or not source_label:
            raise CleanupBenchmarkError(f"Source segment {source_id} has no source label.")
        if not isinstance(text, str) or not text.strip():
            raise CleanupBenchmarkError(f"Source segment {source_id} has empty text.")
        if is_final is not True:
            raise CleanupBenchmarkError(f"Source segment {source_id} is not final.")

        seen_ids.add(source_id)
        previous_sequence = sequence
        segments.append(
            CleanupSourceSegment(
                id=source_id,
                meetingID=item_meeting_id,
                sequence=sequence,
                startOffset=item.get("startOffset"),
                endOffset=item.get("endOffset"),
                sourceLabel=source_label,
                text=text,
                isFinal=True,
            )
        )
    return tuple(segments)


def cleanup_meeting_segments(
    request: object,
    *,
    generator: Generator = _mlx_generator,
    snapshot: SnapshotInspection | None = None,
) -> dict[str, Any]:
    """Run exact-model, offline cleanup and return a strictly aligned result."""

    if not isinstance(request, dict):
        raise CleanupBenchmarkError("Cleanup request must be a JSON object.")
    if request.get("contractVersion") != CONTRACT_VERSION:
        raise CleanupBenchmarkError("Cleanup request has the wrong contractVersion.")
    if request.get("modelRepository") != EXACT_MODEL_ID:
        raise CleanupBenchmarkError(f"Cleanup requires the exact model {EXACT_MODEL_ID}.")
    if request.get("chunkSize") != DEFAULT_CHUNK_SIZE:
        raise CleanupBenchmarkError(
            f"Cleanup requires the accepted chunk size {DEFAULT_CHUNK_SIZE}."
        )

    source_segments = _parse_source_segments(request.get("segments"))
    local_snapshot = snapshot or inspect_local_snapshot(EXACT_MODEL_ID)
    if local_snapshot.repository != EXACT_MODEL_ID:
        raise CleanupBenchmarkError("Resolved snapshot belongs to the wrong model repository.")
    if not local_snapshot.complete:
        missing = ", ".join(local_snapshot.missingFiles)
        raise CleanupBenchmarkError(f"The exact local model snapshot is incomplete: {missing}")

    cleaned_segments: list[CleanedSegment] = []
    guard = OfflineGuard()
    with guard:
        for chunk in chunk_segments(source_segments, DEFAULT_CHUNK_SIZE):
            max_tokens = max(512, min(4096, sum(len(item.text) for item in chunk)))
            cleaned_segments.extend(
                _clean_chunk_with_single_segment_recovery(
                    chunk,
                    generator=generator,
                    snapshot_path=local_snapshot.snapshotPath,
                    max_tokens=max_tokens,
                )
            )
    if guard.attempts:
        raise CleanupBenchmarkError("Cleanup attempted network access.")

    return {
        "contractVersion": CONTRACT_VERSION,
        "modelRepository": EXACT_MODEL_ID,
        "modelRevision": local_snapshot.revision,
        "chunkSize": DEFAULT_CHUNK_SIZE,
        "segments": [
            {
                "sourceSegmentID": segment.sourceSegmentID,
                "cleanedText": segment.cleanedText,
            }
            for segment in cleaned_segments
        ],
    }
