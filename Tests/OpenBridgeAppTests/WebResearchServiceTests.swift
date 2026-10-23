import Foundation
import Testing
@testable import OpenBridgeApp

// MARK: - Web Research Service Tests (#313 / WEB-02)
//
// Contract tests: request minimization (no request without authority),
// evidence normalization via the #312 validator, distinguishable outcomes,
// bounded work, stale-request rejection, and structural-only logging.

@Suite(.serialized) struct WebResearchServiceTests {

    // MARK: - Fixtures

    /// Configurable gate for tests.
    private struct TestGate: WebResearchGate {
        var settingsValue: ProviderSettings = ProviderSettings(cloudEnabled: true, consentGranted: true)
        var credential: Bool = true
        var reachable: Bool = true

        func settings() async -> ProviderSettings { settingsValue }
        func hasCredential() async -> Bool { credential }
        func networkReachable() async -> Bool { reachable }
    }

    private func makeService(
        gate: WebResearchGate = TestGate(),
        webProvider: (any ResearchWebProvider)? = nil,
        configuration: WebResearchService.Configuration = .default,
        logger: @escaping @Sendable (WebResearchLogEvent) -> Void = { _ in }
    ) -> WebResearchService {
        WebResearchService(
            webProvider: webProvider ?? FakeWebResearchProvider(),
            gate: gate,
            logger: logger,
            configuration: configuration
        )
    }

    private func authorizedQuestion(_ text: String = "What is Swift concurrency?", authority: Bool = true) -> AuthorizedWebQuestion {
        AuthorizedWebQuestion(requestID: UUID().uuidString, questionText: text, webAuthority: authority)
    }

    // MARK: - Authority Gate (request minimization)

    @Test func noRequestWithoutExplicitWebAuthority() async throws {
        let recording = CallRecordingWebProvider()
        let service = makeService(webProvider: recording)

        await #expect(throws: WebResearchServiceError.consentRequired) {
            _ = try await service.research(authorizedQuestion(authority: false))
        }
        #expect(await recording.callCount == 0,
                "No provider call may occur without explicit web authority")
    }

    @Test func authorizedQuestionReachesProvider() async throws {
        let recording = CallRecordingWebProvider()
        let service = makeService(webProvider: recording)

        let result = try await service.research(authorizedQuestion())
        #expect(!result.items.isEmpty)
        #expect(await recording.callCount == 1)
    }

    // MARK: - Gate Outcomes

    @Test func disabledCloudThrows() async throws {
        var gate = TestGate()
        gate.settingsValue = ProviderSettings(cloudEnabled: false, consentGranted: true)
        let service = makeService(gate: gate)
        await #expect(throws: WebResearchServiceError.disabled) {
            _ = try await service.research(authorizedQuestion())
        }
    }

    @Test func missingCredentialThrows() async throws {
        var gate = TestGate()
        gate.credential = false
        let service = makeService(gate: gate)
        await #expect(throws: WebResearchServiceError.noCredential) {
            _ = try await service.research(authorizedQuestion())
        }
    }

    @Test func offlineThrows() async throws {
        var gate = TestGate()
        gate.reachable = false
        let service = makeService(gate: gate)
        await #expect(throws: WebResearchServiceError.offline) {
            _ = try await service.research(authorizedQuestion())
        }
    }

    // MARK: - Evidence Normalization

    @Test func completedResultsAreNormalizedWebEvidence() async throws {
        let service = makeService()
        let result = try await service.research(authorizedQuestion())

        for item in result.items {
            #expect(item.url.scheme == "https", "Every factual result must expose a validated https URL")
            #expect(!item.title.isEmpty)
            #expect(!item.passage.isEmpty)
            #expect(item.score.map { $0 >= 0 && $0 <= 1 } == true)
            #expect(!item.provider.isEmpty)
        }
    }

    @Test func nonHTTPSResultsAreDroppedAsPartial() async throws {
        let service = makeService(webProvider: MixedValidityWebProvider())
        let result = try await service.research(authorizedQuestion())

        guard case .partial(let items, let dropped) = result else {
            Issue.record("Expected partial result with invalid URLs; got \(result)")
            return
        }
        #expect(!items.isEmpty)
        #expect(dropped >= 1)
        #expect(items.allSatisfy { $0.url.scheme == "https" })
    }

    @Test func allInvalidThrowsMalformedSource() async throws {
        let service = makeService(webProvider: AllInvalidWebProvider())
        do {
            _ = try await service.research(authorizedQuestion())
            Issue.record("Expected malformedSource error")
        } catch let error as WebResearchServiceError {
            guard case .malformedSource = error else {
                Issue.record("Expected malformedSource, got \(error)")
                return
            }
        }
    }

    @Test func noSourcesReturnsNoSources() async throws {
        let service = makeService(webProvider: EmptyWebProvider())
        let result = try await service.research(authorizedQuestion())
        #expect(result == .noSources)
    }

    // MARK: - Timeout / Cancellation

    @Test func slowProviderTimesOut() async throws {
        let service = makeService(
            webProvider: SlowWebProvider(delay: 2.0),
            configuration: .init(timeout: 0.2)
        )
        await #expect(throws: WebResearchServiceError.timedOut) {
            _ = try await service.research(authorizedQuestion())
        }
    }

    @Test func cancelledTaskPropagatesError() async throws {
        let service = makeService(webProvider: SlowWebProvider(delay: 2.0))

        let task = Task {
            try await service.research(authorizedQuestion())
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to surface as an error")
        } catch {
            // Cancellation surfaced as an error — expected.
        }
    }

    // MARK: - Stale Request Rejection

    @Test func supersededRequestIsRejectedAsStale() async throws {
        let gateProvider = GateWebProvider()
        let service = makeService(webProvider: gateProvider)

        async let first = service.research(AuthorizedWebQuestion(requestID: "first", questionText: "q1", webAuthority: true))
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = try await service.research(AuthorizedWebQuestion(requestID: "second", questionText: "q2", webAuthority: true))

        await gateProvider.release()
        do {
            _ = try await first
            Issue.record("Superseded request should be rejected as stale")
        } catch let error as WebResearchServiceError {
            #expect(error == .staleRequest, "Expected stale failure, got \(error)")
        }
    }

    // MARK: - Bounded Work

    @Test func responseSizeLimitEnforced() async throws {
        let service = makeService(
            webProvider: HugeWebProvider(),
            configuration: .init(maxResponseBytes: 128)
        )
        do {
            _ = try await service.research(authorizedQuestion())
            Issue.record("Expected providerFailed error")
        } catch let error as WebResearchServiceError {
            guard case .providerFailed = error else {
                Issue.record("Expected providerFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func resultCountBounded() async throws {
        let service = makeService(configuration: .init(maxResults: 2))
        let result = try await service.research(authorizedQuestion())
        #expect(result.items.count <= 2)
    }

    // MARK: - Structural Logging

    @Test func logsAreStructuralOnly() async throws {
        let questionText = "What is the meaning of 42 and all secrets?"
        let box = LogBox()
        let service = makeService(logger: { event in
            box.record(event)
        })

        _ = try await service.research(AuthorizedWebQuestion(
            requestID: "log-test",
            questionText: questionText,
            webAuthority: true
        ))

        let events = box.events
        let event = try #require(events.first)
        #expect(event.questionCharacterCount == questionText.count)
        #expect(!"\(event)".contains(questionText),
                "Ordinary logs must never contain question content")
    }

    // MARK: - Web Labeling

    @Test func webEvidenceCarriesProviderAndTimestamp() async throws {
        let service = makeService()
        let result = try await service.research(authorizedQuestion())
        let item = try #require(result.items.first)
        #expect(!item.provider.isEmpty)
        #expect(item.retrievedAt <= Date())
    }

    // MARK: - Failure Isolation (by construction)

    @Test func serviceHoldsNoCaptureReferences() throws {
        // The init accepts only a provider, gate, logger, and config —
        // there is no way to hand it recording, transcription, store, or
        // export facilities. Compile-time guarantee.
        _ = makeService()
    }
}

// MARK: - Helpers / Test Providers

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WebResearchLogEvent] = []
    func record(_ event: WebResearchLogEvent) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(event)
    }
    var events: [WebResearchLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func goodResult(_ path: String, score: Double = 0.8) -> WebResearchResult {
    WebResearchResult(
        title: "Result \(path)",
        url: URL(string: "https://example.com/\(path)")!,
        passage: "Valid passage content.",
        score: score
    )
}

private func insecureResult(_ path: String) -> WebResearchResult {
    WebResearchResult(
        title: "Insecure \(path)",
        url: URL(string: "http://example.com/\(path)")!,
        passage: "Insecure passage.",
        score: 0.5
    )
}

private func makeResponse(_ request: WebResearchRequest, providerID: String, results: [WebResearchResult]) -> WebResearchResponse {
    WebResearchResponse(requestID: request.requestID, providerID: providerID, results: results)
}

private actor CallRecordingWebProvider: ResearchWebProvider {
    nonisolated let providerID = "recording-web"
    private(set) var callCount = 0

    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        callCount += 1
        return makeResponse(request, providerID: providerID, results: [goodResult("a")])
    }
}

private struct MixedValidityWebProvider: ResearchWebProvider {
    let providerID = "mixed-web"
    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        makeResponse(request, providerID: providerID, results: [
            goodResult("good"),
            insecureResult("bad"),
        ])
    }
}

private struct AllInvalidWebProvider: ResearchWebProvider {
    let providerID = "all-invalid-web"
    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        makeResponse(request, providerID: providerID, results: [insecureResult("only")])
    }
}

private struct EmptyWebProvider: ResearchWebProvider {
    let providerID = "empty-web"
    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        makeResponse(request, providerID: providerID, results: [])
    }
}

private actor GateWebProvider: ResearchWebProvider {
    nonisolated let providerID = "gate-web"
    private var released = false

    func release() {
        released = true
    }

    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        // Only the FIRST request is gated; later requests flow through so
        // they can supersede it.
        if request.requestID == "first" {
            while !released {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return makeResponse(request, providerID: providerID, results: [goodResult("gated")])
    }
}

private struct SlowWebProvider: ResearchWebProvider {
    let providerID = "slow-web"
    let delay: TimeInterval
    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return makeResponse(request, providerID: providerID, results: [goodResult("late")])
    }
}

private struct HugeWebProvider: ResearchWebProvider {
    let providerID = "huge-web"
    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        let big = WebResearchResult(
            title: "Big",
            url: URL(string: "https://example.com/big")!,
            passage: String(repeating: "x", count: 4096),
            score: 0.5
        )
        return makeResponse(request, providerID: providerID, results: [big, big])
    }
}