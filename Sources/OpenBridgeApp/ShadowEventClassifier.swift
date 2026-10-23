import Foundation

// MARK: - Shadow Event Classifier (#297 / INT-02)
//
// Classifies bounded meeting events in SHADOW MODE only:
//   - Consumes final transcript spans plus bounded recent context.
//   - Maintains rolling topic / unresolved-question / surfaced-event state.
//   - Links every proposed event to stable source span IDs.
//   - Suppresses duplicates and supersedes events derived from revised text.
//   - Records a private shadow event log with confidence and an explicit
//     abstention reason for every no-intervention outcome.
//   - NEVER shows cards, executes actions, or mutates meeting artifacts.
//   - Classification failures are contained: ingest never throws and never
//     affects capture or transcription.
//
// Routing through the provider abstraction (#296) is advisory: the
// deterministic heuristic owns the shadow taxonomy, and the provider's
// category is recorded alongside for post-meeting review.

// MARK: - Taxonomy

/// The initial event taxonomy. `noIntervention` must dominate.
enum ShadowEventKind: String, Codable, Equatable, Sendable, CaseIterable {
    case explicitQuestion
    case priorContextRequest
    case decisionCandidate
    case actionCandidate
    case noIntervention

    var displayName: String {
        switch self {
        case .explicitQuestion: return "Explicit question"
        case .priorContextRequest: return "Prior context request"
        case .decisionCandidate: return "Decision candidate"
        case .actionCandidate: return "Action candidate"
        case .noIntervention: return "No intervention"
        }
    }
}

/// Explicit reasons recorded for every no-intervention outcome, so shadow
/// output can be reviewed against annotated expected behaviour.
enum ShadowAbstentionReason: String, Codable, Equatable, Sendable {
    case rhetoricalQuestion
    case tentativeProposal
    case correctionOfEarlierStatement
    case duplicateSuppressed
    case belowConfidenceThreshold
    case providerUnavailable
    case plainConversation
}

// MARK: - Event

enum ShadowEventState: String, Codable, Equatable, Sendable {
    case active
    case superseded
}

/// One classified event, linked to the stable spans it was derived from.
struct ShadowEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let meetingID: String
    let kind: ShadowEventKind
    /// Stable source span IDs — every event links to existing spans only.
    let sourceSpanIDs: [String]
    let confidence: Double
    /// Explicit reason; for `noIntervention` this is the abstention reason.
    let reason: ShadowAbstentionReason
    /// The provider's advisory category (#296), recorded for review.
    let providerCategory: String?
    let createdAt: Date
    var state: ShadowEventState

    init(
        id: String = UUID().uuidString,
        meetingID: String,
        kind: ShadowEventKind,
        sourceSpanIDs: [String],
        confidence: Double,
        reason: ShadowAbstentionReason,
        providerCategory: String? = nil,
        createdAt: Date = Date(),
        state: ShadowEventState = .active
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.sourceSpanIDs = sourceSpanIDs
        self.confidence = confidence
        self.reason = reason
        self.providerCategory = providerCategory
        self.createdAt = createdAt
        self.state = state
    }
}

// MARK: - Shadow Log

/// Private, in-memory shadow event log for post-meeting review. Exported as
/// JSON on demand. Contains span IDs and classifications only — never
/// credential or provider-response content.
final class ShadowEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ShadowEvent] = []

    func append(_ event: ShadowEvent) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(event)
    }

    func append(_ events: [ShadowEvent]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(contentsOf: events)
    }

    var allEvents: [ShadowEvent] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var activeEvents: [ShadowEvent] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.state == .active }
    }

    func events(of kind: ShadowEventKind) -> [ShadowEvent] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.kind == kind }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// JSON export for post-meeting review tooling.
    func exportJSON() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entries)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

// MARK: - Rolling State

/// Bounded rolling context the classifier maintains across ingests.
struct ShadowClassifierState: Sendable {
    /// Recent final span IDs, newest last (bounded).
    var recentSpanIDs: [String] = []
    /// Span IDs carrying unanswered explicit questions.
    var unresolvedQuestionSpanIDs: [String] = []
    /// Signature (kind + normalized span text) of already-surfaced events.
    var surfacedSignatures: Set<String> = []
    /// Latest known text per span ID, to detect revisions.
    var spanTextByID: [String: String] = [:]

    static let recentContextWindow = 5

    mutating func recordSpan(_ id: String, text: String) {
        recentSpanIDs.append(id)
        if recentSpanIDs.count > Self.recentContextWindow {
            recentSpanIDs.removeFirst(recentSpanIDs.count - Self.recentContextWindow)
        }
        spanTextByID[id] = ShadowEventClassifier.normalizedText(text)
    }
}

// MARK: - Classifier

/// Shadow-mode event classifier. Ingest never throws and never touches
/// recording, transcription, or meeting artifacts — classification failure
/// is contained to the shadow log.
actor ShadowEventClassifier {
    private let provider: any ResearchProvider
    private let logger: (any ResearchProviderLogger)?
    /// Thread-safe on its own (internal lock); nonisolated so review code
    /// can read the shadow log without entering the actor.
    nonisolated let log: ShadowEventLog
    private var state = ShadowClassifierState()

    init(
        provider: any ResearchProvider = FakeResearchProvider(),
        logger: (any ResearchProviderLogger)? = nil,
        log: ShadowEventLog = ShadowEventLog()
    ) {
        self.provider = provider
        self.logger = logger
        self.log = log
    }

    /// Processes final transcript spans and appends shadow events. Returns
    /// the events produced by this ingest. Non-final spans are ignored
    /// (stable spans only). Provider failures produce `noIntervention`
    /// events with `.providerUnavailable` — never an error.
    func ingest(meetingID: String, segments: [MeetingTranscriptSegment]) async -> [ShadowEvent] {
        var produced: [ShadowEvent] = []

        // Supersession pass: any span re-ingested with revised text marks
        // prior events citing it as superseded.
        for segment in segments where segment.isFinal {
            if let previousText = state.spanTextByID[segment.id],
               previousText != Self.normalizedText(segment.text) {
                supersedeEvents(citing: segment.id)
            }
        }

        for segment in segments where segment.isFinal {
            let providerCategory = await classifyThroughProvider(meetingID: meetingID, segment: segment)
            let event = makeEvent(
                meetingID: meetingID,
                segment: segment,
                providerCategory: providerCategory
            )
            state.recordSpan(segment.id, text: segment.text)

            if let event {
                log.append(event)
                produced.append(event)
            } else {
                // Duplicate: recorded implicitly through state; nothing new.
                continue
            }
        }
        return produced
    }

    // MARK: - Provider Advisory

    private func classifyThroughProvider(
        meetingID: String,
        segment: MeetingTranscriptSegment
    ) async -> String? {
        let request = ClassificationRequest(
            context: ResearchProviderContext(meetingID: meetingID, mode: .localOnly),
            questionText: segment.text
        )
        do {
            let response = try await provider.classify(request)
            return response.category.rawValue
        } catch {
            // Advisory only — contained. The heuristic result stands and the
            // reason records provider unavailability when relevant.
            logger?.log(.init(
                event: .failed,
                operation: .classification,
                providerID: provider.descriptor.identifier,
                requestID: request.context.requestID,
                scopeKey: meetingID,
                durationMS: 0,
                inputCharacterCount: segment.text.count,
                error: error as? ResearchProviderError
            ))
            return nil
        }
    }

    // MARK: - Heuristic Classification

    private func makeEvent(
        meetingID: String,
        segment: MeetingTranscriptSegment,
        providerCategory: String?
    ) -> ShadowEvent? {
        let text = Self.normalizedText(segment.text)
        let spanID = segment.id

        // Duplicate suppression: same kind signature already surfaced from
        // identical normalized text.
        let signature = Self.signature(text: text)
        if state.surfacedSignatures.contains(signature) {
            let duplicate = ShadowEvent(
                meetingID: meetingID,
                kind: .noIntervention,
                sourceSpanIDs: [spanID],
                confidence: 0.0,
                reason: .duplicateSuppressed,
                providerCategory: providerCategory
            )
            log.append(duplicate)
            return nil
        }

        let (kind, reason, confidence) = Self.heuristicClassification(text)

        // Track unresolved explicit questions in rolling state.
        if kind == .explicitQuestion {
            state.unresolvedQuestionSpanIDs.append(spanID)
        }

        // Only surfacing signatures for real (non-abstaining) events are
        // remembered for dedup; abstentions are always allowed to re-occur.
        if kind != .noIntervention {
            state.surfacedSignatures.insert(signature)
        }

        return ShadowEvent(
            meetingID: meetingID,
            kind: kind,
            sourceSpanIDs: [spanID],
            confidence: confidence,
            reason: reason,
            providerCategory: providerCategory
        )
    }

    /// Deterministic pattern classification. Returns
    /// (kind, reason, confidence). Corrections are detected here and mark
    /// themselves as no-intervention (the supersession of the ORIGINAL
    /// event happens in the ingest supersession pass).
    static func heuristicClassification(_ raw: String) -> (kind: ShadowEventKind, reason: ShadowAbstentionReason, confidence: Double) {
        let text = normalizedText(raw)
        let isQuestion = text.hasSuffix("?")

        // Corrections: supersede rather than propose a new event.
        if text.hasPrefix("actually") || text.hasPrefix("sorry, i mean")
            || text.hasPrefix("correction") || text.hasPrefix("scratch that") {
            return (.noIntervention, .correctionOfEarlierStatement, 0.9)
        }

        // Rhetorical questions are not explicit questions.
        if isQuestion {
            let rhetoricalOpeners = ["who knows", "who cares", "whatever", "right", "isn't that something", "who can say"]
            let bare = rhetoricalOpeners.contains { opener in
                text == opener + "?" || text.hasPrefix(opener + "?")
            }
            let rhetoricalTail = text.hasSuffix("right?") || text.hasSuffix("you know?")
            if bare || rhetoricalTail {
                return (.noIntervention, .rhetoricalQuestion, 0.85)
            }
        }

        // Prior-context requests look back at earlier meetings.
        let priorMarkers = ["did we discuss", "what did we decide", "last time we", "previously we", "in the last meeting", "do we have notes on"]
        if priorMarkers.contains(where: { text.contains($0) }) {
            return (.priorContextRequest, .plainConversation, 0.85)
        }

        // Explicit questions addressed to the room.
        if isQuestion {
            return (.explicitQuestion, .plainConversation, 0.8)
        }

        let tentativeMarkers = ["maybe we", "we could", "perhaps", "just thinking", "what if we", "might be worth"]

        // Decision candidates.
        let decisionMarkers = ["we decided", "decision:", "we agreed", "let's go with", "we will use", "we're going with"]
        if decisionMarkers.contains(where: { text.contains($0) }) {
            // Tentative proposals do not count as decisions.
            if tentativeMarkers.contains(where: { text.contains($0) }) {
                return (.noIntervention, .tentativeProposal, 0.75)
            }
            return (.decisionCandidate, .plainConversation, 0.85)
        }

        // Action candidates.
        let actionMarkers = ["action item", "i'll follow up", "i will follow up", "i'll send", "i will send", "by friday", "let me check with", "i'll schedule"]
        if actionMarkers.contains(where: { text.contains($0) }) {
            return (.actionCandidate, .plainConversation, 0.8)
        }

        // Standalone tentative proposals are not events either.
        if tentativeMarkers.contains(where: { text.contains($0) }) {
            return (.noIntervention, .tentativeProposal, 0.75)
        }

        // Default: no intervention dominates.
        return (.noIntervention, .plainConversation, 0.0)
    }

    // MARK: - Supersession

    private func supersedeEvents(citing spanID: String) {
        let updated = log.allEvents.map { event -> ShadowEvent in
            guard event.sourceSpanIDs.contains(spanID), event.state == .active else {
                return event
            }
            var revised = event
            revised.state = .superseded
            return revised
        }
        log.reset()
        log.append(updated)
        state.unresolvedQuestionSpanIDs.removeAll { $0 == spanID }
    }

    // MARK: - Introspection (tests / review)

    var recentContextSpanIDs: [String] { state.recentSpanIDs }
    var unresolvedQuestionIDs: [String] { state.unresolvedQuestionSpanIDs }

    // MARK: - Text Helpers

    static func normalizedText(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func signature(text: String) -> String {
        text
    }
}