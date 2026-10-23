import Foundation
import OpenBridgeUI

// MARK: - Observatory Coordinator (#299 / Live Integration)
//
// The single bounded question coordinator connecting evaluated
// capabilities to the approved #318 Research Observatory shell WITHOUT
// touching recording or transcription.
//
// Responsibilities (per issue):
//   - Typed AND explicit spoken questions share ONE coordinator path
//     (no duplicates); spoken questions arrive from #309 invocations.
//   - Memory questions route to #306 ranked evidence + #307 grounded
//     answers; explicitly authorized web questions route to #313.
//   - Current-meeting, prior-meeting, web, and model-synthesis evidence
//     stay distinct sources.
//   - At most ONE proactive memory cue; explicit answers stay primary.
//   - Centralized confidence gating, duplicate prevention, stale-result
//     cancellation, per-meeting dismissal suppression.
//   - Full rail state machine: quiet / memoryCue / searching / answered /
//     noSource / timeout / failure — all contained inside the rail.
//   - The legacy proactive-card evaluation flag remains unpromoted until a
//     #292 gate record passes; this limited Beta is explicit-action only.
//
// Non-goals: SwiftUI owns presentation; #300/#311 own decision/action
// cards (P1); no external actions; no audio upload; no transcript
// context to the web beyond the #312-approved payload.

// MARK: - Feature Flag

/// The internal feature flag. Promotion requires a passing #292 gate
/// record; enforcement is in `canPromote` and tested.
struct ObservatoryFeatureFlag: Equatable, Sendable {
    /// Promoted only after a passing gate record was recorded.
    private(set) var isEnabled = false
    /// The gate record that authorized promotion (nil while disabled).
    private(set) var authorizingGateRecord: EvaluationGate.GateRecord?

    /// Attempt promotion from a #292 gate record. Succeeds only when the
    /// record passed every check.
    @discardableResult
    mutating func promote(with gateRecord: EvaluationGate.GateRecord) -> Bool {
        guard gateRecord.passed else { return false }
        isEnabled = true
        authorizingGateRecord = gateRecord
        return true
    }

    mutating func demote() {
        isEnabled = false
        authorizingGateRecord = nil
    }
}

// MARK: - Question Intake

/// How a question enters the single coordinator.
enum ObservatoryQuestionOrigin: Equatable, Sendable {
    case typed
    case spoken(SpokenInvocation)
}

/// The unified question both origins normalize into — same coordinator,
/// same dedup key space.
struct ObservatoryQuestion: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let origin: ObservatoryQuestionOrigin
    /// Explicit web authority for THIS question (user opt-in).
    let webAuthority: Bool

    /// Canonical dedup key: normalized text — typed and spoken variants
    /// of the same question collide, so duplicates cannot surface.
    var deduplicationKey: String {
        ShadowEventClassifier.normalizedText(text)
    }

    init(text: String, origin: ObservatoryQuestionOrigin, webAuthority: Bool = false) {
        self.id = UUID().uuidString
        self.text = text
        self.origin = origin
        self.webAuthority = webAuthority
    }
}

// MARK: - Result Evidence

/// One distinct-source evidence row presented by the rail.
struct ObservatoryEvidence: Equatable, Identifiable, Sendable {
    enum Source: Equatable, Sendable {
        case currentMeeting(meetingID: String, spanID: String)
        case priorMeeting(meetingID: String, segmentID: String)
        case web(url: String)
        case modelSynthesis
    }

    let id: String
    let source: Source
    /// Display passage; verbatim from retrieval/web or synthesized.
    let passage: String
    /// Confidence in [0,1] for gating.
    let confidence: Double
}

/// A completed answer with its distinct evidence rows.
struct ObservatoryAnswer: Equatable, Sendable {
    let questionID: String
    let answerText: String
    let evidence: [ObservatoryEvidence]
    var questionText: String = ""
}

// MARK: - Coordinator

/// The bounded question coordinator driving the rail state machine.
@MainActor
final class ObservatoryCoordinator: ObservableObject {
    // Rail state (#318 contract).
    @Published private(set) var railState: ResearchRailState = .quiet
    @Published private(set) var currentAnswer: ObservatoryAnswer?
    /// Completed answers outlive request activity, but never the session.
    @Published private(set) var completedAnswers: [ObservatoryAnswer] = []
    @Published private(set) var activeQuestion: ObservatoryQuestion?
    @Published private(set) var spokenStatus = ResearchSpokenStatus()
    @Published private(set) var proactiveCue: ObservatoryEvidence?
    @Published private(set) var featureFlag = ObservatoryFeatureFlag()

    #if DEBUG
    /// #299: DEBUG-only test-mode activation for manual testing.
    /// Satisfies the rail gate without a real evaluation record; compiled
    /// out in release. Accepts any of:
    ///   - launch argument:  OpenBridgeApp -observatoryTestMode
    ///     (reliable path for the unbundled SwiftPM test executable,
    ///     whose defaults domain is the executable name)
    ///   - process defaults: defaults write OpenBridgeApp observatoryTestMode -bool true
    ///   - bundle suite:     defaults write dev.openbridge.OpenBridgeApp observatoryTestMode -bool true
    func enableForManualTesting() {
        featureFlag.promoteForTesting()
    }

    static func manualTestingRequested() -> Bool {
        if CommandLine.arguments.contains("-observatoryTestMode") { return true }
        if UserDefaults.standard.bool(forKey: "observatoryTestMode") { return true }
        if let suite = UserDefaults(suiteName: "dev.openbridge.OpenBridgeApp"),
           suite.bool(forKey: "observatoryTestMode") {
            return true
        }
        return false
    }
    #endif

    // Dependencies (injected; no SwiftUI provider instantiation).
    private let answerService: GroundedAnswerService
    private let webService: WebResearchService?
    private let workspaceIndex: WorkspaceRetrievalIndex?
    private var workspaceID: String?
    private var providerMode: ResearchProviderMode
    private var meetingContextID: String?

    // Centralized suppression state (session-local).
    private var handledQuestionKeys = Set<String>()
    private var handledSpokenQuestionKeys = Set<String>()
    private var handledSpokenSpanIDs = Set<String>()
    private var dismissedEvidenceKeys = Set<String>()
    private var latestQuestionID: String?
    private var lastQuestion: ObservatoryQuestion?
    private var activeTask: Task<Void, Never>?
    private var pendingSpokenQuestions: [ObservatoryQuestion] = [] {
        didSet { spokenStatus.queuedQuestions = pendingSpokenQuestions.map(\.text) }
    }
    /// #299: quiet-return timer — after a terminal state the rail
    /// returns to quiet (no reason to keep intervening, per #317).
    private var quietReturnTask: Task<Void, Never>?

    struct Configuration: Sendable {
        var minEvidenceConfidence = 0.5
        /// Production Beta is reactive-only. Existing evaluation fixtures
        /// can opt in explicitly while unsolicited cards remain impossible
        /// in the shipped configuration.
        var allowsProactiveCues = false
        /// Maximum proactive cues visible at once (hard: 1).
        let maxProactiveCues = 1
        static let `default` = Configuration()
    }

    private let configuration: Configuration

    init(
        answerService: GroundedAnswerService,
        webService: WebResearchService? = nil,
        workspaceIndex: WorkspaceRetrievalIndex? = nil,
        workspaceID: String? = nil,
        providerMode: ResearchProviderMode = .localOnly,
        configuration: Configuration = .default
    ) {
        self.answerService = answerService
        self.webService = webService
        self.workspaceIndex = workspaceIndex
        self.workspaceID = workspaceID
        self.providerMode = providerMode
        self.configuration = configuration

    }

    // MARK: - Question Intake (typed + spoken → ONE path)

    func receiveSpokenUpdate(_ update: SpokenDetectionUpdate) {
        spokenStatus.pendingQuestion = update.pending?.invocation.commandText
        spokenStatus.needsRepeat = update.needsRepeat
        submitSpoken(update.invocations)
    }

    /// Typed question entry point.
    func submitTyped(_ text: String, webAuthority: Bool = false) {
        submit(ObservatoryQuestion(text: text, origin: .typed, webAuthority: webAuthority))
    }

    /// Spoken question entry point (#309 invocation).
    func submitSpoken(_ invocation: SpokenInvocation, webAuthority: Bool = false) {
        submitSpoken([invocation], webAuthority: webAuthority)
    }

    func submitSpoken(_ invocations: [SpokenInvocation], webAuthority: Bool = false) {
        for invocation in invocations {
            let key = "\(invocation.sourceSpanID)|\(invocation.commandIndex)"
            guard handledSpokenSpanIDs.insert(key).inserted else { continue }
            let question = ObservatoryQuestion(text: invocation.commandText, origin: .spoken(invocation), webAuthority: webAuthority)
            guard !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Preserve typed/spoken cross-origin suppression, but a genuinely
            // new spoken utterance may ask the same question again.
            if handledQuestionKeys.contains(question.deduplicationKey) { continue }
            handledSpokenQuestionKeys.insert(question.deduplicationKey)
            pendingSpokenQuestions.append(question)
        }
        startNextSpokenQuestion()
    }

    private func startNextSpokenQuestion() {
        guard activeTask == nil, !pendingSpokenQuestions.isEmpty else { return }
        start(pendingSpokenQuestions.removeFirst())
    }

    /// Updates the per-meeting privacy boundary used by future explicit
    /// questions. Cloud is allowed only for a meeting created with Cloud
    /// intelligence consent; an absent or local meeting remains local-only.
    func setMeetingContext(
        meetingID: String?,
        workspaceID: String?,
        allowsCloud: Bool
    ) {
        if meetingContextID != meetingID || self.workspaceID != workspaceID {
            endOfMeeting()
        }
        meetingContextID = meetingID
        self.workspaceID = workspaceID
        providerMode = allowsCloud ? .cloudExperiment : .localOnly
    }

    func cancelCurrentRequest() {
        ObservatorySpokenIntake.shared.reset()
        spokenStatus = .init()
        activeTask?.cancel()
        activeTask = nil
        latestQuestionID = nil
        pendingSpokenQuestions.removeAll()
        activeQuestion = nil
        railState = .quiet
    }

    func retryLastQuestion() {
        guard let lastQuestion else { return }
        handledQuestionKeys.remove(lastQuestion.deduplicationKey)
        submit(ObservatoryQuestion(
            text: lastQuestion.text,
            origin: lastQuestion.origin,
            webAuthority: lastQuestion.webAuthority
        ))
    }

    private func submit(_ question: ObservatoryQuestion) {
        guard !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .typed = question.origin {
            // Typing is the offered recovery action, including a repeated
            // question whose answer is already visible. Do not keep a stale
            // voice fragment or its repeat guidance alive after that action.
            ObservatorySpokenIntake.shared.reset()
            spokenStatus.pendingQuestion = nil
            spokenStatus.needsRepeat = false
        }
        if case .typed = question.origin, handledSpokenQuestionKeys.contains(question.deduplicationKey) { return }
        // Duplicate prevention across BOTH origins.
        guard !handledQuestionKeys.contains(question.deduplicationKey) else { return }
        handledQuestionKeys.insert(question.deduplicationKey)
        // Typed replacement/retry remains an explicit supersession action.
        pendingSpokenQuestions.removeAll()
        start(question)
    }

    private func start(_ question: ObservatoryQuestion) {
        lastQuestion = question
        activeQuestion = question

        // Stale cancellation: a newer question supersedes in-flight work.
        activeTask?.cancel()
        quietReturnTask?.cancel()
        latestQuestionID = question.id
        currentAnswer = nil
        railState = .searching

        let questionID = question.id
        let webAuthority = question.webAuthority

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.latestQuestionID == questionID {
                    self.activeTask = nil
                    self.startNextSpokenQuestion()
                }
            }
            do {
                try Task.checkCancellation()

                // Web-authorized questions route to #313.
                if webAuthority {
                    try await self.runWebResearch(question: question)
                } else if case .spoken = question.origin {
                    // Build 25: an explicit wake phrase routes to the
                    // separately attributed model-knowledge path. The
                    // service still fails closed unless this meeting and
                    // the active tested provider match exactly.
                    try await self.runModelKnowledge(question: question)
                } else {
                    // Typed Ask remains the bounded local-meeting path.
                    try await self.runMemoryAnswer(question: question)
                }

                // Stale check: a newer question superseded this work.
                try Task.checkCancellation()
                guard self.latestQuestionID == questionID else { return }
            } catch is CancellationError {
                // Stale/cancelled: silently drop; newer question owns the rail.
            } catch {
                guard self.latestQuestionID == questionID else { return }
                guard !Task.isCancelled else { return }
                self.completedAnswers.append(ObservatoryAnswer(questionID: question.id,
                    answerText: "This request could not be answered. Your meeting is unaffected. You can ask again.",
                    evidence: [], questionText: question.text))
                self.railState = .failure
                self.scheduleQuietReturn()
                // #219: route the provider failure through the recovery
                // boundary — recorded as an isolated event against the
                // ACTIVE meeting (if any); never marks any meeting failed.
                RecoveryActionRouter.recordProviderFailure(String(describing: error))
                #if DEBUG
                print("[observatory] provider failure recorded")
                #endif
            }
        }
    }

    // MARK: - Memory Answers (#306 + #307)

    // MARK: - Model Knowledge (#60)

    /// Spoken-origin path: cloud/model knowledge only — no workspace
    /// retrieval, no prior-meeting citations. Evidence is attributed to
    /// model synthesis.
    private func runModelKnowledge(question: ObservatoryQuestion) async throws {
        guard let answer = try await answerService.answerFromModelKnowledge(
            question: question.text,
            meetingID: meetingContextID,
            mode: providerMode
        ) else {
            try Task.checkCancellation()
            railState = .noSource
            scheduleQuietReturn()
            return
        }
        try Task.checkCancellation()
        publish(ObservatoryAnswer(
            questionID: question.id,
            answerText: answer.text,
            evidence: [ObservatoryEvidence(
                id: UUID().uuidString,
                source: .modelSynthesis,
                passage: "",
                confidence: answer.confidence
            )]
        ), for: question)
        railState = .answered
    }

    private func runMemoryAnswer(question: ObservatoryQuestion) async throws {
        guard let index = workspaceIndex else {
            railState = .noSource
            scheduleQuietReturn()
            return
        }

        guard let answer = try await answerService.answer(
            question: question.text,
            index: index,
            workspaceID: workspaceID,
            meetingID: meetingContextID,
            mode: providerMode
        ) else {
            try Task.checkCancellation()
            // Weak evidence abstains — no card, explicit noSource state.
            railState = .noSource
            scheduleQuietReturn()
            return
        }

        // Source identity comes from local retrieval, never the model.
        let evidence = answer.sources.map { source in
            let kind: ObservatoryEvidence.Source
            if source.meetingID == meetingContextID {
                kind = .currentMeeting(
                    meetingID: source.meetingID,
                    spanID: source.segmentID
                )
            } else {
                kind = .priorMeeting(
                    meetingID: source.meetingID,
                    segmentID: source.segmentID
                )
            }
            return ObservatoryEvidence(
                id: source.evidenceID,
                source: kind,
                passage: source.passage,
                confidence: answer.confidence
            )
        }

        try Task.checkCancellation()

        let filtered = evidence.filter { !dismissedEvidenceKeys.contains($0.source.dedupKey) }
        guard !filtered.isEmpty else {
            railState = .noSource
            return
        }

        publish(ObservatoryAnswer(
            questionID: question.id,
            answerText: answer.sentences.map(\.text).joined(separator: " "),
            evidence: filtered
        ), for: question)
        railState = .answered
    }

    // MARK: - Web Research (#313)

    private func runWebResearch(question: ObservatoryQuestion) async throws {
        guard let webService else {
            railState = .failure
            return
        }
        let authorized = AuthorizedWebQuestion(
            requestID: question.id,
            questionText: question.text,
            webAuthority: question.webAuthority
        )
        do {
            let result = try await webService.research(authorized)
            try Task.checkCancellation()
            let evidence = result.items
                .filter { !dismissedEvidenceKeys.contains("web|\($0.url.absoluteString)") }
                .map { ObservatoryEvidence(
                    id: UUID().uuidString,
                    source: .web(url: $0.url.absoluteString),
                    passage: $0.passage,
                    confidence: $0.score ?? 0 // Legacy rail: unknown confidence never passes a confidence gate.
                ) }
            guard !evidence.isEmpty else {
                railState = .noSource
                return
            }
            publish(ObservatoryAnswer(
                questionID: question.id,
                answerText: evidence.first?.passage ?? "",
                evidence: evidence
            ), for: question)
            railState = .answered
        } catch let error as WebResearchServiceError {
            // Distinguishable outcomes stay inside the rail.
            switch error {
            case .timedOut: railState = .timeout
            case .consentRequired, .noCredential, .disabled: railState = .failure
            case .offline: railState = .failure
            case .malformedSource: railState = .noSource
            case .providerFailed: railState = .failure
            case .staleRequest: break // superseded silently
            }
        }
    }

    // MARK: - Proactive Memory Cue (at most one)

    private func publish(_ result: ObservatoryAnswer, for question: ObservatoryQuestion) {
        var answer = result
        answer.questionText = question.text
        currentAnswer = answer
        completedAnswers.append(answer)
    }

    func dismissAnswer(_ cardID: String) {
        completedAnswers.removeAll { "answer-\($0.questionID)" == cardID }
        if let currentAnswer, "answer-\(currentAnswer.questionID)" == cardID {
            self.currentAnswer = nil
        }
    }

    /// Offers a proactive memory cue; enforces the single-cue invariant
    /// and current-meeting dismissal suppression.
    func offerProactiveCue(_ cue: ObservatoryEvidence) {
        guard configuration.allowsProactiveCues else { return }
        guard proactiveCue == nil else { return } // at most one
        guard !dismissedEvidenceKeys.contains(cue.source.dedupKey) else { return }
        // Only when no explicit answer is primary.
        guard currentAnswer == nil else { return }
        proactiveCue = cue
        if railState == .quiet {
            railState = .memoryCue
        }
    }

    // MARK: - Dismissal / Suppression (current meeting)

    func dismissEvidence(_ evidence: ObservatoryEvidence) {
        dismissedEvidenceKeys.insert(evidence.source.dedupKey)
        if proactiveCue?.id == evidence.id {
            proactiveCue = nil
            if railState == .memoryCue { railState = .quiet }
        }
    }

    // MARK: - Quiet Return (#317)

    /// After a terminal state (answered/noSource/failure/timeout), the
    /// rail returns to quiet after a short dwell so it only intervenes
    /// when there is something to say. Superseded by any new question.
    private func scheduleQuietReturn(after seconds: TimeInterval = 10) {
        // Recovery must remain visible until the user acts, not disappear
        // just because a timer elapsed. Completed answer cards stay intact.
        guard railState != .failure, railState != .timeout, railState != .noSource else { return }
        let questionID = latestQuestionID
        quietReturnTask?.cancel()
        quietReturnTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.latestQuestionID == questionID else { return }
            self.railState = .quiet
        }
    }

    // MARK: - Session Lifecycle

    /// Research history stays session-local: endOfMeeting clears state.
    func endOfMeeting() {
        ObservatorySpokenIntake.shared.reset()
        spokenStatus = .init()
        activeTask?.cancel()
        activeTask = nil
        quietReturnTask?.cancel()
        railState = .quiet
        currentAnswer = nil
        completedAnswers.removeAll()
        activeQuestion = nil
        pendingSpokenQuestions.removeAll()
        proactiveCue = nil
        handledQuestionKeys.removeAll()
        handledSpokenQuestionKeys.removeAll()
        handledSpokenSpanIDs.removeAll()
        dismissedEvidenceKeys.removeAll()
        latestQuestionID = nil
        lastQuestion = nil
        meetingContextID = nil
        providerMode = .localOnly
    }

    // MARK: - Flag Promotion (#292 gate enforcement)

    /// Promotion is only possible with a passing #292 gate record.
    @discardableResult
    func promoteFeatureFlag(with gateRecord: EvaluationGate.GateRecord) -> Bool {
        featureFlag.promote(with: gateRecord)
    }
}

// MARK: - Dedup key for evidence sources

extension ObservatoryEvidence.Source {
    /// Stable suppression key per source kind.
    var dedupKey: String {
        switch self {
        case .currentMeeting(let meetingID, let spanID):
            return "current|\(meetingID)|\(spanID)"
        case .priorMeeting(let meetingID, let segmentID): return "prior|\(meetingID)|\(segmentID)"
        case .web(let url): return "web|\(url)"
        case .modelSynthesis: return "synthesis"
        }
    }
}

#if DEBUG
extension ObservatoryFeatureFlag {
    /// #299: test-only promotion — enables the flag for local manual
    /// testing without an evaluation gate record.
    mutating func promoteForTesting() {
        isEnabled = true
    }
}
#endif

extension ObservatoryCoordinator {
    /// Release coordinator for the opt-in Beta. The adaptive provider is
    /// local unless an individual meeting allows cloud and the app-scoped
    /// provider has a current successful Test Connection attestation.
    static func makeForLiveIntegration(
        providerSettings: ProviderSettingsController? = nil
    ) -> ObservatoryCoordinator {
        // Same shared store the transcriber feeds — questions search
        // what meetings actually said.
        //
        let provider: any ResearchProvider
        if let providerSettings {
            provider = ConfiguredResearchProvider(providerSettings: providerSettings)
        } else {
            provider = LocalEvidenceResearchProvider()
        }
        return ObservatoryCoordinator(
            answerService: GroundedAnswerService(
                provider: provider,
                cloudEvidenceAuthorization: { matches in
                    let activeConfiguration = await MainActor.run {
                        providerSettings?.settings.configuration
                    }
                    return ResearchCloudEvidencePolicy.authorizedConfiguration(
                        for: matches,
                        store: MeetingSessionStore(),
                        activeConfiguration: activeConfiguration
                    )
                },
                cloudModelKnowledgeAuthorization: { meetingID in
                    let activeConfiguration = await MainActor.run {
                        providerSettings?.settings.configuration
                    }
                    return ResearchCloudEvidencePolicy.authorizedConfiguration(
                        forMeetingID: meetingID,
                        store: MeetingSessionStore(),
                        activeConfiguration: activeConfiguration
                    )
                }
            ),
            workspaceIndex: ObservatorySharedIndex.shared,
            workspaceID: Workspace.defaultWorkspace.id,
            providerMode: .localOnly
        )
    }
}
