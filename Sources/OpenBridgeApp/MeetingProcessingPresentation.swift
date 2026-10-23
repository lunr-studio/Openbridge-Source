import Foundation

/// One user-facing interpretation of the durable meeting and cleanup state.
///
/// The Meetings list, latest-meeting panel, Replay sheet, and Export action
/// must not make independent guesses about whether a cleaned transcript is
/// ready. This value is derived only from the persisted manifest plus the
/// app-scoped pre-launch queue marker.
enum MeetingProcessingPhase: String, Equatable, Sendable {
    case finalizingTranscript
    case cleanupQueued
    case cleanupRunning
    case cleanedReady
    case cleanupFailed
    case originalOnly
}

enum MeetingProcessingTone: Equatable, Sendable {
    case neutral
    case working
    case success
    case warning
    case failure
}

struct MeetingProcessingPresentation: Equatable, Sendable {
    let phase: MeetingProcessingPhase
    let badgeText: String
    let detailText: String
    let systemImage: String
    let tone: MeetingProcessingTone
    let completedChunkCount: Int?
    let totalChunkCount: Int?
    let allowsCleanupRetry: Bool
    let includesCleanedExport: Bool

    var showsProgress: Bool {
        phase == .finalizingTranscript || phase == .cleanupQueued || phase == .cleanupRunning
    }

    var progressValue: Double? {
        guard let completedChunkCount, let totalChunkCount, totalChunkCount > 0 else {
            return nil
        }
        return min(1, max(0, Double(completedChunkCount) / Double(totalChunkCount)))
    }

    var exportActionTitle: String {
        includesCleanedExport ? "Export Original + Cleaned" : "Export Original"
    }

    var exportDialogMessage: String {
        if includesCleanedExport {
            return "The Original and current Cleaned transcripts will be exported as TXT and Markdown."
        }
        if phase == .cleanupQueued || phase == .cleanupRunning {
            return "Cleanup is still in progress. This export contains the Original transcript only; export again after Cleaned is ready."
        }
        if phase == .cleanupFailed {
            return "Cleanup did not complete. This export contains the preserved Original transcript only."
        }
        return "The Original transcript will be exported as TXT and Markdown."
    }

    static func make(
        manifest: MeetingManifest,
        isCleanupDeferred: Bool = false
    ) -> MeetingProcessingPresentation {
        switch manifest.state {
        case .transcribingLive, .finalizing:
            return MeetingProcessingPresentation(
                phase: .finalizingTranscript,
                badgeText: "Finalizing transcript",
                detailText: "Finalizing the transcript. Recorded audio remains safely stored on this Mac.",
                systemImage: "waveform.badge.magnifyingglass",
                tone: .working,
                completedChunkCount: nil,
                totalChunkCount: nil,
                allowsCleanupRetry: false,
                includesCleanedExport: false
            )
        case .stopped, .captured:
            return originalOnly(
                badge: "Needs recovery",
                detail: "Transcript finalization did not complete. Recorded audio remains on this Mac; use the recovery actions to retry transcription.",
                tone: .warning
            )
        default:
            break
        }

        if activeValidRevision(in: manifest) != nil {
            return MeetingProcessingPresentation(
                phase: .cleanedReady,
                badgeText: "Cleaned ready",
                detailText: "The Cleaned transcript is ready. The Original remains available and unchanged.",
                systemImage: "checkmark.circle.fill",
                tone: .success,
                completedChunkCount: nil,
                totalChunkCount: nil,
                allowsCleanupRetry: false,
                includesCleanedExport: true
            )
        }

        if isCleanupDeferred {
            let provider = configuredProvider(in: manifest)
            return MeetingProcessingPresentation(
                phase: .cleanupQueued,
                badgeText: "Cleanup queued",
                detailText: "\(provider.queuedText) The Original transcript is ready now.",
                systemImage: "clock.arrow.circlepath",
                tone: .working,
                completedChunkCount: 0,
                totalChunkCount: expectedChunkCount(in: manifest),
                allowsCleanupRetry: false,
                includesCleanedExport: false
            )
        }

        guard let job = manifest.cleanupJobs.last else {
            return originalOnly(
                detail: originalOnlyDetail(for: manifest),
                tone: manifest.state.needsRecovery ? .warning : .neutral
            )
        }

        let provider = provider(for: job, manifest: manifest)
        switch job.state {
        case .queued:
            return MeetingProcessingPresentation(
                phase: .cleanupQueued,
                badgeText: "Cleanup queued",
                detailText: "\(provider.queuedText) The Original transcript is ready now.",
                systemImage: "clock.arrow.circlepath",
                tone: .working,
                completedChunkCount: job.completedChunkCount,
                totalChunkCount: job.totalChunkCount,
                allowsCleanupRetry: false,
                includesCleanedExport: false
            )
        case .running:
            let progress = chunkProgressText(job)
            return MeetingProcessingPresentation(
                phase: .cleanupRunning,
                badgeText: progress.badge,
                detailText: "\(provider.runningText) \(progress.detail) The Original transcript is ready now.",
                systemImage: "sparkles",
                tone: .working,
                completedChunkCount: job.completedChunkCount,
                totalChunkCount: job.totalChunkCount,
                allowsCleanupRetry: false,
                includesCleanedExport: false
            )
        case .completed:
            return originalOnly(
                detail: "Cleanup finished, but no current valid Cleaned revision is available. The Original transcript is ready.",
                tone: .warning
            )
        case .failed:
            return failed(
                badge: "Cleanup failed",
                detail: safeFailureDetail(
                    job.failureReason ?? legacyFailureReason(job.errorMessage),
                    provider: provider
                )
            )
        case .interrupted:
            return failed(
                badge: "Cleanup interrupted",
                detail: "Cleanup was interrupted. The Original transcript is intact and Retry is available."
            )
        case .retryAvailable:
            return failed(
                badge: "Cleanup needs attention",
                detail: "Cleanup did not finish. The Original transcript is intact and Retry is available."
            )
        case .cancelled:
            return originalOnly(
                detail: "Cleanup was cancelled. The Original transcript is ready.",
                tone: .neutral
            )
        case .stale:
            return originalOnly(
                detail: "The transcript changed after cleanup, so the old Cleaned version is stale. The Original is shown.",
                tone: .warning
            )
        }
    }

    private enum CleanupProviderKind {
        case local
        case cloud

        var queuedText: String {
            switch self {
            case .local: return "Local cleanup is waiting to start."
            case .cloud: return "Cloud cleanup is waiting to start."
            }
        }

        var runningText: String {
            switch self {
            case .local: return "Cleaning locally on this Mac."
            case .cloud: return "Cleaning with the configured cloud provider."
            }
        }
    }

    private static func activeValidRevision(in manifest: MeetingManifest) -> MeetingCleanupRevision? {
        let source = manifest.segments.sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
        guard !source.isEmpty,
              Set(source.map(\.id)).count == source.count,
              Set(source.map(\.sequence)).count == source.count,
              source.allSatisfy({ $0.meetingID == manifest.meetingID }),
              source.allSatisfy(\.isFinal),
              source.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }

        let expectedIDs = source.map(\.id)
        guard let activeID = manifest.activeCleanupRevisionID,
              let revision = manifest.cleanupRevisions.first(where: { $0.id == activeID }),
              revision.state == .valid,
              revision.meetingID == manifest.meetingID,
              revision.sourceTranscriptFingerprint == MeetingTranscriptFingerprint.make(for: source),
              revision.sourceSegmentIDs == expectedIDs,
              revision.contractVersion == MeetingCleanupContract.version,
              revision.modelRepository == revision.resolvedProvenance.model,
              revision.chunkSize == MeetingCleanupContract.chunkSize,
              revision.modelRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              revision.cleanedSegments.count == expectedIDs.count,
              Set(revision.cleanedSegments.map(\.sourceSegmentID)).count == expectedIDs.count,
              zip(revision.cleanedSegments, expectedIDs).allSatisfy({ cleaned, expectedID in
                  cleaned.sourceSegmentID == expectedID
                      && !cleaned.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { return nil }
        return revision
    }

    private static func expectedChunkCount(in manifest: MeetingManifest) -> Int? {
        guard !manifest.segments.isEmpty else { return nil }
        return Int(ceil(Double(manifest.segments.count) / Double(MeetingCleanupContract.chunkSize)))
    }

    private static func configuredProvider(in manifest: MeetingManifest) -> CleanupProviderKind {
        manifest.intelligenceConfiguration?.cleanupProvider == .cloud ? .cloud : .local
    }

    private static func provider(
        for job: MeetingCleanupJob,
        manifest: MeetingManifest
    ) -> CleanupProviderKind {
        if let revision = manifest.cleanupRevisions.first(where: { $0.id == job.revisionID }) {
            return revision.resolvedProvenance.producer == .cloud ? .cloud : .local
        }
        return configuredProvider(in: manifest)
    }

    private static func chunkProgressText(
        _ job: MeetingCleanupJob
    ) -> (badge: String, detail: String) {
        guard job.totalChunkCount > 0 else {
            return ("Cleaning", "Cleanup is in progress.")
        }
        let completed = min(job.completedChunkCount, job.totalChunkCount)
        return (
            "Cleaning \(completed)/\(job.totalChunkCount)",
            "\(completed) of \(job.totalChunkCount) chunks saved."
        )
    }

    private static func originalOnlyDetail(for manifest: MeetingManifest) -> String {
        if manifest.state.needsRecovery {
            return "This meeting needs recovery. Any available Original transcript and recorded audio remain on this Mac."
        }
        if manifest.intelligenceConfiguration?.cleanupEnabled == true,
           manifest.aiMode == .transcriptionOnly {
            return "The Original transcript is ready. Cleanup was not authorized for this meeting."
        }
        return "The Original transcript is ready. No cleanup is running."
    }

    private static func originalOnly(
        badge: String = "Original ready",
        detail: String,
        tone: MeetingProcessingTone
    ) -> MeetingProcessingPresentation {
        MeetingProcessingPresentation(
            phase: .originalOnly,
            badgeText: badge,
            detailText: detail,
            systemImage: "doc.text",
            tone: tone,
            completedChunkCount: nil,
            totalChunkCount: nil,
            allowsCleanupRetry: false,
            includesCleanedExport: false
        )
    }

    private static func failed(
        badge: String,
        detail: String
    ) -> MeetingProcessingPresentation {
        MeetingProcessingPresentation(
            phase: .cleanupFailed,
            badgeText: badge,
            detailText: detail,
            systemImage: "exclamationmark.triangle.fill",
            tone: .failure,
            completedChunkCount: nil,
            totalChunkCount: nil,
            allowsCleanupRetry: true,
            includesCleanedExport: false
        )
    }

    /// Durable errors are developer-facing descriptions. Convert the known
    /// failure classes into useful product copy without echoing provider
    /// bodies, prompts, transcript text, or credentials into the UI.
    private static func safeFailureDetail(
        _ failureReason: CleanupFailureReason,
        provider: CleanupProviderKind
    ) -> String {
        let reason: String
        switch failureReason {
        case .invalidJSON:
            reason = "The cleanup engine returned invalid structured output."
        case .wrongCount:
            reason = "The cleanup result did not contain one valid result for every transcript segment."
        case .invalidIndex:
            reason = "The cleanup engine returned results in an invalid order."
        case .emptyText:
            reason = "The cleanup engine returned an empty result for at least one segment."
        case .truncation:
            reason = "The cleanup result was truncated before it finished."
        case .modelUnavailable:
            reason = "The local cleanup model is missing or unavailable."
        case .timeout:
            if provider == .cloud {
                // A manual retry of an older meeting deliberately uses the
                // current settings timeout, not the immutable meeting
                // snapshot. Do not claim which limit the failed attempt used
                // unless that effective value is persisted with the attempt.
                reason = "The cloud cleanup request timed out. In Cloud intelligence Settings, confirm the recommended 120 seconds, run Test Connection, then Retry when the provider is healthy."
            } else {
                reason = "The cleanup request timed out."
            }
        case .offline:
            reason = provider == .cloud
                ? "The cloud provider could not be reached."
                : "The local cleanup sandbox could not start."
        case .authentication:
            reason = "The configured cloud credential was not accepted."
        case .providerRejected:
            reason = "The configured cloud provider rejected the cleanup request."
        case .cloudDisabled:
            reason = "Cloud intelligence is disabled. Enable it in Cloud intelligence Settings before Retry."
        case .consentRequired:
            reason = "Cloud cleanup is not authorized. Restore cloud authorization in Settings before Retry."
        case .connectionTestRequired:
            reason = "The cloud configuration must pass Test Connection again before Retry."
        case .configurationChanged:
            reason = "The cloud provider configuration changed. Restore the meeting's provider settings or clean locally with Gemma."
        case .requestAlreadyActive:
            reason = "Another cloud request is still running. Wait for it to finish before Retry."
        case .unknown:
            reason = provider == .cloud
                ? "The configured cloud provider did not complete cleanup."
                : "The local cleanup model did not complete cleanup."
        }
        return "\(reason) The Original transcript is intact and Retry is available."
    }

    private static func legacyFailureReason(_ message: String?) -> CleanupFailureReason {
        let normalized = (message ?? "").lowercased()
        if normalized.contains("expected") && normalized.contains("received")
            || normalized.contains("aligned")
            || normalized.contains("segment") && normalized.contains("mismatch") {
            return .wrongCount
        }
        if normalized.contains("model") && (
            normalized.contains("missing") || normalized.contains("not found")
                || normalized.contains("not installed") || normalized.contains("unavailable")
        ) { return .modelUnavailable }
        if normalized.contains("timeout") || normalized.contains("timed out") { return .timeout }
        if normalized.contains("offline") || normalized.contains("network") { return .offline }
        if normalized.contains("auth") || normalized.contains("credential")
            || normalized.contains("api key") { return .authentication }
        return .unknown
    }
}
