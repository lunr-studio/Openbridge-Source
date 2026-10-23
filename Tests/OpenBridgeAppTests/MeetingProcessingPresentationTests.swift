import Foundation
import Testing
@testable import OpenBridgeApp

@Suite struct MeetingProcessingPresentationTests {
    @Test func finalizationAndDeferredCleanupAreExplicit() {
        var finalizing = baseManifest()
        finalizing.state = .finalizing
        let finalizingPresentation = MeetingProcessingPresentation.make(manifest: finalizing)
        #expect(finalizingPresentation.phase == .finalizingTranscript)
        #expect(finalizingPresentation.showsProgress)
        #expect(finalizingPresentation.exportActionTitle == "Export Original")

        let deferredPresentation = MeetingProcessingPresentation.make(
            manifest: baseManifest(),
            isCleanupDeferred: true
        )
        #expect(deferredPresentation.phase == .cleanupQueued)
        #expect(deferredPresentation.badgeText == "Cleanup queued")
        #expect(deferredPresentation.totalChunkCount == 1)
        #expect(deferredPresentation.exportDialogMessage.contains("export again"))
    }

    @Test func capturedAndStoppedMeetingsRequireRecoveryInsteadOfSpinningForever() {
        for state in [MeetingSessionState.captured, .stopped] {
            var meeting = baseManifest()
            meeting.state = state

            let presentation = MeetingProcessingPresentation.make(manifest: meeting)
            #expect(presentation.phase == .originalOnly)
            #expect(presentation.badgeText == "Needs recovery")
            #expect(!presentation.showsProgress)
            #expect(presentation.detailText.contains("recovery actions"))
        }
    }

    @Test func durableCleanupStatesDriveOnePresentationContract() {
        let cases: [(MeetingCleanupJobState, MeetingProcessingPhase, Bool, Bool)] = [
            (.queued, .cleanupQueued, false, false),
            (.running, .cleanupRunning, false, false),
            (.failed, .cleanupFailed, true, false),
            (.interrupted, .cleanupFailed, true, false),
            (.retryAvailable, .cleanupFailed, true, false),
            (.cancelled, .originalOnly, false, false),
            (.stale, .originalOnly, false, false),
        ]

        for (jobState, expectedPhase, expectedRetry, expectedCleanedExport) in cases {
            let presentation = MeetingProcessingPresentation.make(
                manifest: manifest(jobState: jobState)
            )
            #expect(presentation.phase == expectedPhase)
            #expect(presentation.allowsCleanupRetry == expectedRetry)
            #expect(presentation.includesCleanedExport == expectedCleanedExport)
            #expect(!presentation.detailText.isEmpty)
        }
    }

    @Test func validActiveRevisionIsTheOnlyCleanedReadyState() {
        let presentation = MeetingProcessingPresentation.make(
            manifest: manifest(jobState: .completed, activeRevision: true)
        )
        #expect(presentation.phase == .cleanedReady)
        #expect(presentation.badgeText == "Cleaned ready")
        #expect(presentation.includesCleanedExport)
        #expect(presentation.exportActionTitle == "Export Original + Cleaned")
        #expect(!presentation.allowsCleanupRetry)
    }

    @Test func runningProgressReportsDurableChunkCount() {
        var meeting = manifest(jobState: .running)
        meeting.cleanupJobs[0] = MeetingCleanupJob(
            id: meeting.cleanupJobs[0].id,
            meetingID: meeting.meetingID,
            revisionID: meeting.cleanupJobs[0].revisionID,
            state: .running,
            createdAt: meeting.cleanupJobs[0].createdAt,
            updatedAt: meeting.cleanupJobs[0].updatedAt,
            attempt: 1,
            completedChunkCount: 2,
            totalChunkCount: 3,
            errorMessage: nil
        )

        let presentation = MeetingProcessingPresentation.make(manifest: meeting)
        #expect(presentation.badgeText == "Cleaning 2/3")
        #expect(presentation.progressValue == 2.0 / 3.0)
        #expect(presentation.detailText.contains("2 of 3 chunks saved"))
    }

    @Test func invalidActiveRevisionCannotAdvertiseOrExportCleaned() {
        var meeting = manifest(jobState: .completed, activeRevision: true)
        meeting.segments = [
            MeetingTranscriptSegment(
                id: "segment-0",
                meetingID: meeting.meetingID,
                sequence: 0,
                text: "Transcript changed after cleanup",
                isFinal: true
            )
        ]

        let presentation = MeetingProcessingPresentation.make(manifest: meeting)
        #expect(presentation.phase == .originalOnly)
        #expect(!presentation.includesCleanedExport)
        #expect(presentation.exportActionTitle == "Export Original")
    }

    @Test func failureCopyIsUsefulButDoesNotEchoDurablePayloads() {
        var meeting = manifest(jobState: .failed)
        let job = meeting.cleanupJobs[0]
        meeting.cleanupJobs[0] = MeetingCleanupJob(
            id: job.id,
            meetingID: job.meetingID,
            revisionID: job.revisionID,
            state: .failed,
            createdAt: job.createdAt,
            updatedAt: job.updatedAt,
            attempt: job.attempt,
            completedChunkCount: 0,
            totalChunkCount: job.totalChunkCount,
            errorMessage: "Expected 7 cleaned segments, received 6. sk-secret raw transcript"
        )

        let presentation = MeetingProcessingPresentation.make(manifest: meeting)
        #expect(presentation.detailText.contains("one valid result for every transcript segment"))
        #expect(!presentation.detailText.contains("sk-secret"))
        #expect(!presentation.detailText.contains("raw transcript"))
    }

    @Test func cloudAuthorizationFailuresExplainTheRequiredRecoveryAction() {
        let cases: [(CleanupFailureReason, String)] = [
            (.cloudDisabled, "Enable it"),
            (.consentRequired, "authorization"),
            (.connectionTestRequired, "Test Connection"),
            (.configurationChanged, "provider configuration changed"),
            (.requestAlreadyActive, "still running"),
        ]

        for (failureReason, expectedCopy) in cases {
            let meeting = manifest(
                jobState: .failed,
                provider: .cloud,
                failureReason: failureReason
            )
            let presentation = MeetingProcessingPresentation.make(manifest: meeting)
            #expect(presentation.detailText.contains(expectedCopy))
            #expect(!presentation.detailText.contains("sk-"))
            #expect(presentation.allowsCleanupRetry)
        }
    }

    @Test func cloudTimeoutExplainsTheConfiguredLimitAndRecoveryPath() {
        let meeting = manifest(
            jobState: .failed,
            provider: .cloud,
            failureReason: .timeout
        )

        let presentation = MeetingProcessingPresentation.make(manifest: meeting)
        #expect(presentation.detailText.contains("request timed out"))
        #expect(presentation.detailText.contains("recommended 120 seconds"))
        #expect(presentation.detailText.contains("Test Connection"))
        #expect(presentation.detailText.contains("Retry"))
        #expect(presentation.allowsCleanupRetry)
    }

    @Test func durableManifestWritesPublishMeetingRefreshSignal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MeetingNotificationCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: MeetingSessionStore.manifestDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            if let meetingID = notification.userInfo?[MeetingSessionStore.changedMeetingIDUserInfoKey]
                as? String {
                capture.record(meetingID)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = baseManifest()
        try store.create(manifest)
        var changed = try store.load(meetingID: manifest.meetingID)
        changed.title = "Updated title"
        try store.saveManifest(changed)

        #expect(capture.count(of: manifest.meetingID) == 2)
    }

    private func baseManifest() -> MeetingManifest {
        let meetingID = "presentation-meeting"
        return MeetingManifest(
            meetingID: meetingID,
            title: "Presentation fixture",
            state: .completed,
            aiMode: .localOnly,
            segments: [
                MeetingTranscriptSegment(
                    id: "segment-0",
                    meetingID: meetingID,
                    sequence: 0,
                    text: "Original text",
                    isFinal: true
                )
            ],
            intelligenceConfiguration: MeetingIntelligenceConfiguration(
                cleanupEnabled: true,
                cleanupProvider: .localGemma,
                cloudProvider: nil
            )
        )
    }

    private func manifest(
        jobState: MeetingCleanupJobState,
        activeRevision: Bool = false,
        provider: MeetingCleanupProvider = .localGemma,
        failureReason: CleanupFailureReason? = nil
    ) -> MeetingManifest {
        var meeting = baseManifest()
        meeting.intelligenceConfiguration = MeetingIntelligenceConfiguration(
            cleanupEnabled: true,
            cleanupProvider: provider,
            cloudProvider: provider == .cloud
                ? MeetingCloudProviderSnapshot(
                    preset: .openRouter,
                    endpoint: URL(string: "https://openrouter.ai/api/v1")!,
                    model: "deepseek/deepseek-v4-flash",
                    timeout: 30
                )
                : nil
        )
        let revisionID = "revision-1"
        let revisionState: MeetingCleanupRevisionState = activeRevision
            ? .valid
            : (jobState == .stale ? .stale : .pending)
        let revision = MeetingCleanupRevision(
            id: revisionID,
            meetingID: meeting.meetingID,
            sourceTranscriptFingerprint: MeetingTranscriptFingerprint.make(for: meeting.segments),
            sourceSegmentIDs: meeting.segments.map(\.id),
            contractVersion: MeetingCleanupContract.version,
            modelRepository: provider == .cloud
                ? "deepseek/deepseek-v4-flash"
                : MeetingCleanupContract.modelRepository,
            modelRevision: activeRevision ? "snapshot" : nil,
            producer: provider == .cloud ? .cloud : .localGemma,
            providerIdentifier: provider == .cloud ? "openRouter" : "local-gemma",
            providerEndpoint: provider == .cloud
                ? URL(string: "https://openrouter.ai/api/v1")
                : nil,
            providerModel: provider == .cloud
                ? "deepseek/deepseek-v4-flash"
                : MeetingCleanupContract.modelRepository,
            chunkSize: MeetingCleanupContract.chunkSize,
            state: revisionState,
            createdAt: Date(timeIntervalSince1970: 1),
            completedAt: activeRevision ? Date(timeIntervalSince1970: 2) : nil,
            cleanedSegments: activeRevision
                ? [MeetingCleanedSegment(sourceSegmentID: "segment-0", cleanedText: "Cleaned text")]
                : []
        )
        let job = MeetingCleanupJob(
            id: "job-1",
            meetingID: meeting.meetingID,
            revisionID: revisionID,
            state: jobState,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            attempt: 1,
            completedChunkCount: activeRevision ? 1 : 0,
            totalChunkCount: 1,
            errorMessage: jobState == .failed ? "model error" : nil,
            failureReason: failureReason
        )
        meeting.cleanupRevisions = [revision]
        meeting.cleanupJobs = [job]
        meeting.activeCleanupRevisionID = activeRevision ? revisionID : nil
        return meeting
    }
}

private final class MeetingNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var meetingIDs: [String] = []

    func record(_ meetingID: String) {
        lock.lock()
        meetingIDs.append(meetingID)
        lock.unlock()
    }

    func count(of meetingID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return meetingIDs.filter { $0 == meetingID }.count
    }
}
