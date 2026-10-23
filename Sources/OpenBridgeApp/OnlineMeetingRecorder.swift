import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
protocol MeetingRecording: MeetingSegmentSource {
    var isRecording: Bool { get }
    var lastMeterLevel: Double { get }
    var systemMeterLevel: Double { get }
    var systemAudioHealth: MeetingAudioHealth? { get }
    var microphoneAudioHealth: MeetingAudioHealth? { get }
    var completedSegments: [URL] { get }
    var fatalCaptureError: MeetingRecorderError? { get }
    var failureStatePersistenceError: String? { get }
    var researchCaptureProgress: [ResearchCaptureSourceProgress] { get }
    func startRecording(meetingID: String, deviceID: String?, segmentDurationSeconds: TimeInterval,
                        commonClockOrigin: TimeInterval?) async throws
    func stopRecording() async throws -> [URL]
    func cancelRecording() async
    func retryPersistingFatalCaptureState() async -> String?
}

extension MeetingRecording {
    var systemMeterLevel: Double { 0 }
    var systemAudioHealth: MeetingAudioHealth? { nil }
    var microphoneAudioHealth: MeetingAudioHealth? { nil }
    var researchCaptureProgress: [ResearchCaptureSourceProgress] { [] }
    func startRecording(meetingID: String, deviceID: String?) async throws {
        try await startRecording(meetingID: meetingID, deviceID: deviceID,
            segmentDurationSeconds: MeetingChunkPolicyConfiguration.live.maxChunkDurationSeconds,
            commonClockOrigin: nil)
    }
}
extension MeetingRecorder: MeetingRecording {}

@available(macOS 15.0, *)
@MainActor
protocol OnlineMeetingStreamDriver: AnyObject {
    var failure: String? { get }
    var lastSystemSampleAt: Date? { get }
    func startCapture() async throws
    func stopCapture() async throws
    func drain() async
}

@available(macOS 15.0, *)
extension OnlineMeetingStreamDriver { var lastSystemSampleAt: Date? { nil } }

/// ScreenCaptureKit only supplies samples. The existing recorder owns each
/// track's FIFO, streaming journal, bounded ring, chunk overlap and Stop drain.
@available(macOS 15.0, *)
@MainActor
final class OnlineMeetingRecorder: MeetingRecording {
    let captureMode: MeetingCaptureMode = .online
    private let store: MeetingSessionStore
    private let microphoneSource: MeetingSourceMetadata
    private let systemSource: MeetingSourceMetadata
    private let microphone: MeetingRecorder
    private let systemAudio: MeetingRecorder
    private var driver: (any OnlineMeetingStreamDriver)?
    // Preserve the driver's actor isolation in the closure type, including
    // across suspension. A MainActor owner alone does not isolate this closure.
    private let makeDriver: @MainActor (MeetingRecorder, MeetingRecorder, String?) async throws -> any OnlineMeetingStreamDriver
    private var meetingID: String?
    private var stopTask: Task<[URL], Error>?
    private var streamError: MeetingRecorderError?
    private let hasSystemAudioPermission: () -> Bool
    private var isStarting = false
    private var captureGeneration = UUID()
    private let includesMicrophone: Bool
    private(set) var isRecording = false

    var lastMeterLevel: Double { microphone.lastMeterLevel }
    var systemMeterLevel: Double { systemAudio.lastMeterLevel }
    var systemAudioHealth: MeetingAudioHealth? {
        fatalCaptureError != nil ? .interrupted : systemAudio.capturedAudioHealth
    }
    var microphoneAudioHealth: MeetingAudioHealth? { includesMicrophone ? microphone.capturedAudioHealth : nil }
    var researchCaptureProgress: [ResearchCaptureSourceProgress] {
        ((includesMicrophone ? microphone.researchCaptureProgress : []) + systemAudio.researchCaptureProgress).map { source in
            var value = source
            value.failed = value.failed || fatalCaptureError != nil
            return value
        }
    }
    var chunkBoundaries: [MeetingChunkBoundary] { [] }
    var audioArtifacts: [MeetingAudioArtifact] {
        ((includesMicrophone ? microphone.audioArtifacts : []) + systemAudio.audioArtifacts).sorted {
            if $0.startOffset != $1.startOffset { return $0.startOffset < $1.startOffset }
            return $0.id < $1.id
        }
    }
    var completedSegments: [URL] {
        guard let meetingID else { return [] }
        return audioArtifacts.map { store.audioDirectory(for: meetingID).appendingPathComponent($0.relativePath) }
    }
    var completedSegmentCount: Int { audioArtifacts.count }
    var fatalCaptureError: MeetingRecorderError? {
        if let message = driver?.failure { return .onlineCaptureFailed(message) }
        return streamError ?? microphone.fatalCaptureError ?? systemAudio.fatalCaptureError
    }
    var failureStatePersistenceError: String? {
        microphone.failureStatePersistenceError ?? systemAudio.failureStatePersistenceError
    }

    init(store: MeetingSessionStore, microphoneSource: MeetingSourceMetadata, systemSource: MeetingSourceMetadata,
         includesMicrophone: Bool = true,
         hasSystemAudioPermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         makeDriver: (@MainActor (MeetingRecorder, MeetingRecorder, String?) async throws -> any OnlineMeetingStreamDriver)? = nil) {
        self.includesMicrophone = includesMicrophone
        self.makeDriver = makeDriver ?? { mic, system, device in
            try await ScreenCaptureMeetingDriver.make(microphone: mic, systemAudio: system,
                deviceID: device, includesMicrophone: includesMicrophone)
        }
        self.hasSystemAudioPermission = hasSystemAudioPermission
        self.store = store
        self.microphoneSource = microphoneSource
        self.systemSource = systemSource
        self.microphone = MeetingRecorder(store: store, capturesMicrophone: false, source: microphoneSource)
        self.systemAudio = MeetingRecorder(store: store, capturesMicrophone: false, source: systemSource)
    }

    func startRecording(meetingID: String, deviceID: String?, segmentDurationSeconds: TimeInterval = 30,
                        commonClockOrigin: TimeInterval? = nil) async throws {
        guard !isRecording, !isStarting, driver == nil, stopTask == nil else { throw MeetingRecorderError.alreadyRecording }
        guard hasSystemAudioPermission() else {
            throw MeetingRecorderError.onlineCaptureFailed("System audio permission is required. Open Settings, grant access, then check again. You may need to restart OpenBridge.")
        }
        isStarting = true
        defer { isStarting = false }
        streamError = nil
        let token = UUID()
        captureGeneration = token
        let prepared = try await makeDriver(microphone, systemAudio, deviceID)
        guard captureGeneration == token, !Task.isCancelled else { throw CancellationError() }
        self.meetingID = meetingID
        let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        do {
            if includesMicrophone {
                try await microphone.startRecording(meetingID: meetingID, deviceID: nil,
                    segmentDurationSeconds: segmentDurationSeconds, commonClockOrigin: origin)
            }
            guard captureGeneration == token, !Task.isCancelled else { throw CancellationError() }
            try await systemAudio.startRecording(meetingID: meetingID, deviceID: nil,
                segmentDurationSeconds: segmentDurationSeconds, commonClockOrigin: origin)
            guard captureGeneration == token, !Task.isCancelled else { throw CancellationError() }
            driver = prepared
            try await prepared.startCapture()
            guard captureGeneration == token, !Task.isCancelled else {
                // Cancel may have stopped/released our property while Start was
                // still pending. Stop the retained handle again after a late
                // successful Start, so it cannot outlive its cancelled meeting.
                try? await prepared.stopCapture()
                await prepared.drain()
                throw CancellationError()
            }
            isRecording = true
        } catch {
            await cancelRecording()
            throw error
        }
    }

    func stopRecording() async throws -> [URL] {
        if let stopTask { return try await stopTask.value }
        captureGeneration = UUID()
        let task = Task { @MainActor [self] in
            var failure: Error?
            if let driver {
                do { try await driver.stopCapture() } catch { failure = error }
                await driver.drain()
                if let message = driver.failure, failure == nil { failure = MeetingRecorderError.onlineCaptureFailed(message) }
            }
            // Both sources get a chance to seal even if the first fails.
            do { _ = try await microphone.stopRecording() } catch { failure = error }
            do { _ = try await systemAudio.stopRecording() } catch { failure = error }
            driver = nil
            isRecording = false
            if let failure {
                streamError = .onlineCaptureFailed("Online capture could not finish: \(failure.localizedDescription). Audio is preserved for recovery.")
                _ = await retryPersistingFatalCaptureState()
                throw streamError!
            }
            if let fatalCaptureError { throw fatalCaptureError }
            return completedSegments
        }
        stopTask = task
        defer { stopTask = nil }
        return try await task.value
    }

    func cancelRecording() async {
        _ = try? await stopRecording()
        await microphone.cancelRecording()
        await systemAudio.cancelRecording()
    }

    func retryPersistingFatalCaptureState() async -> String? {
        guard let meetingID, let error = fatalCaptureError else { return nil }
        do { try store.markMeetingAsFailed(meetingID: meetingID, reason: error.localizedDescription); return nil }
        catch { return error.localizedDescription }
    }
}

/// The adapter owns platform outputs; lifecycle orchestration can be tested
/// with a deterministic driver without pretending a fixture captured Mac audio.
@available(macOS 15.0, *)
@MainActor
final class ScreenCaptureMeetingDriver: OnlineMeetingStreamDriver {
    private let stream: SCStream
    private let output: OnlineMeetingOutput
    private let includesMicrophone: Bool
    var failure: String? { output.failure }
    var lastSystemSampleAt: Date? { output.lastSystemSampleAt }

    private init(stream: SCStream, output: OnlineMeetingOutput, includesMicrophone: Bool) {
        self.stream = stream; self.output = output; self.includesMicrophone = includesMicrophone
    }

    static func make(microphone: MeetingRecorder, systemAudio: MeetingRecorder, deviceID: String?, includesMicrophone: Bool = true) async throws -> ScreenCaptureMeetingDriver {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MeetingRecorderError.onlineCaptureFailed("No display is available for system audio capture.")
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = includesMicrophone
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        if includesMicrophone {
            config.microphoneCaptureDeviceID = deviceID == MicrophoneDevice.systemDefaultID || deviceID == nil
                ? AVCaptureDevice.default(for: .audio)?.uniqueID : deviceID
        }
        let sink = OnlineMeetingOutput(microphone: microphone, systemAudio: systemAudio)
        let capture = SCStream(filter: filter, configuration: config, delegate: sink)
        return ScreenCaptureMeetingDriver(stream: capture, output: sink, includesMicrophone: includesMicrophone)
    }

    func startCapture() async throws {
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        if includesMicrophone { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue) }
        // No screen output is registered and no video frames are persisted.
        try await stream.startCapture()
    }

    func stopCapture() async throws {
        defer {
            try? stream.removeStreamOutput(output, type: .audio)
            try? stream.removeStreamOutput(output, type: .microphone)
        }
        try await stream.stopCapture()
    }

    func drain() async { await output.drain() }
}

@available(macOS 15.0, *)
private final class OnlineMeetingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "openbridge.online.samples", qos: .userInitiated)
    private let microphone: MeetingRecorder
    private let systemAudio: MeetingRecorder
    private let lock = NSLock()
    private var errorMessage: String?
    private var systemSampleAt: Date?
    var lastSystemSampleAt: Date? { lock.withLock { systemSampleAt } }
    var failure: String? { lock.withLock { errorMessage } }

    init(microphone: MeetingRecorder, systemAudio: MeetingRecorder) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, CMSampleBufferDataIsReady(buffer) else { return }
        switch type {
        case .microphone: microphone.enqueueSampleBuffer(buffer)
        case .audio:
            lock.withLock { systemSampleAt = Date() }
            systemAudio.enqueueSampleBuffer(buffer)
        default: break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { errorMessage = "System audio capture stopped: \(error.localizedDescription)" }
    }
    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
