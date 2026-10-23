import Foundation
import Testing
@testable import OpenBridgeApp

private actor TypedCloudGate: CloudRequestAuthorizing {
    let configuration: ProviderConfiguration
    var finished = 0
    let beforeAuthorizationReturns: @Sendable () throws -> Void
    init(_ configuration: ProviderConfiguration, beforeAuthorizationReturns: @escaping @Sendable () throws -> Void = {}) {
        self.configuration = configuration; self.beforeAuthorizationReturns = beforeAuthorizationReturns
    }
    func authorizeCloudRequest(requestID: String, meetingConsent: Bool) async throws -> AuthorizedCloudRequest {
        guard meetingConsent else { throw CloudRequestAuthorizationError.meetingConsentRequired }
        try beforeAuthorizationReturns()
        return .init(requestID: requestID, configuration: configuration, apiKey: "synthetic-test-only")
    }
    func finishCloudRequest(requestID: String) async { finished += 1 }
}
private actor TypedCloudTransport: CloudModelClient {
    var calls = 0
    var outputBudget = 0
    func complete(_ request: CloudChatCompletionRequest, authorization: AuthorizedCloudRequest) async throws -> String {
        calls += 1
        outputBudget = request.maxTokens
        return #"{"meetingClaims":[{"text":"We selected Cedar.","sentenceIDs":["p0s0"]}],"explanation":null,"limitation":null}"#
    }
}
struct CurrentMeetingProviderTests {
    private func request(mode: ResearchProviderMode = .cloudExperiment) -> CurrentMeetingQuestionRequest {
        .init(context: .init(requestID: "typed", meetingID: "current", mode: mode,
            expectedCloudConfiguration: ProviderSettings().configuration), question: "What was selected?",
            previousQuestion: nil, passages: [.init(segmentID: "s", text: "We selected Cedar.", sourceLabel: "Me", start: 1)],
            contextIsPartial: false, coveredThrough: 30)
    }
    @Test func oneTypedQuestionMakesOneAuthorizedTransportCall() async throws {
        let gate = TypedCloudGate(ProviderSettings().configuration), transport = TypedCloudTransport()
        let cloud = OpenAICompatibleResearchProvider(authorizationGate: gate, modelClient: transport)
        let provider = ConfiguredResearchProvider(cloudReadiness: { ProviderSettings().configuration }, localProvider: LocalEvidenceResearchProvider(), cloudProvider: cloud)
        let answer = try await provider.answerCurrentMeeting(request())
        #expect(answer.claims.first?.citations.first?.segmentID == "s")
        #expect(await transport.calls == 1)
        #expect(await transport.outputBudget == 4_000)
        #expect(await gate.finished == 1)
    }
    @Test func unavailableCloudAndLocalModeNeverFallbackOrSend() async {
        let transport = TypedCloudTransport()
        let cloud = OpenAICompatibleResearchProvider(authorizationGate: TypedCloudGate(ProviderSettings().configuration), modelClient: transport)
        let blocked = ConfiguredResearchProvider(cloudReadiness: { nil }, localProvider: LocalEvidenceResearchProvider(), cloudProvider: cloud)
        await #expect(throws: ResearchProviderError.self) { try await blocked.answerCurrentMeeting(request()) }
        await #expect(throws: ResearchProviderError.self) { try await cloud.answerCurrentMeeting(request(mode: .localOnly)) }
        #expect(await transport.calls == 0)
    }
    @Test func providerDriftIsRejectedBeforeCredentialReachesTransport() async {
        var changed = ProviderSettings().configuration
        changed.model = "changed-model"
        let transport = TypedCloudTransport()
        let cloud = OpenAICompatibleResearchProvider(authorizationGate: TypedCloudGate(changed), modelClient: transport)
        await #expect(throws: ResearchProviderError.self) { try await cloud.answerCurrentMeeting(request()) }
        #expect(await transport.calls == 0)
    }

    @Test func sourceRevokedDuringAuthorizationNeverReachesTransport() async throws {
        let store = MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-permission-\(UUID().uuidString)"), meetingDeletionObserver: { _ in })
        defer { try? store.deleteAll() }
        let configuration = ProviderSettings().configuration
        let provider = MeetingCloudProviderSnapshot(preset: configuration.preset, endpoint: configuration.baseURL,
            model: configuration.model, timeout: configuration.timeout)
        for id in ["current", "past"] {
            try store.create(MeetingManifest(meetingID: id, title: "Synthetic", state: .completed))
            try store.setResearchPermission(meetingID: id, provider: provider)
        }
        let transport = TypedCloudTransport()
        let gate = TypedCloudGate(configuration, beforeAuthorizationReturns: {
            try store.setResearchPermission(meetingID: "past", provider: nil)
        })
        let cloud = OpenAICompatibleResearchProvider(authorizationGate: gate, modelClient: transport, researchStore: store)
        var input = request(); input.sourceMeetingIDs = ["current"]
        // Previous answers are also private source-derived context. Transport
        // must revalidate their sources even when no new passage cites them.
        input.conversation = [.init(question: "Earlier question", answer: "Earlier answer", sourceMeetingIDs: ["past"])]
        await #expect(throws: ResearchProviderError.self) { try await cloud.answerCurrentMeeting(input) }
        #expect(await transport.calls == 0)
        #expect(await gate.finished == 1)
    }
}
