import Foundation

// MARK: - Research Provider Orchestrator (#296)
//
// Guards all provider calls with:
//   1. Per-request timeout
//   2. Cooperative cancellation propagation
//   3. Concurrency limit (default 1 concurrent call)
//   4. Stale-request cancellation (a newer request for the same scope
//      supersedes an older in-flight one — the old result is discarded)
//   5. Mode gating (transcriptionOnly blocks everything)

// MARK: - Orchestrator Configuration

struct ResearchOrchestratorConfiguration: Equatable, Sendable {
    /// Maximum time a single provider call may take before it times out.
    var timeout: TimeInterval = 30
    /// Maximum number of concurrent in-flight requests across all scopes.
    var maxConcurrent: Int = 1
    /// When a new request arrives for the same scope key, older in-flight
    /// requests for that key are superseded — their result is discarded
    /// with `.staleRequest`.
    var cancelStaleRequests: Bool = true

    static let `default` = ResearchOrchestratorConfiguration()
    static let test = ResearchOrchestratorConfiguration(
        timeout: 5,
        maxConcurrent: 1,
        cancelStaleRequests: true
    )
}

// MARK: - Orchestrator Errors

enum ResearchOrchestratorError: Equatable, LocalizedError, Sendable {
    case concurrencyLimitReached
    case modeBlocked(ResearchProviderMode)

    var errorDescription: String? {
        switch self {
        case .concurrencyLimitReached:
            return "The research provider concurrency limit was reached."
        case .modeBlocked(let mode):
            return ResearchProviderError.modeBlocked(mode).errorDescription
        }
    }
}

// MARK: - Orchestrator

/// Guards all provider calls. Uses an actor to serialize state access
/// (generation counters, active counts). The actual provider call runs
/// in the caller's task context.
///
/// Stale-request cancellation uses a **generation counter** per scope:
/// every request for a scope increments the counter and captures its
/// value. When the provider call completes, the orchestrator checks if
/// the counter has advanced. If it has, a newer request superseded this
/// one and the result is discarded with `.staleRequest`.
actor ResearchProviderOrchestrator {
    private let provider: any ResearchProvider
    private let configuration: ResearchOrchestratorConfiguration
    private let logger: (any ResearchProviderLogger)?

    private var scopeGenerations: [String: Int] = [:]
    private var activeCount: Int = 0

    init(
        provider: any ResearchProvider,
        configuration: ResearchOrchestratorConfiguration = .default,
        logger: (any ResearchProviderLogger)? = nil
    ) {
        self.provider = provider
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: - Public API

    func classify(
        _ request: ClassificationRequest,
        mode: ResearchProviderMode,
        scopeKey: String = "default"
    ) async throws -> ClassificationResponse {
        try await execute(
            operation: .classification,
            mode: mode,
            scopeKey: scopeKey,
            context: request.context,
            inputCharacterCount: request.questionText.count
        ) { [provider] in
            try await provider.classify(request)
        }
    }

    func groundedAnswer(
        _ request: GroundedAnswerRequest,
        mode: ResearchProviderMode,
        scopeKey: String = "default"
    ) async throws -> GroundedAnswerResponse {
        try await execute(
            operation: .groundedAnswer,
            mode: mode,
            scopeKey: scopeKey,
            context: request.context,
            inputCharacterCount: request.questionText.count
        ) { [provider] in
            try await provider.groundedAnswer(request)
        }
    }

    func stateUpdate(
        _ request: StateUpdateRequest,
        mode: ResearchProviderMode,
        scopeKey: String = "default"
    ) async throws -> StateUpdateResponse {
        let totalChars = request.excerpts.reduce(0) { $0 + $1.text.count }
        return try await execute(
            operation: .stateUpdate,
            mode: mode,
            scopeKey: scopeKey,
            context: request.context,
            inputCharacterCount: totalChars
        ) { [provider] in
            try await provider.stateUpdate(request)
        }
    }

    // MARK: - Core Execution Guard

    private func execute<T: Sendable>(
        operation: ResearchProviderOperation,
        mode: ResearchProviderMode,
        scopeKey: String,
        context: ResearchProviderContext,
        inputCharacterCount: Int,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Mode gate
        guard mode.allowsProviderCalls else {
            logEvent(.rejected, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: 0, inputCharacterCount: inputCharacterCount,
                     error: ResearchProviderError.modeBlocked(mode))
            throw ResearchProviderError.modeBlocked(mode)
        }

        // Cloud provider gate
        if provider.descriptor.isCloud && !mode.allowsCloudProvider {
            logEvent(.rejected, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: 0, inputCharacterCount: inputCharacterCount,
                     error: ResearchProviderError.modeBlocked(mode))
            throw ResearchProviderError.modeBlocked(mode)
        }

        // Concurrency gate
        guard activeCount < configuration.maxConcurrent else {
            logEvent(.rejected, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: 0, inputCharacterCount: inputCharacterCount,
                     error: ResearchOrchestratorError.concurrencyLimitReached)
            throw ResearchOrchestratorError.concurrencyLimitReached
        }

        // Stale-request: bump generation so any in-flight older request
        // for this scope knows it has been superseded.
        let myGeneration: Int
        if configuration.cancelStaleRequests {
            let current = scopeGenerations[scopeKey] ?? 0
            myGeneration = current + 1
            scopeGenerations[scopeKey] = myGeneration
        } else {
            myGeneration = scopeGenerations[scopeKey] ?? 0
        }

        activeCount += 1

        logEvent(.started, operation: operation, context: context,
                 scopeKey: scopeKey, durationMS: 0, inputCharacterCount: inputCharacterCount,
                 error: nil)

        let startedAt = Date()

        do {
            let result = try await withTimeout(operation: operation, timeout: configuration.timeout) {
                try await work()
            }

            activeCount -= 1

            // Stale check: if a newer request bumped the generation for
            // this scope, discard our result.
            if configuration.cancelStaleRequests {
                let latestGeneration = scopeGenerations[scopeKey] ?? myGeneration
                if latestGeneration > myGeneration {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    logEvent(.staleCancelled, operation: operation, context: context,
                             scopeKey: scopeKey, durationMS: elapsed,
                             inputCharacterCount: inputCharacterCount,
                             error: ResearchProviderError.staleRequest)
                    throw ResearchProviderError.staleRequest
                }
            }

            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            logEvent(.completed, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: elapsed,
                     inputCharacterCount: inputCharacterCount, error: nil)
            return result
        } catch let error as CancellationError {
            activeCount -= 1
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            logEvent(.cancelled, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: elapsed,
                     inputCharacterCount: inputCharacterCount,
                     error: ResearchProviderError.cancelled)
            throw ResearchProviderError.cancelled
        } catch let error as ResearchProviderError where error == .timeout {
            activeCount -= 1
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            logEvent(.timedOut, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: elapsed,
                     inputCharacterCount: inputCharacterCount, error: error)
            throw error
        } catch let error as ResearchProviderError where error == .staleRequest {
            // activeCount was already decremented above
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            logEvent(.staleCancelled, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: elapsed,
                     inputCharacterCount: inputCharacterCount, error: error)
            throw error
        } catch {
            activeCount -= 1
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let providerError: ResearchProviderError
            if let pe = error as? ResearchProviderError {
                providerError = pe
            } else {
                providerError = .providerError(String(describing: error))
            }
            logEvent(.failed, operation: operation, context: context,
                     scopeKey: scopeKey, durationMS: elapsed,
                     inputCharacterCount: inputCharacterCount, error: providerError)
            throw providerError
        }
    }

    // MARK: - Timeout Helper

    /// Runs `work` and throws `.timeout` if it doesn't complete within
    /// `timeout` seconds. Also propagates cancellation.
    private func withTimeout<T: Sendable>(
        operation: ResearchProviderOperation,
        timeout: TimeInterval,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ResearchProviderError.timeout
            }

            guard let result = try await group.next() else {
                throw ResearchProviderError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Logging Helper

    private func logEvent(
        _ event: ResearchProviderLogEvent,
        operation: ResearchProviderOperation,
        context: ResearchProviderContext,
        scopeKey: String,
        durationMS: Int,
        inputCharacterCount: Int,
        error: (any Error)?
    ) {
        logger?.log(.init(
            event: event,
            operation: operation,
            providerID: provider.descriptor.identifier,
            requestID: context.requestID,
            scopeKey: scopeKey,
            durationMS: durationMS,
            inputCharacterCount: inputCharacterCount,
            error: error as? ResearchProviderError
        ))
    }

    // MARK: - Introspection (for tests)

    var currentActiveCount: Int {
        activeCount
    }

    func scopeGeneration(for key: String) -> Int {
        scopeGenerations[key] ?? 0
    }
}