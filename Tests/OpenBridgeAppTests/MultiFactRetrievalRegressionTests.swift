import XCTest
@testable import OpenBridgeApp

/// lunr-studio/Openbridge-Beta#299 — post-freeze regression (Alex QA,
/// Build 24 close record, PR #98): multi-fact and bare single-term questions
/// return only the single best-matching passage. Compound forms (single-
/// sentence and two-sentence) answer only the backup-contact fact; bare
/// "When is the kickoff?" misses the kickoff segment entirely, while the
/// control "When is the kickoff scheduled?" finds it. These tests mirror
/// the QA corpus (kickoff fact at sequence 1 / offset 28; Dana Ruiz
/// backup fact at sequence 0) and drive the REAL path:
/// GroundedAnswerService.answer with the LocalEvidenceResearchProvider.
final class MultiFactRetrievalRegressionTests: XCTestCase {

    private func makeFixture() throws -> (WorkspaceRetrievalIndex, GroundedAnswerService) {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("multifact-\(UUID().uuidString).sqlite"))

        // Meeting A — kickoff fact lives at sequence 1, offset 28 (QA shape).
        let a0 = MeetingTranscriptSegment(
            id: "a-seg0", meetingID: "m1", sequence: 0, startOffset: 4,
            text: "Okay let us get started and review the agenda for this sync.", isFinal: true)
        let a1 = MeetingTranscriptSegment(
            id: "a-seg1", meetingID: "m1", sequence: 1, startOffset: 28,
            text: "The kickoff is scheduled for Friday at ten in the morning.", isFinal: true)
        let a2 = MeetingTranscriptSegment(
            id: "a-seg2", meetingID: "m1", sequence: 2, startOffset: 61,
            text: "After that we will go through the open action items.", isFinal: true)
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [a0, a1, a2]))

        // Meeting B — backup-contact fact at sequence 0.
        let b0 = MeetingTranscriptSegment(
            id: "b-seg0", meetingID: "m2", sequence: 0, startOffset: 0,
            text: "The backup contact for the launch is Dana Ruiz.", isFinal: true)
        let b1 = MeetingTranscriptSegment(
            id: "b-seg1", meetingID: "m2", sequence: 1, startOffset: 33,
            text: "She will handle the vendor questions during rollout.", isFinal: true)
        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "Launch Logistics", workspaceID: "w",
            segments: [b0, b1]))

        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        return (index, service)
    }

    private func makeProjectScopedFixture() throws -> (WorkspaceRetrievalIndex, GroundedAnswerService) {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("build25-scope-\(UUID().uuidString).sqlite"))

        try index.index(meeting: MeetingManifest(
            meetingID: "atlas", title: "Project Atlas Mobile App", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "atlas-kickoff", meetingID: "atlas", sequence: 0, startOffset: 12,
                    text: "The Project Atlas mobile app kickoff is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "atlas-contact", meetingID: "atlas", sequence: 1, startOffset: 42,
                    text: "The Project Atlas backup contact is Dana Ruiz.", isFinal: true),
            ]))
        try index.index(meeting: MeetingManifest(
            meetingID: "beta", title: "Project Beta Mobile App", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "beta-kickoff", meetingID: "beta", sequence: 0, startOffset: 8,
                    text: "The Project Beta mobile app kickoff is scheduled for Monday at nine.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "beta-contact", meetingID: "beta", sequence: 1, startOffset: 36,
                    text: "The Project Beta backup contact is Marcus Lee.", isFinal: true),
            ]))

        return (index, GroundedAnswerService(provider: LocalEvidenceResearchProvider()))
    }

    /// QA regression 1: compound single-sentence form must answer BOTH
    /// facts — two evidence rows, kickoff AND backup contact.
    func testCompoundSentenceAnswersBothFacts() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        let segmentIDs = Set(answer!.sources.map(\.segmentID))
        XCTAssertTrue(segmentIDs.contains("a-seg1"), "kickoff fact missing from: \(segmentIDs)")
        XCTAssertTrue(segmentIDs.contains("b-seg0"), "backup-contact fact missing from: \(segmentIDs)")
    }

    /// QA regression 1 (cont.): two-sentence form must answer BOTH facts.
    func testTwoSentenceFormAnswersBothFacts() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff? Who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        let segmentIDs = Set(answer!.sources.map(\.segmentID))
        XCTAssertTrue(segmentIDs.contains("a-seg1"), "kickoff fact missing from: \(segmentIDs)")
        XCTAssertTrue(segmentIDs.contains("b-seg0"), "backup-contact fact missing from: \(segmentIDs)")
    }

    /// QA regression 2: the bare single-term question must find the
    /// kickoff segment.
    func testBareWhenQuestionFindsKickoffSegment() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "a-seg1" },
                      "kickoff segment missing: \(answer!.sources.map(\.segmentID))")
    }

    /// Control (passes at the regression head): the fuller paraphrase finds
    /// the kickoff segment. Must keep passing after the fix.
    func testControlKickoffScheduledStillWorks() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff scheduled?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "a-seg1" })
    }

    /// Abstention must survive the fix: unrelated questions still return nil.
    func testUnrelatedQuestionStillAbstains() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "What color is the bicycle shelter?",
            index: index, workspaceID: "w"
        )
        XCTAssertNil(answer)
    }

    // MARK: Round-2 (PR #99 Codex) regression cases

    /// Round-2 (1) cap starvation: a first clause with MANY matches cannot
    /// eat maxPassages before the second clause's fact is selected — the
    /// backup-contact fact must still appear.
    func testFirstClauseWithManyMatchesCannotStarveSecondClause() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("capstarve-\(UUID().uuidString).sqlite"))
        var kickoffMentions: [MeetingTranscriptSegment] = []
        for i in 0..<5 {
            kickoffMentions.append(MeetingTranscriptSegment(
                id: "k-seg\(i)", meetingID: "m1", sequence: i, startOffset: Double(i) * 40,
                text: "We talked about the kickoff planning again in item \(i) with more context words here.",
                isFinal: true))
        }
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Many Mentions", workspaceID: "w", segments: kickoffMentions))
        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "Launch Logistics", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "b-seg0", meetingID: "m2", sequence: 0, startOffset: 0,
                text: "The backup contact for the launch is Dana Ruiz.", isFinal: true)]))

        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "When is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "b-seg0" },
                      "second-clause fact starved: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-2 (3) over-emission / lexical-match trap: a single-clause
    /// question emits exactly ONE evidence row — the strongest fact — not
    /// every ranked lexical match.
    func testSingleClauseEmitsOnlyTheTopFact() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.count, 1,
                       "single-clause question emitted multiple rows: \(answer!.sources.map(\.segmentID))")
        XCTAssertEqual(answer!.sources.first?.segmentID, "a-seg1")
    }

    /// Round-2 (2) empty clause: "When and where is the kickoff?" produces
    /// an interrogative-only clause that must be skipped, not crash the
    /// answer with an empty query.
    func testInterrogativeOnlyClauseIsSkippedNotFatal() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When and where is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        let segmentIDs = Set(answer!.sources.map(\.segmentID))
        XCTAssertTrue(segmentIDs.contains("a-seg1"), "kickoff fact missing: \(segmentIDs)")
        XCTAssertTrue(segmentIDs.contains("b-seg0"), "backup-contact fact missing: \(segmentIDs)")
    }

    /// Round-2 (5) decimals/times: terminators between digits do not split
    /// the question into numeric-fragment clauses.
    func testDecimalAndTimeTokensDoNotSplitClauses() {
        XCTAssertEqual(
            GroundedAnswerService.clauseSubQuestions("When is the v1.2 review? What time is the 10:30 demo?").map(\.text),
            ["When is the v1.2 review?", "What time is the 10:30 demo?"]
        )
    }

    /// Round-2 (6) noun phrases: a conjunction NOT followed by an
    /// interrogative never splits ("Sales and Marketing" stays intact).
    func testNounPhraseConjunctionDoesNotSplit() async throws {
        XCTAssertEqual(
            GroundedAnswerService.clauseSubQuestions("Who owns Sales and Marketing?").map(\.text),
            ["Who owns Sales and Marketing?"]
        )

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("nounphrase-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m3", title: "Org", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "o-seg0", meetingID: "m3", sequence: 0, startOffset: 0,
                text: "Dana owns Sales and Marketing this quarter.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "Who owns Sales and Marketing?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "o-seg0" })
    }

    /// Round-3 (1): the cloud passage prompt demands one verbatim sentence
    /// per distinct fact with one citation per fact (no single-sentence
    /// ceiling on the authorized-cloud path).
    func testCloudPassagePromptIsMultiFact() {
        let prompt = OpenAICompatibleResearchProvider.passageGroundedAnswerSystemPrompt
        XCTAssertTrue(prompt.contains("per distinct fact"))
        XCTAssertTrue(prompt.contains("one citation for each sentence"))
        XCTAssertFalse(prompt.contains("exactly one"))
    }

    /// Round-4 (2), variant A — same-passage answer: the pronoun-dependent
    /// clause is rebuilt against its anchor's antecedent ("where is the
    /// kickoff"); when one passage holds the fact, that shared passage
    /// satisfies both clauses (one row, no arbitrary emission).
    func testPronounDependentClauseSamePassageVariant() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions("When is the kickoff and where is it?")
        XCTAssertEqual(clauses.count, 2)
        XCTAssertEqual(clauses[0].text, "When is the kickoff")
        XCTAssertTrue(clauses[1].isAntecedentSubstituted)
        XCTAssertTrue(clauses[1].text.contains("kickoff"), "antecedent substituted: \(clauses[1].text)")

        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff and where is it?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["a-seg1"],
                       "pronoun clause emitted an arbitrary passage")
    }

    /// Round-5 (1): substituted dependent attributes ABSTAIN — the separate
    /// location fact exists, but a rebuilt clause cannot verify it answers
    /// the attribute, so no row is emitted (a wrong location is worse than
    /// no location). The anchor's verified fact still emits.
    func testDependentAttributeAbstainsRatherThanGuessing() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("dep-abstain-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "t-seg0", meetingID: "m1", sequence: 0, startOffset: 10,
                    text: "The kickoff is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "t-seg1", meetingID: "m1", sequence: 1, startOffset: 40,
                    text: "The kickoff takes place in the main auditorium.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "When is the kickoff and where is it?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["t-seg0"],
                       "dependent attribute must abstain, not emit a lexical maybe: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-5 (1): the lexical-maybe trap — "we discussed the kickoff" is
    /// not a location fact and must never be promoted for the dependent
    /// attribute.
    func testDependentAttributeNeverPromotesLexicalMaybe() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("dep-trap-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "u-seg0", meetingID: "m1", sequence: 0, startOffset: 10,
                    text: "The kickoff is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "u-seg1", meetingID: "m1", sequence: 1, startOffset: 40,
                    text: "We discussed the kickoff planning again with the team.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "When is the kickoff and where is it?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["u-seg0"],
                       "lexical maybe promoted for the dependent attribute: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-5 (2): a pronoun-only single clause ("Where is it?") abstains
    /// into noSource — never surfaces emptyQuery as a provider failure.
    func testPronounOnlySingleClauseAbstainsToNoSource() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "Where is it?",
            index: index, workspaceID: "w"
        )
        XCTAssertNil(answer)
    }

    /// Round-6 (1): an anaphoric clause that keeps a real verb ("who owns
    /// it?") is dependent — it abstains instead of searching on the bare
    /// verb and emitting an unrelated ownership passage. Standalone form
    /// abstains too.
    func testAnaphoricVerbClauseAbstains() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("anaphoric-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "Launch Logistics", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "b-seg0", meetingID: "m2", sequence: 0, startOffset: 0,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "o-seg0", meetingID: "m2", sequence: 1, startOffset: 30,
                    text: "The facilities team owns the parking garage.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        let compound = try await service.answer(
            question: "Who is the backup contact and who owns it?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(compound)
        XCTAssertEqual(compound!.sources.map(\.segmentID), ["b-seg0"],
                       "anaphoric verb clause must abstain, not emit the ownership passage: \(compound!.sources.map(\.segmentID))")

        let standalone = try await service.answer(
            question: "Who owns it?",
            index: index, workspaceID: "w"
        )
        XCTAssertNil(standalone, "standalone anaphoric question must abstain")
    }

    /// Round-6 (2): acronym casing is preserved through stopword removal —
    /// "Who owns IT?" searches for the IT department, not the pronoun.
    func testAcronymCasingSurvivesStopwordRemoval() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("acronym-it-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m5", title: "Org", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "it-seg0", meetingID: "m5", sequence: 0, startOffset: 0,
                text: "IT owns the deployment pipeline this year.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        XCTAssertFalse(GroundedAnswerService.containsAnaphoricPronoun("Who owns IT?"))
        XCTAssertTrue(GroundedAnswerService.containsAnaphoricPronoun("Who owns it?"))

        let answer = try await service.answer(
            question: "Who owns IT?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "it-seg0" },
                      "acronym IT must be searchable: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-4 (1): two INDEPENDENT clauses reducing to the same query are
    /// both satisfied by the shared top passage — no weaker lexical
    /// substitute is emitted.
    func testSharedTopPassageSatisfiesBothIndependentClauses() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff and when is the kickoff scheduled?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["a-seg1"],
                       "shared top must satisfy both clauses without substitution: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-3 (3): dotted abbreviations ("Dr. Smith") do not split the
    /// question into fragments.
    func testDottedAbbreviationStaysIntact() {
        XCTAssertEqual(
            GroundedAnswerService.clauseSubQuestions("Who is Dr. Smith and who is the backup contact?").map(\.text),
            ["Who is Dr. Smith", "who is the backup contact?"]
        )
    }

    /// Round-7 (1): contracted openers split clauses — "...and who's the
    /// backup contact?" is a second clause answering its own fact.
    func testContractedOpenerSplitsClauses() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions(
            "When is the kickoff and who's the backup contact?")
        XCTAssertEqual(clauses.map(\.text), ["When is the kickoff", "who's the backup contact?"])

        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff and who's the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["a-seg1", "b-seg0"]),
                       "contraction phrasing must still answer both facts: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-7 (2): a pronoun SUBJECT with an explicit topic is a normal
    /// clause — "What did they decide about the budget?" searches
    /// [decide, budget] and answers; it does not abstain.
    func testPronounSubjectWithExplicitTopicSearchesNormally() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("topic-pronoun-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m6", title: "Budget Call", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "dec-seg0", meetingID: "m6", sequence: 0, startOffset: 0,
                text: "They decide the budget is approved for the auditorium work.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        XCTAssertTrue(GroundedAnswerService.hasSearchableTopic("What did they decide about the budget?"))
        XCTAssertFalse(GroundedAnswerService.hasSearchableTopic("Who owns it?"))

        let answer = try await service.answer(
            question: "What did they decide about the budget?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer, "explicit-topic pronoun clause must not abstain")
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "dec-seg0" })
    }

    /// Round-7 (3): all-caps questions keep their normal threshold —
    /// uppercase stopwords strip case-insensitively (no acronym immunity
    /// inside an all-caps string).
    func testAllCapsQuestionStillSearches() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("allcaps-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m6", title: "Budget Call", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "dec-seg0", meetingID: "m6", sequence: 0, startOffset: 0,
                text: "They decide the budget is approved for the auditorium work.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        let answer = try await service.answer(
            question: "WHAT DID WE DECIDE ABOUT THE BUDGET?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer, "all-caps phrasing must not spuriously abstain")
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "dec-seg0" })
    }

    /// Round-8 (1): "what" opens clauses — "When is X and what is Y?"
    /// answers both facts.
    func testWhatOpenerSplitsClauses() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions(
            "When is the kickoff and what is the launch code?")
        XCTAssertEqual(clauses.map(\.text),
                       ["When is the kickoff", "what is the launch code?"])

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("what-opener-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "w-seg0", meetingID: "m1", sequence: 0, startOffset: 10,
                    text: "The kickoff is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "w-seg1", meetingID: "m1", sequence: 1, startOffset: 40,
                    text: "The launch code is falcon seven two.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "When is the kickoff and what is the launch code?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["w-seg0", "w-seg1"]),
                       "what-opener compound must answer both facts: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-8 (2): a topic-less FIRST clause abstains regardless of
    /// position — "Who owns it and …" never searches the bare verb.
    func testTopicLessFirstClauseAbstains() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("firstless-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "Launch Logistics", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "b-seg0", meetingID: "m2", sequence: 0, startOffset: 0,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "o-seg0", meetingID: "m2", sequence: 1, startOffset: 30,
                    text: "The facilities team owns the parking garage.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "Who owns it and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["b-seg0"],
                       "topic-less first clause must abstain, not search the bare verb: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-8 (3): the all-caps fallback rejects topic-less anaphoric
    /// clauses — "WHO OWNS IT?" abstains.
    func testAllCapsTopicLessAnaphoricAbstains() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("allcapsless-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "Launch Logistics", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "o-seg0", meetingID: "m2", sequence: 1, startOffset: 30,
                text: "The facilities team owns the parking garage.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "WHO OWNS IT?",
            index: index, workspaceID: "w"
        )
        XCTAssertNil(answer, "all-caps topic-less anaphoric clause must abstain")
    }

    /// Round-10 (1): verb-led noun-less factual questions keep their
    /// retrieval behavior — "Who resigned?" answers; the topic gate
    /// abstains only on actual anaphors.
    func testVerbLedQuestionSearchesNormally() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("verbled-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m7", title: "Org Change", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "r-seg0", meetingID: "m7", sequence: 0, startOffset: 0,
                text: "Alice resigned yesterday.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        let single = try await service.answer(
            question: "Who resigned?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(single, "verb-led factual question must not abstain")
        XCTAssertTrue(single!.sources.contains { $0.segmentID == "r-seg0" })

        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "Launch Logistics", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "b-seg0", meetingID: "m2", sequence: 0, startOffset: 0,
                text: "The backup contact for the launch is Dana Ruiz.", isFinal: true)]))
        let compound = try await service.answer(
            question: "Who resigned and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(compound)
        XCTAssertEqual(Set(compound!.sources.map(\.segmentID)), Set(["r-seg0", "b-seg0"]),
                       "verb-led clause must answer alongside the contact fact: \(compound!.sources.map(\.segmentID))")
    }

    /// Round-10 (2): declarative prefaces are context — "We discussed the
    /// launch. Who is the backup contact?" emits only the contact answer,
    /// never the preface''s top lexical match.
    func testDeclarativePrefaceIsContextNotAnswer() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("preface-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m8", title: "Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "p-seg0", meetingID: "m8", sequence: 0, startOffset: 0,
                    text: "We discussed the launch timeline in detail.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "p-seg1", meetingID: "m8", sequence: 1, startOffset: 30,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        XCTAssertFalse(GroundedAnswerService.isAnswerBearing("We discussed the launch timeline in detail."))
        XCTAssertTrue(GroundedAnswerService.isAnswerBearing("who is the backup contact?"))

        let answer = try await service.answer(
            question: "We discussed the launch. Who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["p-seg1"],
                       "declarative preface must not emit an answer claim: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-10 (3): shared leading scope is carried into restarted
    /// clauses — "For Project Atlas, ..." never selects another
    /// project''s contact.
    func testSharedScopeCarriesIntoRestartedClauses() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions(
            "For Project Atlas, when is the kickoff and who is the backup contact?")
        XCTAssertEqual(clauses.count, 2)
        XCTAssertTrue(clauses[1].text.hasPrefix("For Project Atlas,"),
                      "scope not carried: \(clauses[1].text)")

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m9", title: "Atlas Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "at-seg0", meetingID: "m9", sequence: 0, startOffset: 10,
                    text: "The Project Atlas kickoff is scheduled for Friday.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "at-seg1", meetingID: "m9", sequence: 1, startOffset: 40,
                    text: "The Project Atlas backup contact is Dana Ruiz.", isFinal: true),
            ]))
        try index.index(meeting: MeetingManifest(
            meetingID: "m10", title: "Beta Sync", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "be-seg0", meetingID: "m10", sequence: 0, startOffset: 0,
                text: "The Project Beta backup contact is Marcus Lee.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())

        let answer = try await service.answer(
            question: "For Project Atlas, when is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["at-seg0", "at-seg1"]),
                       "scope must constrain both clauses to Atlas: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-11 (1): imperative fragments are answer-bearing — "Tell me
    /// the kickoff date and who is X?" answers BOTH facts (the imperative
    /// clause is not mistaken for scope).
    func testImperativeFragmentAnswers() async throws {
        XCTAssertTrue(GroundedAnswerService.isAnswerBearing("Tell me the kickoff date"))

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("imperative-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "a-seg1", meetingID: "m1", sequence: 1, startOffset: 28,
                    text: "The kickoff date is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "b-seg0", meetingID: "m1", sequence: 2, startOffset: 60,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "Tell me the kickoff date and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["a-seg1", "b-seg0"]),
                       "imperative clause must answer alongside the question: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-11 (2): an auxiliary mid-clause is declarative tense, not a
    /// question — "We were discussing the launch." stays context even
    /// though "were" is an opener word.
    func testAuxiliaryPrefaceStaysContext() async throws {
        XCTAssertFalse(GroundedAnswerService.isAnswerBearing("We were discussing the launch."))

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("auxpreface-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m8", title: "Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "q-seg0", meetingID: "m8", sequence: 0, startOffset: 0,
                    text: "We were discussing the launch timeline in detail.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "q-seg1", meetingID: "m8", sequence: 1, startOffset: 30,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "We were discussing the launch. Who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["q-seg1"],
                       "auxiliary preface must stay context: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-11 (3): the cloud prompt receives the same clause-aware
    /// passage selection as the local provider.
    func testCloudPromptSelectionIsClauseAware() {
        let passages = [
            ResearchGroundingPassage(evidenceID: "e1", passage: "first", sourceType: .priorMeeting),
            ResearchGroundingPassage(evidenceID: "e2", passage: "second", sourceType: .priorMeeting),
            ResearchGroundingPassage(evidenceID: "e3", passage: "third", sourceType: .priorMeeting),
        ]
        let single = OpenAICompatibleResearchProvider.passagesForPrompt(
            passages, questionText: "When is the kickoff?"
        )
        XCTAssertEqual(single.map(\.evidenceID), ["e1"],
                       "single-clause cloud prompt must see only the top passage")

        let multi = OpenAICompatibleResearchProvider.passagesForPrompt(
            passages, questionText: "When is the kickoff and who is the backup contact?"
        )
        XCTAssertEqual(multi.map(\.evidenceID), ["e1", "e2", "e3"],
                       "multi-clause cloud prompt keeps every clause-selected fact")
    }

    /// Round-12 (1): imperative verbs restart clauses — "Tell me X and
    /// show me Y" splits and answers both facts.
    func testImperativeConjunctionRestartSplits() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions(
            "Tell me the kickoff date and show me the backup contact?")
        XCTAssertEqual(clauses.count, 2,
                       "imperative restart must split: \(clauses.map(\.text))")

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("imprestart-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "ir-seg0", meetingID: "m1", sequence: 0, startOffset: 10,
                    text: "The kickoff date is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "ir-seg1", meetingID: "m1", sequence: 1, startOffset: 40,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "Tell me the kickoff date and show me the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["ir-seg0", "ir-seg1"]),
                       "imperative restart must answer both facts: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-12 (2): an interrogative embedded in a declarative is an
    /// indirect question — context, never an answer.
    func testEmbeddedIndirectQuestionIsContext() async throws {
        XCTAssertFalse(GroundedAnswerService.isAnswerBearing("We discussed who owns it."))
        XCTAssertTrue(GroundedAnswerService.isAnswerBearing("For Project Atlas, when is the kickoff"))

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("indirect-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m8", title: "Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "ii-seg0", meetingID: "m8", sequence: 0, startOffset: 0,
                    text: "We discussed who owns the parking garage in depth.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "ii-seg1", meetingID: "m8", sequence: 1, startOffset: 30,
                    text: "The backup contact for the launch is Dana Ruiz.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "We discussed who owns the garage. Who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(answer!.sources.map(\.segmentID), ["ii-seg1"],
                       "indirect question must stay context: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-12 (3): full-path audit — every acronym check is contextual.
    /// Inside an all-caps clause no token gets acronym immunity in the
    /// primary tag loop (WHO/IT are not topics), while mixed-case acronyms
    /// keep theirs.
    func testAllCapsAcronymImmunityAudit() {
        XCTAssertFalse(GroundedAnswerService.hasSearchableTopic("WHO OWNS IT?"),
                       "all-caps acronym must not be a topic in the primary path")
        XCTAssertTrue(GroundedAnswerService.hasSearchableTopic("Who owns IT?"),
                      "mixed-case acronym keeps topic status")
        XCTAssertTrue(GroundedAnswerService.containsAnaphoricPronoun("WHERE IS IT?"),
                      "all-caps IT is a pronoun, not an acronym")
    }

    /// Round-13: a colon after an imperative is not a clause boundary —
    /// "Tell me: kickoff date" stays one clause and answers.
    func testImperativeColonIsNotABoundary() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions("Tell me: kickoff date")
        XCTAssertEqual(clauses.count, 1,
                       "imperative colon must not split: \(clauses.map(\.text))")

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("icolon-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "c-seg0", meetingID: "m1", sequence: 0, startOffset: 10,
                text: "The kickoff date is scheduled for Friday at ten.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "Tell me: kickoff date",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer, "imperative-colon question must not fall into noSource")
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "c-seg0" })
    }

    /// Round-14 — EXEMPTION SCOPE audit category: every delimiter exemption
    /// must be asserted to NOT apply past the first, content-free opening
    /// phrase. Later delimiters always split normally.
    func testColonExemptionScope() async throws {
        // A delimiter after CONTENT splits (the round-14 bug: the kickoff
        // clause used to swallow the contact clause).
        XCTAssertEqual(
            GroundedAnswerService.clauseSubQuestions("When is the kickoff; who is the backup contact?").map(\.text),
            ["When is the kickoff;", "who is the backup contact?"])

        // A SECOND delimiter after an exempted first still splits.
        XCTAssertEqual(
            GroundedAnswerService.clauseSubQuestions("Tell me: kickoff date; show me the backup contact?").count,
            2)

        // End-to-end: the semicolon compound answers both facts.
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "When is the kickoff; who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["a-seg1", "b-seg0"]),
                       "later delimiter must split and answer both facts: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-15 (P1): a genuine scope label before a colon stays attached —
    /// "For Project Atlas: …" keeps its qualifier through the colon.
    func testColonDelimitedScopeLabelPreserved() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions(
            "For Project Atlas: when is the kickoff and who is the backup contact?")
        XCTAssertEqual(clauses.count, 2)
        XCTAssertTrue(clauses[1].text.contains("Atlas"),
                      "scope label not carried: \(clauses[1].text)")

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("colonscope-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m9", title: "Atlas Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "cs-seg0", meetingID: "m9", sequence: 0, startOffset: 10,
                    text: "The Project Atlas kickoff is scheduled for Friday.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "cs-seg1", meetingID: "m9", sequence: 1, startOffset: 40,
                    text: "The Project Atlas backup contact is Dana Ruiz.", isFinal: true),
            ]))
        try index.index(meeting: MeetingManifest(
            meetingID: "m10", title: "Beta Sync", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "cb-seg0", meetingID: "m10", sequence: 0, startOffset: 0,
                text: "The Project Beta backup contact is Marcus Lee.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "For Project Atlas: when is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["cs-seg0", "cs-seg1"]),
                       "colon scope label must constrain both clauses to Atlas: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-15 (P2): a declarative prepositional preface is context, not
    /// scope — its words never propagate into the restarted question.
    func testDeclarativePrepositionalPrefaceIsNotScope() async throws {
        XCTAssertFalse(GroundedAnswerService.isScopePhrase(
            ["In", "yesterday's", "meeting", "we", "discussed", "hiring,"]))
        XCTAssertTrue(GroundedAnswerService.isScopePhrase(["For", "Project", "Atlas:"]))

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("notscope-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m8", title: "Sync", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "ns-seg0", meetingID: "m8", sequence: 0, startOffset: 0,
                text: "The backup contact for the launch is Dana Ruiz.", isFinal: true)]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "In yesterday's meeting we discussed hiring, and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer,
                       "declarative preface terms must not raise the retrieval threshold")
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "ns-seg0" })
    }

    /// Round-16 (1): negative contractions normalize to their auxiliary —
    /// "…and isn't the budget approved?" splits and answers.
    func testNegativeContractionRestartSplits() async throws {
        let clauses = GroundedAnswerService.clauseSubQuestions(
            "When is the kickoff and isn't the budget approved?")
        XCTAssertEqual(clauses.count, 2,
                       "negative-contraction restart must split: \(clauses.map(\.text))")

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("negcontr-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "nc-seg0", meetingID: "m1", sequence: 0, startOffset: 10,
                    text: "The kickoff is scheduled for Friday at ten.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "nc-seg1", meetingID: "m1", sequence: 1, startOffset: 40,
                    text: "The budget is approved and final.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "When is the kickoff and isn't the budget approved?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["nc-seg0", "nc-seg1"]),
                       "negative-contraction compound must answer both facts: \(answer!.sources.map(\.segmentID))")
    }

    /// Round-16 (2): the scoped core accepts auxiliary inversions —
    /// "For Project Atlas, is the kickoff Monday and who is X?" answers
    /// both facts.
    func testScopedAuxiliaryOpenerAnswers() async throws {
        XCTAssertTrue(GroundedAnswerService.isAnswerBearing("For Project Atlas, is the kickoff Monday"))

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("scopedaux-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m9", title: "Atlas Sync", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "sa-seg0", meetingID: "m9", sequence: 0, startOffset: 10,
                    text: "The Project Atlas kickoff is on Monday morning.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "sa-seg1", meetingID: "m9", sequence: 1, startOffset: 40,
                    text: "The Project Atlas backup contact is Dana Ruiz.", isFinal: true),
            ]))
        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        let answer = try await service.answer(
            question: "For Project Atlas, is the kickoff Monday and who is the backup contact?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer)
        XCTAssertEqual(Set(answer!.sources.map(\.segmentID)), Set(["sa-seg0", "sa-seg1"]),
                       "scoped auxiliary compound must answer both facts: \(answer!.sources.map(\.segmentID))")
    }

    // MARK: Build 25 carry-in from PR #99 live re-verification

    /// A request preamble changes the grammatical position of "when", but
    /// it must remain grammar rather than becoming a mandatory search term.
    func testBuild25BareImperativeAnswersBothFacts() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "Tell me when is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )

        guard let answer else { return XCTFail("imperative request unexpectedly abstained") }
        XCTAssertEqual(Set(answer.sources.map(\.segmentID)), Set(["a-seg1", "b-seg0"]),
                       "imperative preamble must not make 'when' a required fact term")
    }

    /// Politeness before an imperative is still a direct request. The first
    /// clause must not be discarded just because "tell" is not word zero.
    func testBuild25PoliteImperativeAnswersBothFacts() async throws {
        XCTAssertTrue(GroundedAnswerService.isAnswerBearing("Please tell me the kickoff"))

        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "Please tell me when is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )

        guard let answer else { return XCTFail("polite imperative unexpectedly abstained") }
        XCTAssertEqual(Set(answer.sources.map(\.segmentID)), Set(["a-seg1", "b-seg0"]),
                       "polite imperative must retain the first requested fact")
    }

    /// The live comma-scoped phrasing must keep its first fact. Scope words
    /// provide context; they cannot raise the fact-match threshold so high
    /// that a directly matching passage is discarded.
    func testBuild25CommaScopedCompoundAnswersBothFacts() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(
            question: "For the Thursday demo, when is the kickoff and who is the backup contact?",
            index: index, workspaceID: "w"
        )

        guard let answer else { return XCTFail("comma-scoped request unexpectedly abstained") }
        XCTAssertEqual(Set(answer.sources.map(\.segmentID)), Set(["a-seg1", "b-seg0"]),
                       "comma-scoped request must retain both requested facts")
    }

    /// Scope length is not a semantic boundary. A longer genuine scope must
    /// constrain every restarted clause so another project's equally named
    /// facts cannot be selected.
    func testBuild25LongScopeConstrainsCompoundToNamedProject() async throws {
        let question = "For the Project Atlas mobile app, when is the kickoff and who is the backup contact?"
        let clauses = GroundedAnswerService.clauseSubQuestions(question)
        XCTAssertEqual(clauses.count, 2)
        XCTAssertTrue(clauses[1].text.hasPrefix("For the Project Atlas mobile app,"),
                      "long scope was not propagated: \(clauses.map(\.text))")

        let (index, service) = try makeProjectScopedFixture()
        let answer = try await service.answer(question: question, index: index, workspaceID: "w")

        guard let answer else { return XCTFail("long-scoped compound unexpectedly abstained") }
        XCTAssertEqual(Set(answer.sources.map(\.segmentID)), Set(["atlas-kickoff", "atlas-contact"]),
                       "long scope must not leak into Project Beta: \(answer.sources.map(\.segmentID))")
    }

    /// The same longer scope on a single question must retrieve the named
    /// project's fact instead of failing closed because framing words became
    /// mandatory evidence terms.
    func testBuild25LongScopeSingleClauseRetrievesNamedProject() async throws {
        let (index, service) = try makeProjectScopedFixture()
        let answer = try await service.answer(
            question: "For the Project Atlas mobile app, when is the kickoff?",
            index: index, workspaceID: "w"
        )

        guard let answer else { return XCTFail("long-scoped single question unexpectedly abstained") }
        XCTAssertEqual(answer.sources.map(\.segmentID), ["atlas-kickoff"],
                       "long single-clause scope must select Project Atlas")
    }

    /// A partly matching named scope is ambiguous. If "Project" exists but
    /// the requested project name does not, abstain rather than borrow the
    /// same fact from Atlas or Beta.
    func testUnknownNamedScopeCannotUseCorpusWithNoScopeWords() async throws {
        let (index, service) = try makeFixture()
        let answer = try await service.answer(question: "For Project Gamma, when is the kickoff?",
            index: index, workspaceID: "w")
        XCTAssertNil(answer, "An explicit unknown project cannot borrow the unscoped Friday kickoff.")
    }

    func testBuild25UnknownNamedScopeAbstainsRatherThanLeaksProjects() async throws {
        let (index, service) = try makeProjectScopedFixture()
        let answer = try await service.answer(
            question: "For Project Gamma, when is the kickoff?",
            index: index, workspaceID: "w"
        )

        XCTAssertNil(answer, "unknown Project Gamma must not select Atlas or Beta")
    }

    /// Round-2 (7) cross-clause contradiction: a negated fact about a
    /// DIFFERENT topic than another clause must not void the whole answer.
    func testCrossClauseContradictionDoesNotVoidAnswer() async throws {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("xclause-\(UUID().uuidString).sqlite"))
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "Kickoff Planning", workspaceID: "w",
            segments: [MeetingTranscriptSegment(
                id: "a-seg1", meetingID: "m1", sequence: 1, startOffset: 28,
                text: "The kickoff is scheduled for Friday at ten.", isFinal: true)]))
        try index.index(meeting: MeetingManifest(
            meetingID: "m4", title: "Budget", workspaceID: "w",
            segments: [
                MeetingTranscriptSegment(
                    id: "z-seg0", meetingID: "m4", sequence: 0, startOffset: 0,
                    text: "The budget was not approved this quarter.", isFinal: true),
                MeetingTranscriptSegment(
                    id: "z-seg1", meetingID: "m4", sequence: 1, startOffset: 20,
                    text: "The budget is approved and final.", isFinal: true),
            ]))

        let service = GroundedAnswerService(provider: LocalEvidenceResearchProvider())
        // Clause 1 (kickoff) and clause 2 (budget approval) are unrelated;
        // the budget meeting contains a negated/affirmative pair, but the
        // cross-clause pair must never be compared.
        let answer = try await service.answer(
            question: "When is the kickoff and is the budget approved?",
            index: index, workspaceID: "w"
        )
        XCTAssertNotNil(answer, "cross-clause comparison voided a legitimate multi-fact answer")
        XCTAssertTrue(answer!.sources.contains { $0.segmentID == "a-seg1" })
    }
}
