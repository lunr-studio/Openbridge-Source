import Foundation

// MARK: - Meeting session state

enum MeetingSessionState: String, Codable {
    case setup
    case recording
    case stopped
    case completed
    case interrupted
    case exported

    // Schema v3.1 (#219): granular recovery states
    /// Recording captured to disk but transcription not yet run. The meeting
    /// was likely interrupted (crash/force-quit) after recording stopped but
    /// before finalization completed.
    case captured
    /// Transcription is actively running (live or final).
    case transcribingLive
    /// Meeting is in the finalization phase — transcribing the last segments.
    case finalizing
    /// A capture, transcription, or provider failure occurred. Source audio is
    /// preserved. The user must explicitly recover, retry, or delete.
    case failed
    /// One or more aspects (capture, transcription, cleanup) need user action
    /// to reach a safe terminal state. Surfaced at relaunch.
    case recoveryNeeded

    /// True when the meeting is in a state that should be surfaced for
    /// recovery at relaunch — it never completed cleanly.
    var needsRecovery: Bool {
        switch self {
        case .setup, .recording, .stopped, .captured, .transcribingLive,
             .finalizing, .failed, .recoveryNeeded, .interrupted:
            return true
        case .completed, .exported:
            return false
        }
    }
}

// MARK: - Meeting source metadata

enum MeetingCaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case inPerson
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inPerson: return "In-person"
        case .online: return "Online"
        }
    }
}

enum MeetingCaptureStatus: String, Codable, Sendable {
    case full
    case microphoneOnlyFallback
}

enum MeetingSourceKind: String, Codable, Sendable {
    case microphone
    case systemAudio = "system-audio"
}

struct MeetingSourceMetadata: Codable, Equatable, Sendable {
    let sourceID: String
    let label: String
    let kind: MeetingSourceKind
    let deviceID: String
    let sampleRate: Double

    init(
        sourceID: String = UUID().uuidString,
        label: String = "Room",
        kind: MeetingSourceKind = .microphone,
        deviceID: String,
        sampleRate: Double = 16000
    ) {
        self.sourceID = sourceID
        self.label = label
        self.kind = kind
        self.deviceID = deviceID
        self.sampleRate = sampleRate
    }
}

struct MeetingAudioArtifact: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let sourceKind: MeetingSourceKind
    let sequence: Int
    let relativePath: String
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    var overlapSeconds: TimeInterval? = nil

    init(
        id: String = UUID().uuidString,
        sourceID: String,
        sourceKind: MeetingSourceKind,
        sequence: Int,
        relativePath: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        sampleRate: Double,
        channelCount: Int
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.sequence = sequence
        self.relativePath = relativePath
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

// MARK: - Meeting retention policy

enum MeetingRetentionPolicy: String, Codable {
    case keepUntilDeleted
    case autoDeleteAfter7Days
    case autoDeleteAfter30Days
    case neverStoreTranscript
    case deleteAudioAfterTranscript

    var retentionDays: Int? {
        switch self {
        case .keepUntilDeleted: return nil
        case .autoDeleteAfter7Days: return 7
        case .autoDeleteAfter30Days: return 30
        // Wave-7 (3876716826): neverStoreTranscript suppresses transcript
        // STORAGE, not the meeting itself - it must never be auto-pruned
        // (nil = never). Returning 0 made enforceRetentionPolicy delete the
        // whole meeting (incl. raw audio) on the next page visit/relaunch.
        case .neverStoreTranscript: return nil
        case .deleteAudioAfterTranscript: return nil
        }
    }

    /// lunr-studio/Openbridge-Beta#214: a policy that removes user data automatically is DESTRUCTIVE -
    /// selecting it requires a confirmation before it is applied.
    var isDestructive: Bool {
        switch self {
        case .keepUntilDeleted: return false
        case .autoDeleteAfter7Days, .autoDeleteAfter30Days: return true
        case .neverStoreTranscript: return true
        case .deleteAudioAfterTranscript: return true
        }
    }

    /// lunr-studio/Openbridge-Beta#214: user-facing label (the rawValue is a camelCase code name).
    var displayName: String {
        switch self {
        case .keepUntilDeleted: return "Keep until deleted"
        case .autoDeleteAfter7Days: return "Delete after 7 days"
        case .autoDeleteAfter30Days: return "Delete after 30 days"
        case .neverStoreTranscript: return "Never store transcript"
        case .deleteAudioAfterTranscript: return "Delete audio after transcript"
        }
    }
}

// MARK: - Meeting AI mode

enum MeetingAIMode: String, Codable {
    case transcriptionOnly
    case localOnly
    case cloudOptIn

    var maySendTranscriptToCloud: Bool {
        self == .cloudOptIn
    }
}

// MARK: - Schema v2: Typed transcript segment

/// A single typed transcript segment with a stable identifier.
///
/// Segments are appended during and after recording. Each segment carries
/// enough metadata for source navigation, retrieval, and export without
/// parsing free-text strings.
struct MeetingTranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier that survives save/reload cycles.
    let id: String
    /// Parent meeting identifier.
    let meetingID: String
    /// Zero-based sequence number within the meeting.
    let sequence: Int
    /// Seconds from the meeting start, if known.
    let startOffset: TimeInterval?
    /// Seconds from the meeting start when this segment ended, if known.
    let endOffset: TimeInterval?
    /// Source or speaker label (e.g. "Room", "Microphone"). Never invents named speakers.
    var sourceID: String? = nil
    var sourceSequence: Int? = nil
    var artifactID: String? = nil
    let sourceLabel: String
    /// The transcript text for this segment.
    let text: String
    /// True once the segment has been finalized; false during live transcription.
    let isFinal: Bool

    init(
        id: String = UUID().uuidString,
        meetingID: String,
        sequence: Int,
        startOffset: TimeInterval? = nil,
        endOffset: TimeInterval? = nil,
        sourceLabel: String = "Room",
        text: String,
        isFinal: Bool = true
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sequence = sequence
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.sourceLabel = sourceLabel
        self.text = text
        self.isFinal = isFinal
    }
}

// MARK: - Schema v2: Participant

/// A meeting participant. Labels are generic ("Participant 1") and never
/// invent named speakers unless the user explicitly provides them.
struct MeetingParticipant: Codable, Equatable, Identifiable {
    let id: String
    let label: String

    init(id: String = UUID().uuidString, label: String) {
        self.id = id
        self.label = label
    }
}

// MARK: - Schema v2: Agenda item

struct MeetingAgendaItem: Codable, Equatable, Identifiable {
    let id: String
    let text: String

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - Schema v2: Objective

struct MeetingObjective: Codable, Equatable, Identifiable {
    let id: String
    let text: String

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - Schema v2: Privacy / intelligence settings

/// Explicit per-meeting intelligence and privacy controls.
struct MeetingPrivacySettings: Codable, Equatable {
    var allowsLocalIntelligence: Bool
    var allowsCloudIntelligence: Bool
    var retainsTranscript: Bool

    init(
        allowsLocalIntelligence: Bool = true,
        allowsCloudIntelligence: Bool = false,
        retainsTranscript: Bool = true
    ) {
        self.allowsLocalIntelligence = allowsLocalIntelligence
        self.allowsCloudIntelligence = allowsCloudIntelligence
        self.retainsTranscript = retainsTranscript
    }
}

// MARK: - Meeting manifest

/// Durable pointer to the WAV that is still being journalled. Its start is
/// saved once when the writer is created; after a relaunch the WAV duration
/// supplies the end offset, so force-quit recovery keeps usable timestamps.
struct MeetingActiveJournal: Equatable, Codable, Sendable {
    let filename: String
    let segmentIndex: Int
    let startOffset: TimeInterval
}

/// UI fallback used only when the same storage outage that stopped capture
/// also prevents the manifest's failed-state transition from being saved.
/// It never claims durability; relaunch recovery remains the durable fallback.
enum MeetingCaptureFailurePresentation {
    static func applyingFailure(
        to meetings: [MeetingManifest],
        meetingID: String,
        reason: String
    ) -> [MeetingManifest] {
        var updated = meetings
        guard let index = updated.firstIndex(where: { $0.meetingID == meetingID }),
              updated[index].state != .completed
        else { return updated }
        updated[index].state = .failed
        updated[index].events.append("FAILED_IN_MEMORY: \(reason)")
        return updated
    }
}

struct MeetingManifest: Equatable, Codable, Identifiable {
    static let currentSchemaVersion = 4

    var id: String { meetingID }

    var schemaVersion: Int
    var meetingID: String
    var title: String
    var workspaceID: String?
    var state: MeetingSessionState
    var startedAt: Date
    var endedAt: Date?
    var captureMode: MeetingCaptureMode = .inPerson
    var captureStatus: MeetingCaptureStatus = .full
    var audioArtifacts: [MeetingAudioArtifact] = []
    var activeSourceJournals: [String: MeetingActiveJournal] = [:]
    var transcribedArtifactIDs: [String] = []
    // Raw engine pieces are retained so overlap normalization is repeatable after relaunch.
    // An empty array is a durable successful-silence receipt. Never stored under neverStoreTranscript.
    var rawArtifactSegments: [String: [MeetingTranscriptSegment]] = [:]
    var sources: [MeetingSourceMetadata]
    var retentionPolicy: MeetingRetentionPolicy
    var aiMode: MeetingAIMode
    var lastCompletedSegmentIndex: Int

    // Legacy transcript spans (v1). Preserved verbatim — never deleted or
    // rewritten. New typed segments live in `segments`.
    var transcriptSpans: [String]

    // Schema v2: typed transcript segments
    var segments: [MeetingTranscriptSegment]

    // Schema v2: meeting metadata
    var participants: [MeetingParticipant]
    var agenda: [MeetingAgendaItem]
    var objectives: [MeetingObjective]
    var contextBackground: String?
    var manualNotes: String?

    // Schema v2: explicit privacy/intelligence settings
    var privacySettings: MeetingPrivacySettings

    // Build 19: optional snapshot for cloud cleanup and meeting tools. Nil
    // means the meeting predates the feature and must remain unchanged.
    var intelligenceConfiguration: MeetingIntelligenceConfiguration?

    // Schema v3: durable post-meeting cleanup history. The canonical
    // `segments` array above is never overwritten by a cleanup revision.
    var cleanupJobs: [MeetingCleanupJob]
    var cleanupRevisions: [MeetingCleanupRevision]
    var activeCleanupRevisionID: String?

    // Existing fields (unchanged)
    var summaryText: String?
    var actionItemsText: String?
    var audioSegments: [String]
    /// #294 (3864858081): per-chunk boundary metadata (offsets + overlap),
    /// persisted so the recovery path can apply overlap dedup and populate
    /// span timestamps even after the recorder is gone.
    var chunkBoundaries: [MeetingChunkBoundary]
    var activeJournal: MeetingActiveJournal?
    var events: [String]
    var exportPath: String?
    var modelProviderMetadata: [String: String]

    init(
        meetingID: String = UUID().uuidString,
        title: String,
        workspaceID: String? = nil,
        state: MeetingSessionState = .setup,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        sources: [MeetingSourceMetadata] = [],
        retentionPolicy: MeetingRetentionPolicy = .keepUntilDeleted,
        aiMode: MeetingAIMode = .transcriptionOnly,
        lastCompletedSegmentIndex: Int = 0,
        transcriptSpans: [String] = [],
        segments: [MeetingTranscriptSegment] = [],
        participants: [MeetingParticipant] = [],
        agenda: [MeetingAgendaItem] = [],
        objectives: [MeetingObjective] = [],
        contextBackground: String? = nil,
        manualNotes: String? = nil,
        privacySettings: MeetingPrivacySettings = MeetingPrivacySettings(),
        intelligenceConfiguration: MeetingIntelligenceConfiguration? = nil,
        cleanupJobs: [MeetingCleanupJob] = [],
        cleanupRevisions: [MeetingCleanupRevision] = [],
        activeCleanupRevisionID: String? = nil,
        audioSegments: [String] = [],
        chunkBoundaries: [MeetingChunkBoundary] = [],
        activeJournal: MeetingActiveJournal? = nil,
        events: [String] = [],
        exportPath: String? = nil,
        modelProviderMetadata: [String: String] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.meetingID = meetingID
        self.title = title
        self.workspaceID = workspaceID
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sources = sources
        self.retentionPolicy = retentionPolicy
        self.aiMode = aiMode
        self.lastCompletedSegmentIndex = lastCompletedSegmentIndex
        self.transcriptSpans = transcriptSpans
        self.segments = segments
        self.participants = participants
        self.agenda = agenda
        self.objectives = objectives
        self.contextBackground = contextBackground
        self.manualNotes = manualNotes
        self.privacySettings = privacySettings
        self.intelligenceConfiguration = intelligenceConfiguration
        self.cleanupJobs = cleanupJobs
        self.cleanupRevisions = cleanupRevisions
        self.activeCleanupRevisionID = activeCleanupRevisionID
        self.audioSegments = audioSegments
        self.chunkBoundaries = chunkBoundaries
        self.activeJournal = activeJournal
        self.events = events
        self.exportPath = exportPath
        self.modelProviderMetadata = modelProviderMetadata
    }
}

// MARK: - Codable with schema migration

extension MeetingManifest {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, meetingID, title, workspaceID, state
        case startedAt, endedAt, sources, retentionPolicy, aiMode
        case lastCompletedSegmentIndex, transcriptSpans, summaryText, actionItemsText
        case audioSegments, chunkBoundaries, activeJournal, events, exportPath, modelProviderMetadata
        // Schema v2 fields
        case segments, participants, agenda, objectives
        case contextBackground, manualNotes, privacySettings
        case captureMode, captureStatus, audioArtifacts, activeSourceJournals, transcribedArtifactIDs, rawArtifactSegments
        case intelligenceConfiguration
        // Schema v3 fields
        case cleanupJobs, cleanupRevisions, activeCleanupRevisionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0

        // v0/v1 fields (all use decodeIfPresent for migration safety)
        meetingID = try container.decode(String.self, forKey: .meetingID)
        title = try container.decode(String.self, forKey: .title)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        state = try container.decode(MeetingSessionState.self, forKey: .state)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        captureMode = try container.decodeIfPresent(MeetingCaptureMode.self, forKey: .captureMode) ?? .inPerson
        captureStatus = try container.decodeIfPresent(MeetingCaptureStatus.self, forKey: .captureStatus) ?? .full
        audioArtifacts = try container.decodeIfPresent([MeetingAudioArtifact].self, forKey: .audioArtifacts) ?? []
        activeSourceJournals = try container.decodeIfPresent([String: MeetingActiveJournal].self, forKey: .activeSourceJournals) ?? [:]
        transcribedArtifactIDs = try container.decodeIfPresent([String].self, forKey: .transcribedArtifactIDs) ?? []
        rawArtifactSegments = try container.decodeIfPresent([String: [MeetingTranscriptSegment]].self, forKey: .rawArtifactSegments) ?? [:]
        sources = try container.decodeIfPresent([MeetingSourceMetadata].self, forKey: .sources) ?? []
        retentionPolicy = try container.decodeIfPresent(MeetingRetentionPolicy.self, forKey: .retentionPolicy) ?? .keepUntilDeleted
        aiMode = try container.decodeIfPresent(MeetingAIMode.self, forKey: .aiMode) ?? .transcriptionOnly
        lastCompletedSegmentIndex = try container.decodeIfPresent(Int.self, forKey: .lastCompletedSegmentIndex) ?? 0
        transcriptSpans = try container.decodeIfPresent([String].self, forKey: .transcriptSpans) ?? []
        summaryText = try container.decodeIfPresent(String.self, forKey: .summaryText)
        actionItemsText = try container.decodeIfPresent(String.self, forKey: .actionItemsText)
        audioSegments = try container.decodeIfPresent([String].self, forKey: .audioSegments) ?? []
        chunkBoundaries = try container.decodeIfPresent([MeetingChunkBoundary].self, forKey: .chunkBoundaries) ?? []
        activeJournal = try container.decodeIfPresent(MeetingActiveJournal.self, forKey: .activeJournal)
        events = try container.decodeIfPresent([String].self, forKey: .events) ?? []
        exportPath = try container.decodeIfPresent(String.self, forKey: .exportPath)
        modelProviderMetadata = try container.decodeIfPresent([String: String].self, forKey: .modelProviderMetadata) ?? [:]

        // Schema v2 fields — absent in v0/v1 manifests, default to empty
        segments = try container.decodeIfPresent([MeetingTranscriptSegment].self, forKey: .segments) ?? []
        participants = try container.decodeIfPresent([MeetingParticipant].self, forKey: .participants) ?? []
        agenda = try container.decodeIfPresent([MeetingAgendaItem].self, forKey: .agenda) ?? []
        objectives = try container.decodeIfPresent([MeetingObjective].self, forKey: .objectives) ?? []
        contextBackground = try container.decodeIfPresent(String.self, forKey: .contextBackground)
        manualNotes = try container.decodeIfPresent(String.self, forKey: .manualNotes)
        privacySettings = try container.decodeIfPresent(MeetingPrivacySettings.self, forKey: .privacySettings) ?? MeetingPrivacySettings()
        intelligenceConfiguration = try container.decodeIfPresent(
            MeetingIntelligenceConfiguration.self,
            forKey: .intelligenceConfiguration
        )

        // Schema v3 fields — old meetings migrate with no cleanup history.
        cleanupJobs = try container.decodeIfPresent([MeetingCleanupJob].self, forKey: .cleanupJobs) ?? []
        cleanupRevisions = try container.decodeIfPresent([MeetingCleanupRevision].self, forKey: .cleanupRevisions) ?? []
        activeCleanupRevisionID = try container.decodeIfPresent(String.self, forKey: .activeCleanupRevisionID)

        // Migration: bump to current version. Legacy transcriptSpans are
        // preserved verbatim — no auto-conversion to typed segments.
        schemaVersion = max(decodedVersion, Self.currentSchemaVersion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encode(state, forKey: .state)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(captureMode, forKey: .captureMode)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(audioArtifacts, forKey: .audioArtifacts)
        try container.encode(activeSourceJournals, forKey: .activeSourceJournals)
        try container.encode(transcribedArtifactIDs, forKey: .transcribedArtifactIDs)
        try container.encode(rawArtifactSegments, forKey: .rawArtifactSegments)
        try container.encode(sources, forKey: .sources)
        try container.encode(retentionPolicy, forKey: .retentionPolicy)
        try container.encode(aiMode, forKey: .aiMode)
        try container.encode(lastCompletedSegmentIndex, forKey: .lastCompletedSegmentIndex)
        // Legacy transcriptSpans preserved verbatim
        try container.encode(transcriptSpans, forKey: .transcriptSpans)
        // Schema v2 fields
        try container.encode(segments, forKey: .segments)
        try container.encode(participants, forKey: .participants)
        try container.encode(agenda, forKey: .agenda)
        try container.encode(objectives, forKey: .objectives)
        try container.encodeIfPresent(contextBackground, forKey: .contextBackground)
        try container.encodeIfPresent(manualNotes, forKey: .manualNotes)
        try container.encode(privacySettings, forKey: .privacySettings)
        try container.encodeIfPresent(intelligenceConfiguration, forKey: .intelligenceConfiguration)
        // Schema v3 fields
        try container.encode(cleanupJobs, forKey: .cleanupJobs)
        try container.encode(cleanupRevisions, forKey: .cleanupRevisions)
        try container.encodeIfPresent(activeCleanupRevisionID, forKey: .activeCleanupRevisionID)
        // Remaining existing fields
        try container.encodeIfPresent(summaryText, forKey: .summaryText)
        try container.encodeIfPresent(actionItemsText, forKey: .actionItemsText)
        try container.encode(audioSegments, forKey: .audioSegments)
        try container.encode(chunkBoundaries, forKey: .chunkBoundaries)
        try container.encodeIfPresent(activeJournal, forKey: .activeJournal)
        try container.encode(events, forKey: .events)
        try container.encodeIfPresent(exportPath, forKey: .exportPath)
        try container.encode(modelProviderMetadata, forKey: .modelProviderMetadata)
    }
}
