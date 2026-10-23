import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct CloudMeetingCleanupTests {
    private let providerConfiguration = ProviderConfiguration(
        preset: .deepSeek,
        baseURL: URL(string: "https://api.deepseek.com")!,
        model: "deepseek-v4-flash",
        timeout: 30
    )

    @Test func newMeetingChoosesCloudOnlyForTestedAuthorizedConfiguration() throws {
        let untested = ProviderSettings(
            preset: .deepSeek,
            providerLabel: "DeepSeek",
            baseURL: providerConfiguration.baseURL,
            model: providerConfiguration.model,
            timeout: providerConfiguration.timeout,
            cloudEnabled: true,
            consentGranted: true
        )
        #expect(throws: CloudRequestAuthorizationError.connectionTestRequired) {
            _ = try MeetingIntelligenceConfigurationResolver.snapshot(
                cleanupEnabled: true,
                aiMode: .cloudOptIn,
                providerSettings: untested,
                hasCredential: true,
                providerWasTested: false
            )
        }

        let tested = untested
        let cloud = try MeetingIntelligenceConfigurationResolver.snapshot(
            cleanupEnabled: true,
            aiMode: .cloudOptIn,
            providerSettings: tested,
            hasCredential: true,
            providerWasTested: true
        )
        #expect(cloud.cleanupProvider == .cloud)
        #expect(cloud.cloudProvider?.endpoint == providerConfiguration.baseURL)
        #expect(cloud.cloudProvider?.model == providerConfiguration.model)

        let noMeetingConsent = try MeetingIntelligenceConfigurationResolver.snapshot(
            cleanupEnabled: true,
            aiMode: .localOnly,
            providerSettings: tested,
            hasCredential: false,
            providerWasTested: false
        )
        #expect(noMeetingConsent.cleanupProvider == .localGemma)

        #expect(throws: CloudRequestAuthorizationError.missingCredential) {
            _ = try MeetingIntelligenceConfigurationResolver.snapshot(
                cleanupEnabled: true,
                aiMode: .cloudOptIn,
                providerSettings: tested,
                hasCredential: false,
                providerWasTested: true
            )
        }

        var disabled = tested
        disabled.cloudEnabled = false
        #expect(throws: CloudRequestAuthorizationError.cloudDisabled) {
            _ = try MeetingIntelligenceConfigurationResolver.snapshot(
                cleanupEnabled: true,
                aiMode: .cloudOptIn,
                providerSettings: disabled,
                hasCredential: true,
                providerWasTested: true
            )
        }
    }

    @Test func authorizationFailuresPersistContentFreeActionableReasons() {
        let cases: [(CloudRequestAuthorizationError, CleanupFailureReason)] = [
            (.cloudDisabled, .cloudDisabled),
            (.globalConsentRequired, .consentRequired),
            (.meetingConsentRequired, .consentRequired),
            (.missingCredential, .authentication),
            (.connectionTestRequired, .connectionTestRequired),
            (.invalidConfiguration("private provider detail"), .configurationChanged),
            (.configurationChanged, .configurationChanged),
            (.requestAlreadyActive, .requestAlreadyActive),
        ]

        for (error, expected) in cases {
            let reason = CleanupFailureReason.classify(error)
            #expect(reason == expected)
            #expect(!reason.rawValue.contains("private"))
        }
    }

    @Test func localAndCloudPlaceholderFailuresShareAContentFreeReason() {
        #expect(
            CleanupFailureReason.classify(
                EngineServiceError.processFailed("cleanup_placeholder_text")
            ) == .emptyText
        )
        #expect(
            CleanupFailureReason.classify(CloudMeetingCleanupError.placeholderText) == .emptyText
        )
    }

    @Test func olderManifestDecodesWithoutIntelligenceConfiguration() throws {
        let json = """
        {
          "schemaVersion": 3,
          "meetingID": "legacy-meeting",
          "title": "Legacy",
          "state": "completed",
          "startedAt": "2026-08-01T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(MeetingManifest.self, from: Data(json.utf8))
        #expect(manifest.intelligenceConfiguration == nil)
    }

    @Test func cloudCoordinatorChunksAlignsPersistsProvenanceAndPreservesOriginal() async throws {
        let fixture = try makeCloudMeeting(segmentCount: 9)
        let gate = RecordingCloudGate(configuration: providerConfiguration)
        let client = AlignedCleanupClient()
        let engine = CloudMeetingCleanupEngine(
            meetingID: fixture.manifest.meetingID,
            meetingConsent: true,
            providerSnapshot: fixture.snapshot,
            authorizationGate: gate,
            modelClient: client
        )

        let revision = try await MeetingCleanupCoordinator(
            store: fixture.store,
            engine: engine
        ).run(meetingID: fixture.manifest.meetingID)

        #expect(revision.state == .valid)
        #expect(revision.resolvedProvenance.producer == .cloud)
        #expect(revision.resolvedProvenance.providerIdentifier == ProviderPreset.deepSeek.rawValue)
        #expect(revision.resolvedProvenance.endpoint == providerConfiguration.baseURL)
        #expect(revision.resolvedProvenance.model == providerConfiguration.model)
        #expect(revision.cleanedSegments.map(\.sourceSegmentID) == fixture.manifest.segments.map(\.id))
        #expect(await client.callCount == 2)
        #expect(await gate.authorizationCount == 2)
        #expect(await gate.finishCount == 2)

        let requests = await client.requests
        #expect(requests.count == 2)
        let systemPrompt = try #require(requests.first?.messages.first?.content)
        let requiredInstructions = [
            "Fidelity is more important than",
            "statement, clause, qualification, correction",
            "name, number, amount, date",
            "instance of profanity",
            "sealed container",
            "Never move, copy, borrow, or duplicate text across items",
            "begins or",
            "ends mid-sentence",
            "terminal punctuation",
            "that makes the fragment appear complete",
            "we stopped because must remain We stopped because",
            "Never return empty cleanedText or replace speech with an ellipsis",
            "Do not summarize, paraphrase, reorganize",
            "No glossary is supplied",
            "retain every proper noun",
            "Preserve repetition used for emphasis, disagreement, or correction",
            "Remove an isolated filler",
            "Remove an obvious abandoned word fragment",
            "Collapse a simple accidental stutter",
            "only when the intended wording is unambiguous",
            "silently compare each cleanedText with its own source text",
        ]
        for instruction in requiredInstructions {
            #expect(systemPrompt.contains(instruction))
        }
        #expect(!systemPrompt.contains(#""cleanedText":"...""#))

        let firstUserPrompt = try #require(requests.first?.messages.last?.content)
        let userData = try #require(firstUserPrompt.data(using: .utf8))
        let userObject = try #require(
            try JSONSerialization.jsonObject(with: userData) as? [String: Any]
        )
        let promptSegments = try #require(userObject["segments"] as? [[String: Any]])
        #expect(promptSegments.count == 8)
        #expect(promptSegments.allSatisfy { Set($0.keys) == ["index", "text"] })
        #expect(!firstUserPrompt.contains("segment-"))

        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.segments == fixture.manifest.segments)
        #expect(saved.activeCleanupRevisionID == revision.id)
        let manifestJSON = try String(contentsOf: fixture.store.manifestURL(for: saved.meetingID))
        #expect(manifestJSON.contains("deepseek-v4-flash"))
        #expect(!manifestJSON.contains("sk-cloud-secret"))

        // Build 21 wrote otherwise valid cloud revisions with a nil active
        // pointer. Loading that durable shape must recover the existing result
        // locally and must not make another provider request.
        var build21Manifest = saved
        build21Manifest.activeCleanupRevisionID = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(build21Manifest).write(
            to: fixture.store.manifestURL(for: saved.meetingID),
            options: .atomic
        )

        let recovered = try fixture.store.load(meetingID: saved.meetingID)
        #expect(recovered.activeCleanupRevisionID == revision.id)
        #expect(await client.callCount == 2)
    }

    @Test func providerDriftFailsBeforeTranscriptReachesClientAndDoesNotFallback() async throws {
        let fixture = try makeCloudMeeting(segmentCount: 2)
        let changed = ProviderConfiguration(
            preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/deepseek-v4-flash",
            timeout: 30
        )
        let gate = RecordingCloudGate(configuration: changed)
        let client = AlignedCleanupClient()
        let engine = CloudMeetingCleanupEngine(
            meetingID: fixture.manifest.meetingID,
            meetingConsent: true,
            providerSnapshot: fixture.snapshot,
            authorizationGate: gate,
            modelClient: client
        )

        await #expect(throws: CloudRequestAuthorizationError.configurationChanged) {
            _ = try await MeetingCleanupCoordinator(store: fixture.store, engine: engine)
                .run(meetingID: fixture.manifest.meetingID)
        }

        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.cleanupJobs.last?.state == .failed)
        #expect(saved.cleanupRevisions.count == 1)
        #expect(saved.cleanupRevisions.first?.resolvedProvenance.producer == .cloud)
        #expect(saved.activeCleanupRevisionID == nil)
        #expect(saved.segments == fixture.manifest.segments)
        #expect(await client.callCount == 0)
        #expect(await gate.finishCount == 1)
    }

    @Test func misalignedCloudJSONCannotActivateOrOverwriteOriginal() async throws {
        let fixture = try makeCloudMeeting(segmentCount: 2)
        let gate = RecordingCloudGate(configuration: providerConfiguration)
        let client = MisalignedCleanupClient()
        let engine = CloudMeetingCleanupEngine(
            meetingID: fixture.manifest.meetingID,
            meetingConsent: true,
            providerSnapshot: fixture.snapshot,
            authorizationGate: gate,
            modelClient: client
        )

        await #expect(throws: CloudMeetingCleanupError.invalidIndex) {
            _ = try await MeetingCleanupCoordinator(store: fixture.store, engine: engine)
                .run(meetingID: fixture.manifest.meetingID)
        }
        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.cleanupJobs.last?.state == .failed)
        #expect(saved.activeCleanupRevisionID == nil)
        #expect(saved.segments == fixture.manifest.segments)
        #expect(await client.callCount == 1)
    }

    @Test func ellipsisOnlyCloudJSONCannotActivateOrOverwriteOriginal() async throws {
        let fixture = try makeCloudMeeting(segmentCount: 1)
        let gate = RecordingCloudGate(configuration: providerConfiguration)
        let engine = CloudMeetingCleanupEngine(
            meetingID: fixture.manifest.meetingID,
            meetingConsent: true,
            providerSnapshot: fixture.snapshot,
            authorizationGate: gate,
            modelClient: EllipsisCleanupClient()
        )

        await #expect(throws: CloudMeetingCleanupError.placeholderText) {
            _ = try await MeetingCleanupCoordinator(store: fixture.store, engine: engine)
                .run(meetingID: fixture.manifest.meetingID)
        }
        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.cleanupJobs.last?.failureReason == .emptyText)
        #expect(saved.activeCleanupRevisionID == nil)
        #expect(saved.segments == fixture.manifest.segments)
    }

    @Test func revokedMeetingConsentFailsWithoutCallingCloudClient() async throws {
        let fixture = try makeCloudMeeting(segmentCount: 1)
        let gate = RecordingCloudGate(configuration: providerConfiguration)
        let client = AlignedCleanupClient()
        let engine = CloudMeetingCleanupEngine(
            meetingID: fixture.manifest.meetingID,
            meetingConsent: false,
            providerSnapshot: fixture.snapshot,
            authorizationGate: gate,
            modelClient: client
        )

        await #expect(throws: CloudRequestAuthorizationError.meetingConsentRequired) {
            _ = try await MeetingCleanupCoordinator(store: fixture.store, engine: engine)
                .run(meetingID: fixture.manifest.meetingID)
        }
        #expect(await client.callCount == 0)
        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.cleanupJobs.last?.state == .failed)
        #expect(saved.segments == fixture.manifest.segments)
    }

    @Test func cancellationIsDurableAndNeverActivatesPartialCloudOutput() async throws {
        let fixture = try makeCloudMeeting(segmentCount: 2)
        let gate = RecordingCloudGate(configuration: providerConfiguration)
        let engine = CloudMeetingCleanupEngine(
            meetingID: fixture.manifest.meetingID,
            meetingConsent: true,
            providerSnapshot: fixture.snapshot,
            authorizationGate: gate,
            modelClient: CancellingCleanupClient()
        )

        await #expect(throws: CancellationError.self) {
            _ = try await MeetingCleanupCoordinator(store: fixture.store, engine: engine)
                .run(meetingID: fixture.manifest.meetingID)
        }
        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.cleanupJobs.last?.state == .cancelled)
        #expect(saved.activeCleanupRevisionID == nil)
        #expect(saved.segments == fixture.manifest.segments)
        #expect(await gate.finishCount == 1)
    }

    @Test func localAlternativeRequiresExplicitSelectionAndPreservesCloudSnapshot() throws {
        let fixture = try makeCloudMeeting(segmentCount: 1)
        let original = fixture.manifest.segments

        try fixture.store.selectLocalCleanupAlternative(meetingID: fixture.manifest.meetingID)

        let saved = try fixture.store.load(meetingID: fixture.manifest.meetingID)
        #expect(saved.intelligenceConfiguration?.cleanupProvider == .localGemma)
        #expect(saved.intelligenceConfiguration?.cloudProvider == fixture.snapshot)
        #expect(saved.cleanupJobs.isEmpty)
        #expect(saved.segments == original)
    }

    private func makeCloudMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, manifest: MeetingManifest, snapshot: MeetingCloudProviderSnapshot) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let meetingID = UUID().uuidString
        let snapshot = MeetingCloudProviderSnapshot(
            preset: providerConfiguration.preset,
            endpoint: providerConfiguration.baseURL,
            model: providerConfiguration.model,
            timeout: providerConfiguration.timeout
        )
        let segments = (0..<segmentCount).map { index in
            MeetingTranscriptSegment(
                id: "segment-\(index)",
                meetingID: meetingID,
                sequence: index,
                text: "um source text \(index)",
                isFinal: true
            )
        }
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Cloud cleanup fixture",
            state: .completed,
            aiMode: .cloudOptIn,
            segments: segments,
            privacySettings: MeetingPrivacySettings(
                allowsLocalIntelligence: true,
                allowsCloudIntelligence: true
            ),
            intelligenceConfiguration: MeetingIntelligenceConfiguration(
                cleanupEnabled: true,
                cleanupProvider: .cloud,
                cloudProvider: snapshot
            )
        )
        try store.create(manifest)
        return (store, manifest, snapshot)
    }
}

private actor RecordingCloudGate: CloudRequestAuthorizing {
    let configuration: ProviderConfiguration
    private(set) var authorizationCount = 0
    private(set) var finishCount = 0

    init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    func authorizeCloudRequest(
        requestID: String,
        meetingConsent: Bool
    ) async throws -> AuthorizedCloudRequest {
        guard meetingConsent else {
            throw CloudRequestAuthorizationError.meetingConsentRequired
        }
        authorizationCount += 1
        return AuthorizedCloudRequest(
            requestID: requestID,
            configuration: configuration,
            apiKey: "sk-cloud-secret"
        )
    }

    func finishCloudRequest(requestID: String) async {
        finishCount += 1
    }
}

private actor AlignedCleanupClient: CloudModelClient {
    private(set) var callCount = 0
    private(set) var requests: [CloudChatCompletionRequest] = []

    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        callCount += 1
        requests.append(request)
        guard let user = request.messages.last?.content,
              request.responseFormat == .jsonObject,
              !user.contains("segment-"),
              let data = user.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = object["segments"] as? [[String: Any]] else {
            throw CloudMeetingCleanupError.invalidRequest
        }
        let output: [[String: Any]] = segments.compactMap { segment in
            guard let index = segment["index"] as? Int else { return nil }
            return [
                "index": index,
                "cleanedText": "Cleaned segment \(index)",
            ]
        }
        let response = try JSONSerialization.data(withJSONObject: ["segments": output])
        return String(decoding: response, as: UTF8.self)
    }
}

private actor EllipsisCleanupClient: CloudModelClient {
    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        """
        {"segments":[{"index":1,"cleanedText":" . . . "}]}
        """
    }
}

private actor MisalignedCleanupClient: CloudModelClient {
    private(set) var callCount = 0

    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        callCount += 1
        return """
        {"segments":[{"index":2,"cleanedText":"Unsafe"},{"index":1,"cleanedText":"Unsafe"}]}
        """
    }
}

private actor CancellingCleanupClient: CloudModelClient {
    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        throw CancellationError()
    }
}
