import Foundation
import Testing
@testable import OpenBridgeApp

struct MeetingResearchProgressTests {
    @Test func silentGapDoesNotPullInALaterUnprocessedWindow() {
        let source = ResearchCaptureSourceProgress(sourceID: "room", capturedThrough: 60,
            settledThrough: 60, nextBoundary: 90, windows: [.init(id: "later", start: 30, end: 60)])
        let progress = MeetingResearchProgress(meetingID: "one", sources: [source], transcription: .init())
        #expect(progress.readiness(through: 20) == .ready(through: 20, windowIDs: []))
    }
    @MainActor @Test func realCaptureWorkerPublishesSharedClockReceiptsAndStopTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typed-capture-\(UUID().uuidString)")
        let store = MeetingSessionStore(rootDirectory: root, meetingDeletionObserver: { _ in })
        defer { try? store.deleteAll() }
        let source = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "synthetic")
        let manifest = MeetingManifest(title: "Progress only", state: .recording, sources: [source])
        try store.create(manifest)
        let recorder = MeetingRecorder(store: store, capturesMicrophone: false, source: source)
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil,
            segmentDurationSeconds: 30, commonClockOrigin: 100)
        await recorder.ingestTestPCM(Data(repeating: 32, count: 32_000), sampleRate: 16_000, presentationTime: 102)
        let active = try #require(recorder.researchCaptureProgress.first)
        #expect(active.capturedThrough == 3)
        #expect(active.nextBoundary == 32)
        _ = try await recorder.stopRecording()
        let stopped = try #require(recorder.researchCaptureProgress.first)
        #expect(stopped.settledThrough == 3)
        #expect(stopped.windows.first?.id == recorder.audioArtifacts.first?.id)
        #expect(stopped.windows.first?.end == recorder.audioArtifacts.first?.endOffset)
        #expect(stopped.nextBoundary == nil)
    }
    private func source(_ id: String, captured: Double = 30, settled: Double = 30) -> ResearchCaptureSourceProgress {
        .init(sourceID: id, capturedThrough: captured, settledThrough: settled,
              nextBoundary: 58.5, windows: [.init(id: id, start: 0, end: 30)])
    }
    @Test func bothSourcesMustBeProcessed() {
        let progress = MeetingResearchProgress(meetingID: "one", sources: [source("mic"), source("system")],
            transcription: .init(completed: ["mic"]))
        #expect(progress.readiness(through: 25) == .transcribing)
    }
    @Test func failedSourceCannotLookReady() {
        let progress = MeetingResearchProgress(meetingID: "one", sources: [source("mic"), source("system")],
            transcription: .init(completed: ["mic"], failed: ["system"]))
        #expect(progress.readiness(through: 25) == .failed)
    }
    @Test func overlappingFutureWindowDoesNotExtendWait() {
        var mic = source("mic")
        mic = .init(sourceID: "mic", capturedThrough: 60, settledThrough: 58.5, nextBoundary: 87,
                    windows: mic.windows + [.init(id: "later", start: 28.5, end: 58.5)])
        let progress = MeetingResearchProgress(meetingID: "one", sources: [mic], transcription: .init(completed: ["mic"]))
        #expect(progress.readiness(through: 29) == .ready(through: 30, windowIDs: ["mic"]))
    }
    @Test func silenceCountsOnlyAfterCaptureSettlesIt() {
        let silent = ResearchCaptureSourceProgress(sourceID: "system", capturedThrough: 60,
            settledThrough: 60, nextBoundary: 90, windows: [])
        let progress = MeetingResearchProgress(meetingID: "one", sources: [silent], transcription: .init())
        #expect(progress.readiness(through: 50) == .ready(through: 50, windowIDs: []))
    }
    @Test func unprocessedOlderWindowIsNotSkipped() {
        let mic = ResearchCaptureSourceProgress(sourceID: "mic", capturedThrough: 60, settledThrough: 58.5,
            nextBoundary: 87, windows: [.init(id: "first", start: 0, end: 30), .init(id: "second", start: 28.5, end: 58.5)])
        let progress = MeetingResearchProgress(meetingID: "one", sources: [mic], transcription: .init(completed: ["second"]))
        #expect(progress.readiness(through: 45) == .transcribing)
    }
    @Test func countdownUsesActualWindowClockAndSlowSource() {
        let source = ResearchCaptureSourceProgress(sourceID: "mic", capturedThrough: 19,
            settledThrough: 0, nextBoundary: 30, windows: [])
        let progress = MeetingResearchProgress(meetingID: "one", sources: [source], transcription: .init())
        #expect(progress.readiness(through: 19) == .waiting(seconds: 11))
    }
}
