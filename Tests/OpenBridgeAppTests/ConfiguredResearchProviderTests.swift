import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct ConfiguredResearchProviderTests {
    private let activeConfiguration = ProviderSettings().configuration

    private func providerSnapshot(
        _ configuration: ProviderConfiguration
    ) -> MeetingCloudProviderSnapshot {
        MeetingCloudProviderSnapshot(
            preset: configuration.preset,
            endpoint: configuration.baseURL,
            model: configuration.model,
            timeout: configuration.timeout
        )
    }

    private func match(meetingID: String, segmentID: String) -> WorkspacePassageMatch {
        WorkspacePassageMatch(
            meetingID: meetingID,
            workspaceID: "default",
            segmentID: segmentID,
            sourceLabel: "Room",
            sequence: 0,
            passage: "Selected meeting passage",
            relevanceScore: 1
        )
    }

    private func request(mode: ResearchProviderMode) -> GroundedAnswerRequest {
        GroundedAnswerRequest(
            context: ResearchProviderContext(
                meetingID: "meeting-new",
                workspaceID: "default",
                mode: mode,
                expectedCloudConfiguration: mode.allowsCloudProvider
                    ? activeConfiguration
                    : nil
            ),
            questionText: "What was decided?",
            passages: [ResearchGroundingPassage(
                evidenceID: "segment-1",
                passage: "We decided to ship on Friday.",
                sourceType: .currentMeeting
            )]
        )
    }

    @Test func unavailableCloudUsesLocalBeforeRequestStarts() async throws {
        let localCalls = FakeProviderRecorder()
        let cloudCalls = FakeProviderRecorder()
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { nil },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: FakeResearchProvider(recorder: cloudCalls)
        )

        let response = try await provider.groundedAnswer(request(mode: .cloudExperiment))

        #expect(response.answerText == "We decided to ship on Friday.")
        #expect(localCalls.callCount == 1)
        #expect(cloudCalls.callCount == 0)
    }

    @Test func localMeetingNeverUsesReadyCloud() async throws {
        let localCalls = FakeProviderRecorder()
        let cloudCalls = FakeProviderRecorder()
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { activeConfiguration },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: FakeResearchProvider(recorder: cloudCalls)
        )

        _ = try await provider.groundedAnswer(request(mode: .localOnly))

        #expect(localCalls.callCount == 1)
        #expect(cloudCalls.callCount == 0)
    }

    @Test func authorizedMeetingUsesReadyCloudForExplicitRequest() async throws {
        let localCalls = FakeProviderRecorder()
        let cloudCalls = FakeProviderRecorder()
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { activeConfiguration },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: FakeResearchProvider(recorder: cloudCalls)
        )

        _ = try await provider.groundedAnswer(request(mode: .cloudExperiment))

        #expect(localCalls.callCount == 0)
        #expect(cloudCalls.callCount == 1)
    }

    @Test func cloudFailureIsNotRetriedLocally() async {
        let localCalls = FakeProviderRecorder()
        let cloudCalls = FakeProviderRecorder()
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { activeConfiguration },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: FakeResearchProvider(
                configuration: .init(
                    groundedAnswerFailure: .providerError("injected cloud failure")
                ),
                recorder: cloudCalls
            )
        )

        await #expect(throws: ResearchProviderError.self) {
            _ = try await provider.groundedAnswer(request(mode: .cloudExperiment))
        }
        #expect(cloudCalls.callCount == 1)
        #expect(localCalls.callCount == 0)
    }

    @Test func cancellationDoesNotStartLocalFallback() async {
        let localCalls = FakeProviderRecorder()
        let cloudCalls = FakeProviderRecorder()
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { activeConfiguration },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: FakeResearchProvider(
                configuration: .init(delay: 1),
                recorder: cloudCalls
            )
        )

        let task = Task {
            try await provider.groundedAnswer(request(mode: .cloudExperiment))
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(localCalls.callCount == 0)
    }

    @Test func readinessForDifferentProviderKeepsRequestLocal() async throws {
        let localCalls = FakeProviderRecorder()
        let cloudCalls = FakeProviderRecorder()
        let changed = ProviderConfiguration(
            preset: .custom,
            baseURL: URL(string: "https://different.example/v1")!,
            model: "different-model",
            timeout: 30
        )
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { changed },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: FakeResearchProvider(recorder: cloudCalls)
        )

        _ = try await provider.groundedAnswer(request(mode: .cloudExperiment))

        #expect(localCalls.callCount == 1)
        #expect(cloudCalls.callCount == 0)
    }

    @Test func providerDriftAfterSelectionIsRejectedBeforeTransport() async {
        let localCalls = FakeProviderRecorder()
        let drifted = ProviderConfiguration(
            preset: .custom,
            baseURL: URL(string: "https://drifted.example/v1")!,
            model: "drifted-model",
            timeout: 30
        )
        let modelClient = CountingCloudModelClient()
        let cloud = OpenAICompatibleResearchProvider(
            authorizationGate: FixedCloudGate(configuration: drifted),
            modelClient: modelClient
        )
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { activeConfiguration },
            localProvider: FakeResearchProvider(recorder: localCalls),
            cloudProvider: cloud
        )

        await #expect(throws: ResearchProviderError.self) {
            _ = try await provider.groundedAnswer(request(mode: .cloudExperiment))
        }
        #expect(await modelClient.callCount == 0)
        #expect(localCalls.callCount == 0)
    }

    @Test func everyCloudBoundPassageRequiresItsOwnConsentAndMatchingProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-consent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let active = ProviderSettings().configuration
        let intelligence = MeetingIntelligenceConfiguration(
            cleanupEnabled: false,
            cleanupProvider: .localGemma,
            cloudProvider: providerSnapshot(active)
        )

        try store.create(MeetingManifest(
            meetingID: "cloud-source",
            title: "Cloud source",
            state: .completed,
            aiMode: .cloudOptIn,
            privacySettings: .init(allowsCloudIntelligence: true),
            intelligenceConfiguration: intelligence
        ))
        try store.create(MeetingManifest(
            meetingID: "local-source",
            title: "Local source",
            state: .completed,
            aiMode: .localOnly,
            privacySettings: .init(allowsCloudIntelligence: false),
            intelligenceConfiguration: intelligence
        ))

        #expect(ResearchCloudEvidencePolicy.allowsCloud(
            for: [match(meetingID: "cloud-source", segmentID: "s1")],
            store: store,
            activeConfiguration: active
        ))
        #expect(!ResearchCloudEvidencePolicy.allowsCloud(
            for: [
                match(meetingID: "cloud-source", segmentID: "s1"),
                match(meetingID: "local-source", segmentID: "s2"),
            ],
            store: store,
            activeConfiguration: active
        ))

        let changedProvider = ProviderConfiguration(
            preset: .custom,
            baseURL: URL(string: "https://different.example/v1")!,
            model: "different-model",
            timeout: 30
        )
        #expect(!ResearchCloudEvidencePolicy.allowsCloud(
            for: [match(meetingID: "cloud-source", segmentID: "s1")],
            store: store,
            activeConfiguration: changedProvider
        ))
    }

    @Test func enablingDuringRecordingRestoresWorkspaceAndCloudBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-research-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let intelligence = MeetingIntelligenceConfiguration(
            cleanupEnabled: false,
            cleanupProvider: .localGemma,
            cloudProvider: providerSnapshot(activeConfiguration)
        )
        let meeting = MeetingManifest(
            meetingID: "active-custom",
            title: "Active Custom",
            workspaceID: "customer-workspace",
            state: .recording,
            aiMode: .cloudOptIn,
            privacySettings: .init(
                allowsLocalIntelligence: true,
                allowsCloudIntelligence: true
            ),
            intelligenceConfiguration: intelligence
        )
        try store.create(meeting)

        let context = try #require(ResearchActiveMeetingContext.resolve(
            activeMeetingID: meeting.meetingID,
            store: store
        ))

        #expect(context.meetingID == meeting.meetingID)
        #expect(context.workspaceID == "customer-workspace")
        #expect(context.allowsCloud)
    }
}

private actor FixedCloudGate: CloudRequestAuthorizing {
    let configuration: ProviderConfiguration

    init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    func authorizeCloudRequest(
        requestID: String,
        meetingConsent: Bool
    ) async throws -> AuthorizedCloudRequest {
        AuthorizedCloudRequest(
            requestID: requestID,
            configuration: configuration,
            apiKey: "test-key"
        )
    }

    func finishCloudRequest(requestID: String) async {}
}

private actor CountingCloudModelClient: CloudModelClient {
    private(set) var callCount = 0

    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        callCount += 1
        return #"{"answerText":"unused","citations":[],"confidence":1,"abstained":false}"#
    }
}
