import Foundation
import SwiftUI

/// Transient spoken intake state; never persisted in a meeting manifest.
public struct ResearchSpokenStatus: Equatable, Sendable {
    public var pendingQuestion: String?
    public var needsRepeat: Bool
    public var queuedQuestions: [String]

    public init(pendingQuestion: String? = nil, needsRepeat: Bool = false, queuedQuestions: [String] = []) {
        self.pendingQuestion = pendingQuestion
        self.needsRepeat = needsRepeat
        self.queuedQuestions = queuedQuestions
    }
}

// MARK: - Rail Snapshot (production view state)

/// A deterministic snapshot of the rail. Production type — the shell's
/// views and view model depend on it in Release builds too (review
/// requirement: production shell types must not exist only under DEBUG).
public struct ResearchRailSnapshot: Equatable {
    public var meetingContextID: String? = nil
    public var conversationNotice: String? = nil
    public let state: ResearchRailState
    public var cards: [ResearchCard]
    public let activeQuestion: ResearchQuestion?
    public let spokenStatus: ResearchSpokenStatus
    public let meetingQuestions: [MeetingQuestionCard]?
    public let meetingTitle: String?
    public var researchAccess: MeetingResearchAccess?
    public var researchScope: MeetingResearchScope = .thisMeeting

    public init(state: ResearchRailState, cards: [ResearchCard], activeQuestion: ResearchQuestion?, spokenStatus: ResearchSpokenStatus = .init(), meetingQuestions: [MeetingQuestionCard]? = nil, meetingTitle: String? = nil) {
        self.state = state
        self.cards = cards
        self.activeQuestion = activeQuestion
        self.spokenStatus = spokenStatus
        self.meetingQuestions = meetingQuestions
        self.meetingTitle = meetingTitle
    }
}

// MARK: - Fixture data for Research Observatory (#318)
//
// All data is synthetic. No real meetings, providers, or web sources.
// DEBUG-only: previews, tests, and internal-alpha fixture wiring.

#if DEBUG

enum ResearchObservatoryFixtures {

    // MARK: - States

    static let quietState = ResearchRailState.quiet
    static let memoryCueState = ResearchRailState.memoryCue
    static let searchingState = ResearchRailState.searching
    static let answeredState = ResearchRailState.answered
    static let noSourceState = ResearchRailState.noSource
    static let timeoutState = ResearchRailState.timeout
    static let failureState = ResearchRailState.failure

    static func fixture(for state: ResearchRailState) -> ResearchRailSnapshot {
        switch state {
        case .quiet:
            return ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil)
        case .memoryCue:
            return ResearchRailSnapshot(state: .memoryCue, cards: [memoryCueCard], activeQuestion: nil)
        case .searching:
            return ResearchRailSnapshot(state: .searching, cards: [], activeQuestion: searchingQuestion)
        case .answered:
            return ResearchRailSnapshot(state: .answered, cards: [answeredCard], activeQuestion: answeredQuestion)
        case .noSource:
            return ResearchRailSnapshot(state: .noSource, cards: [], activeQuestion: noSourceQuestion)
        case .timeout:
            return ResearchRailSnapshot(state: .timeout, cards: [], activeQuestion: timeoutQuestion)
        case .failure:
            return ResearchRailSnapshot(state: .failure, cards: [], activeQuestion: failureQuestion)
        }
    }

    // MARK: - Questions

    static let searchingQuestion = ResearchQuestion(
        text: "What did we decide about the launch date?",
        origin: .typed,
        scopes: .localOnly
    )

    static let answeredQuestion = ResearchQuestion(
        text: "What did we decide about the launch date?",
        origin: .typed,
        scopes: .all
    )

    static let noSourceQuestion = ResearchQuestion(
        text: "What's the weather like?",
        origin: .typed,
        scopes: .localOnly
    )

    static let timeoutQuestion = ResearchQuestion(
        text: "Find the budget discussion",
        origin: .typed,
        scopes: .all,
        allowsCloudWeb: true
    )

    static let failureQuestion = ResearchQuestion(
        text: "Summarize last week's sync",
        origin: .spoken,
        scopes: .localOnly
    )

    // MARK: - Cards

    static let memoryCueCard = ResearchCard(
        variant: .priorDiscussion,
        title: "Launch date discussion",
        summary: "Last week you discussed moving the launch to September.",
        evidence: [priorMeetingEvidence]
    )

    static let answeredCard = ResearchCard(
        variant: .priorDecision,
        title: "Launch date: September 15",
        summary: "The team decided to target September 15 for the initial release.",
        // All four evidence bands (tester feedback: test 6).
        evidence: [currentMeetingEvidence, priorMeetingEvidence, webEvidence, modelEvidence]
    )

    static let actionCard = ResearchCard(
        variant: .actionCandidate,
        title: "Follow up with design",
        summary: "Alex agreed to send the final mockups by Friday.",
        evidence: [currentMeetingEvidence]
    )

    static let openLoopCard = ResearchCard(
        variant: .openLoop,
        title: "Budget approval pending",
        summary: "The budget request from last month is still awaiting approval.",
        evidence: [priorMeetingEvidence]
    )

    static let changedDecisionCard = ResearchCard(
        variant: .changedDecision,
        title: "Decision changed: API approach",
        summary: "The team previously chose REST but moved to GraphQL this week.",
        evidence: [priorMeetingEvidence, currentMeetingEvidence]
    )

    // MARK: - Evidence

    static let currentMeetingEvidence = ResearchEvidence(
        type: .currentMeeting,
        passage: "We should move the launch to September to give us more testing time.",
        sourceLocator: .currentPassage(segmentID: "seg-005", meetingID: "current-meeting"),
        confidence: 0.92
    )

    static let priorMeetingEvidence = ResearchEvidence(
        type: .priorMeeting,
        passage: "The team agreed September 15 works as a target date for the initial release.",
        sourceLocator: .priorMeeting(meetingID: "prior-001", segmentID: "seg-012"),
        confidence: 0.88
    )

    static let webEvidence = ResearchEvidence(
        type: .web,
        passage: "Industry benchmarks suggest September launches perform 15% better.",
        sourceLocator: .web(url: URL(string: "https://example.com/launch-benchmarks")!, title: "Launch Benchmarks 2026"),
        confidence: 0.75
    )

    static let modelEvidence = ResearchEvidence(
        type: .modelSynthesis,
        passage: "Combining the prior meeting decision with current discussion, September 15 remains the agreed target.",
        sourceLocator: .currentPassage(segmentID: "seg-003", meetingID: "current-meeting"),
        confidence: 0.82
    )

    // MARK: - All cards for gallery

    static let allCardVariants: [ResearchCard] = [
        memoryCueCard, answeredCard, actionCard, openLoopCard, changedDecisionCard
    ]
}

#endif
