import Foundation
import SwiftUI

// MARK: - Research Rail Actions (#318)
//
// Every card/rail interaction is an injected, fixture-testable behavior.
// The shell performs NO live work: production wiring (clipboard, source
// opening, follow-up) is injected by the app; tests inject recorders.

// MARK: - Actions

/// Injected behaviors for the research rail. All default to no-ops so a
/// misconfigured wiring can never crash the shell.
public struct ResearchRailActions {
    /// Highlight the current-meeting passage (segment + meeting IDs).
    var highlightCurrentPassage: (String, String) -> Void = { _, _ in }
    /// Open the exact prior-meeting passage where available.
    var openPriorMeeting: (String, String?) -> Void = { _, _ in }
    /// Open the original web URL.
    var openWebSource: (URL) -> Void = { _ in }
    /// Pin or unpin a card.
    var togglePin: (String) -> Void = { _ in }
    /// Dismiss a card and suppress it for the current meeting.
    var dismiss: (String) -> Void = { _ in }
    /// Copy the card's text to the clipboard.
    var copyCard: (String) -> Void = { _ in }
    /// Start a follow-up question from a card.
    var followUp: (String) -> Void = { _ in }
    /// Retry the failed/timed-out search.
    var retry: () -> Void = {}
    /// Toggle a card's expanded/collapsed detail.
    var toggleExpanded: (String) -> Void = { _ in }
    var cancelQuestion: (String) -> Void = { _ in }
    var retryQuestion: (String) -> Void = { _ in }
    var answerUsingAvailable: (String) -> Void = { _ in }

    /// Dispatches source-opening to the right behavior by locator kind:
    /// current passage → highlight; prior meeting → open; web → URL.
    func openSource(for evidence: ResearchEvidence) {
        switch evidence.sourceLocator {
        case .currentPassage(let segmentID, let meetingID):
            highlightCurrentPassage(segmentID, meetingID)
        case .priorMeeting(let meetingID, let segmentID):
            openPriorMeeting(meetingID, segmentID)
        case .web(let url, _):
            openWebSource(url)
        }
    }

    /// The production clipboard wiring (safe: NSPasteboard only).
    public init(
        highlightCurrentPassage: @escaping (String, String) -> Void = { _, _ in },
        openPriorMeeting: @escaping (String, String?) -> Void = { _, _ in },
        openWebSource: @escaping (URL) -> Void = { _ in },
        togglePin: @escaping (String) -> Void = { _ in },
        dismiss: @escaping (String) -> Void = { _ in },
        copyCard: @escaping (String) -> Void = { _ in },
        followUp: @escaping (String) -> Void = { _ in },
        retry: @escaping () -> Void = {},
        toggleExpanded: @escaping (String) -> Void = { _ in },
        cancelQuestion: @escaping (String) -> Void = { _ in },
        retryQuestion: @escaping (String) -> Void = { _ in },
        answerUsingAvailable: @escaping (String) -> Void = { _ in }
    ) {
        self.highlightCurrentPassage = highlightCurrentPassage
        self.openPriorMeeting = openPriorMeeting
        self.openWebSource = openWebSource
        self.togglePin = togglePin
        self.dismiss = dismiss
        self.copyCard = copyCard
        self.followUp = followUp
        self.retry = retry
        self.toggleExpanded = toggleExpanded
        self.cancelQuestion = cancelQuestion
        self.retryQuestion = retryQuestion
        self.answerUsingAvailable = answerUsingAvailable
    }

    static func pasteboardCopy(_ text: String) -> Void {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - View Model

/// Observable shell state for the rail: fixture snapshot plus pin/
/// dismiss/expand state. All mutations flow through the injected actions
/// so behavior is unit-testable without a live pipeline (#299 owns live).
@MainActor
public final class ResearchRailViewModel: ObservableObject {
    @Published private(set) var snapshot: ResearchRailSnapshot
    @Published public var focusMode: ResearchFocusMode = .transcript
    @Published public var intelligenceExpanded = false
    @Published public var intelligenceWidth: CGFloat = 420
    @Published public var conversationScrollID: String?
    /// #299: live composer text. The shell stays inert unless the app
    /// provides `onSubmitQuestion`; nil keeps prior behavior exactly.
    @Published public var composerText = ""
    /// False while the production corpus is rebuilding. The UI and the
    /// submit method both enforce this so keyboard submission cannot race a
    /// temporarily disabled Send button.
    @Published public var isComposerEnabled = true
    public struct WebPreview {
        public let question: String
        public let meetingID: String
        public let scope: MeetingResearchScope
    }
    @Published public var webPreview: WebPreview?
    @Published public var webQueryDraft = ""
    @Published public var webSourceDomainsDraft = ""
    public var onSubmitWebQuestion: ((String, String, [String], String) -> Void)?
    public var onSubmitQuestion: ((String) -> Void)?
    public var onResearchScope: ((MeetingResearchScope) -> Void)?
    public var onManageResearch: (() -> Void)?

    let actions: ResearchRailActions

    public init(
        snapshot: ResearchRailSnapshot = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil),
        actions: ResearchRailActions = ResearchRailActions()
    ) {
        self.snapshot = snapshot
        self.actions = actions
    }

    /// Cards visible after dismissal; pinned cards stay first.
    var visibleCards: [ResearchCard] {
        snapshot.cards
            .filter { !$0.isDismissed }
            .sorted { $0.isPinned && !$1.isPinned }
    }

    // MARK: - Card interactions (all testable through actions injection)

    func togglePin(_ cardID: String) {
        actions.togglePin(cardID)
        snapshot.cards = snapshot.cards.map {
            $0.id == cardID
                ? ResearchCard(id: $0.id, variant: $0.variant, title: $0.title, summary: $0.summary,
                               evidence: $0.evidence, isPinned: !$0.isPinned,
                               isDismissed: $0.isDismissed, isExpanded: $0.isExpanded)
                : $0
        }
    }

    /// Dismiss also records suppression feedback for the current meeting.
    func dismiss(_ cardID: String) {
        actions.dismiss(cardID)
        snapshot.cards = snapshot.cards.map {
            $0.id == cardID
                ? ResearchCard(id: $0.id, variant: $0.variant, title: $0.title, summary: $0.summary,
                               evidence: $0.evidence, isPinned: $0.isPinned,
                               isDismissed: true, isExpanded: $0.isExpanded)
                : $0
        }
    }

    func toggleExpanded(_ cardID: String) {
        actions.toggleExpanded(cardID)
        snapshot.cards = snapshot.cards.map {
            $0.id == cardID
                ? ResearchCard(id: $0.id, variant: $0.variant, title: $0.title, summary: $0.summary,
                               evidence: $0.evidence, isPinned: $0.isPinned,
                               isDismissed: $0.isDismissed, isExpanded: !$0.isExpanded)
                : $0
        }
    }

    func copy(_ card: ResearchCard) {
        actions.copyCard("\(card.title)\n\n\(card.summary)")
    }

    func followUp(_ cardID: String) {
        actions.followUp(cardID)
    }

    func retry() {
        actions.retry()
    }

    /// #299: lets the app-side bridge push live coordinator state.
    public func updateSnapshot(_ newSnapshot: ResearchRailSnapshot) {
        let oldQuestionIDs = snapshot.meetingQuestions?.map(\.id) ?? []
        let newQuestionIDs = newSnapshot.meetingQuestions?.map(\.id) ?? []
        let priorStateByID = Dictionary(
            uniqueKeysWithValues: snapshot.cards.map {
                ($0.id, ($0.isPinned, $0.isDismissed, $0.isExpanded))
            }
        )
        let cards = newSnapshot.cards.map { card in
            guard let priorState = priorStateByID[card.id] else { return card }
            return ResearchCard(
                id: card.id,
                variant: card.variant,
                title: card.title,
                summary: card.summary,
                evidence: card.evidence,
                isPinned: priorState.0,
                isDismissed: priorState.1,
                isExpanded: priorState.2
            )
        }
        snapshot = ResearchRailSnapshot(
            state: newSnapshot.state,
            cards: cards,
            activeQuestion: newSnapshot.activeQuestion,
            spokenStatus: newSnapshot.spokenStatus,
            meetingQuestions: newSnapshot.meetingQuestions,
            meetingTitle: newSnapshot.meetingTitle
        )
        if webPreview?.meetingID != newSnapshot.meetingContextID || webPreview?.scope != newSnapshot.researchScope {
            cancelWebPreview()
        }
        snapshot.meetingContextID = newSnapshot.meetingContextID
        snapshot.researchAccess = newSnapshot.researchAccess
        snapshot.researchScope = newSnapshot.researchScope
        snapshot.conversationNotice = newSnapshot.conversationNotice
        // Reveal a newly submitted question, but never pull the reader away
        // just because an existing answer or the recording countdown changes.
        if let last = newQuestionIDs.last,
           newQuestionIDs.count > oldQuestionIDs.count || Set(oldQuestionIDs).isDisjoint(with: newQuestionIDs) {
            conversationScrollID = last
        }
        if let access = newSnapshot.researchAccess { isComposerEnabled = access.canAsk }
    }

    /// #299: submits the composer text when a live handler is wired.
    public func submitQuestion() {
        guard isComposerEnabled else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { return }
        cancelWebPreview()
        onSubmitQuestion?(text)
        composerText = ""
    }

    public var approvedWebDomains: [String]? { WebSearchSourcePolicy.domains(from: webSourceDomainsDraft) }
    public var effectiveWebQuery: String {
        WebSearchSourcePolicy.query(webQueryDraft, domains: approvedWebDomains ?? [])
    }
    public var canApproveWebQuery: Bool {
        guard let preview = webPreview, approvedWebDomains != nil else { return false }
        return isComposerEnabled && preview.meetingID == snapshot.meetingContextID && preview.scope == snapshot.researchScope
            && !webQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && effectiveWebQuery.count <= 600 && effectiveWebQuery.split(whereSeparator: \.isWhitespace).count <= 75
    }

    public func previewWebQuestion() {
        let question = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isComposerEnabled, onSubmitWebQuestion != nil, let id = snapshot.meetingContextID,
              !question.isEmpty, question.count <= 2_000 else { return }
        webPreview = .init(question: question, meetingID: id, scope: snapshot.researchScope)
        webQueryDraft = question
        webSourceDomainsDraft = ""
    }
    public func cancelWebPreview() { webPreview = nil; webQueryDraft = ""; webSourceDomainsDraft = "" }
    public func approveWebQuestion() {
        guard canApproveWebQuery, let preview = webPreview, let domains = approvedWebDomains else { return }
        let query = effectiveWebQuery
        cancelWebPreview() // Consumes approval before invoking the callback.
        composerText = ""
        onSubmitWebQuestion?(preview.question, query, domains, preview.meetingID)
    }

    func openSource(for evidence: ResearchEvidence) {
        actions.openSource(for: evidence)
    }
}
