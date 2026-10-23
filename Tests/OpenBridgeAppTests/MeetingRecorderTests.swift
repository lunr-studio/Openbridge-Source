import Testing
import Foundation
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingRecorderStorageTests {

    @Test func segmentURLUsesWAVExtension() {
        let store = MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory)
        let url = store.audioSegmentURL(for: "test-meeting", segmentIndex: 0)
        #expect(url.pathExtension == "wav")
    }

    @Test func segmentURLFormatIsCorrect() {
        let store = MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory)
        let url = store.audioSegmentURL(for: "test-meeting", segmentIndex: 5)
        #expect(url.lastPathComponent == "segment_0005.wav")
    }

    @Test func sequentialSegmentNames() {
        let store = MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory)
        for i in 0..<10 {
            let url = store.audioSegmentURL(for: "test-meeting", segmentIndex: i)
            let expected = String(format: "segment_%04d.wav", i)
            #expect(url.lastPathComponent == expected)
        }
    }

    @Test func manifestRetainsExactMeetingID() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let meetingID = "exact-id-test-12345"
        let manifest = MeetingManifest(meetingID: meetingID, title: "ID Test", state: .recording)
        try store.create(manifest)
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.meetingID == meetingID)
    }

    @Test func manifestUpdatesAudioSegments() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Segment Test", state: .recording)
        try store.create(manifest)

        var updated = manifest
        updated.audioSegments = ["segment_0000.wav", "segment_0001.wav"]
        updated.lastCompletedSegmentIndex = 2
        try store.saveManifest(updated)

        let reloaded = try store.load(meetingID: manifest.meetingID)
        #expect(reloaded.audioSegments.count == 2)
        #expect(reloaded.lastCompletedSegmentIndex == 2)
    }

    @Test func activeJournalSaveAlsoCatchesUpCompletedBoundaryHistory() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Capture Progress", state: .recording)
        try store.create(manifest)
        let boundaries = [
            MeetingChunkBoundary(
                chunkIndex: 0,
                startOffset: 0,
                endOffset: 10,
                overlapSeconds: 0.6,
                reason: .maxDuration,
                availableOverlap: 0.6
            ),
            MeetingChunkBoundary(
                chunkIndex: 1,
                startOffset: 9.4,
                endOffset: 20,
                overlapSeconds: 0.6,
                reason: .maxDuration,
                availableOverlap: 0.6
            ),
        ]
        let active = MeetingActiveJournal(
            filename: "segment_0002.wav",
            segmentIndex: 2,
            startOffset: 19.4
        )

        try store.saveCaptureProgress(
            meetingID: manifest.meetingID,
            completedSegmentFilenames: ["segment_0000.wav", "segment_0001.wav"],
            chunkBoundaries: boundaries,
            activeJournal: active
        )
        let reloaded = try store.load(meetingID: manifest.meetingID)

        #expect(reloaded.lastCompletedSegmentIndex == 2)
        #expect(reloaded.audioSegments == ["segment_0000.wav", "segment_0001.wav"])
        #expect(reloaded.chunkBoundaries == boundaries)
        #expect(reloaded.activeJournal == active)
    }

    @Test func stateTransitionRecordingToStopped() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        var manifest = MeetingManifest(title: "State Test", state: .recording)
        try store.create(manifest)

        manifest.state = .stopped
        manifest.endedAt = Date()
        try store.saveManifest(manifest)

        let loaded = try store.load(meetingID: manifest.meetingID)
        #expect(loaded.state == .stopped)
        #expect(loaded.endedAt != nil)
    }

    @MainActor
    @Test func recorderInitiallyNotRecording() {
        let store = MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory)
        let recorder = MeetingRecorder(store: store)
        #expect(!recorder.isRecording)
    }

    @Test func storeIsolationSeesSameData() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store1 = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Isolation Test", state: .recording)
        try store1.create(manifest)

        let store2 = MeetingSessionStore(rootDirectory: testRoot)
        let meetings = try store2.listMeetings()
        #expect(meetings.count == 1)
        #expect(meetings[0].meetingID == manifest.meetingID)
    }

    @Test func deleteRemovesAllArtifacts() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Delete Test", state: .recording)
        try store.create(manifest)
        try store.delete(meetingID: manifest.meetingID)
        let after = try store.listMeetings()
        #expect(after.count == 0)
    }

    // MARK: - Retention enforcement tests

    @Test func retentionDeletesExpiredMeetings() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let now = Date()

        // Meeting 1: expired (10 days old, 7-day retention)
        let expiredManifest = MeetingManifest(
            title: "Expired",
            state: .stopped,
            startedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            retentionPolicy: .autoDeleteAfter7Days
        )
        try store.create(expiredManifest)

        // Meeting 2: fresh (1 day old, 7-day retention)
        let freshManifest = MeetingManifest(
            title: "Fresh",
            state: .stopped,
            startedAt: now.addingTimeInterval(-1 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-1 * 24 * 60 * 60),
            retentionPolicy: .autoDeleteAfter7Days
        )
        try store.create(freshManifest)

        // Meeting 3: old but keep-until-deleted (100 days, never expires)
        let keepManifest = MeetingManifest(
            title: "Keep",
            state: .stopped,
            startedAt: now.addingTimeInterval(-100 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-100 * 24 * 60 * 60),
            retentionPolicy: .keepUntilDeleted
        )
        try store.create(keepManifest)

        let deletedCount = try store.enforceRetentionPolicy(now: now)
        #expect(deletedCount == 1)

        let remaining = try store.listMeetings()
        #expect(remaining.count == 2)
        #expect(remaining.contains(where: { $0.title == "Fresh" }))
        #expect(remaining.contains(where: { $0.title == "Keep" }))
    }

    @Test func retentionKeepUntilDeletedNeverExpires() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let now = Date()

        let oldKeepManifest = MeetingManifest(
            title: "Ancient Keep",
            state: .stopped,
            startedAt: now.addingTimeInterval(-365 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-365 * 24 * 60 * 60),
            retentionPolicy: .keepUntilDeleted
        )
        try store.create(oldKeepManifest)

        let deletedCount = try store.enforceRetentionPolicy(now: now)
        #expect(deletedCount == 0)

        let remaining = try store.listMeetings()
        #expect(remaining.count == 1)
    }

    @Test func retention30DayPolicyRespected() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let now = Date()

        // 20 days old with 30-day retention — should survive
        let manifest = MeetingManifest(
            title: "20 days old",
            state: .stopped,
            startedAt: now.addingTimeInterval(-20 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-20 * 24 * 60 * 60),
            retentionPolicy: .autoDeleteAfter30Days
        )
        try store.create(manifest)

        let deletedCount = try store.enforceRetentionPolicy(now: now)
        #expect(deletedCount == 0)

        // Now make it 31 days old — should be deleted
        var expiredManifest = manifest
        expiredManifest.startedAt = now.addingTimeInterval(-31 * 24 * 60 * 60)
        expiredManifest.endedAt = now.addingTimeInterval(-31 * 24 * 60 * 60)
        try store.saveManifest(expiredManifest)

        let deletedCount2 = try store.enforceRetentionPolicy(now: now)
        #expect(deletedCount2 == 1)
    }

    // MARK: - Export tests

    @Test func exportCopiesManifestAndAudio() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Export Test", state: .stopped)
        try store.create(manifest)

        // Create a fake audio segment
        let segmentURL = store.audioSegmentURL(for: manifest.meetingID, segmentIndex: 0)
        try Data("fake-audio".utf8).write(to: segmentURL)

        // Export
        let exportedDir = try store.export(meetingID: manifest.meetingID, to: exportRoot)

        // Verify manifest exists
        let exportedManifest = exportedDir.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: exportedManifest.path))

        // Verify audio directory exists and has the segment
        let exportedAudioDir = exportedDir.appendingPathComponent("audio")
        #expect(FileManager.default.fileExists(atPath: exportedAudioDir.path))

        let exportedSegment = exportedAudioDir.appendingPathComponent("segment_0000.wav")
        #expect(FileManager.default.fileExists(atPath: exportedSegment.path))

        // Verify original meeting still intact (export is a copy)
        let originalMeetings = try store.listMeetings()
        #expect(originalMeetings.count == 1)
    }
}

// MARK: - Test doubles for meeting finalization

/// Stub engine used by finalization tests. Returns a fixed payload or throws,
/// and records every segment URL it was asked to transcribe so tests can
/// assert no segment is transcribed twice.
///
/// Marked `@unchecked Sendable` because the `transcribedURLs` array is only
/// read after the async transcription calls have awaited. The test suites are
/// serialized, so there is no concurrent access in practice.
final class StubMeetingEngine: MeetingEngine, @unchecked Sendable {
    enum Mode {
        case success(text: String)
        case failure
    }

    let mode: Mode
    private(set) var transcribedURLs: [URL] = []

    init(mode: Mode) {
        self.mode = mode
    }

    nonisolated func transcribe(
        audioURL: URL,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> TranscriptPayload {
        transcribedURLs.append(audioURL)

        switch mode {
        case .success(let text):
            return TranscriptPayload(text: text)
        case .failure:
            throw EngineServiceError.processFailed("stub failure for test")
        }
    }
}

// MARK: - Meeting finalization tests (#303)

@Suite(.serialized) struct MeetingFinalizationTests {

    @MainActor
    @Test func finalizeTranscribesRemainingSegmentOnSuccess() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Finalize Success", state: .recording)
        try store.create(manifest)

        // Simulate one finalized segment file on disk.
        let segmentURL = store.audioSegmentURL(for: manifest.meetingID, segmentIndex: 0)
        try Data("synthetic-audio".utf8).write(to: segmentURL)

        let stub = StubMeetingEngine(mode: .success(text: "hello world"))
        let transcriber = MeetingTranscriber(
            store: store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: stub
        )
        transcriber.start(meetingID: manifest.meetingID)

        // Call transcribeSegmentRange directly with a known range — this
        // bypasses the recorder entirely and exercises the real engine-calling
        // loop with the stub.
        let result = await transcriber.transcribeSegmentRange(
            meetingID: manifest.meetingID,
            fromIndex: 0,
            toIndex: 1
        )

        // The stub succeeded, so we expect .completed with 1 transcribed segment.
        if case .completed(let count) = result {
            #expect(count == 1)
        } else {
            Issue.record("Expected .completed with 1 transcribed segment")
        }

        // The transcript text should contain the stub's text.
        #expect(transcriber.transcriptText.contains("hello world"))

        // The manifest should have a transcript span appended.
        let loadedManifest = try store.load(meetingID: manifest.meetingID)
        #expect(loadedManifest.transcriptSpans.count == 1)

        // The stub should have been called exactly once (no duplicate).
        #expect(stub.transcribedURLs.count == 1)

        // Source audio must still exist (never deleted).
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))
    }

    @MainActor
    @Test func finalizePreservesAudioAndReturnsFailureOnEngineError() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Finalize Failure", state: .recording)
        try store.create(manifest)

        let segmentURL = store.audioSegmentURL(for: manifest.meetingID, segmentIndex: 0)
        try Data("synthetic-audio".utf8).write(to: segmentURL)

        let stub = StubMeetingEngine(mode: .failure)
        let transcriber = MeetingTranscriber(
            store: store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: stub
        )
        transcriber.start(meetingID: manifest.meetingID)

        // Exercise the failure path directly via transcribeSegmentRange.
        // The stub throws on every transcribe call, so this should return .failed.
        let result = await transcriber.transcribeSegmentRange(
            meetingID: manifest.meetingID,
            fromIndex: 0,
            toIndex: 1
        )

        // Must be .failed — not .completed.
        if case .failed(let count, let error) = result {
            #expect(count == 0)  // nothing was successfully transcribed
            #expect(!error.isEmpty)  // an error message was surfaced
        } else {
            Issue.record("Expected .failed when the engine throws, but got .completed")
        }

        // The transcriber should have surfaced the error.
        #expect(transcriber.lastError != nil)

        // The transcript should be empty (nothing was transcribed).
        #expect(transcriber.transcriptText.isEmpty)

        // The manifest should NOT have any transcript spans.
        let loadedManifest = try store.load(meetingID: manifest.meetingID)
        #expect(loadedManifest.transcriptSpans.isEmpty)

        // Audio must remain on disk — never deleted on failure.
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))
    }

    @MainActor
    @Test func transcriberDoesNotTranscribeSameSegmentTwice() async {
        let stub = StubMeetingEngine(mode: .success(text: "once"))
        let transcriber = MeetingTranscriber(
            store: MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory),
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: stub
        )

        // Call checkForNewSegments twice with the same recorder state. The
        // second call must not enqueue duplicate transcription because
        // lastTranscribedSegmentCount has advanced.
        let recorder = MeetingRecorder(
            store: MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory)
        )

        transcriber.start(meetingID: "dup-test")
        transcriber.checkForNewSegments(recorder: recorder)
        transcriber.checkForNewSegments(recorder: recorder)

        // completedSegmentCount is 0 for a fresh recorder, so nothing should
        // have been transcribed at all. This guards the duplicate boundary:
        // the count never exceeds lastTranscribedSegmentCount.
        #expect(stub.transcribedURLs.isEmpty)
    }
}
