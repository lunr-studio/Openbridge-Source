import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingRecoveryTests {

    // MARK: - State needsRecovery

    @Test func newStatesAreRecoverable() throws {
        #expect(MeetingSessionState.recording.needsRecovery)
        #expect(MeetingSessionState.stopped.needsRecovery)
        #expect(MeetingSessionState.interrupted.needsRecovery)
        #expect(MeetingSessionState.captured.needsRecovery)
        #expect(MeetingSessionState.transcribingLive.needsRecovery)
        #expect(MeetingSessionState.finalizing.needsRecovery)
        #expect(MeetingSessionState.failed.needsRecovery)
        #expect(MeetingSessionState.recoveryNeeded.needsRecovery)
    }

    @Test func terminalStatesAreNotRecoverable() throws {
        #expect(!MeetingSessionState.completed.needsRecovery)
        #expect(!MeetingSessionState.exported.needsRecovery)
    }

    @Test func newStatesRoundTripThroughCodable() throws {
        let states: [MeetingSessionState] = [
            .captured, .transcribingLive, .finalizing, .failed, .recoveryNeeded
        ]
        for state in states {
            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(MeetingSessionState.self, from: encoded)
            #expect(decoded == state)
        }
    }

    // MARK: - Detect incomplete sessions

    @Test func detectIncompleteSessionsSurfacesNonTerminalMeetings() throws {
        let root = temporaryRoot("detect-incomplete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        // Completed meeting — NOT incomplete
        try store.create(MeetingManifest(
            meetingID: "completed-1", title: "Done", state: .completed
        ))

        // Interrupted meeting — IS incomplete
        try store.create(MeetingManifest(
            meetingID: "interrupted-1", title: "Crashed", state: .interrupted
        ))

        // Failed meeting — IS incomplete
        try store.create(MeetingManifest(
            meetingID: "failed-1", title: "Failed", state: .failed
        ))

        // Recovery needed — IS incomplete
        try store.create(MeetingManifest(
            meetingID: "recovery-1", title: "Recovery", state: .recoveryNeeded
        ))

        let incomplete = try store.detectIncompleteSessions()
        let incompleteIDs = Set(incomplete.map(\.meetingID))

        #expect(!incompleteIDs.contains("completed-1"))
        #expect(incompleteIDs.contains("interrupted-1"))
        #expect(incompleteIDs.contains("failed-1"))
        #expect(incompleteIDs.contains("recovery-1"))
    }

    @Test func detectIncompleteSessionsTransitionsLeftoverRecordingToInterrupted() throws {
        let root = temporaryRoot("detect-transition")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        // #294 (Alex QA): a force-quit leaves the manifest at .recording —
        // relaunch detection must transition it to .interrupted so the UI
        // never shows a dead meeting as still "Recording".
        try store.create(MeetingManifest(
            meetingID: "recording-1", title: "Crashed Mid-Record", state: .recording
        ))
        try store.create(MeetingManifest(
            meetingID: "transcribing-1", title: "Crashed Mid-Transcribe", state: .transcribingLive
        ))

        let incomplete = try store.detectIncompleteSessions()
        let incompleteIDs = Set(incomplete.map(\.meetingID))
        #expect(incompleteIDs.contains("recording-1"))
        #expect(incompleteIDs.contains("transcribing-1"))

        // The durable state is now truthful (interrupted, not recording).
        #expect(try store.load(meetingID: "recording-1").state == .interrupted)
        #expect(try store.load(meetingID: "transcribing-1").state == .interrupted)
    }

    @Test func detectIncompleteSessionsRecoversActiveJournalTiming() throws {
        let root = temporaryRoot("detect-active-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let meetingID = "active-journal-1"
        let filename = "segment_0000.wav"
        try store.create(MeetingManifest(
            meetingID: meetingID,
            title: "Force Quit",
            state: .recording,
            activeJournal: MeetingActiveJournal(
                filename: filename,
                segmentIndex: 0,
                startOffset: 12.5
            )
        ))
        try MeetingWAVFile.write(
            pcm: Data(repeating: 0, count: 16_000 * 2),
            sampleRate: 16_000,
            to: store.audioDirectory(for: meetingID).appendingPathComponent(filename)
        )

        _ = try store.detectIncompleteSessions()
        let recovered = try store.load(meetingID: meetingID)

        #expect(recovered.state == .interrupted)
        #expect(recovered.audioSegments == [filename])
        #expect(recovered.lastCompletedSegmentIndex == 1)
        #expect(recovered.activeJournal == nil)
        #expect(recovered.chunkBoundaries.count == 1)
        #expect(recovered.chunkBoundaries[0].startOffset == 12.5)
        #expect(recovered.chunkBoundaries[0].endOffset == 13.5)
        #expect(recovered.chunkBoundaries[0].reason == .stop)
    }

    @Test func recoveryDoesNotClearJournalAheadOfBoundaryHistory() throws {
        let root = temporaryRoot("detect-ahead-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let meetingID = "ahead-journal-1"
        let journal = MeetingActiveJournal(
            filename: "segment_0001.wav",
            segmentIndex: 1,
            startOffset: 9.4
        )
        try store.create(MeetingManifest(
            meetingID: meetingID,
            title: "Behind Manifest",
            state: .recording,
            activeJournal: journal
        ))
        try MeetingWAVFile.write(
            pcm: Data(repeating: 0, count: 16_000 * 2),
            sampleRate: 16_000,
            to: store.audioSegmentURL(for: meetingID, segmentIndex: 1)
        )

        _ = try store.detectIncompleteSessions()
        let recovered = try store.load(meetingID: meetingID)

        #expect(recovered.state == .interrupted)
        #expect(recovered.activeJournal == journal)
        #expect(recovered.chunkBoundaries.isEmpty)
        #expect(recovered.lastCompletedSegmentIndex == 0)
    }

    @Test func detectIncompleteSessionsReconcilesRunningCleanupJobs() throws {
        let root = temporaryRoot("detect-reconcile")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "cleanup-interrupted"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Cleanup Interrupted",
            state: .completed,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "text", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        // Create a cleanup job and mark it running
        let job = try store.createCleanupJob(meetingID: meetingID)
        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)

        // Simulate relaunch detection
        let incomplete = try store.detectIncompleteSessions()
        // #219 rebuilt flow: a completed meeting whose cleanup job was
        // interrupted IS surfaced (the user is owed a retry decision) —
        // but the meeting state itself stays .completed (never lied about).
        #expect(incomplete.count == 1)
        #expect(incomplete.first?.meetingID == meetingID)
        #expect(incomplete.first?.state == .completed)

        // And the running job should be reconciled to interrupted
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.cleanupJobs.first?.state == .interrupted)
    }

    // MARK: - Mark failed / recovery needed

    @Test func markMeetingAsFailedPreservesAudioAndTranscript() throws {
        let root = temporaryRoot("mark-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "fail-test"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Will Fail",
            state: .recording,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: meetingID, sequence: 0,
                text: "partial", isFinal: true
            )]
        )
        try store.create(manifest)

        // Add audio file
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        try store.markMeetingAsFailed(meetingID: meetingID, reason: "Engine crashed")

        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.state == .failed)
        #expect(loaded.events.contains { $0.contains("FAILED: Engine crashed") })

        // Audio and transcript preserved
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(loaded.segments.count == 1)
    }

    @Test func markMeetingAsFailedNeverDowngradesCompleted() throws {
        let root = temporaryRoot("no-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "completed-no-downgrade"
        try store.create(MeetingManifest(
            meetingID: meetingID, title: "Done", state: .completed
        ))

        try store.markMeetingAsFailed(meetingID: meetingID, reason: "late error")

        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.state == .completed)
    }

    @Test func inMemoryFailureOverlayReplacesStaleRecordingState() {
        let recording = MeetingManifest(
            meetingID: "stale-recording",
            title: "Storage Failed",
            state: .recording
        )

        let updated = MeetingCaptureFailurePresentation.applyingFailure(
            to: [recording],
            meetingID: recording.meetingID,
            reason: "disk full"
        )

        #expect(updated[0].state == .failed)
        #expect(updated[0].events.contains("FAILED_IN_MEMORY: disk full"))
    }

    // MARK: - Evaluate recovery

    @Test func evaluateRecoveryDetectsAudioAndTranscript() throws {
        let root = temporaryRoot("eval-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        // Meeting with audio but no transcript
        let meetingID = "eval-1"
        try store.create(MeetingManifest(
            meetingID: meetingID, title: "Audio Only", state: .interrupted
        ))
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        let assessment = try store.evaluateRecovery(meetingID: meetingID)
        #expect(assessment.hasAudioFiles)
        #expect(!assessment.hasPartialTranscript)
        #expect(assessment.canRetryTranscription)
        #expect(!assessment.isUnrecoverable)

        // Meeting with no audio and no transcript
        let meetingID2 = "eval-2"
        try store.create(MeetingManifest(
            meetingID: meetingID2, title: "Nothing", state: .failed
        ))
        let assessment2 = try store.evaluateRecovery(meetingID: meetingID2)
        #expect(!assessment2.hasAudioFiles)
        #expect(!assessment2.hasPartialTranscript)
        #expect(assessment2.isUnrecoverable)
    }

    @Test func evaluateRecoveryDetectsInterruptedCleanup() throws {
        let root = temporaryRoot("eval-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "eval-cleanup-1"
        try store.create(MeetingManifest(
            meetingID: meetingID,
            title: "Has Cleanup",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: meetingID, sequence: 0,
                text: "text", isFinal: true
            )]
        ))

        let job = try store.createCleanupJob(meetingID: meetingID)
        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)
        try store.reconcileCleanupJobsAfterRelaunch(meetingID: meetingID)

        let assessment = try store.evaluateRecovery(meetingID: meetingID)
        #expect(assessment.hasInterruptedCleanup)
    }

    // MARK: - Complete recovered meeting

    @Test func completeRecoveredMeetingRequiresTranscript() throws {
        let root = temporaryRoot("complete-no-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "no-transcript-complete"
        try store.create(MeetingManifest(
            meetingID: meetingID, title: "Empty", state: .recoveryNeeded
        ))

        #expect(throws: MeetingSessionStoreError.self) {
            try store.completeRecoveredMeeting(meetingID: meetingID)
        }
    }

    @Test func completeRecoveredMeetingWithTranscriptSucceeds() throws {
        let root = temporaryRoot("complete-with-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "transcript-complete"
        try store.create(MeetingManifest(
            meetingID: meetingID,
            title: "Has Transcript",
            state: .recoveryNeeded,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: meetingID, sequence: 0,
                text: "recovered text", isFinal: true
            )]
        ))

        try store.completeRecoveredMeeting(meetingID: meetingID)

        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.state == .completed)
        #expect(loaded.endedAt != nil)
        #expect(loaded.events.contains { $0.contains("RECOVERED_COMPLETED") })
    }

    // MARK: - Delete unrecoverable session

    @Test func deleteUnrecoverableSessionRemovesEverything() throws {
        let root = temporaryRoot("delete-unrecoverable")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "unrecoverable-delete"
        try store.create(MeetingManifest(
            meetingID: meetingID, title: "Dead", state: .failed
        ))

        let meetingDir = store.meetingDirectory(for: meetingID)
        #expect(FileManager.default.fileExists(atPath: meetingDir.path))

        try store.deleteUnrecoverableSession(meetingID: meetingID)

        #expect(!FileManager.default.fileExists(atPath: meetingDir.path))

        // Deletion should be logged
        let logURL = root.appendingPathComponent(".recovery-deletions.log")
        let logContent = try String(contentsOf: logURL, encoding: .utf8)
        #expect(logContent.contains("DELETED_UNRECOVERABLE"))
        #expect(logContent.contains(meetingID))
    }

    // MARK: - Cleanup failure doesn't mark completed meeting as failed

    @Test func cleanupFailurePreservesCompletedState() throws {
        let root = temporaryRoot("cleanup-fail-completed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "cleanup-fail"
        try store.create(MeetingManifest(
            meetingID: meetingID,
            title: "Completed",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: meetingID, sequence: 0,
                text: "text", isFinal: true
            )]
        ))

        // Start cleanup and fail it
        let job = try store.createCleanupJob(meetingID: meetingID)
        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)
        try store.failCleanupJob(meetingID: meetingID, jobID: job.id, message: "model error")

        let loaded = try store.load(meetingID: meetingID)
        // Meeting stays completed despite cleanup failure
        #expect(loaded.state == .completed)
        #expect(loaded.cleanupJobs.first?.state == .failed)

        // Attempting to mark it failed should be a no-op
        try store.markMeetingAsFailed(meetingID: meetingID, reason: "should not work")
        let loaded2 = try store.load(meetingID: meetingID)
        #expect(loaded2.state == .completed)
    }

    // MARK: - Idempotent recovery operations

    @Test func markingFailedMultipleTimesIsIdempotent() throws {
        let root = temporaryRoot("idempotent-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "idempotent"
        try store.create(MeetingManifest(
            meetingID: meetingID, title: "Idempotent", state: .recording
        ))

        try store.markMeetingAsFailed(meetingID: meetingID, reason: "first error")
        try store.markMeetingAsFailed(meetingID: meetingID, reason: "second error")
        try store.markMeetingAsFailed(meetingID: meetingID, reason: "third error")

        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.state == .failed)
        // Each call appends an event, but state is stable
        let failEvents = loaded.events.filter { $0.contains("FAILED:") }
        #expect(failEvents.count == 3)
    }

    // MARK: - Relaunch detection preserves audio on force-quit

    @Test func forceQuitDuringRecordingLeavesRecoverableAudio() throws {
        let root = temporaryRoot("force-quit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "force-quit-test"
        try store.create(MeetingManifest(
            meetingID: meetingID, title: "Recording", state: .recording
        ))

        // Simulate audio captured during recording
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio-segment".utf8).write(to: audioURL)

        // Simulate force-quit: the manifest still says "recording"

        // On relaunch, detect incomplete sessions
        let incomplete = try store.detectIncompleteSessions()
        #expect(incomplete.contains { $0.meetingID == meetingID })

        // Evaluate recovery — audio should be present
        let assessment = try store.evaluateRecovery(meetingID: meetingID)
        #expect(assessment.hasAudioFiles)
        #expect(assessment.canRetryTranscription)

        // Audio file still on disk
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - Helpers

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recovery-\(label)", isDirectory: true)
    }
}
