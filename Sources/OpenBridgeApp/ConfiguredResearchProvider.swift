import Foundation

/// Verifies consent for every local passage selected for a possible cloud
/// answer. Consent does not flow from the current meeting into older meeting
/// records; missing, legacy, or local-only manifests fail closed.
enum ResearchCloudEvidencePolicy {
    /// Authorizes a zero-passage model-knowledge request made during one
    /// active meeting. The meeting's immutable privacy/provider snapshot is
    /// authoritative; current app settings alone never grant consent.
    static func authorizedConfiguration(
        forMeetingID meetingID: String?,
        store: MeetingSessionStore,
        activeConfiguration: ProviderConfiguration?
    ) -> ProviderConfiguration? {
        guard let meetingID,
              let activeConfiguration,
              let meeting = try? store.load(meetingID: meetingID),
              meeting.aiMode.maySendTranscriptToCloud,
              meeting.privacySettings.allowsCloudIntelligence,
              let snapshot = meeting.intelligenceConfiguration?.cloudProvider,
              activeConfiguration.hasSameProviderIdentity(as: snapshot.configuration)
        else { return nil }
        return activeConfiguration
    }

    static func authorizedConfiguration(
        for matches: [WorkspacePassageMatch],
        store: MeetingSessionStore,
        activeConfiguration: ProviderConfiguration?
    ) -> ProviderConfiguration? {
        guard let activeConfiguration else { return nil }
        let everySourceAuthorizesConfiguration = !matches.isEmpty && matches.allSatisfy { match in
            guard let meeting = try? store.load(meetingID: match.meetingID) else {
                return false
            }
            guard meeting.aiMode.maySendTranscriptToCloud,
                  meeting.privacySettings.allowsCloudIntelligence,
                  let snapshot = meeting.intelligenceConfiguration?.cloudProvider else {
                return false
            }
            return activeConfiguration.hasSameProviderIdentity(as: snapshot.configuration)
        }
        return everySourceAuthorizesConfiguration ? activeConfiguration : nil
    }

    static func allowsCloud(
        for matches: [WorkspacePassageMatch],
        store: MeetingSessionStore,
        activeConfiguration: ProviderConfiguration?
    ) -> Bool {
        authorizedConfiguration(
            for: matches,
            store: store,
            activeConfiguration: activeConfiguration
        ) != nil
    }
}

/// A production local-only answerer for the Research rail. It performs no
/// inference and no network request: each retrieved local passage becomes a
/// cited answer contribution (post-freeze regression fix, Build 24 QA on
/// PR #98 — multi-fact questions previously surfaced only the single
/// best-matching passage), each cited to its stable source ID.
struct LocalEvidenceResearchProvider: ResearchProvider {
    let descriptor = ResearchProviderDescriptor(
        identifier: "local-evidence",
        displayName: "Local meeting search",
        capabilities: [.classification, .groundedAnswer],
        isCloud: false
    )

    func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
        ClassificationResponse(
            requestID: request.context.requestID,
            category: .factual,
            confidence: 1
        )
    }

    func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
        try Task.checkCancellation()
        // Post-freeze regression fix (Build 24 QA, PR #98) + round-2 (3):
        // clause-aware selection. A multi-clause (multi-fact) question gets
        // one answer claim per clause-selected fact (the service has
        // already selected one passage per clause). A single-clause question
        // gets exactly ONE claim — the top-ranked passage — so ranked
        // lexical near-matches are never emitted as facts. The extractive
        // contract is unchanged: every cited fragment is verbatim passage
        // text and the deterministic composer still maps each answer
        // sentence to its supporting passage.
        let isMultiClause = GroundedAnswerService.clauseSubQuestions(request.questionText).count > 1
        let selected = isMultiClause
            ? request.passages
            : Array(request.passages.prefix(1))
        guard !selected.isEmpty else {
            return GroundedAnswerResponse(
                requestID: request.context.requestID,
                answerText: "",
                citations: [],
                confidence: 0,
                abstained: true
            )
        }
        return GroundedAnswerResponse(
            requestID: request.context.requestID,
            // Newline-joined: the validator's claim boundary is the
            // newline (answerClaims), so each passage stays one claim even
            // when its text lacks terminal punctuation.
            answerText: selected.map(\.passage).joined(separator: "\n"),
            citations: selected.map { passage in
                ResearchAnswerCitation(
                    evidenceID: passage.evidenceID,
                    quotedFragment: String(passage.passage.prefix(80))
                )
            },
            confidence: max(0.8, min(selected.map(\.confidence).max() ?? 0, 1)),
            abstained: false
        )
    }

    func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
        throw ResearchProviderError.unsupportedOperation("state update")
    }
}

/// Chooses cloud only before a request starts and only when the question's
/// meeting context permits cloud and the current saved provider has a valid
/// Test Connection attestation. A cloud failure is propagated; it never
/// falls back to a different provider after transcript text has been sent.
struct ConfiguredResearchProvider: ResearchProvider, CurrentMeetingQuestionAnswering {
    typealias CloudReadiness = @Sendable () async -> ProviderConfiguration?

    let descriptor = ResearchProviderDescriptor(
        identifier: "configured-research",
        displayName: "Configured meeting research",
        capabilities: .all,
        isCloud: false
    )

    private let cloudReadiness: CloudReadiness
    private let localProvider: any ResearchProvider
    private let cloudProvider: any ResearchProvider

    @MainActor
    init(providerSettings: ProviderSettingsController) {
        cloudReadiness = {
            await MainActor.run {
                guard providerSettings.hasCurrentTestAttestation
                    && providerSettings.settings.mayStartExternalRequest(
                        hasCredential: providerSettings.hasCredential
                    ) else { return nil }
                return providerSettings.settings.configuration
            }
        }
        localProvider = LocalEvidenceResearchProvider()
        cloudProvider = OpenAICompatibleResearchProvider(
            authorizationGate: providerSettings
        )
    }

    init(
        cloudReadiness: @escaping CloudReadiness,
        localProvider: any ResearchProvider,
        cloudProvider: any ResearchProvider
    ) {
        self.cloudReadiness = cloudReadiness
        self.localProvider = localProvider
        self.cloudProvider = cloudProvider
    }

    func classify(_ request: ClassificationRequest) async throws -> ClassificationResponse {
        try await selectedProvider(for: request.context).classify(request)
    }

    func answerCurrentMeeting(_ request: CurrentMeetingQuestionRequest) async throws -> CurrentMeetingQuestionResponse {
        // This explicit cloud workflow must never silently substitute local quotes.
        guard request.context.mode.allowsCloudProvider,
              let expected = request.context.expectedCloudConfiguration,
              let ready = await cloudReadiness(), ready.hasSameProviderIdentity(as: expected),
              let provider = cloudProvider as? any CurrentMeetingQuestionAnswering else {
            throw ResearchProviderError.modeBlocked(request.context.mode)
        }
        return try await provider.answerCurrentMeeting(request)
    }

    func groundedAnswer(_ request: GroundedAnswerRequest) async throws -> GroundedAnswerResponse {
        try await selectedProvider(for: request.context).groundedAnswer(request)
    }

    func stateUpdate(_ request: StateUpdateRequest) async throws -> StateUpdateResponse {
        try await selectedProvider(for: request.context).stateUpdate(request)
    }

    private func selectedProvider(for context: ResearchProviderContext) async -> any ResearchProvider {
        guard context.mode.allowsCloudProvider,
              let expected = context.expectedCloudConfiguration,
              let ready = await cloudReadiness(),
              ready.hasSameProviderIdentity(as: expected) else {
            return localProvider
        }
        return cloudProvider
    }
}
