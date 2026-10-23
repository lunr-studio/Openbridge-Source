"""Keep the async capture factory's actor contract explicit across Swift versions."""

from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "Sources/OpenBridgeApp/OnlineMeetingRecorder.swift"


class OnlineCaptureIsolationTests(unittest.TestCase):
    def test_replay_preparation_transfers_ownership_without_unchecked_sendability(self) -> None:
        source = (SOURCE.parent / "MeetingReplayView.swift").read_text(encoding="utf-8")
        self.assertRegex(source, r"nonisolated private static func prepareOnlineComposition\(")
        self.assertIn("async throws -> sending (AVMutableComposition, TimeInterval)", source)
        self.assertNotIn("@preconcurrency import AVFoundation", source)
        self.assertNotIn("@unchecked Sendable", source)

    def test_stored_and_injected_factory_keep_main_actor_isolation(self) -> None:
        # A closure stored on a MainActor object does not itself inherit that
        # isolation in its function type. Older Swift compilers reject the
        # non-Sendable protocol result crossing that erased async boundary.
        source = SOURCE.read_text(encoding="utf-8")
        signature = r"\(MeetingRecorder, MeetingRecorder, String\?\)\s+async throws -> any OnlineMeetingStreamDriver"
        for declaration in (
            r"private let makeDriver:\s+@MainActor\s+",
            r"makeDriver:\s+\(@MainActor\s+",
        ):
            with self.subTest(declaration=declaration):
                self.assertIsNotNone(re.search(declaration + signature, source))


if __name__ == "__main__":
    unittest.main()
