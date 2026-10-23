import Foundation
import Testing
@testable import OpenBridgeApp

// MARK: - Web Research Provider Tests (#312)
//
// All tests use the fake provider — no production web requests exist in
// this target. The suite covers the normalized contract, validator
// normalization rules, consent enforcement, and failure modes.

@Suite(.serialized) struct ResearchWebProviderTests {

    // MARK: - Request Validation

    @Test func requestClampsMaxResultsToBounds() throws {
        let tooMany = WebResearchRequest(questionText: "q", maxResults: 50, allowsCloudWeb: true)
        #expect(tooMany.maxResults <= 10)

        let tooFew = WebResearchRequest(questionText: "q", maxResults: 0, allowsCloudWeb: true)
        #expect(tooFew.maxResults >= 1)
    }

    @Test func requestCarriesConsentFlagExplicitly() throws {
        let consent = WebResearchRequest(questionText: "q", allowsCloudWeb: true)
        let denied = WebResearchRequest(questionText: "q", allowsCloudWeb: false)
        #expect(consent.allowsCloudWeb == true)
        #expect(denied.allowsCloudWeb == false)
    }

    // MARK: - Fake Provider Behavior

    #if DEBUG
    @Test func fakeProviderEnforcesConsent() async throws {
        let provider = FakeWebResearchProvider()
        let denied = WebResearchRequest(questionText: "test query", allowsCloudWeb: false)

        await #expect(throws: WebResearchError.consentRequired) {
            _ = try await provider.search(denied)
        }
    }

    @Test func fakeProviderReturnsDeterministicResults() async throws {
        let provider = FakeWebResearchProvider()
        let request = WebResearchRequest(questionText: "launch benchmarks", allowsCloudWeb: true)

        let first = try await provider.search(request)
        let second = try await provider.search(request)

        #expect(first.results.count == 3)
        #expect(first == second, "Same query must yield identical results")
        #expect(first.providerID == "fake-web")
        #expect(first.requestID == request.requestID)
    }

    @Test func fakeProviderResultsAreHttpsAndSorted() async throws {
        let provider = FakeWebResearchProvider()
        let response = try await provider.search(
            WebResearchRequest(questionText: "privacy analysis", allowsCloudWeb: true)
        )

        for result in response.results {
            #expect(result.url.scheme == "https")
            #expect(!result.passage.isEmpty)
        }
        let scores = response.results.compactMap(\.score)
        #expect(scores == scores.sorted(by: >), "Results must be sorted by descending score")
    }

    @Test func fakeProviderRespectsMaxResults() async throws {
        let provider = FakeWebResearchProvider()
        let response = try await provider.search(
            WebResearchRequest(questionText: "anything", maxResults: 2, allowsCloudWeb: true)
        )
        #expect(response.results.count <= 2)
    }

    @Test func fakeProviderRecordsQueries() async throws {
        let recorder = FakeWebProviderRecorder()
        let provider = FakeWebResearchProvider(recorder: recorder)

        _ = try await provider.search(WebResearchRequest(questionText: "first query", allowsCloudWeb: true))
        _ = try await provider.search(WebResearchRequest(questionText: "second query", allowsCloudWeb: true))

        #expect(recorder.callCount == 2)
        #expect(recorder.allQueries == ["first query", "second query"])
    }

    @Test func fakeProviderInjectsFailure() async throws {
        let provider = FakeWebResearchProvider(
            configuration: .init(failure: .rateLimited)
        )
        await #expect(throws: WebResearchError.rateLimited) {
            _ = try await provider.search(WebResearchRequest(questionText: "q", allowsCloudWeb: true))
        }
    }

    @Test func fakeProviderInjectsLatency() async throws {
        let provider = FakeWebResearchProvider(configuration: .init(delay: 0.1))
        let start = Date()
        _ = try await provider.search(WebResearchRequest(questionText: "q", allowsCloudWeb: true))
        #expect(Date().timeIntervalSince(start) >= 0.09)
    }
    #endif

    // MARK: - Validator: Normalization Rules

    @Test func normalizeDropsNonHTTPSResults() throws {
        let raw = [
            WebResearchResult(
                title: "Secure", url: URL(string: "https://example.com/a")!,
                passage: "p", score: 0.5
            ),
            WebResearchResult(
                title: "Insecure", url: URL(string: "http://example.com/b")!,
                passage: "p", score: 0.9
            ),
        ]
        let response = try WebResearchResponseValidator.normalize(
            raw, requestID: "r", providerID: "p", maxResults: 5
        )
        #expect(response.results.count == 1)
        #expect(response.results[0].url.absoluteString == "https://example.com/a")
    }

    @Test func normalizeDropsEmptyPassagesAndTitles() throws {
        let raw = [
            WebResearchResult(
                title: "Valid", url: URL(string: "https://example.com/a")!,
                passage: "p", score: 0.5
            ),
            WebResearchResult(
                title: "No passage", url: URL(string: "https://example.com/b")!,
                passage: "   ", score: 0.9
            ),
            WebResearchResult(
                title: "", url: URL(string: "https://example.com/c")!,
                passage: "p", score: 0.9
            ),
        ]
        let response = try WebResearchResponseValidator.normalize(
            raw, requestID: "r", providerID: "p", maxResults: 5
        )
        #expect(response.results.count == 1)
    }

    @Test func normalizeClampsScoresToUnitRange() throws {
        let raw = [
            WebResearchResult(
                title: "Too high", url: URL(string: "https://example.com/a")!,
                passage: "p", score: 1.7
            ),
            WebResearchResult(
                title: "Too low", url: URL(string: "https://example.com/b")!,
                passage: "p", score: -0.4
            ),
        ]
        let response = try WebResearchResponseValidator.normalize(
            raw, requestID: "r", providerID: "p", maxResults: 5
        )
        for result in response.results {
            #expect(result.score.map { $0 >= 0 && $0 <= 1 } == true)
        }
    }

    @Test func normalizeCollapsesDuplicateURLsKeepingHighestScore() throws {
        let url = URL(string: "https://example.com/dup")!
        let raw = [
            WebResearchResult(title: "Low", url: url, passage: "p", score: 0.4),
            WebResearchResult(title: "High", url: url, passage: "p", score: 0.8),
        ]
        let response = try WebResearchResponseValidator.normalize(
            raw, requestID: "r", providerID: "p", maxResults: 5
        )
        #expect(response.results.count == 1)
        #expect(response.results[0].score == 0.8)
    }

    @Test func normalizeSortsByDescendingScore() throws {
        let raw = [
            WebResearchResult(title: "Mid", url: URL(string: "https://example.com/m")!, passage: "p", score: 0.5),
            WebResearchResult(title: "High", url: URL(string: "https://example.com/h")!, passage: "p", score: 0.9),
            WebResearchResult(title: "Low", url: URL(string: "https://example.com/l")!, passage: "p", score: 0.1),
        ]
        let response = try WebResearchResponseValidator.normalize(
            raw, requestID: "r", providerID: "p", maxResults: 5
        )
        #expect(response.results.map(\.score) == [0.9, 0.5, 0.1])
    }

    @Test func normalizeRespectsMaxResultsCap() throws {
        let raw = (0..<8).map { index in
            WebResearchResult(
                title: "T\(index)",
                url: URL(string: "https://example.com/\(index)")!,
                passage: "p",
                score: 0.5
            )
        }
        let response = try WebResearchResponseValidator.normalize(
            raw, requestID: "r", providerID: "p", maxResults: 3
        )
        #expect(response.results.count == 3)
    }

    // MARK: - Validator: Structural Validation

    @Test func validateAcceptsCleanResponse() throws {
        let response = WebResearchResponse(
            requestID: "r",
            providerID: "p",
            results: [
                WebResearchResult(
                    title: "T", url: URL(string: "https://example.com/a")!,
                    passage: "p", score: 0.5
                )
            ]
        )
        try WebResearchResponseValidator.validate(response)
    }

    @Test func validateRejectsEmptyRequestID() throws {
        #expect(throws: WebResearchError.self) {
            try WebResearchResponseValidator.validate(
                WebResearchResponse(requestID: "", providerID: "p", results: [])
            )
        }
    }

    @Test func validateRejectsEmptyProviderID() throws {
        #expect(throws: WebResearchError.self) {
            try WebResearchResponseValidator.validate(
                WebResearchResponse(requestID: "r", providerID: "", results: [])
            )
        }
    }

    @Test func validateRejectsOutOfRangeScore() throws {
        #expect(throws: WebResearchError.self) {
            try WebResearchResponseValidator.validate(
                WebResearchResponse(
                    requestID: "r", providerID: "p",
                    results: [
                        WebResearchResult(
                            title: "T", url: URL(string: "https://example.com/a")!,
                            passage: "p", score: 1.5
                        )
                    ]
                )
            )
        }
    }

    @Test func validateRejectsDuplicateURLs() throws {
        let url = URL(string: "https://example.com/a")!
        #expect(throws: WebResearchError.self) {
            try WebResearchResponseValidator.validate(
                WebResearchResponse(
                    requestID: "r", providerID: "p",
                    results: [
                        WebResearchResult(title: "A", url: url, passage: "p", score: 0.5),
                        WebResearchResult(title: "B", url: url, passage: "p2", score: 0.6),
                    ]
                )
            )
        }
    }

    @Test func validateRejectsEmptyPassage() throws {
        #expect(throws: WebResearchError.self) {
            try WebResearchResponseValidator.validate(
                WebResearchResponse(
                    requestID: "r", providerID: "p",
                    results: [
                        WebResearchResult(
                            title: "T", url: URL(string: "https://example.com/a")!,
                            passage: "  ", score: 0.5
                        )
                    ]
                )
            )
        }
    }

    // MARK: - Error Descriptions

    @Test func webResearchErrorsHaveDescriptions() throws {
        let errors: [WebResearchError] = [
            .consentRequired, .missingCredential, .rateLimited, .timeout,
            .invalidResponse("detail"), .unavailable("reason"),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }
}