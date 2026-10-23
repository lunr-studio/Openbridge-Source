import Foundation
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

/// Cross-component proof using real PCM persistence and transcription scheduling.
/// The microphone, speech model and web transport are deliberately synthetic;
/// this does not exercise MainWindowView's Stop action or replace native QA.
@Suite(.serialized) @MainActor
struct MeetingResearchRecordingIsolationTests {
    @Test(arguments: [URLError.timedOut, .notConnectedToInternet])
    func failedResearchPreservesCaptureAndFinalTranscript(_ error: URLError.Code) async throws {
        try await exercise(failure: error, cancel: false)
    }

    @Test(arguments: [true, false])
    func cancelledResearchCannotCancelLocalInferenceOrReviveAfterStop(beforeStop: Bool) async throws {
        try await exercise(failure: nil, cancel: true, cancelBeforeStop: beforeStop)
    }

    @Test func stopFinishesBeforePendingResearchTransportReturns() async throws {
        try await exercise(failure: nil, cancel: false)
    }

    private func exercise(failure: URLError.Code?, cancel: Bool, cancelBeforeStop: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-capture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root, meetingDeletionObserver: { _ in })
        let configuration = try MeetingIntelligenceConfigurationResolver.snapshot(cleanupEnabled: false,
            aiMode: .cloudOptIn, providerSettings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            hasCredential: true, providerWasTested: true)
        let manifest = MeetingManifest(title: "Synthetic research isolation", state: .recording,
            aiMode: .cloudOptIn, privacySettings: .init(allowsLocalIntelligence: true, allowsCloudIntelligence: true),
            intelligenceConfiguration: configuration)
        try store.create(manifest)
        let recorder = MeetingRecorder(store: store, capturesMicrophone: false)
        let engine = IsolationSpeechEngine()
        let transcriber = MeetingTranscriber(store: store, modelIdentifier: "synthetic-engine",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"), engine: engine)
        let web = IsolationWebTransport()
        let brave = BraveResearchSettings(store: InMemoryProviderCredentialStore(), transport: { try await web.send($0) })
        brave.save("synthetic-test-key")
        let research = MeetingResearchController(store: store) { request in
            _ = try await brave.research(.init(requestID: request.context.requestID,
                questionText: request.approvedWebQuery ?? "", webAuthority: true))
            await web.recordSynthesis()
            return .init(requestID: request.context.requestID, claims: [], explanation: nil, limitation: nil)
        }
        // Always release parked doubles and stop synthetic capture, including
        // assertion/IO failures. Never leave a continuation hanging in CI.
        do {
            try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil, segmentDurationSeconds: 2)
            transcriber.start(meetingID: manifest.meetingID)
            research.selectMeeting(manifest)
            let headPCM = Data(repeating: 32, count: 16_000 * 2 * 2)
            await recorder.ingestTestPCM(headPCM, sampleRate: 16_000, presentationTime: 100)
            #expect(recorder.completedSegmentCount == 1)
            transcriber.checkForNewSegments(recorder: recorder)
            try await eventually { transcriber.researchTranscriptionProgress.completed.count == 1 }
            research.updateProgress(.init(meetingID: manifest.meetingID, sources: recorder.researchCaptureProgress,
                transcription: transcriber.researchTranscriptionProgress))
            research.submit("What does the public source say?", id: "web-question", approvedWebQuery: "public synthetic query")
            try await eventually { await web.requestCount == 1 }
            #expect(research.snapshot.meetingQuestions?.first?.phase == .answering)
            let before = try store.load(meetingID: manifest.meetingID)
            #expect(before.segments.count == 1)
            let firstAudio = try #require(recorder.completedSegments.first)
            let originalWAV = try Data(contentsOf: firstAudio)
            #expect(originalWAV.suffix(headPCM.count) == headPCM)

            if let failure {
                await web.finish(error: failure)
                try await eventually { research.snapshot.meetingQuestions?.first?.phase == .failed }
            }
            if cancelBeforeStop {
                research.cancel("web-question")
                #expect(research.snapshot.meetingQuestions?.first?.phase == .cancelled)
            }
            // Capture keeps accepting PCM after a failed request (or while a
            // request is held). A short last chunk must survive Stop.
            #expect(recorder.isRecording)
            let tailPCM = Data(repeating: 64, count: 16_000)
            await recorder.ingestTestPCM(tailPCM, sampleRate: 16_000, presentationTime: 102)
            #expect(recorder.isRecording)
            #expect(recorder.fatalCaptureError == nil)
            transcriber.stopLiveTaps() // Same ordering as the production Stop path.
            let files = try await recorder.stopRecording()
            #expect(files.count == 2)
            #expect(!recorder.isRecording)
            let tail = try Data(contentsOf: #require(files.last))
            #expect(tail.suffix(tailPCM.count) == tailPCM)
            #expect(recorder.chunkBoundaries.last?.endOffset == 2.5)

            var finalizationResult: MeetingFinalizationResult?
            let finalization = Task {
                finalizationResult = await transcriber.finalizeAndTranscribe(recorder: recorder, meetingID: manifest.meetingID)
            }
            try await eventually { await engine.tailIsWaiting }
            if cancel && !cancelBeforeStop {
                // Deliberately cancel while local inference is suspended.
                research.cancel("web-question")
                #expect(research.snapshot.meetingQuestions?.first?.phase == .cancelled)
            }
            if failure == nil {
                #expect(await web.isWaiting)
            }
            await engine.releaseTail()
            // Completion must be possible BEFORE the web transport is released.
            try await eventually { finalizationResult != nil }
            await finalization.value
            let result = try #require(finalizationResult)
            #expect(transcriber.researchTranscriptionProgress.completed.count == 2)
            guard case .completed(let count) = result else {
                Issue.record("Local finalization failed while research was independent")
                throw IsolationFailure.didNotSettle
            }
            #expect(count == 2)
            let saved = try store.load(meetingID: manifest.meetingID)
            #expect(saved.segments.map(\.text) == [IsolationSpeechEngine.head, IsolationSpeechEngine.tail])
            #expect(saved.transcriptSpans.count == 2)
            #expect(await engine.calls == files)
            #expect(await engine.sawCancellation == false)
            #expect(try Data(contentsOf: firstAudio) == originalWAV)
            #expect(try Data(contentsOf: files[1]) == tail)
            #expect(saved.segments.first == before.segments.first)
            if failure == nil {
                #expect(await web.isWaiting)
                // A cancelled transport deliberately ignores cancellation and
                // returns valid sources late. They must not reach synthesis.
                await web.finish(error: cancel ? nil : .timedOut)
            }
            let phase: MeetingQuestionPhase = cancel ? .cancelled : .failed
            try await eventually {
                let webIsWaiting = await web.isWaiting
                return research.snapshot.meetingQuestions?.first?.phase == phase && !webIsWaiting
            }
            try await eventually { await web.returned }
            // A follow-up queued behind the old serial slot proves the late
            // transport has fully unwound; do not rely on a fixed sleep.
            research.submit("Second deliberate query", id: "follow-up", approvedWebQuery: "second synthetic query")
            research.updateProgress(.init(meetingID: manifest.meetingID, sources: recorder.researchCaptureProgress,
                transcription: transcriber.researchTranscriptionProgress, isRecording: false))
            try await eventually { await web.requestCount == 2 }
            await web.finish(error: .timedOut)
            try await eventually { research.snapshot.meetingQuestions?.last?.phase == .failed }
            #expect(research.snapshot.meetingQuestions?.first?.phase == phase)
            #expect(await web.synthesisCount == 0)
            await research.flushConversationSaves()
            let conversation = try MeetingConversationStore(store: store).load(manifest.meetingID)
            #expect(conversation.questions.map(\.phase) == [phase.rawValue, "failed"])
            #expect(conversation.questions.allSatisfy { $0.response == nil })
            #expect(try store.load(meetingID: manifest.meetingID).segments == saved.segments)
            #expect(try Data(contentsOf: firstAudio) == originalWAV)
            #expect(try Data(contentsOf: files[1]) == tail)
            research.setEnabled(false)
        } catch {
            research.setEnabled(false)
            await web.finish(error: .cancelled)
            await engine.releaseTail()
            await recorder.cancelRecording()
            transcriber.cancelLiveWorkAfterCaptureFailure()
            throw error
        }
    }

    private func eventually(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw IsolationFailure.didNotSettle
    }
}

private enum IsolationFailure: Error { case didNotSettle }

private actor IsolationSpeechEngine: MeetingEngine {
    static let head = "Cedar is the selected codename."
    static let tail = "Final budget approval remains pending."
    var calls: [URL] = []
    var sawCancellation = false
    var tailIsWaiting: Bool { tailContinuation != nil }
    private var tailContinuation: CheckedContinuation<Void, Never>?
    private var tailReleased = false
    func releaseTail() { tailReleased = true; tailContinuation?.resume(); tailContinuation = nil }
    func transcribe(audioURL: URL, modelIdentifier: String, formattingEnabled: Bool,
                    vocabularyCorrectionsEnabled: Bool, customDictionaryURL: URL,
                    cleanupMode: TranscriptionCleanupMode) async throws -> TranscriptPayload {
        calls.append(audioURL)
        #expect(cleanupMode == .off)
        let isTail = audioURL.lastPathComponent == "segment_0001.wav"
        if isTail && !tailReleased { await withCheckedContinuation { tailContinuation = $0 } }
        sawCancellation = sawCancellation || Task.isCancelled
        return TranscriptPayload(text: isTail ? Self.tail : Self.head)
    }
}

private actor IsolationWebTransport {
    var requestCount = 0
    var synthesisCount = 0
    var returned = false
    var isWaiting: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, any Error>?
    func recordSynthesis() { synthesisCount += 1 }
    func finish(error: URLError.Code?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: URLError(error)) }
        else { continuation.resume() }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        defer { returned = true }
        try await withCheckedThrowingContinuation { continuation = $0 }
        let data = Data(#"{"grounding":{"generic":[{"url":"https://example.com/docs","title":"Synthetic source","snippets":["Public synthetic evidence."]}]}}"#.utf8)
        return (data, HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
