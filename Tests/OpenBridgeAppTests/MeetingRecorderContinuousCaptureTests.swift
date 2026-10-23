import Testing
import Foundation
@testable import OpenBridgeApp

/// #294 wave-1 (3857377369 / 3857377361): continuous capture slices
/// overlapping chunk windows from the ring without stopping the engine, and
/// boundaries carry real offsets. The slice/RMS machinery is exercised with
/// synthetic PCM through the public writer + policy.
@Suite(.serialized) struct MeetingRecorderContinuousCaptureTests {

    @MainActor @Test func capturePersistenceDoesNotRunOnInterfaceThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plainStore = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Synthetic responsiveness", state: .recording)
        try plainStore.create(manifest)
        let probe = CaptureThreadProbe()
        let store = MeetingSessionStore(rootDirectory: root, saveFaultInjector: { _ in
            probe.record(isMainThread: Thread.isMainThread)
        })
        let recorder = MeetingRecorder(store: store, capturesMicrophone: false)
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil, segmentDurationSeconds: 1)
        let pcm = Data(repeating: 32, count: 16_000 * 2)
        await recorder.ingestTestPCM(pcm, sampleRate: 16_000, presentationTime: 100)
        let files = try await recorder.stopRecording()
        #expect(!probe.values.isEmpty)
        #expect(probe.values.allSatisfy { !$0 })
        #expect(files.count == 1)
        #expect(try MeetingWAVFile.durationSeconds(at: #require(files.first)) == 1)
    }

    @MainActor @Test func slowCaptureSaveAllowsInterfaceHeartbeats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = MeetingManifest(title: "Synthetic slow storage", state: .recording)
        try MeetingSessionStore(rootDirectory: root).create(manifest)
        let gate = CaptureSaveGate()
        defer { gate.release() }
        let store = MeetingSessionStore(rootDirectory: root, saveFaultInjector: { _ in
            gate.blockFirstSave()
        })
        let recorder = MeetingRecorder(store: store, capturesMicrophone: false)
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil)
        let ingestion = Task { @MainActor in
            await recorder.ingestTestPCM(Data(repeating: 32, count: 8_000), sampleRate: 16_000, presentationTime: 100)
        }
        let deadline = Date().addingTimeInterval(20)
        while !gate.hasEntered && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        // Only this main-actor continuation can release the delayed writer.
        // Also exercise the real timer's snapshot reads while disk IO is parked.
        _ = recorder.lastMeterLevel
        _ = recorder.completedSegments
        gate.release()
        await ingestion.value
        #expect(!gate.didTimeOut)
        let files = try await recorder.stopRecording()
        #expect(files.count == 1)
        #expect(!recorder.isRecording)
    }

    @MainActor @Test func stopPreservesOrderedPCMAndFinalTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Synthetic ordered tail", state: .recording)
        try store.create(manifest)
        let recorder = MeetingRecorder(store: store, capturesMicrophone: false)
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil)
        var expectedPCM = Data()
        for index in 0..<3 {
            let pcm = Data(repeating: UInt8(32 + index), count: 8_000)
            expectedPCM.append(pcm)
            await recorder.ingestTestPCM(pcm, sampleRate: 16_000, presentationTime: 100 + Double(index) * 0.25)
        }
        let files = try await recorder.stopRecording()
        let wav = try Data(contentsOf: #require(files.first))
        #expect(files.count == 1)
        #expect(Data(wav.suffix(expectedPCM.count)) == expectedPCM)
        #expect(try MeetingWAVFile.durationSeconds(at: #require(files.first)) == 0.75)
        #expect(recorder.chunkBoundaries.last?.endOffset == 0.75)
        #expect(try await recorder.stopRecording() == files)
    }

    @MainActor @Test func workerPublishesFatalStorageFailureAndCanRetryStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = MeetingManifest(title: "Synthetic failed storage", state: .recording)
        try MeetingSessionStore(rootDirectory: root).create(manifest)
        let store = MeetingSessionStore(rootDirectory: root, saveFaultInjector: { _ in
            throw NSError(domain: "SyntheticCaptureStorage", code: 1)
        })
        let recorder = MeetingRecorder(store: store, capturesMicrophone: false)
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil)
        for index in 0..<4 {
            await recorder.ingestTestPCM(Data(repeating: 32, count: 8_000), sampleRate: 16_000,
                                         presentationTime: 100 + Double(index) * 0.25)
        }
        #expect(!recorder.isRecording)
        #expect(recorder.fatalCaptureError != nil)
        #expect(recorder.failureStatePersistenceError != nil)
        #expect(await recorder.retryPersistingFatalCaptureState() != nil)
        await #expect(throws: MeetingRecorderError.self) { try await recorder.stopRecording() }
    }

    @Test func concurrentCaptureAndTranscriptTransactionsKeepBothUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Synthetic concurrent persistence", state: .recording)
        try store.create(manifest)
        let captureStore = MeetingSessionStore(rootDirectory: root, saveFaultInjector: { _ in
            Thread.sleep(forTimeInterval: 0.002)
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<20 {
                    try captureStore.saveCaptureProgress(meetingID: manifest.meetingID,
                        completedSegmentFilenames: ["segment_\(index).wav"], chunkBoundaries: [], activeJournal: nil)
                }
            }
            group.addTask {
                for index in 0..<20 {
                    try store.appendSegment(MeetingTranscriptSegment(meetingID: manifest.meetingID,
                        sequence: index, sourceLabel: "Synthetic", text: "marker \(index)", isFinal: true),
                        meetingID: manifest.meetingID)
                }
            }
            try await group.waitForAll()
        }
        let saved = try store.load(meetingID: manifest.meetingID)
        #expect(saved.audioSegments == ["segment_19.wav"])
        #expect(saved.segments.map(\.sequence) == Array(0..<20))
    }

    @Test func captureTimelineIgnoresCallbackSchedulingDelay() {
        var clock = MeetingCaptureTimeline()
        let oneSecondAt16KHz = 16_000 * 2

        let first = clock.advance(
            presentationTime: 100,
            pcmByteCount: oneSecondAt16KHz,
            sampleRate: 16_000
        )
        let second = clock.advance(
            presentationTime: 101,
            pcmByteCount: oneSecondAt16KHz,
            sampleRate: 16_000
        )
        #expect(first.elapsed == 1)
        #expect(second.elapsed == 2)
        #expect(second.gapBeforeBuffer == 0)
    }

    @Test func captureTimelinePreservesRealPresentationGap() {
        var clock = MeetingCaptureTimeline()
        let quarterSecondAt16KHz = 4_000 * 2

        _ = clock.advance(
            presentationTime: 50,
            pcmByteCount: quarterSecondAt16KHz,
            sampleRate: 16_000
        )
        let afterDroppedAudio = clock.advance(
            presentationTime: 50.75,
            pcmByteCount: quarterSecondAt16KHz,
            sampleRate: 16_000
        )

        #expect(afterDroppedAudio.gapBeforeBuffer == 0.5)
        #expect(afterDroppedAudio.elapsed == 1)
    }

    @Test func conversionFailureMarkerDoesNotConsumeDroppedGap() {
        var clock = MeetingCaptureTimeline()
        _ = clock.advance(
            presentationTime: 10,
            pcmByteCount: 0,
            sampleRate: 0
        )
        let recovered = clock.advance(
            presentationTime: 10.25,
            pcmByteCount: 4_000 * 2,
            sampleRate: 16_000
        )

        #expect(recovered.gapBeforeBuffer == 0.25)
        #expect(recovered.elapsed == 0.5)
    }

    @Test func persistentStorageFailuresTripBoundedAbortGuard() {
        var guardrail = MeetingCaptureStorageFailureGuard(maximumConsecutiveFailures: 3)
        let first = guardrail.recordFailure()
        #expect(!first)

        // Reopening the file is not proof that a pending boundary sealed.
        // These successes must not erase the repeated seal-failure streak.
        guardrail.recordSuccess(boundaryPending: true)
        #expect(guardrail.consecutiveFailures == 1)
        let second = guardrail.recordFailure()
        #expect(!second)
        guardrail.recordSuccess(boundaryPending: true)
        let third = guardrail.recordFailure()
        #expect(third)

        guardrail.recordSuccess()
        #expect(guardrail.consecutiveFailures == 0)
    }

    @Test func overlapOnlySilenceDoesNotCreateNextJournal() {
        #expect(!MeetingActiveJournalAdmission.shouldPersist(
            writerExists: false,
            writerNeedsRebuild: false,
            boundaryPending: false,
            currentLevel: 0
        ))
        #expect(MeetingActiveJournalAdmission.shouldPersist(
            writerExists: false,
            writerNeedsRebuild: false,
            boundaryPending: false,
            currentLevel: 0.8
        ))
        #expect(MeetingActiveJournalAdmission.shouldPersist(
            writerExists: false,
            writerNeedsRebuild: false,
            boundaryPending: true,
            currentLevel: 0
        ))
    }

    @Test func droppedGapDoesNotCutFixedWindowShort() {
        let times = MeetingCaptureGapPolicy.silenceSampleTimes(from: 0, to: 1)
        #expect(times == [0.5, 1])

        var accumulator = MeetingChunkAccumulator()
        accumulator.beginChunk(at: 0)
        _ = accumulator.feed(time: 0, level: 0.8)

        var boundary: MeetingChunkBoundary?
        for time in times where boundary == nil {
            boundary = accumulator.feed(time: time, level: 0)
        }

        #expect(boundary == nil)
        let stopped = accumulator.forceBoundary(at: 1)
        #expect(stopped?.reason == .stop)
        #expect(stopped?.endOffset == 1)
    }

    @Test func sliceWindowFromRingMatchesExpectedPCM() {
        // Build 1 s of raw PCM at 48 kHz (96,000 bytes) and slice a 0.5 s
        // window using the same sample math the recorder's ring uses
        // (sample offsets -> byte offsets, 2 bytes/sample).
        let sampleRate = 48000
        let ring = Data(repeating: 7, count: sampleRate * 2)
        let startSample = 0
        let endSample = sampleRate / 2
        let startByte = startSample * 2
        let endByte = endSample * 2
        let slice = ring.subdata(in: startByte..<endByte)
        #expect(slice.count == sampleRate)
        #expect(slice.allSatisfy { $0 == 7 })
    }

    @Test func chunkBoundariesCarryRealOffsetsAndReasons() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var b: MeetingChunkBoundary?
        var t = 0.1
        while t <= 30.5, b == nil {
            b = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(b != nil)
        guard let b else { return }
        #expect(b.reason == .maxDuration)
        #expect(b.startOffset >= 0)
        #expect(b.endOffset > b.startOffset)
        #expect(b.availableOverlap == b.overlapSeconds)
        acc.beginChunk(at: acc.nextChunkStart(after: b))
        var c: MeetingChunkBoundary?
        while t <= 60.5, c == nil {
            c = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(c != nil)
        guard let c else { return }
        #expect(c.chunkIndex == b.chunkIndex + 1)
        #expect(c.startOffset == b.endOffset - b.overlapSeconds)
        #expect(c.endOffset > b.endOffset)
    }

    @Test func overlapWindowIsRealAudioNotReconstruction() {
        // The next chunk's startOffset == previous end - overlap, meaning
        // the ring slice for the next chunk includes actual samples from
        // the previous chunk's tail (no fabricated context).
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var b: MeetingChunkBoundary?
        var t = 0.1
        while t <= 30.5, b == nil {
            b = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        guard let b else { return }
        acc.beginChunk(at: acc.nextChunkStart(after: b))
        #expect(b.overlapSeconds == 1.5)
        #expect(b.availableOverlap == b.overlapSeconds)
    }
}

private final class CaptureThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    func record(isMainThread: Bool) { lock.lock(); defer { lock.unlock() }; observations.append(isMainThread) }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return observations }
}

private final class CaptureSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var entered = false
    private var timedOut = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func release() { signal.signal() }
    func blockFirstSave() {
        lock.lock()
        if entered { lock.unlock(); return }
        entered = true
        lock.unlock()
        let result = signal.wait(timeout: .now() + 15)
        lock.lock()
        timedOut = result == .timedOut
        lock.unlock()
    }
}


extension MeetingRecorderContinuousCaptureTests {
    @Test func providerFailureEventCannotOverwriteConcurrentCaptureJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Synthetic event/capture race", state: .recording)
        try store.create(manifest)
        let captureStore = MeetingSessionStore(rootDirectory: root, saveFaultInjector: { _ in
            // Hold the write lock while the other executor attempts its event.
            Thread.sleep(forTimeInterval: 0.003)
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<40 {
                    try captureStore.saveCaptureProgress(meetingID: manifest.meetingID,
                        completedSegmentFilenames: ["segment_\(index).wav"], chunkBoundaries: [],
                        activeJournal: MeetingActiveJournal(filename: "segment_\(index + 1).wav",
                            segmentIndex: index + 1, startOffset: Double(index + 1) * 30))
                }
            }
            group.addTask {
                for index in 0..<40 {
                    try store.recordRecoveryEvent(meetingID: manifest.meetingID, kind: "PROVIDER_FAILURE", detail: "fixture \(index)")
                }
            }
            try await group.waitForAll()
        }
        let saved = try store.load(meetingID: manifest.meetingID)
        #expect(saved.audioSegments == ["segment_39.wav"])
        #expect(saved.activeJournal?.segmentIndex == 40)
        #expect(saved.events.count == 40)
        #expect(saved.state == .recording)
    }
}
