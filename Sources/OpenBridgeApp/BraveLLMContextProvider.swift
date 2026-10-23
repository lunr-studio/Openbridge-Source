import Foundation

/// One explicit approved query, one bounded request. No page crawling, query
/// expansion, retries, transcript access, cookies or persistent HTTP cache.
struct BraveLLMContextProvider: ResearchWebProvider {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Credential = @Sendable () async throws -> String
    let providerID = "brave-llm-context"
    static let endpoint = URL(string: "https://api.search.brave.com/res/v1/llm/context")!
    static let maximumResponseBytes = 512 * 1_024
    private let credential: Credential
    private let transport: Transport

    init(credential: @escaping Credential, transport: @escaping Transport = Self.send) {
        self.credential = credential; self.transport = transport
    }

    static func validQuery(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 600
            && text.split(whereSeparator: \.isWhitespace).count <= 75
    }

    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse {
        guard request.allowsCloudWeb else { throw WebResearchError.consentRequired }
        guard Self.validQuery(request.questionText) else { throw WebResearchError.invalidQuery }
        try Task.checkCancellation()
        let key = try await credential()
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw WebResearchError.missingCredential }
        var outgoing = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        outgoing.httpMethod = "POST"
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        outgoing.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        outgoing.httpBody = try JSONEncoder().encode(Query(q: request.questionText, count: request.maxResults,
            maximum_number_of_urls: request.maxResults))
        let data: Data, response: HTTPURLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport(outgoing)
            try Task.checkCancellation()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw WebResearchError.timeout
            case .notConnectedToInternet, .networkConnectionLost: throw WebResearchError.offline
            default: throw WebResearchError.unavailable("Brave could not be reached.")
            }
        }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw WebResearchError.authenticationFailed
        case 429: throw WebResearchError.rateLimited
        case 408, 504: throw WebResearchError.timeout
        default: throw WebResearchError.unavailable("Brave returned HTTP \(response.statusCode).")
        }
        guard data.count <= Self.maximumResponseBytes else { throw WebResearchError.invalidResponse("Response too large.") }
        guard let payload = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw WebResearchError.invalidResponse("Unrecognized Brave response.")
        }
        let results = payload.grounding.generic.enumerated().compactMap { rank, item -> WebResearchResult? in
            guard let url = URL(string: item.url), let title = item.title, let snippets = item.snippets else { return nil }
            return .init(title: String(title.prefix(500)), url: url,
                passage: String(snippets.joined(separator: "\n\n").prefix(4_000)), providerRank: rank + 1,
                pageDate: payload.sources[item.url]?.pageDate)
        }
        // Keep validation in the service so it can disclose dropped sources.
        return .init(requestID: request.requestID, providerID: providerID, results: results)
    }

    private struct Query: Encodable {
        let q: String
        let count: Int
        let maximum_number_of_urls: Int
        let maximum_number_of_tokens = 4_096
        let maximum_number_of_tokens_per_url = 1_024
        let maximum_number_of_snippets = 20
        let maximum_number_of_snippets_per_url = 4
        let context_threshold_mode = "balanced"
        let safesearch = "moderate"
        let enable_local = false
    }
    private struct Envelope: Decodable {
        struct Grounding: Decodable {
            struct Item: Decodable { let url: String; let title: String?; let snippets: [String]? }
            let generic: [Item]
        }
        let grounding: Grounding
        let sources: [String: Source]

        private enum CodingKeys: String, CodingKey { case grounding, sources }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            grounding = try container.decode(Grounding.self, forKey: .grounding)
            // Optional metadata must not turn usable excerpts into a failed search.
            sources = (try? container.decode([String: Source].self, forKey: .sources)) ?? [:]
        }

        struct Source: Decodable {
            let pageDate: String?
            private enum CodingKeys: String, CodingKey { case age }
            init(from decoder: any Decoder) throws {
                let container = try? decoder.container(keyedBy: CodingKeys.self)
                let age = try? container?.decode([String].self, forKey: .age)
                // Brave's age[1] is a page-reported publication OR modification date.
                // Never substitute relative age, index-fetch time or our retrieval time.
                pageDate = age.flatMap { $0.count > 1 ? validatedPageDate($0[1]) : nil }
            }
        }
    }

    private static func validatedPageDate(_ value: String) -> String? {
        guard value.utf8.count == 10,
              value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return value
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
        guard let response = response as? HTTPURLResponse else { throw WebResearchError.invalidResponse("Missing HTTP response.") }
        // Never read an error body: providers may echo credentials or query text.
        guard response.statusCode == 200 else { return (Data(), response) }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw WebResearchError.invalidResponse("Response too large.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw WebResearchError.invalidResponse("Response too large.") }
            data.append(byte)
        }
        return (data, response)
    }

    /// Do not forward a subscription token, even to a same-origin redirect.
    final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
