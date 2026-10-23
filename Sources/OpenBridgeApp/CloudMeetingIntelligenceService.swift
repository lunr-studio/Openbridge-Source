import Foundation

/// Explicit post-meeting cloud operations. This service never runs on its own;
/// callers invoke one operation from a visible user action.
struct CloudMeetingIntelligenceService: Sendable {
    static let maximumTranscriptCharacters = 120_000

    private let authorizationGate: any CloudRequestAuthorizing
    private let modelClient: any CloudModelClient
    private let now: @Sendable () -> Date

    init(
        authorizationGate: any CloudRequestAuthorizing,
        modelClient: any CloudModelClient = OpenAICompatibleCloudModelClient(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.authorizationGate = authorizationGate
        self.modelClient = modelClient
        self.now = now
    }

    func summarize(
        meeting: MeetingManifest,
        providerWasTested: Bool
    ) async throws -> MeetingSummaryArtifact {
        let prepared = try prepare(meeting: meeting, providerWasTested: providerWasTested)
        let response = try await complete(
            meeting: meeting,
            snapshot: prepared.snapshot,
            operation: "summary",
            system: """
                Summarize the supplied meeting transcript faithfully. Do not invent facts, names, decisions, or actions. Reply with ONLY JSON: {"summary":"a concise useful summary"}
                """,
            transcriptJSON: prepared.transcriptJSON,
            maxTokens: 1_200
        )
        struct Envelope: Decodable { let summary: String }
        guard let envelope = try? decodePayload(Envelope.self, response),
              !envelope.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingIntelligenceArtifactError.malformedResponse
        }
        return MeetingSummaryArtifact(
            id: UUID().uuidString,
            sourceTranscriptFingerprint: prepared.fingerprint,
            provenance: MeetingIntelligenceProvenance(snapshot: prepared.snapshot),
            createdAt: now(),
            text: envelope.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func extractActionsAndDecisions(
        meeting: MeetingManifest,
        providerWasTested: Bool
    ) async throws -> MeetingActionsDecisionsArtifact {
        let prepared = try prepare(meeting: meeting, providerWasTested: providerWasTested)
        let response = try await complete(
            meeting: meeting,
            snapshot: prepared.snapshot,
            operation: "actions-decisions",
            system: """
                Extract only explicit actions and decisions from the supplied meeting transcript. Every item must cite one or more sourceSegmentIDs from the input. Do not infer missing owners or decisions. Reply with ONLY JSON: {"actions":[{"description":"...","assignee":null,"supportingSegmentIDs":["..."]}],"decisions":[{"summary":"...","supportingSegmentIDs":["..."]}]}
                """,
            transcriptJSON: prepared.transcriptJSON,
            maxTokens: 2_000
        )

        struct ActionEnvelope: Decodable {
            let description: String
            let assignee: String?
            let supportingSegmentIDs: [String]
        }
        struct DecisionEnvelope: Decodable {
            let summary: String
            let supportingSegmentIDs: [String]
        }
        struct Envelope: Decodable {
            let actions: [ActionEnvelope]
            let decisions: [DecisionEnvelope]
        }
        guard let envelope = try? decodePayload(Envelope.self, response) else {
            throw MeetingIntelligenceArtifactError.malformedResponse
        }

        let knownIDs = Set(prepared.segments.map(\.id))
        let referencesAreValid = envelope.actions.allSatisfy {
            !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.supportingSegmentIDs.isEmpty
                && Set($0.supportingSegmentIDs).isSubset(of: knownIDs)
        } && envelope.decisions.allSatisfy {
            !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.supportingSegmentIDs.isEmpty
                && Set($0.supportingSegmentIDs).isSubset(of: knownIDs)
        }
        guard referencesAreValid else {
            throw MeetingIntelligenceArtifactError.unsupportedSegmentReference
        }

        return MeetingActionsDecisionsArtifact(
            id: UUID().uuidString,
            sourceTranscriptFingerprint: prepared.fingerprint,
            provenance: MeetingIntelligenceProvenance(snapshot: prepared.snapshot),
            createdAt: now(),
            actions: envelope.actions.map {
                let normalizedAssignee = $0.assignee?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return MeetingIntelligenceAction(
                    id: UUID().uuidString,
                    description: $0.description.trimmingCharacters(in: .whitespacesAndNewlines),
                    assignee: normalizedAssignee?.isEmpty == false ? normalizedAssignee : nil,
                    supportingSegmentIDs: $0.supportingSegmentIDs
                )
            },
            decisions: envelope.decisions.map {
                MeetingIntelligenceDecision(
                    id: UUID().uuidString,
                    summary: $0.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    supportingSegmentIDs: $0.supportingSegmentIDs
                )
            }
        )
    }

    private struct PreparedMeeting {
        let snapshot: MeetingCloudProviderSnapshot
        let segments: [MeetingTranscriptSegment]
        let transcriptJSON: String
        let fingerprint: String
    }

    private struct TranscriptEnvelope: Encodable {
        struct Segment: Encodable {
            let sourceSegmentID: String
            let text: String
        }
        let segments: [Segment]
    }

    private func prepare(
        meeting: MeetingManifest,
        providerWasTested: Bool
    ) throws -> PreparedMeeting {
        guard meeting.intelligenceConfiguration != nil else {
            throw MeetingIntelligenceArtifactError.legacyMeeting
        }
        guard meeting.state == .completed else {
            throw MeetingIntelligenceArtifactError.meetingNotCompleted
        }
        guard meeting.aiMode.maySendTranscriptToCloud,
              meeting.privacySettings.allowsCloudIntelligence else {
            throw MeetingIntelligenceArtifactError.cloudConsentRequired
        }
        guard providerWasTested else {
            throw MeetingIntelligenceArtifactError.providerNotTested
        }
        guard let snapshot = meeting.intelligenceConfiguration?.cloudProvider else {
            throw MeetingIntelligenceArtifactError.missingProviderSnapshot
        }
        let segments = meeting.segments.sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
        guard !segments.isEmpty,
              segments.allSatisfy({
                  $0.meetingID == meeting.meetingID && $0.isFinal
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              Set(segments.map(\.id)).count == segments.count else {
            throw MeetingIntelligenceArtifactError.noTranscript
        }

        let envelope = TranscriptEnvelope(
            segments: segments.map {
                TranscriptEnvelope.Segment(sourceSegmentID: $0.id, text: $0.text)
            }
        )
        let data = try JSONEncoder().encode(envelope)
        guard let transcriptJSON = String(data: data, encoding: .utf8) else {
            throw MeetingIntelligenceArtifactError.malformedResponse
        }
        guard transcriptJSON.count <= Self.maximumTranscriptCharacters else {
            throw MeetingIntelligenceArtifactError.transcriptTooLarge
        }
        return PreparedMeeting(
            snapshot: snapshot,
            segments: segments,
            transcriptJSON: transcriptJSON,
            fingerprint: MeetingTranscriptFingerprint.make(for: segments)
        )
    }

    private func complete(
        meeting: MeetingManifest,
        snapshot: MeetingCloudProviderSnapshot,
        operation: String,
        system: String,
        transcriptJSON: String,
        maxTokens: Int
    ) async throws -> String {
        try Task.checkCancellation()
        let requestID = "meeting-\(operation)-\(meeting.meetingID)-\(UUID().uuidString)"
        let authorization = try await authorizationGate.authorizeCloudRequest(
            requestID: requestID,
            meetingConsent: meeting.aiMode.maySendTranscriptToCloud
                && meeting.privacySettings.allowsCloudIntelligence,
            expectedConfiguration: snapshot.configuration
        )
        do {
            let response = try await modelClient.complete(
                CloudChatCompletionRequest(
                    messages: [
                        CloudChatMessage(role: .system, content: system),
                        CloudChatMessage(role: .user, content: transcriptJSON),
                    ],
                    maxTokens: maxTokens,
                    temperature: 0.1
                ),
                authorization: authorization
            )
            try Task.checkCancellation()
            await authorizationGate.finishCloudRequest(requestID: requestID)
            return response
        } catch {
            await authorizationGate.finishCloudRequest(requestID: requestID)
            if error is CancellationError || Task.isCancelled
                || (error as? CloudModelClientError) == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, _ content: String) throws -> T {
        var text = content
        if let start = text.range(of: "<think>"),
           let end = text.range(of: "</think>"),
           start.lowerBound < end.upperBound {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8) else {
            throw MeetingIntelligenceArtifactError.malformedResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
