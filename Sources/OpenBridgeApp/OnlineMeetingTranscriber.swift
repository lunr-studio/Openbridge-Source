import Foundation

protocol TimestampedMeetingEngine: MeetingEngine {
    func transcribeDetailed(audioURL: URL, modelIdentifier: String, formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool, customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode) async throws -> TranscriptPayload
}
extension EngineService: TimestampedMeetingEngine {}

/// Artifact identity, not an array position, owns attempts and durability.
/// Two shared slots bound inference across both sources. All state belongs to
/// the main actor; audio persistence remains on the capture workers.
@MainActor
final class OnlineMeetingTranscriber {
    private let store: MeetingSessionStore
    private let engine: any MeetingEngine
    private let meetingID: String
    private let model: String
    private let dictionary: URL
    private let formatting: Bool
    private let vocabulary: Bool
    private var artifacts: [String: MeetingAudioArtifact] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempted: Set<String> = []
    private var completed: Set<String> = []
    private var results: [String: [MeetingTranscriptSegment]] = [:]
    private var failures: [String: String] = [:]
    private var generation = UUID()
    private var stopped = false
    private var finalizing = false
    private var finalization: Task<MeetingFinalizationResult, Never>?
    private var tapped: Set<String> = []
    private var tapTasks: [Task<Void, Never>] = []
    var maximumConcurrent = 2
    var waitTimeout: TimeInterval = 120
    var onChange: ((String, Bool, String?) -> Void)?
    var liveTap: ((MeetingTranscriptSegment) async -> Void)?
    var indexTap: ((String) async -> Void)?
    var hasUnresolvedWork: Bool { !tasks.isEmpty }
    var researchTranscriptionProgress: ResearchTranscriptionProgress {
        ResearchTranscriptionProgress(completed: completed, failed: Set(failures.keys))
    }

    init(store: MeetingSessionStore, engine: any MeetingEngine, meetingID: String, model: String,
         dictionary: URL, formatting: Bool, vocabulary: Bool) {
        self.store = store; self.engine = engine; self.meetingID = meetingID
        self.model = model; self.dictionary = dictionary; self.formatting = formatting; self.vocabulary = vocabulary
        if let manifest = try? store.load(meetingID: meetingID) {
            completed = Set(manifest.transcribedArtifactIDs.filter {
                manifest.retentionPolicy == .neverStoreTranscript || manifest.rawArtifactSegments[$0] != nil
            })
            results = manifest.rawArtifactSegments
        }
    }

    func ingest(_ values: [MeetingAudioArtifact]) {
        for value in values { artifacts[value.id] = value }
        guard !stopped, !finalizing else { return }
        schedule()
    }

    func stopLive() {
        stopped = true
        tapTasks.forEach { $0.cancel() }
        tapTasks.removeAll()
    }

    func cancel() {
        stopLive()
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        publish()
    }

    private var orderedArtifacts: [MeetingAudioArtifact] {
        artifacts.values.sorted {
            if $0.startOffset != $1.startOffset { return $0.startOffset < $1.startOffset }
            if $0.sourceKind != $1.sourceKind { return $0.sourceKind == .microphone }
            return $0.id < $1.id
        }
    }

    private func schedule() {
        for artifact in orderedArtifacts where !completed.contains(artifact.id) && !attempted.contains(artifact.id) {
            guard tasks.count < max(1, min(2, maximumConcurrent)) else { break }
            attempted.insert(artifact.id)
            let token = generation
            tasks[artifact.id] = Task { [weak self] in
                guard let self else { return }
                await self.transcribe(artifact, token: token, live: true)
                guard self.generation == token else { return }
                self.tasks.removeValue(forKey: artifact.id)
                if !self.stopped { self.schedule() }
                self.publish()
            }
        }
        publish()
    }

    private func transcribe(_ artifact: MeetingAudioArtifact, token: UUID, live: Bool) async {
        do {
            let url = store.audioDirectory(for: meetingID).appendingPathComponent(artifact.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MeetingRecorderError.onlineCaptureFailed("Missing audio: \(artifact.relativePath)")
            }
            let payload: TranscriptPayload
            if let detailed = engine as? any TimestampedMeetingEngine {
                payload = try await detailed.transcribeDetailed(audioURL: url, modelIdentifier: model,
                    formattingEnabled: formatting, vocabularyCorrectionsEnabled: vocabulary,
                    customDictionaryURL: dictionary, cleanupMode: .off)
            } else {
                payload = try await engine.transcribe(audioURL: url, modelIdentifier: model,
                    formattingEnabled: formatting, vocabularyCorrectionsEnabled: vocabulary,
                    customDictionaryURL: dictionary, cleanupMode: .off)
            }
            guard generation == token, !Task.isCancelled else { return }
            let manifest = try store.load(meetingID: meetingID)
            guard let source = manifest.sources.first(where: { $0.sourceID == artifact.sourceID }) else {
                throw MeetingRecorderError.onlineCaptureFailed("The audio source is missing from the meeting.")
            }
            let pieces = MeetingTranscriptMerger.merge(meetingID: meetingID, captureMode: .online,
                transcripts: [MeetingArtifactTranscript(artifact: artifact, source: source, payload: payload)])
            results[artifact.id] = pieces
            // Always commit the artifact receipt, including a successfully silent
            // result. Empty text must not create invented speech or endless retry.
            try persist(artifact: artifact, retainingText: manifest.retentionPolicy != .neverStoreTranscript)
            completed.insert(artifact.id)
            failures.removeValue(forKey: artifact.id)
            if live, !stopped { drainMicrophoneTaps() }
            if let indexTap { await indexTap(meetingID) }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            failures[artifact.id] = error.localizedDescription
        }
    }

    private func orderedSegments() -> [MeetingTranscriptSegment] {
        // Overlap is compared only with the immediately preceding artifact of
        // the same source, never with the other participant's utterance.
        var adjusted = results
        for artifact in orderedArtifacts where artifact.sequence > 0 {
            guard let predecessor = artifacts.values.first(where: {
                $0.sourceID == artifact.sourceID && $0.sequence == artifact.sequence - 1
            }), let prior = results[predecessor.id], var pieces = adjusted[artifact.id] else { continue }
            let overlap = min(predecessor.overlapSeconds ?? 0, max(0, predecessor.endOffset - artifact.startOffset))
            guard overlap > 0 else { continue }
            let full = pieces.map(\.text).joined(separator: " ")
            let trimmed = MeetingOverlapDedup.trimOverlappingHead(from: full,
                previousText: prior.map(\.text).joined(separator: " "), overlapSeconds: overlap)
            var removeCount = max(0, full.split(whereSeparator: \.isWhitespace).count - trimmed.split(whereSeparator: \.isWhitespace).count)
            pieces = pieces.compactMap { old in
                let words = old.text.split(whereSeparator: \.isWhitespace)
                let drop = min(removeCount, words.count)
                removeCount -= drop
                guard drop < words.count else { return nil }
                var next = MeetingTranscriptSegment(id: old.id, meetingID: old.meetingID, sequence: old.sequence,
                    startOffset: old.startOffset, endOffset: old.endOffset, sourceLabel: old.sourceLabel,
                    text: drop == 0 ? old.text : String(old.text[words[drop].startIndex...]), isFinal: true)
                next.sourceID = old.sourceID; next.sourceSequence = old.sourceSequence; next.artifactID = old.artifactID
                return next
            }
            adjusted[artifact.id] = pieces
        }
        return adjusted.values.flatMap { $0 }.sorted {
            if $0.startOffset != $1.startOffset { return ($0.startOffset ?? 0) < ($1.startOffset ?? 0) }
            if $0.sourceLabel != $1.sourceLabel { return $0.sourceLabel == "Me" }
            return $0.id < $1.id
        }.enumerated().map { index, old in
            var segment = MeetingTranscriptSegment(id: old.id, meetingID: old.meetingID, sequence: index,
                startOffset: old.startOffset, endOffset: old.endOffset, sourceLabel: old.sourceLabel, text: old.text, isFinal: true)
            segment.sourceID = old.sourceID; segment.sourceSequence = old.sourceSequence; segment.artifactID = old.artifactID
            return segment
        }
    }

    private func persist(artifact: MeetingAudioArtifact, retainingText: Bool) throws {
        let segments = orderedSegments()
        try store.withManifestTransaction(meetingID: meetingID) {
            var manifest = try store.load(meetingID: meetingID)
            let known = Set(manifest.audioArtifacts.map(\.id))
            manifest.audioArtifacts.append(contentsOf: orderedArtifacts.filter { !known.contains($0.id) })
            manifest.audioSegments = manifest.audioArtifacts.map(\.relativePath)
            if retainingText {
                manifest.rawArtifactSegments = results
                manifest.segments = segments
                manifest.transcriptSpans = segments.map { "[\($0.sourceLabel)] \($0.text)" }
            }
            if !manifest.transcribedArtifactIDs.contains(artifact.id) { manifest.transcribedArtifactIDs.append(artifact.id) }
            try store.saveManifest(manifest)
        }
    }

    private func drainMicrophoneTaps() {
        guard let liveTap else { return }
        let mic = orderedArtifacts.filter { $0.sourceKind == .microphone }.sorted { $0.sequence < $1.sequence }
        for artifact in mic {
            guard completed.contains(artifact.id) else { break }
            guard tapped.insert(artifact.id).inserted else { continue }
            let pieces = orderedSegments().filter { $0.artifactID == artifact.id }
            guard let first = pieces.first else { continue }
            // A single mic-chunk intake view preserves question assembly across
            // windows even when model timestamps split one window into spans.
            var intake = MeetingTranscriptSegment(id: first.id, meetingID: meetingID, sequence: artifact.sequence,
                startOffset: artifact.startOffset, endOffset: artifact.endOffset, sourceLabel: "Me",
                text: pieces.map(\.text).joined(separator: " "), isFinal: true)
            intake.sourceID = artifact.sourceID; intake.sourceSequence = artifact.sequence; intake.artifactID = artifact.id
            let token = generation
            tapTasks.append(Task { [weak self] in
                guard let self, self.generation == token, !self.stopped, !Task.isCancelled else { return }
                await liveTap(intake)
            })
        }
    }

    private func publish() {
        onChange?(orderedSegments().map { "[\($0.sourceLabel)] \($0.text)" }.joined(separator: "\n\n"),
                  !tasks.isEmpty || finalizing, failures.sorted(by: { $0.key < $1.key }).first?.value)
    }

    func finalize(_ values: [MeetingAudioArtifact]) async -> MeetingFinalizationResult {
        for value in values { artifacts[value.id] = value }
        if let finalization { return await finalization.value }
        stopLive()
        finalizing = true
        let finalizationToken = generation
        let task = Task<MeetingFinalizationResult, Never> { @MainActor [self] in
            defer { finalizing = false; publish() }
            let deadline = Date().addingTimeInterval(waitTimeout)
            while !tasks.isEmpty, Date() < deadline, generation == finalizationToken {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard generation == finalizationToken else {
                return .failed(transcribedSegmentCount: completed.count, lastError: "Transcription cancelled; audio preserved.")
            }
            if !tasks.isEmpty {
                let remaining = tasks.keys.sorted().joined(separator: ", ")
                cancel()
                return .failed(transcribedSegmentCount: completed.count, lastError: "Transcription timed out; audio preserved: \(remaining)")
            }
            let token = generation
            for artifact in orderedArtifacts where !completed.contains(artifact.id) {
                guard generation == finalizationToken else {
                    return .failed(transcribedSegmentCount: completed.count, lastError: "Transcription cancelled; audio preserved.")
                }
                tasks[artifact.id] = Task { [weak self] in
                    guard let self else { return }
                    await self.transcribe(artifact, token: token, live: false)
                    guard self.generation == token else { return }
                    self.tasks.removeValue(forKey: artifact.id)
                }
                while tasks[artifact.id] != nil, Date() < deadline, generation == finalizationToken {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if tasks[artifact.id] != nil {
                    cancel()
                    return .failed(transcribedSegmentCount: completed.count, lastError: "Retry timed out; audio preserved: \(artifact.relativePath)")
                }
            }
            guard generation == finalizationToken else {
                return .failed(transcribedSegmentCount: completed.count, lastError: "Transcription cancelled; audio preserved.")
            }
            let missing = Set(artifacts.keys).subtracting(completed)
            guard missing.isEmpty else {
                return .failed(transcribedSegmentCount: completed.count,
                    lastError: "Audio preserved for retry: \(missing.sorted().joined(separator: ", ")). \(failures.values.first ?? "")")
            }
            guard let durable = try? store.load(meetingID: meetingID),
                  store.onlineArtifactCoverageIsComplete(durable) else {
                return .failed(transcribedSegmentCount: completed.count,
                    lastError: "The saved transcript does not cover every audio artifact. Audio is preserved for recovery.")
            }
            return .completed(transcribedSegmentCount: completed.count)
        }
        finalization = task
        defer { finalization = nil }
        return await task.value
    }
}
