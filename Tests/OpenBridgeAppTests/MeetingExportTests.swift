import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingExportTests {

    // MARK: - Golden fixtures

    private static let goldenStartedAt = Date(timeIntervalSince1970: 1_723_032_000) // 2024-08-07T12:00:00Z
    private static let goldenEndedAt = Date(timeIntervalSince1970: 1_723_035_600)   // 2024-08-07T13:00:00Z

    /// Two-segment meeting with fixed dates/timestamps for deterministic output.
    private func makeGoldenManifest(meetingID: String = "golden-meeting") -> MeetingManifest {
        let segments = [
            MeetingTranscriptSegment(
                id: "seg-A",
                meetingID: meetingID,
                sequence: 0,
                startOffset: 0,
                endOffset: 30,
                sourceLabel: "Room",
                text: "Hello, this is the first segment.",
                isFinal: true
            ),
            MeetingTranscriptSegment(
                id: "seg-B",
                meetingID: meetingID,
                sequence: 1,
                startOffset: 30,
                endOffset: 65,
                sourceLabel: "Room",
                text: "And here is the second part.",
                isFinal: true
            )
        ]
        return MeetingManifest(
            meetingID: meetingID,
            title: "Golden Export Test",
            state: .completed,
            startedAt: Self.goldenStartedAt,
            endedAt: Self.goldenEndedAt,
            segments: segments
        )
    }

    // MARK: - Original TXT export (golden)

    @Test func originalTxtExportMatchesGolden() throws {
        let root = temporaryRoot("export-txt-orig")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .original
        )

        let expected = """
        OpenBridge Meeting Transcript
        ==============================

        Title: Golden Export Test
        Date: 2024-08-07T12:00:00Z
        Ended: 2024-08-07T13:00:00Z
        Source: Original canonical transcript

        ---

        [00:00:00] Room: Hello, this is the first segment.
        [00:00:30] Room: And here is the second part.
        """

        #expect(result.document.effectiveSource == .original)
        #expect(result.document.revisionID == nil)
        #expect(result.url.lastPathComponent == "Transcript.txt")
        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written == expected + "\n")
    }

    // MARK: - Original Markdown export (golden)

    @Test func originalMarkdownExportMatchesGolden() throws {
        let root = temporaryRoot("export-md-orig")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .markdown,
            source: .original
        )

        let expected = """
        # Golden Export Test

        - **Date:** 2024-08-07T12:00:00Z
        - **Ended:** 2024-08-07T13:00:00Z
        - **Source:** Original canonical transcript

        ---

        **[00:00:00] Room**

        Hello, this is the first segment.

        **[00:00:30] Room**

        And here is the second part.
        """

        #expect(result.document.effectiveSource == .original)
        #expect(result.url.lastPathComponent == "Transcript.md")
        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written == expected + "\n")
    }

    // MARK: - Cleaned export with active revision (golden)

    @Test func cleanedTxtExportUsesActiveRevision() throws {
        let root = temporaryRoot("export-txt-cleaned")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        // Create and complete a cleanup revision
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)
        let cleaned = [
            MeetingCleanedSegment(sourceSegmentID: "seg-A", cleanedText: "Hello, this is the first segment."),
            MeetingCleanedSegment(sourceSegmentID: "seg-B", cleanedText: "And here is the second part.")
        ]
        try store.persistCleanupChunk(
            meetingID: manifest.meetingID, jobID: job.id, chunkIndex: 0, results: cleaned
        )
        let revision = try store.completeCleanupJob(
            meetingID: manifest.meetingID, jobID: job.id, modelRevision: "gemma-snap-1"
        )

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .cleaned
        )

        #expect(result.document.effectiveSource == .cleaned)
        #expect(result.document.revisionID == revision.id)

        let written = try String(contentsOf: result.url, encoding: .utf8)
        // Provenance should appear in cleaned export
        #expect(written.contains("Source: Cleaned revision"))
        #expect(written.contains("Revision ID: \(revision.id)"))
        #expect(written.contains("Model: \(MeetingCleanupContract.modelRepository)"))
        #expect(written.contains("Model Revision: gemma-snap-1"))
        // Cleaned text must appear
        #expect(written.contains("Hello, this is the first segment."))
        #expect(written.contains("And here is the second part."))
        // Original segments must NOT contain cleanup-specific header
        #expect(!written.contains("Source: Original canonical transcript"))
    }

    // MARK: - Cleaned export falls back to original when no valid revision

    @Test func cleanedExportFallsBackToOriginalWhenNoRevision() throws {
        let root = temporaryRoot("export-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .cleaned  // Request cleaned but none exists
        )

        #expect(result.document.effectiveSource == .original)
        #expect(result.document.revisionID == nil)
    }

    // MARK: - Cleaned export falls back when revision is stale

    @Test func cleanedExportFallsBackWhenRevisionIsStale() throws {
        let root = temporaryRoot("export-stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        // Create and complete a revision
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)
        try store.persistCleanupChunk(
            meetingID: manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: [
                MeetingCleanedSegment(sourceSegmentID: "seg-A", cleanedText: "Cleaned A."),
                MeetingCleanedSegment(sourceSegmentID: "seg-B", cleanedText: "Cleaned B.")
            ]
        )
        _ = try store.completeCleanupJob(
            meetingID: manifest.meetingID, jobID: job.id, modelRevision: "snap-1"
        )

        // Now edit the source transcript — makes the revision stale
        var edited = try store.load(meetingID: manifest.meetingID)
        edited.segments[0] = MeetingTranscriptSegment(
            id: "seg-A",
            meetingID: manifest.meetingID,
            sequence: 0,
            startOffset: 0,
            endOffset: 30,
            sourceLabel: "Room",
            text: "The source was corrected after cleanup.",
            isFinal: true
        )
        try store.saveManifest(edited)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .cleaned
        )

        // Stale revision → fallback to original
        #expect(result.document.effectiveSource == .original)
        #expect(result.document.revisionID == nil)
        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written.contains("The source was corrected after cleanup."))
    }

    // MARK: - Legacy v1 span export

    @Test func legacySpansExportWithRoomLabel() throws {
        let root = temporaryRoot("export-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(
            meetingID: "legacy-meeting",
            title: "Legacy V1",
            state: .completed,
            startedAt: Self.goldenStartedAt,
            transcriptSpans: ["[Segment 1] old text", "[Segment 2] more old text"],
            segments: []
        )
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .original
        )

        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written.contains("[--:--:--] Room: [Segment 1] old text"))
        #expect(written.contains("[--:--:--] Room: [Segment 2] more old text"))
    }

    // MARK: - Export preserves metadata sections

    @Test func exportIncludesSummaryActionItemsAndNotes() throws {
        let root = temporaryRoot("export-meta")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        var manifest = makeGoldenManifest(meetingID: "meta-meeting")
        manifest.summaryText = "This is the summary."
        manifest.actionItemsText = "- Follow up with team"
        manifest.manualNotes = "Remember to check audio levels."
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .original
        )

        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written.contains("Summary:"))
        #expect(written.contains("This is the summary."))
        #expect(written.contains("Action Items:"))
        #expect(written.contains("- Follow up with team"))
        #expect(written.contains("Notes:"))
        #expect(written.contains("Remember to check audio levels."))
    }

    // MARK: - Original always available even when cleaned exists

    @Test func originalExportAlwaysAvailableEvenWithActiveRevision() throws {
        let root = temporaryRoot("export-orig-always")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        // Complete a revision
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)
        try store.persistCleanupChunk(
            meetingID: manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: [
                MeetingCleanedSegment(sourceSegmentID: "seg-A", cleanedText: "Cleaned first."),
                MeetingCleanedSegment(sourceSegmentID: "seg-B", cleanedText: "Cleaned second.")
            ]
        )
        _ = try store.completeCleanupJob(
            meetingID: manifest.meetingID, jobID: job.id, modelRevision: "snap"
        )

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .original  // Explicit original despite active revision
        )

        #expect(result.document.effectiveSource == .original)
        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written.contains("Hello, this is the first segment."))
        #expect(!written.contains("Cleaned first."))
    }

    // MARK: - File permissions

    @Test func exportedFilesArePrivate() throws {
        let root = temporaryRoot("export-perms")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .original
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.url.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o700)
    }

    // MARK: - Predictable filenames

    @Test func exportProducesPredictableFilenames() throws {
        let root = temporaryRoot("export-fnames")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        let dest = root.appendingPathComponent("export", isDirectory: true)

        let txtResult = try store.exportTranscript(
            meetingID: manifest.meetingID, to: dest, format: .txt, source: .original
        )
        #expect(txtResult.url.lastPathComponent == "Transcript.txt")

        let mdResult = try store.exportTranscript(
            meetingID: manifest.meetingID, to: dest, format: .markdown, source: .original
        )
        #expect(mdResult.url.lastPathComponent == "Transcript.md")
    }

    // MARK: - Cleanup failure doesn't block export

    @Test func exportWorksWhenCleanupFailed() throws {
        let root = temporaryRoot("export-failed-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        // Start and fail a cleanup
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)
        try store.failCleanupJob(meetingID: manifest.meetingID, jobID: job.id, message: "model error")

        let dest = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportTranscript(
            meetingID: manifest.meetingID,
            to: dest,
            format: .txt,
            source: .cleaned
        )

        // Failed cleanup → no active revision → fall back to original
        #expect(result.document.effectiveSource == .original)
        let written = try String(contentsOf: result.url, encoding: .utf8)
        #expect(written.contains("Hello, this is the first segment."))
    }

    // MARK: - State-aware transcript bundle export (Build 20)

    @Test func bundleBeforeCleanupStartsContainsOriginalOnly() throws {
        let root = temporaryRoot("bundle-before")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)

        let destination = root.appendingPathComponent("export", isDirectory: true)
        let result = try store.exportAvailableTranscripts(
            meetingID: manifest.meetingID,
            to: destination
        )

        #expect(!result.includedCleaned)
        #expect(Set(result.filenames) == ["Original.txt", "Original.md"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Cleaned.txt").path))
    }

    @Test func bundleDuringCleanupContainsOriginalOnly() throws {
        let root = temporaryRoot("bundle-running")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)

        let result = try store.exportAvailableTranscripts(
            meetingID: manifest.meetingID,
            to: root.appendingPathComponent("export", isDirectory: true)
        )

        #expect(!result.includedCleaned)
        #expect(Set(result.filenames) == ["Original.txt", "Original.md"])
    }

    @Test func bundleAfterCleanupContainsOriginalAndCleaned() throws {
        let root = temporaryRoot("bundle-completed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)
        try store.persistCleanupChunk(
            meetingID: manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: [
                MeetingCleanedSegment(sourceSegmentID: "seg-A", cleanedText: "Cleaned first."),
                MeetingCleanedSegment(sourceSegmentID: "seg-B", cleanedText: "Cleaned second."),
            ]
        )
        _ = try store.completeCleanupJob(
            meetingID: manifest.meetingID,
            jobID: job.id,
            modelRevision: "snapshot"
        )

        let result = try store.exportAvailableTranscripts(
            meetingID: manifest.meetingID,
            to: root.appendingPathComponent("export", isDirectory: true)
        )

        #expect(result.includedCleaned)
        #expect(Set(result.filenames) == [
            "Original.txt", "Original.md", "Cleaned.txt", "Cleaned.md",
        ])
    }

    @Test func failedCleanupBundleRemovesStaleCleanedFilesAndKeepsOriginal() throws {
        let root = temporaryRoot("bundle-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = makeGoldenManifest()
        try store.create(manifest)
        let job = try store.createCleanupJob(meetingID: manifest.meetingID)
        _ = try store.markCleanupJobRunning(meetingID: manifest.meetingID, jobID: job.id)
        try store.failCleanupJob(
            meetingID: manifest.meetingID,
            jobID: job.id,
            message: "model failed"
        )
        let destination = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("Cleaned.txt"))
        try Data("stale".utf8).write(to: destination.appendingPathComponent("Cleaned.md"))

        let result = try store.exportAvailableTranscripts(
            meetingID: manifest.meetingID,
            to: destination
        )

        #expect(!result.includedCleaned)
        #expect(Set(result.filenames) == ["Original.txt", "Original.md"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Cleaned.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Cleaned.md").path))
    }

    // MARK: - Helpers

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-export-\(label)", isDirectory: true)
    }
}
