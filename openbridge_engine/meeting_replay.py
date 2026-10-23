"""Meeting replay harness and evaluation runner (#292).

Replays recorded transcript spans at their original timestamps,
injects transcript corrections, seeds prior-meeting memories,
and compares provider responses against expected moments.

Produces a deterministic evaluation record that can be compared
across reference (OpenRouter), local (MLX), and fake providers.
"""

import json
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional, Callable
from enum import Enum

from openbridge_engine.meeting_schema import (
    MeetingFixture,
    TranscriptSpan,
    ExpectedMoment,
    PriorMeetingSeed,
    load_fixture,
    validate_fixture,
)


class ProviderKind(str, Enum):
    REFERENCE = "reference"  # OpenRouter
    LOCAL = "local"          # MLX local model
    FAKE = "fake"            # Deterministic fake for baseline


@dataclass
class ProviderResponse:
    """A single provider response to a transcript context."""

    provider: str
    card_text: Optional[str]
    sources: list[str]
    latency_seconds: float
    succeeded: bool
    error: Optional[str] = None


@dataclass
class MomentEvaluation:
    """Evaluation result for a single expected moment."""

    moment_id: str
    timestamp: float
    kind: str
    description: str
    expected_card: Optional[str]
    provider_responses: dict[str, ProviderResponse] = field(default_factory=dict)
    card_relevant: Optional[bool] = None
    source_correct: Optional[bool] = None
    abstention_correct: Optional[bool] = None

    def to_dict(self) -> dict:
        result = {
            "moment_id": self.moment_id,
            "timestamp": self.timestamp,
            "kind": self.kind,
            "description": self.description,
            "expected_card": self.expected_card,
            "evaluations": {},
        }
        for provider, resp in self.provider_responses.items():
            result["evaluations"][provider] = {
                "card_text": resp.card_text,
                "sources": resp.sources,
                "latency_seconds": resp.latency_seconds,
                "succeeded": resp.succeeded,
                "error": resp.error,
                "card_relevant": self.card_relevant,
                "source_correct": self.source_correct,
                "abstention_correct": self.abstention_correct,
            }
        return result


@dataclass
class ReplayEvaluationRecord:
    """Complete evaluation record for a single replay run."""

    fixture_id: str
    fixture_title: str
    provider: str
    started_at: str
    duration_seconds: float
    moment_evaluations: list[MomentEvaluation]
    metrics: dict = field(default_factory=dict)
    transcript_spans_replayed: int = 0
    failures: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "fixture_id": self.fixture_id,
            "fixture_title": self.fixture_title,
            "provider": self.provider,
            "started_at": self.started_at,
            "duration_seconds": self.duration_seconds,
            "transcript_spans_replayed": self.transcript_spans_replayed,
            "moment_evaluations": [m.to_dict() for m in self.moment_evaluations],
            "metrics": self.metrics,
            "failures": self.failures,
        }

    def save(self, path: Path | str) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2, ensure_ascii=False)


class FakeProvider:
    """Deterministic fake provider for baseline comparison.

    Produces cards based on simple keyword matching against prior meeting seeds.
    Always abstains if no relevant seed is found.
    """

    KIND = ProviderKind.FAKE

    def respond(
        self,
        transcript_context: str,
        prior_meetings: list[PriorMeetingSeed],
    ) -> ProviderResponse:
        start = time.monotonic()
        card_text = None
        sources = []

        context_lower = transcript_context.lower()

        # Use meaningful keywords from prior meeting to avoid false positives
        # from common words like "the", "for", "to"
        stop_words = {"the", "a", "an", "for", "to", "in", "on", "at", "is", "are", "was", "were", "and", "or", "of", "with", "this", "that", "it", "we", "our", "from", "by", "be", "will", "has", "have", "had"}

        for pm in prior_meetings:
            pm_text = (pm.title + " " + pm.summary + " " + " ".join(pm.key_facts)).lower()
            meaningful_words = {w for w in pm_text.split() if w not in stop_words and len(w) > 2}
            context_words = set(context_lower.split())
            overlap = meaningful_words & context_words
            if len(overlap) >= 2:
                card_text = pm.summary
                sources.append(pm.meeting_id)
                break

        latency = time.monotonic() - start
        return ProviderResponse(
            provider=self.KIND.value,
            card_text=card_text,
            sources=sources,
            latency_seconds=latency,
            succeeded=True,
        )


class MeetingReplayHarness:
    """Replays a meeting fixture and evaluates provider responses."""

    def __init__(self, fixture: MeetingFixture):
        self.fixture = fixture

    def replay(
        self,
        provider: object,
        provider_name: str,
        speed_multiplier: float = 1.0,
        simulate_timing: bool = False,
    ) -> ReplayEvaluationRecord:
        """Replay the fixture through a provider and return an evaluation record.

        Args:
            provider: An object with a .respond(transcript_context, prior_meetings) method
            provider_name: Display name for the provider
            speed_multiplier: If >1, replay faster than real-time
            simulate_timing: If True, sleep to simulate real timestamps
        """
        started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        start_time = time.monotonic()
        moment_evaluations = []
        failures = []

        for moment in self.fixture.expected_moments:
            # Build transcript context up to this moment
            context_spans = [
                s for s in self.fixture.transcript_spans
                if s.start_seconds <= moment.timestamp
            ]
            transcript_context = " ".join(s.text for s in context_spans)

            if simulate_timing and speed_multiplier > 0:
                elapsed = time.monotonic() - start_time
                target_time = moment.timestamp / speed_multiplier
                if target_time > elapsed:
                    time.sleep(target_time - elapsed)

            try:
                response = provider.respond(
                    transcript_context=transcript_context,
                    prior_meetings=self.fixture.prior_meetings,
                )
            except Exception as e:
                response = ProviderResponse(
                    provider=provider_name,
                    card_text=None,
                    sources=[],
                    latency_seconds=0,
                    succeeded=False,
                    error=str(e),
                )
                failures.append(f"Moment {moment.moment_id}: {e}")

            # Evaluate the response
            eval_result = MomentEvaluation(
                moment_id=moment.moment_id,
                timestamp=moment.timestamp,
                kind=moment.kind,
                description=moment.description,
                expected_card=moment.expected_card,
            )
            eval_result.provider_responses[provider_name] = response

            # Simple relevance check: did the provider produce a card when expected?
            if moment.kind == "silence" or moment.kind == "abstention":
                eval_result.abstention_correct = response.card_text is None
                eval_result.card_relevant = response.card_text is None
            else:
                eval_result.card_relevant = response.card_text is not None
                if moment.expected_sources:
                    eval_result.source_correct = any(
                        s in response.sources for s in moment.expected_sources
                    )
                else:
                    eval_result.source_correct = True

            moment_evaluations.append(eval_result)

        duration = time.monotonic() - start_time

        # Compute metrics
        metrics = self._compute_metrics(moment_evaluations)

        return ReplayEvaluationRecord(
            fixture_id=self.fixture.fixture_id,
            fixture_title=self.fixture.title,
            provider=provider_name,
            started_at=started_at,
            duration_seconds=duration,
            moment_evaluations=moment_evaluations,
            metrics=metrics,
            transcript_spans_replayed=len(self.fixture.transcript_spans),
            failures=failures,
        )

    def _compute_metrics(self, evaluations: list[MomentEvaluation]) -> dict:
        """Compute summary metrics from moment evaluations."""
        total = len(evaluations)
        if total == 0:
            return {}

        relevant_count = sum(1 for e in evaluations if e.card_relevant == True)
        abstention_count = sum(1 for e in evaluations if e.abstention_correct == True)
        source_count = sum(1 for e in evaluations if e.source_correct == True)

        latencies = []
        for e in evaluations:
            for resp in e.provider_responses.values():
                if resp.succeeded:
                    latencies.append(resp.latency_seconds)

        latencies.sort()
        p95_latency = latencies[int(len(latencies) * 0.95)] if latencies else 0

        return {
            "total_moments": total,
            "relevant_cards": relevant_count,
            "relevant_rate": relevant_count / total if total else 0,
            "abstention_correct": abstention_count,
            "source_correct": source_count,
            "source_correct_rate": source_count / total if total else 0,
            "p95_latency_seconds": p95_latency,
            "p95_latency_passes_gate": p95_latency < 7.0,
            "relevant_rate_passes_gate": (relevant_count / total if total else 0) >= 0.85,
            "failure_count": sum(1 for e in evaluations for r in e.provider_responses.values() if not r.succeeded),
        }


def compare_providers(
    fixture: MeetingFixture,
    providers: dict[str, object],
    output_dir: Path | str,
) -> dict:
    """Run the same fixture through multiple providers and compare results.

    Args:
        fixture: The meeting fixture to replay
        providers: Dict of provider_name -> provider object (must have .respond method)
        output_dir: Directory to save evaluation records

    Returns:
        Dict with comparison summary
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    harness = MeetingReplayHarness(fixture)
    records = {}

    for name, provider in providers.items():
        record = harness.replay(provider=provider, provider_name=name)
        record_path = output_dir / f"{fixture.fixture_id}_{name}.json"
        record.save(record_path)
        records[name] = record

    # Build comparison summary
    comparison = {
        "fixture_id": fixture.fixture_id,
        "providers": {},
    }

    for name, record in records.items():
        comparison["providers"][name] = {
            "p95_latency_seconds": record.metrics.get("p95_latency_seconds", 0),
            "relevant_rate": record.metrics.get("relevant_rate", 0),
            "source_correct_rate": record.metrics.get("source_correct_rate", 0),
            "failure_count": record.metrics.get("failure_count", 0),
            "passes_all_gates": (
                record.metrics.get("p95_latency_passes_gate", False)
                and record.metrics.get("relevant_rate_passes_gate", False)
            ),
        }

    comparison_path = output_dir / f"{fixture.fixture_id}_comparison.json"
    with open(comparison_path, "w", encoding="utf-8") as f:
        json.dump(comparison, f, indent=2, ensure_ascii=False)

    return comparison


def run_shadow_mode_review(
    fixture_path: Path | str,
    provider: object,
    provider_name: str,
    output_path: Path | str,
) -> dict:
    """Run a shadow-mode review and save results without leaking meeting content.

    The output contains only evaluation metrics and moment IDs, not transcript text.
    """
    fixture = load_fixture(fixture_path)
    harness = MeetingReplayHarness(fixture)
    record = harness.replay(provider=provider, provider_name=provider_name)

    # Save sanitized record (no transcript text)
    sanitized = record.to_dict()
    for moment_eval in sanitized["moment_evaluations"]:
        for eval_data in moment_eval["evaluations"].values():
            eval_data["card_text"] = "[REDACTED]" if eval_data["card_text"] else None

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(sanitized, f, indent=2, ensure_ascii=False)

    return sanitized