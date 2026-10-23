import Foundation

struct MeetingCleanupEngineOutput: Codable, Equatable, Sendable {
    let contractVersion: Int
    let modelRepository: String
    let modelRevision: String
    let chunkSize: Int
    let segments: [MeetingCleanedSegment]
}

protocol MeetingCleanupEngine: Sendable {
    var provenance: MeetingCleanupProvenance { get }

    func cleanMeetingSegments(
        _ segments: [MeetingTranscriptSegment]
    ) async throws -> MeetingCleanupEngineOutput
}

extension MeetingCleanupEngine {
    var provenance: MeetingCleanupProvenance { .localGemma }
}

enum MeetingCleanupCheckpoint: Equatable, Sendable {
    case beforeInference
    case afterDurableChunk(Int)
    case beforeActivation
}

/// Orchestrates inference separately from meeting finalization. A completed
/// meeting stays completed even if any cleanup step fails or is cancelled.
struct MeetingCleanupCoordinator: Sendable {
    private let store: MeetingSessionStore
    private let engine: any MeetingCleanupEngine
    private let checkpoint: @Sendable (MeetingCleanupCheckpoint) throws -> Void

    init(
        store: MeetingSessionStore,
        engine: any MeetingCleanupEngine,
        checkpoint: @Sendable @escaping (MeetingCleanupCheckpoint) throws -> Void = { _ in }
    ) {
        self.store = store
        self.engine = engine
        self.checkpoint = checkpoint
    }

    @discardableResult
    func run(meetingID: String) async throws -> MeetingCleanupRevision {
        let job = try store.createCleanupJob(
            meetingID: meetingID,
            provenance: engine.provenance
        )
        if job.state == .completed {
            let manifest = try store.load(meetingID: meetingID)
            guard let revision = manifest.cleanupRevisions.first(where: { $0.id == job.revisionID }),
                  revision.state == .valid else {
                throw MeetingSessionStoreError.incompleteCleanupResult
            }
            return revision
        }
        guard job.state == .queued else {
            throw MeetingCleanupCoordinatorError.alreadyRunning
        }

        _ = try store.markCleanupJobRunning(meetingID: meetingID, jobID: job.id)
        do {
            try Task.checkCancellation()
            try checkpoint(.beforeInference)

            let source = try store.fetchSegments(meetingID: meetingID)
                .sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
            let output = try await engine.cleanMeetingSegments(source)
            try Task.checkCancellation()
            try validateEngineMetadata(output)

            let chunks = output.segments.chunked(size: MeetingCleanupContract.chunkSize)
            for (chunkIndex, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                try store.persistCleanupChunk(
                    meetingID: meetingID,
                    jobID: job.id,
                    chunkIndex: chunkIndex,
                    results: chunk
                )
                try checkpoint(.afterDurableChunk(chunkIndex))
            }

            try Task.checkCancellation()
            try checkpoint(.beforeActivation)
            return try store.completeCleanupJob(
                meetingID: meetingID,
                jobID: job.id,
                modelRevision: output.modelRevision
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                try? store.cancelCleanupJob(meetingID: meetingID, jobID: job.id)
                throw CancellationError()
            }
            let failureReason = CleanupFailureReason.classify(error)
            try? store.failCleanupJob(
                meetingID: meetingID,
                jobID: job.id,
                reason: failureReason
            )
            throw error
        }
    }

    private func validateEngineMetadata(_ output: MeetingCleanupEngineOutput) throws {
        guard output.contractVersion == MeetingCleanupContract.version else {
            throw MeetingCleanupCoordinatorError.contractMismatch
        }
        guard output.modelRepository == engine.provenance.model else {
            throw MeetingCleanupCoordinatorError.modelMismatch
        }
        guard output.chunkSize == MeetingCleanupContract.chunkSize else {
            throw MeetingCleanupCoordinatorError.chunkSizeMismatch
        }
    }
}

enum MeetingCleanupCoordinatorError: LocalizedError {
    case alreadyRunning
    case contractMismatch
    case modelMismatch
    case chunkSizeMismatch

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Cleanup is already running for this transcript."
        case .contractMismatch:
            return "The cleanup engine returned the wrong contract version."
        case .modelMismatch:
            return "The cleanup engine did not use the snapshotted cleanup model."
        case .chunkSizeMismatch:
            return "The cleanup engine did not use the accepted eight-segment chunk size."
        }
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
