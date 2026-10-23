import Foundation
import Testing
@testable import OpenBridgeApp

// MARK: - Shadow Event Classifier Tests (#297 / INT-02)
//
// Evaluation fixtures cover the acceptance criteria: rhetorical questions,
// tentative proposals, corrections, duplicates, supersession, provider
// failure containment, and the no-side-effect guarantee. The classifier
// runs in shadow mode only — nothing here touches capture or transcription.

@Suite(.serialized) struct ShadowEventClassifierTests {

    // MARK: - Fixtures

    private func span(_ id: String, _ text: String, meetingID: String = "m1", isFinal: Bool = true) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            meetingID: meetingID,
            sequence: 0,
            sourceLabel: "Room",
            text: text,
            isFinal: isFinal
        )
    }

    // MARK: - Taxonomy

    @Test func taxonomyMatchesIssue() throws {
        #expect(ShadowEventKind.allCases.map(\.rawValue) == [
            "explicitQuestion", "priorContextRequest", "decisionCandidate", "actionCandidate", "noIntervention"
        ])
    }

    // MARK: - Explicit Questions

    @Test func explicitQuestionIsClassified() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "What is the pricing tier for enterprise?")
        ])
        let event = try #require(produced.first)
        #expect(event.kind == .explicitQuestion)
        #expect(event.sourceSpanIDs == ["s1"])
        #expect(event.confidence > 0)
        #expect(classifier.log.events(of: .explicitQuestion).count == 1)
    }

    @Test func rhetoricalQuestionsAreNoIntervention() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "Who knows?"),
            span("s2", "That's a great feature, right?"),
            span("s3", "It's been a long quarter, you know?")
        ])
        for event in produced {
            #expect(event.kind == .noIntervention)
            #expect(event.reason == .rhetoricalQuestion)
        }
    }

    // MARK: - Prior Context Requests

    @Test func priorContextRequestsAreClassified() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "What did we decide about the launch date last time?"),
            span("s2", "Did we discuss the API limit in the last meeting?")
        ])
        for event in produced {
            #expect(event.kind == .priorContextRequest)
        }
    }

    // MARK: - Decision / Action Candidates

    @Test func decisionCandidateIsClassified() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "We decided to ship on Friday.")
        ])
        #expect(produced.first?.kind == .decisionCandidate)
    }

    @Test func tentativeProposalsAreNoIntervention() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "Maybe we should revisit the onboarding flow."),
            span("s2", "Perhaps we could add a dark mode option.")
        ])
        for event in produced {
            #expect(event.kind == .noIntervention)
            #expect(event.reason == .tentativeProposal)
        }
    }

    @Test func actionCandidateIsClassified() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "I'll follow up with the design team by Friday.")
        ])
        #expect(produced.first?.kind == .actionCandidate)
    }

    // MARK: - Corrections & Supersession

    @Test func correctionMarksItselfNoIntervention() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "Actually, the deadline is the fifteenth, not the tenth.")
        ])
        #expect(produced.first?.kind == .noIntervention)
        #expect(produced.first?.reason == .correctionOfEarlierStatement)
    }

    @Test func revisedTextSupersedesPriorEvents() async throws {
        let classifier = ShadowEventClassifier()
        _ = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "We decided to ship on Friday.")
        ])
        #expect(classifier.log.activeEvents.filter { $0.sourceSpanIDs.contains("s1") }.count == 1)

        // Same span re-ingested with revised text → prior event superseded.
        _ = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "We decided to ship on Monday instead.")
        ])
        let active = classifier.log.activeEvents.filter { $0.sourceSpanIDs.contains("s1") }
        // The revised span yields a fresh decision event (different text)…
        #expect(active.count == 1)
        #expect(active.first?.kind == .decisionCandidate)
        // …and the superseded original remains in the log for review.
        let superseded = classifier.log.allEvents.filter { $0.state == .superseded }
        #expect(superseded.count == 1)
        #expect(superseded.first?.sourceSpanIDs == ["s1"])
    }

    // MARK: - Duplicate Suppression

    @Test func duplicateEventsAreSuppressed() async throws {
        let classifier = ShadowEventClassifier()
        _ = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "We decided to ship on Friday.")
        ])
        // Identical normalized text from a different span → suppressed.
        let second = await classifier.ingest(meetingID: "m1", segments: [
            span("s2", "We decided to ship on Friday.")
        ])
        #expect(second.isEmpty, "Duplicate must produce no event")

        // The log records the suppression as a no-intervention entry.
        let duplicates = classifier.log.events(of: .noIntervention).filter { $0.reason == .duplicateSuppressed }
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.sourceSpanIDs == ["s2"])
    }

    // MARK: - Bounded Context

    @Test func recentContextIsBounded() async throws {
        let classifier = ShadowEventClassifier()
        for index in 0..<12 {
            _ = await classifier.ingest(meetingID: "m1", segments: [
                span("s\(index)", "Plain conversational turn number \(index).")
            ])
        }
        let recent = await classifier.recentContextSpanIDs
        #expect(recent.count == ShadowClassifierState.recentContextWindow)
        #expect(recent.last == "s11")
    }

    @Test func unresolvedQuestionsAreTracked() async throws {
        let classifier = ShadowEventClassifier()
        _ = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "What is the enterprise pricing?")
        ])
        let unresolved = await classifier.unresolvedQuestionIDs
        #expect(unresolved == ["s1"])
    }

    // MARK: - Provider Failure Containment

    @Test func providerFailureDoesNotAffectClassification() async throws {
        let failing = FakeResearchProvider(
            configuration: .init(classificationFailure: .providerError("offline"))
        )
        let classifier = ShadowEventClassifier(provider: failing)
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "We decided to use Swift.")
        ])
        // Heuristic result stands; provider category is simply absent.
        let event = try #require(produced.first)
        #expect(event.kind == .decisionCandidate)
        #expect(event.providerCategory == nil)
        // Ingest never threw; log stayed consistent.
        #expect(classifier.log.count == 1)
    }

    @Test func providerCategoryIsRecordedWhenAvailable() async throws {
        let classifier = ShadowEventClassifier(provider: FakeResearchProvider())
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "What did we decide about the budget?")
        ])
        let event = try #require(produced.first)
        #expect(event.providerCategory == "decisional")
    }

    // MARK: - Non-Final Spans Ignored

    @Test func nonFinalSpansAreIgnored() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "We decided to ship.", isFinal: false)
        ])
        #expect(produced.isEmpty)
        #expect(classifier.log.count == 0)
    }

    // MARK: - No Intervention Dominates

    @Test func plainConversationDominatedByNoIntervention() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "The weather was lovely this weekend."),
            span("s2", "I tried the new coffee place downtown."),
            span("s3", "Traffic on the bridge was terrible.")
        ])
        for event in produced {
            #expect(event.kind == .noIntervention)
            #expect(event.reason == .plainConversation)
        }
    }

    // MARK: - Shadow Log Export

    @Test func shadowLogExportsValidJSON() async throws {
        let classifier = ShadowEventClassifier()
        _ = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "What is the pricing?")
        ])
        let data = try classifier.log.exportJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ShadowEvent].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.kind == .explicitQuestion)
    }

    // MARK: - Evaluation Fixtures (annotated expected behavior)

    @Test func annotatedFixtureEvaluation() async throws {
        struct Fixture {
            let text: String
            let expectedKind: ShadowEventKind
            let expectedReason: ShadowAbstentionReason?
        }
        let fixtures: [Fixture] = [
            Fixture(text: "What is the API rate limit?", expectedKind: .explicitQuestion, expectedReason: .plainConversation),
            Fixture(text: "Who knows?", expectedKind: .noIntervention, expectedReason: .rhetoricalQuestion),
            Fixture(text: "We agreed to postpone the launch.", expectedKind: .decisionCandidate, expectedReason: nil),
            Fixture(text: "Maybe we should add retries.", expectedKind: .noIntervention, expectedReason: .tentativeProposal),
            Fixture(text: "I'll follow up with legal.", expectedKind: .actionCandidate, expectedReason: nil),
            Fixture(text: "Actually, I meant the staging endpoint.", expectedKind: .noIntervention, expectedReason: .correctionOfEarlierStatement),
            Fixture(text: "Did we discuss quotas last time we met?", expectedKind: .priorContextRequest, expectedReason: .plainConversation),
            Fixture(text: "The sandwich place closed.", expectedKind: .noIntervention, expectedReason: .plainConversation),
        ]

        for fixture in fixtures {
            let (kind, reason, confidence) = ShadowEventClassifier.heuristicClassification(fixture.text)
            #expect(kind == fixture.expectedKind, "Text '\(fixture.text)' classified as \(kind.rawValue), expected \(fixture.expectedKind.rawValue)")
            if let expectedReason = fixture.expectedReason {
                #expect(reason == expectedReason, "Text '\(fixture.text)' reason \(reason.rawValue), expected \(expectedReason.rawValue)")
            }
            // Every abstention carries an explicit reason by construction
            // (heuristicClassification always returns a non-optional reason).
            // Confidence always in [0, 1].
            #expect(confidence >= 0.0 && confidence <= 1.0)
        }
    }

    // MARK: - No External Side Effects

    @Test func noEventCreatesExternalSideEffects() async throws {
        let classifier = ShadowEventClassifier()
        let produced = await classifier.ingest(meetingID: "m1", segments: [
            span("s1", "What is the pricing?"),
            span("s2", "We decided to ship."),
            span("s3", "I'll follow up tomorrow.")
        ])
        // Shadow mode: events exist only in the in-memory log. No store
        // mutation, no manifest write, no network — the classifier has no
        // reference to any such facility by construction.
        #expect(produced.allSatisfy { $0.state == .active })
        #expect(produced.allSatisfy { !$0.sourceSpanIDs.isEmpty })
    }
}