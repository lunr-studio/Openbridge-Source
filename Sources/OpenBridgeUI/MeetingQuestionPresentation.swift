import Foundation

public enum MeetingResearchScope: String, CaseIterable, Sendable {
    case thisMeeting, history
    public var title: String { self == .thisMeeting ? "This meeting" : "This meeting + past meetings" }
}

public struct MeetingResearchAccess: Equatable, Sendable {
    public var canAsk: Bool
    public var canEnable: Bool
    public var detail: String
    public var provider: String
    public var approvedHistoryCount: Int
    public init(canAsk: Bool, canEnable: Bool, detail: String, provider: String = "", approvedHistoryCount: Int = 0) {
        self.canAsk = canAsk; self.canEnable = canEnable; self.detail = detail
        self.provider = provider; self.approvedHistoryCount = approvedHistoryCount
    }
}

public enum MeetingQuestionPhase: String, Equatable, Sendable {
    case waiting, transcribing, queued, answering, answered, failed, cancelled

    public var title: String {
        switch self {
        case .waiting: "Waiting for recent discussion"
        case .transcribing: "Transcribing recent discussion"
        case .queued: "Queued"
        case .answering: "Answering your question"
        case .answered: "Answered"
        case .failed: "Could not answer"
        case .cancelled: "Cancelled"
        }
    }
    public var isPending: Bool { [.waiting, .transcribing, .queued, .answering].contains(self) }
}

public struct MeetingWebSource: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let passage: String
    public let retrievedAt: Date
    public let pageDate: String?
    public init(title: String, url: URL, passage: String, retrievedAt: Date, pageDate: String? = nil) {
        self.title = title; self.url = url; self.passage = passage; self.retrievedAt = retrievedAt
        self.pageDate = pageDate
    }
}
public struct MeetingWebClaim: Equatable, Sendable {
    public let text: String
    public let sources: [MeetingWebSource]
    public let isSourceQuotation: Bool
    public init(text: String, isSourceQuotation: Bool = false, sources: [MeetingWebSource]) {
        self.text = text; self.sources = sources; self.isSourceQuotation = isSourceQuotation
    }
}

public struct MeetingQuestionCard: Equatable, Identifiable, Sendable {
    public let id: String
    public let question: String
    public let phase: MeetingQuestionPhase
    public let detail: String?
    public let countdown: Int?
    public let answer: String?
    public let explanation: String?
    public let evidence: [ResearchEvidence]
    public let coverage: String?
    public let mayUseAvailable: Bool
    public let scope: MeetingResearchScope
    public let mayRetry: Bool
    public let webQuery: String?
    public let webSourceDomains: [String]
    public let webClaims: [MeetingWebClaim]
    public let webCoverage: String?

    public init(id: String, question: String, phase: MeetingQuestionPhase, detail: String? = nil,
                countdown: Int? = nil, answer: String? = nil, explanation: String? = nil,
                evidence: [ResearchEvidence] = [], coverage: String? = nil, mayUseAvailable: Bool = false,
                scope: MeetingResearchScope = .thisMeeting, mayRetry: Bool = true,
                webQuery: String? = nil, webSourceDomains: [String] = [], webClaims: [MeetingWebClaim] = [], webCoverage: String? = nil) {
        self.id = id; self.question = question; self.phase = phase; self.detail = detail
        self.countdown = countdown; self.answer = answer; self.explanation = explanation
        self.evidence = evidence; self.coverage = coverage; self.mayUseAvailable = mayUseAvailable
        self.scope = scope; self.mayRetry = mayRetry
        self.webSourceDomains = webSourceDomains
        self.webQuery = webQuery; self.webClaims = webClaims; self.webCoverage = webCoverage
    }
}

extension MeetingQuestionCard {
    public var copyText: String {
        let web = webClaims.map { claim in
            (claim.isSourceQuotation ? "Source quotation: " : "Saved AI summary: ") + claim.text + "\n" + claim.sources.map { "\($0.title): \($0.url.absoluteString)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return [question, answer, explanation, web.isEmpty ? nil : "Web research\n" + web,
                webQuery.map { "Brave query: " + $0 },
                webQuery.map { _ in webSourceDomains.isEmpty ? "Sources: Any website" : "Sources: " + webSourceDomains.joined(separator: ", ") },
                webCoverage, detail].compactMap { $0 }.joined(separator: "\n\n")
    }
}
