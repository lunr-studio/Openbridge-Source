"""Meeting replay fixture schema and validation.

Defines the JSON format for deterministic meeting replay fixtures
used by the V3 evaluation harness (#292).

A fixture describes:
- Metadata about the meeting scenario
- Transcript spans with timestamps
- Expected intervention/silence moments
- Prior-meeting memory seeds
- Corrected/expected final transcript
"""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass(frozen=True)
class TranscriptSpan:
    """A stable transcript span at a specific meeting timestamp."""

    text: str
    start_seconds: float
    end_seconds: float
    speaker_label: str = "Room"
    span_id: str = ""
    corrections: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class ExpectedMoment:
    """An expected outcome at a specific point in the meeting.

    Used to evaluate whether the system correctly intervened or abstained.
    """

    timestamp: float
    kind: str  # silence, explicit_answer, prior_context, decision, action, correction, abstention
    description: str
    expected_card: Optional[str] = None  # What the card should say (if any)
    expected_sources: list[str] = field(default_factory=list)  # Source IDs that should be cited
    moment_id: str = ""


@dataclass(frozen=True)
class PriorMeetingSeed:
    """A seeded memory from a prior meeting for context retrieval testing."""

    meeting_id: str
    title: str
    summary: str
    key_facts: list[str] = field(default_factory=list)
    transcript_excerpts: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class MeetingFixture:
    """A complete replay fixture for a scripted meeting scenario."""

    fixture_id: str
    title: str
    description: str
    workspace_id: str
    duration_seconds: float
    transcript_spans: list[TranscriptSpan]
    expected_moments: list[ExpectedMoment]
    prior_meetings: list[PriorMeetingSeed] = field(default_factory=list)
    corrected_transcript: Optional[str] = None
    audio_file: Optional[str] = None  # Relative path to audio fixture


def load_fixture(path: Path | str) -> MeetingFixture:
    """Load a meeting replay fixture from a JSON file."""
    path = Path(path)
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    spans = [
        TranscriptSpan(
            text=s["text"],
            start_seconds=s["start_seconds"],
            end_seconds=s["end_seconds"],
            speaker_label=s.get("speaker_label", "Room"),
            span_id=s.get("span_id", ""),
            corrections=s.get("corrections", []),
        )
        for s in data.get("transcript_spans", [])
    ]

    moments = [
        ExpectedMoment(
            timestamp=m["timestamp"],
            kind=m["kind"],
            description=m["description"],
            expected_card=m.get("expected_card"),
            expected_sources=m.get("expected_sources", []),
            moment_id=m.get("moment_id", ""),
        )
        for m in data.get("expected_moments", [])
    ]

    priors = [
        PriorMeetingSeed(
            meeting_id=p["meeting_id"],
            title=p["title"],
            summary=p["summary"],
            key_facts=p.get("key_facts", []),
            transcript_excerpts=p.get("transcript_excerpts", []),
        )
        for p in data.get("prior_meetings", [])
    ]

    return MeetingFixture(
        fixture_id=data["fixture_id"],
        title=data["title"],
        description=data["description"],
        workspace_id=data["workspace_id"],
        duration_seconds=data["duration_seconds"],
        transcript_spans=spans,
        expected_moments=moments,
        prior_meetings=priors,
        corrected_transcript=data.get("corrected_transcript"),
        audio_file=data.get("audio_file"),
    )


def validate_fixture(path: Path | str) -> list[str]:
    """Validate a fixture file and return a list of issues (empty if valid)."""
    path = Path(path)
    issues = []

    try:
        fixture = load_fixture(path)
    except Exception as e:
        return [f"Failed to load fixture: {e}"]

    if not fixture.fixture_id:
        issues.append("Missing fixture_id")

    if fixture.duration_seconds <= 0:
        issues.append(f"Invalid duration_seconds: {fixture.duration_seconds}")

    if not fixture.transcript_spans:
        issues.append("No transcript spans defined")

    for i, span in enumerate(fixture.transcript_spans):
        if span.start_seconds < 0:
            issues.append(f"Span {i} has negative start_seconds")
        if span.end_seconds < span.start_seconds:
            issues.append(f"Span {i} end before start")
        if not span.text.strip():
            issues.append(f"Span {i} has empty text")

    valid_kinds = {
        "silence", "explicit_answer", "prior_context", "decision",
        "action", "correction", "abstention",
    }
    for i, moment in enumerate(fixture.expected_moments):
        if moment.kind not in valid_kinds:
            issues.append(f"Moment {i} has invalid kind: {moment.kind}")
        if moment.timestamp < 0 or moment.timestamp > fixture.duration_seconds:
            issues.append(f"Moment {i} timestamp {moment.timestamp} outside meeting duration")

    return issues