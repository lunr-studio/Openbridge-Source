import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers
import OpenBridgeUI

enum MicrophoneDiagnosticsOwner: Hashable {
    case mainDictationPreferences
    case settings
}

struct ResearchActiveMeetingContext: Equatable {
    let meetingID: String
    let workspaceID: String
    let allowsCloud: Bool

    static func resolve(
        activeMeetingID: String?,
        store: MeetingSessionStore
    ) -> ResearchActiveMeetingContext? {
        guard let activeMeetingID else { return nil }
        guard let meeting = try? store.load(meetingID: activeMeetingID) else {
            // Preserve source identity but fail closed on workspace/cloud when
            // the active manifest cannot be read.
            return ResearchActiveMeetingContext(
                meetingID: activeMeetingID,
                workspaceID: Workspace.defaultWorkspace.id,
                allowsCloud: false
            )
        }
        return ResearchActiveMeetingContext(
            meetingID: meeting.meetingID,
            workspaceID: meeting.workspaceID ?? Workspace.defaultWorkspace.id,
            allowsCloud: meeting.aiMode.maySendTranscriptToCloud
                && meeting.privacySettings.allowsCloudIntelligence
                && meeting.intelligenceConfiguration?.cloudProvider != nil
        )
    }
}

@MainActor
final class AppState: ObservableObject {
    /// Single Release-compatible Observatory coordinator owned at app level.
    let observatory: ObservatoryCoordinator
    let meetingResearch: MeetingResearchController
    static var sharedMeetingResearch: MeetingResearchController?

    /// Static handle for the rail bridge (avoids constructing AppState).
    static var sharedObservatoryForRail: ObservatoryCoordinator?

    @Published private(set) var isResearchIndexing = false
    private var researchReindexTask: Task<Void, Never>?
    private var researchReindexID: UUID?

    /// Applies the user-visible Beta switch. Expensive indexing begins only
    /// after opt-in; disabling immediately cancels session work and clears
    /// the in-memory rail state.
    func setResearchRailEnabled(_ enabled: Bool) {
        ResearchObservatoryFeatureFlag.setEnabled(enabled)
        meetingResearch.setEnabled(enabled)
        if enabled {
            let store = MeetingSessionStore()
            startResearchReindex()
            if let context = ResearchActiveMeetingContext.resolve(
                activeMeetingID: activeMeetingID,
                store: store
            ) {
                observatory.setMeetingContext(
                    meetingID: context.meetingID,
                    workspaceID: context.workspaceID,
                    allowsCloud: context.allowsCloud
                )
            }
        } else {
            researchReindexTask?.cancel()
            researchReindexTask = nil
            researchReindexID = nil
            isResearchIndexing = false
            observatory.endOfMeeting()
        }
    }

    /// Manifest decoding and SQLite replacement are blocking filesystem work.
    /// Keep them off the main actor so enabling the Beta cannot freeze the UI.
    private func startResearchReindex() {
        researchReindexTask?.cancel()
        let operationID = UUID()
        researchReindexID = operationID
        isResearchIndexing = true
        let index = ObservatorySharedIndex.shared
        researchReindexTask = Task.detached(priority: .utility) { [weak self] in
            ObservatorySharedIndex.reindexAllSavedMeetings(
                index: index,
                shouldCancel: { Task.isCancelled }
            )
            await self?.finishResearchReindex(operationID: operationID)
        }
    }

    private func finishResearchReindex(operationID: UUID) {
        guard researchReindexID == operationID else { return }
        researchReindexTask = nil
        researchReindexID = nil
        isResearchIndexing = false
    }

    /// #219: app-scoped handle for provider-failure isolation
    /// (RecoveryActionRouter.recordProviderFailure) and the active-meeting
    /// context surfaced to recovery. NOT DEBUG-gated — recovery behavior
    /// ships in Release.
    static weak var shared: AppState?

    /// #219: the currently recording meeting (set by the Meetings flow) —
    /// provider failures during a recording are recorded against it.
    @Published var activeMeetingID: String?

    /// #219: relaunch detection results (incomplete sessions + interrupted
    /// cleanups) — published so the Meetings page can surface them.
    @Published var recoverySurfacedMeetingIDs: [String] = []

    /// #219 (review): the owned recovery-transcription task — non-nil while
    /// a recovery retry is running. Gates meeting Start and additional
    /// retry clicks so the shared transcriber cannot be reconfigured or
    /// double-driven mid-recovery.
    @Published var recoveryRetryTask: Task<Void, Never>?

    /// #219 (review): which meeting the running retry belongs to — deletion
    /// of that meeting cancels and awaits the task before removing data.
    @Published var activeRecoveryMeetingID: String?

    /// Wave-13/20 (3838167622, 3839624996): cleanup failures published at
    /// APP scope and ACCUMULATED per job until the user reads them - a
    /// later queued job no longer erases an earlier job's unread failure.
    @Published var postStopCleanupFailureMessages: [String] = []

    /// Wave-11 (3837659903): app-scoped Start-in-progress flag. Start
    /// can suspend for a long time (awaiting a terminating cleanup); a
    /// page-scoped guard reset when the user navigated away from
    /// Meetings and returned, allowing a second Start to race the first
    /// into manifest/recorder creation. App scope keeps the guard alive
    /// across navigation for the entire start operation.
    @Published private(set) var isMeetingStarting = false

    /// View-facing mutators for the app-scoped Start guard.
    func beginMeetingStart() { isMeetingStarting = true }
    func endMeetingStart() { isMeetingStarting = false }

    /// Wave-10 (3837632200): app-level ownership of the post-Stop cleanup
    /// task. It must SURVIVE leaving the Meetings section - a page-scoped
    /// handle died with the view while the unstructured Gemma job kept
    /// running, letting a fresh page start recording over it (AGENTS L42).
    var postStopCleanupTask: Task<Void, Never>?
    /// Wave-19 (3839500421): deferred cleanups are QUEUED, never dropped
    /// or cancelled-by-replacement. Sequential AI-enabled meetings each
    /// get their selected cleanup.
    var deferredCleanupQueue: [String] = []
    /// Wave-21 (3839766694): true while a meeting's cleanup is being
    /// cancelled FOR DELETION - suppresses the requeue-on-cancel and
    /// scopes the post-await field clear to the cancelled job only.
    var cleanupDeletionMeetingID: String?

    /// lunr-studio/Openbridge-Beta#321 wave-1 (3884760779): true while a meeting's cleanup is being
    /// cancelled BY THE USER (not for deletion) - suppresses the
    /// requeue-on-cancel so a Cancel reliably stops the cleanup from ever
    /// running again (including after relaunch).
    var cleanupCancelMeetingID: String?

    /// Wave-26 (3842499327): published so gated views (Media, Transforms)
    /// re-render when cleanup ownership changes - the Task handle itself is
    /// not observable.
    @Published var isPostStopCleanupRunning = false

    /// Wave-24 (3840273073): durable record of cleanups the user is OWED
    /// (set at enqueue, cleared when the job actually launches, is
    /// found ineligible, or its meeting is deleted). Reconstruction
    /// re-enqueues ONLY marked meetings - never infers intent from
    /// history.
    @Published var owedCleanupMeetingIDs: [String] =
        UserDefaults.standard.stringArray(forKey: "owedPostStopCleanupMeetingIDs") ?? []

    func markOwedCleanup(_ meetingID: String) {
        if !owedCleanupMeetingIDs.contains(meetingID) {
            owedCleanupMeetingIDs.append(meetingID)
            UserDefaults.standard.set(
                owedCleanupMeetingIDs, forKey: "owedPostStopCleanupMeetingIDs"
            )
        }
    }

    func clearOwedCleanup(_ meetingID: String) {
        if let index = owedCleanupMeetingIDs.firstIndex(of: meetingID) {
            owedCleanupMeetingIDs.remove(at: index)
            UserDefaults.standard.set(
                owedCleanupMeetingIDs, forKey: "owedPostStopCleanupMeetingIDs"
            )
        }
    }

    /// Wave-18/19: the single pump draining `deferredCleanupQueue` when
    /// ALL capture state (dictation and meeting) is clear; one cleanup
    /// owns the engine and the single postStopCleanupTask at a time.
    var deferredCleanupWaiter: Task<Void, Never>?

    /// Wave-15 (3838270706): which meeting the running cleanup belongs
    /// to - deleting that meeting must cancel the cleanup instead of
    /// letting Gemma infer over deleted data and then misreport.
    var postStopCleanupMeetingID: String?

    @Published var permissions: [PermissionState] = PermissionKind.allCases.map { PermissionState(kind: $0, value: .unknown) }
    @Published private(set) var permissionFollowUpKinds: Set<PermissionKind> = []
    @Published var curatedModels: [CuratedModel] = []
    @Published var installedModels: [InstalledModel] = []
    @Published var selectedModelID: String
    @Published private(set) var microphoneDevices: [MicrophoneDevice] = []
    @Published private(set) var selectedMicrophoneID: String
    @Published private(set) var microphoneMeterLevel: Double = 0
    @Published private(set) var microphoneDiagnosticsMessage = "Open Settings to test microphone input."
    @Published var formattingEnabled: Bool
    @Published var vocabularyCorrectionsEnabled: Bool
    @Published private(set) var transcriptionCleanupMode: TranscriptionCleanupMode
    @Published private(set) var transcriptionPerformanceMode: TranscriptionPerformanceMode
    @Published var spokenFormattingCommandsEnabled: Bool
    @Published var pressEnterVoiceCommandEnabled: Bool
    @Published var launchAtLogin: Bool
    @Published var onboardingCompleted: Bool
    @Published private(set) var onboardingDeferredUntil: Date?
    @Published var isInstallingModel = false
    @Published private(set) var isWarmingSelectedModel = false
    @Published private(set) var managedModelStatus = "Checking speech models..."
    @Published private(set) var modelReadinessStatus = "Checking speech model readiness..."
    @Published private(set) var modelReadiness: EngineReadinessPayload?
    @Published private(set) var latestEngineDependencies: EngineDependencies?
    @Published private(set) var isRunningSystemCheck = false
    @Published private(set) var systemCheckReport: SystemCheckReport?
    @Published private(set) var systemCheckMessage = "Run System Check before sending setup details to support."
    @Published var isStartingRecording = false
    /// Reads the existing capture meter; does not start capture or add an audio tap.
    var flowBarInputLevel: Double {
        isRecording ? Double(recorder.currentMeterSample().normalizedLevel) : 0
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isTranscribingMedia = false

    /// True while a meeting recording is active in the Meetings page.
    /// Observed by the sidebar so navigation away from Meetings can be guarded.
    @Published var isMeetingRecording = false
    @Published var statusMessage = "Loading OpenBridge..."
    @Published var foregroundStatus: String?
    @Published var maintenanceStatus: String?
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastTranscriptCreatedAt: Date?
    @Published private(set) var mediaTranscriptionResult: MediaTranscriptionResult?
    @Published private(set) var historyRetentionMode: DictationHistoryRetentionMode
    @Published private(set) var historyRetentionChoiceMade: Bool
    @Published private(set) var dictationHistory: [DictationHistoryEntry] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var customDictionaryEntries: [CustomDictionaryEntry] = []
    @Published private(set) var flowBarRecoveryText: String? = nil
    @Published private(set) var flowBarRecoveryTone: DictationRecoveryTone = .attention
    @Published private(set) var flowBarPhase: FlowBarPhase = .hidden
    @Published private(set) var flowBarContext: FlowBarContext = .dictation
    @Published private(set) var flowBarProcessingStep: FlowBarProcessingStep = .transcribing
    @Published private(set) var flowBarProcessingStartedAt: Date?
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingMode: DictationRecordingMode?
    @Published private(set) var handsFreeWarningMessage: String?
    @Published private(set) var shortcutSettings: ShortcutSettings
    @Published private(set) var shortcutSettingsMessage: String?

    let handsFreeMaxDurationSeconds: TimeInterval = 120
    let handsFreeWarningLeadSeconds: TimeInterval = 15
    private let historyRetentionModeKey = "dictationHistoryRetentionMode"
    private static let historyRetentionChoiceMadeKey = "dictationHistoryRetentionChoiceMade"
    private static let shortcutSettingsKey = "shortcutSettings"
    private static let selectedMicrophoneIDKey = "selectedMicrophoneID"
    private static let selectedModelIDKey = "selectedModelID"
    private static let modelPreferenceSchemaVersionKey = "modelPreferenceSchemaVersion"
    private static let selectedPerformanceModeSourceKey = "selectedPerformanceModeSource"
    private static let defaultSelectedModelID = AppPreferenceMigration.defaultSelectedModelID
    private static let didMigrateLegacyTinyDefaultKey = "didMigrateLegacyTinyDefaultToBase"
    private static let didMigrateLegacyBaseDefaultKey = "didMigrateLegacyBaseDefaultToParakeet"
    private static let modelAutoUpdateLastRunKey = "modelAutoUpdateLastRun"
    private static let modelAutoUpdateInterval: TimeInterval = 24 * 60 * 60
    private static let onboardingCompletedKey = "onboardingCompleted"
    private static let onboardingDeferredUntilKey = "onboardingDeferredUntil"
    private static let pressEnterVoiceCommandEnabledKey = "pressEnterVoiceCommandEnabled"
    private static let spokenFormattingCommandsEnabledKey = "spokenFormattingCommandsEnabled"
    private static let vocabularyCorrectionsEnabledKey = "vocabularyCorrectionsEnabled"
    private static let ollamaSecondPassEnabledKey = "ollamaSecondPassEnabled"
    private static let transcriptionCleanupModeKey = "transcriptionCleanupMode"
    private static let transcriptionPerformanceModeKey = "transcriptionPerformanceMode"

    private let engineService = EngineService()
    private let recorder = AudioRecorderService()
    private let hotkeyService = HotkeyService()
    private let historyStore = DictationHistoryStore()
    private let snippetStore = SnippetStore()
    private let customDictionaryStore = CustomDictionaryStore()
    private var flowBarController: FlowBarWindowController?
    private var flowBarVisibilityTask: Task<Void, Never>?
    private var currentRecordingURL: URL?
    private var recordingSourceApplication: String?
    private var activeCommandModeSession: CommandModeSession?
    private var lastPasteTargetApplication: NSRunningApplication?
    private var activeDictationPasteTarget: DictationPasteTarget?
    private var activationObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var handsFreeLimitTask: Task<Void, Never>?
    private var microphoneDiagnosticsTask: Task<Void, Never>?
    private var microphoneDiagnosticsOwners: Set<MicrophoneDiagnosticsOwner> = []
    private var managedModelTask: Task<Void, Never>?
    private var selectedModelWarmTask: Task<Void, Never>?
    private var microphoneDiagnosticsStartedAt: Date?
    private var microphoneDiagnosticsPeakLevel: Double = 0
    private var processingCancellationRequested = false
    private var latestLocalLLMStatus: EngineLocalLLMStatus?
    private var latestEngineCommands: EngineCommands?

    let braveResearch = BraveResearchSettings()

    init(providerSettings: ProviderSettingsController? = nil) {
        meetingResearch = MeetingResearchController.production(providerSettings: providerSettings, braveResearch: braveResearch)
        Self.sharedMeetingResearch = meetingResearch
        observatory = ObservatoryCoordinator.makeForLiveIntegration(
            providerSettings: providerSettings
        )
        Self.sharedObservatoryForRail = observatory
        // Wave-14 (3838221470) + #219: reconcile durable cleanup jobs left
        // `.running` by a previous session - on relaunch no process can
        // still own them; without this the next coordinator run sees
        // `alreadyRunning` and recovery/retry is blocked. The detection
        // RESULT is now PUBLISHED so the Meetings page surfaces incomplete
        // sessions and interrupted cleanups (previously discarded).
        if let surfaced = try? MeetingSessionStore().detectIncompleteSessions() {
            recoverySurfacedMeetingIDs = surfaced.map(\.meetingID)
        }
        let defaults = UserDefaults.standard
        let storedSelectedModelID = defaults.string(forKey: Self.selectedModelIDKey)
        let didMigrateLegacyTinyDefault = defaults.bool(forKey: Self.didMigrateLegacyTinyDefaultKey)
        let didMigrateLegacyBaseDefault = defaults.bool(forKey: Self.didMigrateLegacyBaseDefaultKey)
        let migrationPlan = AppPreferenceMigration.plan(
            storedSelectedModelID: storedSelectedModelID,
            didMigrateLegacyTinyDefault: didMigrateLegacyTinyDefault,
            didMigrateLegacyBaseDefault: didMigrateLegacyBaseDefault,
            storedPerformanceModeRawValue: defaults.string(forKey: Self.transcriptionPerformanceModeKey),
            storedCleanupModeRawValue: defaults.string(forKey: Self.transcriptionCleanupModeKey),
            storedSchemaVersion: defaults.integer(forKey: Self.modelPreferenceSchemaVersionKey),
            storedPerformanceModeSource: defaults.string(forKey: Self.selectedPerformanceModeSourceKey)
        )
        let initialSelectedModelID = migrationPlan.selectedModelID
        if migrationPlan.shouldPersistAllDefaults {
            // Persist the complete recommended preset atomically.
            defaults.set(initialSelectedModelID, forKey: Self.selectedModelIDKey)
            defaults.set(TranscriptionPerformanceMode.experimental.rawValue, forKey: Self.transcriptionPerformanceModeKey)
            defaults.set(TranscriptionCleanupMode.off.rawValue, forKey: Self.transcriptionCleanupModeKey)
            defaults.set(false, forKey: Self.ollamaSecondPassEnabledKey)
            defaults.set(ModelPreferenceSource.appDefault.rawValue, forKey: Self.selectedPerformanceModeSourceKey)
        } else if migrationPlan.shouldPersistSelectedModelID {
            defaults.set(initialSelectedModelID, forKey: Self.selectedModelIDKey)
        }
        if migrationPlan.shouldApplyParakeetDefaultSettings && !migrationPlan.shouldPersistAllDefaults {
            // Repair path: apply Parakeet defaults without full atomic write.
            defaults.set(TranscriptionPerformanceMode.experimental.rawValue, forKey: Self.transcriptionPerformanceModeKey)
            defaults.set(TranscriptionCleanupMode.off.rawValue, forKey: Self.transcriptionCleanupModeKey)
            defaults.set(false, forKey: Self.ollamaSecondPassEnabledKey)
        }
        if migrationPlan.needsSchemaVersionBump {
            defaults.set(AppPreferenceMigration.currentSchemaVersion, forKey: Self.modelPreferenceSchemaVersionKey)
        }
        self.selectedModelID = initialSelectedModelID
        if migrationPlan.shouldMarkLegacyTinyDefaultMigrated {
            defaults.set(true, forKey: Self.didMigrateLegacyTinyDefaultKey)
        }
        if migrationPlan.shouldMarkLegacyBaseDefaultMigrated {
            defaults.set(true, forKey: Self.didMigrateLegacyBaseDefaultKey)
        }
        self.selectedMicrophoneID = defaults.string(forKey: Self.selectedMicrophoneIDKey) ?? MicrophoneDevice.systemDefaultID
        self.formattingEnabled = defaults.object(forKey: "formattingEnabled") as? Bool ?? true
        self.vocabularyCorrectionsEnabled = defaults.object(forKey: Self.vocabularyCorrectionsEnabledKey) as? Bool ?? true
        let initialCleanupMode: TranscriptionCleanupMode
        if let cleanupMode = TranscriptionCleanupMode(rawValue: defaults.string(forKey: Self.transcriptionCleanupModeKey) ?? "") {
            initialCleanupMode = cleanupMode
        } else if defaults.object(forKey: Self.ollamaSecondPassEnabledKey) != nil {
            initialCleanupMode = defaults.bool(forKey: Self.ollamaSecondPassEnabledKey) ? .fast : .off
        } else {
            initialCleanupMode = .fast
            defaults.set(TranscriptionCleanupMode.fast.rawValue, forKey: Self.transcriptionCleanupModeKey)
            defaults.set(true, forKey: Self.ollamaSecondPassEnabledKey)
        }
        self.transcriptionCleanupMode = initialCleanupMode
        if let performanceMode = TranscriptionPerformanceMode(rawValue: defaults.string(forKey: Self.transcriptionPerformanceModeKey) ?? "") {
            self.transcriptionPerformanceMode = performanceMode
        } else {
            let inferredMode = TranscriptionPerformanceMode.inferred(
                modelIdentifier: initialSelectedModelID,
                cleanupMode: initialCleanupMode
            )
            self.transcriptionPerformanceMode = inferredMode
            defaults.set(inferredMode.rawValue, forKey: Self.transcriptionPerformanceModeKey)
        }
        self.spokenFormattingCommandsEnabled = defaults.bool(forKey: Self.spokenFormattingCommandsEnabledKey)
        self.pressEnterVoiceCommandEnabled = defaults.bool(forKey: Self.pressEnterVoiceCommandEnabledKey)
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        let savedOnboardingCompleted = defaults.bool(forKey: Self.onboardingCompletedKey)
        self.onboardingCompleted = savedOnboardingCompleted
        self.onboardingDeferredUntil = defaults.object(forKey: Self.onboardingDeferredUntilKey) as? Date
        let historyStartupState = HistoryRetentionStartupResolver.resolve(
            storedModeRawValue: defaults.string(forKey: historyRetentionModeKey),
            storedChoiceMade: defaults.object(forKey: Self.historyRetentionChoiceMadeKey) as? Bool,
            historyFileExists: historyStore.hasSavedHistoryFile,
            onboardingCompleted: savedOnboardingCompleted
        )
        self.historyRetentionMode = historyStartupState.mode
        self.historyRetentionChoiceMade = historyStartupState.choiceMade
        if historyStartupState.shouldPersistMigration {
            defaults.set(historyStartupState.mode.rawValue, forKey: historyRetentionModeKey)
            defaults.set(historyStartupState.choiceMade, forKey: Self.historyRetentionChoiceMadeKey)
        }
        self.shortcutSettings = Self.loadShortcutSettings(from: defaults)
        loadSnippets()
        loadCustomDictionary()
        loadDictationHistory()
        refresh()
        startTrackingPasteTargetApplications()
        startRefreshingPermissionsOnAppActivation()
        rememberCurrentPasteTargetApplication()
        configureHotkeys()
        // #219: app-scoped handle for provider-failure isolation — assigned
        // LAST, once self is fully initialized.
        Self.shared = self
        ResearchObservatoryFeatureFlag.clearLegacyInternalValue()
        if ResearchObservatoryFeatureFlag.isEnabled {
            startResearchReindex()
        }
    }

    var readyForDictation: Bool {
        missingPermissionTitles.isEmpty && selectedModelAvailableForTranscription
    }

    var shouldShowOnboardingOnLaunch: Bool {
        guard !onboardingCompleted || historyRetentionNeedsChoice else { return false }
        if let onboardingDeferredUntil, onboardingDeferredUntil > Date() {
            return false
        }
        return true
    }

    var readyForMediaTranscription: Bool {
        selectedModelAvailableForTranscription
    }

    var selectedModelAvailableForTranscription: Bool {
        modelReadiness?.ready ?? selectedModelInstalled
    }

    var selectedModelInstalled: Bool {
        installedModels.contains(where: { $0.identifier == selectedModelID && $0.installed })
    }

    /// Returns the model ID to use for transcription. Uses the selected model
    /// if it's installed; otherwise falls back to the first installed model.
    /// This ensures meeting transcription always works regardless of which
    /// model the user has selected in the UI.
    var transcriptionModelID: String {
        if selectedModelInstalled {
            return selectedModelID
        }
        // Fall back to the first installed model
        if let firstInstalled = installedModels.first(where: { $0.installed }) {
            return firstInstalled.identifier
        }
        // Last resort: use the selected model ID — the engine will
        // resolve it via its own fallback logic
        return selectedModelID
    }

    var userSelectableCuratedModels: [CuratedModel] {
        curatedModels.filter { isUserSelectableModel($0) }
    }

    var userSelectablePerformanceModes: [TranscriptionPerformanceMode] {
        TranscriptionPerformanceMode.selectableModes.filter { isUserSelectablePerformanceMode($0) }
    }

    var parakeetCandidateSelectable: Bool {
        guard let candidate = curatedModels.first(where: \.isParakeetCandidate) else {
            return false
        }
        return isUserSelectableModel(candidate)
    }

    var canChangeSelectedModel: Bool {
        !isStartingRecording && !isRecording && !isTranscribing && !isTranscribingMedia
    }

    var selectedModelSummary: String {
        curatedModels.first { $0.identifier == selectedModelID }?.summary
            ?? "Choose the speech model OpenBridge uses for dictation and media transcription."
    }

    var transcriptionPerformanceModeSummary: String {
        switch transcriptionPerformanceMode {
        case .custom:
            return "Custom setup: \(selectedModelDisplayName) with \(transcriptionCleanupMode.title.lowercased()) cleanup."
        default:
            return transcriptionPerformanceMode.summary
        }
    }

    var selectedModelInstallStatusLabel: String {
        selectedModelInstalled ? "Installed" : "Missing"
    }

    var selectedModelRuntimeStatusLabel: String {
        if isInstallingModel {
            return "Installing"
        }
        if isWarmingSelectedModel {
            return "Warming"
        }
        if let readiness = modelReadiness {
            return readiness.ready ? "Ready" : "Needs attention"
        }
        return selectedModelInstalled ? "Installed" : "Missing"
    }

    var selectedModelRuntimeStatusSummary: String {
        if let readiness = modelReadiness {
            return readiness.summary
        }
        return modelReadinessStatus
    }

    var localCleanupStatusSummary: String {
        guard transcriptionCleanupMode.usesLocalLLM else {
            return "Local cleanup is off for the fastest possible transcription path."
        }
        if modelReadiness?.cleanup.available == true {
            return "\(transcriptionCleanupMode.title) cleanup is available locally."
        }
        return "\(transcriptionCleanupMode.title) cleanup is selected. OpenBridge keeps the original transcript if cleanup is unavailable."
    }

    var parakeetExperimentalStatus: String {
        if let candidate = curatedModels.first(where: \.isParakeetCandidate) {
            return "\(candidate.displayName) is the approved V2 default for Apple silicon. OpenBridge uses Whisper Base as the fallback if the Parakeet runtime or model is not ready."
        }
        return "Parakeet is approved as the V2 default. Whisper Base remains the fallback if the Parakeet runtime or model is not ready."
    }

    var dictationSetupMessage: String {
        setupRequirementMessage(action: "dictating")
    }

    var commandModeSetupMessage: String {
        setupRequirementMessage(action: "using Command Mode")
    }

    var mediaSetupMessage: String {
        readyForMediaTranscription
            ? "Ready to transcribe local audio and video files."
            : modelReadiness?.summary ?? "Install \(selectedModelDisplayName) before transcribing media."
    }

    var hasPasteableLastTranscript: Bool {
        pasteableLastTranscript != nil
    }

    var canStartMediaTranscription: Bool {
        // Wave-22 (3839803895): a running post-Stop cleanup occupies the
        // same local Gemma engine - media transcription must not start (and
        // run a second Fast/Careful pass) until it finishes. The deferred
        // cleanup pump already waits on isTranscribingMedia, so ordering
        // serializes both ways.
        readyForMediaTranscription && !isRecording && !isTranscribing
            && !isStartingRecording && !isTranscribingMedia
            && postStopCleanupTask == nil
    }

    var historyRetentionNeedsChoice: Bool {
        !historyRetentionChoiceMade
    }

    var hotkeyDescription: String {
        shortcutSettings.binding(for: .dictation).displayName
    }

    var handsFreeShortcutDescription: String {
        shortcutSettings.binding(for: .handsFree).displayName
    }

    var cancelShortcutDescription: String {
        shortcutSettings.binding(for: .cancel).displayName
    }

    var pasteLastShortcutDescription: String {
        shortcutSettings.binding(for: .pasteLast).displayName
    }

    var commandModeShortcutDescription: String {
        shortcutSettings.binding(for: .commandMode).displayName
    }

    var commandModePresets: [CommandModePreset] {
        CommandModePreset.defaults
    }

    var quickCommandModePresets: [CommandModePreset] {
        CommandModePreset.quickMenuPresetIDs.compactMap { presetID in
            commandModePresets.first { $0.id == presetID }
        }
    }

    var availableShortcutBindings: [ShortcutBinding] {
        ShortcutBinding.allCases
    }

    var selectedMicrophoneDevice: MicrophoneDevice? {
        microphoneDevices.first { $0.id == selectedMicrophoneID }
    }

    var selectedMicrophoneName: String {
        selectedMicrophoneDevice?.pickerTitle ?? "System Default"
    }

    var microphoneDiagnosticWarning: String? {
        selectedMicrophoneDevice?.diagnosticWarning
    }

    var usesDefaultShortcuts: Bool {
        shortcutSettings == .defaults
    }

    var isStandardRecording: Bool {
        recordingMode == .standard
    }

    var isHandsFreeRecording: Bool {
        recordingMode == .handsFree
    }

    var isCommandModeRecording: Bool {
        recordingMode == .commandMode
    }

    var handsFreeMaxDurationLabel: String {
        Self.durationLabel(for: handsFreeMaxDurationSeconds)
    }

    var handsFreeWarningLeadLabel: String {
        Self.durationLabel(for: handsFreeWarningLeadSeconds)
    }

    var flowBarListeningTitle: String {
        if isHandsFreeRecording {
            return "Hands-free listening privately"
        }
        if isCommandModeRecording {
            return "Command Mode listening"
        }
        return "Listening privately"
    }

    var flowBarListeningDetail: String {
        if isHandsFreeRecording {
            if let handsFreeWarningMessage {
                return handsFreeWarningMessage
            }
            return "Talk naturally. OpenBridge will stop after \(handsFreeMaxDurationLabel) and keep the audio on this Mac."
        }

        if isCommandModeRecording {
            return "Say the edit you want. OpenBridge will only work on the selected text."
        }

        return "Speak now. Your recording stays local while OpenBridge listens."
    }

    var commandModeAIUserLabel: String {
        "OpenBridge AI on your computer"
    }

    var flowBarProcessingTitle: String {
        switch flowBarProcessingStep {
        case .capturingSelection:
            return "Checking selection"
        case .transcribing:
            return flowBarContext == .commandMode ? "Understanding command" : "Preparing transcript"
        case .transformingSelection:
            return "Writing polished edit"
        case .replacingSelection:
            return "Returning text"
        }
    }

    func flowBarProcessingDetail(elapsedSeconds: Int = 0) -> String {
        switch flowBarProcessingStep {
        case .capturingSelection:
            return "Checking the highlighted text before recording your edit command."
        case .transcribing:
            return flowBarContext == .commandMode
                ? commandModeTranscriptionDetail(elapsedSeconds: elapsedSeconds)
                : dictationTranscriptionDetail(elapsedSeconds: elapsedSeconds)
        case .transformingSelection:
            if elapsedSeconds >= 8 {
                return "Still working locally with \(commandModeAIUserLabel). Longer selected text can take a moment."
            }
            return "Using \(commandModeAIUserLabel) to rewrite only the selected text."
        case .replacingSelection:
            return "Putting the rewritten text back into the original app."
        }
    }

    var flowBarAllowsCancellation: Bool {
        isRecording || isTranscribing
    }

    private func dictationTranscriptionDetail(elapsedSeconds: Int) -> String {
        let elapsedLabel = Self.processingElapsedLabel(for: elapsedSeconds)
        if elapsedSeconds < 4 {
            return "Working \(elapsedLabel): saving the recording and starting \(selectedModelDisplayName) locally."
        }

        if elapsedSeconds < 10 {
            return "Working \(elapsedLabel): \(selectedModelDisplayName) is decoding speech into words on this Mac."
        }

        if elapsedSeconds < 18 {
            if transcriptionCleanupMode.usesLocalLLM {
                return "Working \(elapsedLabel): cleaning uncertain phrases with \(transcriptionCleanupMode.title.lowercased()) local cleanup before paste."
            }
            if formattingEnabled || vocabularyCorrectionsEnabled {
                return "Working \(elapsedLabel): applying punctuation and vocabulary cleanup before paste."
            }
            return "Working \(elapsedLabel): preparing the transcript and keeping the active app ready for paste."
        }

        if transcriptionCleanupMode.usesLocalLLM {
            return "Still working \(elapsedLabel): local speech plus \(transcriptionCleanupMode.title.lowercased()) cleanup can take longer on bigger recordings."
        }

        return "Still working \(elapsedLabel): longer recordings or a cold speech model can take a bit, but this is still local."
    }

    private func commandModeTranscriptionDetail(elapsedSeconds: Int) -> String {
        let elapsedLabel = Self.processingElapsedLabel(for: elapsedSeconds)
        if elapsedSeconds < 4 {
            return "Working \(elapsedLabel): turning your spoken edit instruction into text."
        }

        if elapsedSeconds < 10 {
            return "Working \(elapsedLabel): decoding the instruction locally before the selected text is rewritten."
        }

        return "Still working \(elapsedLabel): the local model may be warming up before the edit can continue."
    }

    func refresh() {
        refreshPermissionStates()
        Task {
            do {
                let doctor = try await engineService.doctor()
                curatedModels = doctor.curatedModels
                installedModels = doctor.installedModels
                latestEngineDependencies = doctor.dependencies
                latestLocalLLMStatus = doctor.localLlm
                latestEngineCommands = doctor.commands
                if !curatedModels.contains(where: { $0.identifier == selectedModelID })
                    || !isUserSelectableModelID(selectedModelID) {
                    selectedModelID = doctor.defaultModelId
                    UserDefaults.standard.set(selectedModelID, forKey: Self.selectedModelIDKey)
                    updatePerformanceModeFromCurrentConfiguration()
                }
                await refreshModelReadiness(includeLoadCheck: false, includeInferenceCheck: false)
                statusMessage = readyForDictation
                    ? "Ready. Press \(hotkeyDescription) to dictate or \(commandModeShortcutDescription) for Command Mode."
                    : dictationSetupMessage
                startManagedModelMaintenanceIfNeeded(from: doctor)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func requestPermission(_ kind: PermissionKind) {
        markPermissionForFollowUp(kind)
        Task {
            await PermissionService.request(kind)
            refreshPermissionStates()
        }
    }

    func openPrivacySettings(_ kind: PermissionKind) {
        markPermissionForFollowUp(kind)
        Task {
            await PermissionService.prepareForOpeningSettings(kind)
            PermissionService.openSettings(for: kind)
            refreshPermissionStates()
        }
    }

    func openHelp() {
        OpenBridgeHelpController.shared.openHelp(setupDiagnostics: setupDiagnosticsSnapshot())
    }

    func openFeedbackEmail() {
        guard let url = FeedbackSupport.mailtoURL() else {
            PasteboardService.copy(FeedbackSupport.emailBody())
            statusMessage = "Feedback email could not be opened. Copied the feedback template instead."
            return
        }

        let didOpen = NSWorkspace.shared.open(url)
        if didOpen {
            statusMessage = "Opened feedback email. No transcript, audio, or diagnostics were attached."
        } else {
            PasteboardService.copy(FeedbackSupport.emailBody())
            statusMessage = "Mail could not open. Copied the feedback template instead."
        }
    }

    func copyFeedbackTemplate() {
        PasteboardService.copy(FeedbackSupport.emailBody())
        statusMessage = "Copied feedback template. Add only the details you choose to share."
    }

    func copyFeedbackEmailAddress() {
        PasteboardService.copy(FeedbackSupport.emailAddress)
        statusMessage = "Copied feedback address."
    }

    func runSystemCheck() {
        guard !isRunningSystemCheck else { return }
        isRunningSystemCheck = true
        systemCheckMessage = "Running System Check..."
        maintenanceStatus = systemCheckMessage
        statusMessage = systemCheckMessage

        Task {
            defer {
                isRunningSystemCheck = false
                maintenanceStatus = nil
            }
            refreshPermissionStates()
            let helpAvailability = OpenBridgeHelpController.shared.availabilityStatus()

            do {
                let readiness = try await engineService.checkReadiness(
                    modelIdentifier: selectedModelID,
                    cleanupMode: transcriptionCleanupMode,
                    includeLoadCheck: true,
                    includeInferenceCheck: false
                )
                modelReadiness = readiness
                modelReadinessStatus = readiness.summary
                let report = makeSystemCheckReport(
                    readiness: readiness,
                    readinessError: nil,
                    helpAvailability: helpAvailability
                )
                systemCheckReport = report
                systemCheckMessage = report.summary
                statusMessage = report.summary
            } catch {
                let report = makeSystemCheckReport(
                    readiness: nil,
                    readinessError: error.localizedDescription,
                    helpAvailability: helpAvailability
                )
                systemCheckReport = report
                systemCheckMessage = report.summary
                statusMessage = report.summary
            }
        }
    }

    func copySystemCheckReport() {
        guard let systemCheckReport else {
            statusMessage = "Run System Check before copying a support summary."
            return
        }

        PasteboardService.copy(systemCheckReport.supportText)
        statusMessage = "Copied privacy-safe System Check summary."
    }

    func setupDiagnosticsSnapshot() -> SetupDiagnosticsSnapshot {
        let installLocation = AppInstallLocation.current
        let localLLMStatus = latestLocalLLMStatus
        let installedModelCount = installedModels.filter(\.installed).count

        return SetupDiagnosticsSnapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            privacy: SetupDiagnosticsPrivacy(
                summary: "This diagnostic summary contains setup state only. It does not include audio, transcript text, selected text, snippet text, media file contents, or dictation history contents.",
                includedData: [
                    "App version and launch location",
                    "Permission states",
                    "Selected microphone name and meter status",
                    "Selected model and install readiness",
                    "Local AI provider availability",
                    "Shortcut bindings",
                    "Privacy/history mode",
                    "Current task status",
                ],
                excludedData: [
                    "Audio recordings",
                    "Transcript text",
                    "Selected text for Command Mode",
                    "Snippet expansion text",
                    "Media file contents",
                    "Saved dictation history contents",
                ]
            ),
            app: SetupDiagnosticsApp(
                displayName: AppIdentity.displayName,
                bundleIdentifier: AppIdentity.bundleIdentifier,
                version: AppIdentity.version,
                build: AppIdentity.build,
                installLocation: installLocation.kind.diagnosticLabel,
                installLocationDetail: installLocation.kind.diagnosticDetail,
                bundlePath: privacySafeDisplayPath(for: installLocation.bundleURL),
                launchAtLogin: launchAtLogin,
                onboardingCompleted: onboardingCompleted
            ),
            readiness: SetupDiagnosticsReadiness(
                readyForDictation: readyForDictation,
                readyForMediaTranscription: readyForMediaTranscription,
                missingPermissions: missingPermissionTitles,
                selectedModelInstalled: selectedModelInstalled,
                modelReadinessSummary: modelReadiness?.summary,
                modelReadinessChecks: modelReadiness?.checks.map { check in
                    SetupDiagnosticsReadinessCheck(
                        id: check.id,
                        title: check.title,
                        state: check.state,
                        message: check.message,
                        recovery: check.recovery,
                        blocking: check.blocking
                    )
                } ?? [],
                setupMessage: dictationSetupMessage
            ),
            permissions: permissions.map { permission in
                SetupDiagnosticsPermission(
                    id: permission.kind.rawValue,
                    title: permission.kind.title,
                    state: permission.value.label,
                    needsFollowUp: needsPermissionFollowUp(for: permission.kind),
                    whyItMatters: permission.kind.summary
                )
            },
            speechModel: SetupDiagnosticsSpeechModel(
                performanceMode: transcriptionPerformanceMode.title,
                selectedIdentifier: selectedModelID,
                selectedDisplayName: selectedModelDisplayName,
                selectedInstalled: selectedModelInstalled,
                installedCount: installedModelCount,
                availableCount: curatedModels.count,
                managedStatus: managedModelStatus,
                isInstalling: isInstallingModel,
                isWarmingSelectedModel: isWarmingSelectedModel
            ),
            localAI: SetupDiagnosticsLocalAI(
                cleanupMode: transcriptionCleanupMode.title,
                cleanupEnabled: transcriptionCleanupMode.usesLocalLLM,
                defaultProvider: localLLMStatus?.defaultProvider,
                mlxAvailable: localLLMStatus?.mlxAvailable,
                mlxDefaultModel: localLLMStatus?.mlxDefaultModel,
                mlxDefaultModelPresent: localLLMStatus?.mlxDefaultModelPresent,
                ollamaAvailable: localLLMStatus?.ollamaAvailable
            ),
            microphone: SetupDiagnosticsMicrophone(
                selectedName: selectedMicrophoneName,
                selectedIdentifier: selectedMicrophoneID,
                availableInputCount: microphoneDevices.count,
                meterLevel: microphoneMeterLevel,
                diagnosticsMessage: microphoneDiagnosticsMessage,
                warning: microphoneDiagnosticWarning
            ),
            transcription: SetupDiagnosticsTranscription(
                formattingEnabled: formattingEnabled,
                vocabularyCorrectionsEnabled: vocabularyCorrectionsEnabled,
                spokenFormattingCommandsEnabled: spokenFormattingCommandsEnabled,
                pressEnterVoiceCommandEnabled: pressEnterVoiceCommandEnabled
            ),
            media: SetupDiagnosticsMedia(
                ready: readyForMediaTranscription,
                setupMessage: mediaSetupMessage,
                ffmpegAvailable: latestEngineCommands?.ffmpeg,
                isTranscribing: isTranscribingMedia,
                lastResultAvailable: mediaTranscriptionResult != nil
            ),
            shortcuts: [
                SetupDiagnosticsShortcut(action: ShortcutAction.dictation.title, binding: hotkeyDescription),
                SetupDiagnosticsShortcut(action: ShortcutAction.handsFree.title, binding: handsFreeShortcutDescription),
                SetupDiagnosticsShortcut(action: ShortcutAction.cancel.title, binding: cancelShortcutDescription),
                SetupDiagnosticsShortcut(action: ShortcutAction.pasteLast.title, binding: pasteLastShortcutDescription),
                SetupDiagnosticsShortcut(action: ShortcutAction.commandMode.title, binding: commandModeShortcutDescription),
            ],
            history: SetupDiagnosticsHistory(
                retentionMode: historyRetentionMode.title,
                retentionChoiceMade: historyRetentionChoiceMade,
                storedItemCount: dictationHistory.count,
                pasteLastAvailable: hasPasteableLastTranscript
            ),
            activity: SetupDiagnosticsActivity(
                statusMessage: statusMessage,
                isRecording: isRecording,
                isTranscribing: isTranscribing,
                isTranscribingMedia: isTranscribingMedia,
                flowBarContext: flowBarContext.diagnosticLabel,
                flowBarPhase: flowBarPhase.diagnosticLabel
            )
        )
    }

    private func privacySafeDisplayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private func makeSystemCheckReport(
        readiness: EngineReadinessPayload?,
        readinessError: String?,
        helpAvailability: HelpAvailabilityStatus
    ) -> SystemCheckReport {
        var items: [SystemCheckItem] = []

        for permission in permissions {
            let granted = permission.value == .granted
            items.append(
                SystemCheckItem(
                    id: "permission_\(permission.kind.rawValue)",
                    title: permission.kind.title,
                    state: granted ? .pass : .fail,
                    message: granted
                        ? "\(permission.kind.title) permission is granted."
                        : "\(permission.kind.title) permission is missing.",
                    recovery: granted ? nil : systemCheckRecovery(for: permission.kind)
                )
            )
        }

        if let readiness {
            for check in readiness.checks where includeReadinessCheckInSystemCheck(check) {
                items.append(
                    SystemCheckItem(
                        id: "model_\(check.id)",
                        title: check.title,
                        state: systemCheckState(for: check),
                        message: check.message,
                        recovery: check.recovery
                    )
                )
            }
        } else {
            items.append(
                SystemCheckItem(
                    id: "model_readiness_unavailable",
                    title: "Model readiness",
                    state: .fail,
                    message: "OpenBridge could not run model readiness checks.",
                    recovery: readinessError
                )
            )
        }

        items.append(shortcutSystemCheckItem())
        items.append(cleanupSystemCheckItem(readiness: readiness))

        items.append(
            SystemCheckItem(
                id: "local_help",
                title: "Local Help",
                state: helpAvailability.available ? .pass : .warn,
                message: helpAvailability.message,
                recovery: helpAvailability.recovery
            )
        )

        let generatedAt = Date()
        return SystemCheckReport(
            generatedAt: generatedAt,
            items: items,
            supportText: systemCheckSupportText(items: items, generatedAt: generatedAt)
        )
    }

    private func includeReadinessCheckInSystemCheck(_ check: EngineReadinessCheck) -> Bool {
        if check.id == "cleanup_model" {
            return false
        }
        if check.id == "selected_model_test_inference", check.state == "notRun" {
            return false
        }
        return true
    }

    private func systemCheckState(for readinessCheck: EngineReadinessCheck) -> SystemCheckState {
        switch readinessCheck.state {
        case "pass":
            return .pass
        case "fail":
            return .fail
        default:
            return readinessCheck.blocking ? .fail : .warn
        }
    }

    private func shortcutSystemCheckItem() -> SystemCheckItem {
        if !shortcutSettings.hasUniqueBindings {
            return SystemCheckItem(
                id: "hotkeys",
                title: "Shortcuts",
                state: .fail,
                message: "Two or more OpenBridge actions use the same shortcut.",
                recovery: "Open Shortcuts in Settings and choose unique Right Option combinations."
            )
        }

        guard permissionState(for: .inputMonitoring) == .granted else {
            return SystemCheckItem(
                id: "hotkeys",
                title: "Shortcuts",
                state: .fail,
                message: "Keyboard shortcuts are not available until Input Monitoring is granted.",
                recovery: "Open Privacy & Security > Input Monitoring and enable OpenBridge, then return and run System Check again."
            )
        }

        return SystemCheckItem(
            id: "hotkeys",
            title: "Shortcuts",
            state: .pass,
            message: "Keyboard shortcuts are configured and Input Monitoring is granted.",
            recovery: nil
        )
    }

    private func systemCheckRecovery(for permissionKind: PermissionKind) -> String {
        switch permissionKind {
        case .microphone:
            return "Open Settings, press Request for Microphone if available, or enable OpenBridge in Privacy & Security > Microphone."
        case .accessibility:
            return "Open Privacy & Security > Accessibility and enable OpenBridge, then return and run System Check again."
        case .inputMonitoring:
            return "Open Input Monitoring from Openbridge first so macOS can register this app, then enable OpenBridge in Privacy & Security. If OpenBridge is missing, reopen it from Applications and try again."
        }
    }

    private func cleanupSystemCheckItem(readiness: EngineReadinessPayload?) -> SystemCheckItem {
        guard transcriptionCleanupMode.usesLocalLLM else {
            return SystemCheckItem(
                id: "cleanup",
                title: "Local cleanup",
                state: .pass,
                message: "Local cleanup is off by choice. Dictation can still run.",
                recovery: nil
            )
        }

        if readiness?.cleanup.available == true {
            return SystemCheckItem(
                id: "cleanup",
                title: "Local cleanup",
                state: .pass,
                message: "\(transcriptionCleanupMode.title) cleanup is available.",
                recovery: nil
            )
        }

        return SystemCheckItem(
            id: "cleanup",
            title: "Local cleanup",
            state: .warn,
            message: "\(transcriptionCleanupMode.title) cleanup is selected but unavailable.",
            recovery: "OpenBridge will keep the original transcript if local cleanup cannot run. Install the local text model or set cleanup to Off."
        )
    }

    private func systemCheckSupportText(items: [SystemCheckItem], generatedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let installLocation = AppInstallLocation.current
        var lines: [String] = [
            "OpenBridge System Check",
            "Generated: \(formatter.string(from: generatedAt))",
            "Privacy: This summary excludes audio, transcript text, selected text, snippet text, media file contents, saved dictation history contents, credentials, and private keys.",
            "App: \(AppIdentity.displayName) \(AppIdentity.versionLabel)",
            "Install location: \(installLocation.kind.diagnosticLabel)",
            "Performance mode: \(transcriptionPerformanceMode.title)",
            "Selected speech model: \(selectedModelDisplayName) (\(selectedModelID))",
            "Cleanup mode: \(transcriptionCleanupMode.title)",
            "Shortcut bindings: Dictation \(hotkeyDescription); Hands-free \(handsFreeShortcutDescription); Cancel \(cancelShortcutDescription); Paste last \(pasteLastShortcutDescription); Command Mode \(commandModeShortcutDescription)",
            "",
            "Results:",
        ]

        for item in items {
            lines.append("- [\(item.state.label.uppercased())] \(item.title): \(item.message)")
            if let recovery = item.recovery, !recovery.isEmpty {
                lines.append("  Recovery: \(recovery)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func checkPermission(_ kind: PermissionKind) {
        refreshPermissionStates()
        if permissionState(for: kind) != .granted {
            markPermissionForFollowUp(kind)
        }
    }

    func needsPermissionFollowUp(for kind: PermissionKind) -> Bool {
        permissionFollowUpKinds.contains(kind) && permissionState(for: kind) != .granted
    }

    func installSelectedModel() {
        guard !isInstallingModel else { return }
        isInstallingModel = true
        maintenanceStatus = "Installing \(selectedModelID)..."
        statusMessage = maintenanceStatus!
        Task {
            defer {
                isInstallingModel = false
                maintenanceStatus = nil
            }
            do {
                _ = try await engineService.installModel(identifier: selectedModelID)
                try await engineService.warmModel(identifier: selectedModelID)
                refresh()
                statusMessage = "Model installed. Press \(hotkeyDescription) to dictate or \(commandModeShortcutDescription) for Command Mode."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func refreshModelReadiness(
        includeLoadCheck: Bool,
        includeInferenceCheck: Bool
    ) async {
        do {
            let readiness = try await engineService.checkReadiness(
                modelIdentifier: selectedModelID,
                cleanupMode: transcriptionCleanupMode,
                includeLoadCheck: includeLoadCheck,
                includeInferenceCheck: includeInferenceCheck
            )
            modelReadiness = readiness
            modelReadinessStatus = readiness.summary
        } catch {
            modelReadiness = nil
            modelReadinessStatus = "Model readiness check failed: \(error.localizedDescription)"
        }
    }

    private func startManagedModelMaintenanceIfNeeded(from doctor: EngineDoctor) {
        guard !OpenBridgeLaunchContext.isIsolatedReview else {
            managedModelStatus = "Install a model when you are ready to try recording in this review build."
            return
        }
        guard doctor.dependencies.huggingfaceHub else {
            managedModelStatus = "Model updates unavailable until the bundled engine dependencies are installed."
            return
        }
        guard managedModelTask == nil else { return }

        let managedModels = doctor.curatedModels.filter(\.isManagedAutomatically)
        let modelIDs = ManagedModelMaintenancePolicy.orderedIdentifiers(
            selectedIdentifier: selectedModelID,
            availableIdentifiers: managedModels.map(\.identifier)
        )
        guard !modelIDs.isEmpty else { return }

        let installedIDs = Set(doctor.installedModels.filter(\.installed).map(\.identifier))
        let missingModelIDs = modelIDs.filter { !installedIDs.contains($0) }
        let defaults = UserDefaults.standard
        let lastUpdate = defaults.object(forKey: Self.modelAutoUpdateLastRunKey) as? Date ?? .distantPast
        let shouldCheckUpdates = Date().timeIntervalSince(lastUpdate) >= Self.modelAutoUpdateInterval

        guard !missingModelIDs.isEmpty || shouldCheckUpdates else {
            managedModelStatus = "Managed speech models are installed."
            return
        }

        let idsToManage = shouldCheckUpdates ? modelIDs : missingModelIDs
        managedModelTask = Task {
            var failedModelIDs: [String] = []
            isInstallingModel = true
            defer {
                isInstallingModel = false
                managedModelTask = nil
            }

            for (index, modelID) in idsToManage.enumerated() {
                if Task.isCancelled { return }

                let displayName = displayName(forModelID: modelID, in: doctor.curatedModels)
                let isUpdateCheck = shouldCheckUpdates && installedIDs.contains(modelID)
                let step = "\(index + 1)/\(idsToManage.count)"
                let action = isUpdateCheck ? "Updating" : "Installing"
                managedModelStatus = "\(action) \(displayName) (\(step))"
                statusMessage = managedModelStatus

                do {
                    _ = try await engineService.installModel(identifier: modelID, force: shouldCheckUpdates)
                    if ManagedModelMaintenancePolicy.shouldWarm(
                        identifier: modelID,
                        selectedIdentifier: selectedModelID
                    ) {
                        try await engineService.warmModel(identifier: modelID)
                    }
                    let response = try await engineService.listModels()
                    curatedModels = response.curatedModels
                    installedModels = response.installedModels
                    await refreshModelReadiness(includeLoadCheck: false, includeInferenceCheck: false)
                } catch {
                    failedModelIDs.append(modelID)
                    managedModelStatus = "Could not prepare \(displayName). Continuing with the remaining speech models."
                    statusMessage = managedModelStatus
                    continue
                }
            }

            if shouldCheckUpdates {
                defaults.set(Date(), forKey: Self.modelAutoUpdateLastRunKey)
            }
            await refreshModelReadiness(
                includeLoadCheck: !failedModelIDs.isEmpty,
                includeInferenceCheck: false
            )
            if failedModelIDs.isEmpty {
                managedModelStatus = "Managed speech models are installed."
                statusMessage = readyForDictation
                    ? "Ready. Press \(hotkeyDescription) to dictate or \(commandModeShortcutDescription) for Command Mode."
                    : "Speech models are ready. Complete permissions to enable dictation."
            } else {
                let failedNames = failedModelIDs.map {
                    displayName(forModelID: $0, in: doctor.curatedModels)
                }.joined(separator: ", ")
                if modelReadiness?.speechModel.fallbackReady == true {
                    managedModelStatus = "Whisper Base fallback is ready. \(failedNames) needs attention."
                    statusMessage = readyForDictation
                        ? "Ready with Whisper Base fallback. Press \(hotkeyDescription) to dictate."
                        : "Whisper Base fallback is ready. Complete permissions to enable dictation."
                } else if modelReadiness?.ready == true {
                    managedModelStatus = "A speech model is ready. \(failedNames) needs attention."
                    statusMessage = readyForDictation
                        ? "Ready. Press \(hotkeyDescription) to dictate."
                        : "A speech model is ready. Complete permissions to enable dictation."
                } else {
                    managedModelStatus = "Model setup needs attention: \(failedNames)."
                    statusMessage = managedModelStatus
                }
            }
        }
    }

    private func displayName(forModelID modelID: String, in models: [CuratedModel]) -> String {
        models.first { $0.identifier == modelID }?.displayName ?? modelID
    }

    var selectedModelDisplayName: String {
        displayName(forModelID: selectedModelID, in: curatedModels)
    }

    private func isUserSelectableModelID(_ modelID: String) -> Bool {
        guard let model = curatedModels.first(where: { $0.identifier == modelID }) else {
            return curatedModels.isEmpty
                && !modelID.localizedCaseInsensitiveContains("parakeet")
        }
        return isUserSelectableModel(model)
    }

    func isUserSelectableModel(_ model: CuratedModel) -> Bool {
        guard model.isParakeetCandidate else {
            return true
        }
        if model.identifier == Self.defaultSelectedModelID {
            return true
        }
        let runtimeAvailable: Bool
        switch model.runtime {
        case "parakeet_mlx":
            runtimeAvailable = latestEngineDependencies?.parakeetMlx == true
        case "parakeet_transformers":
            runtimeAvailable = latestEngineDependencies?.parakeetTransformers == true
        default:
            runtimeAvailable = false
        }
        let installed = installedModels.contains { installedModel in
            installedModel.identifier == model.identifier && installedModel.installed
        }
        return runtimeAvailable && installed
    }

    func isUserSelectablePerformanceMode(_ mode: TranscriptionPerformanceMode) -> Bool {
        guard mode.isSelectable,
              let modelID = mode.targetModelIdentifier else {
            return false
        }
        return isUserSelectableModelID(modelID)
    }

    private var missingPermissionTitles: [String] {
        permissions
            .filter { $0.value != .granted }
            .map { $0.kind.title }
    }

    private var microphonePermissionState: PermissionStateValue {
        permissions.first { $0.kind == .microphone }?.value ?? .unknown
    }

    private func setupRequirementMessage(action: String) -> String {
        let permissionsList = readableList(missingPermissionTitles)
        let modelName = selectedModelDisplayName
        let modelReady = selectedModelAvailableForTranscription
        let modelMessage = modelReadiness?.summary ?? "Install \(modelName) before \(action)."

        switch (missingPermissionTitles.isEmpty, modelReady) {
        case (true, true):
            return "Ready. Press \(hotkeyDescription) to dictate or \(commandModeShortcutDescription) for Command Mode."
        case (false, true):
            return "Grant \(permissionsList) before \(action)."
        case (true, false):
            return modelMessage
        case (false, false):
            return "Grant \(permissionsList) and fix model setup: \(modelMessage)"
        }
    }

    private func readableList(_ values: [String]) -> String {
        switch values.count {
        case 0:
            return ""
        case 1:
            return values[0]
        case 2:
            return "\(values[0]) and \(values[1])"
        default:
            let leading = values.dropLast().joined(separator: ", ")
            return "\(leading), and \(values.last ?? "")"
        }
    }

    @discardableResult
    func markOnboardingComplete() -> Bool {
        guard historyRetentionChoiceMade else {
            statusMessage = "Choose how Openbridge handles dictation history before finishing setup."
            return false
        }

        onboardingCompleted = true
        onboardingDeferredUntil = nil
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingDeferredUntilKey)
        return true
    }

    func deferOnboardingUntilTomorrow() {
        onboardingCompleted = false
        let deferredUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(24 * 60 * 60)
        onboardingDeferredUntil = deferredUntil
        UserDefaults.standard.set(false, forKey: Self.onboardingCompletedKey)
        UserDefaults.standard.set(deferredUntil, forKey: Self.onboardingDeferredUntilKey)
    }

    func setFormattingEnabled(_ enabled: Bool) {
        formattingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "formattingEnabled")
    }

    func setVocabularyCorrectionsEnabled(_ enabled: Bool) {
        vocabularyCorrectionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.vocabularyCorrectionsEnabledKey)
        statusMessage = enabled
            ? "Vocabulary corrections enabled."
            : "Vocabulary corrections disabled."
    }

    func setTranscriptionCleanupMode(_ mode: TranscriptionCleanupMode) {
        applyTranscriptionCleanupMode(mode)
        // lunr-studio/Openbridge-Beta#321 wave-4 (3886250999): the cleanup-mode
        // picker and the master toggle are ONE intent - changing the mode here
        // must update the persisted toggle so the start-panel control never
        // shows On while the plan gate rejects every meeting.
        MeetingCleanupSettings.syncFromCleanupMode(mode)
        updatePerformanceModeFromCurrentConfiguration()
        Task {
            await refreshModelReadiness(includeLoadCheck: false, includeInferenceCheck: false)
        }
        if let localModel = mode.localLLMModel {
            statusMessage = "\(mode.title) cleanup selected with \(localModel)."
        } else {
            statusMessage = "Local AI cleanup disabled."
        }
    }

    func setTranscriptionPerformanceMode(_ mode: TranscriptionPerformanceMode) {
        guard mode.isSelectable else {
            statusMessage = mode == .experimental
                ? "Parakeet mode will be enabled after local benchmark validation."
                : "Choose Fast, Balanced, or Accurate to update model settings."
            return
        }
        guard canChangeSelectedModel else {
            statusMessage = "Finish the current recording or transcription before changing performance mode."
            return
        }
        guard let targetModelID = mode.targetModelIdentifier,
              let targetCleanupMode = mode.targetCleanupMode else {
            statusMessage = "That performance mode is not ready yet."
            return
        }
        guard curatedModels.isEmpty || curatedModels.contains(where: { $0.identifier == targetModelID }) else {
            statusMessage = "\(mode.title) mode needs a speech model that is not available in this build."
            return
        }
        guard isUserSelectablePerformanceMode(mode) else {
            statusMessage = mode == .experimental
                ? "Parakeet mode is available as the V2 default and will use Whisper Base fallback until setup is ready."
                : "\(mode.title) mode is not available right now."
            return
        }

        transcriptionPerformanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.transcriptionPerformanceModeKey)

        selectedModelWarmTask?.cancel()
        if selectedModelID != targetModelID {
            selectedModelID = targetModelID
            UserDefaults.standard.set(targetModelID, forKey: Self.selectedModelIDKey)
        }
        applyTranscriptionCleanupMode(targetCleanupMode)
        // lunr-studio/Openbridge-Beta#321 wave-5 (3886352723): preset mode
        // changes must route through the SAME toggle synchronization so the
        // start control and MeetingPostStopCleanupPlan cannot disagree.
        MeetingCleanupSettings.syncFromCleanupMode(targetCleanupMode)

        Task {
            await refreshModelReadiness(includeLoadCheck: false, includeInferenceCheck: false)
        }

        if selectedModelInstalled {
            statusMessage = "\(mode.title) mode selected with \(selectedModelDisplayName)."
            warmSelectedModel()
        } else if targetModelID == Self.defaultSelectedModelID {
            statusMessage = "\(mode.title) mode selected. OpenBridge will use Whisper Base fallback until Parakeet is installed."
        } else {
            statusMessage = "\(mode.title) mode selected. Install \(selectedModelDisplayName) before dictating."
        }
    }

    func setSpokenFormattingCommandsEnabled(_ enabled: Bool) {
        spokenFormattingCommandsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.spokenFormattingCommandsEnabledKey)
        statusMessage = enabled
            ? "Spoken formatting commands enabled."
            : "Spoken formatting commands disabled."
    }

    func setPressEnterVoiceCommandEnabled(_ enabled: Bool) {
        pressEnterVoiceCommandEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.pressEnterVoiceCommandEnabledKey)
        statusMessage = enabled
            ? "Press Enter voice command enabled."
            : "Press Enter voice command disabled."
    }

    func setSelectedModelID(_ identifier: String) {
        guard canChangeSelectedModel else {
            statusMessage = "Finish the current recording or transcription before changing models."
            return
        }
        guard curatedModels.isEmpty || curatedModels.contains(where: { $0.identifier == identifier }) else {
            statusMessage = "That speech model is not available."
            return
        }
        guard isUserSelectableModelID(identifier) else {
            statusMessage = "That Parakeet model is available after its runtime and model files are installed."
            return
        }
        guard identifier != selectedModelID else {
            return
        }

        selectedModelWarmTask?.cancel()
        selectedModelID = identifier
        UserDefaults.standard.set(identifier, forKey: Self.selectedModelIDKey)
        updatePerformanceModeFromCurrentConfiguration()
        let modelName = selectedModelDisplayName
        Task {
            await refreshModelReadiness(includeLoadCheck: false, includeInferenceCheck: false)
        }
        if selectedModelInstalled {
            statusMessage = "\(modelName) selected."
            warmSelectedModel()
        } else if identifier == Self.defaultSelectedModelID {
            statusMessage = "\(modelName) selected. OpenBridge will use Whisper Base fallback until Parakeet is installed."
        } else {
            statusMessage = "\(modelName) selected. Install it before dictating."
        }
    }

    private func applyTranscriptionCleanupMode(_ mode: TranscriptionCleanupMode) {
        transcriptionCleanupMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.transcriptionCleanupModeKey)
        UserDefaults.standard.set(mode.usesLocalLLM, forKey: Self.ollamaSecondPassEnabledKey)
    }

    private func updatePerformanceModeFromCurrentConfiguration() {
        let inferredMode = TranscriptionPerformanceMode.inferred(
            modelIdentifier: selectedModelID,
            cleanupMode: transcriptionCleanupMode
        )
        transcriptionPerformanceMode = inferredMode
        UserDefaults.standard.set(inferredMode.rawValue, forKey: Self.transcriptionPerformanceModeKey)
    }

    func warmSelectedModel() {
        guard selectedModelInstalled else {
            statusMessage = "Install \(selectedModelDisplayName) before warming it."
            return
        }
        guard !isWarmingSelectedModel else {
            return
        }

        selectedModelWarmTask?.cancel()
        let modelID = selectedModelID
        let modelName = selectedModelDisplayName
        isWarmingSelectedModel = true
        maintenanceStatus = "Warming \(modelName)..."
        statusMessage = maintenanceStatus!

        selectedModelWarmTask = Task {
            defer {
                isWarmingSelectedModel = false
                selectedModelWarmTask = nil
                maintenanceStatus = nil
            }

            do {
                let readiness = try await engineService.checkReadiness(
                    modelIdentifier: modelID,
                    cleanupMode: transcriptionCleanupMode,
                    includeLoadCheck: true,
                    includeInferenceCheck: false
                )
                guard !Task.isCancelled else {
                    return
                }
                if selectedModelID == modelID {
                    modelReadiness = readiness
                    modelReadinessStatus = readiness.summary
                    statusMessage = readiness.ready
                        ? "\(modelName) is ready."
                        : readiness.summary
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                if selectedModelID == modelID {
                    modelReadinessStatus = "Could not check \(modelName): \(error.localizedDescription)"
                    statusMessage = modelReadinessStatus
                }
            }
        }
    }

    func setSelectedMicrophoneID(_ identifier: String) {
        guard !isRecording, !isTranscribing else {
            statusMessage = "Finish the current dictation before changing microphones."
            return
        }

        let nextIdentifier = microphoneDevices.contains(where: { $0.id == identifier })
            ? identifier
            : MicrophoneDevice.systemDefaultID
        selectedMicrophoneID = nextIdentifier
        UserDefaults.standard.set(nextIdentifier, forKey: Self.selectedMicrophoneIDKey)
        statusMessage = "Microphone set to \(selectedMicrophoneName)."
        refreshMicrophoneDiagnostics()
    }

    func refreshMicrophoneDevices() {
        let devices = recorder.availableInputDevices()
        microphoneDevices = devices
        if !devices.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = MicrophoneDevice.systemDefaultID
            UserDefaults.standard.set(selectedMicrophoneID, forKey: Self.selectedMicrophoneIDKey)
        }
    }

    func startMicrophoneDiagnostics(for owner: MicrophoneDiagnosticsOwner) {
        microphoneDiagnosticsOwners.insert(owner)
        restartMicrophoneDiagnosticsSession()
    }

    func refreshMicrophoneDiagnostics() {
        guard !microphoneDiagnosticsOwners.isEmpty || microphoneDiagnosticsTask != nil else { return }
        restartMicrophoneDiagnosticsSession()
    }

    func stopMicrophoneDiagnostics(for owner: MicrophoneDiagnosticsOwner) {
        microphoneDiagnosticsOwners.remove(owner)
        guard microphoneDiagnosticsOwners.isEmpty else { return }
        stopMicrophoneDiagnosticsSession()
    }

    private func restartMicrophoneDiagnosticsSession() {
        refreshMicrophoneDevices()
        microphoneDiagnosticsTask?.cancel()
        microphoneDiagnosticsTask = nil
        microphoneDiagnosticsStartedAt = Date()
        microphoneDiagnosticsPeakLevel = 0
        microphoneMeterLevel = 0
        recorder.stopDiagnostics()

        do {
            try recorder.startDiagnostics(deviceID: selectedMicrophoneID)
            microphoneDiagnosticsMessage = "Speak to test \(selectedMicrophoneName)."
        } catch {
            microphoneDiagnosticsMessage = error.localizedDescription
            return
        }

        microphoneDiagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.updateMicrophoneDiagnostics()
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func stopMicrophoneDiagnosticsSession() {
        microphoneDiagnosticsTask?.cancel()
        microphoneDiagnosticsTask = nil
        microphoneDiagnosticsStartedAt = nil
        microphoneDiagnosticsPeakLevel = 0
        microphoneMeterLevel = 0
        recorder.stopDiagnostics()
    }

    private func updateMicrophoneDiagnostics() {
        let sample = recorder.currentMeterSample()
        microphoneMeterLevel = sample.normalizedLevel
        microphoneDiagnosticsPeakLevel = max(microphoneDiagnosticsPeakLevel, sample.normalizedLevel)

        guard !microphoneDevices.isEmpty else {
            microphoneDiagnosticsMessage = "No microphone inputs found. Connect a microphone or check System Settings > Sound > Input."
            return
        }

        let elapsed = microphoneDiagnosticsStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if microphoneDiagnosticsPeakLevel > 0.08 {
            microphoneDiagnosticsMessage = "Input detected from \(selectedMicrophoneName)."
        } else if elapsed > 2.5 {
            microphoneDiagnosticsMessage = "No input detected yet. Check the selected microphone, speak closer to it, or choose System Default."
        } else {
            microphoneDiagnosticsMessage = "Speak to test \(selectedMicrophoneName)."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = "Launch at login could not be updated: \(error.localizedDescription)"
        }
    }

    func shortcutBinding(for action: ShortcutAction) -> ShortcutBinding {
        shortcutSettings.binding(for: action)
    }

    func setShortcutBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        if let systemConflictReason = binding.systemConflictReason {
            let message = "\(binding.displayName) cannot be used because \(systemConflictReason)."
            shortcutSettingsMessage = message
            statusMessage = message
            return
        }

        if let conflictingAction = shortcutSettings.action(using: binding, excluding: action) {
            let message = "\(binding.displayName) is already used by \(conflictingAction.title). Choose a different shortcut."
            shortcutSettingsMessage = message
            statusMessage = message
            return
        }

        var nextSettings = shortcutSettings
        nextSettings.set(binding, for: action)
        shortcutSettings = nextSettings
        persistShortcutSettings()
        configureHotkeys()
        let message = "\(action.title) shortcut set to \(binding.displayName)."
        shortcutSettingsMessage = message
        statusMessage = message
    }

    func resetShortcutBindings() {
        shortcutSettings = .defaults
        persistShortcutSettings()
        configureHotkeys()
        shortcutSettingsMessage = "Shortcuts reset to defaults."
        statusMessage = "Shortcuts reset to defaults."
    }

    var historyRetentionSummary: String {
        if historyRetentionNeedsChoice {
            return "History is off until you choose how Openbridge should handle saved dictations."
        }
        return historyRetentionMode.summary
    }

    var dictationHistoryFileLocation: String {
        privacySafeDisplayPath(for: historyStore.fileURL)
    }

    var customDictionaryFileLocation: String {
        privacySafeDisplayPath(for: customDictionaryStore.fileURL)
    }

    func copyHistoryEntry(_ entry: DictationHistoryEntry) {
        PasteboardService.copy(entry.transcript)
        statusMessage = "Copied dictation from history."
    }

    func repasteHistoryEntry(_ entry: DictationHistoryEntry) {
        flowBarContext = .dictation
        pasteIntoLastTarget(entry.transcript)
    }

    func pasteLastTranscript() {
        flowBarContext = .dictation
        guard !isTranscribing else {
            statusMessage = "Finish the current transcription before pasting the last transcript."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }

        if isRecording {
            discardActiveRecordingBeforePasteLast()
        }

        guard let transcript = pasteableLastTranscript else {
            statusMessage = "No transcript is available to paste yet."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }

        rememberLastTranscript(transcript.text, createdAt: transcript.createdAt)
        pasteIntoLastTarget(transcript.text)
    }

    func transcribeMediaFile(_ fileURL: URL) async {
        guard canStartMediaTranscription else {
            statusMessage = readyForMediaTranscription
                ? "Finish the current OpenBridge task before transcribing a file."
                : mediaSetupMessage
            return
        }

        isTranscribingMedia = true
        mediaTranscriptionResult = nil
        statusMessage = "Transcribing \(fileURL.lastPathComponent)..."
        let didStartSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
            isTranscribingMedia = false
        }

        do {
            let response = try await engineService.transcribeMedia(
                fileURL: fileURL,
                modelIdentifier: selectedModelID,
                formattingEnabled: formattingEnabled,
                vocabularyCorrectionsEnabled: vocabularyCorrectionsEnabled,
                customDictionaryURL: customDictionaryStore.fileURL,
                cleanupMode: transcriptionCleanupMode
            )
            let transcriptText = response.transcript.text
            let sourceName = response.media.sourceName.isEmpty
                ? fileURL.lastPathComponent
                : response.media.sourceName
            let result = MediaTranscriptionResult(
                sourceName: sourceName,
                transcript: transcriptText,
                originalText: response.transcript.originalText,
                modelLabel: response.transcript.modelLabel
            )
            mediaTranscriptionResult = result
            rememberLastTranscript(transcriptText, createdAt: result.createdAt)
            statusMessage = "File transcript ready: \(sourceName)."
        } catch {
            statusMessage = "File transcription failed: \(error.localizedDescription)"
        }
    }

    func transcribeYouTubeURL(_ urlString: String) async {
        guard canStartMediaTranscription else {
            statusMessage = readyForMediaTranscription
                ? "Finish the current OpenBridge task before transcribing YouTube."
                : mediaSetupMessage
            return
        }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSupportedYouTubeURL(trimmedURL) else {
            statusMessage = "Enter a full YouTube URL."
            return
        }

        isTranscribingMedia = true
        mediaTranscriptionResult = nil
        statusMessage = "Transcribing YouTube URL..."
        defer { isTranscribingMedia = false }

        do {
            let response = try await engineService.transcribeURL(
                urlString: trimmedURL,
                modelIdentifier: selectedModelID,
                formattingEnabled: formattingEnabled,
                vocabularyCorrectionsEnabled: vocabularyCorrectionsEnabled,
                customDictionaryURL: customDictionaryStore.fileURL,
                cleanupMode: transcriptionCleanupMode
            )
            let transcriptText = response.transcript.text
            let sourceName = response.media.sourceName.isEmpty
                ? "YouTube transcript"
                : response.media.sourceName
            let result = MediaTranscriptionResult(
                sourceName: sourceName,
                transcript: transcriptText,
                originalText: response.transcript.originalText,
                modelLabel: response.transcript.modelLabel
            )
            mediaTranscriptionResult = result
            rememberLastTranscript(transcriptText, createdAt: result.createdAt)
            statusMessage = "YouTube transcript ready: \(sourceName)."
        } catch {
            statusMessage = "YouTube transcription failed: \(error.localizedDescription)"
        }
    }

    func copyMediaTranscriptionResult() {
        guard let mediaTranscriptionResult else {
            statusMessage = "No media transcript is ready to copy."
            return
        }

        PasteboardService.copy(mediaTranscriptionResult.transcript)
        statusMessage = "Copied media transcript."
    }

    func saveMediaTranscriptionResult() {
        guard let mediaTranscriptionResult else {
            statusMessage = "No media transcript is ready to save."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = mediaTranscriptionResult.defaultFileName
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try mediaTranscriptionResult.transcript.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved media transcript to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Media transcript could not be saved: \(error.localizedDescription)"
        }
    }

    func createSnippet(triggerPhrase: String, expansionText: String) -> SnippetMutationResult {
        let trigger = triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = expansionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return .emptyTrigger }
        guard !expansion.isEmpty else { return .emptyExpansion }
        guard !hasDuplicateSnippetTrigger(trigger, excluding: nil) else { return .duplicateTrigger }

        let snippet = Snippet(triggerPhrase: trigger, expansionText: expansion)
        snippets.insert(snippet, at: 0)
        return persistSnippets(successMessage: "Snippet saved.")
    }

    func updateSnippet(_ snippet: Snippet, triggerPhrase: String, expansionText: String) -> SnippetMutationResult {
        let trigger = triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = expansionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return .emptyTrigger }
        guard !expansion.isEmpty else { return .emptyExpansion }
        guard !hasDuplicateSnippetTrigger(trigger, excluding: snippet.id) else { return .duplicateTrigger }
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else {
            return .storageFailed("The snippet no longer exists.")
        }

        snippets[index].triggerPhrase = trigger
        snippets[index].expansionText = expansion
        snippets[index].updatedAt = Date()
        return persistSnippets(successMessage: "Snippet updated.")
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        _ = persistSnippets(successMessage: "Snippet deleted.")
    }

    func createCustomDictionaryEntry(heardAs: String, replaceWith: String) -> CustomDictionaryMutationResult {
        let entry = CustomDictionaryEntry(heardAs: heardAs, replaceWith: replaceWith)
        return persistCustomDictionaryEntries(
            [entry] + customDictionaryEntries,
            successMessage: "Custom dictionary entry saved."
        )
    }

    func updateCustomDictionaryEntry(
        _ entry: CustomDictionaryEntry,
        heardAs: String,
        replaceWith: String
    ) -> CustomDictionaryMutationResult {
        guard let index = customDictionaryEntries.firstIndex(where: { $0.id == entry.id }) else {
            return .missingEntry
        }

        var nextEntries = customDictionaryEntries
        nextEntries[index].heardAs = heardAs
        nextEntries[index].replaceWith = replaceWith
        return persistCustomDictionaryEntries(nextEntries, successMessage: "Custom dictionary entry updated.")
    }

    func deleteCustomDictionaryEntry(_ entry: CustomDictionaryEntry) {
        let nextEntries = customDictionaryEntries.filter { $0.id != entry.id }
        _ = persistCustomDictionaryEntries(nextEntries, successMessage: "Custom dictionary entry deleted.")
    }

    func setHistoryRetentionMode(_ mode: DictationHistoryRetentionMode) {
        let modeChanged = mode != historyRetentionMode
        historyRetentionMode = mode
        historyRetentionChoiceMade = true
        UserDefaults.standard.set(mode.rawValue, forKey: historyRetentionModeKey)
        UserDefaults.standard.set(true, forKey: Self.historyRetentionChoiceMadeKey)

        switch mode {
        case .storeNormally:
            statusMessage = modeChanged
                ? "Dictation history will be stored until you delete it."
                : "Dictation history choice confirmed."
        case .autoDeleteAfter24Hours:
            pruneExpiredHistory(successMessage: "Dictation history older than 24 hours was removed.")
            statusMessage = "Dictation history will auto-delete after 24 hours."
        case .neverStore:
            eraseStoredHistory(successMessage: "Dictation history storage is off.")
        }
    }

    func deleteHistoryEntry(_ entry: DictationHistoryEntry) {
        dictationHistory.removeAll { $0.id == entry.id }
        if lastTranscript == entry.transcript, lastTranscriptCreatedAt == entry.createdAt {
            rememberLastTranscript(from: dictationHistory.first)
        }
        persistDictationHistory(successMessage: "Deleted dictation from history.")
    }

    func clearDictationHistory() {
        eraseStoredHistory(successMessage: "Cleared dictation history.")
    }

    func toggleDictation() async {
        if isTranscribing {
            return
        }
        if isStartingRecording {
            return
        }
        if isRecording {
            guard isStandardRecording else {
                statusMessage = isCommandModeRecording
                    ? "Command Mode is active. Use \(commandModeShortcutDescription) or the Flow Bar stop button to finish."
                    : "Hands-free dictation is active. Use \(handsFreeShortcutDescription) or the Flow Bar stop button to finish."
                return
            }
            await stopAndTranscribe()
            return
        }

        startRecording(mode: .standard)
    }

    func toggleHandsFreeDictation() async {
        if isTranscribing {
            return
        }
        if isStartingRecording {
            return
        }
        if isRecording {
            guard isHandsFreeRecording else {
                statusMessage = isCommandModeRecording
                    ? "Command Mode is active. Stop or cancel it before starting hands-free mode."
                    : "Regular dictation is active. Stop or cancel it before starting hands-free mode."
                return
            }
            await stopAndTranscribe()
            return
        }

        startRecording(mode: .handsFree)
    }

    func toggleCommandMode() async {
        if isTranscribing {
            return
        }
        if isStartingRecording {
            return
        }
        if isRecording {
            guard isCommandModeRecording else {
                statusMessage = "Another dictation mode is active. Stop or cancel it before using Command Mode."
                return
            }
            await stopAndTranscribe()
            return
        }

        await startCommandModeRecording()
    }

    func runCommandModePreset(_ preset: CommandModePreset) async {
        // Wave-23 (3840150569): transforms share the local Gemma engine -
        // wait for a running post-Stop cleanup to finish first.
        guard postStopCleanupTask == nil else {
            statusMessage = "Finish the running transcript cleanup before starting a preset."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }
        guard readyForDictation else {
            statusMessage = commandModeSetupMessage
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }
        guard !isTranscribing else {
            statusMessage = "Finish the current OpenBridge AI rewrite before starting another preset."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }
        guard !isStartingRecording else {
            return
        }
        guard !isRecording else {
            statusMessage = "Stop or cancel the current recording before running a Command Mode preset."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }

        isStartingRecording = true
        isTranscribing = true
        processingCancellationRequested = false
        defer {
            isStartingRecording = false
            isTranscribing = false
        }

        do {
            guard let session = await captureCommandModeSelection() else {
                return
            }
            try throwIfProcessingCancelled()
            try await applyCommandModeInstruction(preset.instruction, session: session)
        } catch is CancellationError {
            statusMessage = "Command Mode preset cancelled. Nothing was pasted."
            showTransientFlowBar(.cancelled, nanoseconds: 1_800_000_000)
        } catch {
            statusMessage = "Command Mode preset failed: \(error.localizedDescription)"
            showTransientFlowBar(.error(statusMessage), nanoseconds: 5_000_000_000)
        }
    }

    func stopActiveRecording() async {
        guard isRecording else { return }
        await stopAndTranscribe()
    }

    func cancelDictation() {
        if isTranscribing {
            processingCancellationRequested = true
            let cancellationMessage = flowBarContext == .commandMode
                ? "Command Mode cancelled. Nothing was pasted."
                : "Dictation cancelled. Nothing was pasted."
            statusMessage = cancellationMessage
            showTransientFlowBar(.cancelled, nanoseconds: 1_800_000_000)
            return
        }

        guard isRecording else { return }
        let cancelledMode = recordingMode
        activeDictationPasteTarget = nil
        let cancelledURL = recorder.cancelRecording()
        let audioURL = cancelledURL ?? currentRecordingURL
        isRecording = false
        recordingStartedAt = nil
        recordingSourceApplication = nil
        activeCommandModeSession = nil
        recordingMode = nil
        handsFreeWarningMessage = nil
        currentRecordingURL = nil
        cancelHandsFreeLimitTask()
        if cancelledURL == nil, let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        flowBarContext = Self.flowBarContext(for: cancelledMode)
        statusMessage = cancelledMode == .commandMode
            ? "Command Mode cancelled. Nothing was pasted."
            : "Dictation cancelled. Nothing was pasted."
        showTransientFlowBar(.cancelled, nanoseconds: 1_800_000_000)
    }

    func dismissFlowBar() {
        setFlowBarPhase(.hidden)
    }

    private func startCommandModeRecording() async {
        guard readyForDictation else {
            requestMicrophonePermissionIfUndetermined()
            statusMessage = commandModeSetupMessage
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }

        // Wave-13 (3838167618): Command Mode is a capture entry point too -
        // it must flow through the SAME cancel-and-await cleanup gate as
        // standard/hands-free dictation (AGENTS.md L42).
        guard !isStartingRecording, !isMeetingStarting else { return }
        isStartingRecording = true

        guard let session = await captureCommandModeSelection() else {
            isStartingRecording = false
            return
        }
        activeCommandModeSession = session
        await cancelAndAwaitPostStopCleanup()
        beginRecording(mode: .commandMode)
        isStartingRecording = false
    }

    private func captureCommandModeSelection() async -> CommandModeSession? {
        flowBarContext = .commandMode
        flowBarProcessingStep = .capturingSelection
        statusMessage = "Reading selected text..."
        setFlowBarPhase(.processing)

        rememberCurrentPasteTargetApplication()
        guard let targetApplication = lastPasteTargetApplication else {
            statusMessage = "Open or focus an app with selected text before using Command Mode."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 4_000_000_000)
            return nil
        }

        let captureResult = await PasteboardService.captureSelectedText(activating: targetApplication)
        switch captureResult {
        case .captured(let selectedText, let accessibilityReference):
            return CommandModeSession(
                selectedText: selectedText,
                targetApplication: targetApplication,
                sourceApplication: targetApplication.localizedName,
                accessibilityReference: accessibilityReference
            )
        case .noSelection:
            statusMessage = "Select text in another app before using Command Mode."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 4_000_000_000)
            return nil
        case .failed:
            statusMessage = "OpenBridge could not copy the selected text. Check Accessibility permission and try again."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 4_000_000_000)
            return nil
        }
    }

    /// Wave-13 (3838167620): the ONE shared cancel-and-await gate for the
    /// post-Stop cleanup. The handle stays SET until the engine process
    /// has actually terminated (cleared inside the continuation), so both
    /// start paths observe it for their entire wait - clearing early let
    /// a meeting start slip in while Gemma was still terminating.
    private func cancelAndAwaitPostStopCleanup() async {
        guard let cleanup = postStopCleanupTask else { return }
        cleanup.cancel()
        statusMessage = "Finishing local meeting cleanup…"
        _ = await cleanup.value
        // Only clear if this exact task is still the tracked one
        // (Task is a value type; equality is not available, but the
        // only writer past this point is the cleanup-finish path).
        postStopCleanupTask = nil
    }

    private func startRecording(mode: DictationRecordingMode) {
        // Wave-12/13 (3837685420, 3838167620): dictation capture must
        // never overlap a still-running post-Stop Gemma cleanup, and the
        // start is cross-serialized with a meeting start (shared cleanup
        // gate + mutually-aware flags).
        guard !isStartingRecording, !isMeetingStarting else { return }
        isStartingRecording = true
        Task { @MainActor in
            await cancelAndAwaitPostStopCleanup()
            beginRecording(mode: mode)
            isStartingRecording = false
        }
    }

    private func beginRecording(mode: DictationRecordingMode) {
        guard readyForDictation else {
            requestMicrophonePermissionIfUndetermined()
            statusMessage = dictationSetupMessage
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }

        do {
            let startedAt = Date()
            processingCancellationRequested = false
            rememberCurrentPasteTargetApplication()
            recordingSourceApplication = lastPasteTargetApplication?.localizedName
            activeDictationPasteTarget = PasteboardService.captureDictationTarget(
                application: lastPasteTargetApplication,
                allowActivation: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            )
            currentRecordingURL = try recorder.startRecording(deviceID: selectedMicrophoneID)
            recordingStartedAt = startedAt
            recordingMode = mode
            flowBarContext = Self.flowBarContext(for: mode)
            handsFreeWarningMessage = nil
            isRecording = true
            switch mode {
            case .standard:
                statusMessage = "Listening..."
            case .handsFree:
                statusMessage = "Hands-free dictation is listening. It will auto-stop after \(handsFreeMaxDurationLabel)."
                scheduleHandsFreeLimit()
            case .commandMode:
                statusMessage = "Command Mode is listening. Say how to change the selected text."
            }
            foregroundStatus = statusMessage
            setFlowBarPhase(.listening)
        } catch {
            if mode == .commandMode {
                activeCommandModeSession = nil
            }
            activeDictationPasteTarget = nil
            statusMessage = "Recording failed: \(error.localizedDescription)"
            showTransientFlowBar(.error(statusMessage), nanoseconds: 4_000_000_000)
        }
    }

    private func stopAndTranscribe() async {
        guard !isTranscribing else {
            return
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            foregroundStatus = nil
        }
        processingCancellationRequested = false

        cancelHandsFreeLimitTask()
        let startedAt = recordingStartedAt
        let sourceApplication = recordingSourceApplication
        let dictationPasteTarget = activeDictationPasteTarget
        activeDictationPasteTarget = nil
        guard let audioURL = await recorder.stopRecording() else {
            isRecording = false
            recordingStartedAt = nil
            recordingSourceApplication = nil
            activeCommandModeSession = nil
            recordingMode = nil
            handsFreeWarningMessage = nil
            currentRecordingURL = nil
            statusMessage = "No recording was available."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 3_000_000_000)
            return
        }

        isRecording = false
        recordingStartedAt = nil
        recordingSourceApplication = nil
        let commandModeSession = activeCommandModeSession
        let completedRecordingMode = recordingMode
        activeCommandModeSession = nil
        recordingMode = nil
        handsFreeWarningMessage = nil
        flowBarContext = Self.flowBarContext(for: completedRecordingMode)
        flowBarProcessingStep = .transcribing
        statusMessage = "Transcribing..."
        setFlowBarPhase(.processing)

        guard recorder.lastRecordingPeakLevel >= 0.025 else {
            statusMessage = "Recording looked silent. Check \(selectedMicrophoneName), speak closer to the mic, or choose System Default."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 5_000_000_000)
            try? FileManager.default.removeItem(at: audioURL)
            currentRecordingURL = nil
            return
        }

        do {
            let transcript = try await engineService.transcribe(
                audioURL: audioURL,
                modelIdentifier: selectedModelID,
                formattingEnabled: formattingEnabled,
                vocabularyCorrectionsEnabled: vocabularyCorrectionsEnabled,
                customDictionaryURL: customDictionaryStore.fileURL,
                cleanupMode: transcriptionCleanupMode
            )
            try throwIfProcessingCancelled()
            if completedRecordingMode == .commandMode {
                try await applyCommandModeInstruction(
                    transcript.text,
                    session: commandModeSession
                )
                try? FileManager.default.removeItem(at: audioURL)
                currentRecordingURL = nil
                return
            }

            let pressEnterCommand = pressEnterCommandResult(for: transcript.text)
            let formattedText = SpokenFormattingCommands.apply(
                to: pressEnterCommand.text,
                enabled: spokenFormattingCommandsEnabled
            )
            let expansion = snippetExpansion(for: formattedText)
            let pastedText = expansion?.text ?? formattedText
            let commandRequestedEnter = pressEnterCommand.shouldPressEnter
            guard DictationDelivery.hasUsableText(pastedText) else {
                throw DictationDeliveryError.noSpeech
            }

            let completedAt = Date()
            rememberLastTranscript(pastedText, createdAt: completedAt)
            // Save recognized words independently of whether the destination
            // still accepts text. A failed paste must not lose the transcript.
            let savedToHistory = saveSuccessfulDictation(
                transcriptText: pastedText,
                modelLabel: transcript.modelLabel,
                durationSeconds: startedAt.map { completedAt.timeIntervalSince($0) },
                sourceApplication: sourceApplication,
                createdAt: completedAt
            )
            var historyFailure: String?
            if case .failed = savedToHistory { historyFailure = statusMessage }
            let delivery = await PasteboardService.deliverDictation(
                pastedText, target: dictationPasteTarget, pressEnter: commandRequestedEnter,
                isCancelled: { [weak self] in self?.processingCancellationRequested ?? true }
            )
            showDictationDeliveryResult(delivery, deliveredText: pastedText, historyFailure: historyFailure)
        } catch is CancellationError {
            statusMessage = completedRecordingMode == .commandMode
                ? "Command Mode cancelled. Nothing was pasted."
                : "Dictation cancelled. Nothing was pasted."
            showTransientFlowBar(.cancelled, nanoseconds: 1_800_000_000)
        } catch {
            let failurePrefix = completedRecordingMode == .commandMode ? "Command Mode failed" : "Transcription failed"
            statusMessage = "\(failurePrefix): \(error.localizedDescription)"
            showTransientFlowBar(.error(statusMessage), nanoseconds: 5_000_000_000)
        }

        try? FileManager.default.removeItem(at: audioURL)
        currentRecordingURL = nil
    }

    private func applyCommandModeInstruction(
        _ instruction: String,
        session: CommandModeSession?
    ) async throws {
        guard let session else {
            throw EngineServiceError.processFailed("Command Mode lost the selected text context. Select the text and try again.")
        }

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw EngineServiceError.processFailed("Command Mode needs a spoken instruction. Try again and say how to change the selected text.")
        }

        flowBarContext = .commandMode
        flowBarProcessingStep = .transformingSelection
        statusMessage = "Transforming selected text with \(commandModeAIUserLabel)..."
        let response = try await engineService.transformSelectedText(
            selectedText: session.selectedText,
            instruction: trimmedInstruction,
            appContext: session.appContext
        )
        try throwIfProcessingCancelled()

        let transformedText = response.transformedText
        rememberLastTranscript(transformedText)
        flowBarProcessingStep = .replacingSelection
        statusMessage = "Replacing selected text..."
        let replacementResult = await PasteboardService.replaceSelectedText(
            transformedText,
            activating: session.targetApplication,
            accessibilityReference: session.accessibilityReference
        )
        try throwIfProcessingCancelled()

        switch replacementResult {
        case .replaced:
            statusMessage = "Command Mode replaced the selected text with \(commandModeAIUserLabel)."
            showTransientFlowBar(.success("Selected text replaced with \(commandModeAIUserLabel). Use Undo to revert."), nanoseconds: 2_400_000_000)
        case .pasteRequested:
            statusMessage = "Command Mode requested paste and left the replacement on the clipboard."
            showTransientFlowBar(
                .success("Replacement requested. Press Command-V if it did not appear."),
                nanoseconds: 4_000_000_000
            )
        case .copiedToClipboard:
            statusMessage = "Command Mode copied the replacement to the clipboard because paste was unavailable."
            showTransientFlowBar(.error(statusMessage), nanoseconds: 5_000_000_000)
        }
    }

    private func setFlowBarPhase(_ phase: FlowBarPhase) {
        flowBarVisibilityTask?.cancel()
        flowBarVisibilityTask = nil
        flowBarRecoveryText = nil
        flowBarRecoveryTone = .attention
        flowBarPhase = phase
        if case .processing = phase {
            if flowBarProcessingStartedAt == nil {
                flowBarProcessingStartedAt = Date()
            }
        } else {
            flowBarProcessingStartedAt = nil
        }
        if phase.isVisible && flowBarController == nil {
            flowBarController = FlowBarWindowController(appState: self)
        }
        flowBarController?.updateVisibility(for: phase)
    }

    private func showTransientFlowBar(_ phase: FlowBarPhase, nanoseconds: UInt64) {
        setFlowBarPhase(phase)
        flowBarVisibilityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.flowBarPhase == phase else { return }
                self?.setFlowBarPhase(.hidden)
            }
        }
    }

    private func scheduleHandsFreeLimit() {
        cancelHandsFreeLimitTask()

        let warningDelay = max(0, handsFreeMaxDurationSeconds - handsFreeWarningLeadSeconds)
        handsFreeLimitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(from: warningDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.showHandsFreeDurationWarning()
            }

            try? await Task.sleep(nanoseconds: Self.nanoseconds(from: self?.handsFreeWarningLeadSeconds ?? 0))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.isHandsFreeRecording == true else { return }
                self?.handsFreeLimitTask = nil
                self?.statusMessage = "Hands-free recording reached \(self?.handsFreeMaxDurationLabel ?? "the limit"). Transcribing..."
            }
            await self?.stopHandsFreeAfterMaximumDuration()
        }
    }

    private func showHandsFreeDurationWarning() {
        guard isHandsFreeRecording else { return }
        flowBarContext = .handsFree
        handsFreeWarningMessage = "Auto-stopping in \(handsFreeWarningLeadLabel)."
        statusMessage = "Hands-free dictation will auto-stop in \(handsFreeWarningLeadLabel)."
        setFlowBarPhase(.listening)
    }

    private func stopHandsFreeAfterMaximumDuration() async {
        guard isHandsFreeRecording else { return }
        await stopAndTranscribe()
    }

    private func cancelHandsFreeLimitTask() {
        handsFreeLimitTask?.cancel()
        handsFreeLimitTask = nil
    }

    private func configureHotkeys() {
        hotkeyService.start(
            shortcutSettings: shortcutSettings,
            dictationCallback: { [weak self] in
                Task { await self?.toggleDictation() }
            },
            handsFreeCallback: { [weak self] in
                Task { await self?.toggleHandsFreeDictation() }
            },
            cancelCallback: { [weak self] in
                self?.cancelDictation()
            },
            pasteLastCallback: { [weak self] in
                self?.pasteLastTranscript()
            },
            commandModeCallback: { [weak self] in
                Task { await self?.toggleCommandMode() }
            }
        )
    }

    private static func loadShortcutSettings(from defaults: UserDefaults) -> ShortcutSettings {
        guard let data = defaults.data(forKey: shortcutSettingsKey),
              let settings = try? JSONDecoder().decode(ShortcutSettings.self, from: data),
              settings.hasUniqueBindings else {
            return .defaults
        }

        return settings
    }

    private func persistShortcutSettings() {
        guard let data = try? JSONEncoder().encode(shortcutSettings) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.shortcutSettingsKey)
    }

    private func loadDictationHistory() {
        do {
            dictationHistory = try historyStore.load()
            applyHistoryRetentionPolicy()
            rememberLastTranscript(from: dictationHistory.first)
        } catch {
            dictationHistory = []
            statusMessage = "Dictation history could not be loaded: \(error.localizedDescription)"
        }
    }

    private func loadSnippets() {
        do {
            snippets = try snippetStore.load()
        } catch {
            snippets = []
            statusMessage = "Snippets could not be loaded: \(error.localizedDescription)"
        }
    }

    private func loadCustomDictionary() {
        do {
            customDictionaryEntries = try customDictionaryStore.load()
        } catch {
            customDictionaryEntries = []
            statusMessage = "Custom dictionary could not be loaded: \(error.localizedDescription)"
        }
    }

    private var pasteableLastTranscript: LastTranscriptSnapshot? {
        let inMemoryTranscript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inMemoryTranscript.isEmpty {
            return LastTranscriptSnapshot(text: lastTranscript, createdAt: lastTranscriptCreatedAt)
        }

        guard historyRetentionMode != .neverStore else {
            return nil
        }

        guard let latestHistoryEntry = dictationHistory.first else {
            return nil
        }

        return LastTranscriptSnapshot(text: latestHistoryEntry.transcript, createdAt: latestHistoryEntry.createdAt)
    }

    private func rememberLastTranscript(_ transcript: String, createdAt: Date? = Date()) {
        lastTranscript = transcript
        lastTranscriptCreatedAt = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : createdAt
    }

    private func rememberLastTranscript(from entry: DictationHistoryEntry?) {
        guard let entry else {
            rememberLastTranscript("", createdAt: nil)
            return
        }

        rememberLastTranscript(entry.transcript, createdAt: entry.createdAt)
    }

    private func pasteIntoLastTarget(_ text: String) {
        guard !isRecording, !isTranscribing, !isStartingRecording else {
            statusMessage = "Finish the current dictation before pasting from History."
            return
        }
        guard DictationDelivery.hasUsableText(text) else {
            showDictationDeliveryResult(.empty)
            return
        }
        let target = PasteboardService.captureDictationTarget(
            application: lastPasteTargetApplication, allowActivation: true
        )
        rememberLastTranscript(text)
        isTranscribing = true
        processingCancellationRequested = false
        Task { @MainActor in
            defer { isTranscribing = false }
            let result = await PasteboardService.deliverDictation(
                text, target: target,
                isCancelled: { [weak self] in self?.processingCancellationRequested ?? true }
            )
            showDictationDeliveryResult(result, deliveredText: text)
        }
    }

    private func showDictationDeliveryResult(_ result: DictationDeliveryResult, deliveredText: String? = nil, historyFailure: String? = nil) {
        statusMessage = result.message
        if let historyFailure { statusMessage += " " + historyFailure }
        if let recoveryText = DictationFlowRecovery.text(for: result, deliveredText: deliveredText) {
            // The user may need time to inspect the destination. Do not hide
            // recovery, paste twice, or substitute text from an earlier request.
            setFlowBarPhase(.error(statusMessage))
            flowBarRecoveryText = recoveryText
            flowBarRecoveryTone = DictationFlowRecovery.tone(for: result, historyFailure: historyFailure)
        } else if case .verified = result, historyFailure == nil {
            showTransientFlowBar(.success(statusMessage), nanoseconds: 1_800_000_000)
        } else {
            showTransientFlowBar(.error(statusMessage), nanoseconds: 6_000_000_000)
        }
    }

    func copyFlowBarRecoveryText() {
        guard let text = flowBarRecoveryText, DictationDelivery.hasUsableText(text) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Text copied. Paste it into your app when you’re ready."
        showTransientFlowBar(.success(statusMessage), nanoseconds: 2_400_000_000)
    }

    private func requestMicrophonePermissionIfUndetermined() {
        guard microphonePermissionState == .unknown else { return }
        requestPermission(.microphone)
    }

    private func refreshPermissionStates() {
        let nextPermissions = PermissionService.currentStates()
        permissions = nextPermissions
        let grantedKinds = Set(nextPermissions.filter { $0.value == .granted }.map(\.kind))
        permissionFollowUpKinds.subtract(grantedKinds)
        refreshMicrophoneDevices()
    }

    private func markPermissionForFollowUp(_ kind: PermissionKind) {
        permissionFollowUpKinds.insert(kind)
    }

    private func permissionState(for kind: PermissionKind) -> PermissionStateValue {
        permissions.first { $0.kind == kind }?.value ?? .unknown
    }

    private func discardActiveRecordingBeforePasteLast() {
        activeDictationPasteTarget = nil
        let cancelledURL = recorder.cancelRecording()
        let audioURL = cancelledURL ?? currentRecordingURL
        isRecording = false
        recordingStartedAt = nil
        recordingSourceApplication = nil
        activeCommandModeSession = nil
        recordingMode = nil
        handsFreeWarningMessage = nil
        currentRecordingURL = nil
        cancelHandsFreeLimitTask()
        if cancelledURL == nil, let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        setFlowBarPhase(.hidden)
    }

    private func saveSuccessfulDictation(
        transcriptText: String,
        modelLabel: String,
        durationSeconds: TimeInterval?,
        sourceApplication: String?,
        createdAt: Date
    ) -> HistoryWriteResult {
        guard historyRetentionChoiceMade else {
            return .skipped
        }

        guard historyRetentionMode != .neverStore else {
            return .skipped
        }

        let entry = DictationHistoryEntry(
            transcript: transcriptText,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            modelIdentifier: selectedModelID,
            modelLabel: modelLabel,
            sourceApplication: sourceApplication
        )
        dictationHistory.insert(entry, at: 0)
        applyHistoryRetentionPolicy()
        return persistDictationHistory(successMessage: nil) ? .saved : .failed
    }

    @discardableResult
    private func persistDictationHistory(successMessage: String?) -> Bool {
        do {
            try historyStore.save(dictationHistory)
            if let successMessage {
                statusMessage = successMessage
            }
            return true
        } catch {
            statusMessage = "Dictation history could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private func persistSnippets(successMessage: String?) -> SnippetMutationResult {
        do {
            try snippetStore.save(snippets)
            if let successMessage {
                statusMessage = successMessage
            }
            return .saved
        } catch {
            statusMessage = "Snippets could not be saved: \(error.localizedDescription)"
            return .storageFailed(error.localizedDescription)
        }
    }

    private func persistCustomDictionaryEntries(
        _ entries: [CustomDictionaryEntry],
        successMessage: String?
    ) -> CustomDictionaryMutationResult {
        do {
            customDictionaryEntries = try customDictionaryStore.save(entries)
            if let successMessage {
                statusMessage = successMessage
            }
            return .saved
        } catch let validationError as CustomDictionaryStore.ValidationError {
            switch validationError {
            case .emptyHeardAs:
                return .emptyHeardAs
            case .emptyReplaceWith:
                return .emptyReplaceWith
            case .duplicateHeardAs:
                return .duplicateHeardAs
            }
        } catch {
            statusMessage = "Custom dictionary could not be saved: \(error.localizedDescription)"
            return .storageFailed(error.localizedDescription)
        }
    }

    private func hasDuplicateSnippetTrigger(_ triggerPhrase: String, excluding snippetID: UUID?) -> Bool {
        let normalizedTrigger = normalizedSnippetTrigger(triggerPhrase)
        guard !normalizedTrigger.isEmpty else { return false }
        return snippets.contains { snippet in
            if let snippetID, snippet.id == snippetID {
                return false
            }
            return normalizedSnippetTrigger(snippet.triggerPhrase) == normalizedTrigger
        }
    }

    private func pressEnterCommandResult(for transcriptText: String) -> PressEnterCommandResult {
        PressEnterVoiceCommand.apply(to: transcriptText, enabled: pressEnterVoiceCommandEnabled)
    }

    private func snippetExpansion(for transcriptText: String) -> SnippetExpansion? {
        let normalizedTranscript = normalizedSnippetTrigger(transcriptText)
        guard !normalizedTranscript.isEmpty else { return nil }

        guard let snippet = snippets.first(where: { normalizedSnippetTrigger($0.triggerPhrase) == normalizedTranscript }) else {
            return nil
        }

        return SnippetExpansion(text: snippet.expansionText)
    }

    private func normalizedSnippetTrigger(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let allowedCharacters = CharacterSet.alphanumerics
        let tokenized = folded.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? String(scalar) : " "
        }.joined()

        return tokenized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func applyHistoryRetentionPolicy() {
        switch historyRetentionMode {
        case .storeNormally:
            return
        case .autoDeleteAfter24Hours:
            pruneExpiredHistory(successMessage: nil)
        case .neverStore:
            eraseStoredHistory(successMessage: nil)
        }
    }

    private func pruneExpiredHistory(successMessage: String?) {
        guard historyRetentionMode == .autoDeleteAfter24Hours else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let originalCount = dictationHistory.count
        dictationHistory = dictationHistory.filter { $0.createdAt >= cutoff }
        if originalCount != dictationHistory.count {
            rememberLastTranscript(from: dictationHistory.first)
            persistDictationHistory(successMessage: successMessage)
        }
    }

    private func eraseStoredHistory(successMessage: String?) {
        dictationHistory = []
        rememberLastTranscript("", createdAt: nil)
        do {
            try historyStore.delete()
            if let successMessage {
                statusMessage = successMessage
            }
        } catch {
            statusMessage = "Dictation history could not be deleted: \(error.localizedDescription)"
        }
    }

    private func rememberCurrentPasteTargetApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return
        }
        rememberPasteTargetApplication(application)
    }

    private func startTrackingPasteTargetApplications() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor in
                self?.rememberPasteTargetApplication(application)
            }
        }
    }

    private func startRefreshingPermissionsOnAppActivation() {
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStates()
            }
        }
    }

    private func rememberPasteTargetApplication(_ application: NSRunningApplication) {
        guard application.activationPolicy == .regular else {
            return
        }
        if application.bundleIdentifier == Bundle.main.bundleIdentifier || application.localizedName == "OpenBridge" {
            return
        }
        lastPasteTargetApplication = application
        PasteboardService.prepareDictationAccessibility(for: application)
    }

    private func throwIfProcessingCancelled() throws {
        if processingCancellationRequested {
            throw CancellationError()
        }
    }

    private static func flowBarContext(for mode: DictationRecordingMode?) -> FlowBarContext {
        switch mode {
        case .handsFree:
            return .handsFree
        case .commandMode:
            return .commandMode
        case .standard, .none:
            return .dictation
        }
    }

    private static func durationLabel(for seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds) seconds"
        }

        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        if remainder == 0 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }

        return "\(minutes)m \(remainder)s"
    }

    private static func processingElapsedLabel(for elapsedSeconds: Int) -> String {
        let totalSeconds = max(0, elapsedSeconds)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private static func isSupportedYouTubeURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

private enum HistoryWriteResult {
    case saved
    case skipped
    case failed
}

private struct LastTranscriptSnapshot {
    let text: String
    let createdAt: Date?
}

private struct CommandModeSession {
    let selectedText: String
    let targetApplication: NSRunningApplication
    let sourceApplication: String?
    let accessibilityReference: AccessibilitySelectionReference?

    var appContext: String {
        guard let sourceApplication, !sourceApplication.isEmpty else {
            return "No app context supplied."
        }
        return "From \(sourceApplication)"
    }
}

private struct SnippetExpansion {
    let text: String
}
