import Foundation

// MARK: - Research Provider Structural Logger (#296)
//
// Logs provider call lifecycle events without exposing any transcript or
// question text. Every entry is structural: operation, provider, request ID,
// scope key, duration, character counts, and outcome.

// MARK: - Log Event Type

enum ResearchProviderLogEvent: String, Equatable, Sendable {
    case started
    case completed
    case cancelled
    case staleCancelled
    case failed
    case rejected
    case timedOut
}

// MARK: - Log Entry

/// A single redacted log entry. Contains **no** user content — only
/// structural metadata. Character counts are logged (not text) so that
/// operators can see payload sizes without seeing payload content.
struct ResearchProviderLogEntry: Equatable, Sendable {
    let event: ResearchProviderLogEvent
    let operation: ResearchProviderOperation
    let providerID: String
    let requestID: String
    let scopeKey: String
    let durationMS: Int
    let inputCharacterCount: Int
    let error: ResearchProviderError?
    let timestamp: Date

    init(
        event: ResearchProviderLogEvent,
        operation: ResearchProviderOperation,
        providerID: String,
        requestID: String,
        scopeKey: String,
        durationMS: Int,
        inputCharacterCount: Int,
        error: ResearchProviderError?,
        timestamp: Date = Date()
    ) {
        self.event = event
        self.operation = operation
        self.providerID = providerID
        self.requestID = requestID
        self.scopeKey = scopeKey
        self.durationMS = durationMS
        self.inputCharacterCount = inputCharacterCount
        self.error = error
        self.timestamp = timestamp
    }

    /// Human-readable redacted summary for console/OSLog.
    var redactedDescription: String {
        var parts: [String] = [
            "[\(event.rawValue)]",
            "op=\(operation.rawValue)",
            "provider=\(providerID)",
            "req=\(requestID.prefix(8))",
            "chars=\(inputCharacterCount)",
            "\(durationMS)ms",
        ]
        if let error {
            parts.append("err=\(error.structuralLogCode)")
        }
        return parts.joined(separator: " ")
    }
}

private extension ResearchProviderError {
    var structuralLogCode: String {
        switch self {
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .staleRequest: return "staleRequest"
        case .invalidJSON: return "invalidJSON"
        case .unsupportedOperation: return "unsupportedOperation"
        case .rateLimited: return "rateLimited"
        case .providerError: return "providerError"
        case .modeBlocked: return "modeBlocked"
        }
    }
}

// MARK: - Logger Protocol

protocol ResearchProviderLogger: Sendable {
    func log(_ entry: ResearchProviderLogEntry)
}

// MARK: - Recording Logger (for tests)

/// Captures all log entries in memory for test assertions.
final class RecordingResearchProviderLogger: ResearchProviderLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ResearchProviderLogEntry] = []

    func log(_ entry: ResearchProviderLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    var allEntries: [ResearchProviderLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func entries(for event: ResearchProviderLogEvent) -> [ResearchProviderLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.event == event }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// Verifies that no entry contains raw user text. A best-effort check
    /// that scans the `redactedDescription` for a known forbidden substring.
    func containsRedactedContent(_ forbiddenText: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.redactedDescription.contains(forbiddenText) }
    }
}

// MARK: - No-Op Logger (production default until OSLog is wired)

struct NoOpResearchProviderLogger: ResearchProviderLogger {
    func log(_ entry: ResearchProviderLogEntry) {
        // Intentionally empty. Production code will replace this with an
        // OSLog-backed implementation in a future issue.
    }
}
