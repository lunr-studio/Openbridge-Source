import Foundation
import Testing
@testable import OpenBridgeApp

@Suite struct MediaTranscriptVariantTests {
    @Test func mediaPayloadRetainsOriginalAlongsideProcessedText() throws {
        let json = #"{"ok":true,"transcript":{"text":"Hello, OpenBridge.","originalText":"hello open bridge","modelLabel":"Local model"},"media":{"sourceName":"Interview.mov","sourcePath":"/tmp/fictional.mov"}}"#
        let response = try JSONDecoder().decode(EngineMediaTranscriptResponse.self, from: Data(json.utf8))
        let result = MediaTranscriptionResult(
            sourceName: response.media.sourceName,
            transcript: response.transcript.text,
            originalText: response.transcript.originalText,
            modelLabel: response.transcript.modelLabel
        )
        #expect(result.hasOriginalTranscript)
        #expect(result.hasCleanedTranscript)
        #expect(result.text(for: .original) == "hello open bridge")
        #expect(result.text(for: .cleaned) == "Hello, OpenBridge.")
        // Legacy copy/paste consumers continue receiving the processed text.
        #expect(result.transcript == "Hello, OpenBridge.")
    }

    @Test func legacyPayloadDoesNotInventAnOriginal() throws {
        let json = #"{"text":"Previously processed words","lowConfidenceSegments":[]}"#
        let payload = try JSONDecoder().decode(TranscriptPayload.self, from: Data(json.utf8))
        #expect(payload.originalText == nil)
        let result = MediaTranscriptionResult(sourceName: "Legacy recording", transcript: payload.text, modelLabel: "")
        #expect(!result.hasOriginalTranscript)
        #expect(!result.hasCleanedTranscript)
        #expect(result.text(for: .original) == payload.text)
        #expect(result.text(for: .cleaned) == payload.text)
    }

    @Test func unchangedTranscriptDoesNotAdvertiseASecondVersion() {
        let result = MediaTranscriptionResult(sourceName: "Recording", transcript: "Hello.", originalText: "Hello.", modelLabel: "")
        #expect(result.hasOriginalTranscript)
        #expect(!result.hasCleanedTranscript)
        #expect(result.text(for: .original) == "Hello.")
    }
}
