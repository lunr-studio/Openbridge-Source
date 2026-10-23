import Foundation

enum MeetingIntelligenceArtifactKind: String, Codable, Equatable, Sendable {
    case summary
    case actionsAndDecisions
}

struct MeetingIntelligenceProvenance: Codable, Equatable, Sendable {
    let provider: ProviderPreset
    let endpoint: URL
    let model: String

    init(snapshot: MeetingCloudProviderSnapshot) {
        provider = snapshot.preset
        endpoint = snapshot.endpoint
        model = snapshot.model
    }
}

struct MeetingSummaryArtifact: Codable, Equatable, Sendable {
    let id: String
    let sourceTranscriptFingerprint: String
    let provenance: MeetingIntelligenceProvenance
    let createdAt: Date
    let text: String

    func isStale(for manifest: MeetingManifest) -> Bool {
        sourceTranscriptFingerprint != MeetingTranscriptFingerprint.make(for: manifest.segments)
    }
}

struct MeetingIntelligenceAction: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let description: String
    let assignee: String?
    let supportingSegmentIDs: [String]
}

struct MeetingIntelligenceDecision: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let summary: String
    let supportingSegmentIDs: [String]
}

struct MeetingActionsDecisionsArtifact: Codable, Equatable, Sendable {
    let id: String
    let sourceTranscriptFingerprint: String
    let provenance: MeetingIntelligenceProvenance
    let createdAt: Date
    let actions: [MeetingIntelligenceAction]
    let decisions: [MeetingIntelligenceDecision]

    func isStale(for manifest: MeetingManifest) -> Bool {
        sourceTranscriptFingerprint != MeetingTranscriptFingerprint.make(for: manifest.segments)
    }
}

/// One atomic, meeting-scoped file. Keeping derived intelligence beside the
/// manifest means retention and meeting deletion remove it automatically.
struct MeetingIntelligenceSidecar: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let meetingID: String
    var summary: MeetingSummaryArtifact?
    var actionsAndDecisions: MeetingActionsDecisionsArtifact?

    init(
        meetingID: String,
        summary: MeetingSummaryArtifact? = nil,
        actionsAndDecisions: MeetingActionsDecisionsArtifact? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.meetingID = meetingID
        self.summary = summary
        self.actionsAndDecisions = actionsAndDecisions
    }
}

enum MeetingIntelligenceArtifactExporter {
    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func summaryDocument(
        meeting: MeetingManifest,
        artifact: MeetingSummaryArtifact
    ) -> (filename: String, text: String) {
        let stale = artifact.isStale(for: meeting) ? "Yes" : "No"
        let text = """
        # Meeting Summary

        - Meeting: \(meeting.title)
        - Generated: \(iso8601(artifact.createdAt))
        - Provider: \(artifact.provenance.provider.displayName)
        - Model: \(artifact.provenance.model)
        - Endpoint: \(artifact.provenance.endpoint.absoluteString)
        - Source fingerprint: \(artifact.sourceTranscriptFingerprint)
        - Stale: \(stale)

        \(artifact.text)
        """
        return ("Meeting Summary.md", text)
    }

    static func actionsAndDecisionsDocument(
        meeting: MeetingManifest,
        artifact: MeetingActionsDecisionsArtifact
    ) -> (filename: String, text: String) {
        let stale = artifact.isStale(for: meeting) ? "Yes" : "No"
        let decisions = artifact.decisions.isEmpty
            ? "- None identified."
            : artifact.decisions.map { "- \($0.summary)" }.joined(separator: "\n")
        let actions = artifact.actions.isEmpty
            ? "- None identified."
            : artifact.actions.map { action in
                if let assignee = action.assignee, !assignee.isEmpty {
                    return "- \(action.description) — \(assignee)"
                }
                return "- \(action.description)"
            }.joined(separator: "\n")
        let text = """
        # Meeting Actions and Decisions

        - Meeting: \(meeting.title)
        - Generated: \(iso8601(artifact.createdAt))
        - Provider: \(artifact.provenance.provider.displayName)
        - Model: \(artifact.provenance.model)
        - Endpoint: \(artifact.provenance.endpoint.absoluteString)
        - Source fingerprint: \(artifact.sourceTranscriptFingerprint)
        - Stale: \(stale)

        ## Decisions

        \(decisions)

        ## Actions

        \(actions)
        """
        return ("Meeting Actions and Decisions.md", text)
    }

    /// Writes a user-requested export with owner-only permissions. Atomic
    /// replacement protects the output from partial writes, while 0600 keeps
    /// transcript-derived content private on multi-user Macs.
    static func write(_ document: (filename: String, text: String), to destination: URL) throws {
        guard let data = document.text.data(using: .utf8) else {
            throw MeetingIntelligenceArtifactError.exportEncodingFailed
        }
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}

enum MeetingIntelligenceArtifactError: LocalizedError, Equatable {
    case legacyMeeting
    case meetingNotCompleted
    case cloudConsentRequired
    case providerNotTested
    case missingProviderSnapshot
    case noTranscript
    case transcriptTooLarge
    case malformedResponse
    case unsupportedSegmentReference
    case unsupportedSidecarSchema
    case sidecarMeetingMismatch
    case exportEncodingFailed

    var errorDescription: String? {
        switch self {
        case .legacyMeeting:
            return "This meeting predates build 19 meeting tools."
        case .meetingNotCompleted:
            return "Finish or recover this meeting before using meeting tools."
        case .cloudConsentRequired:
            return "This meeting was not created with Cloud (opt-in) consent."
        case .providerNotTested:
            return "Test the meeting's configured cloud provider in Settings first."
        case .missingProviderSnapshot:
            return "This meeting has no saved cloud provider configuration."
        case .noTranscript:
            return "This meeting has no completed transcript to analyze."
        case .transcriptTooLarge:
            return "This transcript is too large for one cloud action."
        case .malformedResponse:
            return "The cloud provider returned meeting intelligence JSON OpenBridge could not read."
        case .unsupportedSegmentReference:
            return "The cloud provider cited a segment that is not in this meeting."
        case .unsupportedSidecarSchema:
            return "This meeting intelligence file was written by an unsupported OpenBridge version."
        case .sidecarMeetingMismatch:
            return "The saved meeting intelligence belongs to a different meeting."
        case .exportEncodingFailed:
            return "OpenBridge could not encode this saved output for export."
        }
    }
}
