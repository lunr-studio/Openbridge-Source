// MARK: - Research Provider Abstraction (#296)
//
// Provider-neutral contracts for the Research Observatory reasoning layer.
// No view, store, or orchestration code may import a concrete provider.
// The Release cloud implementation is an OpenAI-compatible reference client
// configured entirely by the app-scoped settings and authorization gate.

import Foundation

// MARK: - Provider Mode

/// Controls which provider may run and how much data it may see.
///
/// Mirrors the existing `MeetingAIMode` privacy boundary so that the
/// research rail cannot accidentally bypass the user's per-meeting choice.
enum ResearchProviderMode: String, Equatable, Sendable, CaseIterable {
    /// Transcription only — no provider calls at all.
    case transcriptionOnly
    /// Local reasoning only — FakeResearchProvider for tests/replay.
    case localOnly
    /// Opt-in cloud intelligence — the configured cloud client is allowed.
    case cloudExperiment

    var allowsProviderCalls: Bool {
        self != .transcriptionOnly
    }

    var allowsCloudProvider: Bool {
        self == .cloudExperiment
    }
}

// MARK: - Provider Operation

/// The three operations every research provider may support.
enum ResearchProviderOperation: String, Equatable, Sendable, CaseIterable {
    case classification
    case groundedAnswer
    case stateUpdate

    var displayName: String {
        switch self {
        case .classification: return "Classification"
        case .groundedAnswer: return "Grounded answer"
        case .stateUpdate: return "State update"
        }
    }
}

// MARK: - Provider Capabilities

/// Declares which operations a provider supports.
struct ResearchProviderCapabilities: Equatable, Sendable, OptionSet {
    let rawValue: Int

    static let classification  = ResearchProviderCapabilities(rawValue: 1 << 0)
    static let groundedAnswer  = ResearchProviderCapabilities(rawValue: 1 << 1)
    static let stateUpdate     = ResearchProviderCapabilities(rawValue: 1 << 2)

    static let all: ResearchProviderCapabilities = [.classification, .groundedAnswer, .stateUpdate]

    func supports(_ operation: ResearchProviderOperation) -> Bool {
        switch operation {
        case .classification:  return contains(.classification)
        case .groundedAnswer:  return contains(.groundedAnswer)
        case .stateUpdate:     return contains(.stateUpdate)
        }
    }
}

// MARK: - Provider Identity

/// Metadata describing a provider implementation.
struct ResearchProviderDescriptor: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let capabilities: ResearchProviderCapabilities
    let isCloud: Bool
}

// MARK: - Provider Context

/// Context passed with every provider request. Contains **no** transcript
/// text — only structural identifiers. The orchestrator never embeds raw
/// meeting content in the context object.
struct ResearchProviderContext: Equatable, Sendable {
    let requestID: String
    let meetingID: String?
    let workspaceID: String?
    let mode: ResearchProviderMode
    /// Non-secret configuration already checked against every selected
    /// meeting's immutable consent snapshot. The transport gate rechecks this
    /// exact identity immediately before releasing a credential.
    let expectedCloudConfiguration: ProviderConfiguration?
    let locale: String

    init(
        requestID: String = UUID().uuidString,
        meetingID: String? = nil,
        workspaceID: String? = nil,
        mode: ResearchProviderMode = .localOnly,
        expectedCloudConfiguration: ProviderConfiguration? = nil,
        locale: String = "en"
    ) {
        self.requestID = requestID
        self.meetingID = meetingID
        self.workspaceID = workspaceID
        self.mode = mode
        self.expectedCloudConfiguration = expectedCloudConfiguration
        self.locale = locale
    }
}

// MARK: - Retrieval Scope (provider-local)

/// Which evidence sources a question is authorized to consult.
///
/// Provider-local mirror of the Research Observatory evidence scope. This
/// module stays self-contained on `main` until the Observatory shell
/// (#318) merges; the two types intentionally share case semantics so the
/// integration is a mechanical mapping.
struct ResearchRetrievalScope: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let currentMeeting  = ResearchRetrievalScope(rawValue: 1 << 0)
    static let priorMeetings   = ResearchRetrievalScope(rawValue: 1 << 1)
    static let web             = ResearchRetrievalScope(rawValue: 1 << 2)
    static let modelSynthesis  = ResearchRetrievalScope(rawValue: 1 << 3)

    static let all: ResearchRetrievalScope = [.currentMeeting, .priorMeetings, .web, .modelSynthesis]
    static let localOnly: ResearchRetrievalScope = [.currentMeeting, .priorMeetings]
}

// MARK: - Passage Source (provider-local)

/// The provenance of a grounding passage.
///
/// Provider-local mirror of the Research Observatory evidence type. Kept
/// here so this module compiles standalone on `main` (see #318).
enum ResearchPassageSource: String, Equatable, Sendable, CaseIterable {
    case currentMeeting
    case priorMeeting
    case web
    case modelSynthesis
}

// MARK: - Classification Request / Response

/// Categorizes a research question to route it to the right retrieval path.
struct ClassificationRequest: Equatable, Sendable {
    let context: ResearchProviderContext
    let questionText: String
    let scopes: ResearchRetrievalScope

    init(
        context: ResearchProviderContext,
        questionText: String,
        scopes: ResearchRetrievalScope = .localOnly
    ) {
        self.context = context
        self.questionText = questionText
        self.scopes = scopes
    }
}

/// The kind of question, used to pick retrieval and answering strategy.
enum ResearchQuestionCategory: String, Equatable, Sendable, CaseIterable {
    case factual
    case decisional
    case actionOriented
    case synthesis
    case unsupported
}

struct ClassificationResponse: Equatable, Sendable {
    static let schemaVersion = 1

    let requestID: String
    let category: ResearchQuestionCategory
    let confidence: Double

    init(requestID: String, category: ResearchQuestionCategory, confidence: Double) {
        self.requestID = requestID
        self.category = category
        self.confidence = confidence
    }
}

// MARK: - Grounded Answer Request / Response

/// A passage offered as grounding context for a grounded-answer call.
struct ResearchGroundingPassage: Equatable, Sendable {
    let evidenceID: String
    let passage: String
    let sourceType: ResearchPassageSource
    let confidence: Double

    init(evidenceID: String, passage: String, sourceType: ResearchPassageSource, confidence: Double = 0.8) {
        self.evidenceID = evidenceID
        self.passage = passage
        self.sourceType = sourceType
        self.confidence = confidence
    }
}

/// A citation linking the answer back to a grounding passage.
struct ResearchAnswerCitation: Equatable, Sendable {
    let evidenceID: String
    let quotedFragment: String

    init(evidenceID: String, quotedFragment: String) {
        self.evidenceID = evidenceID
        self.quotedFragment = quotedFragment
    }
}

struct GroundedAnswerRequest: Equatable, Sendable {
    let context: ResearchProviderContext
    let questionText: String
    let passages: [ResearchGroundingPassage]

    init(
        context: ResearchProviderContext,
        questionText: String,
        passages: [ResearchGroundingPassage]
    ) {
        self.context = context
        self.questionText = questionText
        self.passages = passages
    }
}

struct GroundedAnswerResponse: Equatable, Sendable {
    static let schemaVersion = 1

    let requestID: String
    let answerText: String
    let citations: [ResearchAnswerCitation]
    let confidence: Double
    let abstained: Bool

    init(
        requestID: String,
        answerText: String,
        citations: [ResearchAnswerCitation],
        confidence: Double,
        abstained: Bool = false
    ) {
        self.requestID = requestID
        self.answerText = answerText
        self.citations = citations
        self.confidence = confidence
        self.abstained = abstained
    }
}

// MARK: - State Update Request / Response

/// A transcript excerpt offered for decision/action/open-loop extraction.
struct ResearchTranscriptExcerpt: Equatable, Sendable {
    let segmentID: String
    let meetingID: String
    let text: String

    init(segmentID: String, meetingID: String, text: String) {
        self.segmentID = segmentID
        self.meetingID = meetingID
        self.text = text
    }
}

/// A decision extracted from the transcript.
struct ResearchExtractedDecision: Equatable, Sendable {
    let summary: String
    let supportingSegmentIDs: [String]
    let confidence: Double

    init(summary: String, supportingSegmentIDs: [String], confidence: Double = 0.8) {
        self.summary = summary
        self.supportingSegmentIDs = supportingSegmentIDs
        self.confidence = confidence
    }
}

/// An action candidate extracted from the transcript.
struct ResearchExtractedAction: Equatable, Sendable {
    let description: String
    let assigneeHint: String?
    let supportingSegmentIDs: [String]
    let confidence: Double

    init(
        description: String,
        assigneeHint: String? = nil,
        supportingSegmentIDs: [String],
        confidence: Double = 0.8
    ) {
        self.description = description
        self.assigneeHint = assigneeHint
        self.supportingSegmentIDs = supportingSegmentIDs
        self.confidence = confidence
    }
}

/// An open loop — a topic left unresolved across meetings.
struct ResearchExtractedOpenLoop: Equatable, Sendable {
    let topic: String
    let supportingSegmentIDs: [String]
    let confidence: Double

    init(topic: String, supportingSegmentIDs: [String], confidence: Double = 0.8) {
        self.topic = topic
        self.supportingSegmentIDs = supportingSegmentIDs
        self.confidence = confidence
    }
}

struct StateUpdateRequest: Equatable, Sendable {
    let context: ResearchProviderContext
    let excerpts: [ResearchTranscriptExcerpt]

    init(context: ResearchProviderContext, excerpts: [ResearchTranscriptExcerpt]) {
        self.context = context
        self.excerpts = excerpts
    }
}

struct StateUpdateResponse: Equatable, Sendable {
    static let schemaVersion = 1

    let requestID: String
    let decisions: [ResearchExtractedDecision]
    let actions: [ResearchExtractedAction]
    let openLoops: [ResearchExtractedOpenLoop]

    init(
        requestID: String,
        decisions: [ResearchExtractedDecision] = [],
        actions: [ResearchExtractedAction] = [],
        openLoops: [ResearchExtractedOpenLoop] = []
    ) {
        self.requestID = requestID
        self.decisions = decisions
        self.actions = actions
        self.openLoops = openLoops
    }
}

// MARK: - Provider Error

enum ResearchProviderError: Equatable, LocalizedError, Sendable {
    case timeout
    case cancelled
    case staleRequest
    case invalidJSON(String)
    case unsupportedOperation(String)
    case rateLimited
    case providerError(String)
    case modeBlocked(ResearchProviderMode)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "The research provider request timed out."
        case .cancelled:
            return "The research provider request was cancelled."
        case .staleRequest:
            return "A newer request superseded this one."
        case .invalidJSON(let detail):
            return "The provider returned invalid JSON: \(detail)"
        case .unsupportedOperation(let detail):
            return "The provider does not support this operation: \(detail)"
        case .rateLimited:
            return "The provider rate-limited the request."
        case .providerError(let detail):
            return "The provider encountered an error: \(detail)"
        case .modeBlocked(let mode):
            return "The current mode (\(mode.rawValue)) blocks provider calls."
        }
    }
}

// MARK: - Provider Protocol

/// The core provider protocol. Implementations must be `Sendable`.
///
/// Each operation is an `async throws` function that receives a strongly
/// typed request and returns a strongly typed response. The orchestrator
/// wraps every call with timeout, cancellation, concurrency, and stale-
/// request guards.
protocol ResearchProvider: Sendable {
    var descriptor: ResearchProviderDescriptor { get }

    func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse
    func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse
    func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse
}
