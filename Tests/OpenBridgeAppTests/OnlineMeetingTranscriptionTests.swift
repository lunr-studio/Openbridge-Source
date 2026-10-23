import Testing
import Foundation
@testable import OpenBridgeApp

private actor OnlineFixtureEngine: MeetingEngine {
    var calls: [String] = []
    var active = 0
    var peak = 0
    let failFirst: Bool
    let delay: Duration
    init(failFirst: Bool = false, delay: Duration = .milliseconds(15)) { self.failFirst = failFirst; self.delay = delay }
    func transcribe(audioURL: URL, modelIdentifier: String, formattingEnabled: Bool,
                    vocabularyCorrectionsEnabled: Bool, customDictionaryURL: URL,
                    cleanupMode: TranscriptionCleanupMode) async throws -> TranscriptPayload {
        let name = audioURL.deletingLastPathComponent().lastPathComponent + "/" + audioURL.lastPathComponent
        let first = !calls.contains(name)
        calls.append(name); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        if failFirst && first { throw MeetingRecorderError.onlineCaptureFailed("Synthetic inference failure") }
        return TranscriptPayload(text: "The violet harbor budget is seven dollars.")
    }
}

@MainActor
private struct OnlineFixture {
    let store: MeetingSessionStore
    let manifest: MeetingManifest
    let items: [MeetingAudioArtifact]
    let engine: OnlineFixtureEngine
    let pipeline: OnlineMeetingTranscriber
    init(count: Int = 2, failFirst: Bool = false, neverStore: Bool = false, delay: Duration = .milliseconds(15)) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "synthetic")
        let system = MeetingSourceMetadata(sourceID: "sys", label: "System audio", kind: .systemAudio, deviceID: "synthetic")
        var m = MeetingManifest(title: "Synthetic pipeline", state: .recording, sources: [mic, system],
            retentionPolicy: neverStore ? .neverStoreTranscript : .keepUntilDeleted)
        m.captureMode = .online
        items = (0..<count).map { i in
            let source = i % 2 == 0 ? mic : system
            return MeetingAudioArtifact(id: "\(source.sourceID)-\(i / 2)", sourceID: source.sourceID, sourceKind: source.kind,
                sequence: i / 2, relativePath: "\(source.kind.rawValue)/segment_\(i / 2).wav",
                startOffset: Double(i / 2) * 30 + (i % 2 == 0 ? 2 : 1), endOffset: Double(i / 2) * 30 + 30,
                sampleRate: 16_000, channelCount: 1)
        }
        m.audioArtifacts = items; m.audioSegments = items.map(\.relativePath)
        manifest = m
        try store.create(m)
        for item in items {
            let url = store.audioDirectory(for: m.meetingID).appendingPathComponent(item.relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MeetingWAVFile.write(pcm: Data(repeating: 32, count: 32_000), sampleRate: 16_000, to: url)
        }
        engine = OnlineFixtureEngine(failFirst: failFirst, delay: delay)
        pipeline = OnlineMeetingTranscriber(store: store, engine: engine, meetingID: m.meetingID, model: "test",
            dictionary: root.appendingPathComponent("dictionary.json"), formatting: false, vocabulary: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: store.rootDirectory) }
}

@Suite(.serialized) struct OnlineMeetingTranscriptionTests {
    @MainActor @Test func liveBothSourcesBoundConcurrencyAndKeepStableOrder() async throws {
        let f = try OnlineFixture(count: 6); defer { f.cleanup() }
        var taps: [MeetingTranscriptSegment] = []
        var shown = ""
        f.pipeline.liveTap = { taps.append($0) }
        f.pipeline.onChange = { text, _, _ in shown = text }
        f.pipeline.ingest(f.items)
        // Other full-suite MainActor fixtures deliberately block the executor.
        // This checks job count/order, not a machine-load-dependent 3s latency SLA.
        let deadline = Date().addingTimeInterval(60)
        while f.pipeline.hasUnresolvedWork, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!f.pipeline.hasUnresolvedWork)
        #expect(await f.engine.peak == 2)
        #expect(await f.engine.calls.count == 6)
        #expect(shown.contains("[Me]"))
        #expect(shown.contains("[System audio]"))
        #expect(taps.count == 3)
        #expect(taps.allSatisfy { $0.sourceLabel == "Me" })
        #expect(taps.map(\.sequence) == [0, 1, 2])
        let saved = try f.store.load(meetingID: f.manifest.meetingID)
        #expect(saved.segments.first?.sourceLabel == "System audio")
        #expect(Set(saved.segments.map(\.id)).count == 6)
        #expect(saved.transcribedArtifactIDs.count == 6)
        let ids = saved.segments.map(\.id)
        _ = await f.pipeline.finalize(f.items)
        #expect(try f.store.load(meetingID: f.manifest.meetingID).segments.map(\.id) == ids)
        #expect(await f.engine.calls.count == 6)
    }

    @MainActor @Test func failedLiveArtifactsRetryAtStopWithoutDeletingAudio() async throws {
        let f = try OnlineFixture(failFirst: true); defer { f.cleanup() }
        f.pipeline.ingest(f.items)
        let result = await f.pipeline.finalize(f.items)
        guard case .completed(let count) = result else { Issue.record("Expected successful retry"); return }
        #expect(count == 2)
        #expect(await f.engine.calls.count == 4)
        for item in f.items { #expect(FileManager.default.fileExists(atPath: f.store.audioDirectory(for: f.manifest.meetingID).appendingPathComponent(item.relativePath).path)) }
    }

    @MainActor @Test func simultaneousStopSharesOneFinalization() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        async let first = f.pipeline.finalize(f.items)
        async let second = f.pipeline.finalize(f.items)
        _ = await (first, second)
        #expect(await f.engine.calls.count == 2)
        #expect(try f.store.load(meetingID: f.manifest.meetingID).segments.count == 2)
    }

    @MainActor @Test func timeoutReturnsFailureAndLateWorkCannotPersist() async throws {
        let f = try OnlineFixture(delay: .seconds(2)); defer { f.cleanup() }
        f.pipeline.waitTimeout = 0.03
        f.pipeline.ingest(f.items)
        let result = await f.pipeline.finalize(f.items)
        guard case .failed = result else { Issue.record("Expected bounded timeout"); return }
        try await Task.sleep(for: .milliseconds(60))
        #expect(try f.store.load(meetingID: f.manifest.meetingID).segments.isEmpty)
        #expect(!f.pipeline.hasUnresolvedWork)
    }

    @MainActor @Test func neverStorePublishesLiveButDoesNotPersistText() async throws {
        let f = try OnlineFixture(neverStore: true); defer { f.cleanup() }
        var shown = ""
        f.pipeline.onChange = { text, _, _ in shown = text }
        _ = await f.pipeline.finalize(f.items)
        let saved = try f.store.load(meetingID: f.manifest.meetingID)
        #expect(saved.segments.isEmpty && saved.transcriptSpans.isEmpty)
        #expect(saved.transcribedArtifactIDs.count == 2)
        #expect(shown.contains("violet harbor"))
    }

    @MainActor @Test func missingTrackCannotReportComplete() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        let missing = f.store.audioDirectory(for: f.manifest.meetingID).appendingPathComponent(f.items[1].relativePath)
        try FileManager.default.removeItem(at: missing)
        guard case .failed = await f.pipeline.finalize(f.items) else { Issue.record("Missing source must fail"); return }
        #expect(try f.store.load(meetingID: f.manifest.meetingID).segments.count == 1)
    }
}

extension OnlineMeetingTranscriptionTests {
    @MainActor @Test func replayUsesSharedClockInsteadOfConcatenatingSources() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        let player = MeetingPlayer()
        try await player.loadOnline(artifacts: f.items, audioDirectory: f.store.audioDirectory(for: f.manifest.meetingID))
        // One-second WAVs beginning at seconds 1 and 2 end at second 3.
        #expect(abs(player.onlineDuration - 3) < 0.01)
        #expect(player.totalSegments == 2)
    }

    @MainActor @Test func recoveryRequiresEveryArtifactAndExportKeepsLabels() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        #expect(try !f.store.completeOnlineRecovery(meetingID: f.manifest.meetingID))
        _ = await f.pipeline.finalize(f.items)
        #expect(try f.store.completeOnlineRecovery(meetingID: f.manifest.meetingID))
        let saved = try f.store.load(meetingID: f.manifest.meetingID)
        for format in [MeetingTranscriptExportFormat.txt, .markdown] {
            let doc = MeetingTranscriptExporter.makeDocument(manifest: saved, format: format, requestedSource: .original, activeRevision: nil)
            #expect(doc.text.contains("System audio"))
            #expect(doc.text.contains("Me"))
        }
        #expect(saved.state == .completed)
    }

    @Test func detailedTimestampsAndFallbackKeepSourceIdentity() {
        let source = MeetingSourceMetadata(sourceID: "s", label: "System audio", kind: .systemAudio, deviceID: "fixture")
        let artifact = MeetingAudioArtifact(id: "a", sourceID: "s", sourceKind: .systemAudio, sequence: 4,
            relativePath: "system-audio/segment_4.wav", startOffset: 100, endOffset: 130, sampleRate: 16_000, channelCount: 1)
        let payload = TranscriptPayload(text: "one two", spans: [
            TranscriptSpanPayload(startOffset: 2, endOffset: 3, text: "one"),
            TranscriptSpanPayload(startOffset: 5, endOffset: 6, text: "two")])
        let segments = MeetingTranscriptMerger.merge(meetingID: "meeting", captureMode: .online,
            transcripts: [MeetingArtifactTranscript(artifact: artifact, source: source, payload: payload)])
        #expect(segments.map(\.startOffset) == [102, 105])
        #expect(segments.allSatisfy { $0.sourceID == "s" && $0.artifactID == "a" && $0.sourceSequence == 4 })
        let fallback = MeetingTranscriptMerger.merge(meetingID: "meeting", captureMode: .online,
            transcripts: [MeetingArtifactTranscript(artifact: artifact, source: source, payload: TranscriptPayload(text: "words"))])
        #expect(fallback.first?.startOffset == 100)
        #expect(fallback.first?.endOffset == 130)
    }
}

extension OnlineMeetingTranscriptionTests {
    @MainActor @Test func retentionRequiresBothTrackReceiptsAndRecognizesUnknownNestedAudio() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        _ = await f.pipeline.finalize(f.items)
        var saved = try f.store.load(meetingID: f.manifest.meetingID)
        saved.state = .completed; saved.retentionPolicy = .deleteAudioAfterTranscript
        try f.store.saveManifest(saved)
        #expect(f.store.canSafelyDeleteAudio(saved))
        var partial = saved
        partial.transcribedArtifactIDs.removeLast()
        #expect(!f.store.canSafelyDeleteAudio(partial))
        partial = saved; partial.rawArtifactSegments.removeValue(forKey: f.items[1].id)
        #expect(!f.store.canSafelyDeleteAudio(partial))
        let unknown = f.store.audioDirectory(for: saved.meetingID).appendingPathComponent("system-audio/unknown.wav")
        try Data([0]).write(to: unknown)
        #expect(!f.store.canSafelyDeleteAudio(saved))
        try FileManager.default.removeItem(at: unknown)
        #expect(try f.store.enforceAudioRetention(meetingID: saved.meetingID))
        let retained = try f.store.load(meetingID: saved.meetingID)
        #expect(retained.audioArtifacts == f.items)
        #expect(!retained.rawArtifactSegments.isEmpty && !retained.segments.isEmpty)
        #expect(try !f.store.evaluateRecovery(meetingID: saved.meetingID).hasAudioFiles)
        // Simulate the manifest-before-removal crash window. Metadata still proves
        // coverage when files remain and launch retries audio retention.
        let leftover = f.store.audioDirectory(for: saved.meetingID).appendingPathComponent(f.items[0].relativePath)
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: leftover)
        #expect(try f.store.enforceAudioRetention(meetingID: saved.meetingID))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @MainActor @Test func markerBeforeWAVCrashDoesNotBlockRecoveredArtifacts() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        _ = await f.pipeline.finalize(f.items)
        var saved = try f.store.load(meetingID: f.manifest.meetingID)
        saved.activeSourceJournals["sys"] = MeetingActiveJournal(filename: "system-audio/segment_0001.wav", segmentIndex: 1, startOffset: 30)
        try f.store.saveManifest(saved)
        #expect(try f.store.completeOnlineRecovery(meetingID: saved.meetingID))
        #expect(try f.store.load(meetingID: saved.meetingID).activeSourceJournals.isEmpty)
    }

    @MainActor @Test func relaunchRebuildsOverlapFromRawAndKeepsCrossSourceSpeech() async throws {
        let f = try OnlineFixture(count: 6); defer { f.cleanup() }
        var saved = try f.store.load(meetingID: f.manifest.meetingID)
        let items = f.items.map { old in
            var artifact = MeetingAudioArtifact(id: old.id, sourceID: old.sourceID, sourceKind: old.sourceKind,
                sequence: old.sequence, relativePath: old.relativePath, startOffset: Double(old.sequence) * 28.5,
                endOffset: Double(old.sequence) * 28.5 + 30, sampleRate: old.sampleRate, channelCount: 1)
            artifact.overlapSeconds = 1.5
            return artifact
        }
        saved.audioArtifacts = items
        for item in items.prefix(4) {
            let source = try #require(saved.sources.first { $0.sourceID == item.sourceID })
            let text = item.sequence == 0 ? "Repeat this" : "Repeat this Repeat this is the real repetition."
            saved.rawArtifactSegments[item.id] = MeetingTranscriptMerger.merge(meetingID: saved.meetingID,
                captureMode: .online, transcripts: [.init(artifact: item, source: source, payload: TranscriptPayload(text: text))])
            saved.transcribedArtifactIDs.append(item.id)
        }
        try f.store.saveManifest(saved)
        func reload() -> OnlineMeetingTranscriber {
            OnlineMeetingTranscriber(store: f.store, engine: f.engine, meetingID: saved.meetingID, model: "test",
                dictionary: f.store.rootDirectory.appendingPathComponent("dictionary.json"), formatting: false, vocabulary: false)
        }
        _ = await reload().finalize(Array(items.prefix(5)))
        let first = try f.store.load(meetingID: saved.meetingID)
        #expect(first.segments.filter { $0.sourceSequence == 1 }.map(\.text) ==
                ["Repeat this is the real repetition.", "Repeat this is the real repetition."])
        _ = await reload().finalize(items)
        let second = try f.store.load(meetingID: saved.meetingID)
        #expect(second.segments.filter { $0.sourceSequence == 1 }.map(\.text) ==
                ["Repeat this is the real repetition.", "Repeat this is the real repetition."])
        #expect(await f.engine.calls.count == 2)
    }

    @MainActor @Test func cancellingFinalizationNeverStartsRetriesOrPersistsLateResults() async throws {
        let f = try OnlineFixture(count: 6, delay: .milliseconds(100)); defer { f.cleanup() }
        f.pipeline.ingest(f.items)
        let finish = Task { await f.pipeline.finalize(f.items) }
        try await Task.sleep(for: .milliseconds(20))
        f.pipeline.cancel()
        guard case .failed = await finish.value else { Issue.record("Cancellation must not complete"); return }
        try await Task.sleep(for: .milliseconds(120))
        #expect(await f.engine.calls.count <= 2)
        #expect(try f.store.load(meetingID: f.manifest.meetingID).transcribedArtifactIDs.isEmpty)
    }
}


extension OnlineMeetingTranscriptionTests {
    @MainActor @Test func bothCaptureWritersAndInferenceKeepAllArtifactReceipts() async throws {
        let f = try OnlineFixture(count: 6); defer { f.cleanup() }
        var empty = f.manifest; empty.audioArtifacts = []; empty.audioSegments = []
        try f.store.saveManifest(empty)
        f.pipeline.ingest(f.items)
        let store = f.store, id = f.manifest.meetingID, items = f.items
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in ["mic", "sys"] {
                group.addTask {
                    let own = items.filter { $0.sourceID == source }
                    for count in 1...own.count {
                        try store.saveSourceCaptureProgress(meetingID: id, sourceID: source,
                            artifacts: Array(own.prefix(count)), journal: nil)
                    }
                }
            }
            try await group.waitForAll()
        }
        guard case .completed = await f.pipeline.finalize(f.items) else { Issue.record("Expected durable completion"); return }
        let saved = try f.store.load(meetingID: id)
        #expect(saved.audioArtifacts.count == 6)
        #expect(saved.transcribedArtifactIDs.count == 6)
        #expect(saved.rawArtifactSegments.count == 6)
        #expect(saved.segments.count == 6)
    }

    @MainActor @Test func headerOnlyJournalCrashPreservesCompletedSpeechAndCanFinalize() async throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        _ = await f.pipeline.finalize(f.items)
        var saved = try f.store.load(meetingID: f.manifest.meetingID)
        let name = "system-audio/segment_0001.wav"
        let url = f.store.audioDirectory(for: saved.meetingID).appendingPathComponent(name)
        try MeetingWAVFile.write(pcm: Data(), sampleRate: 16_000, to: url)
        saved.activeSourceJournals["sys"] = MeetingActiveJournal(filename: name, segmentIndex: 1, startOffset: 30)
        try f.store.saveManifest(saved)
        #expect(try f.store.completeOnlineRecovery(meetingID: saved.meetingID))
        #expect(try f.store.load(meetingID: saved.meetingID).segments.count == 2)
    }
}


extension OnlineMeetingTranscriptionTests {
    @MainActor @Test func recoveredArtifactUsesRecordedWAVRateInsteadOfSourcePreference() throws {
        let f = try OnlineFixture(); defer { f.cleanup() }
        var saved = f.manifest
        let name = "system-audio/segment_0001.wav"
        try MeetingWAVFile.write(pcm: Data(repeating: 32, count: 96_000), sampleRate: 48_000,
            to: f.store.audioDirectory(for: saved.meetingID).appendingPathComponent(name))
        saved.activeSourceJournals["sys"] = MeetingActiveJournal(filename: name, segmentIndex: 1, startOffset: 30)
        try f.store.saveManifest(saved)
        let recovered = try f.store.reconcileOnlineAudio(meetingID: saved.meetingID)
        let artifact = try #require(recovered.audioArtifacts.first { $0.id == "sys-1" })
        #expect(artifact.sampleRate == 48_000)
        #expect(artifact.startOffset == 30 && artifact.endOffset == 31)
        #expect(recovered.sources.first { $0.sourceID == "sys" }?.sampleRate == 16_000)
    }
}
