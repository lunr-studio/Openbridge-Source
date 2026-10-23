import Foundation
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

struct CurrentMeetingQuestionTests {
    @Test func contextIsCurrentMeetingOnlyBoundedAndIncludesRecentPassages() {
        var segments = (0..<12).map { i in MeetingTranscriptSegment(id: "s\(i)", meetingID: "current", sequence: i,
            startOffset: Double(i * 30), text: String(repeating: i == 0 ? "Cedar budget. " : "Other discussion. ", count: 800)) }
        segments.append(.init(id: "private", meetingID: "another", sequence: 0, text: "Cedar private budget"))
        let result = CurrentMeetingContextRetriever.select(meetingID: "current", segments: segments, question: "What is the Cedar budget?")
        #expect(result.passages.count == 6)
        #expect(result.passages.reduce(0) { $0 + $1.text.count } <= 12_000)
        #expect(result.isPartial)
        #expect(result.passages.contains { $0.segmentID == "s0" })
        #expect(result.passages.contains { $0.segmentID == "s11" })
        #expect(!result.passages.contains { $0.segmentID == "private" })
    }
    private func request() -> CurrentMeetingQuestionRequest {
        .init(context: .init(requestID: "question", meetingID: "current", mode: .cloudExperiment),
            question: "What codename?", previousQuestion: nil,
            passages: [.init(segmentID: "segment", text: "We chose Cedar.", sourceLabel: "Room", start: 10)],
            contextIsPartial: false, coveredThrough: 30)
    }
    @Test func citationsAreReconstructedLocallyAndExplanationIsSeparate() throws {
        let raw = #"{"meetingClaims":[{"text":"Cedar was chosen.","sentenceIDs":["p0s0"]}],"explanation":"A codename is a project label.","limitation":null}"#
        let value = try CurrentMeetingAnswerCodec.decode(raw, request: request())
        #expect(value.claims.first?.citations.first?.segmentID == "segment")
        #expect(value.claims.first?.citations.first?.quote == "We chose Cedar.")
        #expect(value.explanation == "A codename is a project label.")
        #expect(value.requestID == "question")
    }
    @Test func missingInventedAndMalformedCitationsAreRejected() {
        for raw in [#"{"meetingClaims":[{"text":"Cedar","sentenceIDs":[] }]}"#,
                    #"{"meetingClaims":[{"text":"Cedar","sentenceIDs":["another-meeting"]}]}"#,
                    #"{"meetingClaims":"wrong-type"}"#, "not JSON"] {
            #expect(throws: (any Error).self) { try CurrentMeetingAnswerCodec.decode(raw, request: request()) }
        }
    }
    @Test func noEvidenceDoesNotBecomeModelMeetingFact() throws {
        let value = try CurrentMeetingAnswerCodec.decode(#"{"meetingClaims":[],"explanation":"General explanation"}"#, request: request())
        #expect(value.claims.isEmpty)
        #expect(value.limitation != nil)
    }
    @Test func cloudContextKeepsSourceLabelsAndLocalPassageTime() throws {
        let prompt = try CurrentMeetingAnswerCodec.userPrompt(request())
        let object = try #require(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        let lines = try #require(object["transcriptSentences"] as? [[String: Any]])
        #expect(lines.first?["sourceLabel"] as? String == "Room")
        #expect(lines.first?["passageStartSeconds"] as? Double == 10)
    }
    @MainActor @Test func typedSnapshotSurvivesUpdatesAndActionsStayExplicit() {
        let answered = MeetingQuestionCard(id: "one", question: "What?", phase: .answered, answer: "Cedar", explanation: "General knowledge")
        let waiting = MeetingQuestionCard(id: "two", question: "Why?", phase: .waiting, countdown: 9)
        let vm = ResearchRailViewModel()
        vm.updateSnapshot(.init(state: .quiet, cards: [], activeQuestion: nil, meetingQuestions: [answered], meetingTitle: "Test"))
        vm.updateSnapshot(.init(state: .searching, cards: [], activeQuestion: nil, meetingQuestions: [waiting, answered], meetingTitle: "Test"))
        #expect(vm.snapshot.meetingQuestions == [waiting, answered])
        var requests: [String] = []; vm.onSubmitQuestion = { requests.append($0) }
        #expect(requests.isEmpty)
        vm.composerText = "typed"; vm.submitQuestion()
        #expect(requests == ["typed"])
        vm.composerText = String(repeating: "x", count: 2_001); vm.submitQuestion()
        #expect(requests.count == 1)
    }
    @Test func productionTranscriptTapHasNoSpokenSubmission() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("Sources/OpenBridgeApp/MeetingTranscriber.swift"), encoding: .utf8)
        #expect(!source.contains("ObservatorySpokenIntake.shared.ingest"))
    }
}
