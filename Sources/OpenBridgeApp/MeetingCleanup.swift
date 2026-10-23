import CryptoKit
import Foundation

/// The production cleanup contract accepted by the CLEAN-00 benchmark (#319).
/// The model repository is the local Gemma identity; contract version and
/// chunk size are shared by both local and cloud cleanup paths.
enum MeetingCleanupContract {
    static let version = 1
    static let modelRepository = "mlx-community/gemma-3-4b-it-qat-4bit"
    static let chunkSize = 8
}

/// The engine selected for a meeting's post-Stop cleanup. This is resolved
/// and snapshotted when the meeting is created; a later settings change must
/// never silently move an existing meeting to another provider.
enum MeetingCleanupProvider: String, Codable, Equatable, Sendable {
    case localGemma
    case cloud
}

/// Non-secret provider settings captured for a newly-created meeting.
/// Credentials deliberately remain in Keychain and are never encoded here.
struct MeetingCloudProviderSnapshot: Codable, Equatable, Sendable {
    let preset: ProviderPreset
    let endpoint: URL
    let model: String
    let timeout: TimeInterval

    var configuration: ProviderConfiguration {
        ProviderConfiguration(
            preset: preset,
            baseURL: endpoint,
            model: model,
            timeout: timeout
        )
    }
}

/// Build-19 intelligence contract for a newly-created meeting. Its optional
/// presence is also the compatibility boundary: older manifests decode nil
/// and do not gain cloud-cleanup or post-meeting intelligence controls.
struct MeetingIntelligenceConfiguration: Codable, Equatable, Sendable {
    let cleanupEnabled: Bool
    let cleanupProvider: MeetingCleanupProvider
    let cloudProvider: MeetingCloudProviderSnapshot?
}

enum MeetingIntelligenceConfigurationResolver {
    static func snapshot(
        cleanupEnabled: Bool,
        aiMode: MeetingAIMode,
        providerSettings: ProviderSettings,
        hasCredential: Bool,
        providerWasTested: Bool,
        cleanupProvider: MeetingCleanupProvider? = nil
    ) throws -> MeetingIntelligenceConfiguration {
        let selectedCloud = aiMode.maySendTranscriptToCloud
        if cleanupEnabled && cleanupProvider == .cloud && !selectedCloud {
            throw CloudRequestAuthorizationError.meetingConsentRequired
        }
        let cloudSnapshot: MeetingCloudProviderSnapshot?

        if selectedCloud {
            // Validate again at the instant the manifest is created. Start can
            // suspend while an earlier cleanup exits, and Settings can change
            // while the confirmation alert is open. A stale UI gate must never
            // stamp an unusable cloud configuration into a new meeting.
            guard providerSettings.cloudEnabled else {
                throw CloudRequestAuthorizationError.cloudDisabled
            }
            guard providerSettings.consentGranted else {
                throw CloudRequestAuthorizationError.globalConsentRequired
            }
            guard hasCredential else {
                throw CloudRequestAuthorizationError.missingCredential
            }
            guard providerWasTested else {
                throw CloudRequestAuthorizationError.connectionTestRequired
            }

            let configuration: ProviderConfiguration
            do {
                configuration = try providerSettings.configuration.validated()
            } catch {
                throw CloudRequestAuthorizationError.invalidConfiguration(
                    "The cloud provider configuration is invalid. Review it in Settings and Test Connection again."
                )
            }
            cloudSnapshot = MeetingCloudProviderSnapshot(
                preset: configuration.preset,
                endpoint: configuration.baseURL,
                model: configuration.model,
                timeout: configuration.timeout
            )
        } else {
            cloudSnapshot = nil
        }

        return MeetingIntelligenceConfiguration(
            cleanupEnabled: cleanupEnabled,
            cleanupProvider: cleanupProvider ?? (cleanupEnabled && selectedCloud ? .cloud : .localGemma),
            cloudProvider: selectedCloud ? cloudSnapshot : nil
        )
    }
}

/// Provenance persisted with a cleanup revision. This contains no secret
/// material and is used both for auditability and provider-drift protection.
struct MeetingCleanupProvenance: Equatable, Sendable {
    let producer: MeetingCleanupProvider
    let providerIdentifier: String
    let endpoint: URL?
    let model: String

    static let localGemma = MeetingCleanupProvenance(
        producer: .localGemma,
        providerIdentifier: "local-gemma",
        endpoint: nil,
        model: MeetingCleanupContract.modelRepository
    )

    static func cloud(_ snapshot: MeetingCloudProviderSnapshot) -> MeetingCleanupProvenance {
        MeetingCleanupProvenance(
            producer: .cloud,
            providerIdentifier: snapshot.preset.rawValue,
            endpoint: snapshot.endpoint,
            model: snapshot.model
        )
    }
}

/// Durable execution state for a post-meeting cleanup job.
enum MeetingCleanupJobState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case interrupted
    case stale
    case retryAvailable
}

/// A revision is pending until every source segment has exactly one valid,
/// ID-aligned result. Only a valid revision may become the active revision.
enum MeetingCleanupRevisionState: String, Codable, Equatable, Sendable {
    case pending
    case valid
    case stale
}

struct MeetingCleanedSegment: Codable, Equatable, Sendable {
    let sourceSegmentID: String
    let cleanedText: String
}

/// Content-free failure categories safe to persist, display, and include in
/// diagnostics. They describe structure or transport only and can never echo
/// transcript text or a provider response body.
enum CleanupFailureReason: String, Codable, Equatable, Sendable {
    case invalidJSON
    case wrongCount
    case invalidIndex
    case emptyText
    case truncation
    case modelUnavailable
    case authentication
    case offline
    case timeout
    case providerRejected
    case cloudDisabled
    case consentRequired
    case connectionTestRequired
    case configurationChanged
    case requestAlreadyActive
    case unknown

    static func classify(_ error: Error) -> CleanupFailureReason {
        if let authorization = error as? CloudRequestAuthorizationError {
            switch authorization {
            case .cloudDisabled: return .cloudDisabled
            case .globalConsentRequired, .meetingConsentRequired: return .consentRequired
            case .missingCredential: return .authentication
            case .connectionTestRequired: return .connectionTestRequired
            case .invalidConfiguration, .configurationChanged: return .configurationChanged
            case .requestAlreadyActive: return .requestAlreadyActive
            }
        }
        if let cloud = error as? CloudMeetingCleanupError {
            switch cloud {
            case .malformedResponse: return .invalidJSON
            case .wrongCount: return .wrongCount
            case .invalidIndex: return .invalidIndex
            case .emptyText, .placeholderText: return .emptyText
            case .invalidRequest: return .unknown
            }
        }
        if let client = error as? CloudModelClientError {
            switch client {
            case .authenticationFailed: return .authentication
            case .offline: return .offline
            case .timeout: return .timeout
            case .malformedResponse, .responseTooLarge: return .invalidJSON
            case .creditUnavailable, .rateLimited, .providerFailure: return .providerRejected
            case .cancelled: return .unknown
            }
        }

        let message = String(describing: error).lowercased()
        if message.contains("cleanup_invalid_json") { return .invalidJSON }
        if message.contains("cleanup_wrong_count") { return .wrongCount }
        if message.contains("cleanup_invalid_index") { return .invalidIndex }
        if message.contains("cleanup_empty_text") { return .emptyText }
        if message.contains("cleanup_placeholder_text") { return .emptyText }
        if message.contains("cleanup_truncation") { return .truncation }
        if message.contains("model") && (
            message.contains("missing") || message.contains("unavailable")
                || message.contains("not found") || message.contains("incomplete")
        ) { return .modelUnavailable }
        if message.contains("auth") || message.contains("credential") || message.contains("api key") {
            return .authentication
        }
        if message.contains("offline") || message.contains("network") { return .offline }
        if message.contains("timeout") || message.contains("timed out") { return .timeout }
        return .unknown
    }
}

/// Untrusted model-generation shape. It deliberately contains no durable
/// UUID; OpenBridge validates the ordinal and attaches `sourceSegmentID`
/// locally from the immutable canonical transcript.
struct CleanupGenerationItem: Codable, Equatable, Sendable {
    let index: Int
    let cleanedText: String
}

struct MeetingCleanupRevision: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let meetingID: String
    let sourceTranscriptFingerprint: String
    let sourceSegmentIDs: [String]
    let contractVersion: Int
    let modelRepository: String
    var modelRevision: String?
    /// Nil on revisions written before build 19; those resolve to local Gemma.
    var producer: MeetingCleanupProvider? = nil
    var providerIdentifier: String? = nil
    var providerEndpoint: URL? = nil
    var providerModel: String? = nil
    let chunkSize: Int
    var state: MeetingCleanupRevisionState
    let createdAt: Date
    var completedAt: Date?
    var cleanedSegments: [MeetingCleanedSegment]

    var resolvedProvenance: MeetingCleanupProvenance {
        MeetingCleanupProvenance(
            producer: producer ?? .localGemma,
            providerIdentifier: providerIdentifier ?? "local-gemma",
            endpoint: providerEndpoint,
            model: providerModel ?? modelRepository
        )
    }
}

struct MeetingCleanupJob: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let meetingID: String
    let revisionID: String
    var state: MeetingCleanupJobState
    let createdAt: Date
    var updatedAt: Date
    var attempt: Int
    var completedChunkCount: Int
    let totalChunkCount: Int
    var errorMessage: String?
    var failureReason: CleanupFailureReason? = nil
}

/// Stable SHA-256 identity for the canonical typed transcript.
///
/// Length-prefixing each field avoids ambiguous concatenations: for example,
/// `["ab", "c"]` cannot hash like `["a", "bc"]`. A changed source ID,
/// ordering field, timestamp, label, text, or finality therefore makes an old
/// cleanup revision stale without modifying the original transcript.
enum MeetingTranscriptFingerprint {
    static func make(for segments: [MeetingTranscriptSegment]) -> String {
        var data = Data()
        for segment in segments.sorted(by: canonicalOrder) {
            append(segment.id, to: &data)
            append(segment.meetingID, to: &data)
            append(String(segment.sequence), to: &data)
            append(segment.startOffset.map { String($0) } ?? "nil", to: &data)
            append(segment.endOffset.map { String($0) } ?? "nil", to: &data)
            append(segment.sourceLabel, to: &data)
            append(segment.text, to: &data)
            append(segment.isFinal ? "true" : "false", to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalOrder(_ lhs: MeetingTranscriptSegment, _ rhs: MeetingTranscriptSegment) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.id < rhs.id
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        data.append(Data("\(bytes.count):".utf8))
        data.append(bytes)
        data.append(0)
    }
}

/// lunr-studio/Openbridge-Beta#321 (AC8): the revision-review validity decision that MUST agree with
/// the lunr-studio/Openbridge-Beta#214 export gate - Cleaned is shown/exported ONLY when a valid,
/// current active revision exists. Extracted as one predicate so the review
/// surface and the export path cannot drift apart.
enum MeetingRevisionReviewValidity {
    static func shouldDefaultToCleaned(_ revision: MeetingCleanupRevision?) -> Bool {
        revision?.state == .valid
    }
}
