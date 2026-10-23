import AVFoundation
import Foundation
import os

/// Durations only: never log audio, transcript text, or meeting identifiers.
enum MeetingPerformance {
    private static let logger = Logger(subsystem: "studio.lunr.openbridge", category: "MeetingPerformance")

    static func record(_ operation: String, since started: TimeInterval) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        logger.info("\(operation, privacy: .public): \(milliseconds, privacy: .public) ms")
    }
}

/// Wave-7 (3865752976): thread-safe FIFO for capture-thread PCM. Appends are
/// serialized by the capture queue and guarded by a lock (capture thread);
/// the recorder worker drains it in FIFO order.
private final class PendingIngestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(pcm: Data, sampleRate: Int, presentationTime: TimeInterval?)] = []

    func enqueue(_ item: (pcm: Data, sampleRate: Int, presentationTime: TimeInterval?)) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    func drainAll() -> [(pcm: Data, sampleRate: Int, presentationTime: TimeInterval?)] {
        lock.lock()
        defer { lock.unlock() }
        let drained = items
        items.removeAll(keepingCapacity: true)
        return drained
    }
}

struct MeetingCaptureTiming: Equatable {
    let elapsed: TimeInterval
    let gapBeforeBuffer: TimeInterval
}

/// Capture time derived from the sample buffer presentation clock. Callback
/// scheduling cannot stretch it, while a genuinely dropped buffer remains a
/// real gap instead of silently shortening the meeting timeline.
struct MeetingCaptureTimeline {
    private(set) var elapsed: TimeInterval = 0
    private var firstPresentationTime: TimeInterval?

    mutating func advance(
        presentationTime: TimeInterval?,
        pcmByteCount: Int,
        sampleRate: Int,
        bytesPerSample: Int = 2
    ) -> MeetingCaptureTiming {
        if firstPresentationTime == nil,
           let presentationTime,
           presentationTime.isFinite {
            firstPresentationTime = presentationTime
        }
        guard sampleRate > 0, bytesPerSample > 0 else {
            return MeetingCaptureTiming(elapsed: elapsed, gapBeforeBuffer: 0)
        }
        let sampleCount = pcmByteCount / bytesPerSample
        let duration = Double(sampleCount) / Double(sampleRate)
        let contiguousEnd = elapsed + duration

        guard let presentationTime, presentationTime.isFinite else {
            elapsed = contiguousEnd
            return MeetingCaptureTiming(elapsed: elapsed, gapBeforeBuffer: 0)
        }

        guard let firstPresentationTime else {
            elapsed = contiguousEnd
            return MeetingCaptureTiming(elapsed: elapsed, gapBeforeBuffer: 0)
        }

        // A conversion-failure marker establishes the hardware-clock anchor
        // but must not consume timeline duration: the next successful buffer
        // will materialize the entire missing interval as bounded silence.
        guard sampleCount > 0 else {
            return MeetingCaptureTiming(elapsed: elapsed, gapBeforeBuffer: 0)
        }

        let presentedStart = max(0, presentationTime - firstPresentationTime)
        // Ignore sub-millisecond timestamp jitter; a real skipped audio buffer
        // is materially larger than this tolerance.
        let gap = max(0, presentedStart - elapsed)
        let meaningfulGap = gap >= 0.001 ? gap : 0
        elapsed = meaningfulGap > 0 ? presentedStart + duration : contiguousEnd
        return MeetingCaptureTiming(elapsed: elapsed, gapBeforeBuffer: meaningfulGap)
    }

    mutating func reset() {
        elapsed = 0
        firstPresentationTime = nil
    }
}

struct MeetingCaptureStorageFailureGuard {
    let maximumConsecutiveFailures: Int
    private(set) var consecutiveFailures = 0

    init(maximumConsecutiveFailures: Int = 3) {
        self.maximumConsecutiveFailures = max(1, maximumConsecutiveFailures)
    }

    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= maximumConsecutiveFailures
    }

    mutating func recordSuccess(boundaryPending: Bool = false) {
        guard !boundaryPending else { return }
        consecutiveFailures = 0
    }
}

enum MeetingActiveJournalAdmission {
    static func shouldPersist(
        writerExists: Bool,
        writerNeedsRebuild: Bool,
        boundaryPending: Bool,
        currentLevel: Double,
        speechThreshold: Double = MeetingChunkPolicyConfiguration.live.silenceLevelThreshold
    ) -> Bool {
        writerExists
            || writerNeedsRebuild
            || boundaryPending
            || currentLevel >= speechThreshold
    }
}

/// Converts a real presentation-time hole into bounded silence-policy ticks.
/// The accumulator intentionally caps any single tick at 0.5 seconds, so a
/// longer gap must be represented by multiple ticks or it cannot satisfy the
/// 0.85-second utterance threshold.
enum MeetingCaptureGapPolicy {
    static func silenceSampleTimes(
        from startTime: TimeInterval,
        to endTime: TimeInterval,
        maximumStep: TimeInterval = 0.5
    ) -> [TimeInterval] {
        guard startTime.isFinite,
              endTime.isFinite,
              endTime > startTime,
              maximumStep > 0
        else { return [] }

        var times: [TimeInterval] = []
        var cursor = startTime
        while cursor < endTime {
            cursor = min(cursor + maximumStep, endTime)
            times.append(cursor)
        }
        return times
    }
}

/// #294 continuous-capture meeting recorder.
///
/// Wave-1 (3857377369) removed the stop/restart file-rotation audio gap by
/// capturing continuously; wave-2 (3864613542) restores device selection and
/// (3864613553) continuous sample delivery by using `AVCaptureSession` +
/// `AVCaptureAudioDataOutput`: the session honors the requested microphone via
/// `AVCaptureDeviceInput`, and the data output delivers sample buffers
/// continuously (no audio is ever dropped at chunk rotation). PCM is converted
/// on the CAPTURE thread (only Sendable data hops to the recorder worker) and
/// accumulates in an in-memory ring buffer; the chunking policy slices
/// overlapping transcription windows out of the ring and writes each as a WAV.
///
/// Public recorder API is preserved: `startRecording(meetingID:deviceID:)`,
/// `stopRecording() async`, `cancelRecording()`, `completedSegmentCount`,
/// `lastMeterLevel`, `chunkBoundaries`.
@MainActor
final class MeetingRecorder: NSObject {
    nonisolated private let worker: MeetingCaptureWorker
    private var isStarting = false
    private let configuredSource: MeetingSourceMetadata?
    var captureMode: MeetingCaptureMode { configuredSource == nil ? .inPerson : .online }
    var researchCaptureProgress: [ResearchCaptureSourceProgress] { worker.snapshot.researchProgress }

    var isRecording: Bool { worker.snapshot.isRecording }
    var lastMeterLevel: Double { worker.snapshot.lastMeterLevel }
    var capturedAudioHealth: MeetingAudioHealth {
        let value = worker.snapshot
        return .assess(lastSampleAt: value.lastSampleAt, level: value.lastMeterLevel, failed: value.fatalCaptureError != nil)
    }
    var microphoneAudioHealth: MeetingAudioHealth? { capturedAudioHealth }
    var completedSegments: [URL] { worker.snapshot.completedSegments }
    var completedSegmentCount: Int { worker.snapshot.completedSegments.count }
    var chunkBoundaries: [MeetingChunkBoundary] { worker.snapshot.chunkBoundaries }
    var fatalCaptureError: MeetingRecorderError? { worker.snapshot.fatalCaptureError }
    var audioArtifacts: [MeetingAudioArtifact] { worker.snapshot.audioArtifacts }
    var failureStatePersistenceError: String? { worker.snapshot.failureStatePersistenceError }

    init(store: MeetingSessionStore, capturesMicrophone: Bool = true, source: MeetingSourceMetadata? = nil) {
        configuredSource = source
        worker = MeetingCaptureWorker(store: store, capturesMicrophone: capturesMicrophone, source: source)
    }

    func startRecording(
        meetingID: String,
        deviceID: String?,
        segmentDurationSeconds: TimeInterval = MeetingChunkPolicyConfiguration.live.maxChunkDurationSeconds,
        commonClockOrigin: TimeInterval? = nil
    ) async throws {
        guard !isStarting, !isRecording else { throw MeetingRecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        try await worker.perform("capture-start") { core in
            try core.startRecording(meetingID: meetingID, deviceID: deviceID,
                                    segmentDurationSeconds: segmentDurationSeconds, commonClockOrigin: commonClockOrigin)
        }
    }

    func stopRecording() async throws -> [URL] {
        try await worker.perform("capture-stop") { try $0.stopRecording() }
    }

    func cancelRecording() async {
        try? await worker.perform("capture-cancel") { $0.cancelRecording() }
    }

    @discardableResult
    func retryPersistingFatalCaptureState() async -> String? {
        try? await worker.perform("capture-failure-state") { $0.retryPersistingFatalCaptureState() }
    }

    /// ScreenCaptureKit uses the same conversion, FIFO, chunking and journal path.
    nonisolated func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        worker.enqueueSampleBuffer(sampleBuffer)
    }

    /// Hardware-free input follows the real FIFO and persistence path.
    func ingestTestPCM(_ pcm: Data, sampleRate: Int, presentationTime: TimeInterval) async {
        precondition(!worker.capturesMicrophone)
        try? await worker.perform("capture-test-input") { core in
            core.ingestFromQueue(pcm: pcm, sampleRate: sampleRate, presentationTime: presentationTime)
        }
    }
}

private struct MeetingCaptureSnapshot: Sendable {
    var researchProgress: [ResearchCaptureSourceProgress] = []
    var audioArtifacts: [MeetingAudioArtifact] = []
    var isRecording = false
    var lastMeterLevel: Double = 0
    var lastSampleAt: Date?
    var completedSegments: [URL] = []
    var chunkBoundaries: [MeetingChunkBoundary] = []
    var fatalCaptureError: MeetingRecorderError?
    var failureStatePersistenceError: String?
}

/// Mutable recorder state belongs exclusively to workQueue. The capture
/// callback only enqueues immutable PCM in its locked FIFO. The interface
/// reads a short-lived snapshot lock, never a lock held during file/device IO.
private final class MeetingCaptureWorker: NSObject, @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "openbridge.meeting.worker", qos: .userInitiated)
    private let snapshotLock = NSLock()
    private var publishedSnapshot = MeetingCaptureSnapshot()

    var snapshot: MeetingCaptureSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publishedSnapshot
    }

    private func publishSnapshot() {
        let next = MeetingCaptureSnapshot(
            researchProgress: makeResearchProgress(),
            audioArtifacts: makeAudioArtifacts(),
            isRecording: isRecording, lastMeterLevel: lastMeterLevel,
            lastSampleAt: lastSampleAt,
            completedSegments: completedSegments, chunkBoundaries: chunkBoundaries,
            fatalCaptureError: fatalCaptureError,
            failureStatePersistenceError: failureStatePersistenceError
        )
        snapshotLock.lock()
        publishedSnapshot = next
        snapshotLock.unlock()
    }

    func perform<T: Sendable>(
        _ label: String,
        _ operation: @escaping @Sendable (MeetingCaptureWorker) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                let started = ProcessInfo.processInfo.systemUptime
                let result = Result { try operation(self) }
                self.publishSnapshot()
                MeetingPerformance.record(label, since: started)
                continuation.resume(with: result)
            }
        }
    }

    private func scheduleDrain() {
        workQueue.async {
            self.drainPendingIngest()
            self.publishSnapshot()
        }
    }

    private lazy var session = AVCaptureSession()
    private lazy var dataOutput = AVCaptureAudioDataOutput()
    private var input: AVCaptureDeviceInput?
    private var configuredDeviceID: String?
    private let captureQueue = DispatchQueue(label: "openbridge.meeting.capture")

    private var meetingID: String?
    private var isStopping = false
    private(set) var isRecording = false
    private(set) var lastMeterLevel: Double = 0
    private var lastSampleAt: Date?
    /// Wave-7 (3865752976): FIFO queue of capture-thread PCM (int16 mono +
    /// sample rate + capture timestamp). Appended ON THE CAPTURE THREAD (the
    /// serial capture queue preserves callback order) BEFORE any actor work is
    /// spawned, then drained IN ORDER on the recorder worker. The wave-6 version
    /// appended inside the main-actor tasks — task scheduling could still
    /// reorder them.
    private let pendingIngest = PendingIngestQueue()

    /// Finalized chunk WAV URLs in flush order (the transcriber counts these).
    private(set) var completedSegments: [URL] = []
    var completedSegmentCount: Int { completedSegments.count }

    // MARK: - #294 ring buffer / slicing

    private var ring = Data()
    private var ringCapacityBytes = 0
    /// Absolute sample index represented by `ring[0]` (wave-2 3864613522).
    private var ringOriginSample = 0
    private var sampleRate = 48000
    private var capturedSampleCount = 0
    private var captureTimeline = MeetingCaptureTimeline()
    private let maximumRecoverableCaptureGap: TimeInterval = 2

    /// The active segment is journalled directly to its final WAV path while
    /// recording. It is intentionally not counted as completed until a chunk
    /// boundary seals it, but a force-quit leaves recoverable audio on disk.
    private var activeWriter: MeetingStreamingWAVWriter?
    private var activeWriterStartSample = 0
    private var activeWriterNeedsRebuild = false
    private var pendingBoundary: MeetingChunkBoundary?
    /// Speech classification for the capture buffer that crossed a scheduled
    /// boundary whose writer could not be sealed yet. The PCM remains in the
    /// ring; this marker must survive until retry/finalization begins the next
    /// accumulator or that real tail can be mistaken for silence.
    private var pendingBoundaryCarrySample: (time: TimeInterval, level: Double)?
    private var storageFailureGuard = MeetingCaptureStorageFailureGuard()
    private(set) var fatalCaptureError: MeetingRecorderError?
    private(set) var failureStatePersistenceError: String?

    private var chunkAccumulator: MeetingChunkAccumulator?
    private var chunkPolicyConfiguration = MeetingChunkPolicyConfiguration.live
    private(set) var chunkBoundaries: [MeetingChunkBoundary] = []
    /// Wave-4 (3865266547): elapsed (from capture start) of the LAST buffer
    /// actually appended — the final boundary must end here, not at the
    /// post-drain wall clock (no PCM exists beyond the last buffer).
    private var lastIngestElapsed: TimeInterval = 0

    private let store: MeetingSessionStore
    private let source: MeetingSourceMetadata?
    private var commonClockOrigin: TimeInterval?
    private var sourceOffset: TimeInterval?
    let capturesMicrophone: Bool

    init(store: MeetingSessionStore, capturesMicrophone: Bool = true, source: MeetingSourceMetadata? = nil) {
        self.store = store
        self.capturesMicrophone = capturesMicrophone
        self.source = source
    }

    // MARK: - Public API

    func startRecording(
        meetingID: String,
        deviceID: String?,
        segmentDurationSeconds: TimeInterval = MeetingChunkPolicyConfiguration.live.maxChunkDurationSeconds,
        commonClockOrigin: TimeInterval? = nil
    ) throws {
        guard !isRecording else { throw MeetingRecorderError.alreadyRecording }
        self.meetingID = meetingID
        self.commonClockOrigin = commonClockOrigin
        self.sourceOffset = nil
        self.completedSegments = []
        self.chunkBoundaries = []
        self.isStopping = false
        self.ring = Data()
        self.ringOriginSample = 0
        var policy = MeetingChunkPolicyConfiguration.live
        policy.maxChunkDurationSeconds = max(1, segmentDurationSeconds)
        // The production 30-second policy retains 35 seconds. A deliberately
        // selected longer benchmark window receives the same 5-second safety
        // margin so recorder offsets can never describe audio already evicted.
        policy.ringRetentionSeconds = max(
            MeetingChunkPolicyConfiguration.live.ringRetentionSeconds,
            policy.maxChunkDurationSeconds + 5
        )
        self.chunkPolicyConfiguration = policy
        self.ringCapacityBytes = sampleRate * 2 * Int(policy.ringRetentionSeconds.rounded(.up))
        self.capturedSampleCount = 0
        self.captureTimeline.reset()
        self.lastIngestElapsed = 0
        self.activeWriter = nil
        self.activeWriterStartSample = 0
        self.activeWriterNeedsRebuild = false
        self.pendingBoundary = nil
        self.pendingBoundaryCarrySample = nil
        self.storageFailureGuard = MeetingCaptureStorageFailureGuard()
        self.fatalCaptureError = nil
        self.lastSampleAt = nil
        self.failureStatePersistenceError = nil
        self.chunkAccumulator = MeetingChunkAccumulator(configuration: policy)
        self.chunkAccumulator?.beginChunk(at: 0)

        if capturesMicrophone {
            try configureSession(deviceID: physicalDeviceID(from: deviceID))
        }
        // With sample-derived timing there is no wall-clock anchor race. Mark
        // the recorder active before the session starts so its first delivered
        // buffer is accepted rather than silently dropped.
        self.isRecording = true
        if capturesMicrophone { startSessionIfNeeded() }
    }

    func stopRecording() throws -> [URL] {
        if let fatalCaptureError { throw fatalCaptureError }
        guard isRecording else { return completedSegments }
        isStopping = true

        // Wave-3 (3864858066): stop capture FIRST, drain the capture queue
        // and its FIFO, and only THEN finalize
        // the boundary — otherwise buffers delivered during finalize are
        // discarded (recordingStartTime is already nil).
        if capturesMicrophone { session.stopRunning() }
        captureQueue.sync { }
        // No scheduling guesses: all capture callbacks have completed and
        // their FIFO is now drained on this same serial worker before sealing.
        drainPendingIngest()

        // Wave-4 (3865266533): a final-chunk write failure is reported, not
        // silently swallowed — completing without that audio would be a
        // false completion.
        // Wave-6 (3865592992): on failure PRESERVE the anchor (and the
        // pending boundary / ring) so a retry of Stop actually finalizes
        // the tail — clearing the anchor would make the retry a no-op that
        // silently completes without the audio.
        guard finalizeCurrentChunk() else {
            isStopping = false
            throw fatalCaptureError ?? MeetingRecorderError.stopWriteFailed
        }
        if let source, let meetingID {
            // Do not report Stop complete if the final artifact receipt was not durable.
            try store.saveSourceCaptureProgress(meetingID: meetingID, sourceID: source.sourceID,
                artifacts: makeAudioArtifacts(), journal: nil)
        }
        isRecording = false
        isStopping = false
        return completedSegments
    }

    func cancelRecording() {
        guard isRecording else { return }
        isStopping = true
        if capturesMicrophone { session.stopRunning() }
        captureQueue.sync { }
        _ = pendingIngest.drainAll()
        try? activeWriter?.synchronizeAndClose()
        activeWriter = nil
        pendingBoundaryCarrySample = nil
        clearActiveJournalProgress()
        isRecording = false
        isStopping = false
        completedSegments = []
    }

    /// Retries the durable failed-state transition after capture has already
    /// stopped. The UI uses the returned message to decide whether it must
    /// overlay an in-memory failed state while storage remains unavailable.
    @discardableResult
    func retryPersistingFatalCaptureState() -> String? {
        guard let meetingID, let fatalCaptureError else { return nil }
        do {
            try store.markMeetingAsFailed(
                meetingID: meetingID,
                reason: fatalCaptureError.localizedDescription
            )
            failureStatePersistenceError = nil
        } catch {
            failureStatePersistenceError = error.localizedDescription
        }
        return failureStatePersistenceError
    }


    // MARK: - Session configuration (device selection)

    private func configureSession(deviceID: String?) throws {
        if configuredDeviceID == deviceID, input != nil, session.outputs.contains(dataOutput) {
            return
        }
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            if wasRunning { startSessionIfNeeded() }
        }

        if let input {
            session.removeInput(input)
            self.input = nil
        }

        // Ask for linear PCM int16 mono at 48 kHz; if the device cannot
        // honor it we convert from the delivered format on the capture thread.
        dataOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        if !session.outputs.contains(dataOutput) {
            if session.canAddOutput(dataOutput) {
                session.addOutput(dataOutput)
            } else {
                throw MeetingRecorderError.outputUnavailable
            }
        }
        dataOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard let device = selectedDevice(for: deviceID) else {
            configuredDeviceID = nil
            throw MeetingRecorderError.noInputDevice
        }
        let nextInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(nextInput) else {
            throw MeetingRecorderError.inputUnavailable(device.localizedName)
        }
        session.addInput(nextInput)
        input = nextInput
        configuredDeviceID = deviceID
    }

    private func selectedDevice(for deviceID: String?) -> AVCaptureDevice? {
        if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func physicalDeviceID(from deviceID: String?) -> String? {
        guard let deviceID, deviceID != MicrophoneDevice.systemDefaultID else {
            return nil
        }
        return deviceID
    }

    private func startSessionIfNeeded() {
        guard !session.isRunning else { return }
        session.startRunning()
    }


    // MARK: - Capture -> ring (conversion on the capture thread)

    /// Wave-6 (3865593002): drain the FIFO in strict capture order. Callbacks
    /// append to `pendingIngest`; only this single drain appends to the ring,
    /// so a later buffer can never be ingested ahead of an earlier one.
    private func drainPendingIngest() {
        for next in pendingIngest.drainAll() {
            ingestFromQueue(
                pcm: next.pcm,
                sampleRate: next.sampleRate,
                presentationTime: next.presentationTime
            )
        }
    }

    fileprivate func ingestFromQueue(
        pcm: Data,
        sampleRate: Int,
        presentationTime: TimeInterval?
    ) {
        guard isRecording else { return }

        if source != nil, sampleRate > 0, sampleRate != self.sampleRate, capturedSampleCount > 0 {
            abortCapture(with: .onlineCaptureFailed("The audio format changed during capture. Audio is preserved; start a new recording with the selected device."))
            return
        }
        // Adopt the delivered rate if the device did not honor 48 kHz
        // (keeps ring capacity and slice math accurate).
        if sampleRate > 0, sampleRate != self.sampleRate {
            self.sampleRate = sampleRate
            ringCapacityBytes = sampleRate * 2
                * Int(chunkPolicyConfiguration.ringRetentionSeconds.rounded(.up))
        }

        if sourceOffset == nil, let commonClockOrigin, let presentationTime {
            sourceOffset = max(0, presentationTime - commonClockOrigin)
        }
        let previousElapsed = captureTimeline.elapsed
        let timing = captureTimeline.advance(
            presentationTime: presentationTime,
            pcmByteCount: pcm.count,
            sampleRate: self.sampleRate
        )
        // A conversion-failure marker still anchors the presentation clock,
        // but it contains no audio to persist or meter.
        guard !pcm.isEmpty else { return }
        lastSampleAt = Date()

        // Keep the WAV sample positions aligned with presentation time by
        // materializing short dropped-buffer gaps as silence. Larger gaps mean
        // the capture device was interrupted; fail visibly instead of creating
        // an unbounded allocation or pretending continuous audio exists.
        if timing.gapBeforeBuffer > maximumRecoverableCaptureGap {
            abortCapture(with: .captureDiscontinuity(timing.gapBeforeBuffer))
            return
        }
        let gapSampleCount = Int((timing.gapBeforeBuffer * Double(self.sampleRate)).rounded())
        let gapPCM = Data(repeating: 0, count: max(0, gapSampleCount * 2))
        var journalPCM = Data(capacity: gapPCM.count + pcm.count)
        journalPCM.append(gapPCM)
        journalPCM.append(pcm)

        lastIngestElapsed = timing.elapsed
        ring.append(journalPCM)
        capturedSampleCount += journalPCM.count / 2
        lastMeterLevel = Self.normalizedLevel(fromInt16: pcm)

        // If the prior callback found a boundary but could not seal it, retry
        // before journalling this callback. On success this buffer belongs to
        // the new chunk; on failure it stays safely pinned in the ring.
        guard retryPendingBoundaryIfNeeded() else { return }

        // Persist the active chunk before allowing the ring to evict older
        // samples. If a write fails, rebuilding stays possible because trimming
        // is paused until the complete current window is safely on disk again.
        if MeetingActiveJournalAdmission.shouldPersist(
            writerExists: activeWriter != nil,
            writerNeedsRebuild: activeWriterNeedsRebuild,
            boundaryPending: pendingBoundary != nil,
            currentLevel: lastMeterLevel
        ) {
            persistActiveChunk(pcm: journalPCM)
        }
        guard fatalCaptureError == nil else { return }

        // Wave-2 (3864613522): ring trimming must track the absolute sample
        // origin so slice offsets stay correct past 16 s of capture.
        if !activeWriterNeedsRebuild, pendingBoundary == nil, ring.count > ringCapacityBytes {
            let drop = ring.count - ringCapacityBytes
            let alignedDrop = drop - (drop % 2)
            ring.removeSubrange(0..<alignedDrop)
            ringOriginSample += alignedDrop / 2
        }

        // A presentation-time gap participates in silence-boundary decisions.
        // Feed it in <=0.5 s steps because the accumulator deliberately caps a
        // single sample delta at 0.5 s to reject callback scheduling stalls.
        if timing.gapBeforeBuffer > 0 {
            let gapEnd = timing.elapsed - (Double(pcm.count / 2) / Double(self.sampleRate))
            for sampleTime in MeetingCaptureGapPolicy.silenceSampleTimes(
                from: previousElapsed,
                to: gapEnd
            ) {
                guard feedChunkPolicy(time: sampleTime, level: 0) else { break }
            }
            if let pendingBoundary {
                // A synthetic silence tick found the boundary, but the real
                // callback PCM was already appended to the ring above. If the
                // seal failed, replace that synthetic carry marker with this
                // actual buffer's end time and measured speech level so retry
                // or Stop cannot discard meaning-bearing post-boundary audio.
                if timing.elapsed > pendingBoundary.endOffset {
                    pendingBoundaryCarrySample = (
                        time: timing.elapsed,
                        level: lastMeterLevel
                    )
                }
                return
            }

            // The gap itself may have sealed the old chunk. The real speech
            // carried by this same callback belongs to the new chunk, so open
            // its journal now rather than waiting for another callback (which
            // might never arrive before a force-quit).
            if MeetingActiveJournalAdmission.shouldPersist(
                writerExists: activeWriter != nil,
                writerNeedsRebuild: activeWriterNeedsRebuild,
                boundaryPending: pendingBoundary != nil,
                currentLevel: lastMeterLevel
            ), activeWriter == nil {
                persistActiveChunk(pcm: journalPCM)
                guard fatalCaptureError == nil else { return }
            }
        }

        // Feed the policy; flush on boundary. On write failure the chunk is
        // NOT advanced (wave-2 3864613558): the next feed re-fires it.
        let policyAccepted = feedChunkPolicy(
            time: timing.elapsed,
            level: lastMeterLevel
        )
        guard policyAccepted else { return }

        // A capture buffer can straddle the exact scheduled boundary. The
        // sealed old writer is truncated at that boundary, while the same
        // buffer's speech state is carried into the next accumulator below.
        // Rebuild its active journal immediately from the retained ring so a
        // force-quit before the next callback cannot lose the short tail.
        if activeWriter == nil,
           chunkAccumulator?.hasHeardSpeech == true {
            persistActiveChunk(pcm: journalPCM)
        }
    }

    @discardableResult
    private func feedChunkPolicy(time: TimeInterval, level: Double) -> Bool {
        guard pendingBoundary == nil,
              var acc = chunkAccumulator,
              fatalCaptureError == nil
        else { return false }
        let priorWindowStart = acc.chunkStartOffset
        if let boundary = acc.feed(time: time, level: level) {
            chunkAccumulator = acc
            pendingBoundary = boundary
            let carrySample = time > boundary.endOffset
                ? (time: time, level: level)
                : nil
            if flush(boundary: boundary) {
                pendingBoundary = nil
                // The current capture buffer may extend past the scheduled
                // boundary. Re-feed its end sample after `flush` begins the
                // next overlapping window so Stop/recovery knows that real
                // post-boundary speech exists. Audio itself stays in `ring`.
                if carrySample != nil {
                    return feedChunkPolicy(time: time, level: level)
                }
                return true
            }
            pendingBoundaryCarrySample = carrySample
            return false
        } else {
            if acc.chunkStartOffset != priorWindowStart {
                activeWriterStartSample = Int(
                    acc.chunkStartOffset * Double(sampleRate)
                )
            }
            chunkAccumulator = acc
            return true
        }
    }

    private func retryPendingBoundaryIfNeeded() -> Bool {
        guard let pendingBoundary else { return true }
        if flush(boundary: pendingBoundary) {
            self.pendingBoundary = nil
            return replayPendingBoundaryCarryIfNeeded()
        }
        return false
    }

    /// Re-arm the overlapping accumulator with the speech state from the
    /// exact buffer that originally crossed the scheduled boundary. Called
    /// after a delayed seal succeeds, including during Stop finalization.
    private func replayPendingBoundaryCarryIfNeeded() -> Bool {
        guard let carrySample = pendingBoundaryCarrySample else { return true }
        pendingBoundaryCarrySample = nil
        return feedChunkPolicy(
            time: carrySample.time,
            level: carrySample.level
        )
    }

    private static func normalizedLevel(fromInt16 pcm: Data) -> Double {
        guard !pcm.isEmpty else { return 0 }
        var sum = 0.0
        var count = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            count = samples.count
            for v in samples {
                let x = Double(v) / 32767.0
                sum += x * x
            }
        }
        guard count > 0 else { return 0 }
        let rms = (sum / Double(count)).squareRoot()
        let db = 20.0 * log10(max(rms, 1e-6))
        let clamped = max(-60.0, min(0.0, db))
        return (clamped + 60) / 60
    }


    /// Convert a capture sample buffer to int16 mono PCM on the capture
    /// thread (handles float/int16, interleaved/non-interleaved).
    /// Runs on the capture thread (nonisolated): the sample buffer must be
    /// converted before hopping to the main actor.
    nonisolated private static func convertToPCM(sampleBuffer: CMSampleBuffer) -> (pcm: Data, sampleRate: Int)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let rate = Int(asbd.pointee.mSampleRate)
        guard frames > 0, channels > 0, rate > 0 else { return nil }

        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // Wave-3 (3864858108): allocate the FULL buffer-list storage — a
        // multichannel non-interleaved delivery returns one AudioBuffer per
        // channel, so a single-element typed allocation is not enough.
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let bufferListRaw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListRaw.deallocate() }
        let bufferListPtr = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let extractionStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPtr,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        // Wave-4 (3865266550): a nonzero status means the destination is NOT
        // valid — a recoverable dropped capture buffer, not undefined memory.
        guard extractionStatus == 0 else { return nil }

        // The AudioBuffer entries may point into `blockBuffer`. Keep that
        // retained Core Media storage alive until every sample has been read;
        // an optimized build may otherwise release it after extraction.
        return withExtendedLifetime(blockBuffer) {
            // Bind the variable-length AudioBufferList to the lifetime of the
            // storage we allocated above. Taking `&mBuffers` directly creates
            // a temporary pointer whose lifetime ends at the initializer call.
            let buffers = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            guard !buffers.isEmpty else { return nil }
            let samplesPerChannel = frames * (isFloat ? 4 : 2)
            let expected = nonInterleaved ? samplesPerChannel : frames * channels * (isFloat ? 4 : 2)
            if nonInterleaved {
                guard buffers.count >= channels else { return nil }
                for channel in 0..<channels {
                    guard Int(buffers[channel].mDataByteSize) >= expected,
                          buffers[channel].mData != nil
                    else { return nil }
                }
            } else {
                guard Int(buffers[0].mDataByteSize) >= expected else { return nil }
            }
            guard let mData = buffers[0].mData else { return nil }

            var out = Data(count: frames * 2)
            let ok = out.withUnsafeMutableBytes { raw -> Bool in
                let out16 = raw.bindMemory(to: Int16.self)
                // Wave-6 (3865593079): DOWNMIX multichannel inputs to mono
                // (average all channels) instead of selecting channel one — if
                // speech is routed to another channel, a mono mix keeps it.
                let divisor = Float(channels)
                if nonInterleaved {
                    // Each channel has its own AudioBuffer; average them.
                    if isFloat {
                        for i in 0..<frames {
                            var sum: Float = 0
                            for ch in 0..<channels {
                                guard let chData = buffers[ch].mData else { return false }
                                let f = chData.assumingMemoryBound(to: Float.self)
                                sum += f[i]
                            }
                            out16[i] = Int16(max(-1, min(1, sum / divisor)) * 32767)
                        }
                    } else {
                        for i in 0..<frames {
                            var sum: Int32 = 0
                            for ch in 0..<channels {
                                guard let chData = buffers[ch].mData else { return false }
                                let s = chData.assumingMemoryBound(to: Int16.self)
                                sum += Int32(s[i])
                            }
                            out16[i] = Int16(sum / Int32(channels))
                        }
                    }
                } else if isFloat {
                    let f = mData.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels {
                            sum += f[i * channels + ch]
                        }
                        out16[i] = Int16(max(-1, min(1, sum / divisor)) * 32767)
                    }
                } else {
                    let s = mData.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frames {
                        var sum: Int32 = 0
                        for ch in 0..<channels {
                            sum += Int32(s[i * channels + ch])
                        }
                        out16[i] = Int16(sum / Int32(channels))
                    }
                }
                return true
            }
            return ok ? (out, rate) : nil
        }
    }


    // MARK: - Chunk finalization / slicing

    private func finalizeCurrentChunk() -> Bool {
        if let pendingBoundary {
            var sealed = flush(boundary: pendingBoundary)
            if !sealed {
                sealed = flush(boundary: pendingBoundary)
            }
            guard sealed else { return false }
            self.pendingBoundary = nil
            guard replayPendingBoundaryCarryIfNeeded() else { return false }
        }
        guard var acc = chunkAccumulator else { return true }
        // Wave-4 (3865266547): end the final boundary at the LAST captured
        // buffer, not at the post-drain wall clock — no PCM exists beyond it.
        let elapsed = lastIngestElapsed
        // Wave-7 (3865753038): do NOT re-feed the last sample. Every drained
        // buffer already fed the accumulator; re-feeding a stale speech level
        // at the same timestamp could arm a fresh empty chunk (if the last
        // buffer just flushed a max-duration boundary) and forceBoundary would
        // write an overlap-only extra WAV. Finalize the EXISTING accumulator
        // state directly — forceBoundary no-ops when the chunk heard no
        // speech, and still finalizes a partial spoken tail.
        let boundary = acc.forceBoundary(at: elapsed)
        chunkAccumulator = acc
        guard let boundary else {
            discardUnfinalizedActiveWriter()
            return true
        }
        // Wave-4 (3865266533): Stop has no next policy feed, so a failed
        // final write must be retried here and reported if it still fails —
        // never silently omitted (the meeting would complete without audio).
        var ok = flush(boundary: boundary)
        if !ok {
            ok = flush(boundary: boundary)
        }
        return ok
    }

    /// Returns true when the WAV was written and the chunk advanced.
    private func flush(boundary: MeetingChunkBoundary) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        defer { MeetingPerformance.record("capture-chunk-seal", since: started) }
        let startSample = Int(boundary.startOffset * Double(sampleRate))
        let endSample = Int(boundary.endOffset * Double(sampleRate))
        guard endSample > startSample else { return true }

        let segmentIndex = completedSegments.count
        let url = segmentURL(meetingID: meetingID ?? "", index: segmentIndex)
        do {
            try sealActiveWriter(
                startSample: startSample,
                endSample: endSample,
                expectedURL: url
            )
            storageFailureGuard.recordSuccess()
            completedSegments.append(url)
            // Wave-4 (3865266536): record the boundary BEFORE saving progress
            // so persisted chunkBoundaries never trail audioSegments.
            chunkBoundaries.append(boundary)
            if let meetingID { updateManifestProgress(meetingID: meetingID) }
            // Advance the chunk window ONLY after the write succeeded
            // (wave-2 3864613558).
            if var acc = chunkAccumulator {
                let nextStart = acc.nextChunkStart(after: boundary)
                acc.beginChunk(at: nextStart)
                chunkAccumulator = acc
                activeWriterStartSample = Int(nextStart * Double(sampleRate))
            }
            return true
        } catch {
            activeWriterNeedsRebuild = true
            try? activeWriter?.synchronizeAndClose()
            activeWriter = nil
            recordStorageWriteFailure()
            // Keep the chunk open and keep every required sample in the ring;
            // the next policy feed rebuilds and retries this same boundary.
            return false
        }
    }

    private func persistActiveChunk(pcm: Data) {
        if activeWriter == nil || activeWriterNeedsRebuild {
            rebuildActiveWriterFromRing(throughSample: capturedSampleCount)
            return
        }
        do {
            try activeWriter?.append(pcm)
            storageFailureGuard.recordSuccess(boundaryPending: pendingBoundary != nil)
        } catch {
            activeWriterNeedsRebuild = true
            try? activeWriter?.synchronizeAndClose()
            activeWriter = nil
            recordStorageWriteFailure()
        }
    }

    private func rebuildActiveWriterFromRing(throughSample endSample: Int) {
        let actualStartSample = max(activeWriterStartSample, ringOriginSample)
        let pcm = slicePCM(startSample: actualStartSample, endSample: endSample)
        guard !pcm.isEmpty, let meetingID else { return }
        let url = segmentURL(meetingID: meetingID, index: completedSegments.count)
        do {
            try? activeWriter?.synchronizeAndClose()
            // Save the start pointer first. A crash after this write but before
            // WAV creation leaves a harmless marker with no file; the reverse
            // order could leave recoverable audio with no timing metadata.
            try persistActiveJournalProgress(
                meetingID: meetingID,
                url: url,
                startSample: actualStartSample
            )
            let writer = try MeetingStreamingWAVWriter(
                url: url,
                sampleRate: sampleRate,
                initialPCM: pcm
            )
            activeWriter = writer
            activeWriterStartSample = actualStartSample
            activeWriterNeedsRebuild = false
            storageFailureGuard.recordSuccess(boundaryPending: pendingBoundary != nil)
        } catch {
            try? activeWriter?.synchronizeAndClose()
            activeWriter = nil
            activeWriterNeedsRebuild = true
            recordStorageWriteFailure()
        }
    }

    private func sealActiveWriter(
        startSample: Int,
        endSample: Int,
        expectedURL: URL
    ) throws {
        let expectedPCMByteCount = (endSample - startSample) * 2
        if activeWriter == nil
            || activeWriterNeedsRebuild
            || activeWriter?.url != expectedURL
            || activeWriterStartSample != startSample {
            let pcm = slicePCM(startSample: startSample, endSample: endSample)
            guard !pcm.isEmpty else { throw MeetingRecorderError.stopWriteFailed }
            guard let meetingID else { throw MeetingRecorderError.stopWriteFailed }
            try? activeWriter?.synchronizeAndClose()
            try persistActiveJournalProgress(
                meetingID: meetingID,
                url: expectedURL,
                startSample: startSample
            )
            activeWriter = try MeetingStreamingWAVWriter(
                url: expectedURL,
                sampleRate: sampleRate,
                initialPCM: pcm
            )
            activeWriterStartSample = startSample
            activeWriterNeedsRebuild = false
        }
        guard let activeWriter else { throw MeetingRecorderError.stopWriteFailed }
        try activeWriter.truncatePCM(toByteCount: expectedPCMByteCount)
        try activeWriter.synchronizeAndClose()
        self.activeWriter = nil
        activeWriterNeedsRebuild = false
    }

    private func discardUnfinalizedActiveWriter() {
        guard let activeWriter else {
            clearActiveJournalProgress()
            return
        }
        let url = activeWriter.url
        try? activeWriter.synchronizeAndClose()
        self.activeWriter = nil
        try? FileManager.default.removeItem(at: url)
        activeWriterNeedsRebuild = false
        clearActiveJournalProgress()
    }

    private func recordStorageWriteFailure() {
        if storageFailureGuard.recordFailure() {
            abortCapture(with: .persistentStorageFailure)
        }
    }

    private func abortCapture(with error: MeetingRecorderError) {
        guard fatalCaptureError == nil else { return }
        fatalCaptureError = error
        try? activeWriter?.synchronizeAndClose()
        activeWriter = nil
        activeWriterNeedsRebuild = false
        if capturesMicrophone { session.stopRunning() }
        isRecording = false
        isStopping = false
        lastMeterLevel = 0

        // Bound memory even when storage remains unavailable. Completed WAVs
        // and any partial active file stay on disk for recovery; the app must
        // not trade a disk failure for an eventual process-wide memory crash.
        if ring.count > ringCapacityBytes {
            let drop = ring.count - ringCapacityBytes
            let alignedDrop = drop - (drop % 2)
            ring.removeSubrange(0..<alignedDrop)
            ringOriginSample += alignedDrop / 2
        }

        _ = retryPersistingFatalCaptureState()
    }

    private func slicePCM(startSample: Int, endSample: Int) -> Data {
        let bytesPerSample = 2
        // Wave-2 (3864613522): convert absolute sample offsets to ring-local
        // offsets using the tracked ring origin.
        let relStart = max(0, startSample - ringOriginSample)
        let relEnd = min(ring.count / bytesPerSample, endSample - ringOriginSample)
        guard relEnd > relStart else { return Data() }
        return ring.subdata(in: relStart * bytesPerSample..<relEnd * bytesPerSample)
    }

    // MARK: - Manifest progress

    private func segmentURL(meetingID: String, index: Int) -> URL {
        guard let source else { return store.audioSegmentURL(for: meetingID, segmentIndex: index) }
        return store.audioDirectory(for: meetingID).appendingPathComponent(source.kind.rawValue)
            .appendingPathComponent("segment_\(String(format: "%04d", index)).wav")
    }

    private func makeResearchProgress() -> [ResearchCaptureSourceProgress] {
        let offset = sourceOffset ?? 0
        let windows: [ResearchAudioWindow]
        if source != nil {
            windows = makeAudioArtifacts().map { ResearchAudioWindow(id: $0.id, start: $0.startOffset, end: $0.endOffset) }
        } else {
            windows = chunkBoundaries.enumerated().map {
                ResearchAudioWindow(id: "room:\($0.offset)", start: $0.element.startOffset, end: $0.element.endOffset)
            }
        }
        let settled = !isRecording && pendingBoundary == nil && fatalCaptureError == nil
            ? lastIngestElapsed
            : max(chunkBoundaries.last?.endOffset ?? 0, chunkAccumulator?.chunkStartOffset ?? 0)
        return [ResearchCaptureSourceProgress(sourceID: source?.sourceID ?? "room",
            capturedThrough: lastIngestElapsed + offset, settledThrough: settled + offset,
            nextBoundary: isRecording ? (chunkAccumulator?.chunkStartOffset ?? 0) + chunkPolicyConfiguration.maxChunkDurationSeconds + offset : nil,
            windows: windows, failed: fatalCaptureError != nil || (!isRecording && pendingBoundary != nil))]
    }

    private func makeAudioArtifacts() -> [MeetingAudioArtifact] {
        guard let source, let meetingID else { return [] }
        return zip(completedSegments, chunkBoundaries).enumerated().map { index, pair in
            let (url, boundary) = pair
            var artifact = MeetingAudioArtifact(id: "\(source.sourceID)-\(index)", sourceID: source.sourceID,
                sourceKind: source.kind, sequence: index,
                relativePath: url.path.replacingOccurrences(of: store.audioDirectory(for: meetingID).path + "/", with: ""),
                startOffset: boundary.startOffset + (sourceOffset ?? 0),
                endOffset: boundary.endOffset + (sourceOffset ?? 0), sampleRate: Double(sampleRate), channelCount: 1)
            artifact.overlapSeconds = boundary.overlapSeconds
            return artifact
        }
    }

    private func updateManifestProgress(meetingID: String) {
        do {
            if let source {
                try store.saveSourceCaptureProgress(meetingID: meetingID, sourceID: source.sourceID,
                    artifacts: makeAudioArtifacts(), journal: nil)
                return
            }
            try store.saveCaptureProgress(
                meetingID: meetingID,
                completedSegmentFilenames: completedSegmentFilenames(meetingID: meetingID),
                chunkBoundaries: chunkBoundaries,
                activeJournal: nil
            )
        } catch {
            // Non-fatal during recording.
        }
    }

    private func persistActiveJournalProgress(
        meetingID: String,
        url: URL,
        startSample: Int
    ) throws {
        if let source {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try store.saveSourceCaptureProgress(meetingID: meetingID, sourceID: source.sourceID,
                artifacts: makeAudioArtifacts(), journal: MeetingActiveJournal(
                    filename: "\(source.kind.rawValue)/\(url.lastPathComponent)", segmentIndex: completedSegments.count,
                    startOffset: Double(startSample) / Double(sampleRate) + (sourceOffset ?? 0)))
            return
        }
        try store.saveCaptureProgress(
            meetingID: meetingID,
            completedSegmentFilenames: completedSegmentFilenames(meetingID: meetingID),
            chunkBoundaries: chunkBoundaries,
            activeJournal: MeetingActiveJournal(
                filename: url.lastPathComponent,
                segmentIndex: completedSegments.count,
                startOffset: Double(startSample) / Double(sampleRate)
            )
        )
    }

    private func clearActiveJournalProgress() {
        guard let meetingID else { return }
        if let source {
            try? store.saveSourceCaptureProgress(meetingID: meetingID, sourceID: source.sourceID,
                artifacts: makeAudioArtifacts(), journal: nil)
            return
        }
        try? store.saveCaptureProgress(
            meetingID: meetingID,
            completedSegmentFilenames: completedSegmentFilenames(meetingID: meetingID),
            chunkBoundaries: chunkBoundaries,
            activeJournal: nil
        )
    }

    private func completedSegmentFilenames(meetingID: String) -> [String] {
        let basePath = store.audioDirectory(for: meetingID).path
        return completedSegments.map { url in
            url.path.replacingOccurrences(of: basePath + "/", with: "")
        }
    }
}


// MARK: - Delegate

extension MeetingCaptureWorker: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        enqueueSampleBuffer(sampleBuffer)
    }

    nonisolated func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // PCM conversion + presentation timestamp capture happen on the
        // CAPTURE thread. The FIFO therefore preserves genuine device-time
        // gaps without measuring main-actor callback delay.
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds = CMTimeGetSeconds(presentation)
        let presentationTime = presentationSeconds.isFinite ? presentationSeconds : nil
        // Wave-6 (3865593002): append
        // to the FIFO (capture order); the main-actor drain appends to the
        // ring in that order, never out of order.
        guard let converted = Self.convertToPCM(sampleBuffer: sampleBuffer) else {
            // Keep the timeline anchor even when conversion rejects a buffer.
            self.pendingIngest.enqueue((Data(), 0, presentationTime))
            scheduleDrain()
            return
        }
        let pcm = converted.pcm
        let rate = converted.sampleRate
        // Wave-7 (3865752976): enqueue ON THE CAPTURE THREAD (the serial
        // capture queue preserves order) BEFORE scheduling the drain — the
        // queue is therefore populated in true capture order regardless of
        // main-actor task scheduling.
        self.pendingIngest.enqueue((pcm, rate, presentationTime))
        scheduleDrain()
    }
}

// MARK: - Errors

enum MeetingRecorderError: LocalizedError {
    case onlineCaptureFailed(String)
    case alreadyRecording
    case noInputDevice
    case inputUnavailable(String)
    case outputUnavailable
    case unsupportedFileType
    /// Wave-4 (3865266533): the final chunk could not be written at Stop.
    case stopWriteFailed
    case persistentStorageFailure
    case captureDiscontinuity(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .onlineCaptureFailed(let message): return message
        case .alreadyRecording:
            return "A meeting recording is already in progress."
        case .noInputDevice:
            return "No microphone input was found for meeting recording."
        case .inputUnavailable(let deviceName):
            return "\(deviceName) could not be used for meeting recording."
        case .outputUnavailable:
            return "Could not prepare audio capture for meeting recording."
        case .unsupportedFileType:
            return "This Mac cannot record WAV audio for meeting capture."
        case .stopWriteFailed:
            return "The final audio segment could not be saved — recording was not finalized."
        case .persistentStorageFailure:
            return "Recording stopped because Openbridge could not keep saving audio. Preserved segments remain available for recovery."
        case .captureDiscontinuity(let seconds):
            return "Recording stopped after the microphone stream was interrupted for \(String(format: "%.1f", seconds)) seconds. Preserved audio remains available for recovery."
        }
    }
}
