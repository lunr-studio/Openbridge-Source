"""Production meeting-cleanup adapter tests for CLEAN-01 (#320)."""

from __future__ import annotations

import json
import socket
import unittest

from openbridge_engine.meeting_cleanup import cleanup_meeting_segments
from openbridge_engine.meeting_cleanup_benchmark import (
    CleanupBenchmarkError,
    OfflineNetworkAttempt,
    SnapshotInspection,
)


def complete_snapshot() -> SnapshotInspection:
    return SnapshotInspection(
        repository="mlx-community/gemma-3-4b-it-qat-4bit",
        revision="snapshot-test",
        snapshotPath="/tmp/local-gemma-snapshot",
        complete=True,
        missingFiles=(),
        warnings=(),
        config=None,
        tokenizerFiles=(),
        weightFiles=(),
    )


def request(segment_count: int = 9) -> dict[str, object]:
    return {
        "contractVersion": 1,
        "modelRepository": "mlx-community/gemma-3-4b-it-qat-4bit",
        "chunkSize": 8,
        "segments": [
            {
                "id": f"source-{index}",
                "meetingID": "meeting-1",
                "sequence": index,
                "startOffset": index * 30.0,
                "endOffset": (index + 1) * 30.0,
                "sourceLabel": "Room",
                "text": f"raw segment {index}",
                "isFinal": True,
            }
            for index in range(segment_count)
        ],
    }


def aligned_generator(prompt: str, model_path: str, _max_tokens: int) -> str:
    assert model_path == "/tmp/local-gemma-snapshot"
    payload = json.loads(prompt.split("Request JSON:\n", 1)[1])
    return json.dumps(
        {
            "contractVersion": 1,
            "segments": [
                {
                    "index": item["index"],
                    "cleanedText": item["sourceText"].capitalize() + ".",
                }
                for item in payload["segments"]
            ],
        }
    )


class ProductionCleanupTests(unittest.TestCase):
    def test_exact_contract_runs_in_eight_segment_chunks_and_preserves_ids(self) -> None:
        calls = 0

        def counting_generator(prompt: str, model_path: str, max_tokens: int) -> str:
            nonlocal calls
            calls += 1
            return aligned_generator(prompt, model_path, max_tokens)

        result = cleanup_meeting_segments(
            request(),
            generator=counting_generator,
            snapshot=complete_snapshot(),
        )

        self.assertEqual(calls, 2)
        self.assertEqual(result["contractVersion"], 1)
        self.assertEqual(result["modelRevision"], "snapshot-test")
        self.assertEqual(result["chunkSize"], 8)
        self.assertEqual(
            [item["sourceSegmentID"] for item in result["segments"]],
            [f"source-{index}" for index in range(9)],
        )

    def test_request_rejects_wrong_model_chunk_nonfinal_and_duplicate_ids(self) -> None:
        cases = []
        wrong_model = request(1)
        wrong_model["modelRepository"] = "some-cloud-model"
        cases.append(wrong_model)
        wrong_chunk = request(1)
        wrong_chunk["chunkSize"] = 16
        cases.append(wrong_chunk)
        nonfinal = request(1)
        nonfinal["segments"][0]["isFinal"] = False
        cases.append(nonfinal)
        duplicate = request(2)
        duplicate["segments"][1]["id"] = "source-0"
        cases.append(duplicate)

        for invalid in cases:
            with self.subTest(invalid=invalid), self.assertRaises(CleanupBenchmarkError):
                cleanup_meeting_segments(
                    invalid,
                    generator=aligned_generator,
                    snapshot=complete_snapshot(),
                )

    def test_network_attempt_is_denied_with_no_fallback(self) -> None:
        def network_generator(_prompt: str, _model_path: str, _max_tokens: int) -> str:
            socket.create_connection(("openrouter.ai", 443))
            raise AssertionError("network denial did not fail closed")

        with self.assertRaises(OfflineNetworkAttempt):
            cleanup_meeting_segments(
                request(1),
                generator=network_generator,
                snapshot=complete_snapshot(),
            )

    def test_failed_batch_splits_into_bounded_single_segment_requests(self) -> None:
        calls = 0

        def partial_then_single_generator(prompt: str, model_path: str, max_tokens: int) -> str:
            nonlocal calls
            calls += 1
            if calls == 1:
                return json.dumps({"contractVersion": 1, "segments": []})
            return aligned_generator(prompt, model_path, max_tokens)

        result = cleanup_meeting_segments(
            request(2),
            generator=partial_then_single_generator,
            snapshot=complete_snapshot(),
        )
        self.assertEqual(calls, 3)
        self.assertEqual(len(result["segments"]), 2)

    def test_single_segment_recovery_failure_fails_closed(self) -> None:
        prompts: list[str] = []

        def invalid_generator(prompt: str, _model_path: str, _max_tokens: int) -> str:
            prompts.append(prompt)
            return json.dumps({"contractVersion": 1, "segments": []})

        with self.assertRaisesRegex(CleanupBenchmarkError, "cleanup_wrong_count"):
            cleanup_meeting_segments(
                request(2), generator=invalid_generator, snapshot=complete_snapshot()
            )
        self.assertEqual(len(prompts), 2)
        self.assertNotIn("source-0", prompts[0])
        self.assertNotIn("source-1", prompts[0])


if __name__ == "__main__":
    unittest.main()
