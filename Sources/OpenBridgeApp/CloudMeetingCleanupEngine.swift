import Foundation

/// Provider-neutral cloud cleanup adapter. It asks for one strict,
/// ID-preserving JSON result per bounded source chunk, then hands the complete
/// aligned result to the existing durable coordinator for atomic activation.
struct CloudMeetingCleanupEngine: MeetingCleanupEngine {
    private let meetingID: String
    private let meetingConsent: Bool
    private let providerSnapshot: MeetingCloudProviderSnapshot
    private let authorizationGate: any CloudRequestAuthorizing
    private let modelClient: any CloudModelClient

    init(
        meetingID: String,
        meetingConsent: Bool,
        providerSnapshot: MeetingCloudProviderSnapshot,
        authorizationGate: any CloudRequestAuthorizing,
        modelClient: any CloudModelClient = OpenAICompatibleCloudModelClient()
    ) {
        self.meetingID = meetingID
        self.meetingConsent = meetingConsent
        self.providerSnapshot = providerSnapshot
        self.authorizationGate = authorizationGate
        self.modelClient = modelClient
    }

    var provenance: MeetingCleanupProvenance {
        .cloud(providerSnapshot)
    }

    func cleanMeetingSegments(
        _ segments: [MeetingTranscriptSegment]
    ) async throws -> MeetingCleanupEngineOutput {
        let ordered = segments.sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
        var cleaned: [MeetingCleanedSegment] = []

        for (chunkIndex, chunk) in chunked(ordered).enumerated() {
            try Task.checkCancellation()
            let requestID = "cleanup-\(meetingID)-\(chunkIndex)-\(UUID().uuidString)"
            let authorization = try await authorizationGate.authorizeCloudRequest(
                requestID: requestID,
                meetingConsent: meetingConsent,
                expectedConfiguration: providerSnapshot.configuration
            )

            do {
                let response = try await modelClient.complete(
                    CloudChatCompletionRequest(
                        messages: [
                            CloudChatMessage(role: .system, content: Self.systemPrompt),
                            CloudChatMessage(role: .user, content: try Self.userPrompt(for: chunk)),
                        ],
                        maxTokens: 4_096,
                        temperature: 0,
                        responseFormat: Self.responseFormat(
                            for: providerSnapshot.preset,
                            itemCount: chunk.count
                        ),
                        reasoning: providerSnapshot.preset == .openRouter ? .disabled : nil
                    ),
                    authorization: authorization
                )
                await authorizationGate.finishCloudRequest(requestID: requestID)
                cleaned.append(contentsOf: try Self.decodeAligned(response, source: chunk))
            } catch {
                await authorizationGate.finishCloudRequest(requestID: requestID)
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }

        return MeetingCleanupEngineOutput(
            contractVersion: MeetingCleanupContract.version,
            modelRepository: providerSnapshot.model,
            modelRevision: providerSnapshot.model,
            chunkSize: MeetingCleanupContract.chunkSize,
            segments: cleaned
        )
    }

    private static let systemPrompt = """
        You are a conservative editor of automatic speech-recognition transcript segments.
        Produce clean verbatim text, not a rewrite or summary. Fidelity is more important than
        fluency; when uncertain, make fewer changes.

        PRIORITIES
        1. Preserve every meaningful statement, clause, qualification, correction, comparison,
        and negation.
        2. Preserve every name, number, amount, date, and instance of profanity.
        3. Improve punctuation, capitalization, and readability.

        SEALED-SEGMENT RULES
        - Treat each numbered input item as a sealed container.
        - Return exactly one result for every input item, in the same order, and copy each numeric
        index exactly.
        - Edit only text from that item. Never move, copy, borrow, or duplicate text across items.
        - Never add, omit, merge, or split items. Preserve boundaries even when an item begins or
        ends mid-sentence.
        - When an item ends mid-sentence, do not add words, an ellipsis, or terminal punctuation
        that makes the fragment appear complete.
          Example: we stopped because must remain We stopped because, not We stopped because. or
        We stopped because...
        - Never return empty cleanedText or replace speech with an ellipsis.

        CONTENT RULES
        - Do not summarize, paraphrase, reorganize, improve the speaker's argument, add transitions,
        infer information, or invent facts.
        - Do not guess unclear words or names. No glossary is supplied, so retain every proper noun
        exactly as transcribed.
        - Preserve repetition used for emphasis, disagreement, or correction, such as no, no, no.

        ALLOWED EDITS
        - Correct punctuation and capitalization.
        - Remove an isolated filler such as um, uh, or er.
        - Remove an obvious abandoned word fragment.
        - Collapse a simple accidental stutter such as the the.
        - Make a small grammatical repair only when the intended wording is unambiguous.

        Before responding, silently compare each cleanedText with its own source text. Correct any
        loss, import, duplication, changed name, number, date, amount, negation, or profanity, empty
        value, ellipsis substitution, or boundary completion.
        Reply with ONLY JSON in exactly this shape:
        {"segments":[{"index":1,"cleanedText":"Cleaned speech."}]}
        """

    private struct PromptSegment: Encodable {
        let index: Int
        let text: String
    }

    private struct PromptEnvelope: Encodable {
        let segments: [PromptSegment]
    }

    private struct ResponseEnvelope: Decodable {
        let segments: [CleanupGenerationItem]
    }

    private static func userPrompt(for segments: [MeetingTranscriptSegment]) throws -> String {
        let envelope = PromptEnvelope(
            segments: segments.enumerated().map { index, segment in
                PromptSegment(index: index + 1, text: segment.text)
            }
        )
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CloudMeetingCleanupError.invalidRequest
        }
        return json
    }

    private static func decodeAligned(
        _ response: String,
        source: [MeetingTranscriptSegment]
    ) throws -> [MeetingCleanedSegment] {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            throw CloudMeetingCleanupError.malformedResponse
        }

        guard envelope.segments.count == source.count else {
            throw CloudMeetingCleanupError.wrongCount
        }
        return try zip(source, envelope.segments).enumerated().map { offset, pair in
            let (sourceSegment, generated) = pair
            guard generated.index == offset + 1 else {
                throw CloudMeetingCleanupError.invalidIndex
            }
            let text = generated.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CloudMeetingCleanupError.emptyText
            }
            guard !isEllipsisOnly(text) else {
                throw CloudMeetingCleanupError.placeholderText
            }
            return MeetingCleanedSegment(
                sourceSegmentID: sourceSegment.id,
                cleanedText: text
            )
        }
    }

    private static func isEllipsisOnly(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        if compact.allSatisfy({ $0 == "…" }) {
            return !compact.isEmpty
        }
        return compact.count >= 3 && compact.allSatisfy { $0 == "." }
    }

    private static func responseFormat(
        for preset: ProviderPreset,
        itemCount: Int
    ) -> CloudResponseFormat {
        switch preset {
        case .openRouter:
            return .strictCleanupSchema(itemCount: itemCount)
        case .deepSeek, .custom:
            return .jsonObject
        }
    }

    private func chunked(
        _ segments: [MeetingTranscriptSegment]
    ) -> [[MeetingTranscriptSegment]] {
        stride(from: 0, to: segments.count, by: MeetingCleanupContract.chunkSize).map { start in
            Array(segments[start..<min(start + MeetingCleanupContract.chunkSize, segments.count)])
        }
    }
}

enum CloudMeetingCleanupError: LocalizedError, Equatable {
    case invalidRequest
    case malformedResponse
    case wrongCount
    case invalidIndex
    case emptyText
    case placeholderText

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "OpenBridge could not prepare the cleanup request."
        case .malformedResponse:
            return "The cloud provider returned cleanup JSON OpenBridge could not read."
        case .wrongCount:
            return "The cloud provider returned the wrong number of cleanup results."
        case .invalidIndex:
            return "The cloud provider returned an invalid cleanup index."
        case .emptyText:
            return "The cloud provider returned an empty cleanup result."
        case .placeholderText:
            return "The cloud provider replaced transcript speech with an ellipsis placeholder."
        }
    }
}
