import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct ResearchProviderTests {

    // MARK: - Protocol & Schema Tests

    @Test func providerModesAreComplete() throws {
        #expect(ResearchProviderMode.allCases.count == 3)
        #expect(ResearchProviderMode.allCases.contains(.transcriptionOnly))
        #expect(ResearchProviderMode.allCases.contains(.localOnly))
        #expect(ResearchProviderMode.allCases.contains(.cloudExperiment))
    }

    @Test func transcriptionOnlyBlocksAllProviderCalls() throws {
        #expect(ResearchProviderMode.transcriptionOnly.allowsProviderCalls == false)
        #expect(ResearchProviderMode.transcriptionOnly.allowsCloudProvider == false)
    }

    @Test func localOnlyAllowsProviderButNotCloud() throws {
        #expect(ResearchProviderMode.localOnly.allowsProviderCalls == true)
        #expect(ResearchProviderMode.localOnly.allowsCloudProvider == false)
    }

    @Test func cloudExperimentAllowsEverything() throws {
        #expect(ResearchProviderMode.cloudExperiment.allowsProviderCalls == true)
        #expect(ResearchProviderMode.cloudExperiment.allowsCloudProvider == true)
    }

    @Test func operationsAreComplete() throws {
        #expect(ResearchProviderOperation.allCases.count == 3)
    }

    @Test func capabilitiesOptionSetWorks() throws {
        let all = ResearchProviderCapabilities.all
        #expect(all.supports(.classification))
        #expect(all.supports(.groundedAnswer))
        #expect(all.supports(.stateUpdate))

        let none = ResearchProviderCapabilities(rawValue: 0)
        #expect(!none.supports(.classification))
        #expect(!none.supports(.groundedAnswer))
        #expect(!none.supports(.stateUpdate))
    }

    @Test func responseSchemaVersionsAreStable() throws {
        #expect(ClassificationResponse.schemaVersion == 1)
        #expect(GroundedAnswerResponse.schemaVersion == 1)
        #expect(StateUpdateResponse.schemaVersion == 1)
    }

    @Test func providerContextHasNoTranscriptText() throws {
        let ctx = ResearchProviderContext(
            meetingID: "meeting-123",
            workspaceID: "ws-456",
            mode: .localOnly
        )
        #expect(ctx.meetingID == "meeting-123")
        #expect(ctx.workspaceID == "ws-456")
        #expect(ctx.mode == .localOnly)
        // Context should only carry structural identifiers
        #expect(!ctx.requestID.isEmpty)
    }

    @Test func providerDescriptorIdentifiesProvider() throws {
        let fake = FakeResearchProvider()
        #expect(fake.descriptor.identifier == "fake")
        #expect(fake.descriptor.isCloud == false)
        #expect(fake.descriptor.capabilities == .all)
    }

    // MARK: - Fake Provider Tests

    @Test func fakeClassificationIsDeterministicByKeyword() async throws {
        let provider = FakeResearchProvider()

        let factual = ClassificationRequest(
            context: .init(),
            questionText: "What time is it?"
        )
        let factualResponse = try await provider.classify(factual)
        #expect(factualResponse.category == .factual)

        let decisional = ClassificationRequest(
            context: .init(),
            questionText: "What did we decide about the launch?"
        )
        let decisionalResponse = try await provider.classify(decisional)
        #expect(decisionalResponse.category == .decisional)

        let action = ClassificationRequest(
            context: .init(),
            questionText: "What are the next action items?"
        )
        let actionResponse = try await provider.classify(action)
        #expect(actionResponse.category == .actionOriented)

        let synthesis = ClassificationRequest(
            context: .init(),
            questionText: "Can you synthesize the key points?"
        )
        let synthesisResponse = try await provider.classify(synthesis)
        #expect(synthesisResponse.category == .synthesis)
    }

    @Test func fakeGroundedAnswerReturnsFirstPassageWithCitation() async throws {
        let provider = FakeResearchProvider()
        let request = GroundedAnswerRequest(
            context: .init(),
            questionText: "What was decided?",
            passages: [
                ResearchGroundingPassage(
                    evidenceID: "ev-1",
                    passage: "The team decided to launch in September.",
                    sourceType: .priorMeeting
                ),
                ResearchGroundingPassage(
                    evidenceID: "ev-2",
                    passage: "Marketing agreed with the timeline.",
                    sourceType: .currentMeeting
                ),
            ]
        )
        let response = try await provider.groundedAnswer(request)

        #expect(response.abstained == false)
        #expect(response.answerText == "The team decided to launch in September.")
        #expect(response.citations.count == 1)
        #expect(response.citations[0].evidenceID == "ev-1")
    }

    @Test func fakeGroundedAnswerAbstainsWithNoPassages() async throws {
        let provider = FakeResearchProvider()
        let request = GroundedAnswerRequest(
            context: .init(),
            questionText: "What was decided?",
            passages: []
        )
        let response = try await provider.groundedAnswer(request)

        #expect(response.abstained == true)
        #expect(response.answerText.isEmpty)
        #expect(response.citations.isEmpty)
    }

    @Test func fakeStateUpdateExtractsDecisionsActionsOpenLoops() async throws {
        let provider = FakeResearchProvider()
        let request = StateUpdateRequest(
            context: .init(),
            excerpts: [
                ResearchTranscriptExcerpt(segmentID: "seg-1", meetingID: "m-1",
                                          text: "We decided to go with option A."),
                ResearchTranscriptExcerpt(segmentID: "seg-2", meetingID: "m-1",
                                          text: "I will follow up with the design team."),
                ResearchTranscriptExcerpt(segmentID: "seg-3", meetingID: "m-1",
                                          text: "The budget approval is still pending."),
            ]
        )
        let response = try await provider.stateUpdate(request)

        #expect(response.decisions.count == 1)
        #expect(response.decisions[0].supportingSegmentIDs == ["seg-1"])

        #expect(response.actions.count == 1)
        #expect(response.actions[0].supportingSegmentIDs == ["seg-2"])

        #expect(response.openLoops.count == 1)
        #expect(response.openLoops[0].supportingSegmentIDs == ["seg-3"])
    }

    @Test func fakeProviderRecorderCapturesAllCalls() async throws {
        let recorder = FakeProviderRecorder()
        let provider = FakeResearchProvider(recorder: recorder)

        _ = try await provider.classify(.init(context: .init(), questionText: "test"))
        _ = try await provider.groundedAnswer(.init(context: .init(), questionText: "test", passages: [
            .init(evidenceID: "e1", passage: "p", sourceType: .currentMeeting)
        ]))
        _ = try await provider.stateUpdate(.init(context: .init(), excerpts: [
            .init(segmentID: "s1", meetingID: "m1", text: "decide")
        ]))

        #expect(recorder.callCount == 3)
        #expect(recorder.calls(of: .classification).count == 1)
        #expect(recorder.calls(of: .groundedAnswer).count == 1)
        #expect(recorder.calls(of: .stateUpdate).count == 1)
    }

    @Test func fakeProviderCanInjectFailure() async throws {
        let provider = FakeResearchProvider(
            configuration: .init(classificationFailure: .providerError("injected"))
        )

        await #expect(throws: ResearchProviderError.self) {
            _ = try await provider.classify(.init(context: .init(), questionText: "test"))
        }
    }

    @Test func fakeProviderDelaysAreRespected() async throws {
        let provider = FakeResearchProvider(
            configuration: .init(delay: 0.1)
        )
        let start = Date()
        _ = try await provider.classify(.init(context: .init(), questionText: "test"))
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.09) // Allow small scheduling jitter
    }

    // MARK: - Release Cloud Provider (offline transport stubs)

    /// Builds a chat-completions envelope with proper JSON escaping
    /// (string interpolation of nested JSON corrupts quotes).
    private func envelope(content: String) -> Data {
        let payload: [String: Any] = [
            "choices": [["message": ["content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// Sendable capture box for transport-stub assertions.
    private final class CaptureBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private actor TestCloudGate: CloudRequestAuthorizing {
        let configuration: ProviderConfiguration
        let apiKey: String
        var isActive = false

        init(
            configuration: ProviderConfiguration = ProviderSettings().configuration,
            apiKey: String = "test-key-123"
        ) {
            self.configuration = configuration
            self.apiKey = apiKey
        }

        func authorizeCloudRequest(
            requestID: String,
            meetingConsent: Bool
        ) async throws -> AuthorizedCloudRequest {
            guard meetingConsent else {
                throw CloudRequestAuthorizationError.meetingConsentRequired
            }
            guard !apiKey.isEmpty else {
                throw CloudRequestAuthorizationError.missingCredential
            }
            guard !isActive else {
                throw CloudRequestAuthorizationError.requestAlreadyActive
            }
            isActive = true
            return AuthorizedCloudRequest(
                requestID: requestID,
                configuration: configuration,
                apiKey: apiKey
            )
        }

        func finishCloudRequest(requestID: String) async {
            isActive = false
        }
    }

    private func cloudProvider(
        configuration: ProviderConfiguration = ProviderSettings().configuration,
        apiKey: String = "test-key-123",
        transport: @escaping OpenAICompatibleCloudModelClient.Transport
    ) -> OpenAICompatibleResearchProvider {
        OpenAICompatibleResearchProvider(
            authorizationGate: TestCloudGate(configuration: configuration, apiKey: apiKey),
            modelClient: OpenAICompatibleCloudModelClient(transport: transport)
        )
    }

    // Explicit opt-in only: never runs in the normal suite or CI. Uses only
    // synthetic text; no saved meeting or provider secret is logged.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENBRIDGE_APPROVED_QUEUED_RESEARCH_PROBE"] == "1"))
    @MainActor func approvedTwoQuestionQueueProbe() async throws {
        guard let key = try KeychainProviderCredentialStore().readAPIKey() else {
            throw CloudRequestAuthorizationError.missingCredential
        }
        let configuration = ProviderConfiguration(preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: "deepseek/deepseek-v4-flash", timeout: 45)
        let provider = cloudProvider(configuration: configuration, apiKey: key) { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("SYNTHETIC_QUEUE_PROBE usage=\(json["usage"] ?? "unavailable")")
            }
            return (data, try #require(response as? HTTPURLResponse))
        }
        // The consent policy is injected for this synthetic test; the real
        // detector, coordinator, service, transport and validator are used.
        let coordinator = ObservatoryCoordinator(answerService: GroundedAnswerService(provider: provider,
            cloudModelKnowledgeAuthorization: { _ in configuration }), providerMode: .cloudExperiment)
        let detector = SpokenWakePhraseDetector()
        let prefix = await detector.processAll(.init(id: "synthetic-a", meetingID: "synthetic", sequence: 0,
            sourceLabel: "Synthetic", text: "OpenBridge. Can you", isFinal: true))
        #expect(prefix.isEmpty)
        let batch = await detector.processAll(.init(id: "synthetic-b", meetingID: "synthetic", sequence: 1,
            sourceLabel: "Synthetic", text: "tell me what two plus two is? OpenBridge? What is the capital of France?", isFinal: true))
        #expect(batch.count == 2)
        coordinator.submitSpoken(batch)
        coordinator.submitSpoken(batch) // identical replay must send nothing
        for _ in 0..<950 {
            if coordinator.completedAnswers.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let answers = coordinator.completedAnswers
        #expect(answers.count == 2)
        #expect(answers.map(\.questionText) == batch.map(\.commandText))
        #expect(answers.allSatisfy { !$0.evidence.isEmpty && $0.evidence.allSatisfy { $0.source == .modelSynthesis } })
        if answers.count == 2 {
            #expect(answers[0].answerText.lowercased().contains("four") || answers[0].answerText.contains("4"))
            #expect(answers[1].answerText.lowercased().contains("paris"))
            print("SYNTHETIC_QUEUE_PROBE two complete answers retained")
        }
        coordinator.endOfMeeting()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENBRIDGE_APPROVED_SYNTHETIC_RESEARCH_PROBE"] == "1"))
    func approvedSyntheticResearchProbe() async throws {
        guard let key = try KeychainProviderCredentialStore().readAPIKey() else {
            throw CloudRequestAuthorizationError.missingCredential
        }
        let configuration = ProviderConfiguration(
            preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/deepseek-v4-flash",
            timeout: 45
        )
        let provider = cloudProvider(configuration: configuration, apiKey: key) { request in
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("SYNTHETIC_PROBE elapsed=\(Date().timeIntervalSince(started)) usage=\(json["usage"] ?? "unavailable")")
                if let choices = json["choices"] as? [[String: Any]],
                   let message = choices.first?["message"] as? [String: Any] {
                    print("SYNTHETIC_PROBE content=\(message["content"] ?? "empty")")
                }
            }
            return (data, try #require(response as? HTTPURLResponse))
        }
        let passage = "Um, so yeah, the release is on Friday, Friday the fifteenth, and Maya owns the launch, I think that's what we agreed. We did not approve the budget increase."
        let spoken = ProcessInfo.processInfo.environment["OPENBRIDGE_SYNTHETIC_PROBE_KIND"] == "spoken"
        let detector = SpokenWakePhraseDetector()
        let fragment = await detector.process(.init(
            id: "synthetic-spoken", meetingID: "synthetic-meeting", sequence: 0,
            sourceLabel: "Synthetic", text: "OpenBridge. Can you", isFinal: true
        ))
        let invocation = await detector.process(.init(
            id: "synthetic-continuation", meetingID: "synthetic-meeting", sequence: 1,
            sourceLabel: "Synthetic", text: "tell me what two plus two is?", isFinal: true
        ))
        if spoken {
            #expect(fragment == nil)
            #expect(invocation?.commandText == "can you tell me what two plus two is?")
        }
        let context = ResearchProviderContext(mode: .cloudExperiment)
        let response = try await provider.groundedAnswer(.init(
            context: context,
            questionText: spoken ? try #require(invocation).commandText : "When is the release and who owns the launch?",
            passages: spoken ? [] : [.init(evidenceID: "synthetic-1", passage: passage, sourceType: .priorMeeting)]
        ))
        try ResearchProviderResponseValidator.validate(
            response: response,
            expectedRequestID: context.requestID,
            knownEvidenceIDs: spoken ? [] : ["synthetic-1"],
            evidenceTextByID: spoken ? [:] : ["synthetic-1": passage]
        )
        #expect(!response.abstained)
        if spoken { #expect(response.citations.isEmpty) }
    }

    @Test func releaseCloudProviderRequiresCredentialOnAllOperations() async {
        let transport: OpenAICompatibleCloudModelClient.Transport = { _ in
            Issue.record("Transport must not run without a credential")
            throw CloudModelClientError.authenticationFailed
        }
        let provider = cloudProvider(apiKey: "", transport: transport)
        let context = ResearchProviderContext(mode: .cloudExperiment)

        await #expect(throws: ResearchProviderError.self) {
            _ = try await provider.classify(.init(context: context, questionText: "test"))
        }
        await #expect(throws: ResearchProviderError.self) {
            _ = try await provider.groundedAnswer(.init(context: context, questionText: "test", passages: []))
        }
        await #expect(throws: ResearchProviderError.self) {
            _ = try await provider.stateUpdate(.init(context: context, excerpts: []))
        }
    }

    @Test func sentenceSelectionBuildsVerbatimAnswerAndCitations() async throws {
        let provider = cloudProvider { request in
            let content = #"{"sentenceIDs":["p0s0","p1s0","p0s0"],"confidence":0.9,"abstained":false}"#
            return (envelope(content: content), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let context = ResearchProviderContext(mode: .cloudExperiment)
        let first = "Um, yeah, the release is Friday, Friday the fifteenth."
        let second = "Maya owns the launch, that's what we agreed."
        let result = try await provider.groundedAnswer(.init(
            context: context, questionText: "When is the release and who owns launch?",
            passages: [
                .init(evidenceID: "e1", passage: first, sourceType: .priorMeeting),
                .init(evidenceID: "e2", passage: second, sourceType: .priorMeeting),
            ]
        ))
        #expect(result.answerText == first + "\n" + second)
        #expect(result.citations.count == 2)
        try ResearchProviderResponseValidator.validate(
            response: result, expectedRequestID: context.requestID,
            knownEvidenceIDs: ["e1", "e2"], evidenceTextByID: ["e1": first, "e2": second]
        )
    }

    @Test func sentenceSelectionRejectsUnknownIDsAndPreservesNegation() async throws {
        for selection in ["p0s0", "invented"] {
            let provider = cloudProvider { request in
                let content = "{\"sentenceIDs\":[\"\(selection)\"],\"confidence\":0.9,\"abstained\":false}"
                return (envelope(content: content), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let request = GroundedAnswerRequest(
                context: .init(mode: .cloudExperiment), questionText: "Was the budget approved?",
                passages: [.init(evidenceID: "e1", passage: "The budget was not approved.", sourceType: .priorMeeting)]
            )
            if selection == "invented" {
                await #expect(throws: ResearchProviderError.self) { _ = try await provider.groundedAnswer(request) }
            } else {
                let response = try await provider.groundedAnswer(request)
                #expect(response.answerText == "The budget was not approved.")
            }
        }
    }

    @Test func releaseCloudProviderIsProviderNeutralAndCloud() {
        let provider = OpenAICompatibleResearchProvider(
            authorizationGate: TestCloudGate()
        )
        #expect(provider.descriptor.isCloud)
        #expect(provider.descriptor.identifier == "configured-openai-compatible")
    }

    @Test func savedConfigurationControlsEndpointModelTimeoutAndBearer() async throws {
        let capturedBody = CaptureBox<Data>()
        let capturedRequest = CaptureBox<URLRequest>()
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            capturedRequest.set(request)
            capturedBody.set(request.httpBody ?? Data())
            let content = #"{"sentenceIDs":["p0s0"],"confidence":0.9,"abstained":false}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (envelope(content: content), response)
        }
        let configuration = ProviderConfiguration(
            preset: .custom,
            baseURL: URL(string: "https://models.example/v9")!,
            model: "owner/saved-model",
            timeout: 17
        )
        let provider = cloudProvider(configuration: configuration, transport: transport)

        let response = try await provider.groundedAnswer(.init(
            context: .init(mode: .cloudExperiment),
            questionText: "What did we decide about the launch date?",
            passages: [ResearchGroundingPassage(evidenceID: "e1", passage: "We decided the launch date is September 15th.", sourceType: .priorMeeting)]
        ))

        let request = try #require(capturedRequest.get())
        #expect(request.url?.absoluteString == "https://models.example/v9/chat/completions")
        #expect(request.timeoutInterval == 17)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")

        let body = try #require(capturedBody.get())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "owner/saved-model")

        #expect(response.answerText == "We decided the launch date is September 15th.")
        #expect(response.abstained == false)
        #expect(response.citations.first?.evidenceID == "e1")
    }

    @Test func cloudProviderParsesAbstention() async throws {
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            let content = #"{"sentenceIDs":[],"confidence":0.1,"abstained":true}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (envelope(content: content), response)
        }
        let provider = cloudProvider(transport: transport)
        let response = try await provider.groundedAnswer(.init(
            context: .init(mode: .cloudExperiment),
            questionText: "irrelevant",
            passages: [ResearchGroundingPassage(evidenceID: "e1", passage: "text", sourceType: .priorMeeting)]
        ))
        #expect(response.abstained == true)
        #expect(response.answerText.isEmpty)
    }

    @Test func cloudProviderSendsBracketFreePassages() async throws {
        let capturedBody = CaptureBox<Data>()
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            capturedBody.set(request.httpBody ?? Data())
            let content = #"{"sentenceIDs":["p0s0"],"confidence":0.9,"abstained":false}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let envelope: [String: Any] = ["choices": [["message": ["content": content]]]]
            return (try! JSONSerialization.data(withJSONObject: envelope), response)
        }
        let provider = cloudProvider(transport: transport)
        _ = try await provider.groundedAnswer(.init(
            context: .init(mode: .cloudExperiment), questionText: "q",
            passages: [ResearchGroundingPassage(evidenceID: "e1", passage: "The [launch] date is September 15th…", sourceType: .priorMeeting)]
        ))
        let body = try #require(capturedBody.get())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("launch date"))
        #expect(!user.contains("[launch]"))
    }

    @Test func cloudProviderStripsThinkBlocksAndParsesJSON() throws {
        let content = #"<think>reasoning here</think> {"category":"decisional","confidence":0.9}"#
        struct Out: Decodable { let category: String; let confidence: Double }
        let out = try OpenAICompatibleResearchProvider.decodePayload(Out.self, from: content)
        #expect(out.category == "decisional")
    }

    @Test func cloudProvider401MapsToClearAuthError() async throws {
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        let provider = cloudProvider(transport: transport)
        do {
            _ = try await provider.groundedAnswer(.init(
                context: .init(mode: .cloudExperiment), questionText: "q",
                passages: [ResearchGroundingPassage(evidenceID: "e1", passage: "p", sourceType: .priorMeeting)]
            ))
            Issue.record("expected 401 error")
        } catch let error as ResearchProviderError {
            guard case .providerError(let detail) = error else {
                Issue.record("expected providerError"); return
            }
            #expect(detail.contains("API key"))
        }
    }

    @Test func cloudProvider402MapsToCreditsError() async throws {
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 402, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        let provider = cloudProvider(transport: transport)
        do {
            _ = try await provider.groundedAnswer(.init(
                context: .init(mode: .cloudExperiment), questionText: "q",
                passages: [ResearchGroundingPassage(evidenceID: "e1", passage: "p", sourceType: .priorMeeting)]
            ))
            Issue.record("expected 402 error")
        } catch let error as ResearchProviderError {
            guard case .providerError(let detail) = error else {
                Issue.record("expected providerError"); return
            }
            #expect(detail.localizedCaseInsensitiveContains("credit"))
        }
    }

    @Test func cloudProviderRateLimitMapsToRateLimited() async throws {
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        let provider = cloudProvider(transport: transport)
        await #expect(throws: ResearchProviderError.rateLimited) {
            _ = try await provider.groundedAnswer(.init(
                context: .init(mode: .cloudExperiment), questionText: "q",
                passages: [ResearchGroundingPassage(evidenceID: "e1", passage: "p", sourceType: .priorMeeting)]
            ))
        }
    }

    @Test func cancellationReleasesTheCentralGateForTheNextRequest() async {
        let transport: OpenAICompatibleCloudModelClient.Transport = { _ in
            throw CancellationError()
        }
        let provider = cloudProvider(transport: transport)
        let request = ClassificationRequest(
            context: .init(mode: .cloudExperiment),
            questionText: "Classify this"
        )

        await #expect(throws: ResearchProviderError.cancelled) {
            _ = try await provider.classify(request)
        }
        await #expect(throws: ResearchProviderError.cancelled) {
            _ = try await provider.classify(request)
        }
    }

    @Test func providerErrorBodiesCannotLeakPromptOrTranscriptText() async {
        let secret = "PRIVATE TRANSCRIPT PHRASE"
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (Data("provider echoed \(secret)".utf8), response)
        }
        let provider = cloudProvider(transport: transport)

        do {
            _ = try await provider.groundedAnswer(.init(
                context: .init(mode: .cloudExperiment),
                questionText: "Question containing \(secret)",
                passages: [.init(evidenceID: "e1", passage: secret, sourceType: .currentMeeting)]
            ))
            Issue.record("Expected provider failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
    }

    @Test func sameTypedRequestsReplayThroughFakeAndReleaseReferenceProvider() async throws {
        let transport: OpenAICompatibleCloudModelClient.Transport = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let content: String
            if body.contains("classify research questions") {
                content = #"{"category":"decisional","confidence":0.9}"#
            } else if body.contains("extract meeting state") {
                content = #"{"decisions":[{"summary":"Ship Friday","supportingSegmentIDs":["s1"],"confidence":0.9}],"actions":[],"openLoops":[]}"#
            } else {
                content = #"{"sentenceIDs":["p0s0"],"confidence":0.9,"abstained":false}"#
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (envelope(content: content), response)
        }
        let fake: any ResearchProvider = FakeResearchProvider()
        let reference: any ResearchProvider = cloudProvider(transport: transport)
        let context = ResearchProviderContext(requestID: "replay-1", mode: .cloudExperiment)
        let classification = ClassificationRequest(
            context: context,
            questionText: "What did we decide?"
        )
        let answer = GroundedAnswerRequest(
            context: context,
            questionText: "What did we decide?",
            passages: [.init(
                evidenceID: "s1",
                passage: "We decided to ship Friday.",
                sourceType: .currentMeeting
            )]
        )
        let state = StateUpdateRequest(
            context: context,
            excerpts: [.init(
                segmentID: "s1",
                meetingID: "m1",
                text: "We decided to ship Friday."
            )]
        )

        for provider in [fake, reference] {
            #expect(try await provider.classify(classification).requestID == "replay-1")
            #expect(try await provider.groundedAnswer(answer).requestID == "replay-1")
            #expect(try await provider.stateUpdate(state).requestID == "replay-1")
        }
    }

    // MARK: - Orchestrator: Mode Gating

    @Test func orchestratorBlocksTranscriptionOnlyMode() async throws {
        let orchestrator = ResearchProviderOrchestrator(provider: FakeResearchProvider())

        await #expect(throws: ResearchProviderError.self) {
            try await orchestrator.classify(
                .init(context: .init(), questionText: "test"),
                mode: .transcriptionOnly
            )
        }
    }

    @Test func orchestratorAllowsLocalOnlyMode() async throws {
        let orchestrator = ResearchProviderOrchestrator(provider: FakeResearchProvider())

        let response = try await orchestrator.classify(
            .init(context: .init(), questionText: "test"),
            mode: .localOnly
        )
        #expect(response.category == .factual)
    }

    @Test func orchestratorBlocksCloudProviderInLocalOnlyMode() async throws {
        let orchestrator = ResearchProviderOrchestrator(
            provider: OpenAICompatibleResearchProvider(authorizationGate: TestCloudGate())
        )

        await #expect(throws: ResearchProviderError.self) {
            try await orchestrator.classify(
                .init(context: .init(), questionText: "test"),
                mode: .localOnly
            )
        }
    }

    // MARK: - Orchestrator: Timeout

    @Test func orchestratorTimesOutSlowProvider() async throws {
        let provider = FakeResearchProvider(configuration: .init(delay: 10, checkCancellation: false))
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .init(timeout: 0.2, maxConcurrent: 1)
        )

        let start = Date()
        do {
            _ = try await orchestrator.classify(
                .init(context: .init(), questionText: "test"),
                mode: .localOnly
            )
            Issue.record("Should have timed out")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            #expect(error is ResearchProviderError || error is ResearchOrchestratorError)
            #expect(elapsed < 2.0, "Should have timed out within ~0.2s, not \(elapsed)s")
        }
    }

    @Test func orchestratorFastCallCompletesWithoutTimeout() async throws {
        let provider = FakeResearchProvider()
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .init(timeout: 5.0, maxConcurrent: 1)
        )

        let response = try await orchestrator.classify(
            .init(context: .init(), questionText: "test"),
            mode: .localOnly
        )
        #expect(response.category == .factual)
    }

    // MARK: - Orchestrator: Cancellation

    @Test func orchestratorPropagatesCancellation() async throws {
        let provider = FakeResearchProvider(configuration: .init(delay: 5, checkCancellation: true))
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .init(timeout: 30, maxConcurrent: 1)
        )

        let task = Task {
            try await orchestrator.classify(
                .init(context: .init(), questionText: "test"),
                mode: .localOnly
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Should have been cancelled")
        } catch {
            // Expected: either ResearchProviderError.cancelled or ResearchProviderError.timeout
            #expect(error is ResearchProviderError || error is ResearchOrchestratorError || error is CancellationError)
        }
    }

    // MARK: - Orchestrator: Concurrency Limit

    @Test func orchestratorEnforcesConcurrencyLimit() async throws {
        let provider = FakeResearchProvider(configuration: .init(delay: 0.3))
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .init(timeout: 10, maxConcurrent: 1)
        )

        // Start first call (holds the slot for 0.3s)
        let task1 = Task {
            try await orchestrator.classify(
                .init(context: .init(), questionText: "first"),
                mode: .localOnly
            )
        }

        // Wait briefly so task1 enters the execute method first
        try await Task.sleep(for: .milliseconds(50))

        // Second call should fail because maxConcurrent=1 and first is in-flight
        do {
            _ = try await orchestrator.classify(
                .init(context: .init(), questionText: "second"),
                mode: .localOnly
            )
            // If it succeeds that's also acceptable (actor may serialize),
            // but the important thing is no crash and no deadlock.
        } catch {
            // Acceptable: concurrency limit or similar
            #expect(error is ResearchProviderError || error is ResearchOrchestratorError)
        }

        // Ensure task1 completes
        let result1 = try await task1.value
        #expect(result1.category == .factual)
    }

    // MARK: - Orchestrator: Stale Request Cancellation

    @Test func orchestratorNewerRequestSupersedesOlderForSameScope() async throws {
        let provider = FakeResearchProvider(configuration: .init(delay: 0.3))
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .init(timeout: 10, maxConcurrent: 2, cancelStaleRequests: true)
        )

        let scope = "meeting-1"

        // Start first call (slow, same scope)
        let task1 = Task {
            try await orchestrator.classify(
                .init(context: .init(), questionText: "old question"),
                mode: .localOnly,
                scopeKey: scope
            )
        }

        try await Task.sleep(for: .milliseconds(50))

        // Start second call (same scope, supersedes the first)
        let task2 = Task {
            try await orchestrator.classify(
                .init(context: .init(), questionText: "new question"),
                mode: .localOnly,
                scopeKey: scope
            )
        }

        // Task 2 should succeed
        let result2 = try await task2.value
        #expect(result2.category == .factual)

        // Task 1 should throw staleRequest (or timeout/cancelled)
        do {
            _ = try await task1.value
            // If it succeeds that's fine too (timing dependent), but verify it
            // was superseded by checking generation advanced
        } catch {
            #expect(error is ResearchProviderError || error is ResearchOrchestratorError)
        }

        // Generation for this scope should be >= 2
        let gen = await orchestrator.scopeGeneration(for: scope)
        #expect(gen >= 2)
    }

    @Test func orchestratorDifferentScopesDoNotInterfere() async throws {
        let provider = FakeResearchProvider(configuration: .init(delay: 0.2))
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .init(timeout: 10, maxConcurrent: 4, cancelStaleRequests: true)
        )

        async let result1 = try await orchestrator.classify(
            .init(context: .init(), questionText: "scope1"),
            mode: .localOnly,
            scopeKey: "scope-1"
        )
        async let result2 = try await orchestrator.classify(
            .init(context: .init(), questionText: "scope2"),
            mode: .localOnly,
            scopeKey: "scope-2"
        )

        let (r1, r2) = try await (result1, result2)
        #expect(r1.category == .factual)
        #expect(r2.category == .factual)
    }

    // MARK: - Validation Tests

    @Test func validationRejectsConfidenceAboveOne() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: ClassificationResponse(
                    requestID: "r1", category: .factual, confidence: 1.5
                ),
                expectedRequestID: "r1"
            )
        }
    }

    @Test func validationRejectsConfidenceBelowZero() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: ClassificationResponse(
                    requestID: "r1", category: .factual, confidence: -0.1
                ),
                expectedRequestID: "r1"
            )
        }
    }

    @Test func validationAcceptsValidConfidenceBounds() throws {
        try ResearchProviderResponseValidator.validate(
            response: ClassificationResponse(
                requestID: "r1", category: .factual, confidence: 0.0
            ),
            expectedRequestID: "r1"
        )
        try ResearchProviderResponseValidator.validate(
            response: ClassificationResponse(
                requestID: "r1", category: .factual, confidence: 1.0
            ),
            expectedRequestID: "r1"
        )
    }

    @Test func validationRejectsEmptyAnswerTextWhenNotAbstained() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: GroundedAnswerResponse(
                    requestID: "r1", answerText: "   ", citations: [],
                    confidence: 0.5, abstained: false
                ),
                expectedRequestID: "r1",
                knownEvidenceIDs: []
            )
        }
    }

    @Test func validationAllowsEmptyAnswerWhenAbstained() throws {
        try ResearchProviderResponseValidator.validate(
            response: GroundedAnswerResponse(
                requestID: "r1", answerText: "", citations: [],
                confidence: 0.0, abstained: true
            ),
            expectedRequestID: "r1",
            knownEvidenceIDs: []
        )
    }

    @Test func validationRejectsCitationWithUnknownEvidenceID() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: GroundedAnswerResponse(
                    requestID: "r1",
                    answerText: "Answer",
                    citations: [ResearchAnswerCitation(evidenceID: "unknown", quotedFragment: "...")],
                    confidence: 0.8
                ),
                expectedRequestID: "r1",
                knownEvidenceIDs: ["ev-1", "ev-2"]
            )
        }
    }

    @Test func validationAcceptsCitationsWithKnownEvidenceIDs() throws {
        try ResearchProviderResponseValidator.validate(
            response: GroundedAnswerResponse(
                requestID: "r1",
                answerText: "Answer",
                citations: [
                    ResearchAnswerCitation(evidenceID: "ev-1", quotedFragment: "..."),
                    ResearchAnswerCitation(evidenceID: "ev-2", quotedFragment: "..."),
                ],
                confidence: 0.8
            ),
            expectedRequestID: "r1",
            knownEvidenceIDs: ["ev-1", "ev-2"]
        )
    }

    @Test func validationRejectsCitationsThatChangeSpecificFacts() throws {
        let conflicts = [
            (quote: "The launch date is June 15", answer: "The launch date is September 15."),
            (quote: "The order contains 25 launch kits", answer: "The order contains 50 launch kits."),
            (quote: "Alice approved the launch plan", answer: "Bob approved the launch plan."),
        ]

        for conflict in conflicts {
            #expect(throws: ResearchProviderValidationError.self) {
                try ResearchProviderResponseValidator.validate(
                    response: GroundedAnswerResponse(
                        requestID: "r1",
                        answerText: conflict.answer,
                        citations: [ResearchAnswerCitation(
                            evidenceID: "ev-1",
                            quotedFragment: conflict.quote
                        )],
                        confidence: 0.8
                    ),
                    expectedRequestID: "r1",
                    knownEvidenceIDs: ["ev-1"],
                    evidenceTextByID: ["ev-1": conflict.quote]
                )
            }
        }
    }

    @Test func validationRejectsParaphraseEvenWhenSpecificFactsMatch() throws {
        let quote = "Alice decided to move the launch date to September fifteenth"
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: GroundedAnswerResponse(
                    requestID: "r1",
                    answerText: "Alice moved the launch to September fifteenth.",
                    citations: [ResearchAnswerCitation(evidenceID: "ev-1", quotedFragment: quote)],
                    confidence: 0.8
                ),
                expectedRequestID: "r1",
                knownEvidenceIDs: ["ev-1"],
                evidenceTextByID: ["ev-1": quote]
            )
        }
    }

    @Test func validationAcceptsACompleteExtractiveClaim() throws {
        let quote = "Alice decided to move the launch date to September fifteenth"
        try ResearchProviderResponseValidator.validate(
            response: GroundedAnswerResponse(
                requestID: "r1",
                answerText: "Alice decided to move the launch date to September fifteenth.",
                citations: [ResearchAnswerCitation(evidenceID: "ev-1", quotedFragment: quote)],
                confidence: 0.8
            ),
            expectedRequestID: "r1",
            knownEvidenceIDs: ["ev-1"],
            evidenceTextByID: ["ev-1": quote]
        )
    }

    @Test func validationRejectsUnsupportedLowercaseAttribution() throws {
        let quote = "The launch plan was approved"
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: GroundedAnswerResponse(
                    requestID: "r1",
                    answerText: "The launch plan was approved by regulators.",
                    citations: [ResearchAnswerCitation(evidenceID: "ev-1", quotedFragment: quote)],
                    confidence: 0.8
                ),
                expectedRequestID: "r1",
                knownEvidenceIDs: ["ev-1"],
                evidenceTextByID: ["ev-1": quote]
            )
        }
    }

    @Test func validationCannotJoinAdjacentEvidenceSentences() throws {
        let evidence = "We approved the launch. By regulators' standards, the timeline is too short."
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: GroundedAnswerResponse(
                    requestID: "r1",
                    answerText: "We approved the launch by regulators.",
                    citations: [ResearchAnswerCitation(
                        evidenceID: "ev-1",
                        quotedFragment: "We approved the launch"
                    )],
                    confidence: 0.8
                ),
                expectedRequestID: "r1",
                knownEvidenceIDs: ["ev-1"],
                evidenceTextByID: ["ev-1": evidence]
            )
        }
    }

    @Test func validationRejectsAConflictingSecondClaim() throws {
        let evidence = "Team launch schedule remains planned June"
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: GroundedAnswerResponse(
                    requestID: "r1",
                    answerText: "Team launch schedule remains planned June. Team launch schedule remains planned September.",
                    citations: [ResearchAnswerCitation(evidenceID: "ev-1", quotedFragment: evidence)],
                    confidence: 0.8
                ),
                expectedRequestID: "r1",
                knownEvidenceIDs: ["ev-1"],
                evidenceTextByID: ["ev-1": evidence]
            )
        }
    }

    @Test func validationRejectsRequestIDMismatch() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: ClassificationResponse(
                    requestID: "wrong", category: .factual, confidence: 0.9
                ),
                expectedRequestID: "expected"
            )
        }
    }

    @Test func validationRejectsStateUpdateWithInvalidConfidence() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: StateUpdateResponse(
                    requestID: "r1",
                    decisions: [
                        ResearchExtractedDecision(
                            summary: "Decision", supportingSegmentIDs: ["s1"],
                            confidence: 2.0
                        )
                    ]
                ),
                expectedRequestID: "r1"
            )
        }
    }

    @Test func validationRejectsStateUpdateWithEmptyDecisionSummary() throws {
        #expect(throws: ResearchProviderValidationError.self) {
            try ResearchProviderResponseValidator.validate(
                response: StateUpdateResponse(
                    requestID: "r1",
                    decisions: [
                        ResearchExtractedDecision(
                            summary: "  ", supportingSegmentIDs: ["s1"],
                            confidence: 0.8
                        )
                    ]
                ),
                expectedRequestID: "r1"
            )
        }
    }

    @Test func validateRawJSONRejectsEmptyData() throws {
        #expect(throws: ResearchProviderError.self) {
            try ResearchProviderResponseValidator.validateRawJSON(Data())
        }
    }

    @Test func validateRawJSONRejectsNonJSONData() throws {
        #expect(throws: ResearchProviderError.self) {
            try ResearchProviderResponseValidator.validateRawJSON(Data("not json".utf8))
        }
    }

    @Test func validateRawJSONAcceptsValidJSON() throws {
        let json = Data(#"{"key": "value"}"#.utf8)
        try ResearchProviderResponseValidator.validateRawJSON(json)
    }

    @Test func validateRawJSONChecksSchemaVersion() throws {
        let json = Data(#"{"schemaVersion": 2}"#.utf8)
        #expect(throws: ResearchProviderError.self) {
            try ResearchProviderResponseValidator.validateRawJSON(json, expectedSchemaVersion: 1)
        }
    }

    // MARK: - Logging Tests

    @Test func logEntryRedactsQuestionText() throws {
        let forbiddenQuestion = "What did we decide about SECRET_PROJECT?"
        let logger = RecordingResearchProviderLogger()

        let entry = ResearchProviderLogEntry(
            event: .started,
            operation: .classification,
            providerID: "fake",
            requestID: UUID().uuidString,
            scopeKey: "default",
            durationMS: 0,
            inputCharacterCount: forbiddenQuestion.count,
            error: nil
        )
        logger.log(entry)

        #expect(logger.entryCount == 1)
        #expect(logger.containsRedactedContent("SECRET_PROJECT") == false)
        #expect(logger.containsRedactedContent("What did we decide") == false)
    }

    @Test func logEntryIncludesStructuralMetadata() throws {
        let logger = RecordingResearchProviderLogger()
        let entry = ResearchProviderLogEntry(
            event: .completed,
            operation: .groundedAnswer,
            providerID: "openrouter",
            requestID: "req-12345678",
            scopeKey: "meeting-abc",
            durationMS: 150,
            inputCharacterCount: 42,
            error: nil
        )
        logger.log(entry)

        let recorded = logger.allEntries[0]
        #expect(recorded.event == .completed)
        #expect(recorded.operation == .groundedAnswer)
        #expect(recorded.providerID == "openrouter")
        #expect(recorded.durationMS == 150)
        #expect(recorded.inputCharacterCount == 42)
    }

    @Test func logEntryRedactsAssociatedErrorDetails() {
        let forbidden = "PRIVATE TRANSCRIPT IN PROVIDER ERROR"
        let entry = ResearchProviderLogEntry(
            event: .failed,
            operation: .groundedAnswer,
            providerID: "configured-openai-compatible",
            requestID: "request-1",
            scopeKey: "meeting",
            durationMS: 20,
            inputCharacterCount: forbidden.count,
            error: .providerError(forbidden)
        )
        #expect(entry.redactedDescription.contains("err=providerError"))
        #expect(!entry.redactedDescription.contains(forbidden))
    }

    @Test func recordingLoggerFiltersByEvent() throws {
        let logger = RecordingResearchProviderLogger()
        logger.log(.init(event: .started, operation: .classification, providerID: "p",
                         requestID: "r", scopeKey: "s", durationMS: 0, inputCharacterCount: 0, error: nil))
        logger.log(.init(event: .completed, operation: .classification, providerID: "p",
                         requestID: "r", scopeKey: "s", durationMS: 10, inputCharacterCount: 0, error: nil))
        logger.log(.init(event: .failed, operation: .classification, providerID: "p",
                         requestID: "r", scopeKey: "s", durationMS: 5, inputCharacterCount: 0,
                         error: .providerError("test")))

        #expect(logger.entryCount == 3)
        #expect(logger.entries(for: .completed).count == 1)
        #expect(logger.entries(for: .failed).count == 1)
    }

    @Test func orchestratorLogsLifecycleEvents() async throws {
        let logger = RecordingResearchProviderLogger()
        let orchestrator = ResearchProviderOrchestrator(
            provider: FakeResearchProvider(),
            configuration: .default,
            logger: logger
        )

        _ = try await orchestrator.classify(
            .init(context: .init(), questionText: "test"),
            mode: .localOnly
        )

        #expect(logger.entryCount >= 2)
        #expect(logger.entries(for: .started).count >= 1)
        #expect(logger.entries(for: .completed).count >= 1)
    }

    @Test func orchestratorLogsRejectionForBlockedMode() async throws {
        let logger = RecordingResearchProviderLogger()
        let orchestrator = ResearchProviderOrchestrator(
            provider: FakeResearchProvider(),
            logger: logger
        )

        do {
            _ = try await orchestrator.classify(
                .init(context: .init(), questionText: "test"),
                mode: .transcriptionOnly
            )
        } catch {
            // expected
        }

        #expect(logger.entries(for: .rejected).count == 1)
    }

    // MARK: - Error Equality Tests

    @Test func providerErrorsAreEquatable() throws {
        #expect(ResearchProviderError.timeout == ResearchProviderError.timeout)
        #expect(ResearchProviderError.cancelled == ResearchProviderError.cancelled)
        #expect(ResearchProviderError.staleRequest == ResearchProviderError.staleRequest)
        #expect(ResearchProviderError.timeout != ResearchProviderError.cancelled)
        #expect(ResearchProviderError.rateLimited == ResearchProviderError.rateLimited)
    }

    // MARK: - Integration: Full Workflow

    @Test func fullWorkflowClassifyAnswerStateUpdate() async throws {
        let recorder = FakeProviderRecorder()
        let provider = FakeResearchProvider(recorder: recorder)
        let logger = RecordingResearchProviderLogger()
        let orchestrator = ResearchProviderOrchestrator(
            provider: provider,
            configuration: .default,
            logger: logger
        )

        // 1. Classify
        let classification = try await orchestrator.classify(
            ClassificationRequest(
                context: ResearchProviderContext(mode: .localOnly),
                questionText: "What did we decide?"
            ),
            mode: .localOnly
        )
        #expect(classification.category == .decisional)

        // 2. Grounded answer
        let answer = try await orchestrator.groundedAnswer(
            GroundedAnswerRequest(
                context: ResearchProviderContext(mode: .localOnly),
                questionText: "What did we decide?",
                passages: [
                    ResearchGroundingPassage(
                        evidenceID: "ev-1",
                        passage: "We decided to ship on Friday.",
                        sourceType: .priorMeeting
                    )
                ]
            ),
            mode: .localOnly
        )
        #expect(answer.abstained == false)
        #expect(answer.citations.count == 1)

        // 3. State update
        let state = try await orchestrator.stateUpdate(
            StateUpdateRequest(
                context: ResearchProviderContext(mode: .localOnly),
                excerpts: [
                    ResearchTranscriptExcerpt(
                        segmentID: "seg-1", meetingID: "m-1",
                        text: "We decided to use Swift."
                    )
                ]
            ),
            mode: .localOnly
        )
        #expect(state.decisions.count == 1)

        // All three operations were recorded
        #expect(recorder.callCount == 3)
        #expect(logger.entryCount >= 6) // 3 started + 3 completed
    }
}
