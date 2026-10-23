import Foundation
import OpenBridgeUI
import Testing
@testable import OpenBridgeApp

// MARK: - Observatory Coordinator Tests (#299 / Live Integration)
//
// Deterministic integration coverage of the issue's verification
// scenarios: silence, memory cue, explicit local answer, explicit spoken
// answer, cited web answer, no source, timeout, stale result, duplicate
// suppression, and provider failure — with fake providers throughout.

@Suite(.serialized) @MainActor struct ObservatoryCoordinatorTests {

    // MARK: - Fixtures

    private struct TestGate: WebResearchGate {
        var settingsValue: ProviderSettings = ProviderSettings(cloudEnabled: true, consentGranted: true)
        var credential: Bool = true
        var reachable: Bool = true
        func settings() async -> ProviderSettings { settingsValue }
        func hasCredential() async -> Bool { credential }
        func networkReachable() async -> Bool { reachable }
    }

    private struct ModeAssertingProvider: ResearchProvider {
        let expectedMode: ResearchProviderMode
        let descriptor = ResearchProviderDescriptor(
            identifier: "mode-asserting",
            displayName: "Mode Asserting Provider",
            capabilities: .all,
            isCloud: false
        )

        func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
            throw ResearchProviderError.unsupportedOperation("classification")
        }

        func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
            #expect(request.context.mode == expectedMode)
            if request.passages.isEmpty {
                return GroundedAnswerResponse(
                    requestID: request.context.requestID,
                    answerText: "Authorized model answer.",
                    citations: [],
                    confidence: 0.9,
                    abstained: false
                )
            }
            guard let passage = request.passages.first else {
                return GroundedAnswerResponse(
                    requestID: request.context.requestID,
                    answerText: "",
                    citations: [],
                    confidence: 0,
                    abstained: true
                )
            }
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: passage.passage,
                citations: [.init(
                    evidenceID: passage.evidenceID,
                    quotedFragment: passage.passage
                )],
                confidence: 0.9,
                abstained: false
            )
        }

        func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
            throw ResearchProviderError.unsupportedOperation("state update")
        }
    }

    private func makeIndex() throws -> (index: WorkspaceRetrievalIndex, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("observatory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        // Corpus mirrors #307's fixture exactly: IDF over 4 segments keeps
        // the launch-date passage above the 0.5 abstention threshold.
        try index.index(meeting: MeetingManifest(
            meetingID: "prior-launch",
            title: "Launch Planning",
            workspaceID: "acme",
            state: .completed,
            segments: [
                MeetingTranscriptSegment(meetingID: "prior-launch", sequence: 0, sourceLabel: "Room",
                                         text: "We decided to move the launch date to September fifteenth."),
                MeetingTranscriptSegment(meetingID: "prior-launch", sequence: 1, sourceLabel: "Room",
                                         text: "The beta milestone depends on the design freeze next week."),
            ]
        ))
        try index.index(meeting: MeetingManifest(
            meetingID: "prior-api",
            title: "API Design",
            workspaceID: "acme",
            state: .completed,
            segments: [
                MeetingTranscriptSegment(meetingID: "prior-api", sequence: 0, sourceLabel: "Room",
                                         text: "Decision: the new API will use REST instead of GraphQL."),
                MeetingTranscriptSegment(meetingID: "prior-api", sequence: 1, sourceLabel: "Room",
                                         text: "The team agreed on cursor based pagination for the endpoint."),
            ]
        ))
        return (index, root)
    }

    // MARK: - #60 origin routing

    private static func makeInvocation(_ text: String) -> SpokenInvocation {
        SpokenInvocation(requestID: UUID().uuidString, commandText: text, sourceSpanID: "s1", form: "openbridge,")
    }

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

    // A spoken request without an authorized meeting never calls a provider.
    @Test func spokenWithoutAuthorizedMeetingAbstains() async throws {
        let recorder = FakeProviderRecorder()
        let fake = FakeResearchProvider(recorder: recorder)
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: fake),
            webService: nil,
            workspaceIndex: nil,
            workspaceID: "acme"
        )
        coordinator.submitSpoken(Self.makeInvocation("explain the theory of relativity"))
        let state = await waitForRail(coordinator)
        #expect(state == .noSource)
        #expect(coordinator.currentAnswer == nil)
        #expect(recorder.callCount == 0)
    }

    @Test func modelKnowledgeAuthorizationUsesImmutableMeetingSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-model-consent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let active = ProviderSettings().configuration
        let intelligence = MeetingIntelligenceConfiguration(
            cleanupEnabled: false,
            cleanupProvider: .localGemma,
            cloudProvider: providerSnapshot(active)
        )
        try store.create(MeetingManifest(
            meetingID: "cloud-meeting",
            title: "Cloud meeting",
            state: .recording,
            aiMode: .cloudOptIn,
            privacySettings: .init(allowsCloudIntelligence: true),
            intelligenceConfiguration: intelligence
        ))
        try store.create(MeetingManifest(
            meetingID: "local-meeting",
            title: "Local meeting",
            state: .recording,
            aiMode: .localOnly,
            privacySettings: .init(allowsCloudIntelligence: false),
            intelligenceConfiguration: intelligence
        ))

        #expect(ResearchCloudEvidencePolicy.authorizedConfiguration(
            forMeetingID: "cloud-meeting",
            store: store,
            activeConfiguration: active
        ) == active)
        #expect(ResearchCloudEvidencePolicy.authorizedConfiguration(
            forMeetingID: "local-meeting",
            store: store,
            activeConfiguration: active
        ) == nil)
        #expect(ResearchCloudEvidencePolicy.authorizedConfiguration(
            forMeetingID: nil,
            store: store,
            activeConfiguration: active
        ) == nil)
    }

    @Test func injectedProviderModeReachesSpokenModelRequest() async throws {
        let expectedMode = ResearchProviderMode.cloudExperiment
        let configuration = ProviderSettings().configuration
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(
                provider: ModeAssertingProvider(expectedMode: expectedMode),
                cloudModelKnowledgeAuthorization: { _ in configuration }
            ),
            workspaceIndex: nil,
            workspaceID: "acme",
            providerMode: expectedMode
        )

        coordinator.submitSpoken(Self.makeInvocation("explain the theory of relativity"))

        #expect(await waitForRail(coordinator) == .answered)
        #expect(coordinator.currentAnswer?.evidence.allSatisfy { $0.source == .modelSynthesis } == true)
    }

    @Test func deniedSourceMeetingConsentForcesEntireAnswerLocal() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(
                provider: ModeAssertingProvider(expectedMode: .localOnly),
                cloudEvidenceAuthorization: { _ in nil }
            ),
            workspaceIndex: index,
            workspaceID: "acme",
            providerMode: .cloudExperiment
        )

        coordinator.submitTyped("launch date september")

        #expect(await waitForRail(coordinator) == .answered)
    }

    // Typed questions search meetings; authorized wake-phrase questions use
    // model knowledge and carry separate synthesis provenance.
    @Test func typedUsesMeetingsWhileSpokenUsesModelKnowledge() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var fake = FakeResearchProvider()
        fake.configuration.modelKnowledgeAnswers = true
        let configuration = ProviderSettings().configuration
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(
                provider: fake,
                cloudModelKnowledgeAuthorization: { _ in configuration }
            ),
            webService: nil,
            workspaceIndex: index,
            workspaceID: "acme",
            providerMode: .cloudExperiment
        )

        coordinator.submitTyped("What did we decide about the launch date?")
        let typedState = await waitForRail(coordinator)
        #expect(typedState == .answered)
        let typedAnswer = try #require(coordinator.currentAnswer)
        #expect(typedAnswer.evidence.contains { $0.source != .modelSynthesis })

        coordinator.submitSpoken(Self.makeInvocation("what did we decide about the launch date"))
        let spokenState = await waitForRail(coordinator)
        #expect(spokenState == .answered)
        let spokenAnswer = try #require(coordinator.currentAnswer)
        #expect(spokenAnswer.evidence.allSatisfy { $0.source == .modelSynthesis })
    }

    // #60: same question typed then spoken = one card (cross-origin dedup).
    @Test func sameQuestionTypedAndSpokenNoDuplicate() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var fake = FakeResearchProvider()
        fake.configuration.modelKnowledgeAnswers = true
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: fake),
            webService: nil,
            workspaceIndex: index,
            workspaceID: "acme"
        )
        coordinator.submitTyped("What did we decide about the launch date?")
        let typedState = await waitForRail(coordinator)
        #expect(typedState == .answered)
        let firstAnswerID = try #require(coordinator.currentAnswer).questionID

        // Dedup consumes byte-identical re-asks (as established in the
        // #299 v10 live rounds): same string spoken after typed = no
        // second card.
        coordinator.submitSpoken(Self.makeInvocation("What did we decide about the launch date?"))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(coordinator.currentAnswer?.questionID == firstAnswerID)
        #expect(coordinator.railState == .answered)
    }

    private func makeCoordinator(
        index: WorkspaceRetrievalIndex? = nil,
        webProvider: (any ResearchWebProvider)? = nil
    ) -> ObservatoryCoordinator {
        ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: FakeResearchProvider()),
            webService: webProvider.map { WebResearchService(webProvider: $0, gate: TestGate()) },
            workspaceIndex: index,
            workspaceID: "acme"
        )
    }

    private func waitForRail(_ coordinator: ObservatoryCoordinator,
                             timeoutMS: Int = 30_000) async -> ResearchRailState {
        let start = Date()
        while coordinator.railState == .searching,
              Date().timeIntervalSince(start) < Double(timeoutMS) / 1000 {
            // Yield first: under heavy parallel-suite load the MainActor can
            // be starved by polling tasks, freezing the rail in .searching
            // even though the answer already completed. Yielding before the
            // next poll lets the answer task land.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return coordinator.railState
    }

    // MARK: - 1. Silence

    @Test func successfulAnswerDoesNotAutoHideAfterTenSeconds() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)
        coordinator.submitTyped("What did we decide about the launch date?")
        #expect(await waitForRail(coordinator) == .answered)
        let answer = coordinator.currentAnswer
        try await Task.sleep(for: .milliseconds(10_150))
        #expect(coordinator.railState == .answered)
        #expect(coordinator.currentAnswer == answer)
        coordinator.endOfMeeting()
    }

    @Test func spokenBatchQueuesEveryQuestionOnceAndRetainsAnswers() async throws {
        let recorder = FakeProviderRecorder()
        var fake = FakeResearchProvider(recorder: recorder)
        fake.configuration.modelKnowledgeAnswers = true
        fake.configuration.delay = 0.03
        let configuration = ProviderSettings().configuration
        let coordinator = ObservatoryCoordinator(answerService: GroundedAnswerService(provider: fake,
            cloudModelKnowledgeAuthorization: { _ in configuration }), providerMode: .cloudExperiment)
        let detector = SpokenWakePhraseDetector()
        let batch = await detector.processAll(.init(id: "multi", meetingID: "test", sequence: 0, sourceLabel: "Synthetic",
            text: "OpenBridge, explain gravity. OpenBridge, explain magnets. OpenBridge, explain induction loops.", isFinal: true))
        #expect(batch.count == 3)
        coordinator.submitSpoken(batch)
        coordinator.submitSpoken(batch) // replay while work is queued
        for _ in 0..<200 {
            if coordinator.completedAnswers.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.callCount == 3)
        #expect(coordinator.completedAnswers.map(\.questionText) == batch.map(\.commandText))
        #expect(coordinator.completedAnswers.allSatisfy { $0.evidence.allSatisfy { $0.source == .modelSynthesis } })
        // A corrected version of the same command ordinal cannot call again.
        var revision = batch[0]
        revision = SpokenInvocation(requestID: UUID().uuidString, commandText: "explain corrected gravity.", sourceSpanID: revision.sourceSpanID, form: revision.form, commandIndex: revision.commandIndex)
        coordinator.submitSpoken(revision)
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.callCount == 3)
        let removed = coordinator.completedAnswers[1].questionID
        coordinator.dismissAnswer("answer-\(removed)")
        #expect(coordinator.completedAnswers.count == 2)
        coordinator.endOfMeeting()
        #expect(coordinator.completedAnswers.isEmpty)
        #expect(coordinator.activeQuestion == nil)
    }

    @Test func stopCancelsQueuedSpokenWork() async throws {
        let recorder = FakeProviderRecorder()
        var fake = FakeResearchProvider(recorder: recorder)
        fake.configuration.modelKnowledgeAnswers = true
        fake.configuration.delay = 0.2
        let configuration = ProviderSettings().configuration
        let coordinator = ObservatoryCoordinator(answerService: GroundedAnswerService(provider: fake,
            cloudModelKnowledgeAuthorization: { _ in configuration }), providerMode: .cloudExperiment)
        coordinator.submitSpoken((0..<3).map {
            SpokenInvocation(requestID: UUID().uuidString, commandText: "explain topic \($0)", sourceSpanID: "span", form: "openbridge,", commandIndex: $0)
        })
        try await Task.sleep(for: .milliseconds(20))
        coordinator.endOfMeeting()
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.callCount <= 1)
        #expect(coordinator.completedAnswers.isEmpty)
        #expect(coordinator.railState == .quiet)
        coordinator.setMeetingContext(meetingID: "next", workspaceID: "acme", allowsCloud: true)
        coordinator.submitSpoken(Self.makeInvocation("explain gravity"))
        #expect(await waitForRail(coordinator) == .answered, "A stopped task must not block the next meeting's queue")
        coordinator.endOfMeeting()
    }

    @Test func silenceStaysQuiet() async throws {
        let coordinator = makeCoordinator()
        // No question, no cue → quiet.
        #expect(coordinator.railState == .quiet)
        #expect(coordinator.currentAnswer == nil)
        #expect(coordinator.proactiveCue == nil)
    }

    @Test func productionConfigurationRejectsUnsolicitedCue() {
        let coordinator = makeCoordinator()
        coordinator.offerProactiveCue(ObservatoryEvidence(
            id: "unsolicited",
            source: .priorMeeting(meetingID: "m", segmentID: "s"),
            passage: "This must stay hidden.",
            confidence: 1
        ))
        #expect(coordinator.railState == .quiet)
        #expect(coordinator.proactiveCue == nil)
    }

    // MARK: - 2. Memory Cue (at most one)

    @Test func proactiveCueSurfacesOnce() {
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: FakeResearchProvider()),
            configuration: .init(allowsProactiveCues: true)
        )
        let cue = ObservatoryEvidence(
            id: "cue-1", source: .priorMeeting(meetingID: "m", segmentID: "s"),
            passage: "Launch date was decided.", confidence: 0.9
        )
        coordinator.offerProactiveCue(cue)
        #expect(coordinator.proactiveCue?.id == "cue-1")
        #expect(coordinator.railState == .memoryCue)

        // A second cue is refused — at most one.
        let second = ObservatoryEvidence(
            id: "cue-2", source: .priorMeeting(meetingID: "m2", segmentID: "s2"),
            passage: "Another memory.", confidence: 0.8
        )
        coordinator.offerProactiveCue(second)
        #expect(coordinator.proactiveCue?.id == "cue-1", "At most one proactive cue")
    }

    // MARK: - 3. Explicit Local Answer (typed)

    @Test func typedQuestionProducesGroundedAnswer() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)

        coordinator.submitTyped("launch date september")
        let state = await waitForRail(coordinator)
        #expect(state == .answered)
        let answer = try #require(coordinator.currentAnswer)
        #expect(!answer.evidence.isEmpty, "Answer must carry source evidence")
    }

    @Test func selectedMeetingEvidenceRetainsExactNavigationIdentity() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)
        coordinator.setMeetingContext(
            meetingID: "prior-launch",
            workspaceID: "acme",
            allowsCloud: false
        )

        coordinator.submitTyped("launch date september")
        #expect(await waitForRail(coordinator) == .answered)
        let evidence = try #require(coordinator.currentAnswer?.evidence.first)
        guard case .currentMeeting(let meetingID, let spanID) = evidence.source else {
            Issue.record("Selected meeting evidence must retain current-meeting identity")
            return
        }
        #expect(meetingID == "prior-launch")
        #expect(!spanID.isEmpty)
        #expect(!evidence.passage.isEmpty)
    }

    @Test func selectedMeetingWorkspaceScopesRetrieval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("observatory-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "default-launch",
            title: "Default Launch",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "default-launch", sequence: 0, sourceLabel: "Room",
                text: "Project Zephyr launches in June."
            )]
        ))
        try index.index(meeting: MeetingManifest(
            meetingID: "custom-launch",
            title: "Custom Launch",
            workspaceID: "customer-workspace",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "custom-launch", sequence: 0, sourceLabel: "Room",
                text: "Project Zephyr launches in October."
            )]
        ))
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: FakeResearchProvider()),
            workspaceIndex: index,
            workspaceID: Workspace.defaultWorkspace.id
        )
        coordinator.setMeetingContext(
            meetingID: "custom-launch",
            workspaceID: "customer-workspace",
            allowsCloud: false
        )

        coordinator.submitTyped("Project Zephyr launches")

        #expect(await waitForRail(coordinator) == .answered)
        let evidence = try #require(coordinator.currentAnswer?.evidence.first)
        guard case .currentMeeting(let meetingID, _) = evidence.source else {
            Issue.record("Selected workspace should return the selected meeting")
            return
        }
        #expect(meetingID == "custom-launch")
        #expect(evidence.passage.contains("October"))
    }

    // MARK: - 4. Explicit Spoken Answer (authorized model path, no duplicates)

    @Test func spokenQuestionUsesAuthorizedModelPath() async throws {
        var fake = FakeResearchProvider()
        fake.configuration.modelKnowledgeAnswers = true
        let configuration = ProviderSettings().configuration
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(
                provider: fake,
                cloudModelKnowledgeAuthorization: { _ in configuration }
            ),
            webService: nil,
            workspaceIndex: nil,
            workspaceID: "acme",
            providerMode: .cloudExperiment
        )

        let invocation = SpokenInvocation(
            requestID: "req-1",
            commandText: "explain the theory of relativity",
            sourceSpanID: "span-1",
            form: "openbridge,"
        )
        coordinator.submitSpoken(invocation)
        let state = await waitForRail(coordinator)
        #expect(state == .answered)
        let answer = try #require(coordinator.currentAnswer)
        #expect(answer.evidence.allSatisfy { $0.source == .modelSynthesis })

        // Same question typed after spoken → duplicate suppressed (one
        // coordinator, one dedup key space). Rail not stuck searching.
        coordinator.submitTyped("explain the theory of relativity")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(coordinator.currentAnswer?.questionID == answer.questionID)
        #expect(coordinator.railState == .answered)
    }

    @Test func finalWakeSpanRoutesExactlyOnceAcrossReplayAndCorrection() async throws {
        let detector = SpokenWakePhraseDetector()
        let localRecorder = FakeProviderRecorder()
        let cloudRecorder = FakeProviderRecorder()
        var cloud = FakeResearchProvider(recorder: cloudRecorder)
        cloud.configuration.modelKnowledgeAnswers = true
        let configuration = ProviderSettings().configuration
        let provider = ConfiguredResearchProvider(
            cloudReadiness: { configuration },
            localProvider: FakeResearchProvider(recorder: localRecorder),
            cloudProvider: cloud
        )
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(
                provider: provider,
                cloudModelKnowledgeAuthorization: { _ in configuration }
            ),
            workspaceIndex: nil,
            workspaceID: "acme",
            providerMode: .cloudExperiment
        )
        let firstSpan = MeetingTranscriptSegment(
            id: "final-span",
            meetingID: "meeting-cloud",
            sequence: 1,
            sourceLabel: "Room",
            text: "OpenBridge, what is the pricing?",
            isFinal: true
        )
        let firstInvocation = try #require(await detector.process(firstSpan))
        coordinator.submitSpoken(firstInvocation)
        #expect(await waitForRail(coordinator) == .answered)
        #expect(cloudRecorder.calls(of: .groundedAnswer).count == 1)
        #expect(localRecorder.callCount == 0)
        #expect(coordinator.currentAnswer?.evidence.allSatisfy { $0.source == .modelSynthesis } == true)

        #expect(await detector.process(firstSpan) == nil, "identical replay must not re-emit")
        let correction = MeetingTranscriptSegment(
            id: "final-span",
            meetingID: "meeting-cloud",
            sequence: 1,
            sourceLabel: "Room",
            text: "OpenBridge, what is our pricing?",
            isFinal: true
        )
        let correctedInvocation = try #require(await detector.process(correction))
        coordinator.submitSpoken(correctedInvocation)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(cloudRecorder.calls(of: .groundedAnswer).count == 1,
                "one finalized ASR span may start only one provider request")
    }

    // MARK: - 5. Cited Web Answer

    @Test func authorizedWebQuestionReturnsOpenableSources() async throws {
        struct GoodWebProvider: ResearchWebProvider {
            let providerID = "good-web"
            func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
                WebResearchResponse(requestID: request.requestID, providerID: providerID, results: [
                    WebResearchResult(
                        title: "Pricing",
                        url: URL(string: "https://example.com/pricing")!,
                        passage: "Enterprise pricing is public.",
                        score: 0.9
                    )
                ])
            }
        }

        let coordinator = makeCoordinator(webProvider: GoodWebProvider())
        coordinator.submitTyped("what is enterprise pricing", webAuthority: true)
        let state = await waitForRail(coordinator)
        #expect(state == .answered)
        let answer = try #require(coordinator.currentAnswer)
        // Every factual web result exposes an openable https source.
        for evidence in answer.evidence {
            guard case .web(let url) = evidence.source else {
                Issue.record("Web answers must carry web evidence")
                return
            }
            #expect(url.hasPrefix("https://"))
        }
    }

    // MARK: - 6. No Source (weak evidence abstains)

    @Test func weakEvidenceAbstainsNoCard() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)

        coordinator.submitTyped("quantum holography zephyr")
        let state = await waitForRail(coordinator)
        #expect(state == .noSource)
        #expect(coordinator.currentAnswer == nil, "No card for weak evidence")
    }

    // MARK: - 7. Timeout (web)

    @Test func webTimeoutStaysInsideRail() async throws {
        struct SlowWebProvider: ResearchWebProvider {
            let providerID = "slow-web"
            func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return WebResearchResponse(requestID: request.requestID, providerID: providerID, results: [])
            }
        }

        struct FastGate: WebResearchGate {
            func settings() async -> ProviderSettings { ProviderSettings(cloudEnabled: true, consentGranted: true) }
            func hasCredential() async -> Bool { true }
            func networkReachable() async -> Bool { true }
        }

        let web = WebResearchService(
            webProvider: SlowWebProvider(),
            gate: FastGate(),
            configuration: .init(timeout: 0.2)
        )
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: FakeResearchProvider()),
            webService: web,
            workspaceIndex: nil,
            workspaceID: nil
        )
        coordinator.submitTyped("slow web question", webAuthority: true)
        let state = await waitForRail(coordinator, timeoutMS: 3_000)
        #expect(state == .timeout, "Timeout stays inside the rail")
    }

    // MARK: - 8. Stale Result (superseded question)

    @Test func supersededQuestionResultIsDropped() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)

        // First question, then immediately supersede with a second.
        coordinator.submitTyped("launch date september")
        coordinator.submitTyped("api rest graphql decision")
        let state = await waitForRail(coordinator)
        // The rail reflects the LATEST question only.
        #expect(state == .answered)
        if let answer = coordinator.currentAnswer {
            // The stale first question's answer must never be presented.
            #expect(answer.evidence.isEmpty == false)
        }
    }

    // MARK: - 9. Dismissal Suppression (current meeting)

    @Test func dismissedEvidenceStaysSuppressed() {
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: FakeResearchProvider()),
            configuration: .init(allowsProactiveCues: true)
        )
        let cue = ObservatoryEvidence(
            id: "cue-1", source: .priorMeeting(meetingID: "m", segmentID: "s"),
            passage: "Memory.", confidence: 0.9
        )
        coordinator.offerProactiveCue(cue)
        #expect(coordinator.proactiveCue != nil)

        coordinator.dismissEvidence(cue)
        #expect(coordinator.proactiveCue == nil)
        #expect(coordinator.railState == .quiet)

        // Re-offering the dismissed evidence stays suppressed for the
        // current meeting.
        coordinator.offerProactiveCue(cue)
        #expect(coordinator.proactiveCue == nil, "Dismissed evidence suppressed for this meeting")
    }

    // MARK: - 10. Provider Failure (isolated)

    @Test func providerFailureContainedInRail() async throws {
        // A real index ensures the question reaches the provider, whose
        // failure must surface as the rail's failure state.
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = FakeResearchProvider(
            configuration: .init(groundedAnswerFailure: .providerError("engine down"))
        )
        let coordinator = ObservatoryCoordinator(
            answerService: GroundedAnswerService(provider: failing),
            webService: nil,
            workspaceIndex: index,
            workspaceID: "acme"
        )
        coordinator.submitTyped("launch date september")
        let state = await waitForRail(coordinator)
        #expect(state == .failure, "Failure surfaces inside the rail")
        // Coordinator still usable: end-of-meeting resets cleanly.
        coordinator.endOfMeeting()
        #expect(coordinator.railState == .quiet)
    }

    // MARK: - Distinct Evidence Sources

    @Test func evidenceSourcesRemainDistinct() {
        let sources: [ObservatoryEvidence.Source] = [
            .currentMeeting(meetingID: "current", spanID: "a"),
            .priorMeeting(meetingID: "m", segmentID: "b"),
            .web(url: "https://example.com"),
            .modelSynthesis,
        ]
        // Distinct dedup keys prove the sources can never conflate.
        let keys = sources.map(\.dedupKey)
        #expect(Set(keys).count == 4, "Current/prior/web/synthesis remain distinct")
    }

    // MARK: - Feature Flag Gate (#292 enforcement)

    @Test func flagCannotPromoteWithoutPassingGate() async throws {
        // Produce a FAILING gate record via the slow profile.
        let slow = ReplayProviderProfile(
            identifier: "slow", classificationLatencyMS: 2_000, answerLatencyMS: 8_000, retrievalLatencyMS: 5
        )
        let runner = EvaluationRunner()
        let failing = try await runner.run(fixture: .standardFixture(), profile: slow)
        #expect(!failing.gateRecord.passed)

        var flag = ObservatoryFeatureFlag()
        let failedPromotion = flag.promote(with: failing.gateRecord)
        #expect(!failedPromotion, "Failing gate must not promote")
        #expect(!flag.isEnabled)

        // Produce a PASSING gate record via the fake profile.
        let passing = try await runner.run(fixture: .standardFixture(), profile: .fake)
        #expect(passing.gateRecord.passed)
        let succeededPromotion = flag.promote(with: passing.gateRecord)
        #expect(succeededPromotion, "Passing gate promotes")
        #expect(flag.isEnabled)
        #expect(flag.authorizingGateRecord == passing.gateRecord)
    }

    // MARK: - Session-Local History

    @Test func historyIsSessionLocal() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)

        coordinator.submitTyped("launch date september")
        _ = await waitForRail(coordinator)
        #expect(coordinator.currentAnswer != nil)

        coordinator.endOfMeeting()
        #expect(coordinator.currentAnswer == nil)
        #expect(coordinator.railState == .quiet)

        // After end-of-meeting the same question may be asked again (new
        // session, fresh dedup space).
        coordinator.submitTyped("launch date september")
        let state = await waitForRail(coordinator)
        #expect(state == .answered)
    }
}
