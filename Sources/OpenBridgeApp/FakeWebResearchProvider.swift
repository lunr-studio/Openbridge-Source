import Foundation

// MARK: - Fake Web Research Provider (#312)
//
// Deterministic, local-only web research provider for tests. NEVER makes
// network requests. Returns synthetic results derived from the query text
// so tests can assert exact outputs.

#if DEBUG

/// Configuration for the fake web provider's failure injection and timing.
struct FakeWebProviderConfiguration: Equatable, Sendable {
    /// Artificial delay before responding (seconds).
    var delay: TimeInterval = 0
    /// If non-nil, search throws this error.
    var failure: WebResearchError?
    /// If true, raw (un-normalized) results are returned to exercise the
    /// validator in tests.
    var returnUnnormalizedResults: Bool = false

    static let defaultFast = FakeWebProviderConfiguration()
}

/// Records fake web provider calls for test assertions.
final class FakeWebProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    func record(query: String) {
        lock.lock()
        defer { lock.unlock() }
        queries.append(query)
    }

    var allQueries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queries.count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        queries.removeAll()
    }
}

/// Deterministic fake web research provider.
///
/// Results are keyed off the query: each query deterministically maps to
/// synthetic URLs so the same query always yields the same results.
struct FakeWebResearchProvider: ResearchWebProvider {
    let providerID = "fake-web"

    let configuration: FakeWebProviderConfiguration
    let recorder: FakeWebProviderRecorder?

    init(
        configuration: FakeWebProviderConfiguration = .defaultFast,
        recorder: FakeWebProviderRecorder? = nil
    ) {
        self.configuration = configuration
        self.recorder = recorder
    }

    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        recorder?.record(query: request.questionText)

        // Consent is enforced before anything else, mirroring the contract
        // every real adapter must honor.
        guard request.allowsCloudWeb else {
            throw WebResearchError.consentRequired
        }

        try Task.checkCancellation()
        if configuration.delay > 0 {
            try await Task.sleep(for: .seconds(configuration.delay))
        }
        if let failure = configuration.failure {
            throw failure
        }

        // Deterministic slug from the query for stable synthetic URLs.
        let slug = request.questionText
            .lowercased()
            .map { character in
                if character.isLetter || character.isNumber { return String(character) }
                return "-"
            }
            .joined()
            .replacingOccurrences(of: "--", with: "-")

        var rawResults: [WebResearchResult] = []
        for index in 0..<3 {
            guard let url = URL(string: "https://example.com/\(slug)-\(index)") else { continue }
            rawResults.append(WebResearchResult(
                title: "Result \(index + 1) for \(request.questionText)",
                url: url,
                passage: "Synthetic passage \(index + 1) addressing \(request.questionText) with citation-grade content.",
                score: 0.9 - Double(index) * 0.1,
                providerRank: index + 1
            ))
        }

        if configuration.returnUnnormalizedResults {
            return WebResearchResponse(
                requestID: request.requestID,
                providerID: providerID,
                results: rawResults
            )
        }

        return try WebResearchResponseValidator.normalize(
            rawResults,
            requestID: request.requestID,
            providerID: providerID,
            maxResults: request.maxResults
        )
    }
}

#endif