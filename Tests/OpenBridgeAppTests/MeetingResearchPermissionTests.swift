import Foundation
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

private actor HistoryQuestionRecorder {
    var requests: [CurrentMeetingQuestionRequest] = []
    func answer(_ request: CurrentMeetingQuestionRequest) -> CurrentMeetingQuestionResponse {
        requests.append(request)
        return .init(requestID: request.context.requestID, claims: request.passages.map {
            .init(text: $0.text, citations: [.init(segmentID: $0.segmentID, quote: $0.text, meetingID: $0.meetingID)])
        }, explanation: nil, limitation: nil)
    }
}

@Suite(.serialized) @MainActor struct MeetingResearchPermissionTests {
    private func fixture(_ id: String, cleanup: MeetingAIMode = .transcriptionOnly, research: Bool = false) throws -> MeetingManifest {
        let mode = MeetingAIChoices.permissionMode(research: research, cleanup: cleanup)
        return MeetingManifest(meetingID: id, title: "Synthetic \(id)", state: .completed, aiMode: mode,
            segments: [.init(id: "same-segment", meetingID: id, sequence: 0, startOffset: 0, endOffset: 30,
                text: "Project Cedar budget is seven dollars for \(id).")],
            privacySettings: .init(allowsLocalIntelligence: mode != .transcriptionOnly,
                allowsCloudIntelligence: mode == .cloudOptIn),
            intelligenceConfiguration: try MeetingIntelligenceConfigurationResolver.snapshot(
                cleanupEnabled: cleanup != .transcriptionOnly, aiMode: mode,
                providerSettings: .init(cloudEnabled: true, consentGranted: true),
                hasCredential: true, providerWasTested: true,
                cleanupProvider: cleanup == .cloudOptIn ? .cloud : .localGemma))
    }
    private func store() -> MeetingSessionStore {
        .init(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("research-access-\(UUID().uuidString)"), meetingDeletionObserver: { _ in })
    }
    private var provider: MeetingCloudProviderSnapshot {
        let configuration = ProviderSettings().configuration
        return .init(preset: configuration.preset, endpoint: configuration.baseURL, model: configuration.model, timeout: configuration.timeout)
    }
    private func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        Issue.record("State did not settle")
    }

    @Test func sixIndependentChoicesAndSidecarSurviveCaptureSave() throws {
        let store = store(); defer { try? store.deleteAll() }
        for research in [false, true] {
            for cleanup in [MeetingAIMode.transcriptionOnly, .localOnly, .cloudOptIn] {
                let manifest = try fixture(UUID().uuidString, cleanup: cleanup, research: research)
                try store.create(manifest)
                try store.setResearchPermission(meetingID: manifest.meetingID, provider: research ? provider : nil)
                #expect((MeetingResearchPermissionPolicy.provider(for: manifest, store: store) != nil) == research)
                #expect(MeetingPostStopCleanupPlan.shouldRun(mode: .off, manifest: manifest) == (cleanup != .transcriptionOnly))
                let before = try Data(contentsOf: store.manifestURL(for: manifest.meetingID))
                try store.setResearchPermission(meetingID: manifest.meetingID, provider: research ? nil : provider)
                #expect(try Data(contentsOf: store.manifestURL(for: manifest.meetingID)) == before)
                try store.saveManifest(manifest)
                #expect((MeetingResearchPermissionPolicy.provider(for: manifest, store: store) != nil) == !research)
            }
        }
    }

    @Test func legacyPermissionIsPreservedButExplicitDenialWins() throws {
        let store = store(); defer { try? store.deleteAll() }
        let value = try fixture("old", research: true); try store.create(value)
        #expect(MeetingResearchPermissionPolicy.provider(for: value, store: store) != nil)
        try store.setResearchPermission(meetingID: value.meetingID, provider: nil)
        #expect(MeetingResearchPermissionPolicy.provider(for: value, store: store) == nil)
        try Data("broken".utf8).write(to: store.meetingDirectory(for: value.meetingID).appendingPathComponent("research-permission.json"))
        #expect(MeetingResearchPermissionPolicy.provider(for: value, store: store) == nil)
    }

    @Test func neverStoreExpiredAndDeletedCannotBeAuthorized() throws {
        let store = store(); defer { try? store.deleteAll() }
        var never = try fixture("never"); never.retentionPolicy = .neverStoreTranscript; try store.create(never)
        #expect(throws: (any Error).self) { try store.setResearchPermission(meetingID: "never", provider: provider) }
        var expired = try fixture("expired"); expired.retentionPolicy = .autoDeleteAfter7Days
        expired.startedAt = Date(timeIntervalSinceNow: -8 * 86_400); try store.create(expired)
        #expect(!MeetingResearchPermissionPolicy.eligible(expired))
        let deleted = try fixture("deleted"); try store.create(deleted); try store.delete(meetingID: "deleted")
        #expect(throws: (any Error).self) { try store.setResearchPermission(meetingID: "deleted", provider: provider) }
        #expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(for: "deleted").path))
    }

    @Test func midMeetingGrantAndFrozenBulkApprovalNeverChangeCleanupOrFutureMeetings() async throws {
        let store = store(); defer { try? store.deleteAll() }
        var current = try fixture("current"); current.state = .recording; try store.create(current)
        try store.create(fixture("past"))
        let configured = provider.configuration
        let controller = MeetingResearchController(store: store, configuredProvider: { configured }, answer: { _ in
            Issue.record("Permission changes must not submit a request"); throw URLError(.cancelled)
        })
        controller.selectMeeting(current)
        await eventually { controller.snapshot.researchAccess?.canEnable == true }
        #expect(controller.snapshot.researchAccess?.detail.contains("Cloud research is off") == true)
        let providerLabel = controller.snapshot.researchAccess?.provider
        let ids = await controller.permissionRows().map(\.id)
        try store.create(fixture("future"))
        #expect(await controller.applyResearchPermission(ids: ids, allowed: true).isEmpty)
        await eventually { controller.snapshot.researchAccess?.canAsk == true }
        #expect(controller.snapshot.researchAccess?.detail == "")
        #expect(controller.snapshot.researchAccess?.provider == providerLabel)
        #expect(try store.load(meetingID: "current").intelligenceConfiguration?.cleanupEnabled == false)
        #expect(MeetingResearchPermissionPolicy.provider(for: try store.load(meetingID: "future"), store: store) == nil)
        #expect(await controller.applyResearchPermission(ids: ["current"], allowed: false).isEmpty)
        await eventually { controller.snapshot.researchAccess?.canAsk == false }
        #expect(controller.snapshot.researchAccess?.detail.contains("Cloud research is off") == true)
    }

    @Test func historySelectionIsBoundedAndCitationIdentityIncludesMeeting() throws {
        let current = try fixture("current"), past = try fixture("past")
        let selection = MeetingHistoryContextRetriever.select(current: current, history: [past], question: "Cedar budget past",
            previousQuestion: nil, previousSourceIDs: [])
        #expect(selection.passages.count <= 6)
        #expect(selection.passages.map(\.text.count).reduce(0, +) <= 12_000)
        #expect(Set(selection.passages.compactMap(\.meetingID)) == ["current", "past"])
        let request = CurrentMeetingQuestionRequest(context: .init(requestID: "q", mode: .cloudExperiment),
            question: "budget", previousQuestion: nil, passages: selection.passages, contextIsPartial: true, coveredThrough: 30)
        let response = try CurrentMeetingAnswerCodec.decode("{\"meetingClaims\":[{\"text\":\"Seven dollars.\",\"sentenceIDs\":[\"p1s0\"]}],\"explanation\":null,\"limitation\":null}", request: request)
        #expect(response.claims.first?.citations.first?.meetingID == "past")
        #expect(response.claims.first?.citations.first?.segmentID == "same-segment")
        let followUp = MeetingHistoryContextRetriever.select(current: current, history: [past], question: "Explain that",
            previousQuestion: nil, previousSourceIDs: [MeetingHistoryContextRetriever.sourceKey(meetingID: "past", segmentID: "same-segment")])
        #expect(followUp.passages.contains { $0.meetingID == "past" })
    }

    @Test func eachSourceNeedsCurrentPermissionAndMatchingProvider() throws {
        let store = store(); defer { try? store.deleteAll() }
        for id in ["current", "past"] { try store.create(fixture(id)) }
        try store.setResearchPermission(meetingID: "current", provider: provider)
        #expect(MeetingResearchPermissionPolicy.authorizedConfiguration(ids: ["current", "past"], store: store, configuration: provider.configuration) == nil)
        try store.setResearchPermission(meetingID: "past", provider: provider)
        #expect(MeetingResearchPermissionPolicy.authorizedConfiguration(ids: ["current", "past"], store: store, configuration: provider.configuration) != nil)
        var changed = provider.configuration; changed.model = "another-model"
        #expect(MeetingResearchPermissionPolicy.authorizedConfiguration(ids: ["current", "past"], store: store, configuration: changed) == nil)
        try store.setResearchPermission(meetingID: "past", provider: nil)
        #expect(MeetingResearchPermissionPolicy.authorizedConfiguration(ids: ["current", "past"], store: store, configuration: provider.configuration) == nil)
    }

    @Test func historyUsesOnlyApprovedMeetingsAndDeletionPurgesCrossMeetingAnswers() async throws {
        let store = store(); defer { try? store.deleteAll() }
        let current = try fixture("current"); try store.create(current)
        try store.create(fixture("past")); try store.create(fixture("private"))
        for id in ["current", "past"] { try store.setResearchPermission(meetingID: id, provider: provider) }
        let ledger = HistoryQuestionRecorder(), configuration = provider.configuration
        let controller = MeetingResearchController(store: store, configuredProvider: { configuration }, answer: { await ledger.answer($0) })
        controller.selectMeeting(current)
        await eventually { controller.snapshot.researchAccess?.approvedHistoryCount == 1 }
        controller.setScope(.history); controller.submit("Cedar budget", id: "history")
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        let requests = await ledger.requests
        #expect(requests.count == 1)
        #expect(Set(requests[0].sourceMeetingIDs) == ["current", "past"])
        #expect(controller.snapshot.meetingQuestions?.first?.scope == .history)
        #expect(controller.snapshot.meetingQuestions?.first?.evidence.contains { $0.sourceTitle?.contains("Synthetic past") == true } == true)
        try store.delete(meetingID: "past")
        await eventually { controller.snapshot.meetingQuestions?.isEmpty == true }
        #expect(try store.load(meetingID: "private").segments.count == 1)
    }

    @Test func deniedComposerKeepsDraftAndCannotSubmitFromKeyboard() {
        var snapshot = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil, meetingQuestions: [], meetingTitle: "Synthetic")
        snapshot.researchAccess = .init(canAsk: false, canEnable: true, detail: "Cloud research off")
        let vm = ResearchRailViewModel(); vm.updateSnapshot(snapshot)
        vm.composerText = "What did we agree?"
        vm.onSubmitQuestion = { _ in Issue.record("Denied composer submitted") }
        vm.submitQuestion()
        #expect(vm.composerText == "What did we agree?")
    }

    @Test func newPermissionCannotExpandAQueuedQuestionsConversationScope() async throws {
        let store = store(); defer { try? store.deleteAll() }
        var current = try fixture("current"); current.state = .recording
        try store.create(current); try store.create(fixture("past"))
        for id in ["current", "past"] { try store.setResearchPermission(meetingID: id, provider: provider) }
        let ledger = HistoryQuestionRecorder()
        let controller = MeetingResearchController(store: store, configuredProvider: { provider.configuration }, answer: { await ledger.answer($0) })
        controller.selectMeeting(current)
        await eventually { controller.snapshot.researchAccess?.approvedHistoryCount == 1 }
        controller.setScope(.history); controller.submit("Cedar budget", id: "first")
        controller.useAvailable("first")
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        try store.setResearchPermission(meetingID: "past", provider: nil)
        await eventually { controller.snapshot.researchAccess?.approvedHistoryCount == 0 }
        controller.submit("A new question", id: "second")
        try store.setResearchPermission(meetingID: "past", provider: provider)
        await eventually { controller.snapshot.researchAccess?.approvedHistoryCount == 1 }
        controller.useAvailable("second")
        await eventually { controller.snapshot.meetingQuestions?.last?.phase == .answered }
        let second = try #require(await ledger.requests.last)
        #expect(await ledger.requests.count == 2)
        #expect(second.previousQuestion == nil)
        #expect(second.conversation.isEmpty)
        #expect(second.sourceMeetingIDs == ["current"])
    }

    @Test func queuedQuestionFreezesHistoryAndProviderWithdrawalRequiresExplicitRetry() async throws {
        let store = store(); defer { try? store.deleteAll() }
        var current = try fixture("current"); current.state = .recording
        try store.create(current); try store.create(fixture("past")); try store.create(fixture("later"))
        for id in ["current", "past"] { try store.setResearchPermission(meetingID: id, provider: provider) }
        let ledger = HistoryQuestionRecorder()
        var configuration: ProviderConfiguration? = provider.configuration
        let controller = MeetingResearchController(store: store, configuredProvider: { configuration }, answer: { await ledger.answer($0) })
        controller.selectMeeting(current)
        await eventually { controller.snapshot.researchAccess?.approvedHistoryCount == 1 }
        controller.setScope(.history)
        controller.submit("Cedar budget", id: "frozen")
        try store.setResearchPermission(meetingID: "later", provider: provider)
        await eventually { controller.snapshot.researchAccess?.approvedHistoryCount == 2 }
        controller.useAvailable("frozen")
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(Set(await ledger.requests.first?.sourceMeetingIDs ?? []) == ["current", "past"])
        controller.submit("Another question", id: "blocked")
        configuration = nil; controller.refreshAccess()
        await eventually { controller.snapshot.meetingQuestions?.last?.phase == .failed }
        #expect(controller.snapshot.meetingQuestions?.last?.mayRetry == false)
        configuration = provider.configuration; controller.refreshAccess()
        await eventually { controller.snapshot.meetingQuestions?.last?.mayRetry == true }
        #expect(await ledger.requests.count == 1)
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .answered)
    }
}
