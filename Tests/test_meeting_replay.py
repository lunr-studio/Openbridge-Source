"""Tests for the meeting replay harness and fixture schema (#292)."""

import json
import os
import tempfile
import unittest
from pathlib import Path

from openbridge_engine.meeting_schema import (
    TranscriptSpan,
    ExpectedMoment,
    PriorMeetingSeed,
    MeetingFixture,
    load_fixture,
    validate_fixture,
)
from openbridge_engine.meeting_replay import (
    FakeProvider,
    MeetingReplayHarness,
    compare_providers,
    run_shadow_mode_review,
    ProviderResponse,
    ProviderKind,
)

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "meeting_planning_session.json"


class TestMeetingSchema(unittest.TestCase):
    """Test fixture loading and validation."""

    def test_load_fixture(self):
        fixture = load_fixture(FIXTURE_PATH)
        self.assertEqual(fixture.fixture_id, "planning-session-v1")
        self.assertEqual(fixture.workspace_id, "ws-test-001")
        self.assertEqual(len(fixture.transcript_spans), 10)
        self.assertEqual(len(fixture.expected_moments), 7)
        self.assertEqual(len(fixture.prior_meetings), 2)

    def test_fixture_spans_have_timestamps(self):
        fixture = load_fixture(FIXTURE_PATH)
        for span in fixture.transcript_spans:
            self.assertGreaterEqual(span.start_seconds, 0)
            self.assertGreater(span.end_seconds, span.start_seconds)
            self.assertTrue(span.text.strip())

    def test_fixture_moments_have_valid_kinds(self):
        fixture = load_fixture(FIXTURE_PATH)
        valid_kinds = {"silence", "explicit_answer", "prior_context", "decision", "action", "correction", "abstention"}
        for moment in fixture.expected_moments:
            self.assertIn(moment.kind, valid_kinds)

    def test_validate_fixture_clean(self):
        issues = validate_fixture(FIXTURE_PATH)
        self.assertEqual(issues, [], f"Fixture validation issues: {issues}")

    def test_validate_bad_fixture(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"fixture_id": "", "duration_seconds": -1}, f)
            bad_path = f.name
        try:
            issues = validate_fixture(bad_path)
            self.assertGreater(len(issues), 0)
        finally:
            os.unlink(bad_path)

    def test_prior_meetings_have_required_fields(self):
        fixture = load_fixture(FIXTURE_PATH)
        for pm in fixture.prior_meetings:
            self.assertTrue(pm.meeting_id)
            self.assertTrue(pm.title)
            self.assertTrue(pm.summary)


class TestFakeProvider(unittest.TestCase):
    """Test the deterministic fake provider."""

    def setUp(self):
        self.fixture = load_fixture(FIXTURE_PATH)
        self.provider = FakeProvider()

    def test_responds_to_pricing_context(self):
        context = "What did we decide about the pricing tier change last quarter?"
        response = self.provider.respond(context, self.fixture.prior_meetings)
        self.assertIsNotNone(response.card_text)
        self.assertIn("prior-pricing-review-2026q3", response.sources)

    def test_abstains_on_irrelevant_context(self):
        context = "Nice weather today."
        response = self.provider.respond(context, self.fixture.prior_meetings)
        self.assertIsNone(response.card_text)
        self.assertEqual(response.sources, [])

    def test_always_succeeds(self):
        response = self.provider.respond("any text", [])
        self.assertTrue(response.succeeded)
        self.assertGreaterEqual(response.latency_seconds, 0)


class TestMeetingReplayHarness(unittest.TestCase):
    """Test the replay harness with the fake provider."""

    def setUp(self):
        self.fixture = load_fixture(FIXTURE_PATH)
        self.harness = MeetingReplayHarness(self.fixture)
        self.provider = FakeProvider()

    def test_replay_produces_evaluation_record(self):
        record = self.harness.replay(self.provider, "fake")
        self.assertEqual(record.fixture_id, "planning-session-v1")
        self.assertEqual(record.provider, "fake")
        self.assertEqual(len(record.moment_evaluations), 7)
        self.assertEqual(record.transcript_spans_replayed, 10)

    def test_replay_metrics_computed(self):
        record = self.harness.replay(self.provider, "fake")
        self.assertIn("total_moments", record.metrics)
        self.assertIn("p95_latency_seconds", record.metrics)
        self.assertIn("relevant_rate", record.metrics)
        self.assertIn("relevant_rate_passes_gate", record.metrics)

    def test_silence_moment_evaluated_as_abstention(self):
        record = self.harness.replay(self.provider, "fake")
        silence_moments = [e for e in record.moment_evaluations if e.kind == "silence"]
        self.assertGreater(len(silence_moments), 0)
        for m in silence_moments:
            self.assertIsNotNone(m.abstention_correct)

    def test_prior_context_moment_has_source(self):
        record = self.harness.replay(self.provider, "fake")
        context_moments = [e for e in record.moment_evaluations if e.kind == "prior_context"]
        self.assertGreater(len(context_moments), 0)

    def test_evaluation_record_serializes(self):
        record = self.harness.replay(self.provider, "fake")
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "eval.json"
            record.save(path)
            self.assertTrue(path.exists())
            with open(path) as f:
                data = json.load(f)
            self.assertEqual(data["fixture_id"], "planning-session-v1")

    def test_no_failures_with_fake_provider(self):
        record = self.harness.replay(self.provider, "fake")
        self.assertEqual(record.failures, [])


class TestCompareProviders(unittest.TestCase):
    """Test multi-provider comparison."""

    def test_compare_fake_with_itself(self):
        fixture = load_fixture(FIXTURE_PATH)
        providers = {"fake": FakeProvider(), "fake2": FakeProvider()}
        with tempfile.TemporaryDirectory() as tmpdir:
            comparison = compare_providers(fixture, providers, tmpdir)
            self.assertIn("fake", comparison["providers"])
            self.assertIn("fake2", comparison["providers"])
            self.assertIn("passes_all_gates", comparison["providers"]["fake"])
            # Check files were written
            self.assertTrue((Path(tmpdir) / "planning-session-v1_comparison.json").exists())


class TestShadowModeReview(unittest.TestCase):
    """Test shadow-mode review sanitization."""

    def test_shadow_mode_redacts_card_text(self):
        provider = FakeProvider()
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "shadow.json"
            result = run_shadow_mode_review(FIXTURE_PATH, provider, "fake", output_path)
            for moment_eval in result["moment_evaluations"]:
                for eval_data in moment_eval["evaluations"].values():
                    if eval_data["card_text"]:
                        self.assertEqual(eval_data["card_text"], "[REDACTED]")


class TestGateChecks(unittest.TestCase):
    """Test that evaluation gates from the issue are checked."""

    def test_p95_latency_gate(self):
        fixture = load_fixture(FIXTURE_PATH)
        harness = MeetingReplayHarness(fixture)
        record = harness.replay(FakeProvider(), "fake")
        # Fake provider should be fast enough to pass the latency gate
        self.assertTrue(record.metrics["p95_latency_passes_gate"])
        self.assertLess(record.metrics["p95_latency_seconds"], 7.0)

    def test_failure_isolation(self):
        """Intelligence failures should not affect the evaluation record structure."""
        class FailingProvider:
            def respond(self, transcript_context, prior_meetings):
                raise RuntimeError("Simulated failure")

        fixture = load_fixture(FIXTURE_PATH)
        harness = MeetingReplayHarness(fixture)
        record = harness.replay(FailingProvider(), "failing")
        # Record should still be produced even with failures
        self.assertEqual(len(record.moment_evaluations), 7)
        self.assertGreater(len(record.failures), 0)
        # All responses should be marked as failed
        for eval_result in record.moment_evaluations:
            for resp in eval_result.provider_responses.values():
                self.assertFalse(resp.succeeded)


if __name__ == "__main__":
    unittest.main()