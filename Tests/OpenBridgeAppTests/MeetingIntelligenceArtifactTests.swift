import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingIntelligenceArtifactTests {
    private let configuration = ProviderConfiguration(
        preset: .deepSeek,
        baseURL: URL(string: "https://api.deepseek.com")!,
        model: "deepseek-v4-flash",
        timeout: 30
    )

    @Test func legacyMeetingsCannotGainPostMeetingActions() async throws {
        var fixture = try makeMeeting()
        fixture.manifest.intelligenceConfiguration = nil
        let client = IntelligenceResponseClient(response: #"{"summary":"Should not run"}"#)
        let service = CloudMeetingIntelligenceService(
            authorizationGate: IntelligenceRecordingGate(configuration: configuration),
            modelClient: client
        )

        await #expect(throws: MeetingIntelligenceArtifactError.legacyMeeting) {
            _ = try await service.summarize(meeting: fixture.manifest, providerWasTested: true)
        }
        #expect(await client.callCount == 0)
    }

    @Test func summaryUsesExplicitGateAndCarriesFingerprintAndProvenance() async throws {
        let fixture = try makeMeeting()
        let gate = IntelligenceRecordingGate(configuration: configuration)
        let client = IntelligenceResponseClient(response: #"{"summary":"The team approved the launch."}"#)
        let generatedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let service = CloudMeetingIntelligenceService(
            authorizationGate: gate,
            modelClient: client,
            now: { generatedAt }
        )

        let artifact = try await service.summarize(
            meeting: fixture.manifest,
            providerWasTested: true
        )

        #expect(artifact.text == "The team approved the launch.")
        #expect(artifact.createdAt == generatedAt)
        #expect(artifact.sourceTranscriptFingerprint == MeetingTranscriptFingerprint.make(for: fixture.manifest.segments))
        #expect(artifact.provenance == MeetingIntelligenceProvenance(snapshot: fixture.snapshot))
        #expect(await gate.authorizationCount == 1)
        #expect(await gate.finishCount == 1)
        #expect(await client.callCount == 1)
    }

    @Test func incompleteMeetingsCannotSendPartialLiveTranscript() async throws {
        var fixture = try makeMeeting()
        fixture.manifest.state = .recoveryNeeded
        let client = IntelligenceResponseClient(response: #"{"summary":"Should not run"}"#)
        let service = CloudMeetingIntelligenceService(
            authorizationGate: IntelligenceRecordingGate(configuration: configuration),
            modelClient: client
        )

        await #expect(throws: MeetingIntelligenceArtifactError.meetingNotCompleted) {
            _ = try await service.summarize(meeting: fixture.manifest, providerWasTested: true)
        }
        #expect(await client.callCount == 0)
    }

    @Test func extractionRequiresRealSourceSegmentReferencesAndNormalizesOwners() async throws {
        let fixture = try makeMeeting()
        let valid = IntelligenceResponseClient(response: """
            {"actions":[{"description":"Send the launch note","assignee":"   ","supportingSegmentIDs":["segment-1"]}],"decisions":[{"summary":"Launch Friday","supportingSegmentIDs":["segment-2"]}]}
            """)
        let service = CloudMeetingIntelligenceService(
            authorizationGate: IntelligenceRecordingGate(configuration: configuration),
            modelClient: valid
        )
        let artifact = try await service.extractActionsAndDecisions(
            meeting: fixture.manifest,
            providerWasTested: true
        )
        #expect(artifact.actions.first?.assignee == nil)
        #expect(artifact.actions.first?.supportingSegmentIDs == ["segment-1"])
        #expect(artifact.decisions.first?.supportingSegmentIDs == ["segment-2"])

        let invalid = CloudMeetingIntelligenceService(
            authorizationGate: IntelligenceRecordingGate(configuration: configuration),
            modelClient: IntelligenceResponseClient(response: """
                {"actions":[],"decisions":[{"summary":"Invented","supportingSegmentIDs":["not-a-source"]}]}
                """)
        )
        await #expect(throws: MeetingIntelligenceArtifactError.unsupportedSegmentReference) {
            _ = try await invalid.extractActionsAndDecisions(
                meeting: fixture.manifest,
                providerWasTested: true
            )
        }
    }

    @Test func providerDriftAndUntestedProviderFailBeforeTranscriptReachesClient() async throws {
        let fixture = try makeMeeting()
        let client = IntelligenceResponseClient(response: #"{"summary":"Unsafe"}"#)
        let changed = ProviderConfiguration(
            preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/deepseek-v4-flash",
            timeout: 30
        )
        let service = CloudMeetingIntelligenceService(
            authorizationGate: IntelligenceRecordingGate(configuration: changed),
            modelClient: client
        )
        await #expect(throws: CloudRequestAuthorizationError.configurationChanged) {
            _ = try await service.summarize(meeting: fixture.manifest, providerWasTested: true)
        }
        #expect(await client.callCount == 0)

        await #expect(throws: MeetingIntelligenceArtifactError.providerNotTested) {
            _ = try await service.summarize(meeting: fixture.manifest, providerWasTested: false)
        }
        #expect(await client.callCount == 0)
    }

    @Test func cancellationReleasesTheCentralGate() async throws {
        let fixture = try makeMeeting()
        let gate = IntelligenceRecordingGate(configuration: configuration)
        let service = CloudMeetingIntelligenceService(
            authorizationGate: gate,
            modelClient: CancellingIntelligenceClient()
        )

        await #expect(throws: CancellationError.self) {
            _ = try await service.summarize(meeting: fixture.manifest, providerWasTested: true)
        }
        #expect(await gate.finishCount == 1)
    }

    @Test func sidecarIsAtomicPrivateExportedStaleAndRegeneratable() throws {
        var fixture = try makeMeeting()
        let first = MeetingSummaryArtifact(
            id: "summary-one",
            sourceTranscriptFingerprint: MeetingTranscriptFingerprint.make(for: fixture.manifest.segments),
            provenance: MeetingIntelligenceProvenance(snapshot: fixture.snapshot),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            text: "First summary"
        )
        let extraction = MeetingActionsDecisionsArtifact(
            id: "extract-one",
            sourceTranscriptFingerprint: first.sourceTranscriptFingerprint,
            provenance: first.provenance,
            createdAt: first.createdAt,
            actions: [],
            decisions: []
        )
        try fixture.store.saveSummary(first, meetingID: fixture.manifest.meetingID)
        try fixture.store.saveActionsAndDecisions(extraction, meetingID: fixture.manifest.meetingID)

        let sidecarURL = fixture.store.intelligenceSidecarURL(for: fixture.manifest.meetingID)
        let json = try String(contentsOf: sidecarURL)
        #expect(json.contains("First summary"))
        #expect(!json.contains("sk-cloud-secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)

        let replacement = MeetingSummaryArtifact(
            id: "summary-two",
            sourceTranscriptFingerprint: first.sourceTranscriptFingerprint,
            provenance: first.provenance,
            createdAt: first.createdAt.addingTimeInterval(10),
            text: "Replacement summary"
        )
        try fixture.store.saveSummary(replacement, meetingID: fixture.manifest.meetingID)
        #expect(try fixture.store.loadIntelligenceSidecar(meetingID: fixture.manifest.meetingID)?.summary?.id == "summary-two")

        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("intelligence-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let exported = try fixture.store.export(meetingID: fixture.manifest.meetingID, to: exportRoot)
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("intelligence.json").path))

        let markdown = MeetingIntelligenceArtifactExporter.summaryDocument(
            meeting: fixture.manifest,
            artifact: replacement
        )
        let markdownURL = exportRoot.appendingPathComponent(markdown.filename)
        try MeetingIntelligenceArtifactExporter.write(markdown, to: markdownURL)
        let markdownAttributes = try FileManager.default.attributesOfItem(atPath: markdownURL.path)
        #expect((markdownAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        fixture.manifest.segments.append(MeetingTranscriptSegment(
            id: "segment-3",
            meetingID: fixture.manifest.meetingID,
            sequence: 2,
            sourceLabel: "Room",
            text: "The canonical transcript changed.",
            isFinal: true
        ))
        try fixture.store.saveManifest(fixture.manifest)
        let saved = try #require(fixture.store.loadIntelligenceSidecar(meetingID: fixture.manifest.meetingID)?.summary)
        #expect(saved.isStale(for: fixture.manifest))
    }

    @Test func failedRegenerationPreservesOldOutputAndDeletionRemovesSidecarWithMeeting() async throws {
        let fixture = try makeMeeting()
        let prior = MeetingSummaryArtifact(
            id: "safe-existing",
            sourceTranscriptFingerprint: MeetingTranscriptFingerprint.make(for: fixture.manifest.segments),
            provenance: MeetingIntelligenceProvenance(snapshot: fixture.snapshot),
            createdAt: Date(),
            text: "Keep me"
        )
        try fixture.store.saveSummary(prior, meetingID: fixture.manifest.meetingID)
        let malformed = CloudMeetingIntelligenceService(
            authorizationGate: IntelligenceRecordingGate(configuration: configuration),
            modelClient: IntelligenceResponseClient(response: "not json")
        )
        await #expect(throws: MeetingIntelligenceArtifactError.malformedResponse) {
            _ = try await malformed.summarize(meeting: fixture.manifest, providerWasTested: true)
        }
        let preserved = try fixture.store.loadIntelligenceSidecar(meetingID: fixture.manifest.meetingID)?.summary
        #expect(preserved?.id == prior.id)
        #expect(preserved?.text == prior.text)
        #expect(preserved?.sourceTranscriptFingerprint == prior.sourceTranscriptFingerprint)

        try fixture.store.deleteIntelligenceArtifact(.summary, meetingID: fixture.manifest.meetingID)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.intelligenceSidecarURL(for: fixture.manifest.meetingID).path))
        try fixture.store.saveSummary(prior, meetingID: fixture.manifest.meetingID)
        try fixture.store.delete(meetingID: fixture.manifest.meetingID)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.meetingDirectory(for: fixture.manifest.meetingID).path))
    }

    private func makeMeeting() throws -> (
        store: MeetingSessionStore,
        manifest: MeetingManifest,
        snapshot: MeetingCloudProviderSnapshot
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-intelligence-test-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let meetingID = UUID().uuidString
        let snapshot = MeetingCloudProviderSnapshot(
            preset: configuration.preset,
            endpoint: configuration.baseURL,
            model: configuration.model,
            timeout: configuration.timeout
        )
        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Build 19 meeting",
            state: .completed,
            aiMode: .cloudOptIn,
            segments: [
                MeetingTranscriptSegment(
                    id: "segment-1",
                    meetingID: meetingID,
                    sequence: 0,
                    sourceLabel: "Room",
                    text: "The team approved the Friday launch.",
                    isFinal: true
                ),
                MeetingTranscriptSegment(
                    id: "segment-2",
                    meetingID: meetingID,
                    sequence: 1,
                    sourceLabel: "Room",
                    text: "Morgan will send the launch note.",
                    isFinal: true
                ),
            ],
            privacySettings: MeetingPrivacySettings(
                allowsLocalIntelligence: true,
                allowsCloudIntelligence: true
            ),
            intelligenceConfiguration: MeetingIntelligenceConfiguration(
                cleanupEnabled: false,
                cleanupProvider: .localGemma,
                cloudProvider: snapshot
            )
        )
        try store.create(manifest)
        return (store, manifest, snapshot)
    }
}

private actor IntelligenceRecordingGate: CloudRequestAuthorizing {
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

private actor IntelligenceResponseClient: CloudModelClient {
    let response: String
    private(set) var callCount = 0

    init(response: String) {
        self.response = response
    }

    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        callCount += 1
        return response
    }
}

private actor CancellingIntelligenceClient: CloudModelClient {
    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        throw CancellationError()
    }
}
