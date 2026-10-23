import Foundation
import Testing
@testable import OpenBridgeApp

// MARK: - Grounded Answer Service Tests (#307 / INT-04A)
//
// Verifies the acceptance criteria: every material sentence maps to a
// supplied passage, source metadata is never model-generated, weak or
// contradictory evidence abstains, provider failure is isolated, and the
// same fixture runs through fake and reference providers.

@Suite(.serialized) struct GroundedAnswerServiceTests {

    // MARK: - Fixture Corpus (two prior meetings)

    private func makeIndexedCorpus(label: String = UUID().uuidString) throws -> (index: WorkspaceRetrievalIndex, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try WorkspaceRetrievalIndex(
            databaseURL: root.appendingPathComponent("index.sqlite")
        )

        let launch = MeetingManifest(
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
        )
        let api = MeetingManifest(
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
        )
        try index.index(meeting: launch)
        try index.index(meeting: api)
        return (index, root)
    }

    /// A provider whose grounded answers quote passage content verbatim,
    /// standing in for any well-behaved reference provider.
    private struct QuotingProvider: ResearchProvider {
        let descriptor = ResearchProviderDescriptor(
            identifier: "quoting", displayName: "Quoting", capabilities: .all, isCloud: false
        )

        func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
            ClassificationResponse(requestID: request.context.requestID, category: .factual, confidence: 0.9)
        }

        func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
            guard let top = request.passages.first else {
                return GroundedAnswerResponse(
                    requestID: request.context.requestID, answerText: "",
                    citations: [], confidence: 0.0, abstained: true
                )
            }
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: top.passage,
                citations: [ResearchAnswerCitation(evidenceID: top.evidenceID, quotedFragment: String(top.passage.prefix(60)))],
                confidence: 0.85
            )
        }

        func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
            StateUpdateResponse(requestID: request.context.requestID)
        }
    }

    /// A provider that returns one supported sentence plus one unsupported
    /// hallucinated sentence — the composer must drop the latter.
    private struct HallucinatingProvider: ResearchProvider {
        let descriptor = ResearchProviderDescriptor(
            identifier: "hallucinating", displayName: "Hallucinating", capabilities: .all, isCloud: false
        )

        func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
            ClassificationResponse(requestID: request.context.requestID, category: .factual, confidence: 0.9)
        }

        func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
            guard let top = request.passages.first else {
                return GroundedAnswerResponse(
                    requestID: request.context.requestID, answerText: "",
                    citations: [], confidence: 0.0, abstained: true
                )
            }
            let answer = top.passage + ". " + "Maria owns the trademark and the deadline was invented yesterday."
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: answer,
                citations: [ResearchAnswerCitation(evidenceID: top.evidenceID, quotedFragment: String(top.passage.prefix(60)))],
                confidence: 0.85
            )
        }

        func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
            StateUpdateResponse(requestID: request.context.requestID)
        }
    }

    /// Simulates the production cloud contract with a caller-selected answer
    /// and exact quote tied to a retrieval-owned evidence ID.
    private struct CitationParaphrasingProvider: ResearchProvider {
        let quotedFragment: String
        let answerText: String
        let descriptor = ResearchProviderDescriptor(
            identifier: "paraphrasing", displayName: "Paraphrasing", capabilities: .all, isCloud: true
        )

        init(
            quotedFragment: String,
            answerText: String = "The launch moved to September fifteenth."
        ) {
            self.quotedFragment = quotedFragment
            self.answerText = answerText
        }

        func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
            ClassificationResponse(requestID: request.context.requestID, category: .factual, confidence: 0.9)
        }

        func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
            let top = try #require(request.passages.first)
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: answerText,
                citations: [ResearchAnswerCitation(
                    evidenceID: top.evidenceID,
                    quotedFragment: quotedFragment
                )],
                confidence: 0.9
            )
        }

        func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
            StateUpdateResponse(requestID: request.context.requestID)
        }
    }

    private struct ExtraCitationProvider: ResearchProvider {
        let descriptor = ResearchProviderDescriptor(
            identifier: "extra-citation",
            displayName: "Extra citation",
            capabilities: .all,
            isCloud: true
        )

        func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
            ClassificationResponse(
                requestID: request.context.requestID,
                category: .factual,
                confidence: 0.9
            )
        }

        func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
            let supporting = try #require(request.passages.first { $0.passage.contains("September") })
            let unrelated = try #require(request.passages.first { $0.evidenceID != supporting.evidenceID })
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: "The launch timeline is September.",
                citations: [
                    ResearchAnswerCitation(
                        evidenceID: supporting.evidenceID,
                        quotedFragment: "The launch timeline is September"
                    ),
                    ResearchAnswerCitation(
                        evidenceID: unrelated.evidenceID,
                        quotedFragment: String(unrelated.passage.prefix(50))
                    ),
                ],
                confidence: 0.9
            )
        }

        func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
            StateUpdateResponse(requestID: request.context.requestID)
        }
    }

    // MARK: - Happy Path

    @Test func strongEvidenceProducesGroundedAnswer() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: QuotingProvider())

        let answer = try await service.answer(
            question: "launch date september",
            index: index,
            workspaceID: "acme"
        )
        let grounded = try #require(answer)
        #expect(!grounded.isEmpty)
        #expect(!grounded.sentences.isEmpty)

        // Every material sentence maps to a supplied passage.
        for sentence in grounded.sentences where sentence.kind != .uncertainty {
            #expect(!sentence.passageIDs.isEmpty,
                    "Material sentence must cite at least one passage: '\(sentence.text)'")
        }

        #expect(!grounded.citedPassageIDs.isEmpty)
        let source = try #require(grounded.sources.first)
        #expect(source.meetingID == "prior-launch")
        #expect(source.segmentID == grounded.citedPassageIDs.first)
        #expect(source.sourceLabel == "Room")
        #expect(source.passage.lowercased().contains("launch"))
    }

    @Test func sameFixtureRunsThroughFakeAndReferenceProviders() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeAnswer = try await GroundedAnswerService(provider: FakeResearchProvider())
            .answer(question: "launch date september", index: index, workspaceID: "acme")
        let quotingAnswer = try await GroundedAnswerService(provider: QuotingProvider())
            .answer(question: "launch date september", index: index, workspaceID: "acme")

        for answer in [fakeAnswer, quotingAnswer] {
            let grounded = try #require(answer)
            for sentence in grounded.sentences where sentence.kind != .uncertainty {
                #expect(!sentence.passageIDs.isEmpty)
            }
        }
    }

    // MARK: - Decision vs Discussion

    @Test func decisionEvidenceLabeledAsPriorDecision() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: QuotingProvider())

        let answer = try await service.answer(
            question: "REST GraphQL API",
            index: index,
            workspaceID: "acme"
        )
        let grounded = try #require(answer)
        #expect(grounded.kind == .priorDecision)
    }

    @Test func discussionEvidenceLabeledAsPriorDiscussion() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: QuotingProvider())

        let answer = try await service.answer(
            question: "beta milestone design freeze",
            index: index,
            workspaceID: "acme"
        )
        let grounded = try #require(answer)
        #expect(grounded.kind == .priorDiscussion)
    }

    // MARK: - Abstention

    @Test func noEvidenceAbstains() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: QuotingProvider())

        let answer = try await service.answer(
            question: "quantum holography zephyr",
            index: index,
            workspaceID: "acme"
        )
        #expect(answer == nil)
    }

    @Test func providerAbstentionPropagates() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        // Nonexistent workspace → retrieval yields no passages → abstain.
        let service = GroundedAnswerService(provider: FakeResearchProvider())
        let answer = try await service.answer(
            question: "launch date september",
            index: index,
            workspaceID: "does-not-exist"
        )
        #expect(answer == nil)
    }

    @Test func lowConfidenceAbstains() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(
            provider: QuotingProvider(),
            configuration: .init(minConfidence: 0.99)
        )
        let answer = try await service.answer(
            question: "launch date september",
            index: index,
            workspaceID: "acme"
        )
        #expect(answer == nil)
    }

    @Test func contradictoryEvidenceAbstains() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-contradict", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m-a", title: "A", workspaceID: "acme", state: .completed,
            segments: [
                MeetingTranscriptSegment(meetingID: "m-a", sequence: 0, sourceLabel: "Room",
                                         text: "We decided the launch is in September and shipping proceeds."),
                MeetingTranscriptSegment(meetingID: "m-a", sequence: 1, sourceLabel: "Room",
                                         text: "We decided the launch is not in September because shipping blocked."),
            ]
        ))

        let service = GroundedAnswerService(provider: QuotingProvider())
        let answer = try await service.answer(
            question: "launch september shipping",
            index: index,
            workspaceID: "acme"
        )
        #expect(answer == nil, "Conflicting passages must produce no answer payload")
    }

    // MARK: - Unsupported Content Rejected

    @Test func unsupportedSentencesRejectTheProviderResponse() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: HallucinatingProvider())

        await #expect(throws: GroundedAnswerServiceError.self) {
            _ = try await service.answer(
                question: "launch date september",
                index: index,
                workspaceID: "acme"
            )
        }
    }

    @Test func oneSentenceExtractUsesValidatedExactQuote() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: CitationParaphrasingProvider(
            quotedFragment: "move the launch date to September fifteenth",
            answerText: "We decided to move the launch date to September fifteenth."
        ))

        let answer = try await service.answer(
            question: "launch date september",
            index: index,
            workspaceID: "acme"
        )

        let grounded = try #require(answer)
        #expect(grounded.sentences.map(\.text) == ["We decided to move the launch date to September fifteenth."])
        #expect(grounded.sources.first?.meetingID == "prior-launch")
    }

    @Test func newlineSeparatedClaimsRemainGroundedAndVisible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-newlines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "newline",
            title: "Timeline",
            workspaceID: "acme",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "newline",
                sequence: 0,
                sourceLabel: "Room",
                text: "The launch date is September.\nThe design freeze is next week."
            )]
        ))

        let answer = try await GroundedAnswerService(provider: QuotingProvider()).answer(
            question: "launch September design freeze",
            index: index,
            workspaceID: "acme"
        )

        let grounded = try #require(answer)
        #expect(grounded.sentences.count == 2)
        #expect(grounded.sentences[0].text.contains("launch"))
        #expect(grounded.sentences[1].text.contains("design"))
        #expect(grounded.sentences.allSatisfy { !$0.passageIDs.isEmpty })
    }

    @Test func decimalVersionsAndAbbreviationsRemainIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-dotted-values-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "dotted-values",
            title: "Budget",
            workspaceID: "acme",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "dotted-values",
                sequence: 0,
                sourceLabel: "Room",
                text: "The budget is $1.5 million. U.S. sales use v1.2 today."
            )]
        ))

        let answer = try await GroundedAnswerService(provider: QuotingProvider()).answer(
            question: "budget sales version",
            index: index,
            workspaceID: "acme"
        )

        let grounded = try #require(answer)
        #expect(grounded.sentences.map(\.text) == [
            "The budget is $1.5 million.",
            "U.S. sales use v1.2 today.",
        ])
    }

    @Test func paraphraseWithInventedQuoteIsRejected() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: CitationParaphrasingProvider(
            quotedFragment: "a quote that never occurred"
        ))

        await #expect(throws: GroundedAnswerServiceError.self) {
            _ = try await service.answer(
                question: "launch date september",
                index: index,
                workspaceID: "acme"
            )
        }
    }

    @Test func paraphraseWithTrivialQuoteIsRejected() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GroundedAnswerService(provider: CitationParaphrasingProvider(
            quotedFragment: "launch"
        ))

        await #expect(throws: GroundedAnswerServiceError.self) {
            _ = try await service.answer(
                question: "launch date september",
                index: index,
                workspaceID: "acme"
            )
        }
    }

    @Test func citationCannotReverseEvidencePolarity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-polarity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "polarity",
            title: "Polarity",
            workspaceID: "acme",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "polarity", sequence: 0, sourceLabel: "Room",
                text: "The launch date was not cancelled."
            )]
        ))
        let reversed = GroundedAnswerService(provider: CitationParaphrasingProvider(
            quotedFragment: "The launch date was not cancelled",
            answerText: "The launch date was cancelled."
        ))

        await #expect(throws: GroundedAnswerServiceError.self) {
            _ = try await reversed.answer(
                question: "launch date cancelled",
                index: index,
                workspaceID: "acme"
            )
        }

        let matching = GroundedAnswerService(provider: CitationParaphrasingProvider(
            quotedFragment: "The launch date was not cancelled",
            answerText: "The launch date was not cancelled."
        ))
        #expect(try await matching.answer(
            question: "launch date cancelled",
            index: index,
            workspaceID: "acme"
        ) != nil)
    }

    @Test func shortExtractCannotDropSourceNegation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-negation-omission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "approval",
            title: "Approval",
            workspaceID: "acme",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "approval",
                sequence: 0,
                sourceLabel: "Room",
                text: "The launch was not approved."
            )]
        ))
        let service = GroundedAnswerService(provider: CitationParaphrasingProvider(
            quotedFragment: "The launch was not approved",
            answerText: "Approved."
        ))

        await #expect(throws: GroundedAnswerServiceError.self) {
            _ = try await service.answer(
                question: "launch approved",
                index: index,
                workspaceID: "acme"
            )
        }
    }

    @Test func unrelatedValidCitationIsNotDisplayedAsSupportingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-extra-citation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "timeline",
            title: "Timeline",
            workspaceID: "acme",
            state: .completed,
            segments: [
                MeetingTranscriptSegment(
                    meetingID: "timeline",
                    sequence: 0,
                    sourceLabel: "Room",
                    text: "The launch timeline is September."
                ),
                MeetingTranscriptSegment(
                    meetingID: "timeline",
                    sequence: 1,
                    sourceLabel: "Room",
                    text: "The launch timeline document is stored in Drive."
                ),
            ]
        ))

        let answer = try await GroundedAnswerService(provider: ExtraCitationProvider()).answer(
            question: "launch timeline",
            index: index,
            workspaceID: "acme"
        )

        let grounded = try #require(answer)
        #expect(grounded.sources.count == 1)
        #expect(grounded.sources[0].passage.contains("September"))
        #expect(!grounded.sources[0].passage.contains("Drive"))
        #expect(grounded.sentences[0].passageIDs == [grounded.sources[0].evidenceID])
    }

    // MARK: - Provider Failure Isolation

    @Test func providerFailureThrowsContainedError() async throws {
        let (index, root) = try makeIndexedCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = FakeResearchProvider(
            configuration: .init(groundedAnswerFailure: .providerError("engine down"))
        )
        let service = GroundedAnswerService(provider: failing)

        await #expect(throws: GroundedAnswerServiceError.self) {
            _ = try await service.answer(
                question: "launch date september",
                index: index,
                workspaceID: "acme"
            )
        }
    }

    // MARK: - Deterministic Helpers

    @Test func contradictionDetectorBehavior() throws {
        let a = "We decided the launch is in September and shipping proceeds"
        let b = "We decided the launch is not in September because shipping blocked"
        #expect(GroundedAnswerService.passagesContradict(a, b))

        let c = "We decided the launch is in September and shipping proceeds"
        let d = "The team agreed on cursor based pagination for the endpoint"
        #expect(!GroundedAnswerService.passagesContradict(c, d))
    }

    @Test func uncertaintyDetection() throws {
        #expect(GroundedAnswerService.isUncertainty("it is not clear who owns the repo"))
        #expect(GroundedAnswerService.isUncertainty("the record does not say"))
        #expect(!GroundedAnswerService.isUncertainty("we agreed to ship"))
    }

    @Test func decisionDetection() throws {
        #expect(GroundedAnswerService.isDecision("we decided to move the date"))
        #expect(GroundedAnswerService.isDecision("decision: use rest"))
        #expect(!GroundedAnswerService.isDecision("the weather was nice"))
    }

    // MARK: - Multiple Supporting Passages

    @Test func multiplePassagesRetainedWhenSupported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounded-multi", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        // Filler segments keep IDF positive (a corpus where every doc
        // matches drives bm25 negative via IDF math).
        try index.index(meeting: MeetingManifest(
            meetingID: "m-filler", title: "F", workspaceID: "acme", state: .completed,
            segments: [
                MeetingTranscriptSegment(meetingID: "m-filler", sequence: 0, sourceLabel: "Room",
                                         text: "The onboarding flow confuses new users according to surveys."),
                MeetingTranscriptSegment(meetingID: "m-filler", sequence: 1, sourceLabel: "Room",
                                         text: "Kubernetes cluster autoscaling was enabled for cost savings."),
                MeetingTranscriptSegment(meetingID: "m-filler", sequence: 2, sourceLabel: "Room",
                                         text: "The tire rotation and oil change are due next week."),
                MeetingTranscriptSegment(meetingID: "m-filler", sequence: 3, sourceLabel: "Room",
                                         text: "Flights to Lisbon were booked for the spring holiday."),
            ]
        ))
        try index.index(meeting: MeetingManifest(
            meetingID: "m-multi", title: "M", workspaceID: "acme", state: .completed,
            segments: [
                MeetingTranscriptSegment(meetingID: "m-multi", sequence: 0, sourceLabel: "Room",
                                         text: "We decided the launch date is September fifteenth."),
                MeetingTranscriptSegment(meetingID: "m-multi", sequence: 1, sourceLabel: "Room",
                                         text: "We decided the launch date is September fifteenth and marketing agreed."),
            ]
        ))

        let service = GroundedAnswerService(provider: QuotingProvider())
        let answer = try await service.answer(
            question: "launch date september fifteenth",
            index: index,
            workspaceID: "acme"
        )
        let grounded = try #require(answer)
        #expect(!grounded.citedPassageIDs.isEmpty)
    }
}
