import Foundation

// MARK: - Fake Research Provider (#296)
//
// Deterministic, local-only provider for tests and replay. Never makes
// network calls. Responses are keyed off input keywords so tests can
// assert exact outputs without flakiness.

/// A snapshot of every request/response pair the fake provider has seen.
/// Used by tests to assert invocation counts, ordering, and payloads.
struct FakeProviderRecordedCall: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case classification
        case groundedAnswer
        case stateUpdate
    }

    let kind: Kind
    let requestID: String
    let timestamp: Date
}

/// Thread-safe recorder that captures call metadata. Does not retain
/// request/response text to avoid accidental data leakage in logs.
final class FakeProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [FakeProviderRecordedCall] = []

    func record(_ call: FakeProviderRecordedCall) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }

    var allCalls: [FakeProviderRecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    func calls(of kind: FakeProviderRecordedCall.Kind) -> [FakeProviderRecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls.filter { $0.kind == kind }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        calls.removeAll()
    }
}

/// Configuration for the fake provider's failure injection and timing.
struct FakeProviderConfiguration: Equatable, Sendable {
    /// #60: empty-passage requests answer from "model knowledge"
    /// instead of abstaining (spoken-origin routing tests).
    var modelKnowledgeAnswers = false
    /// Artificial delay before each response (seconds).
    var delay: TimeInterval = 0
    /// If non-nil, the classification call throws this error.
    var classificationFailure: ResearchProviderError?
    /// If non-nil, the groundedAnswer call throws this error.
    var groundedAnswerFailure: ResearchProviderError?
    /// If non-nil, the stateUpdate call throws this error.
    var stateUpdateFailure: ResearchProviderError?
    /// Whether the provider should check for cancellation before responding.
    var checkCancellation: Bool = true

    static let defaultFast = FakeProviderConfiguration()
}

/// Deterministic fake provider for tests and replay scenarios.
///
/// Classification maps keywords to categories:
/// - "decide"/"decision" → `.decisional`
/// - "action"/"follow up"/"task" → `.actionOriented`
/// - "summarize"/"combine"/"synthesize" → `.synthesis`
/// - otherwise → `.factual`
///
/// Grounded answers echo the first passage as the answer with one citation.
/// State updates scan excerpt text for "decide", "action"/"will", "open"/"pending".
struct FakeResearchProvider: ResearchProvider {
    let descriptor = ResearchProviderDescriptor(
        identifier: "fake",
        displayName: "Fake Provider",
        capabilities: .all,
        isCloud: false
    )

    var configuration: FakeProviderConfiguration
    let recorder: FakeProviderRecorder?

    init(
        configuration: FakeProviderConfiguration = .defaultFast,
        recorder: FakeProviderRecorder? = nil
    ) {
        self.configuration = configuration
        self.recorder = recorder
    }

    func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
        recorder?.record(.init(
            kind: .classification,
            requestID: request.context.requestID,
            timestamp: Date()
        ))

        if configuration.checkCancellation {
            try Task.checkCancellation()
        }
        if configuration.delay > 0 {
            try await Task.sleep(for: .seconds(configuration.delay))
        }
        if let failure = configuration.classificationFailure {
            throw failure
        }

        let text = request.questionText.lowercased()
        let category: ResearchQuestionCategory
        if text.contains("decide") || text.contains("decision") {
            category = .decisional
        } else if text.contains("action") || text.contains("follow up") || text.contains("task") {
            category = .actionOriented
        } else if text.contains("summarize") || text.contains("combine") || text.contains("synthesize") {
            category = .synthesis
        } else {
            category = .factual
        }

        return ClassificationResponse(
            requestID: request.context.requestID,
            category: category,
            confidence: 0.9
        )
    }

    func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
        recorder?.record(.init(
            kind: .groundedAnswer,
            requestID: request.context.requestID,
            timestamp: Date()
        ))

        if configuration.checkCancellation {
            try Task.checkCancellation()
        }
        if configuration.delay > 0 {
            try await Task.sleep(for: .seconds(configuration.delay))
        }
        if let failure = configuration.groundedAnswerFailure {
            throw failure
        }

        guard let firstPassage = request.passages.first else {
            // #60: model-knowledge mode for spoken-origin questions.
            if configuration.modelKnowledgeAnswers {
                return GroundedAnswerResponse(
                    requestID: request.context.requestID,
                    answerText: "Model knowledge: \(request.questionText)",
                    citations: [],
                    confidence: 0.6,
                    abstained: false
                )
            }
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: "",
                citations: [],
                confidence: 0.0,
                abstained: true
            )
        }

        let answer = firstPassage.passage
        let citation = ResearchAnswerCitation(
            evidenceID: firstPassage.evidenceID,
            quotedFragment: String(firstPassage.passage.prefix(60))
        )

        return GroundedAnswerResponse(
            requestID: request.context.requestID,
            answerText: answer,
            citations: [citation],
            confidence: 0.85,
            abstained: false
        )
    }

    func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
        recorder?.record(.init(
            kind: .stateUpdate,
            requestID: request.context.requestID,
            timestamp: Date()
        ))

        if configuration.checkCancellation {
            try Task.checkCancellation()
        }
        if configuration.delay > 0 {
            try await Task.sleep(for: .seconds(configuration.delay))
        }
        if let failure = configuration.stateUpdateFailure {
            throw failure
        }

        var decisions: [ResearchExtractedDecision] = []
        var actions: [ResearchExtractedAction] = []
        var openLoops: [ResearchExtractedOpenLoop] = []

        for excerpt in request.excerpts {
            let lower = excerpt.text.lowercased()
            let segID = excerpt.segmentID

            if lower.contains("decide") || lower.contains("decision") {
                decisions.append(.init(
                    summary: excerpt.text,
                    supportingSegmentIDs: [segID],
                    confidence: 0.82
                ))
            }
            if lower.contains("action") || lower.contains("will ") || lower.contains("follow up") {
                actions.append(.init(
                    description: excerpt.text,
                    supportingSegmentIDs: [segID],
                    confidence: 0.78
                ))
            }
            if lower.contains("open") || lower.contains("pending") || lower.contains("unresolved") {
                openLoops.append(.init(
                    topic: excerpt.text,
                    supportingSegmentIDs: [segID],
                    confidence: 0.75
                ))
            }
        }

        return StateUpdateResponse(
            requestID: request.context.requestID,
            decisions: decisions,
            actions: actions,
            openLoops: openLoops
        )
    }
}