import SwiftUI
import Testing
@testable import OpenBridgeApp

// MARK: - #219 Fault-Injection Recovery Tests (RED-first)
//
// These encode the "recovery that cannot lie" contract at the store and
// flow boundaries. Written FIRST against the current production behavior:
// several MUST FAIL until the lying paths are removed and the recovery
// flow is rebuilt (pre-start comment: issuecomment-5402802399).

@Suite(.serialized) @MainActor struct MeetingRecoveryFaultInjectionTests {

    private func makeStore() throws -> (MeetingSessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-fi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingSessionStore(rootDirectory: root), root)
    }

    private func makeSegment(_ n: Int, meeting: String, text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: "seg-\(n)", meetingID: meeting, sequence: n,
            startOffset: TimeInterval(n * 60), endOffset: TimeInterval(n * 60 + 60),
            sourceLabel: "Room", text: text, isFinal: true
        )
    }

    // ---------------------------------------------------------------
    // FI-1: audio-only meeting (crash before ANY transcript persisted)
    // ---------------------------------------------------------------

    /// The guarded path refuses to complete a transcriptless meeting.
    @Test func audioOnlyMeetingCannotCompleteViaGuardedPath() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "audio-only", title: "Crashed", state: .interrupted,
            startedAt: Date(), audioSegments: ["segment_0000.wav", "segment_0001.wav"]
        ))
        let audioDir = root.appendingPathComponent("audio-only/audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        for name in ["segment_0000.wav", "segment_0001.wav"] {
            try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioDir.appendingPathComponent(name))
        }

        let assessment = try store.evaluateRecovery(meetingID: "audio-only")
        #expect(assessment.hasAudioFiles, "audio detected")
        #expect(!assessment.hasPartialTranscript, "no transcript — must be visible in the verdict")

        #expect(throws: MeetingSessionStoreError.self) {
            try store.completeRecoveredMeeting(meetingID: "audio-only")
        }
        let still = try store.load(meetingID: "audio-only")
        #expect(still.state != .completed, "audio-only meeting can NEVER complete without a transcript")
    }

    /// FI-1b: the production recovery action must route through the guarded
    /// path. RED today: no router exists — MainWindowView still calls the
    /// unconditional store.finalizeMeeting.
    @Test func recoveryRouterNeverCompletesTranscriptlessMeeting() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "audio-only-2", title: "Crashed", state: .interrupted,
            startedAt: Date(), audioSegments: ["segment_0000.wav"]
        ))

        let outcome = try RecoveryActionRouter.route(
            action: .finalize, meetingID: "audio-only-2", store: store
        )
        #expect(outcome == .refusedNoTranscript, "router refuses transcriptless completion")
        let m = try store.load(meetingID: "audio-only-2")
        #expect(m.state != .completed)
    }

    /// FI-1d (P1): a manifest whose only transcript data is invalid —
    /// whitespace-only spans, empty/foreign/non-final segments — must be
    /// REFUSED, not completed.
    @Test func routerRefusesInvalidTranscriptData() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "junk-transcript", title: "Junk", state: .interrupted,
            startedAt: Date(),
            transcriptSpans: ["   ", "\t\n"],
            segments: [
                // Foreign meeting, non-final, empty text — all invalid.
                MeetingTranscriptSegment(
                    id: "x1", meetingID: "other-meeting", sequence: 0,
                    sourceLabel: "Room", text: "valid text", isFinal: true
                ),
                MeetingTranscriptSegment(
                    id: "x2", meetingID: "junk-transcript", sequence: 1,
                    sourceLabel: "Room", text: "not final", isFinal: false
                ),
                MeetingTranscriptSegment(
                    id: "x3", meetingID: "junk-transcript", sequence: 2,
                    sourceLabel: "Room", text: "   ", isFinal: true
                )
            ]
        ))

        let outcome = try RecoveryActionRouter.route(
            action: .finalize, meetingID: "junk-transcript", store: store
        )
        #expect(outcome == .refusedNoTranscript, "invalid transcript data is not completable")
        let m = try store.load(meetingID: "junk-transcript")
        #expect(m.state != .completed)
    }

    /// FI-1c: with a transcript the guarded path completes and preserves it.
    @Test func recoveryRouterCompletesMeetingWithTranscript() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "has-transcript", title: "Interrupted", state: .interrupted,
            startedAt: Date(),
            segments: [makeSegment(0, meeting: "has-transcript", text: "live text")]
        ))

        let outcome = try RecoveryActionRouter.route(
            action: .finalize, meetingID: "has-transcript", store: store
        )
        #expect(outcome == .completed)
        let m = try store.load(meetingID: "has-transcript")
        #expect(m.state == .completed)
        #expect(m.segments.first?.text == "live text", "transcript preserved")
    }

    // ---------------------------------------------------------------
    // FI-2: interrupted cleanup jobs (relaunch boundary)
    // ---------------------------------------------------------------

    /// A .running cleanup job at relaunch is reconciled AND the meeting is
    /// surfaced (detection result, not a silent flip).
    @Test func relaunchSurfacesInterruptedCleanupJobs() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "cleanup-crash", title: "Cleanup Interrupted", state: .completed,
            startedAt: Date(),
            segments: [makeSegment(0, meeting: "cleanup-crash", text: "original text")]
        ))
        var manifest = try store.load(meetingID: "cleanup-crash")
        manifest.cleanupJobs = [MeetingCleanupJob(
            id: "job-1", meetingID: "cleanup-crash", revisionID: "rev-1",
            state: .running,
            createdAt: Date(), updatedAt: Date(),
            attempt: 1, completedChunkCount: 0, totalChunkCount: 1, errorMessage: nil
        )]
        try store.saveManifest(manifest)

        let surfaced = try store.detectIncompleteSessions()
        #expect(surfaced.contains { $0.meetingID == "cleanup-crash" },
                "interrupted cleanup surfaces the meeting")

        let reconciled = try store.load(meetingID: "cleanup-crash")
        let jobState = reconciled.cleanupJobs.first?.state
        #expect(jobState == .interrupted || jobState == .retryAvailable,
                "reconciled to a recovery-visible state, got: \(String(describing: jobState))")
    }

    /// Interrupted cleanup NEVER fails the completed meeting itself.
    @Test func interruptedCleanupCannotFailCompletedMeeting() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "stay-completed", title: "Keep", state: .completed,
            startedAt: Date(),
            segments: [makeSegment(0, meeting: "stay-completed", text: "kept")]
        ))
        var manifest = try store.load(meetingID: "stay-completed")
        manifest.cleanupJobs = [MeetingCleanupJob(
            id: "job-2", meetingID: "stay-completed", revisionID: "rev-2",
            state: .running,
            createdAt: Date(), updatedAt: Date(),
            attempt: 1, completedChunkCount: 0, totalChunkCount: 1, errorMessage: nil
        )]
        try store.saveManifest(manifest)

        _ = try store.detectIncompleteSessions()

        let m = try store.load(meetingID: "stay-completed")
        #expect(m.state == .completed, "cleanup interruption never fails a completed meeting")
        #expect(!m.segments.isEmpty, "original transcript untouched")
    }

    // ---------------------------------------------------------------
    // FI-3: provider failure isolation (production boundary)
    // ---------------------------------------------------------------

    /// A provider failure is isolated — never recorded as capture or
    /// transcription failure on the meeting.
    @Test func providerFailureNeverMarksMeetingFailed() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.create(MeetingManifest(
            meetingID: "provider-fail", title: "Cloud Down", state: .recording,
            startedAt: Date(), audioSegments: ["segment_0000.wav"]
        ))

        let outcome = try RecoveryActionRouter.route(
            action: .providerFailure("provider unreachable"), meetingID: "provider-fail", store: store
        )
        #expect(outcome == .isolatedProviderFailure, "provider failure isolated")
        let m = try store.load(meetingID: "provider-fail")
        #expect(m.state != .failed, "provider failure must never mark the meeting failed")
        #expect(m.state == .recording || m.state == .interrupted,
                "meeting stays recoverable, got: \(m.state)")
    }
}
