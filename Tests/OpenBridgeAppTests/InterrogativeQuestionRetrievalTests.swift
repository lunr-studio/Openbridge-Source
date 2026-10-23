import XCTest
@testable import OpenBridgeApp

/// lunr-studio/Openbridge-Beta#299 (Build 24, checkpoint finding 2):
/// interrogatives (when/who/...) must not count toward the strict-majority
/// match postfilter. Before the fix, "When is the kickoff?" abstained
/// because `when` inflated minTermHits to 2 while the kickoff segment hit
/// only 1 term; compound questions with when/who failed the same way.
final class InterrogativeQuestionRetrievalTests: XCTestCase {

    private func makeIndex() throws -> WorkspaceRetrievalIndex {
        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("interrog-\(UUID().uuidString).sqlite"))

        let kickoff = MeetingTranscriptSegment(
            id: "s-kick", meetingID: "m1", sequence: 0, startOffset: 10,
            text: "The kickoff is scheduled for Friday morning.", isFinal: true)
        let backup = MeetingTranscriptSegment(
            id: "s-back", meetingID: "m2", sequence: 0, startOffset: 5,
            text: "The backup contact for the launch is Dana.", isFinal: true)
        var filler: [MeetingTranscriptSegment] = []
        for i in 0..<8 {
            filler.append(MeetingTranscriptSegment(
                id: "s-f\(i)", meetingID: "m1", sequence: 10 + i, startOffset: 100 + Double(i) * 30,
                text: "Filler discussion about budget planning item number \(i) continues.", isFinal: true))
        }
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "A", workspaceID: "w", segments: [kickoff] + filler))
        try index.index(meeting: MeetingManifest(
            meetingID: "m2", title: "B", workspaceID: "w", segments: [backup]))
        return index
    }

    private func ask(_ index: WorkspaceRetrievalIndex, _ question: String) throws -> [WorkspacePassageMatch]? {
        try index.searchOrAbstain(
            ReplayHarness.retrievalQuery(for: question), workspaceID: "w", rawQuestion: question)
    }

    /// Regression: when-prefixed single-fact question matches the fact.
    func testWhenQuestionMatchesSingleFact() throws {
        let index = try makeIndex()
        let result = try ask(index, "When is the kickoff?")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains { $0.segmentID == "s-kick" })
    }

    /// Regression: who-prefixed single-fact question matches the fact.
    func testWhoQuestionMatchesSingleFact() throws {
        let index = try makeIndex()
        let result = try ask(index, "Who is the backup contact for the launch?")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains { $0.segmentID == "s-back" })
    }

    /// Compound question: no longer abstains wholesale; the extractive
    /// provider returns the segments that DO hold a majority of the
    /// non-interrogative content terms (here: the backup-contact segment;
    /// the kickoff segment still needs 2 of {kickoff, backup, contact}).
    func testCompoundQuestionDoesNotWholesaleAbstain() throws {
        let index = try makeIndex()
        let result = try ask(index, "When is the kickoff and who is the backup contact?")
        XCTAssertNotNil(result, "compound question must not abstain wholesale")
        XCTAssertTrue(result!.contains { $0.segmentID == "s-back" })
    }

    /// Abstention still works for genuinely unrelated questions.
    func testUnrelatedQuestionStillAbstains() throws {
        let index = try makeIndex()
        XCTAssertNil(try ask(index, "What color is the company bicycle shelter?"))
    }

    /// Fix-cycle P1: interrogative-only rows must not be able to fill the
    /// FTS candidate pool (LIMIT*4) and starve the fact passage at scale.
    func testInterrogativeRowsCannotStarveCandidatePool() throws {
        var config = WorkspaceRetrievalConfiguration()
        config.defaultResultLimit = 1  // candidate pool = 4 rows
        let index = try WorkspaceRetrievalIndex(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("starve-\(UUID().uuidString).sqlite"),
            configuration: config
        )

        var noise: [MeetingTranscriptSegment] = []
        for i in 0..<5 {
            noise.append(MeetingTranscriptSegment(
                id: "s-n\(i)", meetingID: "m1", sequence: i, startOffset: Double(i) * 10,
                text: "Question about when the vendor who ships parts responds",
                isFinal: true))
        }
        let fact = MeetingTranscriptSegment(
            id: "s-kick2", meetingID: "m1", sequence: 90, startOffset: 500,
            text: "The kickoff is scheduled for Friday morning and we also discussed the agenda, catering, parking, badges, av setup, and the guest list for the session.",
            isFinal: true)
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "A", workspaceID: "w", segments: noise + [fact]))

        let result = try ask(index, "When is the kickoff?")
        XCTAssertNotNil(result, "fact passage starved by interrogative-only rows")
        XCTAssertTrue(result?.contains { $0.segmentID == "s-kick2" } == true)
    }

    /// The pure helper drops QUESTION-WORD interrogatives only (by
    /// position in the raw question; see round-3 acronym fix).
    func testContentTermsDropQuestionWordInterrogativesOnly() {
        let question = "When is the kickoff and who is the backup contact?"
        XCTAssertEqual(
            WorkspaceRetrievalIndex.contentTerms(
                ReplayHarness.retrievalQuery(for: question), rawQuestion: question
            ),
            ["kickoff", "backup", "contact"]
        )
    }

    /// Round-3 (P2 acronym collision): "What did WHO recommend?" keeps
    /// `who` as a required content term.
    func testAcronymInterrogativeKeptAsContent() throws {
        let question = "What did WHO recommend?"
        XCTAssertEqual(
            WorkspaceRetrievalIndex.contentTerms(
                ReplayHarness.retrievalQuery(for: question), rawQuestion: question
            ),
            ["who", "recommend"]
        )

        let index = try WorkspaceRetrievalIndex(databaseURL: FileManager.default
            .temporaryDirectory.appendingPathComponent("who-org-\(UUID().uuidString).sqlite"))
        let whoSegment = MeetingTranscriptSegment(
            id: "s-who", meetingID: "m1", sequence: 0, startOffset: 10,
            text: "WHO recommends updated boosters this season.", isFinal: true)
        try index.index(meeting: MeetingManifest(
            meetingID: "m1", title: "A", workspaceID: "w", segments: [whoSegment]))

        let result = try index.searchOrAbstain(
            ReplayHarness.retrievalQuery(for: question), workspaceID: "w", rawQuestion: question)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains { $0.segmentID == "s-who" })
    }

    /// The position classifier: clause-leading interrogatives are question
    /// words; everything else is content. Conjunction-led clauses included.
    func testQuestionWordIndicesByPosition() {
        XCTAssertEqual(
            WorkspaceRetrievalIndex.questionWordIndices(
                inRaw: "When is the kickoff and who did who recommend?"),
            [0, 5]
        )
    }

    /// Round-4 (P2 two-sentence boundary): sentence-terminating punctuation
    /// also starts a clause — the second interrogative in "When is X?
    /// Who is Y?" is a question word too.
    func testQuestionWordIndicesAcrossSentenceBoundary() {
        XCTAssertEqual(
            WorkspaceRetrievalIndex.questionWordIndices(
                inRaw: "When is the kickoff? Who is the backup contact?"),
            [0, 4]
        )
    }

    /// Round-4 (P2 two-sentence boundary): both question words drop, so a
    /// two-sentence question searches its two facts.
    func testTwoSentenceQuestionDropsBothQuestionWords() {
        let question = "When is the kickoff? Who is the backup contact?"
        XCTAssertEqual(
            WorkspaceRetrievalIndex.contentTerms(
                ReplayHarness.retrievalQuery(for: question), rawQuestion: question
            ),
            ["kickoff", "backup", "contact"]
        )
    }

    /// Round-4 (P2 clause-leading acronym): "WHO recommended boosters?"
    /// keeps the clause-leading WHO — acronym casing beats position.
    func testClauseLeadingAcronymKeptAsContent() {
        let question = "WHO recommended boosters?"
        XCTAssertEqual(
            WorkspaceRetrievalIndex.contentTerms(
                ReplayHarness.retrievalQuery(for: question), rawQuestion: question
            ),
            ["who", "recommended", "boosters"]
        )
    }
}