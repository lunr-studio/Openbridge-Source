import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingCleanupTests {
    @Test func schemaV2ManifestMigratesWithEmptyCleanupHistory() throws {
        let root = temporaryRoot("schema-v2")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingDirectory = root.appendingPathComponent("schema-v2-meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        let fixture = """
        {
          "schemaVersion": 2,
          "meetingID": "schema-v2-meeting",
          "title": "Schema v2 fixture",
          "state": "completed",
          "startedAt": "2026-08-01T10:00:00Z",
          "sources": [],
          "retentionPolicy": "keepUntilDeleted",
          "aiMode": "transcriptionOnly",
          "lastCompletedSegmentIndex": 0,
          "transcriptSpans": ["original legacy span"],
          "segments": [{
            "id": "source-0",
            "meetingID": "schema-v2-meeting",
            "sequence": 0,
            "sourceLabel": "Room",
            "text": "original typed transcript",
            "isFinal": true
          }],
          "participants": [],
          "agenda": [],
          "objectives": [],
          "privacySettings": {
            "allowsLocalIntelligence": true,
            "allowsCloudIntelligence": false,
            "retainsTranscript": true
          },
          "audioSegments": [],
          "events": [],
          "modelProviderMetadata": {}
        }
        """
        try Data(fixture.utf8).write(to: meetingDirectory.appendingPathComponent("manifest.json"))

        let store = MeetingSessionStore(rootDirectory: root)
        let migrated = try store.load(meetingID: "schema-v2-meeting")
        try store.saveManifest(migrated)
        let reloaded = try store.load(meetingID: "schema-v2-meeting")

        #expect(reloaded.schemaVersion == 4)
        #expect(reloaded.transcriptSpans == ["original legacy span"])
        #expect(reloaded.segments.map(\.text) == ["original typed transcript"])
        #expect(reloaded.cleanupJobs.isEmpty)
        #expect(reloaded.cleanupRevisions.isEmpty)
        #expect(reloaded.activeCleanupRevisionID == nil)
    }

    @Test func completedMeetingCreatesOneQueuedRevisionWithoutChangingOriginal() throws {
        let fixture = try makeFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let original = fixture.manifest.segments
        let first = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        let repeated = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        let loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)

        #expect(first == repeated)
        #expect(first.state == .queued)
        #expect(loaded.cleanupJobs.count == 1)
        #expect(loaded.cleanupRevisions.count == 1)
        #expect(loaded.cleanupRevisions[0].state == .pending)
        #expect(loaded.segments == original)
        #expect(loaded.activeCleanupRevisionID == nil)
    }

    @Test func cleanupCannotStartDuringRecordingOrWithNonFinalSource() throws {
        let root = temporaryRoot("cleanup-preconditions")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let meetingID = "recording-meeting"
        let segment = MeetingTranscriptSegment(
            id: "source-0",
            meetingID: meetingID,
            sequence: 0,
            text: "unfinished words",
            isFinal: false
        )
        try store.create(MeetingManifest(
            meetingID: meetingID,
            title: "Recording",
            state: .recording,
            segments: [segment]
        ))

        #expect(throws: MeetingSessionStoreError.self) {
            try store.createCleanupJob(meetingID: meetingID)
        }

        var completed = try store.load(meetingID: meetingID)
        completed.state = .completed
        try store.saveManifest(completed)
        #expect(throws: MeetingSessionStoreError.self) {
            try store.createCleanupJob(meetingID: meetingID)
        }
    }

    @Test func exactAlignedCompletionActivatesRevisionAndPreservesCanonicalText() throws {
        let fixture = try makeFixture(segmentCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.manifest.segments
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id
        )
        let results = alignedResults(for: original)
        try fixture.store.persistCleanupChunk(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: results
        )
        // An identical repeated write is safe and does not duplicate results.
        try fixture.store.persistCleanupChunk(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: results
        )
        let revision = try fixture.store.completeCleanupJob(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            modelRevision: "snapshot-abc"
        )
        // Repeating completion returns the same already-valid revision.
        let repeated = try fixture.store.completeCleanupJob(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            modelRevision: "snapshot-abc"
        )
        let loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)

        #expect(repeated == revision)
        #expect(revision.state == .valid)
        #expect(revision.cleanedSegments == results)
        #expect(loaded.activeCleanupRevisionID == revision.id)
        #expect(loaded.segments == original)
        #expect(try fixture.store.activeCleanupRevision(meetingID: fixture.manifest.meetingID) == revision)
    }

    @Test func missingDuplicateReorderedAndConflictingResultsCannotActivate() throws {
        let invalidCases: [[MeetingCleanedSegment]] = [
            [MeetingCleanedSegment(sourceSegmentID: "source-0", cleanedText: "Only one.")],
            [
                MeetingCleanedSegment(sourceSegmentID: "source-0", cleanedText: "First."),
                MeetingCleanedSegment(sourceSegmentID: "source-0", cleanedText: "Duplicate."),
            ],
            [
                MeetingCleanedSegment(sourceSegmentID: "source-1", cleanedText: "Second."),
                MeetingCleanedSegment(sourceSegmentID: "source-0", cleanedText: "First."),
            ],
            [
                MeetingCleanedSegment(sourceSegmentID: "source-0", cleanedText: "First."),
                MeetingCleanedSegment(sourceSegmentID: "source-1", cleanedText: "   "),
            ],
        ]

        for (index, invalid) in invalidCases.enumerated() {
            let fixture = try makeFixture(segmentCount: 2, label: "invalid-\(index)")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
            _ = try fixture.store.markCleanupJobRunning(
                meetingID: fixture.manifest.meetingID,
                jobID: job.id
            )
            #expect(throws: MeetingSessionStoreError.self) {
                try fixture.store.persistCleanupChunk(
                    meetingID: fixture.manifest.meetingID,
                    jobID: job.id,
                    chunkIndex: 0,
                    results: invalid
                )
            }
            #expect(try fixture.store.load(meetingID: fixture.manifest.meetingID).activeCleanupRevisionID == nil)
        }

        let fixture = try makeFixture(segmentCount: 2, label: "conflicting")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(meetingID: fixture.manifest.meetingID, jobID: job.id)
        let accepted = alignedResults(for: fixture.manifest.segments)
        try fixture.store.persistCleanupChunk(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: accepted
        )
        var conflict = accepted
        conflict[0] = MeetingCleanedSegment(sourceSegmentID: "source-0", cleanedText: "Different.")
        #expect(throws: MeetingSessionStoreError.self) {
            try fixture.store.persistCleanupChunk(
                meetingID: fixture.manifest.meetingID,
                jobID: job.id,
                chunkIndex: 0,
                results: conflict
            )
        }
    }

    @Test func sourceEditMarksActiveRevisionAndJobStale() throws {
        let fixture = try makeFixture(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(meetingID: fixture.manifest.meetingID, jobID: job.id)
        try fixture.store.persistCleanupChunk(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: alignedResults(for: fixture.manifest.segments)
        )
        _ = try fixture.store.completeCleanupJob(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            modelRevision: "snapshot-abc"
        )

        var edited = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        edited.segments[0] = MeetingTranscriptSegment(
            id: edited.segments[0].id,
            meetingID: edited.meetingID,
            sequence: 0,
            sourceLabel: "Room",
            text: "the source transcript was corrected",
            isFinal: true
        )
        try fixture.store.saveManifest(edited)
        let reloaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)

        #expect(reloaded.cleanupJobs[0].state == .stale)
        #expect(reloaded.cleanupRevisions[0].state == .stale)
        #expect(reloaded.activeCleanupRevisionID == nil)
        #expect(try fixture.store.activeCleanupRevision(meetingID: fixture.manifest.meetingID) == nil)
    }

    @Test func corruptedValidRevisionIsDeactivatedOnRepositorySave() throws {
        let fixture = try makeFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(meetingID: fixture.manifest.meetingID, jobID: job.id)
        try fixture.store.persistCleanupChunk(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: alignedResults(for: fixture.manifest.segments)
        )
        _ = try fixture.store.completeCleanupJob(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            modelRevision: "snapshot-abc"
        )

        var corrupted = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        corrupted.cleanupRevisions[0].cleanedSegments.removeLast()
        try fixture.store.saveManifest(corrupted)
        let reloaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)

        #expect(reloaded.activeCleanupRevisionID == nil)
        #expect(try fixture.store.activeCleanupRevision(meetingID: fixture.manifest.meetingID) == nil)
        #expect(reloaded.segments == fixture.manifest.segments)
    }

    @Test func relaunchFailureAndRetryStatesAreDurableAndIdempotent() throws {
        let fixture = try makeFixture(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(meetingID: fixture.manifest.meetingID, jobID: job.id)
        try fixture.store.reconcileCleanupJobsAfterRelaunch(meetingID: fixture.manifest.meetingID)
        #expect(try fixture.store.load(meetingID: fixture.manifest.meetingID).cleanupJobs[0].state == .interrupted)

        try fixture.store.makeCleanupRetryAvailable(meetingID: fixture.manifest.meetingID, jobID: job.id)
        #expect(try fixture.store.load(meetingID: fixture.manifest.meetingID).cleanupJobs[0].state == .retryAvailable)
        try fixture.store.queueCleanupRetry(meetingID: fixture.manifest.meetingID, jobID: job.id)
        var loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(loaded.cleanupJobs[0].state == .queued)
        #expect(loaded.cleanupJobs[0].attempt == 2)

        try fixture.store.failCleanupJob(meetingID: fixture.manifest.meetingID, jobID: job.id, message: "load failed")
        try fixture.store.failCleanupJob(meetingID: fixture.manifest.meetingID, jobID: job.id, message: "load failed")
        loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(loaded.cleanupJobs[0].state == .failed)
        #expect(loaded.state == .completed)
    }

    @Test func cancellationIsDurableAndIdempotent() throws {
        let fixture = try makeFixture(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)

        try fixture.store.cancelCleanupJob(meetingID: fixture.manifest.meetingID, jobID: job.id)
        try fixture.store.cancelCleanupJob(meetingID: fixture.manifest.meetingID, jobID: job.id)
        let loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(loaded.cleanupJobs[0].state == .cancelled)
        #expect(loaded.state == .completed)
    }

    @Test func coordinatorCancellationPersistsCancelledWithoutChangingMeeting() async throws {
        let fixture = try makeFixture(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = MeetingCleanupCoordinator(
            store: fixture.store,
            engine: SlowCleanupEngine()
        )
        let task = Task {
            try await coordinator.run(meetingID: fixture.manifest.meetingID)
        }

        for _ in 0..<100 {
            let state = try fixture.store.load(meetingID: fixture.manifest.meetingID)
                .cleanupJobs.first?.state
            if state == .running { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(loaded.cleanupJobs[0].state == .cancelled)
        #expect(loaded.state == .completed)
        #expect(loaded.segments == fixture.manifest.segments)
        #expect(loaded.activeCleanupRevisionID == nil)
    }

    @Test func coordinatorFaultAfterDurableChunkCanRetryAndReplaceDraft() async throws {
        let fixture = try makeFixture(segmentCount: 9)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let engine = StubCleanupEngine()
        let faulting = MeetingCleanupCoordinator(
            store: fixture.store,
            engine: engine,
            checkpoint: { checkpoint in
                if checkpoint == .afterDurableChunk(0) { throw InjectedCleanupFault() }
            }
        )

        await #expect(throws: InjectedCleanupFault.self) {
            try await faulting.run(meetingID: fixture.manifest.meetingID)
        }
        var loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(loaded.state == .completed)
        #expect(loaded.cleanupJobs[0].state == .failed)
        #expect(loaded.cleanupRevisions[0].cleanedSegments.count == 8)
        #expect(loaded.activeCleanupRevisionID == nil)

        let jobID = loaded.cleanupJobs[0].id
        try fixture.store.makeCleanupRetryAvailable(meetingID: fixture.manifest.meetingID, jobID: jobID)
        try fixture.store.queueCleanupRetry(meetingID: fixture.manifest.meetingID, jobID: jobID)
        let retrying = MeetingCleanupCoordinator(store: fixture.store, engine: engine)
        let revision = try await retrying.run(meetingID: fixture.manifest.meetingID)
        loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)

        #expect(revision.state == .valid)
        #expect(revision.cleanedSegments.count == 9)
        #expect(loaded.cleanupRevisions.count == 1)
        #expect(loaded.activeCleanupRevisionID == revision.id)
        #expect(loaded.segments == fixture.manifest.segments)
    }

    @Test func inferenceFailureDoesNotChangeCompletedMeeting() async throws {
        let fixture = try makeFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = MeetingCleanupCoordinator(
            store: fixture.store,
            engine: FailingCleanupEngine()
        )

        await #expect(throws: InjectedCleanupFault.self) {
            try await coordinator.run(meetingID: fixture.manifest.meetingID)
        }
        let loaded = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(loaded.state == .completed)
        #expect(loaded.cleanupJobs[0].state == .failed)
        #expect(loaded.cleanupRevisions[0].cleanedSegments.isEmpty)
        #expect(loaded.activeCleanupRevisionID == nil)
        #expect(loaded.segments == fixture.manifest.segments)
    }

    @Test func failedAtomicReplacementLeavesPreviousManifestReadable() throws {
        let fixture = try makeFixture(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(meetingID: fixture.manifest.meetingID, jobID: job.id)

        let faultingStore = MeetingSessionStore(
            rootDirectory: fixture.root,
            saveFaultInjector: { point in
                if point == .beforeManifestReplacement { throw InjectedCleanupFault() }
            }
        )
        #expect(throws: InjectedCleanupFault.self) {
            try faultingStore.persistCleanupChunk(
                meetingID: fixture.manifest.meetingID,
                jobID: job.id,
                chunkIndex: 0,
                results: alignedResults(for: fixture.manifest.segments)
            )
        }

        let durable = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(durable.cleanupJobs[0].state == .running)
        #expect(durable.cleanupJobs[0].completedChunkCount == 0)
        #expect(durable.cleanupRevisions[0].cleanedSegments.isEmpty)
        #expect(durable.activeCleanupRevisionID == nil)
    }

    @Test func revisionReviewValidityAgreesWithExportGate() throws {
        // lunr-studio/Openbridge-Beta#321 (AC8): the review surface defaults to
        // Cleaned exactly when the lunr-studio/Openbridge-Beta#214 export gate actually
        // exports Cleaned - i.e. a valid, CURRENT ACTIVE revision in the STORE
        // (this exercises activeCleanupRevision + the real exporter, not a bare
        // synthetic fixture).
        let fixture = try makeFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Control: no active revision yet -> neither review nor export offer Cleaned.
        #expect(MeetingRevisionReviewValidity.shouldDefaultToCleaned(
            try? fixture.store.activeCleanupRevision(meetingID: fixture.manifest.meetingID)) == false)
        let controlExport = try fixture.store.exportTranscript(
            meetingID: fixture.manifest.meetingID,
            to: fixture.root.appendingPathComponent("export-control", isDirectory: true),
            format: .txt,
            source: .cleaned
        )
        #expect(controlExport.document.effectiveSource == .original)

        // Drive a real cleanup to completion -> active VALID revision.
        let job = try fixture.store.createCleanupJob(meetingID: fixture.manifest.meetingID)
        _ = try fixture.store.markCleanupJobRunning(meetingID: fixture.manifest.meetingID, jobID: job.id)
        try fixture.store.persistCleanupChunk(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: alignedResults(for: fixture.manifest.segments)
        )
        _ = try fixture.store.completeCleanupJob(
            meetingID: fixture.manifest.meetingID,
            jobID: job.id,
            modelRevision: "snapshot-abc"
        )

        let active = try fixture.store.activeCleanupRevision(meetingID: fixture.manifest.meetingID)
        #expect(active?.state == .valid)
        // Review defaults to Cleaned exactly when the export gate resolves .cleaned.
        #expect(MeetingRevisionReviewValidity.shouldDefaultToCleaned(active) == true)
        let cleanedExport = try fixture.store.exportTranscript(
            meetingID: fixture.manifest.meetingID,
            to: fixture.root.appendingPathComponent("export-active", isDirectory: true),
            format: .txt,
            source: .cleaned
        )
        #expect(cleanedExport.document.effectiveSource == .cleaned)
    }

    @Test func reviewValidityRejectsNonCurrentStaleRevisionLikeExport() throws {
        // lunr-studio/Openbridge-Beta#321 (AC8): a stale or pending revision must
        // be treated identically by review and export - never default to Cleaned.
        #expect(MeetingRevisionReviewValidity.shouldDefaultToCleaned(
            MeetingCleanupRevision(
                id: "stale", meetingID: "x", sourceTranscriptFingerprint: "f",
                sourceSegmentIDs: [], contractVersion: MeetingCleanupContract.version,
                modelRepository: MeetingCleanupContract.modelRepository, modelRevision: nil,
                chunkSize: MeetingCleanupContract.chunkSize, state: .stale,
                createdAt: Date(), completedAt: nil, cleanedSegments: []
            )) == false)
        #expect(MeetingRevisionReviewValidity.shouldDefaultToCleaned(
            MeetingCleanupRevision(
                id: "pending", meetingID: "x", sourceTranscriptFingerprint: "f",
                sourceSegmentIDs: [], contractVersion: MeetingCleanupContract.version,
                modelRepository: MeetingCleanupContract.modelRepository, modelRevision: nil,
                chunkSize: MeetingCleanupContract.chunkSize, state: .pending,
                createdAt: Date(), completedAt: nil, cleanedSegments: []
            )) == false)
    }

    private func makeFixture(
        segmentCount: Int,
        label: String = UUID().uuidString
    ) throws -> (root: URL, store: MeetingSessionStore, manifest: MeetingManifest) {
        let root = temporaryRoot(label)
        let store = MeetingSessionStore(rootDirectory: root)
        let meetingID = "meeting-\(label)"
        let segments = (0..<segmentCount).map { index in
            MeetingTranscriptSegment(
                id: "source-\(index)",
                meetingID: meetingID,
                sequence: index,
                startOffset: Double(index * 30),
                endOffset: Double((index + 1) * 30),
                sourceLabel: "Room",
                text: "raw segment \(index)",
                isFinal: true
            )
        }
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Cleanup Test",
            state: .completed,
            segments: segments
        )
        try store.create(manifest)
        return (root, store, manifest)
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-cleanup-\(label)", isDirectory: true)
    }

    private func alignedResults(for segments: [MeetingTranscriptSegment]) -> [MeetingCleanedSegment] {
        segments.sorted(by: MeetingTranscriptFingerprint.canonicalOrder).map {
            MeetingCleanedSegment(
                sourceSegmentID: $0.id,
                cleanedText: $0.text.capitalized + "."
            )
        }
    }
}

private struct InjectedCleanupFault: Error {}

private struct StubCleanupEngine: MeetingCleanupEngine {
    func cleanMeetingSegments(
        _ segments: [MeetingTranscriptSegment]
    ) async throws -> MeetingCleanupEngineOutput {
        MeetingCleanupEngineOutput(
            contractVersion: MeetingCleanupContract.version,
            modelRepository: MeetingCleanupContract.modelRepository,
            modelRevision: "snapshot-test",
            chunkSize: MeetingCleanupContract.chunkSize,
            segments: segments.map {
                MeetingCleanedSegment(
                    sourceSegmentID: $0.id,
                    cleanedText: $0.text.capitalized + "."
                )
            }
        )
    }
}

private struct FailingCleanupEngine: MeetingCleanupEngine {
    func cleanMeetingSegments(
        _ segments: [MeetingTranscriptSegment]
    ) async throws -> MeetingCleanupEngineOutput {
        throw InjectedCleanupFault()
    }
}

private struct SlowCleanupEngine: MeetingCleanupEngine {
    func cleanMeetingSegments(
        _ segments: [MeetingTranscriptSegment]
    ) async throws -> MeetingCleanupEngineOutput {
        try await Task.sleep(for: .seconds(10))
        throw InjectedCleanupFault()
    }
}
