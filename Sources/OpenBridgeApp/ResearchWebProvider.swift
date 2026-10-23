import Foundation

// MARK: - Web Research Provider Contract (#312)
//
// Provider-neutral contract for opt-in web research evidence. ADR-002
// records the provider decision. This module defines the normalized types
// every adapter must produce; BraveLLMContextProvider owns the live transport.

// MARK: - Errors

enum WebResearchError: Equatable, LocalizedError, Sendable {
    /// The question did not authorize cloud web research.
    case consentRequired
    /// No API credential is configured.
    case missingCredential
    /// The provider rate-limited the request.
    case authenticationFailed
    case offline
    case invalidQuery
    case rateLimited
    /// The request timed out.
    case timeout
    /// The provider returned an unusable response.
    case invalidResponse(String)
    /// Web research is unavailable for any other reason; callers degrade
    /// to "web evidence unavailable" rather than surfacing an error.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "Web research requires explicit consent for this question."
        case .missingCredential:
            return "No web research credential is configured."
        case .authenticationFailed: return "Brave rejected the API key or its access to LLM Context."
        case .offline: return "No network connection is available."
        case .invalidQuery: return "Use a search query of 1–600 characters and at most 75 words."
        case .rateLimited:
            return "The web research provider rate-limited the request."
        case .timeout:
            return "The web research request timed out."
        case .invalidResponse(let detail):
            return "The web research provider returned an invalid response: \(detail)"
        case .unavailable(let detail):
            return "Web research is unavailable: \(detail)"
        }
    }
}

// MARK: - Request

/// A web research query. Carries the consent flag explicitly so adapters
/// can never be constructed without it.
struct WebResearchRequest: Equatable, Sendable {
    let requestID: String
    let questionText: String
    /// Maximum number of normalized results requested.
    let maxResults: Int
    /// Must be true or the provider throws `.consentRequired`.
    let allowsCloudWeb: Bool

    init(
        requestID: String = UUID().uuidString,
        questionText: String,
        maxResults: Int = 5,
        allowsCloudWeb: Bool
    ) {
        self.requestID = requestID
        self.questionText = questionText
        self.maxResults = max(1, min(maxResults, 10))
        self.allowsCloudWeb = allowsCloudWeb
    }
}

// MARK: - Result

/// One normalized web research result. This is the only shape callers see,
/// regardless of which adapter (Tavily, Brave, Serper) produced it.
struct WebResearchResult: Equatable, Sendable {
    let title: String
    let url: URL
    /// Answer-grade passage used as `passage` evidence.
    let passage: String
    /// Normalized relevance score, 0.0–1.0, only when supplied by the provider.
    let score: Double?
    /// The rank position the provider assigned (1-based), if known.
    let providerRank: Int?
    /// Optional page-reported date; never the time this app retrieved the result.
    let pageDate: String?

    init(title: String, url: URL, passage: String, score: Double? = nil, providerRank: Int? = nil, pageDate: String? = nil) {
        self.title = title
        self.url = url
        self.passage = passage
        self.score = score
        self.providerRank = providerRank
        self.pageDate = pageDate
    }
}

// MARK: - Response

/// A normalized provider response plus metadata for logging/diagnostics.
struct WebResearchResponse: Equatable, Sendable {
    static let schemaVersion = 1

    let requestID: String
    let providerID: String
    let results: [WebResearchResult]

    init(requestID: String, providerID: String, results: [WebResearchResult]) {
        self.requestID = requestID
        self.providerID = providerID
        self.results = results
    }
}

// MARK: - Protocol

/// The web research provider contract (ADR-002). Implementations must be
/// `Sendable` and must enforce consent before any network activity.
protocol ResearchWebProvider: Sendable {
    /// Stable identifier used in logging and evidence provenance.
    var providerID: String { get }

    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse
}

// MARK: - Response Validator

/// Enforces ADR-002 normalization rules on raw adapter output:
/// https-only URLs, non-empty passages, clamped scores, deduplicated URLs.
enum WebResearchResponseValidator {

    /// Normalizes and validates a batch of raw results for a request.
    /// - Drops non-https URLs (never upgrades http).
    /// - Drops results with empty/whitespace passages or titles.
    /// - Clamps scores to [0, 1].
    /// - Collapses duplicate URLs, keeping the highest-scored instance.
    /// - Sorts by descending normalized score.
    static func normalize(
        _ rawResults: [WebResearchResult],
        requestID: String,
        providerID: String,
        maxResults: Int
    ) throws -> WebResearchResponse {
        var bestByURL: [URL: WebResearchResult] = [:]
        var order: [URL] = []

        for raw in rawResults {
            guard isSafeSourceURL(raw.url) else { continue }
            guard !raw.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !raw.passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let clampedScore = raw.score.flatMap { $0.isFinite ? min(max($0, 0.0), 1.0) : nil }
            let normalized = WebResearchResult(
                title: raw.title,
                url: raw.url,
                passage: raw.passage,
                score: clampedScore,
                providerRank: raw.providerRank,
                pageDate: raw.pageDate
            )

            if let existing = bestByURL[raw.url] {
                if (normalized.score ?? -1) > (existing.score ?? -1) {
                    bestByURL[raw.url] = normalized
                }
            } else {
                bestByURL[raw.url] = normalized
                order.append(raw.url)
            }
        }

        let sorted = order.enumerated().compactMap { index, url in bestByURL[url].map { (index, $0) } }
            .sorted { a, b in
                let sa = a.1.score ?? -1, sb = b.1.score ?? -1
                return sa == sb ? a.0 < b.0 : sa > sb
            }.map { $0.1 }
            .prefix(max(0, maxResults))

        return WebResearchResponse(
            requestID: requestID,
            providerID: providerID,
            results: Array(sorted)
        )
    }

    static func isSafeSourceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    /// Validates an already-normalized response for structural integrity.
    static func validate(_ response: WebResearchResponse) throws {
        guard !response.requestID.isEmpty else {
            throw WebResearchError.invalidResponse("Empty request ID.")
        }
        guard !response.providerID.isEmpty else {
            throw WebResearchError.invalidResponse("Empty provider ID.")
        }
        for result in response.results {
            guard isSafeSourceURL(result.url) else {
                throw WebResearchError.invalidResponse("Unsafe source URL.")
            }
            guard result.score.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true else {
                throw WebResearchError.invalidResponse("Score out of range.")
            }
            guard !result.passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WebResearchError.invalidResponse("Empty passage.")
            }
        }
        let urls = response.results.map(\.url)
        guard Set(urls.map(\.absoluteString)).count == urls.count else {
            throw WebResearchError.invalidResponse("Duplicate URLs in response.")
        }
    }
}