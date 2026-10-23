import Foundation

struct CloudChatMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// Provider-neutral request for machine-readable output. The transport maps
/// the strict cleanup schema to OpenRouter's `json_schema` form. Direct
/// DeepSeek and custom OpenAI-compatible endpoints use `json_object` and are
/// accepted only after the synthetic cleanup capability test succeeds.
enum CloudResponseFormat: Equatable, Sendable {
    case jsonObject
    case strictCleanupSchema(itemCount: Int)
}

/// Optional provider-neutral reasoning control. Cleanup is a deterministic
/// text-rewrite task, so OpenRouter cleanup explicitly disables the model's
/// default reasoning budget. Research requests leave this nil and retain the
/// selected model's normal behavior.
enum CloudReasoningMode: Equatable, Sendable {
    case disabled
}

struct CloudChatCompletionRequest: Equatable, Sendable {
    let messages: [CloudChatMessage]
    let maxTokens: Int
    let temperature: Double
    let responseFormat: CloudResponseFormat?
    let reasoning: CloudReasoningMode?

    init(
        messages: [CloudChatMessage],
        maxTokens: Int,
        temperature: Double,
        responseFormat: CloudResponseFormat? = nil,
        reasoning: CloudReasoningMode? = nil
    ) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.reasoning = reasoning
    }
}

enum CloudModelClientError: LocalizedError, Equatable, Sendable {
    case authenticationFailed
    case creditUnavailable
    case rateLimited
    case offline
    case timeout
    case cancelled
    case malformedResponse
    case responseTooLarge
    case providerFailure(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "The cloud provider rejected the API key."
        case .creditUnavailable:
            return "The cloud provider reports that credit or billing is unavailable."
        case .rateLimited:
            return "The cloud provider rate-limited the request."
        case .offline:
            return "No network connection is available."
        case .timeout:
            return "The cloud request timed out."
        case .cancelled:
            return "The cloud request was cancelled."
        case .malformedResponse:
            return "The cloud provider returned a response OpenBridge could not read."
        case .responseTooLarge:
            return "The cloud provider response exceeded the safety limit."
        case .providerFailure(let statusCode):
            return "The cloud provider returned HTTP \(statusCode)."
        }
    }
}

/// Provider-neutral completion boundary. Implementations receive a one-call
/// authorization snapshot from the central gate; they never discover keys,
/// endpoints, models, or environment variables themselves.
protocol CloudModelClient: Sendable {
    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String
}

/// Release-compatible OpenAI chat-completions transport used by OpenRouter,
/// direct DeepSeek, and custom HTTPS-compatible providers.
struct OpenAICompatibleCloudModelClient: CloudModelClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let maximumResponseBytes = 2 * 1_024 * 1_024

    private let transport: Transport

    init(transport: @escaping Transport = Self.urlSessionTransport) {
        self.transport = transport
    }

    func complete(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) async throws -> String {
        let urlRequest = try Self.makeURLRequest(request, authorization: authorization)
        let timeout = try authorization.configuration.validated().timeout
        let (data, response) = try await perform(
            urlRequest,
            timeoutSeconds: timeout
        )

        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw CloudModelClientError.authenticationFailed
        case 402:
            throw CloudModelClientError.creditUnavailable
        case 408, 504:
            throw CloudModelClientError.timeout
        case 429:
            throw CloudModelClientError.rateLimited
        default:
            // Do not copy provider response bodies into errors or logs: a
            // provider may echo prompt/transcript text in its error payload.
            throw CloudModelClientError.providerFailure(statusCode: response.statusCode)
        }

        guard data.count <= Self.maximumResponseBytes else {
            throw CloudModelClientError.responseTooLarge
        }
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data),
              let content = envelope.choices.first?.message.content,
              !content.isEmpty else {
            throw CloudModelClientError.malformedResponse
        }
        return content
    }

    static func makeURLRequest(
        _ request: CloudChatCompletionRequest,
        authorization: AuthorizedCloudRequest
    ) throws -> URLRequest {
        let configuration = try authorization.configuration.validated()
        var urlRequest = URLRequest(url: configuration.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(authorization.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(RequestEnvelope(
            model: configuration.model,
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            stream: false,
            responseFormat: request.responseFormat,
            reasoning: request.reasoning,
            preset: configuration.preset
        ))
        return urlRequest
    }

    private func perform(
        _ request: URLRequest,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            // A structured task group waits for every child before its scope
            // exits, even after cancellation. That breaks a wall-clock limit
            // when a custom transport ignores cancellation. Race two
            // independently owned tasks through a one-shot continuation:
            // the caller resumes immediately, while the losing URLSession
            // task is explicitly cancelled without being structurally awaited.
            let race = CloudTransportRace()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    race.install(continuation)

                    let transportTask = Task {
                        do {
                            race.resolve(.success(try await transport(request)))
                        } catch {
                            race.resolve(.failure(error))
                        }
                    }
                    let timeoutTask = Task {
                        do {
                            try await Task.sleep(
                                nanoseconds: UInt64(
                                    timeoutSeconds * 1_000_000_000
                                )
                            )
                        } catch {
                            return
                        }
                        race.resolve(.failure(CloudModelClientError.timeout))
                    }
                    race.storeTasks([transportTask, timeoutTask])
                }
            } onCancel: {
                race.resolve(.failure(CancellationError()))
            }
        } catch let error as CloudModelClientError {
            throw error
        } catch is CancellationError {
            throw CloudModelClientError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CloudModelClientError.cancelled
            case .timedOut:
                throw CloudModelClientError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                throw CloudModelClientError.offline
            default:
                throw CloudModelClientError.providerFailure(statusCode: error.code.rawValue)
            }
        } catch {
            throw CloudModelClientError.providerFailure(statusCode: -1)
        }
    }

    private static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudModelClientError.malformedResponse
        }
        return (data, http)
    }
}

/// Thread-safe, one-shot relay for the cloud transport/timeout race. Tasks
/// are deliberately unstructured so returning the configured timeout never
/// waits for a cancellation-unaware transport. Production URLSession work is
/// still cancelled promptly; a pathological injected transport may finish in
/// the background, but it cannot delay or double-resume the caller.
private final class CloudTransportRace: @unchecked Sendable {
    typealias Output = (Data, HTTPURLResponse)

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var bufferedResult: Result<Output, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Output, Error>) {
        lock.lock()
        if let bufferedResult {
            self.bufferedResult = nil
            lock.unlock()
            continuation.resume(with: bufferedResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func storeTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if isResolved {
            lock.unlock()
            tasks.forEach { $0.cancel() }
        } else {
            self.tasks = tasks
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Output, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            bufferedResult = result
        }
        let tasks = tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

private struct RequestEnvelope: Encodable {
    let model: String
    let messages: [CloudChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool
    let responseFormat: CloudResponseFormat?
    let reasoning: CloudReasoningMode?
    let preset: ProviderPreset

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case provider
        case reasoning
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(stream, forKey: .stream)

        if reasoning == .disabled {
            try container.encode(ReasoningConfiguration(enabled: false), forKey: .reasoning)
        }

        switch responseFormat {
        case nil:
            break
        case .jsonObject:
            try container.encode(JSONObjectFormat(), forKey: .responseFormat)
        case .strictCleanupSchema(let itemCount):
            guard itemCount > 0 else { throw CloudMeetingCleanupError.invalidRequest }
            try container.encode(
                StrictCleanupFormat(itemCount: itemCount),
                forKey: .responseFormat
            )
            if preset == .openRouter {
                try container.encode(
                    OpenRouterProviderRouting(requireParameters: true),
                    forKey: .provider
                )
            }
        }
    }
}

private struct ReasoningConfiguration: Encodable {
    let enabled: Bool
}

private struct JSONObjectFormat: Encodable {
    let type = "json_object"
}

private struct OpenRouterProviderRouting: Encodable {
    let requireParameters: Bool
    /// Cleanup is output-heavy enough that routing by throughput is more
    /// representative than OpenRouter's price-first default. Provider
    /// fallbacks remain enabled by OpenRouter; this is routing within the same
    /// user-selected model, not an application retry or model switch.
    let sort = "throughput"

    enum CodingKeys: String, CodingKey {
        case requireParameters = "require_parameters"
        case sort
    }
}

private struct StrictCleanupFormat: Encodable {
    let type = "json_schema"
    let jsonSchema: JSONSchema

    init(itemCount: Int) {
        jsonSchema = JSONSchema(itemCount: itemCount)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    struct JSONSchema: Encodable {
        let name = "openbridge_cleanup_segments"
        let strict = true
        let schema: RootSchema

        init(itemCount: Int) {
            schema = RootSchema(itemCount: itemCount)
        }
    }

    struct RootSchema: Encodable {
        let type = "object"
        let additionalProperties = false
        let properties: RootProperties
        let required = ["segments"]

        init(itemCount: Int) {
            properties = RootProperties(itemCount: itemCount)
        }
    }

    struct RootProperties: Encodable {
        let segments: SegmentArraySchema

        init(itemCount: Int) {
            segments = SegmentArraySchema(itemCount: itemCount)
        }
    }

    struct SegmentArraySchema: Encodable {
        let type = "array"
        let minItems: Int
        let maxItems: Int
        let items: SegmentItemSchema

        init(itemCount: Int) {
            minItems = itemCount
            maxItems = itemCount
            items = SegmentItemSchema(maximumIndex: itemCount)
        }
    }

    struct SegmentItemSchema: Encodable {
        let type = "object"
        let additionalProperties = false
        let properties: SegmentProperties
        let required = ["index", "cleanedText"]

        init(maximumIndex: Int) {
            properties = SegmentProperties(maximumIndex: maximumIndex)
        }
    }

    struct SegmentProperties: Encodable {
        let index: IntegerSchema
        let cleanedText = StringSchema()

        init(maximumIndex: Int) {
            index = IntegerSchema(maximum: maximumIndex)
        }
    }

    struct IntegerSchema: Encodable {
        let type = "integer"
        let minimum = 1
        let maximum: Int
    }

    struct StringSchema: Encodable {
        let type = "string"
        let minLength = 1
    }
}

private struct ResponseEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
