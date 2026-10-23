import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingRetentionTests {

    // MARK: - Policy decoding

    @Test func deleteAudioAfterTranscriptPolicyDecodesAndRoundTrips() throws {
        let root = temporaryRoot("retention-decode")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let manifest = MeetingManifest(
            meetingID: "policy-test",
            title: "Policy",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0",
                    meetingID: "policy-test",
                    sequence: 0,
                    text: "transcript exists",
                    isFinal: true
                )
            ]
        )
        try store.create(manifest)

        let loaded = try store.load(meetingID: "policy-test")
        #expect(loaded.retentionPolicy == .deleteAudioAfterTranscript)

        // retentionDays is nil for this policy — meeting is never fully pruned
        #expect(loaded.retentionPolicy.retentionDays == nil)
    }

    // MARK: - Safety gate: no transcript

    @Test func audioNotDeletedWhenNoTranscriptExists() throws {
        let root = temporaryRoot("retention-no-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "no-transcript-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "No Transcript",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: []
        )
        try store.create(manifest)

        // Add a fake audio file
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio-data".utf8).write(to: audioURL)

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)

        // Audio must still exist
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - Safety gate: interrupted meeting (recovery pending)

    @Test func audioNotDeletedWhenMeetingInterrupted() throws {
        let root = temporaryRoot("retention-interrupted")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "interrupted-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Interrupted",
            state: .interrupted,
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0",
                    meetingID: meetingID,
                    sequence: 0,
                    text: "transcript exists but recovery pending",
                    isFinal: true
                )
            ]
        )
        try store.create(manifest)

        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio-data".utf8).write(to: audioURL)

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)

        // Audio must still exist despite valid transcript
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - Audio deletion with valid transcript preserves manifest + revisions

    @Test func neverStoreTranscriptCannotCreateCleanupJob() throws {
        // Wave-2 (3876240282): neverStoreTranscript means no transcript is
        // stored - cleanup must not create revisions from an un-stored
        // transcript.
        let root = temporaryRoot("retention-never-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "never-store-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Never Store",
            state: .completed,
            retentionPolicy: .neverStoreTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "hello", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        #expect(throws: (any Error).self) {
            _ = try store.createCleanupJob(meetingID: meetingID)
        }
    }

    @Test func legacyAudioNotDeletedWhenSpanIndexDoesNotCoverDiskIndex() throws {
        // Wave-5 (3876574873): a count-only legacy match is not enough - one
        // meaningful span (segment 0) plus a lone segment_0005.wav on disk
        // must NOT authorize deleting the uncovered recording.
        let root = temporaryRoot("retention-legacy-gap")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "legacy-gap"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Legacy Gap",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: ["[Segment 1] legacy text"],
            segments: []
        )
        try store.create(manifest)
        // Only segment 5 on disk - the span covers index 0, not index 5.
        try Data("audio5".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 5))

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 5).path))
    }

    @Test func legacySpanWithoutSuffixTextDoesNotCoverAudio() throws {
        // Wave-6 (3876623273): "[Segment 1]   " trims to a nonempty span
        // but has NO transcript text after the bracket - it must not count
        // as coverage for index 0, so segment_0000.wav is preserved.
        let root = temporaryRoot("retention-legacy-suffix-ws")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "legacy-suffix-ws"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Legacy Suffix WS",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: ["[Segment 1]   "],
            segments: []
        )
        try store.create(manifest)
        try Data("audio".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 0).path))
    }

    @Test func mixedTypedAndLegacyDoesNotDeleteUncoveredAudio() throws {
        // Wave-8 (3876762103): when typed segments exist, canonical export
        // uses ONLY the typed array (legacy spans are omitted) - the legacy
        // fallback must not authorize deletion that the Original export
        // would omit. Typed covers index 0 only; legacy spans claim 0+1;
        // both WAVs on disk -> audio 1 must be preserved.
        let root = temporaryRoot("retention-mixed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "mixed-typed-legacy"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Mixed",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: ["[Segment 1] legacy 0", "[Segment 2] legacy 1"],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "typed 0", isFinal: true
                )
            ]
        )
        try store.create(manifest)
        try Data("audio0".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))
        try Data("audio1".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 1))

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 1).path))
    }

    @Test func audioNotDeletedWhenTranscriptCoverageIsPartial() throws {
        // Wave-4 (3876353121): a PARTIAL transcript (1 usable segment for 2
        // WAVs on disk) must NOT satisfy the safety gate - finalizing
        // recovery would otherwise delete every still-untranscribed segment.
        let root = temporaryRoot("retention-partial-coverage")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "partial-coverage"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Partial",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "only segment", isFinal: true
                )
            ]
        )
        try store.create(manifest)
        // Two WAVs on disk, only segment 0 transcribed.
        try Data("audio0".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))
        try Data("audio1".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 1))

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 1).path))
    }

    @Test func audioNotDeletedWhenLegacySpanIsWhitespaceOnly() throws {
        // Wave-3 (3876301205): a legacy transcriptSpans entry that is
        // whitespace-only must NOT satisfy the safety gate - deleting the
        // only audio would leave nothing.
        let root = temporaryRoot("retention-legacy-ws")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "legacy-ws-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Legacy WS",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: ["   \n  "]
        )
        try store.create(manifest)
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test func audioNotDeletedWhenTranscriptIsWhitespaceOnly() throws {
        // Wave-1 (3875726281): a whitespace-only successful engine result is
        // not a usable transcript - the destructive delete-audio-after-
        // transcript policy must NOT delete the only audio.
        let root = temporaryRoot("retention-whitespace")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "whitespace-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Whitespace",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "   \n  ", isFinal: true
                )
            ]
        )
        try store.create(manifest)
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test func audioDeletedPreservesTranscriptAndRevisions() throws {
        let root = temporaryRoot("retention-safe-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "safe-delete-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Safe Delete",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0",
                    meetingID: meetingID,
                    sequence: 0,
                    text: "transcript exists",
                    isFinal: true
                ),
                // Wave-4 (3876353121): full coverage - a segment for EVERY
                // recorded audio index is required before destructive
                // deletion, so provide the second one.
                MeetingTranscriptSegment(
                    id: "seg-1", meetingID: meetingID, sequence: 1,
                    text: "second segment",
                    isFinal: true
                )
            ]
        )
        try store.create(manifest)

        // Add audio files
        let audioURL0 = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        let audioURL1 = store.audioSegmentURL(for: meetingID, segmentIndex: 1)
        try Data("audio-0".utf8).write(to: audioURL0)
        try Data("audio-1".utf8).write(to: audioURL1)

        // Add a completed cleanup revision
        let job = try store.createCleanupJob(meetingID: meetingID)
        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)
        try store.persistCleanupChunk(
            meetingID: meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: [
                MeetingCleanedSegment(sourceSegmentID: "seg-0", cleanedText: "Cleaned."),
                MeetingCleanedSegment(sourceSegmentID: "seg-1", cleanedText: "Cleaned second.")
            ]
        )
        let revision = try store.completeCleanupJob(
            meetingID: meetingID, jobID: job.id, modelRevision: "snap"
        )

        // Verify audio exists before deletion
        #expect(FileManager.default.fileExists(atPath: audioURL0.path))

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == true)

        // Audio files are gone
        #expect(!FileManager.default.fileExists(atPath: audioURL0.path))
        #expect(!FileManager.default.fileExists(atPath: audioURL1.path))

        // Transcript is preserved
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.segments.count == 2)
        #expect(loaded.segments[0].text == "transcript exists")

        // Cleanup revisions preserved
        #expect(loaded.cleanupRevisions.count == 1)
        #expect(loaded.cleanupRevisions[0].id == revision.id)
        #expect(loaded.activeCleanupRevisionID == revision.id)

        // audioSegments list cleared
        #expect(loaded.audioSegments.isEmpty)

        // Audio directory still exists (empty)
        let audioDir = store.audioDirectory(for: meetingID)
        #expect(FileManager.default.fileExists(atPath: audioDir.path))
    }

    // MARK: - Non-deleteAudioAfterTranscript policy never triggers audio deletion

    @Test func audioNotDeletedForKeepUntilDeletedPolicy() throws {
        let root = temporaryRoot("retention-keep")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "keep-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Keep",
            state: .completed,
            retentionPolicy: .keepUntilDeleted,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0",
                    meetingID: meetingID,
                    sequence: 0,
                    text: "text",
                    isFinal: true
                )
            ]
        )
        try store.create(manifest)

        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - Cleanup failure does not block audio deletion when transcript valid

    @Test func cleanupFailureDoesNotBlockAudioDeletion() throws {
        let root = temporaryRoot("retention-cleanup-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "failed-cleanup-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Failed Cleanup",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0",
                    meetingID: meetingID,
                    sequence: 0,
                    text: "valid transcript",
                    isFinal: true
                )
            ]
        )
        try store.create(manifest)

        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        // Start and fail cleanup
        let job = try store.createCleanupJob(meetingID: meetingID)
        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)
        try store.failCleanupJob(meetingID: meetingID, jobID: job.id, message: "crashed")

        // Audio can still be deleted — transcript is valid
        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == true)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))

        // Transcript preserved
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.segments.count == 1)
    }

    // MARK: - Legacy spans satisfy safety gate

    @Test func legacySpansSatisfySafetyGateForAudioDeletion() throws {
        let root = temporaryRoot("retention-legacy-spans")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "legacy-spans-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Legacy Spans",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: ["[Segment 1] legacy text"],
            segments: []  // No typed segments
        )
        try store.create(manifest)

        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == true)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))

        // Legacy spans preserved
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.transcriptSpans == ["[Segment 1] legacy text"])
    }

    // MARK: - Time-controlled auto-delete

    @Test func autoDeleteAfter7DaysRemovesExpiredMeetings() throws {
        let root = temporaryRoot("retention-7d")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let baseTime = Date(timeIntervalSince1970: 1_723_032_000)

        // Meeting ended 8 days ago
        let oldMeeting = MeetingManifest(
            meetingID: "old-meeting",
            title: "Old",
            state: .completed,
            startedAt: baseTime.addingTimeInterval(-9 * 24 * 60 * 60),
            endedAt: baseTime.addingTimeInterval(-8 * 24 * 60 * 60),
            retentionPolicy: .autoDeleteAfter7Days,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: "old-meeting", sequence: 0, text: "old", isFinal: true
                )
            ]
        )
        try store.create(oldMeeting)

        // Meeting ended 1 day ago — not yet expired
        let recentMeeting = MeetingManifest(
            meetingID: "recent-meeting",
            title: "Recent",
            state: .completed,
            startedAt: baseTime.addingTimeInterval(-2 * 24 * 60 * 60),
            endedAt: baseTime.addingTimeInterval(-1 * 24 * 60 * 60),
            retentionPolicy: .autoDeleteAfter7Days,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: "recent-meeting", sequence: 0, text: "recent", isFinal: true
                )
            ]
        )
        try store.create(recentMeeting)

        let deletedCount = try store.enforceRetentionPolicy(now: baseTime)
        #expect(deletedCount == 1)

        let remaining = try store.listMeetings()
        #expect(remaining.count == 1)
        #expect(remaining[0].meetingID == "recent-meeting")
    }

    // MARK: - deleteAudioAfterTranscript meetings never pruned by enforceRetentionPolicy

    @Test func neverStoreTranscriptNeverAutoPruned() throws {
        // Wave-7 (3876716826): neverStoreTranscript suppresses transcript
        // STORAGE, not the meeting - enforceRetentionPolicy must never delete
        // the whole meeting (incl. raw audio) for it.
        let root = temporaryRoot("retention-never-store-prune")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "never-store-prune"
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Never Store Prune",
            state: .completed,
            startedAt: started,
            retentionPolicy: .neverStoreTranscript
        )
        try store.create(manifest)
        try Data("audio".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))

        // Far future date - a 0-day policy would prune, but never-store must
        // never be auto-pruned.
        let deleted = try store.enforceRetentionPolicy(now: started.addingTimeInterval(100 * 24 * 60 * 60))
        #expect(deleted == 0)
        #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(for: meetingID).path))
    }

    @Test func deleteAudioAfterTranscriptNeverFullyPruned() throws {
        let root = temporaryRoot("retention-never-prune")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "never-prune-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Never Prune",
            state: .completed,
            startedAt: Date(timeIntervalSince1970: 0),  // Very old
            retentionPolicy: .deleteAudioAfterTranscript,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0, text: "text", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        let deletedCount = try store.enforceRetentionPolicy(now: Date())
        #expect(deletedCount == 0)

        // Meeting still exists
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.meetingID == meetingID)
    }

    // MARK: - Atomic deletion removes revisions atomically

    @Test func deleteRemovesMeetingAndAllCleanupRevisions() throws {
        let root = temporaryRoot("retention-atomic-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "atomic-delete-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Atomic Delete",
            state: .completed,
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0, text: "text", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        // Add cleanup revision + job
        let job = try store.createCleanupJob(meetingID: meetingID)
        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)
        try store.persistCleanupChunk(
            meetingID: meetingID,
            jobID: job.id,
            chunkIndex: 0,
            results: [MeetingCleanedSegment(sourceSegmentID: "seg-0", cleanedText: "Cleaned.")]
        )
        _ = try store.completeCleanupJob(
            meetingID: meetingID, jobID: job.id, modelRevision: "snap"
        )

        // Add audio file
        let audioURL = store.audioSegmentURL(for: meetingID, segmentIndex: 0)
        try Data("audio".utf8).write(to: audioURL)

        // Verify meeting directory exists
        let meetingDir = store.meetingDirectory(for: meetingID)
        #expect(FileManager.default.fileExists(atPath: meetingDir.path))

        // Delete atomically
        try store.delete(meetingID: meetingID)

        // Entire directory including revisions, jobs, manifest, audio is gone
        #expect(!FileManager.default.fileExists(atPath: meetingDir.path))

        // listMeetings no longer contains this meeting
        let remaining = try store.listMeetings()
        #expect(remaining.allSatisfy { $0.meetingID != meetingID })
    }

    @Test func destructiveRetentionPoliciesRequireConfirmationFlag() throws {
        // lunr-studio/Openbridge-Beta#214: auto-delete / never-store / delete-audio-after-transcript are
        // DESTRUCTIVE (they remove user data automatically) — the UI must
        // confirm before applying them. keepUntilDeleted is never destructive.
        #expect(MeetingRetentionPolicy.keepUntilDeleted.isDestructive == false)
        #expect(MeetingRetentionPolicy.autoDeleteAfter7Days.isDestructive)
        #expect(MeetingRetentionPolicy.autoDeleteAfter30Days.isDestructive)
        #expect(MeetingRetentionPolicy.neverStoreTranscript.isDestructive)
        #expect(MeetingRetentionPolicy.deleteAudioAfterTranscript.isDestructive)

        // displayName is the user-facing label (rawValue is a code name).
        #expect(MeetingRetentionPolicy.deleteAudioAfterTranscript.displayName == "Delete audio after transcript")
        #expect(MeetingRetentionPolicy.keepUntilDeleted.displayName == "Keep until deleted")
    }

    @Test func audioNotDeletedWhenTypedSetContainsInvalidSegment() throws {
        // Wave-10 (3876862709): deletion requires the WHOLE typed set to be
        // canonically valid. The coverage set silently filters invalid
        // entries, so a foreign typed segment next to valid ones (covering
        // every WAV) must NOT authorize deletion - the Original export still
        // contains the corrupt entry and the finalize predicate rejects it.
        let root = temporaryRoot("retention-invalid-segment")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "invalid-segment-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Invalid Segment",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "valid 0", isFinal: true
                ),
                MeetingTranscriptSegment(
                    id: "seg-1", meetingID: meetingID, sequence: 1,
                    text: "valid 1", isFinal: true
                ),
                // Foreign meetingID - canonically invalid but its sequence is
                // filtered out of the usable coverage set.
                MeetingTranscriptSegment(
                    id: "seg-foreign", meetingID: "other-meeting", sequence: 2,
                    text: "foreign", isFinal: true
                )
            ]
        )
        try store.create(manifest)
        try Data("audio0".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))
        try Data("audio1".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 1))

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 1).path))
    }

    @Test func audioNotDeletedWhenTypedSetHasDuplicateSequence() throws {
        // Wave-10 (3876862709): uniqueness is part of the canonical validity
        // predicate - two typed segments claiming the same sequence must
        // refuse deletion even though one of them covers the disk audio.
        let root = temporaryRoot("retention-duplicate-seq")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "duplicate-seq-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Duplicate Seq",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "first 0", isFinal: true
                ),
                MeetingTranscriptSegment(
                    id: "seg-0b", meetingID: meetingID, sequence: 0,
                    text: "second 0", isFinal: true
                )
            ]
        )
        try store.create(manifest)
        try Data("audio0".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 0).path))
    }

    @Test func enforceRetentionPolicyReconcilesPendingAudioDeletion() throws {
        // Wave-10 (3876862720): if the process exits after the completed
        // manifest is saved but before the stop-time enforcement block runs,
        // the meeting is terminal while raw audio remains. Startup must
        // reconcile such meetings via the same safety-gated enforcement.
        let root = temporaryRoot("retention-reconcile-pending")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "reconcile-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Reconcile",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "valid transcript", isFinal: true
                )
            ]
        )
        try store.create(manifest)
        try Data("audio0".utf8).write(to: store.audioSegmentURL(for: meetingID, segmentIndex: 0))
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 0).path))

        _ = try store.enforceRetentionPolicy()

        #expect(!FileManager.default.fileExists(atPath: store.audioSegmentURL(for: meetingID, segmentIndex: 0).path))
    }

    @Test func neverStoreRecoveredMeetingCompletesWithoutTranscript() throws {
        // Wave-11 (3876962658): neverStoreTranscript stores NO text by design -
        // the transcript-presence guard must not block completion once the
        // marker-verified path (all audio chunks retried) is used.
        let root = temporaryRoot("retention-never-store-complete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "never-store-complete"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Never Store Complete",
            state: .interrupted,
            retentionPolicy: .neverStoreTranscript,
            transcriptSpans: [],
            segments: []
        )
        try store.create(manifest)

        // Without the bypass the guard still throws.
        var threw = false
        do {
            try store.completeRecoveredMeeting(meetingID: meetingID)
        } catch {
            threw = true
        }
        #expect(threw)

        // The marker-verified path bypasses the guard and completes.
        try store.completeRecoveredMeeting(meetingID: meetingID, allowsEmptyTranscript: true)
        let completed = try store.load(meetingID: meetingID)
        #expect(completed.state == .completed)
        #expect(completed.events.contains { $0.contains("RECOVERED_COMPLETED") })
    }

    @Test func audioNotDeletedWhenAudioDirectoryCannotBeEnumerated() throws {
        // Wave-13 (3877338958): a failed audio-directory enumeration must fail
        // CLOSED. The "audio directory" path exists but is a regular file (a
        // stand-in for a temporarily unreadable directory) - contentsOfDirectory
        // throws while fileExists is true, so the old fallback would read "no
        // audio on disk" and a partial-but-valid transcript could authorize
        // deletion of unverified recordings.
        let root = temporaryRoot("retention-unreadable-audio-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "unreadable-audio-dir-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Unreadable Audio Dir",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "valid segment", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        // Replace the audio directory with a regular file: fileExists is true
        // but contentsOfDirectory fails -> the fail-closed branch.
        let audioDir = store.audioDirectory(for: meetingID)
        try? FileManager.default.removeItem(at: audioDir)
        try Data("not-a-directory".utf8).write(to: audioDir)

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)
        // The path must be untouched (still the regular file).
        #expect(FileManager.default.fileExists(atPath: audioDir.path))
    }

    @Test func audioNotDeletedWhenWAVNameIsUnparseable() throws {
        // Wave-14 (3884384378): a WAV whose name is not a parseable
        // segment_<Int>.wav (e.g. a legacy segment_backup.wav) must REFUSE
        // deletion - it is silently dropped from diskIndices, so without this
        // guard the no-disk branch would authorize deleting audio whose
        // transcript coverage was never established.
        let root = temporaryRoot("retention-unparseable-wav")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "unparseable-wav-meeting"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Unparseable WAV",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "valid segment", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        // The ONLY audio file has an unparseable name.
        let audioDir = store.audioDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audioDir.appendingPathComponent("segment_backup.wav"))

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)
        #expect(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("segment_backup.wav").path))
    }

    @Test func audioNotDeletedWhenWAVNameIsUnparseableAlongsideCovered() throws {
        // Wave-14 (3884384378): even when every parseable index is covered,
        // one unparseable WAV next to them still refuses deletion.
        let root = temporaryRoot("retention-unparseable-wav-mixed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let meetingID = "unparseable-wav-mixed"
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Unparseable WAV Mixed",
            state: .completed,
            retentionPolicy: .deleteAudioAfterTranscript,
            transcriptSpans: [],
            segments: [
                MeetingTranscriptSegment(
                    id: "seg-0", meetingID: meetingID, sequence: 0,
                    text: "valid 0", isFinal: true
                )
            ]
        )
        try store.create(manifest)

        let audioDir = store.audioDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("audio0".utf8).write(to: audioDir.appendingPathComponent("segment_0.wav"))
        try Data("audio1".utf8).write(to: audioDir.appendingPathComponent("segment_backup.wav"))

        let canDelete = store.canSafelyDeleteAudio(try store.load(meetingID: meetingID))
        #expect(canDelete == false)

        let deleted = try store.enforceAudioRetention(meetingID: meetingID)
        #expect(deleted == false)
        #expect(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("segment_0.wav").path))
    }

    // MARK: - Helpers

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-retention-\(label)", isDirectory: true)
    }
}