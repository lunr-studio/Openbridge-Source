import Foundation
import Testing
@testable import OpenBridgeApp
import OpenBridgeUI

// MARK: - Workspace Retrieval Index Tests (#306)
//
// Quality suite over a deterministic 24-meeting fixture corpus (per the
// issue's "20+ meeting fixture corpus" requirement), plus unit coverage
// for incremental indexing, deletion, rebuild, ranking, workspace scoping,
// abstention, and query sanitization.
//
// NOTE on query semantics: FTS5 queries use AND — every term must appear
// in the SAME passage of the expected meeting. Probes are written
// accordingly.

@Suite(.serialized) struct WorkspaceRetrievalIndexTests {

    // MARK: - Fixture Corpus (24 meetings)

    /// Deterministic corpus: 24 synthetic meetings across two workspaces
    /// with distinct topical content per meeting.
    private struct Corpus {
        let meetings: [MeetingManifest]
        let acmeMeetings: [MeetingManifest]
        let personalMeetings: [MeetingManifest]

        static func make() -> Corpus {
            let acmeTopics: [(String, [String])] = [
                ("Launch Planning", [
                    "We decided to move the launch date to September fifteenth.",
                    "The beta milestone depends on the design freeze next week.",
                    "Action item: Alex will follow up with legal on the trademark.",
                ]),
                ("Budget Review", [
                    "The budget approval from finance is still pending.",
                    "Marketing spend was reduced to protect the runway.",
                    "We should revisit the budget after the launch metrics arrive.",
                ]),
                ("API Design Review", [
                    "Decision: the new API will use REST instead of GraphQL.",
                    "Pagination was the most debated aspect of the API design.",
                    "The team agreed on cursor based pagination for the endpoint.",
                ]),
                ("Hiring Sync", [
                    "We decided to open a senior engineering role in October.",
                    "The interview loop needs a system design stage added.",
                    "Action item: post the job listing by Friday.",
                ]),
                ("Security Audit", [
                    "The penetration test found no critical vulnerabilities.",
                    "We agreed to rotate all API keys quarterly.",
                    "Two factor authentication rollout begins next sprint.",
                ]),
                ("Customer Feedback", [
                    "Customers repeatedly requested a dark mode interface.",
                    "The onboarding flow confuses new users according to surveys.",
                    "Decision: prioritize dark mode in the next release cycle.",
                ]),
                ("Infrastructure", [
                    "The deployment pipeline now builds in under ten minutes.",
                    "We migrated the staging environment to the new cloud region.",
                    "Kubernetes cluster autoscaling was enabled for cost savings.",
                ]),
                ("Quarterly Roadmap", [
                    "The roadmap includes three major releases this quarter.",
                    "Strategic priorities are retention, reliability, and revenue.",
                    "Each release will ship behind a feature flag initially.",
                ]),
                ("Pricing Discussion", [
                    "We debated raising the starter tier price by two dollars.",
                    "Enterprise contracts keep the annual discount structure.",
                    "Decision: keep current pricing until the launch review.",
                ]),
                ("Mobile Strategy", [
                    "The iOS app will share networking code with the server SDK.",
                    "Offline support is the top requested mobile feature.",
                    "We agreed to delay the Android app until next year.",
                ]),
                ("Partnership Review", [
                    "The integration partner completed the sandbox certification.",
                    "Contract renewal terms were sent to legal for review.",
                    "Both sides agreed on quarterly business reviews.",
                ]),
                ("Data Migration", [
                    "The legacy database migration completed without downtime.",
                    "Backfill jobs will run nightly until the archive is empty.",
                    "We verified row counts match between old and new systems.",
                ]),
            ]

            let personalTopics: [(String, [String])] = [
                ("Portuguese Study Plan", [
                    "I decided to practice Portuguese for twenty minutes daily.",
                    "The flashcard deck focuses on travel vocabulary this month.",
                    "Speaking practice with the tutor happens every Tuesday.",
                ]),
                ("Apartment Search", [
                    "The two bedroom apartment on Elm street fits the budget.",
                    "Decision: submit the application before the Friday deadline.",
                    "The landlord requires two references and proof of income.",
                ]),
                ("Wedding Planning", [
                    "The venue booking for June was confirmed this week.",
                    "We set the guest list target at seventy five people.",
                    "Catering deposits are due by the end of the month.",
                ]),
                ("Fitness Goals", [
                    "I will train for the half marathon in November.",
                    "Strength training is scheduled on Mondays and Thursdays.",
                    "The running plan peaks at ten miles before the race.",
                ]),
                ("Book Club", [
                    "This month the club reads a novel by Saramago.",
                    "Decision: the next meeting discusses the final three chapters.",
                    "Members voted to include more nonfiction next season.",
                ]),
                ("Home Renovation", [
                    "The kitchen renovation budget was approved at eight thousand.",
                    "We chose quartz countertops over marble for durability.",
                    "The contractor starts demolition in the first week of March.",
                ]),
                ("Tax Preparation", [
                    "All charitable receipts were gathered for the accountant.",
                    "The filing deadline extension was approved until October.",
                    "Decision: switch to the new accountant starting this year.",
                ]),
                ("Trip to Lisbon", [
                    "Flights to Lisbon were booked for the spring holiday.",
                    "The itinerary includes two days in Sintra for the palaces.",
                    "Pastel de nata tasting is non negotiable according to Ana.",
                ]),
                ("Volunteer Schedule", [
                    "The shelter needs volunteers on weekend mornings.",
                    "I committed to the Saturday food sorting shift monthly.",
                    "Training for new volunteers happens the first Sunday.",
                ]),
                ("Car Maintenance", [
                    "The tire rotation and oil change are due next week.",
                    "The mechanic quoted four hundred for the brake service.",
                    "Decision: replace the battery before winter arrives.",
                ]),
                ("Garden Planning", [
                    "Tomato and basil seedlings were started indoors.",
                    "The raised beds need fresh soil before planting season.",
                    "We agreed to try drip irrigation this summer.",
                ]),
                ("Course Enrollment", [
                    "Enrollment in the statistics course closed yesterday.",
                    "The waitlist moves quickly according to the registrar.",
                    "Decision: take the machine learning course in spring instead.",
                ]),
            ]

            func makeMeeting(index: Int, topic: (String, [String]), workspace: String) -> MeetingManifest {
                let segments = topic.1.enumerated().map { offset, text in
                    MeetingTranscriptSegment(
                        meetingID: "m-\(workspace)-\(index)",
                        sequence: offset,
                        sourceLabel: "Room",
                        text: text
                    )
                }
                return MeetingManifest(
                    meetingID: "m-\(workspace)-\(index)",
                    title: topic.0,
                    workspaceID: workspace,
                    state: .completed,
                    segments: segments
                )
            }

            let acme = acmeTopics.enumerated().map { index, topic in
                makeMeeting(index: index, topic: topic, workspace: "acme")
            }
            let personal = personalTopics.enumerated().map { index, topic in
                makeMeeting(index: index, topic: topic, workspace: "personal")
            }
            return Corpus(
                meetings: acme + personal,
                acmeMeetings: acme,
                personalMeetings: personal
            )
        }
    }

    // MARK: - Helpers

    private func makeIndex(label: String = UUID().uuidString) throws -> (index: WorkspaceRetrievalIndex, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-index-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try WorkspaceRetrievalIndex(
            databaseURL: root.appendingPathComponent("index.sqlite")
        )
        return (index, root)
    }

    // MARK: - Indexing Lifecycle

    @Test func indexingIsIncrementalAndIdempotent() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()

        try index.index(meeting: corpus.meetings[0])
        #expect(index.indexedSegmentCount == 3)
        #expect(index.indexedMeetingIDs == ["m-acme-0"])

        // Re-indexing the same meeting must not duplicate rows.
        try index.index(meeting: corpus.meetings[0])
        #expect(index.indexedSegmentCount == 3)

        try index.index(meeting: corpus.meetings[1])
        #expect(index.indexedSegmentCount == 6)
        #expect(index.indexedMeetingIDs.count == 2)
    }

    @Test func indexingPicksUpTranscriptEdits() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        try index.index(meeting: meeting)

        meeting.segments[0] = MeetingTranscriptSegment(
            id: meeting.segments[0].id,
            meetingID: meeting.meetingID,
            sequence: 0,
            sourceLabel: "Room",
            text: "Completely different content about kite surfing.",
            isFinal: true
        )
        try index.index(meeting: meeting)

        let oldMatches = try index.search("launch date september")
        let newMatches = try index.search("kite surfing")
        #expect(oldMatches.filter { $0.meetingID == meeting.meetingID }.isEmpty)
        #expect(!newMatches.isEmpty)
    }

    @Test func deletionRemovesAllMeetingRows() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.acmeMeetings { try index.index(meeting: meeting) }
        #expect(index.indexedSegmentCount == corpus.acmeMeetings.count * 3)

        try index.removeMeeting(meetingID: "m-acme-0")
        #expect(index.indexedSegmentCount == corpus.acmeMeetings.count * 3 - 3)
        #expect(!index.indexedMeetingIDs.contains("m-acme-0"))

        // Deleted meeting's content is no longer retrievable.
        let matches = try index.search("trademark")
        #expect(matches.allSatisfy { $0.meetingID != "m-acme-0" })
    }

    @Test func rebuildReplacesEntireIndex() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()

        for meeting in corpus.meetings { try index.index(meeting: meeting) }
        #expect(index.indexedSegmentCount == corpus.meetings.count * 3)

        // Rebuild with only the personal workspace.
        try index.rebuild(meetings: corpus.personalMeetings)
        #expect(index.indexedSegmentCount == corpus.personalMeetings.count * 3)
        #expect(!index.indexedMeetingIDs.contains { $0.hasPrefix("m-acme") })
    }

    @Test func indexPersistsAcrossReopen() throws {
        let (index, root) = try makeIndex()
        let corpus = Corpus.make()
        try index.index(meeting: corpus.meetings[0])
        // Deliberately do not remove root; reopen from the same file.
        let reopened = try WorkspaceRetrievalIndex(
            databaseURL: root.appendingPathComponent("index.sqlite")
        )
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(reopened.indexedSegmentCount == 3)
    }

    // MARK: - Search Quality (fixture corpus)

    @Test func corpusHasAtLeastTwentyMeetings() throws {
        let corpus = Corpus.make()
        #expect(corpus.meetings.count >= 20)
        #expect(corpus.acmeMeetings.count == 12)
        #expect(corpus.personalMeetings.count == 12)
    }

    @Test func exactTopicQueryRanksCorrectMeetingFirst() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        // Every term in a probe co-occurs in one passage of the expected
        // meeting (FTS5 AND semantics).
        let probes: [(query: String, expectedMeeting: String)] = [
            ("launch date september", "m-acme-0"),
            ("budget approval finance", "m-acme-1"),
            ("REST GraphQL", "m-acme-2"),
            ("senior engineering role", "m-acme-3"),
            ("penetration test vulnerabilities", "m-acme-4"),
            ("dark mode interface", "m-acme-5"),
            ("deployment pipeline builds", "m-acme-6"),
            ("roadmap three releases", "m-acme-7"),
            ("starter tier price", "m-acme-8"),
            ("offline mobile feature", "m-acme-9"),
            ("partner sandbox certification", "m-acme-10"),
            ("legacy database migration", "m-acme-11"),
        ]

        for probe in probes {
            let matches = try index.search(probe.query, limit: 3)
            let top = try #require(matches.first, "No results for \(probe.query)")
            #expect(top.meetingID == probe.expectedMeeting,
                    "Top hit for '\(probe.query)' was \(top.meetingID), expected \(probe.expectedMeeting)")
        }
    }

    @Test func personalTopicQueriesRankCorrectly() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let probes: [(query: String, expectedMeeting: String)] = [
            ("practice portuguese daily", "m-personal-0"),
            ("bedroom apartment elm", "m-personal-1"),
            ("venue booking june", "m-personal-2"),
            ("half marathon november", "m-personal-3"),
            ("novel saramago month", "m-personal-4"),
            ("quartz countertops marble", "m-personal-5"),
            ("charitable receipts accountant", "m-personal-6"),
            ("flights lisbon spring", "m-personal-7"),
            ("shelter weekend mornings", "m-personal-8"),
            ("tire rotation oil", "m-personal-9"),
            ("tomato basil seedlings", "m-personal-10"),
            ("statistics course closed", "m-personal-11"),
        ]

        for probe in probes {
            let matches = try index.search(probe.query, limit: 3)
            let top = try #require(matches.first, "No results for \(probe.query)")
            #expect(top.meetingID == probe.expectedMeeting,
                    "Top hit for '\(probe.query)' was \(top.meetingID)")
        }
    }

    @Test func resultsCarryFullSourceReferences() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let matches = try index.search("launch date september", limit: 2)
        let top = try #require(matches.first)
        #expect(!top.meetingID.isEmpty)
        #expect(top.workspaceID == "acme")
        #expect(!top.segmentID.isEmpty)
        #expect(top.sourceLabel == "Room")
        #expect(!top.passage.isEmpty)
        #expect(top.passage == corpus.acmeMeetings[0].segments[0].text)
    }

    @Test func rankingOrdersByDescendingRelevance() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let matches = try index.search("launch roadmap", limit: 10)
        let scores = matches.map(\.relevanceScore)
        #expect(scores == scores.sorted(by: >))
    }

    @Test func porterStemmingMatchesWordForms() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        // "decision" appears verbatim in several passages.
        let singular = try index.search("decision")
        #expect(!singular.isEmpty)
        // "migrating" should match "migration" via porter stemming.
        let gerund = try index.search("migrating legacy")
        #expect(!gerund.isEmpty)
    }

    @Test func workspaceScopingRestrictsResults() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let scoped = try index.search("decision", workspaceID: "personal", limit: 10)
        #expect(!scoped.isEmpty)
        #expect(scoped.allSatisfy { $0.workspaceID == "personal" })

        let otherScope = try index.search("kubernetes", workspaceID: "personal", limit: 10)
        #expect(otherScope.isEmpty)
    }

    @Test func limitCapsResultCount() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let matches = try index.search("decision", limit: 4)
        #expect(matches.count <= 4)
    }

    // MARK: - Abstention

    @Test func searchOrAbstainReturnsResultsForStrongMatches() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let result = try index.searchOrAbstain("launch date september")
        #expect(result != nil)
        #expect(result?.first?.meetingID == "m-acme-0")
    }

    @Test func searchOrAbstainReturnsNilWhenNoMatches() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        let result = try index.searchOrAbstain("quantum holography zephyr")
        #expect(result == nil)
    }

    @Test func searchOrAbstainReturnsNilWithoutMatches() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        try index.rebuild(meetings: Corpus.make().meetings)
        // Nothing in the corpus resembles this.
        let abstained = try index.searchOrAbstain("zzzqxvv nonexistent topic", workspaceID: "acme")
        #expect(abstained == nil)
    }

    // MARK: - #299 round-6: question-echo suppression (74D489F3 evidence)

    @Test func questionEchoDoesNotOutrankTheFact() throws {
        // Verbatim from the 74D489F3 meeting: spoken question echoes
        // outranked the fact-bearing passage (0.769/0.685/0.470 vs 0.318).
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        // FTS5 ANDs every query term, so the fact-bearing row must also
        // contain the question words — exactly like the real 60s segment
        // that bundled the question and its answer.
        meeting.segments = [
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 0, sourceLabel: "Room",
                                     text: "Okay so what did we decide about the launch date? We decided the launch date is September 15th, everyone agreed.", isFinal: true),
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 1, sourceLabel: "Room",
                                     text: "What did we decide about the launch date?", isFinal: true),
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 2, sourceLabel: "Room",
                                     text: "Open bridge. What did we decide about the launch date?", isFinal: true)
        ]
        try index.index(meeting: meeting)

        let results = try index.search("What did we decide about the launch date?")
        guard let top = results.first else {
            Issue.record("expected results"); return
        }
        // The fact-bearing segment (0) must outrank every pure echo,
        // and the exact stored segment must retain the fact text.
        #expect(top.sequence == 0)
        #expect(top.passage.contains("September 15"))
        // Echoes are demoted, never deleted (fact + at least one echo).
        // Pure echoes may be diversity-collapsed into the bundled fact
        // (its question sentence contains the echo text), so only
        // non-emptiness is guaranteed for the final cut.
        #expect(!results.isEmpty)
    }

    // Round-7: the live failure — statement-only fact (no bundled
    // question) must outrank spoken/typed echoes of the question.
    @Test func statementOnlyFactBeatsEchoes() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        meeting.segments = [
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 0, sourceLabel: "Room",
                                     text: "We decided the launch date is September fifteenth.", isFinal: true),
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 1, sourceLabel: "Room",
                                     text: "What did we decide about the launch date?", isFinal: true),
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 2, sourceLabel: "Room",
                                     text: "Open bridge. What did we decide about the launch date?", isFinal: true)
        ]
        try index.index(meeting: meeting)

        let raw = "What did we decide about the launch date?"
        let results = try index.search(
            ReplayHarness.retrievalQuery(for: raw),
            rawQuestion: raw
        )
        guard let top = results.first else {
            Issue.record("expected results"); return
        }
        #expect(top.sequence == 0)
        #expect(results.count >= 2)
    }

    // Round-8 (live evidence: top=3.79e-06, gate=0.15): a fresh 2-segment
    // index must still answer — IDF epsilon collapse must not abstain.
    @Test func tinyCorpusStillAnswers() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        meeting.segments = [
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 0, sourceLabel: "Room",
                                     text: "We decided the launch date is September fifteenth.", isFinal: true),
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 1, sourceLabel: "Room",
                                     text: "What did we decide about the launch date?", isFinal: true)
        ]
        try index.index(meeting: meeting)
        #expect(index.indexedSegmentCount == 2)

        let raw = "What did we decide about the launch date?"
        let answered = try index.searchOrAbstain(
            ReplayHarness.retrievalQuery(for: raw),
            workspaceID: meeting.workspaceID,
            rawQuestion: raw
        )
        #expect(answered != nil)
        #expect(answered?.first?.passage.contains("September") == true)
    }

    // Round-10 (live evidence): with SQL LIMIT applied before demotion,
    // a cluster of question-bearing narration passages filled every
    // slot and the fact never reached the provider. Over-fetching a 4x
    // candidate pool must let the fact surface in the final cut.
    @Test func factSurvivesEchoClusterUnderLimit() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        let raw = "What did we decide about the launch date?"
        var segments = [
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 0, sourceLabel: "Room",
                                     text: "We decided the launch date is September fifteenth.", isFinal: true)
        ]
        for i in 1...6 {
            segments.append(MeetingTranscriptSegment(
                meetingID: meeting.id, sequence: i, sourceLabel: "Room",
                text: "Okay. \(raw) Let me say it again for the recording. Testing.",
                isFinal: true
            ))
        }
        meeting.segments = segments
        try index.index(meeting: meeting)

        let results = try index.search(
            ReplayHarness.retrievalQuery(for: raw),
            limit: 4,
            rawQuestion: raw
        )
        // The fact passage must be inside the final trimmed cut even
        // though six echo-style passages outrank it in raw BM25 —
        // that is the over-fetch guarantee. The diversity layer then
        // collapses the six near-identical echoes into one, so the
        // final cut is the fact + at most one echo (<= limit).
        #expect(results.contains { $0.sequence == 0 })
        #expect(results.count <= 4)
        #expect(results.filter { $0.sequence != 0 }.count <= 1)
    }

    // Round-11: paraphrase query must retrieve (OR + min-half-match).
    @Test func paraphraseQueryRetrievesFact() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        meeting.segments = [
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 0, sourceLabel: "Room",
                                     text: "We decided the launch date is September fifteenth.", isFinal: true),
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 1, sourceLabel: "Room",
                                     text: "The team reviewed the quarterly numbers today.", isFinal: true)
        ]
        try index.index(meeting: meeting)
        // 'again' is absent from the corpus; AND semantics returned nil.
        let results = try index.search("launch date decision again")
        #expect(results.contains { $0.passage.contains("September") })
    }

    // Round-11: saturated realistic corpus must still answer
    // (epsilon collapse skips absolute floors).
    @Test func saturatedCorpusStillAnswers() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        var segments: [MeetingTranscriptSegment] = []
        for i in 0..<10 {
            segments.append(MeetingTranscriptSegment(
                meetingID: meeting.id, sequence: i, sourceLabel: "Room",
                text: "What did we decide about the launch date? Testing again.",
                isFinal: true
            ))
        }
        segments.append(MeetingTranscriptSegment(
            meetingID: meeting.id, sequence: 10, sourceLabel: "Room",
            text: "We decided the launch date is September fifteenth.",
            isFinal: true
        ))
        meeting.segments = segments
        try index.index(meeting: meeting)

        let answered = try index.searchOrAbstain("decide launch date")
        #expect(answered != nil)
    }

    // Round-11: wake invocations are stripped at index time; facts kept.
    @Test func wakeInvocationStrippedFromIndex() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Corpus.make().meetings[0]
        meeting.segments = [
            MeetingTranscriptSegment(meetingID: meeting.id, sequence: 0, sourceLabel: "Room",
                                     text: "Open bridge. What did we decide about the launch date? We decided the launch date is September fifteenth.",
                                     isFinal: true)
        ]
        try index.index(meeting: meeting)
        #expect(index.indexedSegmentCount == 1)

        let results = try index.search("launch date september")
        guard let top = results.first else {
            Issue.record("expected results"); return
        }
        #expect(!top.passage.lowercased().contains("open bridge"))
        #expect(top.passage.contains("September"))
    }

    // #62: removeMeeting drops a deleted meeting's rows; survivors intact.
    @Test func removeMeetingPurgesIndexRows() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        try index.index(meeting: corpus.meetings[0])
        try index.index(meeting: corpus.meetings[1])
        #expect(index.indexedMeetingIDs.count == 2)

        try index.removeMeeting(meetingID: corpus.meetings[0].meetingID)
        #expect(index.indexedMeetingIDs == [corpus.meetings[1].meetingID])
        #expect(index.indexedSegmentCount == 3)
    }

    @Test func deletionPurgeDoesNotDependOnResearchBetaBeingEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-disabled-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("i.sqlite"))
        let store = MeetingSessionStore(
            rootDirectory: root.appendingPathComponent("meetings", isDirectory: true),
            meetingDeletionObserver: { meetingID in
                ObservatorySharedIndex.purgeMeeting(meetingID: meetingID, from: index)
            }
        )
        let originalFlag = ResearchObservatoryFeatureFlag.isEnabled
        defer { ResearchObservatoryFeatureFlag.setEnabled(originalFlag) }
        ResearchObservatoryFeatureFlag.setEnabled(false)

        let meeting = Corpus.make().meetings[0]
        try store.create(meeting)
        try index.index(meeting: meeting)
        #expect(index.indexedMeetingIDs.contains(meeting.meetingID))

        try store.delete(meetingID: meeting.meetingID)

        #expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(for: meeting.meetingID).path))
        #expect(!index.indexedMeetingIDs.contains(meeting.meetingID))
        #expect(index.indexedSegmentCount == 0)
    }

    // #62: startup orphan sweep must drop rows for meetings no longer in
    // the store while keeping live meetings fully indexed.
    @Test func orphanedMeetingsAreSwept() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        try index.index(meeting: corpus.meetings[0])
        try index.index(meeting: corpus.meetings[1])

        // Simulate the sweep: live store has only meetings[1].
        let liveIDs = Set([corpus.meetings[1].meetingID])
        for indexedID in index.indexedMeetingIDs where !liveIDs.contains(indexedID) {
            try index.removeMeeting(meetingID: indexedID)
        }

        #expect(index.indexedMeetingIDs == [corpus.meetings[1].meetingID])
        // Live meeting's passages still retrievable.
        let results = try index.search("budget")
        #expect(!results.isEmpty)
    }

    @Test func shortQueriesSkipEchoSuppression() throws {
        // 3-token query: suppression must not run (not distinctive enough).
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        try index.rebuild(meetings: Corpus.make().meetings)
        let results = try index.search("launch date september")
        #expect(!results.isEmpty)
    }

    // MARK: - Query Sanitization

    @Test func emptyAndPunctuationOnlyQueriesThrow() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: WorkspaceRetrievalIndexError.self) {
            _ = try index.search("   ")
        }
        #expect(throws: WorkspaceRetrievalIndexError.self) {
            _ = try index.search("!!! ??? ---")
        }
    }

    @Test func ftsSyntaxInjectionIsNeutralized() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        try index.index(meeting: corpus.meetings[0])

        // Malicious FTS5 syntax must not crash or alter semantics.
        let matches = try index.search("launch\" OR 1=1 --")
        #expect(matches.allSatisfy { $0.meetingID == "m-acme-0" })

        // Parenthesized syntax is stripped to plain terms; both words
        // co-occur in the same passage.
        let parens = try index.search("(launch) (date)")
        #expect(!parens.isEmpty)
    }

    @Test func multiWordQueriesRequireMajorityOfTerms() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()
        for meeting in corpus.meetings { try index.index(meeting: meeting) }

        // Round-11 (OR + strict-majority): two-term queries still require
        // BOTH terms (majority of 2 is 2) — "launch quantum" matches
        // nothing because no passage contains "quantum".
        let matches = try index.search("launch quantum")
        #expect(matches.isEmpty)
    }

    @Test func startupReindexPrunesExpiredMeetingsBeforeCopyingPassages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings"))
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let now = Date()
        let expired = MeetingManifest(
            meetingID: "expired",
            title: "Expired",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            startedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            retentionPolicy: .autoDeleteAfter7Days,
            segments: [MeetingTranscriptSegment(
                meetingID: "expired", sequence: 0, sourceLabel: "Room",
                text: "This expired passage must leave the research index."
            )]
        )
        let retained = MeetingManifest(
            meetingID: "retained",
            title: "Retained",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            startedAt: now,
            endedAt: now,
            retentionPolicy: .keepUntilDeleted,
            segments: [MeetingTranscriptSegment(
                meetingID: "retained", sequence: 0, sourceLabel: "Room",
                text: "This retained passage remains searchable."
            )]
        )
        try store.create(expired)
        try store.create(retained)
        try index.index(meeting: expired)
        try index.index(meeting: retained)
        #expect(index.indexedMeetingIDs == ["expired", "retained"])

        ObservatorySharedIndex.reindexAllSavedMeetings(
            store: store,
            index: index,
            now: now
        )

        #expect(Set(try store.listMeetings().map(\.meetingID)) == ["retained"])
        #expect(index.indexedMeetingIDs == ["retained"])
    }

    @Test func transcriptionOnlyMeetingIsPurgedFromStartupAndLiveIndexing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-transcription-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings"))
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let meeting = MeetingManifest(
            meetingID: "transcription-only",
            title: "Transcription Only",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            aiMode: .transcriptionOnly,
            segments: [MeetingTranscriptSegment(
                meetingID: "transcription-only", sequence: 0, sourceLabel: "Room",
                text: "Private transcription-only passage."
            )],
            privacySettings: .init(allowsLocalIntelligence: false),
            intelligenceConfiguration: MeetingIntelligenceConfiguration(
                cleanupEnabled: false,
                cleanupProvider: .localGemma,
                cloudProvider: nil
            )
        )
        try store.create(meeting)
        try index.index(meeting: meeting)
        #expect(index.indexedMeetingIDs == [meeting.meetingID])

        ObservatorySharedIndex.reindexAllSavedMeetings(store: store, index: index)
        #expect(index.indexedMeetingIDs.isEmpty)

        try index.index(meeting: meeting)
        ObservatorySharedIndex.indexMeeting(meeting, into: index)
        #expect(index.indexedMeetingIDs.isEmpty)
    }

    @Test func orphanSweepRechecksMeetingCreatedAfterInitialSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-orphan-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings"))
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let meeting = MeetingManifest(
            meetingID: "created-during-reindex",
            title: "Concurrent meeting",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "created-during-reindex",
                sequence: 0,
                sourceLabel: "Room",
                text: "This passage must survive the orphan sweep."
            )]
        )
        try index.index(meeting: meeting)

        var cancellationChecks = 0
        ObservatorySharedIndex.reindexAllSavedMeetings(
            store: store,
            index: index,
            shouldCancel: {
                cancellationChecks += 1
                if cancellationChecks == 3 {
                    try? store.create(meeting)
                }
                return false
            }
        )

        #expect(try store.load(meetingID: meeting.meetingID).meetingID == meeting.meetingID)
        #expect(index.indexedMeetingIDs == [meeting.meetingID])
    }

    @Test func pausedFullReindexDoesNotBlockAnIndexPurge() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-reindex-lock-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings"))
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let meeting = MeetingManifest(
            meetingID: "delete-while-reindexing",
            title: "Delete me",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "delete-while-reindexing",
                sequence: 0,
                sourceLabel: "Room",
                text: "Temporary indexed passage."
            )]
        )
        try index.index(meeting: meeting)

        let rebuildEntered = DispatchSemaphore(value: 0)
        let allowRebuildToFinish = DispatchSemaphore(value: 0)
        let rebuildFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ObservatorySharedIndex.reindexAllSavedMeetings(
                store: store,
                index: index,
                shouldCancel: {
                    rebuildEntered.signal()
                    allowRebuildToFinish.wait()
                    return true
                }
            )
            rebuildFinished.signal()
        }
        #expect(rebuildEntered.wait(timeout: .now() + 1) == .success)

        let purgeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ObservatorySharedIndex.purgeMeeting(meetingID: meeting.meetingID, from: index)
            purgeFinished.signal()
        }
        let purgeWasPrompt = purgeFinished.wait(timeout: .now() + 1) == .success
        allowRebuildToFinish.signal()
        #expect(rebuildFinished.wait(timeout: .now() + 1) == .success)
        #expect(purgeWasPrompt)
        #expect(index.indexedMeetingIDs.isEmpty)
    }

    @Test func rebuildCannotReinsertAMeetingDeletedAfterItsSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-delete-before-replace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingSessionStore(
            rootDirectory: root.appendingPathComponent("meetings"),
            meetingDeletionObserver: { _ in }
        )
        let index = try WorkspaceRetrievalIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let meeting = MeetingManifest(
            meetingID: "deleted-after-snapshot",
            title: "Stale snapshot",
            workspaceID: Workspace.defaultWorkspace.id,
            state: .completed,
            segments: [MeetingTranscriptSegment(
                meetingID: "deleted-after-snapshot",
                sequence: 0,
                sourceLabel: "Room",
                text: "Deleted text must not return to search."
            )]
        )
        try store.create(meeting)
        try index.index(meeting: meeting)

        var cancellationChecks = 0
        ObservatorySharedIndex.reindexAllSavedMeetings(
            store: store,
            index: index,
            shouldCancel: {
                cancellationChecks += 1
                if cancellationChecks == 3 {
                    try? store.delete(meetingID: meeting.meetingID)
                }
                return false
            }
        )

        #expect((try? store.load(meetingID: meeting.meetingID)) == nil)
        #expect(index.indexedMeetingIDs.isEmpty)
    }

    // MARK: - Concurrency

    @Test func concurrentReadsAndWritesAreSafe() async throws {
        let (index, root) = try makeIndex(label: "concurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = Corpus.make()

        await withTaskGroup(of: Void.self) { group in
            for meeting in corpus.meetings {
                group.addTask {
                    try? index.index(meeting: meeting)
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    _ = try? index.search("launch roadmap decision")
                    _ = index.indexedSegmentCount
                }
            }
        }

        // All 24 meetings indexed exactly once each.
        #expect(index.indexedSegmentCount == corpus.meetings.count * 3)
        #expect(index.indexedMeetingIDs.count == corpus.meetings.count)
    }
}
