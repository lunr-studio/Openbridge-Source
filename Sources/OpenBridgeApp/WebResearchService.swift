import Foundation
import OpenBridgeUI

// MARK: - Web Research Service (#313 / WEB-02)
//
// Explicit cited web research as a provider-neutral, cancellable service
// returning normalized evidence to the Research Observatory. Builds ON the
// #312 contract (ResearchWebProvider + WebResearchResponseValidator).
//
// Guarantees: no request without explicit per-question web authority;
// audio can never be sent (input type has no audio); only the #312 payload
// leaves; validated https URLs via the #312 validator; dedicated web
// evidence type (cannot masquerade as memory/synthesis); distinguishable
// disabled/no-key/offline/timeout/cancelled/malformed/provider outcomes;
// bounded work (timeout, concurrency, results, response bytes); superseded
// requests rejected as stale; structural-only logs; no references to
// recording/transcription/export facilities.

// MARK: - Gate

/// Environment gate the service consults before any external work.
protocol WebResearchGate: Sendable {
    func settings() async -> ProviderSettings
    func hasCredential() async -> Bool
    func networkReachable() async -> Bool
}

/// Deny-by-default gate.
struct DenyAllWebResearchGate: WebResearchGate {
    func settings() async -> ProviderSettings { ProviderSettings() }
    func hasCredential() async -> Bool { false }
    func networkReachable() async -> Bool { true }
}

// MARK: - Errors

enum WebResearchServiceError: LocalizedError, Equatable, Sendable {
    case consentRequired
    case disabled
    case noCredential
    case offline
    case timedOut
    case malformedSource(String)
    case providerFailed(String)
    case staleRequest

    var errorDescription: String? {
        switch self {
        case .consentRequired: return "Web research requires an explicit authorized question."
        case .disabled: return "Cloud web research is disabled."
        case .noCredential: return "No web research credential is configured."
        case .offline: return "No network connection is available."
        case .timedOut: return "Web research timed out."
        case .malformedSource(let detail): return "A source failed validation: \(detail)"
        case .providerFailed(let detail): return "Web research failed: \(detail)"
        case .staleRequest: return "A newer request superseded this one."
        }
    }
}

// MARK: - Input / Evidence

/// The ONLY input. No audio, no transcript payload — request minimization
/// by type.
struct AuthorizedWebQuestion: Sendable {
    let requestID: String
    let questionText: String
    let webAuthority: Bool
    let allowedDomains: [String]

    init(requestID: String = UUID().uuidString, questionText: String, webAuthority: Bool, allowedDomains: [String] = []) {
        self.requestID = requestID
        self.questionText = questionText
        self.webAuthority = webAuthority
        self.allowedDomains = allowedDomains
    }
}

/// Normalized web evidence row. Dedicated type — cannot be presented as
/// meeting memory or model synthesis.
struct WebEvidenceItem: Codable, Equatable, Sendable {
    let title: String
    let url: URL
    let passage: String
    let provider: String
    let retrievedAt: Date
    let score: Double?
    /// Provider-reported page date (publication or modification), not retrieval time.
    var pageDate: String? = nil
}

enum WebResearchServiceResult: Equatable, Sendable {
    case completed(items: [WebEvidenceItem])
    case partial(items: [WebEvidenceItem], droppedMalformed: Int)
    case noSources

    var items: [WebEvidenceItem] {
        switch self {
        case .completed(let items), .partial(let items, _): return items
        case .noSources: return []
        }
    }
}

// MARK: - Logging

enum WebResearchOutcomeKind: String, Equatable, Sendable {
    case success, partialResults, noSources, disabled, consentRequired
    case noCredential, offline, timedOut, cancelled, malformedSource
    case providerFailed, staleRequest
}

/// Structural-only log event: lengths and identifiers, never content.
struct WebResearchLogEvent: Equatable, Sendable {
    let outcome: WebResearchOutcomeKind
    let requestID: String
    let providerID: String
    let durationMS: Int
    let questionCharacterCount: Int
    let resultCount: Int
    let droppedMalformedCount: Int
}

// MARK: - Service

actor WebResearchService {
    private let webProvider: any ResearchWebProvider
    private let gate: any WebResearchGate
    private let logger: @Sendable (WebResearchLogEvent) -> Void
    private let configuration: Configuration

    private var activeRequestCount = 0
    private var latestRequestID: String?

    struct Configuration: Sendable {
        var timeout: TimeInterval = 20
        var maxConcurrentRequests = 2
        var maxResults = 5
        var maxResponseBytes = 512 * 1024
        static let `default` = Configuration()
    }

    init(
        webProvider: any ResearchWebProvider,
        gate: (any WebResearchGate)? = nil,
        logger: @escaping @Sendable (WebResearchLogEvent) -> Void = { _ in },
        configuration: Configuration = .default
    ) {
        self.webProvider = webProvider
        self.gate = gate ?? DenyAllWebResearchGate()
        self.logger = logger
        self.configuration = configuration
    }

    func research(_ question: AuthorizedWebQuestion) async throws -> WebResearchServiceResult {
        let started = Date()

        // Gate 1: explicit per-question web authority.
        guard question.webAuthority else {
            log(.consentRequired, question, started, [], 0)
            throw WebResearchServiceError.consentRequired
        }
        guard question.allowedDomains.count <= 5, question.allowedDomains.allSatisfy(WebSearchSourcePolicy.validDomain) else {
            throw WebResearchServiceError.providerFailed("Invalid website selection. Review your query.")
        }
        // Gate 2: cloud enabled in settings.
        guard await gate.settings().cloudEnabled else {
            log(.disabled, question, started, [], 0)
            throw WebResearchServiceError.disabled
        }
        // Gate 3: credential present.
        guard await gate.hasCredential() else {
            log(.noCredential, question, started, [], 0)
            throw WebResearchServiceError.noCredential
        }
        // Gate 4: network reachable.
        guard await gate.networkReachable() else {
            log(.offline, question, started, [], 0)
            throw WebResearchServiceError.offline
        }
        // Gate 5: concurrency bound.
        guard activeRequestCount < configuration.maxConcurrentRequests else {
            log(.providerFailed, question, started, [], 0)
            throw WebResearchServiceError.providerFailed("busy")
        }

        latestRequestID = question.requestID
        activeRequestCount += 1
        defer { activeRequestCount -= 1 }

        let request = WebResearchRequest(
            requestID: question.requestID,
            questionText: question.questionText,
            maxResults: configuration.maxResults,
            allowsCloudWeb: true
        )

        let rawResponse: WebResearchResponse
        do {
            rawResponse = try await withTimeout(configuration.timeout) {
                try await self.webProvider.search(request)
            }
        } catch let error as WebResearchError {
            let mapped = Self.map(error)
            log(Self.outcome(for: mapped), question, started, [], 0)
            throw mapped
        } catch let error as WebResearchServiceError {
            // Timeout (and any pass-through service error) surfaces directly.
            log(Self.outcome(for: error), question, started, [], 0)
            throw error
        } catch is CancellationError {
            log(.cancelled, question, started, [], 0)
            throw CancellationError()
        } catch {
            log(.providerFailed, question, started, [], 0)
            throw WebResearchServiceError.providerFailed("The provider could not complete the request.")
        }

        try Task.checkCancellation()
        guard rawResponse.requestID == question.requestID, rawResponse.providerID == webProvider.providerID else {
            throw WebResearchServiceError.malformedSource("Response identity mismatch.")
        }

        // Stale check after the provider call.
        guard latestRequestID == question.requestID else {
            log(.staleRequest, question, started, [], 0)
            throw WebResearchServiceError.staleRequest
        }

        // Response-size bound.
        let payloadSize = rawResponse.results.reduce(0) {
            $0 + $1.passage.utf8.count + $1.title.utf8.count + $1.url.absoluteString.utf8.count
        }
        guard payloadSize <= configuration.maxResponseBytes else {
            log(.providerFailed, question, started, [], rawResponse.results.count)
            throw WebResearchServiceError.providerFailed("response too large")
        }

        // Filter before the result cap so unrelated sources cannot crowd out
        // selected domains. Query operators alone are not a local boundary.
        let selected = rawResponse.results.filter { WebSearchSourcePolicy.allows($0.url, domains: question.allowedDomains) }
        // Normalize through the #312 validator.
        let normalized = try WebResearchResponseValidator.normalize(
            selected,
            requestID: rawResponse.requestID,
            providerID: rawResponse.providerID,
            maxResults: configuration.maxResults
        )
        try WebResearchResponseValidator.validate(normalized)

        let dropped = selected.count - normalized.results.count
        let items = normalized.results.map { result in
            WebEvidenceItem(
                title: result.title,
                url: result.url,
                passage: result.passage,
                provider: normalized.providerID,
                retrievedAt: Date(),
                score: result.score,
                pageDate: result.pageDate
            )
        }

        if items.isEmpty && dropped > 0 {
            log(.malformedSource, question, started, [], dropped)
            throw WebResearchServiceError.malformedSource("all sources failed validation")
        }
        if items.isEmpty {
            log(.noSources, question, started, [], 0)
            return .noSources
        }

        let outcome: WebResearchOutcomeKind = dropped > 0 ? .partialResults : .success
        log(outcome, question, started, items, dropped)
        return dropped > 0
            ? .partial(items: items, droppedMalformed: dropped)
            : .completed(items: items)
    }

    /// Marks in-flight work superseded (the rail's cancel action).
    func cancelCurrentWork() {
        latestRequestID = nil
    }

    // MARK: - Helpers

    private static func map(_ error: WebResearchError) -> WebResearchServiceError {
        switch error {
        case .consentRequired: return .consentRequired
        case .missingCredential: return .noCredential
        case .authenticationFailed: return .providerFailed("Brave rejected the key or LLM Context access. Review your Brave plan and key.")
        case .offline: return .offline
        case .invalidQuery: return .providerFailed("Use a query of 1–600 characters and at most 75 words.")
        case .rateLimited: return .providerFailed("rate limited")
        case .timeout: return .timedOut
        case .invalidResponse(let detail): return .malformedSource(detail)
        case .unavailable(let detail): return .providerFailed(detail)
        }
    }

    private static func outcome(for error: WebResearchServiceError) -> WebResearchOutcomeKind {
        switch error {
        case .consentRequired: return .consentRequired
        case .disabled: return .disabled
        case .noCredential: return .noCredential
        case .offline: return .offline
        case .timedOut: return .timedOut
        case .malformedSource: return .malformedSource
        case .providerFailed: return .providerFailed
        case .staleRequest: return .staleRequest
        }
    }

    private func log(
        _ outcome: WebResearchOutcomeKind,
        _ question: AuthorizedWebQuestion,
        _ started: Date,
        _ items: [WebEvidenceItem],
        _ dropped: Int
    ) {
        logger(WebResearchLogEvent(
            outcome: outcome,
            requestID: question.requestID,
            providerID: webProvider.providerID,
            durationMS: Int(Date().timeIntervalSince(started) * 1000),
            questionCharacterCount: question.questionText.count,
            resultCount: items.count,
            droppedMalformedCount: dropped
        ))
    }

    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WebResearchServiceError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WebResearchServiceError.providerFailed("no result")
            }
            group.cancelAll()
            return result
        }
    }
}
