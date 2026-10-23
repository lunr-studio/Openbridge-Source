import Foundation

enum PermissionKind: String, CaseIterable, Hashable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            return "Needed to record your dictation audio."
        case .accessibility:
            return "Needed to paste transcribed text into the active app."
        case .inputMonitoring:
            return "Needed to detect OpenBridge shortcuts while the app runs."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }
}

enum PermissionStateValue: String {
    case granted
    case needsAttention
    case unknown

    var label: String {
        switch self {
        case .granted:
            return "Granted"
        case .needsAttention:
            return "Needs attention"
        case .unknown:
            return "Unknown"
        }
    }
}

struct PermissionState: Identifiable {
    let kind: PermissionKind
    let value: PermissionStateValue

    var id: String { kind.id }
}

enum TranscriptionCleanupMode: String, CaseIterable, Identifiable {
    case off
    case fast
    case careful

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .fast:
            return "Fast"
        case .careful:
            return "Careful"
        }
    }

    var summary: String {
        switch self {
        case .off:
            return "Fastest. Uses Whisper plus vocabulary and formatting only."
        case .fast:
            // Wave-17 (3838661484): truthful copy - both Fast and Careful
            // currently run the SAME full-transcript cleanup pass; Fast does
            // not repair only low-confidence segments. Mode-differentiated
            // behavior is #321 scope.
            return "Runs the local MLX Gemma full-transcript cleanup pass after Stop (same pass as Careful today)."
        case .careful:
            return "Runs the local MLX Gemma full-transcript cleanup pass after Stop (same pass as Fast today)."
        }
    }

    var usesLocalLLM: Bool {
        localLLMModel != nil
    }

    var localLLMModel: String? {
        switch self {
        case .off:
            return nil
        case .fast:
            return "mlx-community/gemma-3-4b-it-qat-4bit"
        case .careful:
            return "mlx-community/gemma-3-4b-it-qat-4bit"
        }
    }

    var usesOllama: Bool {
        usesLocalLLM
    }

    var ollamaModel: String? {
        localLLMModel
    }
}

enum TranscriptionPerformanceMode: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case accurate
    case experimental
    case custom

    var id: String { rawValue }

    static let selectableModes: [TranscriptionPerformanceMode] = [
        .fast,
        .balanced,
        .accurate,
        .experimental,
    ]

    var title: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .accurate:
            return "Accurate"
        case .experimental:
            return "Experimental"
        case .custom:
            return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .fast:
            return "Lowest latency for quick notes and everyday dictation."
        case .balanced:
            return "Stable daily mode: Whisper Base with fast local cleanup."
        case .accurate:
            return "Heavier local transcription and careful cleanup for important or longer text."
        case .experimental:
            return "Approved V2 Parakeet default with Whisper Base fallback."
        case .custom:
            return "Manual model or cleanup settings are active."
        }
    }

    var useCase: String {
        switch self {
        case .fast:
            return "Quick notes"
        case .balanced:
            return "Daily dictation"
        case .accurate:
            return "Important text"
        case .experimental:
            return "V2 default"
        case .custom:
            return "Manual setup"
        }
    }

    var targetModelIdentifier: String? {
        switch self {
        case .fast:
            return "whisper-tiny"
        case .balanced:
            return "whisper-base"
        case .accurate:
            return "whisper-large-v3"
        case .experimental:
            return "parakeet-tdt-0.6b-v3-mlx-bf16"
        case .custom:
            return nil
        }
    }

    var targetCleanupMode: TranscriptionCleanupMode? {
        switch self {
        case .fast:
            return .off
        case .balanced:
            return .fast
        case .accurate:
            return .careful
        case .experimental:
            return .off
        case .custom:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .fast:
            return "bolt.fill"
        case .balanced:
            return "dial.medium"
        case .accurate:
            return "target"
        case .experimental:
            return "testtube.2"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    var isSelectable: Bool {
        targetModelIdentifier != nil && targetCleanupMode != nil
    }

    static func inferred(
        modelIdentifier: String,
        cleanupMode: TranscriptionCleanupMode
    ) -> TranscriptionPerformanceMode {
        if modelIdentifier == "whisper-tiny", cleanupMode == .off {
            return .fast
        }
        if modelIdentifier == "whisper-base", cleanupMode == .fast {
            return .balanced
        }
        if modelIdentifier == "whisper-large-v3", cleanupMode == .careful {
            return .accurate
        }
        if modelIdentifier.localizedCaseInsensitiveContains("parakeet") {
            return .experimental
        }
        return .custom
    }
}

struct MicrophoneDevice: Identifiable, Equatable {
    static let systemDefaultID = "system-default"

    let id: String
    let displayName: String
    let detail: String?
    let transportLabel: String?
    let isSystemDefault: Bool
    let isBluetooth: Bool

    var pickerTitle: String {
        if let detail, !detail.isEmpty {
            return "\(displayName) - \(detail)"
        }
        return displayName
    }

    var diagnosticWarning: String? {
        guard isBluetooth else { return nil }
        return "Bluetooth microphones can take a moment to wake up. If the first second is quiet, try again or choose a built-in or USB microphone."
    }
}

struct MicrophoneMeterSample: Equatable {
    let averagePowerDecibels: Float
    let peakPowerDecibels: Float
    let normalizedLevel: Double

    static let silent = MicrophoneMeterSample(
        averagePowerDecibels: -160,
        peakPowerDecibels: -160,
        normalizedLevel: 0
    )
}

struct DictationHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let transcript: String
    let createdAt: Date
    let durationSeconds: TimeInterval?
    let modelIdentifier: String
    let modelLabel: String?
    let sourceApplication: String?

    init(
        id: UUID = UUID(),
        transcript: String,
        createdAt: Date = Date(),
        durationSeconds: TimeInterval?,
        modelIdentifier: String,
        modelLabel: String?,
        sourceApplication: String?
    ) {
        self.id = id
        self.transcript = transcript
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.modelIdentifier = modelIdentifier
        self.modelLabel = modelLabel
        self.sourceApplication = sourceApplication
    }
}

enum MediaTranscriptVariant: String, CaseIterable, Identifiable {
    case original, cleaned
    var id: String { rawValue }
    var title: String { self == .original ? "Original" : "Cleaned" }
}

struct MediaTranscriptionResult: Equatable, Identifiable {
    let id: UUID
    let sourceName: String
    let transcript: String
    /// Unmodified speech-recognition output; absent for legacy engines.
    let originalText: String?
    let modelLabel: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceName: String,
        transcript: String,
        originalText: String? = nil,
        modelLabel: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceName = sourceName
        self.transcript = transcript
        self.originalText = originalText
        self.modelLabel = modelLabel
        self.createdAt = createdAt
    }

    var hasOriginalTranscript: Bool { originalText != nil }

    var hasCleanedTranscript: Bool {
        guard let originalText else { return false }
        return originalText != transcript
    }

    func text(for variant: MediaTranscriptVariant) -> String {
        switch variant {
        case .original: originalText ?? transcript
        case .cleaned: transcript
        }
    }

    var defaultFileName: String {
        let stem = (sourceName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = stem.isEmpty ? "OpenBridge transcript" : stem
        return "\(baseName) transcript.txt"
    }
}

struct Snippet: Codable, Equatable, Identifiable {
    let id: UUID
    var triggerPhrase: String
    var expansionText: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        triggerPhrase: String,
        expansionText: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.triggerPhrase = triggerPhrase
        self.expansionText = expansionText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CommandModePreset: Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let instruction: String
    let systemImage: String

    static let quickMenuPresetIDs = [
        "concise",
        "professional",
        "friendly",
        "translate",
    ]

    static let defaults: [CommandModePreset] = [
        CommandModePreset(
            id: "clean-text",
            title: "Clean Text",
            summary: "Fix punctuation and dictation artifacts.",
            instruction: "Clean spelling, punctuation, spacing, repeated filler words, and obvious dictation artifacts while preserving the original meaning and tone.",
            systemImage: "wand.and.stars"
        ),
        CommandModePreset(
            id: "polish-message",
            title: "Polish Message",
            summary: "Turn rough text into a clear email or message.",
            instruction: "Rewrite this as a clear, concise email or message. Keep it natural, polite, and faithful to the original meaning.",
            systemImage: "envelope"
        ),
        CommandModePreset(
            id: "format-notes",
            title: "Format Notes",
            summary: "Structure dictation into readable notes.",
            instruction: "Format this into clear notes with short headings or bullets where helpful. Preserve the original facts and avoid adding new information.",
            systemImage: "note.text"
        ),
        CommandModePreset(
            id: "code-comment-cleanup",
            title: "Code Comment",
            summary: "Clean developer notes without changing code.",
            instruction: "Clean up comments, commit notes, or developer-facing prose. If code is included, keep the code behavior unchanged and only improve comments, wording, or formatting.",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ),
        CommandModePreset(
            id: "concise",
            title: "Concise",
            summary: "Shorten without losing the point.",
            instruction: "Make this shorter and more concise while preserving the key meaning.",
            systemImage: "text.alignleft"
        ),
        CommandModePreset(
            id: "professional",
            title: "Professional",
            summary: "Make it polished and work-ready.",
            instruction: "Rewrite this in a clear, professional tone while preserving the original meaning.",
            systemImage: "briefcase"
        ),
        CommandModePreset(
            id: "friendly",
            title: "Friendly",
            summary: "Warm up the tone.",
            instruction: "Rewrite this in a warmer, friendlier tone while preserving the original meaning.",
            systemImage: "face.smiling"
        ),
        CommandModePreset(
            id: "translate",
            title: "Translate",
            summary: "Translate into clear English.",
            instruction: "Translate this into clear natural English. If it is already English, make it clearer without changing the meaning.",
            systemImage: "globe"
        ),
        CommandModePreset(
            id: "summarize",
            title: "Summarize",
            summary: "Extract the main point.",
            instruction: "Summarize this into the clearest useful version while preserving the main point.",
            systemImage: "list.bullet.rectangle"
        ),
        CommandModePreset(
            id: "outline",
            title: "Outline",
            summary: "Turn it into structure.",
            instruction: "Expand this into a clear outline with concise bullet points and logical structure.",
            systemImage: "list.bullet.indent"
        ),
        CommandModePreset(
            id: "grammar",
            title: "Fix Grammar",
            summary: "Clean spelling and grammar.",
            instruction: "Fix spelling, punctuation, and grammar while preserving the original meaning and tone.",
            systemImage: "checkmark.seal"
        ),
    ]
}

enum SnippetMutationResult: Equatable {
    case saved
    case emptyTrigger
    case emptyExpansion
    case duplicateTrigger
    case storageFailed(String)

    var message: String? {
        switch self {
        case .saved:
            return nil
        case .emptyTrigger:
            return "Enter a trigger phrase."
        case .emptyExpansion:
            return "Enter expansion text."
        case .duplicateTrigger:
            return "A snippet with this trigger already exists."
        case .storageFailed(let details):
            return "Snippet could not be saved: \(details)"
        }
    }
}

enum DictationRecordingMode: Equatable {
    case standard
    case handsFree
    case commandMode
}

enum DictationHistoryRetentionMode: String, CaseIterable, Identifiable {
    case storeNormally
    case autoDeleteAfter24Hours
    case neverStore

    static let privacyFirstOptions: [DictationHistoryRetentionMode] = [
        .autoDeleteAfter24Hours,
        .neverStore,
        .storeNormally,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storeNormally:
            return "Store normally"
        case .autoDeleteAfter24Hours:
            return "Auto-delete after 24 hours"
        case .neverStore:
            return "Never store"
        }
    }

    var summary: String {
        switch self {
        case .storeNormally:
            return "Keep successful dictations until you delete them."
        case .autoDeleteAfter24Hours:
            return "Keep only recent dictations and remove older entries automatically."
        case .neverStore:
            return "Do not save dictation history on this Mac."
        }
    }
}

struct HistoryRetentionStartupState: Equatable {
    let mode: DictationHistoryRetentionMode
    let choiceMade: Bool
    let shouldPersistMigration: Bool
}

enum HistoryRetentionStartupResolver {
    static func resolve(
        storedModeRawValue: String?,
        storedChoiceMade: Bool?,
        historyFileExists: Bool,
        onboardingCompleted: Bool
    ) -> HistoryRetentionStartupState {
        if let storedModeRawValue,
           let storedMode = DictationHistoryRetentionMode(rawValue: storedModeRawValue) {
            return HistoryRetentionStartupState(
                mode: storedMode,
                choiceMade: storedChoiceMade ?? true,
                shouldPersistMigration: storedChoiceMade == nil
            )
        }

        if historyFileExists || onboardingCompleted {
            return HistoryRetentionStartupState(
                mode: .storeNormally,
                choiceMade: true,
                shouldPersistMigration: true
            )
        }

        return HistoryRetentionStartupState(
            mode: .neverStore,
            choiceMade: false,
            shouldPersistMigration: false
        )
    }
}

enum FlowBarPhase: Equatable {
    case hidden
    case listening
    case processing
    case success(String)
    case cancelled
    case error(String)

    var isVisible: Bool {
        self != .hidden
    }
}

enum FlowBarContext: Equatable {
    case dictation
    case handsFree
    case commandMode
}

enum FlowBarProcessingStep: Equatable {
    case capturingSelection
    case transcribing
    case transformingSelection
    case replacingSelection
}

struct CuratedModel: Decodable, Identifiable {
    let identifier: String
    let repoID: String
    let displayName: String
    let summary: String
    let runtime: String?
    let autoManage: Bool?

    enum CodingKeys: String, CodingKey {
        case identifier
        case repoID = "repo_id"
        case displayName = "display_name"
        case summary
        case runtime
        case autoManage = "auto_manage"
    }

    var id: String { identifier }

    var isManagedAutomatically: Bool { autoManage ?? true }

    var isParakeetCandidate: Bool {
        identifier.localizedCaseInsensitiveContains("parakeet")
    }
}

struct InstalledModel: Decodable, Identifiable {
    let identifier: String
    let repoID: String
    let displayName: String
    let summary: String
    let runtime: String?
    let autoManage: Bool?
    let installed: Bool
    let path: String?

    enum CodingKeys: String, CodingKey {
        case identifier
        case repoID = "repo_id"
        case displayName = "display_name"
        case summary
        case runtime
        case autoManage = "auto_manage"
        case installed
        case path
    }

    var id: String { identifier }

    var isManagedAutomatically: Bool { autoManage ?? true }

    var isParakeetCandidate: Bool {
        identifier.localizedCaseInsensitiveContains("parakeet")
    }
}

struct EngineDoctor: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let curatedModels: [CuratedModel]
    let installedModels: [InstalledModel]
    let defaultModelId: String
    let dependencies: EngineDependencies
    let localLlm: EngineLocalLLMStatus?
    let commands: EngineCommands?
}

struct EngineDependencies: Decodable {
    let python: String
    let mlxWhisper: Bool
    let mlxLm: Bool?
    let huggingfaceHub: Bool
    let transformers: Bool?
    let torch: Bool?
    let parakeetTransformers: Bool?
    let parakeetMlx: Bool?

    enum CodingKeys: String, CodingKey {
        case python
        case mlxWhisper = "mlx_whisper"
        case mlxLm = "mlx_lm"
        case huggingfaceHub = "huggingface_hub"
        case transformers
        case torch
        case parakeetTransformers = "parakeet_transformers"
        case parakeetMlx = "parakeet_mlx"
    }
}

struct EngineLocalLLMStatus: Decodable {
    let defaultProvider: String
    let mlxAvailable: Bool
    let mlxDefaultModel: String
    let mlxDefaultModelPresent: Bool?
    let mlxCarefulModel: String
    let mlxCarefulModelPresent: Bool?
    let ollamaAvailable: Bool
    let ollamaDefaultModel: String
    let cacheRoot: String
}

struct EngineCommands: Decodable {
    let ffmpeg: Bool
    let ollama: Bool
}

struct EngineModelInstallResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let model: InstalledModel
}

struct EngineTranscriptResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let transcript: TranscriptPayload
}

struct EngineMediaTranscriptResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let transcript: TranscriptPayload
    let media: EngineMediaPayload
}

struct EngineMediaPayload: Decodable {
    let sourcePath: String
    let sourceName: String
}

struct EngineCommandModeResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let transformedText: String
    let commandMode: CommandModePayload
}

struct CommandModePayload: Decodable {
    let provider: String
    let model: String
    let inputCharacters: Int
}

struct TranscriptSpanPayload: Decodable, Equatable, Sendable {
    let startOffset: TimeInterval?
    let endOffset: TimeInterval?
    let text: String

    init(startOffset: TimeInterval? = nil, endOffset: TimeInterval? = nil, text: String) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.text = text
    }
}

struct TranscriptPayload: Decodable, Sendable {
    let text: String
    let originalText: String?
    let lowConfidenceSegments: [String]
    let modelLabel: String
    let modelPath: String
    let spans: [TranscriptSpanPayload]
    let modelRuntime: String?
    let requestedModel: String?
    let fallbackUsed: Bool
    let fallbackReason: String?

    init(
        text: String,
        originalText: String? = nil,
        lowConfidenceSegments: [String] = [],
        modelLabel: String = "",
        modelPath: String = "",
        spans: [TranscriptSpanPayload] = [],
        modelRuntime: String? = nil,
        requestedModel: String? = nil,
        fallbackUsed: Bool = false,
        fallbackReason: String? = nil
    ) {
        self.text = text
        self.originalText = originalText
        self.lowConfidenceSegments = lowConfidenceSegments
        self.modelLabel = modelLabel
        self.modelPath = modelPath
        self.spans = spans
        self.modelRuntime = modelRuntime
        self.requestedModel = requestedModel
        self.fallbackUsed = fallbackUsed
        self.fallbackReason = fallbackReason
    }

    private enum CodingKeys: String, CodingKey {
        case text, originalText, lowConfidenceSegments, modelLabel, modelPath, spans
        case modelRuntime, requestedModel, fallbackUsed, fallbackReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText)
        lowConfidenceSegments = try container.decodeIfPresent([String].self, forKey: .lowConfidenceSegments) ?? []
        modelLabel = try container.decodeIfPresent(String.self, forKey: .modelLabel) ?? ""
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        spans = try container.decodeIfPresent([TranscriptSpanPayload].self, forKey: .spans) ?? []
        modelRuntime = try container.decodeIfPresent(String.self, forKey: .modelRuntime)
        requestedModel = try container.decodeIfPresent(String.self, forKey: .requestedModel)
        fallbackUsed = try container.decodeIfPresent(Bool.self, forKey: .fallbackUsed) ?? false
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
    }
}

struct EngineModelsListResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let curatedModels: [CuratedModel]
    let installedModels: [InstalledModel]
}

struct EngineWarmModelResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let model: EngineResolvedModel
}

struct EngineReadinessResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let readiness: EngineReadinessPayload
}

struct EngineReadinessPayload: Decodable {
    let ready: Bool
    let summary: String
    let checks: [EngineReadinessCheck]
    let speechModel: EngineReadinessSpeechModel
    let cleanup: EngineReadinessCleanup
    let resources: EngineReadinessResources

    var blockingRecoveryMessage: String? {
        checks.first { $0.state == "fail" && $0.blocking }?.recovery
    }

    var displayChecks: [EngineReadinessCheck] {
        checks.filter { $0.state != "pass" }
    }
}

struct EngineReadinessCheck: Decodable, Identifiable {
    let id: String
    let title: String
    let state: String
    let message: String
    let recovery: String?
    let blocking: Bool
}

struct EngineReadinessSpeechModel: Decodable {
    let identifier: String
    let displayName: String
    let runtime: String?
    let runtimeSupported: Bool?
    let fallbackIdentifier: String?
    let fallbackReady: Bool?
    let installed: Bool
    let path: String?
    let loadChecked: Bool
    let loadOK: Bool?
    let inferenceChecked: Bool
    let inferenceOK: Bool?
}

struct EngineReadinessCleanup: Decodable {
    let mode: String
    let enabled: Bool
    let model: String?
    let available: Bool
    let modelPresent: Bool
    let provider: String?
}

struct EngineReadinessResources: Decodable {
    let freeDiskBytes: Int?
    let requiredDiskBytes: Int
    let totalMemoryBytes: Int?
    let recommendedMemoryBytes: Int
}

struct EngineResolvedModel: Decodable {
    let path: String
    let label: String
}

struct EngineErrorResponse: Decodable {
    let ok: Bool
    let schemaVersion: Int?
    let error: String
    let code: String?
    let details: String?

    var displayMessage: String {
        guard let details, !details.isEmpty else {
            return error
        }
        return "\(error) Details: \(details)"
    }
}
