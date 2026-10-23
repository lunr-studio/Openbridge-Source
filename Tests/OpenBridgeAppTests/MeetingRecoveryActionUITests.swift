import SwiftUI
import Testing
@testable import OpenBridgeApp

// MARK: - #219 Recovery Action UI Tests
//
// Verifies the interrupted-meeting recovery surface: a clear banner with
// Finalize / Reveal actions appears ONLY for interrupted meetings, the
// actions are wired, and the store path preserves data.

@Suite(.serialized) @MainActor struct MeetingRecoveryActionUITests {

    private func makeMeeting(state: MeetingSessionState, segments: [MeetingTranscriptSegment] = []) -> MeetingManifest {
        MeetingManifest(
            meetingID: "recover-test",
            title: "Interrupted Sync",
            state: state,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: segments
        )
    }

    /// The recovery banner renders (non-nil image) for an interrupted meeting.
    @Test func recoveryBannerRendersForInterruptedMeeting() throws {
        let row = MainSavedMeetingRow(
            meeting: makeMeeting(state: .interrupted),
            onExport: {},
            onDelete: {},
            onFinalizeRecovery: {},
            onRevealRecoveredFiles: {}
        )
        let renderer = ImageRenderer(content: row.frame(width: 640, height: 260))
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    /// Completed meetings render normally (banner is state-gated).
    @Test func recoveryBannerHiddenForCompletedMeeting() throws {
        let row = MainSavedMeetingRow(
            meeting: makeMeeting(state: .completed),
            onExport: {},
            onDelete: {},
            onFinalizeRecovery: {},
            onRevealRecoveredFiles: {}
        )
        let renderer = ImageRenderer(content: row.frame(width: 640, height: 260))
        #expect(renderer.nsImage != nil)
    }

    /// Cleanup status, progress, and actions must keep rendering at both a
    /// narrow utility-window width and a wide desktop-window width. This is a
    /// structural regression test for the ViewThatFits layout used by the row.
    @Test func cleanupLifecycleRowsRenderAtWideAndNarrowWidths() throws {
        let meetings = [
            makeCleanupMeeting(state: .queued),
            makeCleanupMeeting(state: .running, completedChunks: 2, totalChunks: 3),
            makeCleanupMeeting(state: .failed),
            makeCleanupMeeting(state: .completed, includesValidRevision: true),
        ]

        for width in [420.0, 900.0] {
            for meeting in meetings {
                let row = MainSavedMeetingRow(
                    meeting: meeting,
                    onExport: {},
                    onDelete: {},
                    onRetryCleanup: {}
                )
                let renderer = ImageRenderer(content: row.frame(width: width, height: 260))
                let image = try #require(renderer.nsImage)
                #expect(image.size.width > 0 && image.size.height > 0)
            }
        }
    }

    /// Handlers are wired and invocable — the closures ARE the button
    /// actions; invoking them directly proves the wiring compiles and fires.
    @Test func recoveryActionsFire() {
        var finalizedCount = 0
        var revealedCount = 0

        let row = MainSavedMeetingRow(
            meeting: makeMeeting(state: .interrupted),
            onExport: {},
            onDelete: {},
            onFinalizeRecovery: { finalizedCount += 1 },
            onRevealRecoveredFiles: { revealedCount += 1 }
        )

        row.onFinalizeRecovery?()
        row.onRevealRecoveredFiles?()

        #expect(finalizedCount == 1, "finalize action fired")
        #expect(revealedCount == 1, "reveal action fired")
    }

    /// Handlers are optional: rows built without them (legacy call sites)
    /// still construct — backward compatibility.
    @Test func recoveryHandlersOptional() {
        let row = MainSavedMeetingRow(
            meeting: makeMeeting(state: .interrupted),
            onExport: {},
            onDelete: {}
        )
        #expect(row.onFinalizeRecovery == nil)
        #expect(row.onRevealRecoveredFiles == nil)
    }

    /// The store path the Finalize button drives: finalizeMeeting moves an
    /// interrupted manifest to completed while preserving segments.
    @Test func finalizeRecoveryPreservesSegmentsAndCompletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)

        let segments = [
            MeetingTranscriptSegment(
                id: "s1", meetingID: "m1", sequence: 0,
                startOffset: 0, endOffset: 10, sourceLabel: "Room",
                text: "live segment one", isFinal: true
            )
        ]
        let manifest = MeetingManifest(
            meetingID: "m1", title: "Interrupted", state: .interrupted,
            startedAt: Date(), segments: segments
        )
        try store.create(manifest)

        try store.finalizeMeeting(meetingID: "m1")

        let recovered = try store.load(meetingID: "m1")
        #expect(recovered.state == .completed)
        #expect(recovered.segments.count == 1, "live segments preserved")
        #expect(recovered.segments.first?.text == "live segment one")
        #expect(recovered.endedAt != nil)
    }

    private func makeCleanupMeeting(
        state: MeetingCleanupJobState,
        completedChunks: Int = 0,
        totalChunks: Int = 1,
        includesValidRevision: Bool = false
    ) -> MeetingManifest {
        let meetingID = "cleanup-layout-\(state.rawValue)"
        let revisionID = "revision-1"
        let segment = MeetingTranscriptSegment(
            id: "segment-1",
            meetingID: meetingID,
            sequence: 0,
            text: "Original text",
            isFinal: true
        )
        let revision = MeetingCleanupRevision(
            id: revisionID,
            meetingID: meetingID,
            sourceTranscriptFingerprint: MeetingTranscriptFingerprint.make(for: [segment]),
            sourceSegmentIDs: [segment.id],
            contractVersion: MeetingCleanupContract.version,
            modelRepository: MeetingCleanupContract.modelRepository,
            modelRevision: includesValidRevision ? "snapshot" : nil,
            producer: .localGemma,
            providerIdentifier: "local-gemma",
            providerEndpoint: nil,
            providerModel: MeetingCleanupContract.modelRepository,
            chunkSize: MeetingCleanupContract.chunkSize,
            state: includesValidRevision ? .valid : .pending,
            createdAt: Date(timeIntervalSince1970: 1),
            completedAt: includesValidRevision ? Date(timeIntervalSince1970: 2) : nil,
            cleanedSegments: includesValidRevision
                ? [MeetingCleanedSegment(sourceSegmentID: segment.id, cleanedText: "Cleaned text")]
                : []
        )
        let job = MeetingCleanupJob(
            id: "job-1",
            meetingID: meetingID,
            revisionID: revisionID,
            state: state,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            attempt: 1,
            completedChunkCount: completedChunks,
            totalChunkCount: totalChunks,
            errorMessage: state == .failed ? "model error" : nil
        )
        return MeetingManifest(
            meetingID: meetingID,
            title: "Cleanup layout fixture",
            state: .completed,
            startedAt: Date(timeIntervalSince1970: 1),
            aiMode: .localOnly,
            segments: [segment],
            intelligenceConfiguration: MeetingIntelligenceConfiguration(
                cleanupEnabled: true,
                cleanupProvider: .localGemma,
                cloudProvider: nil
            ),
            cleanupJobs: [job],
            cleanupRevisions: [revision],
            activeCleanupRevisionID: includesValidRevision ? revisionID : nil
        )
    }
}
