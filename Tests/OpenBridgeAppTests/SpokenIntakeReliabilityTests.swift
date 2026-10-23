import Foundation
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

@Suite(.serialized) @MainActor struct SpokenIntakeReliabilityTests {
    private func coordinator(_ recorder: FakeProviderRecorder, delay: TimeInterval = 0) -> ObservatoryCoordinator {
        var fake = FakeResearchProvider(recorder: recorder)
        fake.configuration.modelKnowledgeAnswers = true
        fake.configuration.delay = delay
        let config = ProviderSettings().configuration
        return ObservatoryCoordinator(answerService: GroundedAnswerService(provider: fake,
            cloudModelKnowledgeAuthorization: { _ in config }), providerMode: .cloudExperiment)
    }

    private func span(_ id: String, _ sequence: Int, _ text: String, meeting: String = "synthetic") -> MeetingTranscriptSegment {
        .init(id: id, meetingID: meeting, sequence: sequence, sourceLabel: "Synthetic", text: text, isFinal: true)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func productionIntakePublishesWaitingThenOneAnswerAndAllowsANewUtterance() async {
        let calls = FakeProviderRecorder()
        let coordinator = coordinator(calls)
        let intake = ObservatorySpokenIntake(coordinator: { coordinator }, isEnabled: { true })
        await intake.ingest(span("a", 0, "So OpenBridge, can you tell me um uh you"))
        #expect(coordinator.spokenStatus.pendingQuestion == "can you tell me")
        #expect(calls.callCount == 0)
        let next = span("b", 1, "uh you know what the largest country is?")
        await intake.ingest(next)
        await waitUntil { coordinator.completedAnswers.count == 1 }
        #expect(calls.callCount == 1)
        #expect(coordinator.completedAnswers.first?.questionText == "can you tell me what the largest country is?")
        #expect(coordinator.spokenStatus.pendingQuestion == nil)
        await intake.ingest(next)
        #expect(calls.callCount == 1)
        await intake.ingest(span("c", 2, "Okay OpenBridge, can you tell me what the largest country is?"))
        await waitUntil { coordinator.completedAnswers.count == 2 }
        #expect(calls.callCount == 2)
        intake.reset()
        coordinator.endOfMeeting()
    }

    @Test func timerPublishesRepeatWithoutCloudAndResetCancelsItsGeneration() async {
        let calls = FakeProviderRecorder()
        let coordinator = coordinator(calls)
        var date = Date(timeIntervalSince1970: 1000)
        let intake = ObservatorySpokenIntake(coordinator: { coordinator }, isEnabled: { true }, now: { date }, sleep: { delay in
            #expect(delay == 60)
            try await Task.sleep(for: .milliseconds(20))
            date = date.addingTimeInterval(60)
        })
        await intake.ingest(span("a", 0, "Um OpenBridge, tell me"))
        await waitUntil { coordinator.spokenStatus.needsRepeat }
        #expect(coordinator.spokenStatus.needsRepeat)
        #expect(coordinator.spokenStatus.pendingQuestion == nil)
        #expect(calls.callCount == 0)
        await intake.ingest(span("b", 1, "what the largest country is?"))
        #expect(calls.callCount == 0)
        await intake.ingest(span("c", 2, "OpenBridge, can you"))
        intake.reset()
        coordinator.cancelCurrentRequest()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.spokenStatus == .init())
        await intake.ingest(span("d", 3, "tell me what the largest country is?"))
        #expect(calls.callCount == 0)
    }

    @Test func disabledCancelledAndDifferentMeetingCannotCompletePending() async {
        let calls = FakeProviderRecorder()
        let coordinator = coordinator(calls)
        var enabled = false
        let intake = ObservatorySpokenIntake(coordinator: { coordinator }, isEnabled: { enabled })
        await intake.ingest(span("disabled", 0, "So OpenBridge, explain magnets."))
        #expect(calls.callCount == 0)
        enabled = true
        await intake.ingest(span("a", 0, "OpenBridge, can you"))
        await intake.ingest(span("b", 1, "tell me what magnets are?", meeting: "different"))
        #expect(calls.callCount == 0)
        let cancelled = Task { @MainActor in await intake.ingest(span("c", 2, "Okay OpenBridge, explain magnets.")) }
        cancelled.cancel()
        await cancelled.value
        #expect(calls.callCount == 0)
        intake.reset()
        coordinator.endOfMeeting()
    }

    @Test func queueSnapshotAndRetainedCardsSurviveStatusUpdates() async {
        let calls = FakeProviderRecorder()
        let coordinator = coordinator(calls, delay: 0.05)
        let intake = ObservatorySpokenIntake(coordinator: { coordinator }, isEnabled: { true })
        await intake.ingest(span("a", 0, "So OpenBridge, explain magnets. Uh OpenBridge, explain gravity. Okay OpenBridge, tell me"))
        #expect(coordinator.spokenStatus.queuedQuestions == ["explain gravity."])
        #expect(coordinator.spokenStatus.pendingQuestion == "tell me")
        await waitUntil { coordinator.completedAnswers.count == 2 }
        #expect(calls.callCount == 2)
        #expect(coordinator.spokenStatus.queuedQuestions.isEmpty)
        let cards = coordinator.completedAnswers.flatMap { ObservatoryRailBridge.cards(for: $0) }
        let vm = ResearchRailViewModel(snapshot: .init(state: .answered, cards: cards, activeQuestion: nil))
        for state in [ResearchRailState.quiet, .searching, .failure, .noSource, .timeout] {
            let status = ResearchSpokenStatus(pendingQuestion: "tell me", needsRepeat: false, queuedQuestions: ["explain gravity."])
            vm.updateSnapshot(.init(state: state, cards: cards, activeQuestion: nil, spokenStatus: status))
            #expect(vm.visibleCards.count == 2)
            #expect(vm.snapshot.spokenStatus == status)
        }
        intake.reset()
        coordinator.endOfMeeting()
        #expect(coordinator.spokenStatus == .init())
    }

    @Test func typingRecoveryClearsIncompleteSpeechGuidance() async {
        let calls = FakeProviderRecorder()
        let coordinator = coordinator(calls)
        coordinator.receiveSpokenUpdate(.init(needsRepeat: true))
        #expect(coordinator.spokenStatus.needsRepeat)
        coordinator.submitTyped("What is the project color?")
        #expect(!coordinator.spokenStatus.needsRepeat)
        #expect(coordinator.spokenStatus.pendingQuestion == nil)
        coordinator.endOfMeeting()
    }
}
