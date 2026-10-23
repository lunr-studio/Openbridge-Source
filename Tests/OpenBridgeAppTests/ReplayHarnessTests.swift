import Foundation
import Testing
@testable import OpenBridgeApp

// MARK: - Replay Harness + Evaluation Gate Tests (#292 / IP-00)

@Suite(.serialized) struct ReplayHarnessTests {

    // MARK: - Fixture

    @Test func standardFixtureIsMachineReadable() throws {
        let fixture = EvaluationFixture.standardFixture()
        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(EvaluationFixture.self, from: data)
        #expect(decoded == fixture)
        // Expected moments are machine-readable annotations.
        #expect(fixture.expectedMoments.count == 8)
        #expect(fixture.expectedMoments.contains { $0.kind == .abstention })
        #expect(fixture.spans.contains { $0.revisesSpanID != nil }, "Fixture must include a correction injection")
    }

    // MARK: - Deterministic Replay

    @Test func replayIsDeterministic() async throws {
        let fixture = EvaluationFixture.standardFixture()
        let first = try await ReplayHarness(profile: .fake).replay(fixture)
        let second = try await ReplayHarness(profile: .fake).replay(fixture)

        #expect(first.count == fixture.spans.count)
        // Identical inputs → identical observations (modulo IDs).
        let strip = { (moments: [ObservedMoment]) in
            moments.map { "\($0.spanID)|\($0.kind.rawValue)|\($0.latencyMS)|\($0.surfacedCard)|\($0.hasEvidence)" }
        }
        #expect(strip(first) == strip(second), "Replay must be deterministic")
    }

    @Test func replayHonorsOriginalTimestamps() async throws {
        let fixture = EvaluationFixture.standardFixture()
        let observed = try await ReplayHarness(profile: .fake).replay(fixture)
        #expect(observed.map(\.atMS) == fixture.spans.map(\.atMS))
    }

    @Test func correctionsAreInjected() async throws {
        let fixture = EvaluationFixture.standardFixture()
        let observed = try await ReplayHarness(profile: .fake).replay(fixture)
        let correction = observed.first { $0.kind == .correction }
        #expect(correction != nil, "Correction injection must be observed")
        #expect(correction?.spanID == "s8")
    }

    // MARK: - Expected-Moment Coverage

    @Test func observedMomentsMatchExpectations() async throws {
        let fixture = EvaluationFixture.standardFixture()
        let observed = try await ReplayHarness(profile: .fake).replay(fixture)

        let bySpan = Dictionary(observed.map { ($0.spanID, $0.kind) }, uniquingKeysWith: { a, _ in a })
        // Silence moments.
        #expect(bySpan["s1"] == .silence)
        #expect(bySpan["s9"] == .silence)
        // Prior-context retrieval (seeded memory exists for launch date).
        #expect(bySpan["s3"] == .priorContextRetrieval)
        // Decision / action.
        #expect(bySpan["s5"] == .decision)
        #expect(bySpan["s6"] == .action)
        // Weak evidence → abstention (no card).
        #expect(bySpan["s7"] == .abstention)
        let abstention = observed.first { $0.spanID == "s7" }
        #expect(abstention?.surfacedCard == false, "Abstention must not surface a card")
        // Correction.
        #expect(bySpan["s8"] == .correction)
    }

    // MARK: - Evidence + Duplicates

    @Test func everySurfacedFactualMomentHasEvidence() async throws {
        let observed = try await ReplayHarness(profile: .fake).replay(.standardFixture())
        let factual: Set<ExpectedMoment.Kind> = [.explicitAnswer, .priorContextRetrieval, .decision, .action]
        for moment in observed where moment.surfacedCard && factual.contains(moment.kind) {
            #expect(moment.hasEvidence, "Surfaced factual moment must carry evidence: \(moment.spanID)")
        }
    }

    @Test func noDuplicateCardsSurface() async throws {
        let observed = try await ReplayHarness(profile: .fake).replay(.standardFixture())
        let surfacedKeys = observed.filter(\.surfacedCard).map(\.deduplicationKey)
        #expect(Set(surfacedKeys).count == surfacedKeys.count, "No duplicate card for the same event")
    }

    // MARK: - Multi-Provider Comparison

    @Test func sameFixtureComparesAcrossProviders() async throws {
        let runner = EvaluationRunner()
        let results = try await runner.compareProviders(fixture: .standardFixture())

        #expect(results.count == 2)
        #expect(results.map(\.profile) == ["fake", "openrouter-stub"])
        // Same matched-moment counts; latencies differ by profile.
        #expect(results[0].record.matchedMoments == results[1].record.matchedMoments,
                "Same evaluation record across providers")
        #expect(results[1].record.p95LatencyMS > results[0].record.p95LatencyMS,
                "Reference stub latencies exceed fake")
    }

    // MARK: - Gate

    @Test func gatePassesForFakeProfile() async throws {
        let runner = EvaluationRunner()
        let result = try await runner.run(fixture: .standardFixture(), profile: .fake)
        #expect(result.gateRecord.passed, "Fake profile must pass all provisional gates. Checks: \(result.gateRecord.checks.filter { !$0.passed })")
    }

    @Test func gateFailsWhenLatencyExceedsThreshold() async throws {
        let slow = ReplayProviderProfile(
            identifier: "slow-stub", classificationLatencyMS: 2_000, answerLatencyMS: 8_000, retrievalLatencyMS: 5
        )
        let runner = EvaluationRunner()
        let result = try await runner.run(fixture: .standardFixture(), profile: slow)
        #expect(!result.gateRecord.passed, "P95 card latency above 7s must fail the gate")
        #expect(result.gateRecord.checks.contains { $0.name == "p95-card-latency" && !$0.passed })
    }

    @Test func gateFailsOnDuplicates() {
        let gate = EvaluationGate()
        let record = EvaluationRecord(
            fixtureName: "t", providerIdentifier: "t",
            ranAt: Date(),
            matchedMoments: 8, totalExpectedMoments: 8,
            p95LatencyMS: 100,
            relevantProactiveCards: 4, totalProactiveCards: 4,
            duplicateCardsSurfaced: 1,
            unsupportedFactualMoments: 0,
            abstentionsHonored: 1, totalExpectedAbstentions: 1
        )
        let gateRecord = gate.evaluate(record, meetingDurationMS: 80_000)
        #expect(!gateRecord.passed)
        #expect(gateRecord.checks.contains { $0.name == "no-duplicate-cards" && !$0.passed })
    }

    @Test func gateFailsOnUnsupportedFactualAnswers() {
        let gate = EvaluationGate()
        let record = EvaluationRecord(
            fixtureName: "t", providerIdentifier: "t",
            ranAt: Date(),
            matchedMoments: 8, totalExpectedMoments: 8,
            p95LatencyMS: 100,
            relevantProactiveCards: 4, totalProactiveCards: 4,
            duplicateCardsSurfaced: 0,
            unsupportedFactualMoments: 1,
            abstentionsHonored: 1, totalExpectedAbstentions: 1
        )
        let gateRecord = gate.evaluate(record, meetingDurationMS: 80_000)
        #expect(!gateRecord.passed)
        #expect(gateRecord.checks.contains { $0.name == "evidence-on-factual-answers" && !$0.passed })
    }

    @Test func gateFailsOnMissedAbstention() {
        let gate = EvaluationGate()
        let record = EvaluationRecord(
            fixtureName: "t", providerIdentifier: "t",
            ranAt: Date(),
            matchedMoments: 8, totalExpectedMoments: 8,
            p95LatencyMS: 100,
            relevantProactiveCards: 4, totalProactiveCards: 4,
            duplicateCardsSurfaced: 0,
            unsupportedFactualMoments: 0,
            abstentionsHonored: 0, totalExpectedAbstentions: 1
        )
        let gateRecord = gate.evaluate(record, meetingDurationMS: 80_000)
        #expect(!gateRecord.passed)
        #expect(gateRecord.checks.contains { $0.name == "abstention-on-weak-evidence" && !$0.passed })
    }

    @Test func gateFailsOnIrrelevantCardRate() {
        let gate = EvaluationGate()
        // 1 irrelevant card in a very short meeting → rate explodes.
        let record = EvaluationRecord(
            fixtureName: "t", providerIdentifier: "t",
            ranAt: Date(),
            matchedMoments: 8, totalExpectedMoments: 8,
            p95LatencyMS: 100,
            relevantProactiveCards: 3, totalProactiveCards: 4,
            duplicateCardsSurfaced: 0,
            unsupportedFactualMoments: 0,
            abstentionsHonored: 1, totalExpectedAbstentions: 1
        )
        let gateRecord = gate.evaluate(record, meetingDurationMS: 80_000)
        #expect(!gateRecord.passed)
        #expect(gateRecord.checks.contains { $0.name == "irrelevant-card-rate" && !$0.passed })
    }

    @Test func gateRecordIsMachineReadable() throws {
        let gate = EvaluationGate()
        let record = EvaluationRecord(
            fixtureName: "t", providerIdentifier: "t",
            ranAt: Date(),
            matchedMoments: 8, totalExpectedMoments: 8,
            p95LatencyMS: 100,
            relevantProactiveCards: 4, totalProactiveCards: 4,
            duplicateCardsSurfaced: 0,
            unsupportedFactualMoments: 0,
            abstentionsHonored: 1, totalExpectedAbstentions: 1
        )
        let gateRecord = gate.evaluate(record, meetingDurationMS: 80_000)
        let data = try JSONEncoder().encode(gateRecord)
        let decoded = try JSONDecoder().decode(EvaluationGate.GateRecord.self, from: data)
        #expect(decoded == gateRecord)
        #expect(decoded.passed)
    }

    // MARK: - Structural-Only Records (privacy)

    @Test func recordsContainNoMeetingContent() async throws {
        let runner = EvaluationRunner()
        let result = try await runner.run(fixture: .standardFixture(), profile: .fake)
        let recordJSON = String(data: try JSONEncoder().encode(result.record), encoding: .utf8) ?? ""
        let gateJSON = String(data: try JSONEncoder().encode(result.gateRecord), encoding: .utf8) ?? ""

        for forbidden in ["Good morning", "launch date", "pricing", "legal", "quantum", "lunch"] {
            #expect(!recordJSON.contains(forbidden), "Record must not leak content: \(forbidden)")
            #expect(!gateJSON.contains(forbidden), "Gate record must not leak content: \(forbidden)")
        }
    }

    // MARK: - Shadow Review Form

    @Test func reviewFormIsRepeatableAndStructural() throws {
        let form = ShadowModeReviewForm(
            fixtureName: "standard-alpha",
            providerIdentifier: "fake",
            reviewerSlot: "reviewer-1",
            relevanceJudgements: ["decision-s5": true, "action-s6": true, "explicitAnswer-s4": false],
            notesSlot: "slot-only"
        )
        let data = try JSONEncoder().encode(form)
        let decoded = try JSONDecoder().decode(ShadowModeReviewForm.self, from: data)
        #expect(decoded == form)
        #expect(decoded.judgedRelevantCount == 2)
        // IDs and booleans only.
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("Good morning"))
    }

    // MARK: - Failure Isolation

    @Test func intelligenceFailuresNeverTouchCapture() async throws {
        // The harness type has no reference to recorder, transcriber, or
        // store — compile-time isolation. This run proves the pipeline
        // completes even when retrieval abstains everywhere.
        var fixture = EvaluationFixture.standardFixture()
        fixture = EvaluationFixture(
            name: fixture.name,
            workspaceID: fixture.workspaceID,
            spans: fixture.spans,
            expectedMoments: fixture.expectedMoments,
            seededMemories: []
        )
        let observed = try await ReplayHarness(profile: .fake).replay(fixture)
        // Questions with no seeded memory must abstain, not crash.
        let s3 = observed.first { $0.spanID == "s3" }
        #expect(s3?.kind == .abstention)
        #expect(s3?.surfacedCard == false)
    }
}