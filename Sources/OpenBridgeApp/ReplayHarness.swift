import Foundation

// MARK: - Replay Harness + Evaluation Gate (#292 / IP-00)
//
// A deterministic way to develop and judge meeting intelligence before
// exposing live cards in real meetings.
//
// Components:
//   - EvaluationFixture: machine-readable scripted meeting — timestamped
//     stable spans, injected corrections/revisions, seeded prior-meeting
//     memories, and annotated EXPECTED moments (silence, explicit answer,
//     prior-context retrieval, decision, action, correction, abstention).
//   - ReplayHarness: replays the fixture through the intelligence pipeline
//     (shadow classifier #297 + workspace retrieval #306) at ORIGINAL
//     timestamps. Deterministic: latencies come from injected provider
//     latency profiles, not wall-clock waits.
//   - EvaluationRunner: runs the same fixture through different providers
//     (fake / reference stub) and produces comparable metric records.
//   - EvaluationGate: encodes the provisional gates and produces the
//     machine-readable pass/fail record #299's feature flag consumes.
//
// Privacy: records contain only IDs, timings, counts, and pass/fail —
// never transcript, question, answer, or provider-response content.

// MARK: - Fixture

/// One scripted transcript event at an original timestamp.
struct ReplaySpanEvent: Codable, Equatable, Sendable {
    /// Milliseconds from meeting start.
    let atMS: Int
    let spanID: String
    let text: String
    /// Replaces an earlier span's text (correction/revision injection).
    var revisesSpanID: String?
}

/// An annotated expected moment in the fixture.
struct ExpectedMoment: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case silence
        case explicitAnswer
        case priorContextRetrieval
        case decision
        case action
        case correction
        case abstention
    }
    let atMS: Int
    let kind: Kind
    /// Span ID the expectation is anchored to.
    let spanID: String
}

/// A seeded prior-meeting memory for retrieval.
struct SeededMemory: Codable, Equatable, Sendable {
    let meetingID: String
    let title: String
    let passages: [String]
}

/// The complete machine-readable evaluation fixture.
struct EvaluationFixture: Codable, Equatable, Sendable {
    let name: String
    let workspaceID: String
    let spans: [ReplaySpanEvent]
    let expectedMoments: [ExpectedMoment]
    let seededMemories: [SeededMemory]

    static func standardFixture() -> EvaluationFixture {
        EvaluationFixture(
            name: "standard-alpha",
            workspaceID: "eval-workspace",
            spans: [
                ReplaySpanEvent(atMS: 0, spanID: "s1", text: "Good morning everyone.", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 4_000, spanID: "s2", text: "Traffic was rough today.", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 12_000, spanID: "s3", text: "What did we decide about the launch date last time?", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 30_000, spanID: "s4", text: "OpenBridge, what is the enterprise pricing?", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 45_000, spanID: "s5", text: "We decided to ship on Friday.", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 52_000, spanID: "s6", text: "I'll follow up with legal by Monday.", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 60_000, spanID: "s7", text: "OpenBridge, what about the quantum roadmap?", revisesSpanID: nil),
                ReplaySpanEvent(atMS: 70_000, spanID: "s8", text: "Correction: we decided to ship on Monday, not Friday.", revisesSpanID: "s5"),
                ReplaySpanEvent(atMS: 80_000, spanID: "s9", text: "Anyway, lunch was great yesterday.", revisesSpanID: nil),
            ],
            expectedMoments: [
                ExpectedMoment(atMS: 0, kind: .silence, spanID: "s1"),
                ExpectedMoment(atMS: 12_000, kind: .priorContextRetrieval, spanID: "s3"),
                ExpectedMoment(atMS: 30_000, kind: .explicitAnswer, spanID: "s4"),
                ExpectedMoment(atMS: 45_000, kind: .decision, spanID: "s5"),
                ExpectedMoment(atMS: 52_000, kind: .action, spanID: "s6"),
                ExpectedMoment(atMS: 60_000, kind: .abstention, spanID: "s7"),
                ExpectedMoment(atMS: 70_000, kind: .correction, spanID: "s8"),
                ExpectedMoment(atMS: 80_000, kind: .silence, spanID: "s9"),
            ],
            seededMemories: [
                SeededMemory(
                    meetingID: "prior-launch",
                    title: "Launch Planning",
                    passages: [
                        "We decided to move the launch date to September fifteenth.",
                        "The beta milestone depends on the design freeze next week.",
                    ]
                ),
                SeededMemory(
                    meetingID: "prior-pricing",
                    title: "Pricing Review",
                    passages: [
                        "The enterprise pricing tier costs five hundred dollars per seat.",
                    ]
                ),
            ]
        )
    }
}

// MARK: - Observed Moments

/// What the pipeline actually did at a fixture moment.
struct ObservedMoment: Equatable, Sendable {
    let atMS: Int
    let spanID: String
    let kind: ExpectedMoment.Kind
    /// Simulated latency (from the provider profile) in ms.
    let latencyMS: Int
    /// Whether a card would surface for this moment.
    let surfacedCard: Bool
    /// Whether retrieved/answer evidence cited a source.
    let hasEvidence: Bool
    /// Dedup key — the same key surfacing twice is a duplicate.
    let deduplicationKey: String
}

// MARK: - Provider Profile

/// Simulated provider latencies; identical inputs produce identical runs.
struct ReplayProviderProfile: Codable, Equatable, Sendable {
    let identifier: String
    /// Simulated classification latency per span (ms).
    let classificationLatencyMS: Int
    /// Simulated grounded-answer latency (ms).
    let answerLatencyMS: Int
    /// Simulated retrieval latency (ms).
    let retrievalLatencyMS: Int

    static let fake = ReplayProviderProfile(
        identifier: "fake", classificationLatencyMS: 5, answerLatencyMS: 20, retrievalLatencyMS: 2
    )
    static let referenceStub = ReplayProviderProfile(
        identifier: "openrouter-stub", classificationLatencyMS: 1_200, answerLatencyMS: 3_500, retrievalLatencyMS: 2
    )
}

// MARK: - Replay Harness

/// Deterministic pipeline replay: fixture spans through the shadow
/// classifier (#297) and workspace retrieval (#306) at original
/// timestamps. Latencies are simulated — never wall-clock waits.
final class ReplayHarness: @unchecked Sendable {
    private let profile: ReplayProviderProfile

    init(profile: ReplayProviderProfile = .fake) {
        self.profile = profile
    }

    /// Replays the fixture; returns observed moments in fixture order.
    func replay(_ fixture: EvaluationFixture) async throws -> [ObservedMoment] {
        // 1. Seed prior-meeting memories into a throwaway workspace index.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try WorkspaceRetrievalIndex(
            databaseURL: root.appendingPathComponent("replay.sqlite")
        )
        for memory in fixture.seededMemories {
            let segments = memory.passages.enumerated().map { offset, passage in
                MeetingTranscriptSegment(
                    meetingID: memory.meetingID,
                    sequence: offset,
                    sourceLabel: "Room",
                    text: passage
                )
            }
            try index.index(meeting: MeetingManifest(
                meetingID: memory.meetingID,
                title: memory.title,
                workspaceID: fixture.workspaceID,
                state: .completed,
                segments: segments
            ))
        }

        // 2. Feed spans through the classifier; derive observed moments.
        let classifier = ShadowEventClassifier(provider: FakeResearchProvider())
        var observed: [ObservedMoment] = []
        var seenDedupKeys = Set<String>()
        var sequence = 0

        for event in fixture.spans {
            // Correction injection: revise the target span in classifier state.
            if let target = event.revisesSpanID {
                let corrected = MeetingTranscriptSegment(
                    id: target,
                    meetingID: "replay-meeting",
                    sequence: sequence,
                    sourceLabel: "Room",
                    text: event.text
                )
                sequence += 1
                _ = await classifier.ingest(meetingID: "replay-meeting", segments: [corrected])
                observed.append(ObservedMoment(
                    atMS: event.atMS,
                    spanID: event.spanID,
                    kind: .correction,
                    latencyMS: profile.classificationLatencyMS,
                    surfacedCard: false,
                    hasEvidence: false,
                    deduplicationKey: "correction-\(target)"
                ))
                continue
            }

            let segment = MeetingTranscriptSegment(
                id: event.spanID,
                meetingID: "replay-meeting",
                sequence: sequence,
                sourceLabel: "Room",
                text: event.text
            )
            sequence += 1

            let events = await classifier.ingest(meetingID: "replay-meeting", segments: [segment])
            guard let shadowEvent = events.first else {
                // No-intervention moment.
                observed.append(ObservedMoment(
                    atMS: event.atMS,
                    spanID: event.spanID,
                    kind: .silence,
                    latencyMS: profile.classificationLatencyMS,
                    surfacedCard: false,
                    hasEvidence: false,
                    deduplicationKey: "silence-\(event.spanID)"
                ))
                continue
            }

            let momentKind: ExpectedMoment.Kind
            var latency = profile.classificationLatencyMS
            var surfaced: Bool
            var evidence: Bool

            switch shadowEvent.kind {
            case .explicitQuestion, .priorContextRequest:
                let query = ReplayHarness.retrievalQuery(for: event.text)
                let matches = try index.searchOrAbstain(query, workspaceID: fixture.workspaceID, limit: 4)
                if let matches, !matches.isEmpty {
                    momentKind = shadowEvent.kind == .explicitQuestion ? .explicitAnswer : .priorContextRetrieval
                    latency += profile.retrievalLatencyMS
                        + (shadowEvent.kind == .explicitQuestion ? profile.answerLatencyMS : 0)
                    surfaced = true
                    evidence = true
                } else {
                    // Abstention: weak/no evidence → no card.
                    momentKind = .abstention
                    latency += profile.retrievalLatencyMS
                    surfaced = false
                    evidence = false
                }
            case .decisionCandidate:
                momentKind = .decision
                surfaced = true
                evidence = true
            case .actionCandidate:
                momentKind = .action
                surfaced = true
                evidence = true
            case .noIntervention:
                momentKind = .silence
                surfaced = false
                evidence = false
            }

            let dedupKey = "\(momentKind.rawValue)-\(event.spanID)"
            if seenDedupKeys.contains(dedupKey) {
                surfaced = false // duplicate suppressed
            }
            seenDedupKeys.insert(dedupKey)

            observed.append(ObservedMoment(
                atMS: event.atMS,
                spanID: event.spanID,
                kind: momentKind,
                latencyMS: latency,
                surfacedCard: surfaced,
                hasEvidence: evidence,
                deduplicationKey: dedupKey
            ))
        }
        return observed
    }

    /// Content-word query: strips common stopwords so FTS5 AND-semantics
    /// match passages containing the question's content words.
    static let retrievalStopwords: Set<String> = [
        "what", "did", "do", "does", "the", "a", "an", "about", "last",
        "time", "is", "are", "we", "you", "i", "our", "for", "to", "in",
        "on", "of", "me", "tell", "openbridge", "hey", "and", "was",
        // Round-3 (PR #99 Codex): pronouns are not retrieval content;
        // "it" previously survived stripping and matched arbitrary passages.
        "it", "its", "they", "them", "their", "this", "that",
        "these", "those", "he", "she", "him", "her", "his",
        // Round-11 (PR #99 Codex): imperative openers are grammar, not
        // content ("Tell me the kickoff date" searches [kickoff, date]).
        "show", "list", "give", "find",
    ]

    static func retrievalQuery(for raw: String) -> String {
        // Round-6 (PR #99 Codex): raw casing is preserved. Stopwords drop
        // only their pronoun/word FORM — acronym-cased tokens ("WHO", "IT")
        // survive stripping, mirroring the Build 24 acronym treatment.
        // Downstream consumers tokenize (lowercase), so the preserved
        // casing only changes stopword eligibility.
        // Round-16 (PR #99 Codex): negative contractions map to their
        // auxiliary FIRST (typographic apostrophes normalized), so
        // "isn't" contributes the stopword "is" instead of the non-word
        // content term "isn".
        let straightened = raw.replacingOccurrences(of: "’", with: "'")
        var tokens: [String] = []
        for word in straightened.split(separator: " ") {
            if let auxiliary = GroundedAnswerService.negativeContractions[word.lowercased()] {
                tokens.append(auxiliary)
            } else {
                tokens.append(contentsOf: word.components(separatedBy: CharacterSet.alphanumerics.inverted))
            }
        }
        return tokens
            .filter { token in
                !token.isEmpty && !(retrievalStopwords.contains(token.lowercased())
                    && !WorkspaceRetrievalIndex.isAcronymToken(token, inRaw: raw))
            }
            .joined(separator: " ")
    }
}

// MARK: - Evaluation Record

/// Comparable per-provider metric record. Structural only — no content.
struct EvaluationRecord: Codable, Equatable, Sendable {
    let fixtureName: String
    let providerIdentifier: String
    let ranAt: Date
    let matchedMoments: Int
    let totalExpectedMoments: Int
    /// P95 of surfaced-moment latencies (ms).
    let p95LatencyMS: Int
    let relevantProactiveCards: Int
    let totalProactiveCards: Int
    let duplicateCardsSurfaced: Int
    let unsupportedFactualMoments: Int
    let abstentionsHonored: Int
    let totalExpectedAbstentions: Int

    var accuracy: Double {
        guard totalExpectedMoments > 0 else { return 0 }
        return Double(matchedMoments) / Double(totalExpectedMoments)
    }
}

// MARK: - Evaluation Gate

/// Encodes the provisional gates from #292; produces the machine-readable
/// pass/fail record #299's feature flag consumes.
struct EvaluationGate {
    struct Thresholds: Codable, Equatable, Sendable {
        var maxP95CardLatencyMS = 7_000
        var minRelevantCardRatio = 0.85
        var maxDuplicateCards = 0
        var maxUnsupportedFactualMoments = 0
        var maxIrrelevantCardsPer15Minutes = 1.0

        static let `default` = Thresholds()
    }

    let thresholds: Thresholds

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    struct GateRecord: Codable, Equatable, Sendable {
        let fixtureName: String
        let providerIdentifier: String
        let passed: Bool
        let checks: [Check]

        struct Check: Codable, Equatable, Sendable {
            let name: String
            let passed: Bool
            let detail: String
        }
    }

    func evaluate(_ record: EvaluationRecord, meetingDurationMS: Int) -> GateRecord {
        var checks: [GateRecord.Check] = []

        // 1. ≥85% of displayed proactive cards judged relevant.
        let relevanceRatio = record.totalProactiveCards > 0
            ? Double(record.relevantProactiveCards) / Double(record.totalProactiveCards)
            : 1.0
        checks.append(.init(
            name: "proactive-card-relevance",
            passed: relevanceRatio >= thresholds.minRelevantCardRatio,
            detail: "ratio=\(relevanceRatio)"
        ))

        // 2. Fewer than 1 irrelevant proactive card per 15 minutes.
        let irrelevant = record.totalProactiveCards - record.relevantProactiveCards
        let minutes = Double(max(meetingDurationMS, 1)) / 60_000.0
        let per15 = Double(irrelevant) * (15.0 / minutes)
        checks.append(.init(
            name: "irrelevant-card-rate",
            passed: per15 <= thresholds.maxIrrelevantCardsPer15Minutes,
            detail: "per15min=\(per15)"
        ))

        // 3. No duplicate cards for the same conversational event.
        checks.append(.init(
            name: "no-duplicate-cards",
            passed: record.duplicateCardsSurfaced <= thresholds.maxDuplicateCards,
            detail: "duplicates=\(record.duplicateCardsSurfaced)"
        ))

        // 4. Every factual/prior-context answer includes source evidence.
        checks.append(.init(
            name: "evidence-on-factual-answers",
            passed: record.unsupportedFactualMoments <= thresholds.maxUnsupportedFactualMoments,
            detail: "unsupported=\(record.unsupportedFactualMoments)"
        ))

        // 5. Abstention when evidence is inadequate.
        checks.append(.init(
            name: "abstention-on-weak-evidence",
            passed: record.abstentionsHonored == record.totalExpectedAbstentions,
            detail: "honored=\(record.abstentionsHonored)/\(record.totalExpectedAbstentions)"
        ))

        // 6. P95 source-grounded card latency below ~7s.
        checks.append(.init(
            name: "p95-card-latency",
            passed: record.p95LatencyMS <= thresholds.maxP95CardLatencyMS,
            detail: "p95ms=\(record.p95LatencyMS)"
        ))

        // 7. Expected-moment accuracy (silent correctness).
        checks.append(.init(
            name: "expected-moment-accuracy",
            passed: record.accuracy >= 0.8,
            detail: "accuracy=\(record.accuracy)"
        ))

        return GateRecord(
            fixtureName: record.fixtureName,
            providerIdentifier: record.providerIdentifier,
            passed: checks.allSatisfy(\.passed),
            checks: checks
        )
    }
}

// MARK: - Evaluation Runner

/// Runs a fixture through provider profiles and produces comparable records.
struct EvaluationRunner {
    let gate: EvaluationGate

    init(gate: EvaluationGate = EvaluationGate()) {
        self.gate = gate
    }

    func run(
        fixture: EvaluationFixture,
        profile: ReplayProviderProfile
    ) async throws -> (record: EvaluationRecord, gateRecord: EvaluationGate.GateRecord, observed: [ObservedMoment]) {
        let harness = ReplayHarness(profile: profile)
        let observed = try await harness.replay(fixture)

        // Score observations against expectations (kind + span match).
        let expectedBySpan = Dictionary(
            fixture.expectedMoments.map { ($0.spanID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var matched = 0
        var relevantCards = 0
        var totalCards = 0
        var duplicates = 0
        var unsupported = 0
        var abstentionsHonored = 0
        let totalAbstentions = fixture.expectedMoments.filter { $0.kind == .abstention }.count
        var surfacedLatencies: [Int] = []
        var seenKeys = Set<String>()

        for moment in observed {
            let expectation = expectedBySpan[moment.spanID]
            let kindMatches = expectation?.kind == moment.kind
            if kindMatches { matched += 1 }

            if moment.surfacedCard {
                totalCards += 1
                surfacedLatencies.append(moment.latencyMS)
                if kindMatches {
                    relevantCards += 1
                }
                if seenKeys.contains(moment.deduplicationKey) {
                    duplicates += 1
                }
                seenKeys.insert(moment.deduplicationKey)

                if [.explicitAnswer, .priorContextRetrieval, .decision, .action].contains(moment.kind)
                    && !moment.hasEvidence {
                    unsupported += 1
                }
            }
            if moment.kind == .abstention && expectation?.kind == .abstention && !moment.surfacedCard {
                abstentionsHonored += 1
            }
        }

        let p95 = Self.percentile95(surfacedLatencies)
        let meetingDurationMS = fixture.spans.map(\.atMS).max() ?? 0

        let record = EvaluationRecord(
            fixtureName: fixture.name,
            providerIdentifier: profile.identifier,
            ranAt: Date(),
            matchedMoments: matched,
            totalExpectedMoments: fixture.expectedMoments.count,
            p95LatencyMS: p95,
            relevantProactiveCards: relevantCards,
            totalProactiveCards: totalCards,
            duplicateCardsSurfaced: duplicates,
            unsupportedFactualMoments: unsupported,
            abstentionsHonored: abstentionsHonored,
            totalExpectedAbstentions: totalAbstentions
        )
        let gateRecord = gate.evaluate(record, meetingDurationMS: meetingDurationMS)
        return (record, gateRecord, observed)
    }

    /// The same fixture through multiple providers — comparable records.
    func compareProviders(
        fixture: EvaluationFixture,
        profiles: [ReplayProviderProfile] = [.fake, .referenceStub]
    ) async throws -> [(profile: String, record: EvaluationRecord, gate: EvaluationGate.GateRecord)] {
        var results: [(String, EvaluationRecord, EvaluationGate.GateRecord)] = []
        for profile in profiles {
            let result = try await run(fixture: fixture, profile: profile)
            results.append((profile.identifier, result.record, result.gateRecord))
        }
        return results
    }

    static func percentile95(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(0.95 * Double(sorted.count)))
        return sorted[index]
    }
}

// MARK: - Shadow-Mode Review Form (repeatable, structural)

/// Repeatable human review form for shadow-mode judgement. IDs and
/// counts only — meeting content never enters the form.
struct ShadowModeReviewForm: Codable, Equatable, Sendable {
    let fixtureName: String
    let providerIdentifier: String
    let reviewerSlot: String
    /// Per-card relevance judgements keyed by dedup key.
    let relevanceJudgements: [String: Bool]
    let notesSlot: String

    var judgedRelevantCount: Int {
        relevanceJudgements.values.filter { $0 == true }.count
    }
}