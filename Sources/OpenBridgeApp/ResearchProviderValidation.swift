import Foundation
import NaturalLanguage

// MARK: - Research Provider Response Validation (#296)
//
// Validates provider response shapes before returning them to callers.
// Catches schema drift, invalid confidence ranges, empty required fields,
// and citation integrity issues at the boundary.

enum ResearchProviderValidationError: Equatable, LocalizedError, Sendable {
    case confidenceOutOfRange(Double, String)
    case emptyAnswerText(String)
    case emptyCleanedText(String)
    case missingGroundedCitation
    case citationEvidenceIDNotFound(String)
    case citationQuoteNotFound(String)
    case citationDoesNotSubstantiateAnswer
    case schemaVersionMismatch(expected: Int, actual: Int)
    case requestIDMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .confidenceOutOfRange(let value, let context):
            return "Confidence \(value) is out of range [0.0, 1.0] for \(context)."
        case .emptyAnswerText(let context):
            return "Answer text must not be empty for \(context)."
        case .emptyCleanedText(let context):
            return "Cleaned text must not be empty for \(context)."
        case .missingGroundedCitation:
            return "A meeting-grounded answer must cite at least one supplied passage."
        case .citationEvidenceIDNotFound(let id):
            return "Citation references unknown evidence ID: \(id)."
        case .citationQuoteNotFound(let id):
            return "Citation quote does not occur in evidence ID: \(id)."
        case .citationDoesNotSubstantiateAnswer:
            return "Citation quotes do not substantiate the grounded answer."
        case .schemaVersionMismatch(let expected, let actual):
            return "Schema version mismatch: expected \(expected), got \(actual)."
        case .requestIDMismatch(let expected, let actual):
            return "Request ID mismatch: expected \(expected), got \(actual)."
        }
    }
}

/// Validates provider responses before they reach consumers.
enum ResearchProviderResponseValidator {

    // MARK: - Confidence Helper

    private static func validateConfidence(
        _ value: Double,
        context: String
    ) throws {
        guard value >= 0.0 && value <= 1.0 else {
            throw ResearchProviderValidationError.confidenceOutOfRange(value, context)
        }
    }

    // MARK: - Classification

    static func validate(
        response: ClassificationResponse,
        expectedRequestID: String
    ) throws {
        guard response.requestID == expectedRequestID else {
            throw ResearchProviderValidationError.requestIDMismatch(
                expected: expectedRequestID,
                actual: response.requestID
            )
        }
        try validateConfidence(response.confidence, context: "classification")
    }

    // MARK: - Grounded Answer

    static func validate(
        response: GroundedAnswerResponse,
        expectedRequestID: String,
        knownEvidenceIDs: Set<String>,
        evidenceTextByID: [String: String] = [:]
    ) throws {
        guard response.requestID == expectedRequestID else {
            throw ResearchProviderValidationError.requestIDMismatch(
                expected: expectedRequestID,
                actual: response.requestID
            )
        }
        try validateConfidence(response.confidence, context: "groundedAnswer")

        // Abstained responses may have empty text
        if !response.abstained && response.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ResearchProviderValidationError.emptyAnswerText("groundedAnswer")
        }
        if !response.abstained,
           !knownEvidenceIDs.isEmpty,
           response.citations.isEmpty {
            throw ResearchProviderValidationError.missingGroundedCitation
        }

        for citation in response.citations {
            guard knownEvidenceIDs.contains(citation.evidenceID) else {
                throw ResearchProviderValidationError.citationEvidenceIDNotFound(citation.evidenceID)
            }
            if let evidenceText = evidenceTextByID[citation.evidenceID] {
                let normalizedQuote = normalizeCitationText(citation.quotedFragment)
                let normalizedEvidence = normalizeCitationText(evidenceText)
                guard !normalizedQuote.isEmpty,
                      normalizedEvidence.contains(normalizedQuote) else {
                    throw ResearchProviderValidationError.citationQuoteNotFound(citation.evidenceID)
                }
            }
        }
        if !response.abstained, !evidenceTextByID.isEmpty {
            let claims = answerClaims(in: response.answerText)
            let everyClaimIsSubstantiated = !claims.isEmpty && claims.allSatisfy { claim in
                let normalizedClaim = normalizeCitationText(claim)
                guard !normalizedClaim.isEmpty else { return false }
                return response.citations.contains { citation in
                    guard let evidenceText = evidenceTextByID[citation.evidenceID] else {
                        return false
                    }
                    // Fail closed: every answer sentence must itself be an
                    // extract from the retrieval-owned passage identified by
                    // a separately verified exact citation. A short display
                    // quote may omit the rest of a long source sentence, but
                    // the answer cannot add any words absent from that source.
                    return self.evidenceText(evidenceText, supports: claim)
                }
            }
            guard everyClaimIsSubstantiated else {
                throw ResearchProviderValidationError.citationDoesNotSubstantiateAnswer
            }
        }
    }

    /// Retrieval snippets add local highlight punctuation that is removed
    /// before the cloud prompt. Normalize both sides so a genuinely exact
    /// quote still validates without trusting arbitrary model text.
    private static func normalizeCitationText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Canonical claim segmentation shared by validation and presentation.
    /// Newlines are explicit transcript boundaries. Within each line,
    /// Apple's sentence tokenizer distinguishes terminal punctuation from
    /// decimal points and dotted abbreviations such as 1.5, v1.2, and U.S.
    static func answerClaims(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).flatMap { rawLine -> [String] in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return [] }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = line
            var claims: [String] = []
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let claim = line[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !claim.isEmpty {
                    claims.append(claim)
                }
                return true
            }
            return claims.isEmpty ? [line] : claims
        }
    }

    /// Shared by validation and composition so the source IDs shown to the
    /// user are exactly the passages that substantiate the sentence. Sentence
    /// boundaries are retained; punctuation cannot join unrelated assertions.
    static func evidenceText(_ evidenceText: String, supports claim: String) -> Bool {
        let normalizedClaim = normalizeCitationText(claim)
        guard !normalizedClaim.isEmpty else { return false }
        // The production provider is instructed to copy a complete evidence
        // sentence. Requiring equality after display-only normalization keeps
        // a short substring ("Approved") from reversing a source assertion
        // ("The launch was not approved").
        return answerClaims(in: evidenceText).contains { evidenceClaim in
            normalizeCitationText(evidenceClaim) == normalizedClaim
        }
    }

    // MARK: - State Update

    static func validate(
        response: StateUpdateResponse,
        expectedRequestID: String
    ) throws {
        guard response.requestID == expectedRequestID else {
            throw ResearchProviderValidationError.requestIDMismatch(
                expected: expectedRequestID,
                actual: response.requestID
            )
        }
        for decision in response.decisions {
            try validateConfidence(decision.confidence, context: "decision")
            guard !decision.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResearchProviderValidationError.emptyCleanedText("decision summary")
            }
        }
        for action in response.actions {
            try validateConfidence(action.confidence, context: "action")
            guard !action.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResearchProviderValidationError.emptyCleanedText("action description")
            }
        }
        for openLoop in response.openLoops {
            try validateConfidence(openLoop.confidence, context: "openLoop")
            guard !openLoop.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResearchProviderValidationError.emptyCleanedText("open loop topic")
            }
        }
    }

    // MARK: - Raw JSON Validation

    /// Validates that a raw Data payload is parseable as JSON and optionally
    /// matches an expected schema version key. Used at the provider boundary
    /// before decoding into a typed response.
    static func validateRawJSON(
        _ data: Data,
        expectedSchemaVersion: Int? = nil
    ) throws {
        guard !data.isEmpty else {
            throw ResearchProviderError.invalidJSON("Response data is empty.")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ResearchProviderError.invalidJSON("Data is not valid JSON.")
        }

        if let expected = expectedSchemaVersion,
           let dict = json as? [String: Any],
           let actual = dict["schemaVersion"] as? Int {
            guard actual == expected else {
                throw ResearchProviderError.invalidJSON(
                    "Schema version \(actual) does not match expected \(expected)."
                )
            }
        }
    }
}
