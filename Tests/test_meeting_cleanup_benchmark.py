"""Contract and safety tests for the CLEAN-00 benchmark harness."""

from __future__ import annotations

import json
import socket
import tempfile
import unittest
from pathlib import Path

from openbridge_engine.meeting_cleanup_benchmark import (
    CleanupBenchmarkError,
    CleanupFixture,
    CleanupSourceSegment,
    OfflineGuard,
    OfflineNetworkAttempt,
    SnapshotInspection,
    benchmark_suite,
    build_cleanup_prompt,
    evaluate_runs,
    generate_synthetic_fixture,
    inspect_local_snapshot,
    load_cleanup_fixture,
    parse_cleanup_result,
    run_fixture_once,
    validate_fixture,
    write_fixture,
)


def aligned_generator(prompt: str, _model_path: str, _max_tokens: int) -> str:
    request = json.loads(prompt.split("Request JSON:\n", 1)[1])
    return json.dumps(
        {
            "contractVersion": 1,
            "segments": [
                {
                    "index": item["index"],
                    "cleanedText": item["sourceText"].capitalize() + ".",
                }
                for item in request["segments"]
            ],
        }
    )


class FixtureTests(unittest.TestCase):
    def test_fixtures_are_deterministic_and_match_expected_duration(self) -> None:
        fifteen = generate_synthetic_fixture(15)
        sixty = generate_synthetic_fixture(60)

        self.assertEqual(fifteen, generate_synthetic_fixture(15))
        self.assertEqual(len(fifteen.segments), 30)
        self.assertEqual(len(sixty.segments), 120)
        self.assertEqual(sixty.segments[-1].endOffset, 3600.0)
        self.assertEqual(validate_fixture(fifteen), [])
        self.assertEqual(validate_fixture(sixty), [])

    def test_fixture_uses_schema_v2_keys_without_confidence_scores(self) -> None:
        fixture = generate_synthetic_fixture(15)
        payload = fixture.to_dict()
        first = payload["segments"][0]

        self.assertEqual(
            set(first),
            {
                "id",
                "meetingID",
                "sequence",
                "startOffset",
                "endOffset",
                "sourceLabel",
                "text",
                "isFinal",
            },
        )
        self.assertNotIn("confidence", json.dumps(payload).lower())

    def test_fixture_round_trip_preserves_stable_ids_and_original_text(self) -> None:
        fixture = generate_synthetic_fixture(15)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.json"
            write_fixture(fixture, path)
            loaded = load_cleanup_fixture(path)
        self.assertEqual(loaded, fixture)

    def test_fixture_validator_rejects_duplicate_ids(self) -> None:
        segment = CleanupSourceSegment(
            id="duplicate",
            meetingID="meeting",
            sequence=0,
            startOffset=0,
            endOffset=30,
            sourceLabel="Room",
            text="hello",
        )
        fixture = CleanupFixture("fixture", "meeting", 60, (segment, segment))
        self.assertTrue(
            any("Duplicate" in issue for issue in validate_fixture(fixture))
        )


class ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = generate_synthetic_fixture(15).segments[:2]

    def result(self, indexes: list[int], texts: list[str] | None = None) -> str:
        texts = texts or ["Cleaned text."] * len(indexes)
        return json.dumps(
            {
                "contractVersion": 1,
                "segments": [
                    {"index": index, "cleanedText": text}
                    for index, text in zip(indexes, texts)
                ],
            }
        )

    def test_prompt_uses_numbers_and_never_exposes_internal_ids(self) -> None:
        prompt = build_cleanup_prompt(self.source)
        for segment in self.source:
            self.assertNotIn(segment.id, prompt)
        self.assertIn('"index":1', prompt)
        self.assertIn('"index":2', prompt)
        self.assertIn("exactly one result", prompt)
        self.assertNotIn("confidence", prompt.lower())
        self.assertNotIn('"cleanedText":"..."', prompt)

    def test_prompt_encodes_the_conservative_sealed_segment_policy(self) -> None:
        prompt = build_cleanup_prompt(self.source)

        required_instructions = (
            "Fidelity is more important than fluency",
            "statement, clause, qualification, correction",
            "name, number, amount, date",
            "instance of profanity",
            "sealed container",
            "Never move, copy, borrow, or duplicate text across items",
            "begins or ends mid-sentence",
            "terminal punctuation that makes the fragment appear complete",
            "we stopped because must remain We stopped because",
            "Never return empty cleanedText or replace speech with an ellipsis",
            "Do not summarize, paraphrase, reorganize",
            "No glossary is supplied",
            "retain every proper noun exactly as transcribed",
            "Preserve repetition used for emphasis, disagreement, or correction",
            "Remove an isolated filler",
            "Remove an obvious abandoned word fragment",
            "Collapse a simple accidental stutter",
            "only when the intended wording is unambiguous",
            "silently compare each cleanedText with its own sourceText",
        )
        for instruction in required_instructions:
            with self.subTest(instruction=instruction):
                self.assertIn(instruction, prompt)

    def test_parser_accepts_exact_one_to_one_result(self) -> None:
        raw = self.result([1, 2])
        parsed = parse_cleanup_result(raw, self.source)
        self.assertEqual(
            [item.sourceSegmentID for item in parsed], [item.id for item in self.source]
        )

    def test_parser_accepts_json_code_fence_but_not_misalignment(self) -> None:
        raw = (
            "```json\n" + self.result([1, 2]) + "\n```"
        )
        self.assertEqual(len(parse_cleanup_result(raw, self.source)), 2)

        reordered = self.result([2, 1])
        with self.assertRaisesRegex(CleanupBenchmarkError, "cleanup_invalid_index"):
            parse_cleanup_result(reordered, self.source)

    def test_parser_rejects_missing_duplicate_empty_and_ellipsis_results(self) -> None:
        with self.assertRaisesRegex(CleanupBenchmarkError, "cleanup_wrong_count"):
            parse_cleanup_result(self.result([1]), self.source)

        with self.assertRaisesRegex(CleanupBenchmarkError, "cleanup_invalid_index"):
            parse_cleanup_result(
                self.result([1, 1]), self.source
            )

        with self.assertRaisesRegex(CleanupBenchmarkError, "cleanup_empty_text"):
            parse_cleanup_result(
                self.result([1, 2], ["Okay.", "  "]),
                self.source,
            )

        for placeholder in ("...", " … ", " . . . ", "……"):
            with self.subTest(placeholder=placeholder), self.assertRaisesRegex(
                CleanupBenchmarkError, "cleanup_placeholder_text"
            ):
                parse_cleanup_result(
                    self.result([1, 2], ["Okay.", placeholder]),
                    self.source,
                )

    def test_parser_allows_real_speech_that_ends_with_an_ellipsis(self) -> None:
        parsed = parse_cleanup_result(
            self.result([1, 2], ["I suppose...", "Still meaningful…"]),
            self.source,
        )
        self.assertEqual(parsed[0].cleanedText, "I suppose...")
        self.assertEqual(parsed[1].cleanedText, "Still meaningful…")


class SnapshotTests(unittest.TestCase):
    def make_snapshot(self, root: Path, *, include_weights: bool) -> Path:
        from openbridge_engine import model_integrity
        snapshot = root / "snapshots" / model_integrity.model_spec("gemma")["revision"]
        snapshot.mkdir(parents=True)
        (snapshot / "config.json").write_text("{}", encoding="utf-8")
        (snapshot / "tokenizer.json").write_text("{}", encoding="utf-8")
        (snapshot / "model.safetensors.index.json").write_text(
            json.dumps(
                {
                    "weight_map": {
                        "layer.one": "model-00001-of-00002.safetensors",
                        "layer.two": "model-00002-of-00002.safetensors",
                    }
                }
            ),
            encoding="utf-8",
        )
        if include_weights:
            (snapshot / "model-00001-of-00002.safetensors").write_bytes(b"weight-one")
            (snapshot / "model-00002-of-00002.safetensors").write_bytes(b"weight-two")
        return snapshot

    def test_incomplete_snapshot_reports_every_missing_weight_shard(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "model-cache"
            self.make_snapshot(root, include_weights=False)
            inspection = inspect_local_snapshot(cache_roots=(root,))
        self.assertFalse(inspection.complete)
        self.assertEqual(
            inspection.missingFiles,
            ("model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"),
        )

    def test_complete_snapshot_records_revision_files_sizes_and_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "model-cache"
            snapshot = self.make_snapshot(root, include_weights=True)
            inspection = inspect_local_snapshot(cache_roots=(root,))
        self.assertTrue(inspection.complete)
        self.assertEqual(inspection.revision, snapshot.name)
        self.assertEqual(len(inspection.weightFiles), 2)
        self.assertTrue(all(len(item.sha256) == 64 for item in inspection.weightFiles))

    def test_single_weight_file_is_accepted_when_upstream_index_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "model-cache"
            snapshot = self.make_snapshot(root, include_weights=False)
            (snapshot / "model.safetensors").write_bytes(b"consolidated-weights")
            inspection = inspect_local_snapshot(cache_roots=(root,))
        self.assertTrue(inspection.complete)
        self.assertEqual(
            [item.path for item in inspection.weightFiles], ["model.safetensors"]
        )
        self.assertTrue(
            any("absent shards" in warning for warning in inspection.warnings)
        )


class OfflineAndMeasurementTests(unittest.TestCase):
    def test_offline_guard_blocks_and_records_socket_attempt(self) -> None:
        guard = OfflineGuard()
        with self.assertRaises(OfflineNetworkAttempt), guard:
            socket.create_connection(("example.com", 443))
        self.assertEqual(guard.attempts, ["('example.com', 443)"])

    def test_fixture_run_preserves_original_and_records_metrics(self) -> None:
        fixture = generate_synthetic_fixture(15)
        result = run_fixture_once(
            fixture,
            model_path="/tmp/test-model",
            chunk_size=8,
            generator=aligned_generator,
        )
        self.assertTrue(result["structurallyAligned"])
        self.assertEqual(result["segmentCount"], 30)
        self.assertEqual(result["chunkCount"], 4)
        self.assertEqual(result["networkAttempts"], [])
        self.assertGreater(result["peakResidentBytes"], 0)
        self.assertIn("mlxPeakMemoryBytes", result)
        self.assertEqual(
            result["segments"][0]["originalText"], fixture.segments[0].text
        )
        self.assertNotEqual(
            result["segments"][0]["cleanedText"], fixture.segments[0].text
        )

    def test_gate_analysis_detects_progressive_growth_per_duration(self) -> None:
        runs = []
        for repetition, rss in enumerate((100, 400_000_000, 800_000_000), start=1):
            runs.append(
                {
                    "durationSeconds": 3600.0,
                    "wallTimeSeconds": 1.0,
                    "peakResidentBytes": rss,
                    "swapUsedBytesAfter": 0,
                    "structurallyAligned": True,
                    "networkAttempts": [],
                    "repetition": repetition,
                }
            )
        self.assertTrue(evaluate_runs(runs)["progressivePeakRSSGrowth"])

    def test_gate_accepts_only_the_product_approved_boundary_tolerance(self) -> None:
        def run_at(wall_time: float) -> dict[str, object]:
            return {
                "durationSeconds": 3600.0,
                "wallTimeSeconds": wall_time,
                "peakResidentBytes": 100,
                "swapUsedBytesAfter": 0,
                "structurallyAligned": True,
                "networkAttempts": [],
            }

        accepted = evaluate_runs([run_at(300.006)])
        self.assertFalse(accepted["sixtyMinuteStrictlyUnderFiveMinutes"])
        self.assertTrue(accepted["sixtyMinutePerformanceGateAccepted"])

        outside_tolerance = evaluate_runs([run_at(300.051)])
        self.assertFalse(outside_tolerance["sixtyMinutePerformanceGateAccepted"])

    def test_incomplete_snapshot_produces_reject_without_inference(self) -> None:
        snapshot = SnapshotInspection(
            "repo", "revision", "/tmp/model", False, ("weights",), (), None, (), ()
        )
        report = benchmark_suite(
            (generate_synthetic_fixture(15), generate_synthetic_fixture(60)),
            runs_per_fixture=3,
            chunk_size=8,
            snapshot=snapshot,
            generator=aligned_generator,
        )
        self.assertEqual(report["decision"], "Reject")
        self.assertEqual(report["runs"], [])

    def test_runtime_failure_produces_reject_record_instead_of_crashing(self) -> None:
        def failing_generator(_prompt: str, _model_path: str, _max_tokens: int) -> str:
            raise ImportError("runtime unavailable")

        snapshot = SnapshotInspection(
            "repo", "revision", "/tmp/model", True, (), (), None, (), ()
        )
        report = benchmark_suite(
            (generate_synthetic_fixture(15),),
            runs_per_fixture=1,
            chunk_size=8,
            snapshot=snapshot,
            generator=failing_generator,
        )
        self.assertEqual(report["decision"], "Reject")
        self.assertEqual(report["inferenceFailure"]["type"], "ImportError")

    def test_partial_smoke_suite_is_incomplete_not_a_failed_full_decision(self) -> None:
        snapshot = SnapshotInspection(
            "repo", "revision", "/tmp/model", True, (), (), None, (), ()
        )
        report = benchmark_suite(
            (generate_synthetic_fixture(15),),
            runs_per_fixture=1,
            chunk_size=8,
            snapshot=snapshot,
            generator=aligned_generator,
        )
        self.assertEqual(report["decision"], "Incomplete")
        self.assertFalse(report["gates"]["coverageComplete"])
        self.assertIsNone(report["gates"]["sixtyMinuteStrictlyUnderFiveMinutes"])
        self.assertIsNone(report["gates"]["sixtyMinutePerformanceGateAccepted"])

    def test_complete_aligned_offline_suite_recommends_build(self) -> None:
        snapshot = SnapshotInspection(
            "repo", "revision", "/tmp/model", True, (), (), None, (), ()
        )
        report = benchmark_suite(
            (generate_synthetic_fixture(15), generate_synthetic_fixture(60)),
            runs_per_fixture=3,
            chunk_size=8,
            snapshot=snapshot,
            generator=aligned_generator,
        )
        self.assertEqual(report["decision"], "Build")
        self.assertTrue(report["gates"]["coverageComplete"])
        self.assertTrue(report["gates"]["sixtyMinutePerformanceGateAccepted"])


if __name__ == "__main__":
    unittest.main()
