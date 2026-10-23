import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBridgeUI

enum MainWindowLayout {
    // This constrains content; macOS adds toolbar/title-bar height. Allow the
    // complete window to reach the approved 980 × 680 review size.
    static let windowMinimumSize = CGSize(width: 980, height: 620)
    static let windowPreferredSize = CGSize(width: 1180, height: 760)
}

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @SceneStorage("mainWindowSelectedSection") private var selectedSectionRawValue = MainWindowSection.home.rawValue
    @State private var showingMediaImporter = false
    @State private var navGuardMessage: String?
    @State private var sidebarSelectionRevision = 0
    @ObservedObject private var navigation = OpenBridgeNavigation.shared
    @State private var showingCaptureSettings = false
    @State private var captureSettingsSection: MainSettingsSection = .general
    @State private var stopAfterSettingsDismissal = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 204, max: 220)
        } detail: {
            detailView(for: selectedSection)
                .navigationTitle(selectedSection.title)

        }
        .background(OpenBridgeTheme.canvas)
        .preferredColorScheme(.light)
        .font(OpenBridgeTypography.control)
        .tint(OpenBridgeTheme.brandBlue)
        .onReceive(navigation.$requestedSection) { section in
            guard let section else { return }
            navigate(to: section)
            navigation.requestedSection = nil
        }
        .fileImporter(
            isPresented: $showingMediaImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false,
            onCompletion: handleMediaImport
        )
        .sheet(isPresented: $showingCaptureSettings, onDismiss: {
            if stopAfterSettingsDismissal {
                stopAfterSettingsDismissal = false
                navigation.stopMeetingRequests.send(())
            }
        }) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Label("Your meeting keeps recording", systemImage: "record.circle")
                        .font(OpenBridgeTypography.heading(size: 18))
                    Spacer()
                    Button("Stop meeting") {
                        stopAfterSettingsDismissal = true
                        showingCaptureSettings = false
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                    .disabled(!appState.isMeetingRecording)
                    Button("Done") { showingCaptureSettings = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(20)
                Divider()
                MainSettingsPage(navigate: { section in
                    if section.group == .settings {
                        captureSettingsSection = section.settingsTab
                    } else {
                        showingCaptureSettings = false
                        navigate(to: section)
                    }
                }, initialSection: captureSettingsSection)
            }
            .font(OpenBridgeTypography.control)
            .background(OpenBridgeTheme.card)
            .frame(minWidth: 740, idealWidth: 860, minHeight: 520, idealHeight: 640)
        }
        .task {
            appState.refresh()
        }
    }

    private var selectedSection: MainWindowSection {
        MainWindowSection(rawValue: selectedSectionRawValue) ?? .home
    }

    private var selectedSectionBinding: Binding<MainWindowSection?> {
        Binding {
            MainWindowSection(rawValue: selectedSectionRawValue) ?? .home
        } set: { nextSection in
            let target = nextSection ?? .home

            navigate(to: target)
        }
    }

    private func navigate(to target: MainWindowSection) {
        if target.group == .settings, appState.isMeetingRecording {
            // Present the same hierarchy above the existing recorder owner.
            // Never replace Home while capture or finalization owns it.
            captureSettingsSection = target.settingsTab
            showingCaptureSettings = true
            return
        }
        if let message = MeetingHomeNavigation.blocker(
            leavingHome: target != .home,
            starting: appState.isMeetingStarting,
            recording: appState.isMeetingRecording
        ) {
            navGuardMessage = message
            // AppKit may highlight the attempted row even when its binding
            // rejects navigation. Refresh only the sidebar, never the recorder.
            sidebarSelectionRevision += 1
            return
        }
        navGuardMessage = nil
        selectedSectionRawValue = target.rawValue
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OpenBridgeBrandMark(size: 30)
                Text(AppIdentity.displayName).font(OpenBridgeTypography.heading(size: 18))
            }
            .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 30)
            Text("WORKSPACE").font(OpenBridgeTypography.body(size: 11, weight: .medium))
                .tracking(1).foregroundStyle(OpenBridgeTheme.mutedInk)
                .padding(.horizontal, 12).padding(.bottom, 10)
            ForEach(MainWindowSection.primary) { sidebarRow($0) }
            Spacer(minLength: 24)
            ForEach(MainWindowSection.support) { sidebarRow($0) }
            Divider().padding(.horizontal, 8).padding(.vertical, 16)
            Label("Local AI, your control.", systemImage: "lock")
                .font(OpenBridgeTypography.body(size: 12))
                .foregroundStyle(OpenBridgeTheme.brandGreen)
                .padding(.horizontal, 12).padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .background(OpenBridgeTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private func sidebarRow(_ section: MainWindowSection) -> some View {
        let isSelected = selectedSection.group == section
        return Button { navigate(to: section) } label: {
            Label(section.title, systemImage: section.systemImage)
                .font(OpenBridgeTypography.body(size: 15, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? OpenBridgeTheme.ink : OpenBridgeTheme.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(isSelected ? OpenBridgeTheme.brandBlue.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("navigation.\(section.rawValue)")
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detailView(for section: MainWindowSection) -> some View {
        switch section {
        case .home, .meetings:
            // One identity/owner above every adaptive layout. Home and library
            // never instantiate separate recording sessions.
            MainMeetingWorkspace(
                isLibrary: section == .meetings,
                showingMediaImporter: $showingMediaImporter,
                navGuardMessage: $navGuardMessage,
                onNavigate: { navigate(to: $0) }
            )
        case .dictation, .history, .transforms, .snippets, .dictionary:
            MainVoiceTypingPage(initialTab: section.voiceTab, navigate: navigate)
        case .transcribe, .transcribeYouTube:
            MainTranscribePage(initialTab: section == .transcribeYouTube ? .youtube : .files, navigate: navigate)
        case .models, .systemCheck, .settings:
            MainSettingsPage(navigate: navigate, initialSection: section.settingsTab)
        case .help:
            MainHelpPage(navigate: navigate)
        }
    }

    private func handleMediaImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                appState.statusMessage = "Choose an audio or video file to transcribe."
                return
            }
            Task { await appState.transcribeMediaFile(url) }
        case .failure(let error):
            appState.statusMessage = "File could not be opened: \(error.localizedDescription)"
        }
    }
}

enum MainWindowSection: String, CaseIterable, Identifiable, Hashable {
    case home, meetings, dictation, transforms, history, snippets, dictionary
    case transcribe, transcribeYouTube, models, systemCheck, help, settings

    var id: String { rawValue }
    static let primary: [Self] = [.home, .meetings, .dictation, .transcribe]
    static let support: [Self] = [.settings, .help]

    var group: Self {
        switch self {
        case .transforms, .history, .snippets, .dictionary: .dictation
        case .models, .systemCheck: .settings
        case .transcribeYouTube: .transcribe
        default: self
        }
    }

    var voiceTab: MainVoiceTypingTab {
        switch self {
        case .history: .history
        case .transforms: .textActions
        case .snippets: .snippets
        case .dictionary: .dictionary
        default: .preferences
        }
    }

    var settingsTab: MainSettingsSection {
        switch self {
        case .models: .models
        case .systemCheck: .systemCheck
        default: .general
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .meetings: "Meetings"
        case .dictation: "Voice typing"
        case .transforms: "Text actions"
        case .history: "History"
        case .snippets: "Snippets"
        case .dictionary: "Dictionary"
        case .transcribe, .transcribeYouTube: "Transcribe"
        case .models: "Models & performance"
        case .systemCheck: "System Check"
        case .help: "Help"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self.group {
        case .home: "house"
        case .meetings: "calendar"
        case .dictation: "waveform"
        case .transcribe: "doc.text"
        case .help: "questionmark.circle"
        default: "gearshape"
        }
    }
}

@MainActor
final class OpenBridgeNavigation: ObservableObject {
    static let shared = OpenBridgeNavigation()
    @Published var requestedSection: MainWindowSection?
    let stopMeetingRequests = PassthroughSubject<Void, Never>()

    func request(_ section: MainWindowSection) {
        requestedSection = section
    }
}

/// A live Stop action must remain outside modal content that can disable its
/// own controls while saving. Dismissal hands off to the mounted workspace;
/// this wrapper never owns, pauses, or stops a recorder directly.
struct MeetingAuxiliarySheet<Content: View>: View {
    let isRecording: Bool
    let isStopping: Bool
    let onStop: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if isRecording {
                HStack(spacing: 16) {
                    Label(isStopping ? "Finalizing your meeting" : "Your meeting keeps recording",
                          systemImage: isStopping ? "hourglass" : "record.circle")
                        .font(OpenBridgeTypography.heading(size: 18))
                        .foregroundStyle(OpenBridgeTheme.ink)
                    Spacer(minLength: 12)
                    Button(isStopping ? "Finalizing…" : "Stop meeting", action: onStop)
                        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                        .disabled(isStopping)
                        .accessibilityIdentifier("meeting.sheet.stop")
                }
                .padding(20)
                Divider()
            }
            content
        }
        .background(OpenBridgeTheme.card)
        .preferredColorScheme(.light)
    }
}

struct MainSidebarHeader: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            OpenBridgeBrandMark(size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.displayName)
                    .font(OpenBridgeTypography.heading(size: 20, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(appState.readyForDictation ? "Ready" : "Setup needed")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MainHomeTools: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showingMediaImporter: Bool
    @State private var youtubeURL = ""
    @State private var showingYouTube = false
    @State private var showingLatestTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { toolButtons }
                VStack(alignment: .leading, spacing: 12) { toolButtons }
            }
            .buttonStyle(.bordered)
            if showingYouTube { MainHomeYouTubePanel(youtubeURL: $youtubeURL) }
            if appState.mediaTranscriptionResult != nil || !appState.lastTranscript.isEmpty || !appState.dictationHistory.isEmpty {
                DisclosureGroup("Latest file or dictation transcript", isExpanded: $showingLatestTranscript) {
                    MainRecentActivityPanel().padding(.top, 12)
                }
            }
        }
        .onChange(of: appState.mediaTranscriptionResult?.createdAt) { _, value in
            if value != nil { showingLatestTranscript = true }
        }
        .onChange(of: appState.lastTranscriptCreatedAt) { _, value in
            if value != nil { showingLatestTranscript = true }
        }
    }

    @ViewBuilder private var toolButtons: some View {
        Button {
            Task { await appState.toggleDictation() }
        } label: {
            Label(appState.isStandardRecording ? "Stop dictation" : "Dictate", systemImage: "mic")
        }
        .disabled(appState.isRecording && !appState.isStandardRecording)
        .help("Dictate using \(appState.hotkeyDescription)")
        Button { showingMediaImporter = true } label: {
            Label("Transcribe a file", systemImage: "doc.badge.plus")
        }
        .disabled(!appState.canStartMediaTranscription)
        Button { showingYouTube.toggle() } label: {
            Label("YouTube", systemImage: "play.rectangle")
        }
        .accessibilityValue(showingYouTube ? "Expanded" : "Collapsed")
    }
}

struct MainHomeYouTubePanel: View {
    @EnvironmentObject private var appState: AppState
    @Binding var youtubeURL: String

    private var trimmedURL: String {
        youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        MainInfoCard("Transcribe a YouTube video", systemImage: "play.rectangle") {
            Text("Paste a YouTube link. Downloaded audio is transcribed on this Mac.")
                .font(OpenBridgeTypography.body(size: 16))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://youtube.com/watch?v=...", text: $youtubeURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!appState.canStartMediaTranscription)

                Button {
                    Task { await appState.transcribeYouTubeURL(youtubeURL) }
                } label: {
                    Label("Transcribe", systemImage: "waveform")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                .disabled(!appState.canStartMediaTranscription || trimmedURL.isEmpty)
                .help("Transcribe this YouTube URL locally")
            }

            if appState.isTranscribingMedia {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.statusMessage)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .lineLimit(2)
                }
            }

            MainHomeStorageNote()
        }
    }
}

struct MainHomeStorageNote: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder")
                .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.brandGold)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text("Where transcripts go")
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text("Your current result appears in Transcribe. Use Copy or Save As to keep it; voice typing history stays local.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.42))
        }
    }
}

struct MainHomeSetupPanel: View {
    @EnvironmentObject private var appState: AppState
    let microphoneName: String
    let navigate: (MainWindowSection) -> Void

    var body: some View {
        MeetingHomeSetupSummary(
            microphone: microphoneName,
            model: appState.selectedModelDisplayName,
            modelStatus: appState.selectedModelRuntimeStatusLabel,
            readiness: appState.readyForMediaTranscription
                ? "Speech model ready. Audio access is checked for your selected sources."
                : appState.mediaSetupMessage,
            onSystemCheck: { navigate(.systemCheck) },
            onModels: { navigate(.models) },
            onSettings: { navigate(.settings) }
        )
    }
}

struct MeetingStartGate: Equatable {
    let title: String
    let isMeetingRecording: Bool
    let isMeetingStopping: Bool
    let isMeetingStarting: Bool
    let isDictationStarting: Bool
    let isRecoveryRetryRunning: Bool
    let readyForDictation: Bool
    let setupMessage: String
    let cleanupBlocker: String?

    init(
        title: String,
        isMeetingRecording: Bool,
        isMeetingStopping: Bool,
        isMeetingStarting: Bool,
        isDictationStarting: Bool,
        isRecoveryRetryRunning: Bool,
        readyForDictation: Bool,
        setupMessage: String,
        cleanupBlocker: String? = nil
    ) {
        self.title = title
        self.isMeetingRecording = isMeetingRecording
        self.isMeetingStopping = isMeetingStopping
        self.isMeetingStarting = isMeetingStarting
        self.isDictationStarting = isDictationStarting
        self.isRecoveryRetryRunning = isRecoveryRetryRunning
        self.readyForDictation = readyForDictation
        self.setupMessage = setupMessage
        self.cleanupBlocker = cleanupBlocker
    }

    var blockerText: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this meeting a name to enable Start meeting."
        }
        if isMeetingRecording {
            return "A meeting is already recording."
        }
        if isMeetingStopping {
            return "Wait for the current meeting to finish saving."
        }
        if isMeetingStarting {
            return "Wait for the meeting to finish starting."
        }
        if isDictationStarting {
            return "Wait for dictation to finish starting."
        }
        if isRecoveryRetryRunning {
            return "Finish the recovery retry before starting a meeting."
        }
        if !readyForDictation {
            return setupMessage
        }
        return nil
    }

    var canStart: Bool { blockerText == nil }

    // Optional cloud setup requires an explicit recovery choice, not a disabled
    // recording entry point. Runtime provider/permission guards still apply.
    var helperText: String { blockerText ?? cleanupBlocker ?? "Ready to record." }
}

struct MainMeetingWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var providerSettings: ProviderSettingsController
    let isLibrary: Bool
    @Binding var showingMediaImporter: Bool
    @Binding var navGuardMessage: String?
    let onNavigate: (MainWindowSection) -> Void
    @State private var optionsExpanded = false
    @State private var meetingTitle = ""
    @State private var audioSelection: MeetingAudioSelection = .microphone
    @State private var hasMacAudioPermission = CGPreflightScreenCaptureAccess()
    @State private var startRecovery: MeetingStartRecovery?
    @State private var pendingStartRecoveryAction: MeetingStartRecoveryAction?
    @State private var showingStartCloudSettings = false
    @StateObject private var startCloudDrafts = ProviderSettingsDrafts()
    @State private var audioHealth: MeetingAudioHealth?
    @State private var microphoneHealth: MeetingAudioHealth?
    private var captureMode: MeetingCaptureMode { audioSelection.captureMode }
    @State private var systemMeterLevel = 0.0
    @State private var selectedMicrophoneID: String?
    @State private var retentionPolicy: MeetingRetentionPolicy = .keepUntilDeleted
    /// lunr-studio/Openbridge-Beta#214: a destructive retention selection (auto-delete / never-store /
    /// delete-audio-after-transcript) is held here until the user confirms.
    @State private var pendingRetentionPolicy: MeetingRetentionPolicy?
    @State private var showingDestructiveRetentionConfirmation = false
    @State private var aiMode: MeetingAIMode = .transcriptionOnly
    @State private var cloudAnswersEnabled = false
    private var meetingPermissionMode: MeetingAIMode {
        MeetingAIChoices.permissionMode(research: cloudAnswersEnabled, cleanup: aiMode)
    }
    @State private var showingResearchPermissions = false
    @State private var openSettingsAfterResearchDismissal = false
    @State private var stopAfterReplayDismissal = false
    @State private var stopAfterResearchDismissal = false
    @State private var selectedWorkspaceID: String = Workspace.defaultWorkspace.id
    @State private var workspaces: [Workspace] = [Workspace.defaultWorkspace]
    @State private var showingStartConfirmation = false
    @State private var showingStopConfirmation = false
    @State private var isMeetingRecording = false
    /// Wave-7 (3836482852 + 3836998423): true from the moment the user
    /// confirms Stop until finalization fully completes. Set SYNCHRONOUSLY
    /// before awaiting `stopRecording()` so the 0.1s meter callback stops
    /// launching live segment work during the recorder-await window (and a
    /// repeated Stop confirm cannot re-enter the recorder).
    @State private var isMeetingStopping = false
    @State private var meetingElapsedSeconds: TimeInterval = 0
    @State private var meetingSegmentCount = 0
    @State private var meetingMeterLevel: Double = 0
    @State private var meetingError: String?
    @State private var stopToast: String?
    @State private var recordingStartedAt: Date?
    @State private var savedMeetings: [MeetingManifest] = []
    @State private var pendingBulkDelete: [MeetingManifest] = []
    @State private var showingBulkDeleteConfirmation = false
    @State private var bulkDeletionInFlight = false
    @State private var showingLibraryResearch = false
    @State private var recentMeetingID: String?
    @State private var meetingSearchText = ""
    @State private var selectedReplayMeeting: MeetingManifest?
    @State private var selectedResearchSourceSegmentID: String?
    @State private var pendingDeleteMeeting: MeetingManifest?
    @State private var showingDeleteMeetingConfirmation = false
    @State private var pendingCloudRetryMeeting: MeetingManifest?
    @State private var showingCloudRetryConfirmation = false
    // lunr-studio/Openbridge-Beta#219: recovery finalize confirmation.
    @State private var pendingFinalizeMeeting: MeetingManifest?
    @State private var showingFinalizeRecoveryConfirmation = false
    @State private var meetingStatusToast: String?

    // Persistent instances — same recorder/store used across Start/Stop
    @State private var store = MeetingSessionStore()
    @State private var recorder: (any MeetingRecording)?
    @State private var activeMeetingID: String?
    @State private var recordingIntelligenceConfiguration: MeetingIntelligenceConfiguration?
    @StateObject private var transcriber = MeetingTranscriber(
        store: MeetingSessionStore(),
        modelIdentifier: "",
        customDictionaryURL: URL(fileURLWithPath: "/dev/null")
    )

    private let defaultRetentionPolicyKey = "meetingDefaultRetentionPolicy"

    private var meetingStartGate: MeetingStartGate {
        MeetingStartGate(
            title: meetingTitle,
            isMeetingRecording: isMeetingRecording,
            isMeetingStopping: isMeetingStopping,
            isMeetingStarting: appState.isMeetingStarting,
            isDictationStarting: appState.isStartingRecording,
            isRecoveryRetryRunning: appState.recoveryRetryTask != nil,
            readyForDictation: appState.readyForMediaTranscription,
            setupMessage: appState.mediaSetupMessage,
            cleanupBlocker: cleanupChoiceBlocker
        )
    }

    private var cleanupChoiceBlocker: String? {
        guard cloudAnswersEnabled || aiMode == .cloudOptIn else { return nil }
        guard providerSettings.settings.cloudEnabled,
              providerSettings.settings.consentGranted,
              providerSettings.hasCredential,
              providerSettings.hasCurrentTestAttestation else {
            if !providerSettings.hasCredential && providerSettings.canLoadSavedCredential {
                return "In Settings → Cloud AI, choose Load saved key. Test Connection only if it is not already verified. Or use local recording for this meeting."
            }
            return "Configure your provider and pass Test Connection in Settings → Cloud AI. Or use local recording for this meeting."
        }
        return nil
    }

    private var startSetupRecovery: MeetingStartRecovery? {
        MeetingStartRecovery.resolve(audio: audioSelection,
            supportsMacAudio: supportsMacAudio, hasMacAudioPermission: hasMacAudioPermission,
            cloudBlocker: cleanupChoiceBlocker)
    }

    private var startHelperText: String {
        meetingStartGate.blockerText ?? startSetupRecovery?.summary ?? "Ready to record."
    }

    private var supportsMacAudio: Bool {
        if #available(macOS 15, *) { true } else { false }
    }

    private func requestMeetingStart() {
        guard meetingStartGate.canStart else { return }
        meetingError = nil
        hasMacAudioPermission = CGPreflightScreenCaptureAccess()
        if let recovery = startSetupRecovery {
            startRecovery = recovery
        } else {
            showingStartConfirmation = true
        }
    }

    /// Run navigation or the next confirmation only after the sheet closes.
    /// Activation/permission refresh alone must never start a recording.
    private func finishStartRecovery() {
        guard let action = pendingStartRecoveryAction else { return }
        pendingStartRecoveryAction = nil
        switch action {
        case .configureCloud:
            showingStartCloudSettings = true
        case .useLocalRecording:
            cloudAnswersEnabled = false
            aiMode = MeetingStartRecovery.localCleanupChoice(aiMode)
            requestMeetingStart()
        case .requestMacAudioAccess:
            hasMacAudioPermission = CGRequestScreenCaptureAccess()
            requestMeetingStart()
        case .openMacAudioSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .checkMacAudioAccess:
            requestMeetingStart()
        case .chooseMicrophone:
            audioSelection = .microphone
            requestMeetingStart()
        }
    }

    var body: some View {
        // Recorder lifetime is independent of the adaptive presentation below.
        VStack(spacing: 0) {
            if isMeetingRecording {
                MeetingHomeRecordingHeader(
                    title: meetingTitle, elapsed: elapsedTimeString, isStopping: isMeetingStopping,
                    microphone: microphoneName, microphoneLevel: meetingMeterLevel,
                    systemLevel: audioSelection.includesMacAudio ? systemMeterLevel : nil,
                    configurationSummary: configurationSummary,
                    onStop: { showingStopConfirmation = true },
                    includesMicrophone: audioSelection.includesMicrophone,
                    systemStatus: audioHealth?.title,
                    microphoneStatus: microphoneHealth?.title
                )
            }
            ResearchGatedMeetingsContent(
                transcript: workspacePage,
                isPresented: isMeetingRecording || (isLibrary ? showingLibraryResearch : appState.meetingResearch.snapshot.meetingTitle != nil),
                makeViewModel: { ObservatoryRailBridge.shared.makeViewModel() }
            )
        }
        .alert(
            "Finalize this interrupted meeting?",
            isPresented: $showingFinalizeRecoveryConfirmation
        ) {
            Button("Finalize") {
                if let pendingFinalizeMeeting {
                    finalizeRecoveredMeeting(pendingFinalizeMeeting)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\"\(pendingFinalizeMeeting?.title ?? "")\" stopped unexpectedly. "
                    + "Finalizing keeps all recorded audio and any live segments "
                    + "and marks the meeting complete."
                    // Wave-12 (3876176439): when the policy is
                    // deleteAudioAfterTranscript, finalizing ALSO deletes the
                    // raw audio once the transcript is verified - the
                    // confirmation must not promise otherwise.
                    + (pendingFinalizeMeeting?.retentionPolicy == .deleteAudioAfterTranscript
                        ? " This meeting's retention policy deletes the raw audio after the transcript is verified."
                        : "")
            )
        }
        .alert("Delete this meeting?", isPresented: $showingDeleteMeetingConfirmation) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteMeeting {
                    deleteMeeting(pendingDeleteMeeting)
                }
                pendingDeleteMeeting = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteMeeting = nil
            }
        } message: {
            Text("This permanently removes \"\(pendingDeleteMeeting?.title ?? "this meeting")\", its audio and transcript from this Mac. This cannot be undone. Export anything you want to keep first.")
        }
        .alert("Delete \(pendingBulkDelete.count) selected meetings?", isPresented: $showingBulkDeleteConfirmation) {
            Button("Delete selected", role: .destructive) { deleteSelectedMeetings() }
            Button("Cancel", role: .cancel) { pendingBulkDelete = [] }
        } message: {
            Text(MeetingDeletionSelection.confirmation(pendingBulkDelete))
        }
        // lunr-studio/Openbridge-Beta#214: destructive retention selection requires confirmation.
        .alert("Change retention policy?", isPresented: $showingDestructiveRetentionConfirmation) {
            Button("Apply", role: .destructive) {
                if let candidate = pendingRetentionPolicy {
                    retentionPolicy = candidate
                    UserDefaults.standard.set(candidate.rawValue, forKey: defaultRetentionPolicyKey)
                }
                pendingRetentionPolicy = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRetentionPolicy = nil
            }
        } message: {
            Text("\(pendingRetentionPolicy?.displayName ?? "This policy") automatically removes meeting data. This applies to future meetings using the default retention setting.")
        }
        .sheet(item: $startRecovery, onDismiss: finishStartRecovery) { recovery in
            MeetingStartRecoveryView(recovery: recovery) { action in
                pendingStartRecoveryAction = action
            }
        }
        .sheet(isPresented: $showingStartCloudSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Cloud AI setup").font(OpenBridgeTypography.heading(size: 20))
                    Spacer()
                    Button("Back to meeting") { showingStartCloudSettings = false }
                        .keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                ScrollView {
                    ProviderSettingsView(drafts: startCloudDrafts)
                        .padding(24)
                }
            }
            .frame(width: 780, height: 620)
            .background(OpenBridgeTheme.canvas)
        }
        .alert("Start meeting?", isPresented: $showingStartConfirmation) {
            Button("Start") {
                // Wave-26 (3842499334): latch the start flag SYNCHRONOUSLY
                // before the async task - navigation finishing first must
                // not find the flags unset and orphan a recorder.
                appState.beginMeetingStart()
                Task { await startMeeting(preLatched: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(audioSelection.title). \(audioSelection.notice) Make sure participants are aware.")
        }
        .alert("Retry cloud cleanup?", isPresented: $showingCloudRetryConfirmation) {
            Button("Retry and send") {
                if let meeting = pendingCloudRetryMeeting {
                    retryInterruptedCleanup(meeting, cloudChargeConfirmed: true)
                }
                pendingCloudRetryMeeting = nil
            }
            Button("Cancel", role: .cancel) {
                pendingCloudRetryMeeting = nil
            }
        } message: {
            Text("This sends the meeting transcript text to the configured provider again. Another provider charge may occur.")
        }
        .alert("Stop meeting?", isPresented: $showingStopConfirmation) {
            Button("Stop", role: .destructive) { stopMeeting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Wave-1 (3875726293): policy-aware - under deleteAudioAfterTranscript
            // the raw audio is removed after a successful finalization, so the
            // confirmation must not promise the recording is saved.
            if retentionPolicy == .deleteAudioAfterTranscript {
                Text("This will finalize the recording. Under the current retention policy, the raw audio is deleted once the transcript is verified.")
            } else {
                Text("This will finalize the recording. Audio segments will be saved locally.")
            }
        }
        .onReceive(elapsedTimer) { _ in
            if isMeetingRecording, let start = recordingStartedAt {
                meetingElapsedSeconds = Date().timeIntervalSince(start)
            }
        }
        .onReceive(meterTimer) { _ in
            // Wave-7 (3836998423): during the stop window (recorder await +
            // finalization) ticks must not launch live work - the tail
            // segment belongs to the finalizer, and live taps must not fire
            // after the user pressed Stop.
            if isMeetingRecording && !isMeetingStopping {
                meetingMeterLevel = recorder?.lastMeterLevel ?? 0
                systemMeterLevel = recorder?.systemMeterLevel ?? 0
                audioHealth = recorder?.systemAudioHealth
                microphoneHealth = recorder?.microphoneAudioHealth
                if audioHealth == .awaitingAudio { systemMeterLevel = 0 }
                if microphoneHealth == .awaitingAudio { meetingMeterLevel = 0 }
                if let r = recorder {
                    if let captureError = r.fatalCaptureError {
                        // The recorder has already stopped the hardware and
                        // marked the durable session failed. Leave the active
                        // capture UI immediately instead of appearing to keep
                        // recording after storage/device failure.
                        tearDownFailedMeetingCapture(recorder: r, error: captureError)
                        return
                    }
                    meetingSegmentCount = r.completedSegmentCount
                    transcriber.checkForNewSegments(recorder: r)
                }
            }
            if let r = recorder, let id = activeMeetingID {
                appState.meetingResearch.updateProgress(MeetingResearchProgress(meetingID: id,
                    sources: r.researchCaptureProgress, transcription: transcriber.researchTranscriptionProgress,
                    isRecording: r.isRecording))
            }
        }
        .task {
            refreshSavedMeetings()
            reconstructDeferredCleanups()
            if !appState.postStopCleanupFailureMessages.isEmpty {
                showStopToast(appState.postStopCleanupFailureMessages.joined(separator: "\n"))
                appState.postStopCleanupFailureMessages.removeAll()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MeetingSessionStore.manifestDidChangeNotification
            )
            .receive(on: RunLoop.main)
        ) { _ in
            // Cleanup and final transcription persist through the shared
            // store. Reload from disk on every durable transition so the
            // main list and latest-meeting panel never retain the post-Stop
            // snapshot while Replay sees newer state.
            refreshSavedMeetings()
        }
        .task {
            // Load workspaces from local storage on appear
            let workspaceStore = WorkspaceStore()
            if let loaded = try? workspaceStore.load() {
                workspaces = loaded
            }
            // Load the persisted default retention policy so the picker
            // remembers the user's choice across launches.
            if let stored = UserDefaults.standard.string(forKey: defaultRetentionPolicyKey),
               let policy = MeetingRetentionPolicy(rawValue: stored) {
                retentionPolicy = policy
            }

            // Enforce retention on appear — prune expired meetings.
            do {
                let deleted = try store.enforceRetentionPolicy()
                if deleted > 0 {
                    appState.statusMessage = "Removed \(deleted) expired meeting(s)."
                }
            } catch {
                // Non-fatal — retention enforcement failure shouldn't block the UI
            }

            refreshSavedMeetings()
        }
        .sheet(item: $selectedReplayMeeting, onDismiss: {
            if stopAfterReplayDismissal {
                stopAfterReplayDismissal = false
                OpenBridgeNavigation.shared.stopMeetingRequests.send(())
            }
        }) { meeting in
            MeetingAuxiliarySheet(isRecording: isMeetingRecording, isStopping: isMeetingStopping, onStop: {
                stopAfterReplayDismissal = true
                selectedReplayMeeting = nil
            }) {
                // lunr-studio/Openbridge-Beta#321 (AC5) + wave-1 (3884760779): retry re-routes through the
                // app-scoped deferred cleanup pump; cancel routes through the
                // app-scoped cleanup owner so it stops the QUEUE + IN-FLIGHT
                // task and suppresses requeue, not just the durable job record.
                MeetingReplayView(
                    manifest: meeting,
                    store: store,
                    researchSourceSegmentID: selectedResearchSourceSegmentID,
                    onAskAnything: { replayMeeting in
                        ObservatoryRailBridge.shared.beginAsk(from: replayMeeting)
                        showingLibraryResearch = true
                    },
                    onRetryCleanup: { replayMeeting in
                        retryInterruptedCleanup(replayMeeting)
                    },
                    onCancelCleanup: { replayMeeting in
                        cancelPostStopCleanup(replayMeeting)
                    },
                    onCleanLocally: { replayMeeting in
                        cleanLocallyAfterCloudFailure(replayMeeting)
                    },
                    isCleanupDeferred: { replayMeeting in
                        appState.deferredCleanupQueue.contains(replayMeeting.meetingID)
                    }
                )
                .frame(minWidth: 600, minHeight: 500)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ResearchSourceNavigationRequest.notification)) { notification in
            guard let request = notification.object as? ResearchSourceNavigationRequest else { return }
            let meetingID = request.meetingID.isEmpty
                ? (appState.activeMeetingID ?? "")
                : request.meetingID
            guard !meetingID.isEmpty,
                  let meeting = try? store.load(meetingID: meetingID) else { return }
            selectedResearchSourceSegmentID = request.segmentID
            selectedReplayMeeting = meeting
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageMeetingResearch)) { _ in
            showingResearchPermissions = true
        }
        .onReceive(OpenBridgeNavigation.shared.stopMeetingRequests) { _ in
            guard isMeetingRecording, !isMeetingStopping else { return }
            showingStopConfirmation = true
        }
        .sheet(isPresented: $showingResearchPermissions, onDismiss: {
            if stopAfterResearchDismissal {
                stopAfterResearchDismissal = false
                openSettingsAfterResearchDismissal = false
                OpenBridgeNavigation.shared.stopMeetingRequests.send(())
            } else if openSettingsAfterResearchDismissal {
                openSettingsAfterResearchDismissal = false
                onNavigate(.settings)
            }
        }) {
            MeetingAuxiliarySheet(isRecording: isMeetingRecording, isStopping: isMeetingStopping, onStop: {
                stopAfterResearchDismissal = true
                showingResearchPermissions = false
            }) {
                MeetingResearchPermissionView(controller: appState.meetingResearch, providerSettings: providerSettings) {
                    // Wait for the first sheet to close before presenting Settings.
                    openSettingsAfterResearchDismissal = true
                }
            }
        }
    }

    @ViewBuilder
    private var workspacePage: some View {
        if isMeetingRecording {
            activeMeetingView
        } else {
            MainPageScaffold {
                if isLibrary { meetingLibraryView } else { meetingSetupView }
            }
        }
    }

    @ViewBuilder
    private var navGuardToastView: some View {
        if let message = navGuardMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(OpenBridgeTheme.brandCoral)

                Text(message)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Spacer(minLength: 0)

                Button {
                    dismissNavGuardToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenBridgeTheme.brandCoral.opacity(0.1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OpenBridgeTheme.brandCoral.opacity(0.3), lineWidth: 1)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func dismissNavGuardToast() {
        withAnimation { navGuardMessage = nil }
    }

    @ViewBuilder
    private var stopToastView: some View {
        if let message = stopToast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OpenBridgeTheme.brandTeal)

                Text(message)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Spacer(minLength: 0)

                Button {
                    withAnimation { stopToast = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenBridgeTheme.brandTeal.opacity(0.1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OpenBridgeTheme.brandTeal.opacity(0.3), lineWidth: 1)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func showStopToast(_ message: String) {
        withAnimation { stopToast = message }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                withAnimation { stopToast = nil }
            }
        }
    }

    @ViewBuilder
    private var latestMeetingCompletionPanel: some View {
        if let recentMeetingID,
           let meeting = savedMeetings.first(where: { $0.meetingID == recentMeetingID }) {
            let presentation = MeetingProcessingPresentation.make(
                manifest: meeting,
                isCleanupDeferred: appState.deferredCleanupQueue.contains(meeting.meetingID)
            )
            MainLatestMeetingPanel(
                meeting: meeting,
                presentation: presentation,
                onReplay: {
                    selectedResearchSourceSegmentID = nil
                    selectedReplayMeeting = meeting
                },
                onExport: {
                    exportMeeting(meeting)
                },
                onRetryCleanup: presentation.allowsCleanupRetry ? {
                    retryInterruptedCleanup(meeting)
                } : nil
            )
        }
    }

    private var microphoneName: String {
        guard audioSelection.includesMicrophone else { return "Microphone off" }
        let id = selectedMicrophoneID ?? appState.selectedMicrophoneID
        return appState.microphoneDevices.first(where: { $0.id == id })?.pickerTitle ?? "System default"
    }

    private var optionsSummary: String {
        let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID })?.name ?? "Default workspace"
        let cleanup = aiMode == .transcriptionOnly ? "No cleanup" : (aiMode == .localOnly ? "Local cleanup after Stop" : "Cloud cleanup after Stop")
        return "\(workspace) · \(retentionPolicy.displayName) · \(cleanup)"
    }

    private var configurationSummary: String {
        let capture = audioSelection.title
        let researchOn = isMeetingRecording ? appState.meetingResearch.snapshot.researchAccess?.canAsk == true : cloudAnswersEnabled
        return "\(capture) · Research \(researchOn ? "cloud on" : "off") · \(optionsSummary)"
    }

    private var meetingSetupView: some View {
        VStack(alignment: .leading, spacing: 24) {
            MeetingHomeSetupHeading(
                canStart: meetingStartGate.canStart,
                isStarting: appState.isMeetingStarting,
                helperText: startHelperText,
                onStart: requestMeetingStart
            )
            navGuardToastView
            stopToastView
            MeetingHomeColumns {
                MeetingHomeForm(
                    title: $meetingTitle, cloudAllowed: $cloudAnswersEnabled,
                    optionsExpanded: $optionsExpanded,
                    helperText: meetingError ?? startHelperText,
                    canStart: meetingStartGate.canStart,
                    isStarting: appState.isMeetingStarting,
                    providerLabel: "\(providerSettings.settings.providerLabel) · \(providerSettings.settings.model)",
                    optionsSummary: optionsSummary,
                    cleanup: $aiMode,
                    showsStartButton: false,
                    onSettings: { onNavigate(.settings) },
                    onStart: requestMeetingStart
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        OnlineMeetingSetupControls(selection: $audioSelection, hasPermission: $hasMacAudioPermission)
                        if audioSelection.includesMicrophone {
                        Picker("Microphone", selection: Binding(
                            get: { selectedMicrophoneID ?? appState.selectedMicrophoneID },
                            set: { selectedMicrophoneID = $0 }
                        )) {
                            ForEach(appState.microphoneDevices) { device in
                                Text(device.pickerTitle).tag(device.id)
                            }
                        }
                        .pickerStyle(.menu)
                        }
                    }
                } options: {
                    meetingAdvancedOptions
                }
                VStack(alignment: .leading, spacing: 24) {
                    MainHomeSetupPanel(microphoneName: microphoneName, navigate: onNavigate)
                    MeetingHomePanel(title: "Another way to capture") {
                        homeShortcut("Voice typing", detail: "Speak into any app", icon: "waveform", destination: .dictation)
                        Divider()
                        homeShortcut("Transcribe a file", detail: "Audio or video you already have", icon: "doc.text", destination: .transcribe)
                        Divider()
                        homeShortcut("YouTube", detail: "Start with a video link", icon: "play.rectangle", destination: .transcribeYouTube)
                    }
                }
            }
            latestMeetingCompletionPanel
            meetingStatusToastView
            recentMeetingsView
            HStack {
                Text("Your voice typing is kept in History.")
                    .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk)
                Spacer()
                Button { onNavigate(.history) } label: {
                    Label("Recent text", systemImage: "clock.arrow.circlepath")
                }.buttonStyle(.link)
            }
        }
    }

    private func homeShortcut(_ title: String, detail: String, icon: String, destination: MainWindowSection) -> some View {
        Button { onNavigate(destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(OpenBridgeTheme.mutedInk).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    Text(detail).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(OpenBridgeTypography.body(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var meetingAdvancedOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace")
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                Picker("Workspace", selection: $selectedWorkspaceID) {
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Retention")
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                Picker("Retention", selection: Binding(
                    get: { retentionPolicy },
                    set: { candidate in
                        // lunr-studio/Openbridge-Beta#214: destructive policies require
                        // confirmation before they are applied.
                        if candidate.isDestructive, candidate != retentionPolicy {
                            pendingRetentionPolicy = candidate
                            showingDestructiveRetentionConfirmation = true
                        } else {
                            retentionPolicy = candidate
                            UserDefaults.standard.set(candidate.rawValue, forKey: defaultRetentionPolicyKey)
                        }
                    }
                )) {
                    Text("Keep until deleted").tag(MeetingRetentionPolicy.keepUntilDeleted)
                    Text("Delete after 7 days").tag(MeetingRetentionPolicy.autoDeleteAfter7Days)
                    Text("Delete after 30 days").tag(MeetingRetentionPolicy.autoDeleteAfter30Days)
                    // lunr-studio/Openbridge-Beta#214: expose the never-store-transcript and
                    // delete-audio-after-transcript policies
                    // (previously omitted from the picker).
                    Text("Never store transcript").tag(MeetingRetentionPolicy.neverStoreTranscript)
                    Text("Delete audio after transcript").tag(MeetingRetentionPolicy.deleteAudioAfterTranscript)
                }
                // lunr-studio/Openbridge-Beta#321 QA (7.3): a 5-option
                // SEGMENTED picker overflows at narrow window widths - it
                // clipped the label, left dead space, and expanded
                // vertically. A MENU picker is the standard macOS pattern
                // for 5+ options: compact at any width, label preserved,
                // and the destructive-confirmation binding is unchanged.
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Dictionary is shared across OpenBridge.")
                .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk)
            Button("Review shared Dictionary →") { onNavigate(.dictionary) }.buttonStyle(.link)
        }
    }

    private var meetingLibraryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                MainPageHeader(title: "Meetings", subtitle: "Find, replay and export your saved meetings.",
                               statusText: "Local library", statusTint: OpenBridgeTheme.brandTeal)
                Spacer()
                if ResearchObservatoryFeatureFlag.isEnabled {
                    Button(showingLibraryResearch ? "Hide research" : "Show research") { showingLibraryResearch.toggle() }
                        .buttonStyle(.bordered)
                }
                Button("New meeting") { onNavigate(.home) }
                    .buttonStyle(.borderedProminent).tint(OpenBridgeTheme.ink)
            }
            stopToastView
            meetingStatusToastView
            MainSavedMeetingsCard(
                savedMeetings: savedMeetings,
                onReplay: { meeting in
                    selectedResearchSourceSegmentID = nil
                    selectedReplayMeeting = meeting
                },
                onDelete: { meeting in
                    pendingDeleteMeeting = meeting
                    showingDeleteMeetingConfirmation = true
                },
                onDeleteSelected: { meetings in
                    pendingBulkDelete = meetings
                    showingBulkDeleteConfirmation = true
                },
                onExport: { meeting in
                    exportMeeting(meeting)
                },
                onFinalizeRecovery: { meeting in
                    pendingFinalizeMeeting = meeting
                    showingFinalizeRecoveryConfirmation = true
                },
                onRevealRecoveredFiles: { meeting in
                    revealMeetingFiles(meeting)
                },
                onRetryTranscription: { meeting in
                    retryRecoveredTranscription(meeting)
                },
                onRetryCleanup: { meeting in
                    retryInterruptedCleanup(meeting)
                },
                isCleanupDeferred: { meeting in
                    appState.deferredCleanupQueue.contains(meeting.meetingID)
                },
                searchText: $meetingSearchText
            )
            .disabled(bulkDeletionInFlight || meetingDeletionInFlight)
            if bulkDeletionInFlight {
                ProgressView("Deleting selected meetings…").controlSize(.small)
            }
        }
    }

    private var recentMeetingsView: some View {
        MeetingHomePanel(title: "Recent meetings") {
            if savedMeetings.isEmpty {
                Text("Your first saved meeting will appear here.")
                    .font(OpenBridgeTypography.body(size: 15)).foregroundStyle(OpenBridgeTheme.mutedInk)
            } else {
                ForEach(MeetingHomeNavigation.recentMeetings(savedMeetings)) { meeting in
                    Button {
                        selectedResearchSourceSegmentID = nil
                        selectedReplayMeeting = meeting
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(meeting.title).font(OpenBridgeTypography.body(size: 15, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                            Image(systemName: "chevron.right").font(OpenBridgeTypography.body(size: 13))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open saved meeting")
                }
            }
            Button("View all meetings") { onNavigate(.meetings) }.buttonStyle(.link)
        }
    }

    private var activeMeetingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            navGuardToastView
            MeetingHomePanel(title: "Live transcript", titleBadge: "Draft") {
                MeetingLiveTranscriptNotice(configuration: recordingIntelligenceConfiguration)
                if transcriber.transcriptText.isEmpty {
                    if transcriber.isTranscribing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Transcribing...")
                                .font(OpenBridgeTypography.body(size: 13))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                        }
                    } else if let error = transcriber.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.brandCoral)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        MainEmptyState(
                            systemImage: "waveform",
                            title: "Listening...",
                            subtitle: "Transcript text will appear here about every 30 seconds."
                        )
                    }
                } else {
                    ScrollView {
                        Text(transcriber.transcriptText)
                            .font(OpenBridgeTypography.body)
                            .lineSpacing(10)
                            .foregroundStyle(OpenBridgeTheme.ink)
                            .frame(maxWidth: 700, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if transcriber.isTranscribing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Processing next segment...")
                                .font(OpenBridgeTypography.body(size: 13))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                        }
                    }

                    if let error = transcriber.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.brandCoral)
                    }
                }
            }

        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OpenBridgeTheme.canvas)
    }

    @ViewBuilder
    private var meetingStatusToastView: some View {
        if let toast = meetingStatusToast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OpenBridgeTheme.brandTeal)

                Text(toast)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Spacer(minLength: 0)

                Button {
                    dismissToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenBridgeTheme.brandTeal.opacity(0.1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OpenBridgeTheme.brandTeal.opacity(0.3), lineWidth: 1)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var elapsedTimeString: String {
        let total = Int(meetingElapsedSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Recording actions

    private func startMeeting(preLatched: Bool = false) async {
        // Wave-10/11 (3837632196, 3837659903): the guard runs BEFORE any
        // await and lives at APP scope - it survives navigating away from
        // Meetings and back, so while this task is suspended (e.g. awaiting
        // cleanup termination) no fresh page can race a second Start into
        // manifest/recorder creation.
        // Wave-27 (3842942701): the Start action latches the flag
        // SYNCHRONOUSLY (wave-26); a pre-latched call already owns the latch
        // and must proceed - only un-latched callers are duplicate-checked.
        if !preLatched {
            guard !appState.isMeetingStarting,
                  !appState.isStartingRecording,
                  !isMeetingRecording,
                  !isMeetingStopping
            else { return }
            appState.beginMeetingStart()
        }
        defer { appState.endMeetingStart() }

        // Wave-8/9/10 (3837539266, 3837588529, 3837632200): a still-running
        // post-Stop cleanup - now APP-OWNED, surviving navigation away from
        // Meetings - is cancelled AND awaited to termination before capture
        // starts; cancel() only requests it, the engine's process must
        // actually exit so no Gemma inference overlaps recording (AGENTS L42).
        if let cleanup = appState.postStopCleanupTask {
            cleanup.cancel()
            _ = await cleanup.value
            appState.postStopCleanupTask = nil
        }

        do {
            if audioSelection.includesMicrophone {
                var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    granted = await AVCaptureDevice.requestAccess(for: .audio)
                }
                guard granted else { throw MeetingRecorderError.onlineCaptureFailed("Microphone access is required for this selection. Enable it in Privacy & Security > Microphone, or choose Mac audio only.") }
            }
            if audioSelection.includesMacAudio {
                guard #available(macOS 15, *) else {
                    throw MeetingRecorderError.onlineCaptureFailed("Mac audio capture requires macOS 15 or later. Choose Microphone only.")
                }
            }
            let micID = selectedMicrophoneID ?? appState.selectedMicrophoneID
            let source = MeetingSourceMetadata(label: captureMode == .online ? "Me" : "Room", deviceID: micID)
            let systemSource = MeetingSourceMetadata(label: "System audio", kind: .systemAudio, deviceID: "system-output", sampleRate: 48_000)
            if audioSelection.includesMacAudio && !CGPreflightScreenCaptureAccess() {
                throw MeetingRecorderError.onlineCaptureFailed("Allow system audio in Settings, select microphone-only recording explicitly, or cancel.")
            }
            var manifest = MeetingManifest(
                title: meetingTitle,
                workspaceID: selectedWorkspaceID,
                state: .recording,
                sources: (audioSelection.includesMicrophone ? [source] : []) + (audioSelection.includesMacAudio ? [systemSource] : []),
                retentionPolicy: retentionPolicy,
                aiMode: meetingPermissionMode,
                privacySettings: MeetingPrivacySettings(
                    allowsLocalIntelligence: meetingPermissionMode != .transcriptionOnly,
                    allowsCloudIntelligence: meetingPermissionMode.maySendTranscriptToCloud,
                    retainsTranscript: retentionPolicy != .neverStoreTranscript
                ),
                intelligenceConfiguration: try MeetingIntelligenceConfigurationResolver.snapshot(
                    cleanupEnabled: aiMode != .transcriptionOnly,
                    aiMode: meetingPermissionMode,
                    providerSettings: providerSettings.settings,
                    hasCredential: providerSettings.hasCredential,
                    providerWasTested: providerSettings.hasCurrentTestAttestation,
                    cleanupProvider: aiMode == .cloudOptIn ? .cloud : .localGemma
                )
            )

            manifest.captureMode = captureMode
            manifest.captureStatus = .full
            try store.create(manifest)
            // Explicit denial for new cleanup-only meetings prevents legacy
            // cloud-cleanup permission from authorizing research implicitly.
            try store.setResearchPermission(meetingID: manifest.meetingID,
                provider: cloudAnswersEnabled ? manifest.intelligenceConfiguration?.cloudProvider : nil)

            // Create persistent recorder instance for this meeting
            let r: any MeetingRecording
            if audioSelection.includesMacAudio {
                if #available(macOS 15.0, *) {
                    r = OnlineMeetingRecorder(store: store, microphoneSource: source, systemSource: systemSource,
                        includesMicrophone: audioSelection.includesMicrophone)
                } else {
                    throw MeetingRecorderError.onlineCaptureFailed("Online meetings require macOS 15 or later.")
                }
            } else {
                r = MeetingRecorder(store: store, source: captureMode == .online ? source : nil)
            }
            recorder = r

            try await r.startRecording(
                meetingID: manifest.meetingID,
                deviceID: micID
            )

            activeMeetingID = manifest.meetingID
            recordingIntelligenceConfiguration = manifest.intelligenceConfiguration
            appState.activeMeetingID = manifest.meetingID
            // Choosing research for this meeting also reveals its controls.
            // This presentation flag does not grant access to any other meeting.
            if cloudAnswersEnabled { ResearchObservatoryFeatureFlag.setEnabled(true) }
            appState.meetingResearch.selectMeeting(manifest)
            appState.meetingResearch.setEnabled(ResearchObservatoryFeatureFlag.isEnabled)
            if ResearchObservatoryFeatureFlag.isEnabled {
                appState.observatory.setMeetingContext(
                    meetingID: manifest.meetingID,
                    workspaceID: manifest.workspaceID ?? Workspace.defaultWorkspace.id,
                    allowsCloud: manifest.aiMode.maySendTranscriptToCloud
                        && manifest.privacySettings.allowsCloudIntelligence
                )
            }
            isMeetingRecording = true
            appState.isMeetingRecording = true
            meetingSegmentCount = 0
            recordingStartedAt = Date()
            meetingElapsedSeconds = 0
            meetingError = nil

            transcriber.configure(
                store: store,
                modelIdentifier: appState.transcriptionModelID,
                customDictionaryURL: URL(fileURLWithPath: appState.customDictionaryFileLocation),
                cleanupMode: .off,
                formattingEnabled: appState.formattingEnabled,
                vocabularyEnabled: appState.vocabularyCorrectionsEnabled
            )
            transcriber.start(meetingID: manifest.meetingID)

            // Keep local indexing current. Transcript text never submits a
            // research question; the typed rail owns that explicit action.
            // Finalize never taps; tests leave this nil.
            transcriber.liveSegmentTap = MeetingTranscriber.productionLiveTap(store: store)
            // Wave-9 (3837560681): keep the shared Observatory index in step
            // with durable writes (flush/ordered drain) - the engine-success
            // tap indexes BEFORE persistence lands.
            transcriber.postPersistIndexTap = MeetingTranscriber.productionIndexRefreshTap(store: store)

            startElapsedTimer()
            startMeterUpdates()
        } catch {
            meetingError = error.localizedDescription
        }
    }

    private func stopMeeting() {
        // Wave-7 (3836482852): dedupe begins at the Stop/recorder boundary,
        // BEFORE any await - a second confirmation while the first is still
        // awaiting `stopRecording()` must be a no-op.
        guard let r = recorder, !isMeetingStopping else { return }
        isMeetingStopping = true
        // Wave-9 (3837588531): latch tap suppression in the transcriber NOW -
        // before the recorder await - so an in-flight live call landing in
        // that window keeps its transcript but fires no Observatory tap.
        transcriber.stopLiveTaps()
        Task { @MainActor in
            let segments: [URL]
            do {
                segments = try await r.stopRecording()
            } catch {
                // A fatal recorder error is not retryable: capture hardware is
                // already stopped and the ring has been bounded. Use the same
                // teardown as the meter path so a Stop click inside its 0.1 s
                // observation window cannot strand the recording UI forever.
                if let fatalCaptureError = r.fatalCaptureError {
                    tearDownFailedMeetingCapture(
                        recorder: r,
                        error: fatalCaptureError
                    )
                    return
                }
                // Wave-4 (3865266533): a failed final write must surface, not
                // silently complete a meeting missing its last audio.
                // Wave-5 (3865415996): KEEP the recorder so the user can
                // retry Stop — releasing it would permanently lose the
                // in-memory tail that only it still holds.
                // Wave-7 (3865752996): KEEP the global recording latch too —
                // clearing `appState.isMeetingRecording` disables the
                // navigation guard, letting the user leave the Meetings page
                // (releasing the retained recorder) or start another meeting.
                meetingError = error.localizedDescription
                stopMeterUpdates()
                isMeetingStopping = false
                return
            }
            meetingSegmentCount = segments.count

            // Capture the meeting ID before we clear any state — finalization
            // needs it, and the recorder's completedSegmentCount is only
            // reliable now (before startRecording resets it on next use).
            guard let meetingID = activeMeetingID else {
                stopMeterUpdates()
                isMeetingRecording = false
                appState.isMeetingRecording = false
                recordingIntelligenceConfiguration = nil
                recorder = nil
                return
            }

            // Persist the segment list so recovery is possible even if
            // final transcription fails.
            let segmentNames = segments.map { url in
                let basePath = store.audioDirectory(for: meetingID).path
                return url.path.replacingOccurrences(of: basePath + "/", with: "")
            }

            // Finalize and transcribe the last partial segment(s) BEFORE
            // reporting the meeting as complete. The meeting must not be
            // marked complete until this succeeds.
            let result = await transcriber.finalizeAndTranscribe(recorder: r, meetingID: meetingID)

            if var manifest = try? store.load(meetingID: meetingID) {
                manifest.audioSegments = segmentNames
                manifest.lastCompletedSegmentIndex = segments.count
                manifest.activeJournal = nil
                manifest.endedAt = Date()

                switch result {
                case .completed:
                    manifest.state = .completed
                case .failed:
                    // Recovery-needed: keep audio, surface error, do NOT mark complete.
                    manifest.state = .interrupted
                }
                // Wave-1 (3875726227): persist the COMPLETED manifest (with
                // the real segment names) FIRST - enforcing retention
                // afterwards reloads + saves its own updated copy, so the
                // completed manifest can never re-advertise audio that was
                // deleted.
                // Wave-12 (3876176414): the completion save must SUCCEED
                // before any retention enforcement - a suppressed failure
                // leaves the disk in the prior live state, and deleting audio
                // against that stale manifest would destroy the only source
                // available for recovery.
                let manifestSaveSucceeded: Bool
                do {
                    try store.saveManifest(manifest)
                    manifestSaveSucceeded = true
                } catch {
                    manifestSaveSucceeded = false
                    meetingError = "Meeting could not be saved - audio retention not applied, raw audio preserved. \(error.localizedDescription)"
                }

                let finalizationCompleted: Bool
                switch result {
                case .completed: finalizationCompleted = true
                case .failed: finalizationCompleted = false
                }
                if finalizationCompleted && manifestSaveSucceeded {
                    // lunr-studio/Openbridge-Beta#214: production enforcement - when the meeting's
                    // policy is deleteAudioAfterTranscript and a valid
                    // canonical transcript now exists, delete the raw audio
                    // (safety gates are enforced inside the store; recovery
                    // or a failed final transcription never deletes).
                    // Wave-1 (3875726273): surface a failure instead of
                    // swallowing it - the user explicitly selected this
                    // policy and must know if it could not be honored
                    // (audio preserved).
                    // Wave-11 (3876962667): ONLY the delete-audio policy
                    // reaches this block. Keep/auto-delete/never-store stops
                    // previously called enforceAudioRetention, which returns
                    // false on policy mismatch, and the Wave-10 refusal
                    // message then mislabeled ordinary successful meetings
                    // as retention failures.
                    if manifest.retentionPolicy == .deleteAudioAfterTranscript {
                        do {
                            // Wave-10 (3876862715): a safety-gate refusal returns
                            // false, not a throw - check it and surface that the
                            // selected policy left raw audio behind instead of a
                            // silent success toast.
                            let applied = try store.enforceAudioRetention(meetingID: meetingID)
                            if !applied {
                                meetingError = "Audio retention was not applied - raw audio preserved (retention safety gates refused deletion)."
                            }
                        } catch {
                            meetingError = "Audio retention could not be applied - audio preserved. \(error.localizedDescription)"
                        }
                    }
                }
            }

            if let completedManifest = try? store.load(meetingID: meetingID) {
                appState.meetingResearch.recordingEnded(completedManifest,
                    finalProgress: MeetingResearchProgress(meetingID: meetingID, sources: r.researchCaptureProgress,
                        transcription: transcriber.researchTranscriptionProgress, isRecording: false))
            }
            stopMeterUpdates()
            isMeetingRecording = false
            appState.isMeetingRecording = false
            activeMeetingID = nil
            recordingIntelligenceConfiguration = nil
            appState.activeMeetingID = nil
            appState.observatory.endOfMeeting()
            recorder = nil
            isMeetingStopping = false

            // Keep the latest result visible while cleanup advances after
            // Stop. Durable store notifications refresh this same panel.
            recentMeetingID = meetingID

            // Refresh the saved meetings list so the stopped meeting appears
            // immediately without a manual reload.
            refreshSavedMeetings()

            // Wave-7 (3836503097): the user's selected Fast/Careful cleanup
            // finally EXECUTES as a post-Stop revision via the coordinator
            // (AGENTS.md L39-42) - the transcriber is Parakeet-only; this
            // runs strictly after Stop, never during recording. The meeting's
            // immutable build-19 snapshot selects local or authorized cloud.
            if case .completed = result {
                runPostStopCleanup(meetingID: meetingID)
            }

            switch result {
            case .completed(let count):
                showStopToast("Meeting saved. \(segments.count) segment(s), \(count) transcribed.")
            case .failed(_, let error):
                meetingError = "Meeting saved but transcription incomplete: \(error). Audio was preserved locally for recovery."
                showStopToast("Meeting saved with transcription errors — see details.")
            }
        }
    }

    private func tearDownFailedMeetingCapture(
        recorder failedRecorder: any MeetingRecording,
        error: MeetingRecorderError
    ) {
        isMeetingStopping = true
        Task { @MainActor in
            let failedMeetingID = activeMeetingID
            await failedRecorder.cancelRecording()
            _ = await failedRecorder.retryPersistingFatalCaptureState()
            let persistenceError = failedRecorder.failureStatePersistenceError == nil
                ? nil
                : await failedRecorder.retryPersistingFatalCaptureState()
            meetingSegmentCount = failedRecorder.completedSegmentCount
            if let persistenceError {
                meetingError = error.localizedDescription
                    + " The recovery status could not be saved yet (\(persistenceError)). "
                    + "This session is shown as Failed in the current app session; "
                    + "relaunch recovery will reconcile its durable state."
            } else {
                meetingError = error.localizedDescription
            }
            transcriber.cancelLiveWorkAfterCaptureFailure()
            if let id = failedMeetingID {
                appState.meetingResearch.updateProgress(MeetingResearchProgress(meetingID: id,
                    sources: failedRecorder.researchCaptureProgress,
                    transcription: transcriber.researchTranscriptionProgress, isRecording: false))
            }
            stopMeterUpdates()
            isMeetingRecording = false
            isMeetingStopping = false
            appState.isMeetingRecording = false
            appState.activeMeetingID = nil
            appState.observatory.endOfMeeting()
            recordingStartedAt = nil
            activeMeetingID = nil
            recordingIntelligenceConfiguration = nil
            recorder = nil
            refreshSavedMeetings()
            if let failedMeetingID, persistenceError != nil {
                savedMeetings = MeetingCaptureFailurePresentation.applyingFailure(
                    to: savedMeetings,
                    meetingID: failedMeetingID,
                    reason: error.localizedDescription
                )
            }
        }
    }

    /// Wave-7 (3836503097): runs the selected post-meeting cleanup AFTER a
    /// successful Stop. Gated by the eligibility plan (mode + toggle +
    /// completed + final segments + privacy); failures surface truthfully
    /// and never touch the completed Original transcript.
    private func runPostStopCleanup(meetingID: String) {
        guard
            let manifest = try? store.load(meetingID: meetingID),
            MeetingPostStopCleanupPlan.shouldRun(
                mode: appState.transcriptionCleanupMode, manifest: manifest
            )
        else {
            // Wave-24 (3840273073): an ineligible meeting clears any stale
            // owed marker (user turned cleanup Off or eligibility changed).
            appState.clearOwedCleanup(meetingID)
            return
        }
                        // Wave-19 (3839500417/3839500421): deferred cleanups are QUEUED at
        // app scope, never dropped. One pump drains the queue only when
        // ALL capture state - dictation OR meeting, starting OR recording
        // - is clear; cleanups run one at a time so a single task owns
        // the engine and the single postStopCleanupTask handle
        // (AGENTS.md L40-42).
        guard !appState.deferredCleanupQueue.contains(meetingID) else { return }
        appState.deferredCleanupQueue.append(meetingID)
        // Wave-24 (3840273073): durably record the OWED cleanup so an app
        // exit during the wait can reconstruct exactly this intent.
        appState.markOwedCleanup(meetingID)
        guard appState.deferredCleanupWaiter == nil else { return }
        appState.deferredCleanupWaiter = Task { @MainActor in
            while !appState.deferredCleanupQueue.isEmpty {
                // Wave-20 (3839625006): dictation INFERENCE is capture too -
                // stopAndTranscribe clears isRecording before awaiting the
                // engine, so isTranscribing must hold the pump as well.
                while appState.isRecording || appState.isStartingRecording
                        || appState.isMeetingStarting
                        || appState.isMeetingRecording
                        || appState.isTranscribing
                        || appState.isTranscribingMedia {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if Task.isCancelled { break }
                guard let nextID = appState.deferredCleanupQueue.first else { break }
                appState.deferredCleanupQueue.removeFirst()
                if let earlier = appState.postStopCleanupTask {
                    _ = await earlier.value
                }
                if Task.isCancelled {
                    appState.deferredCleanupQueue.insert(nextID, at: 0)
                    break
                }
                runOnePostStopCleanup(meetingID: nextID)
                if let task = appState.postStopCleanupTask {
                    _ = await task.value
                }
            }
            appState.deferredCleanupWaiter = nil
        }
        return
    }

    /// Wave-19/20: runs ONE queued post-Stop cleanup to completion.
    private func runOnePostStopCleanup(meetingID: String) {
        appState.postStopCleanupTask = Task { @MainActor in
            // Wave-20 (3839625002): re-evaluate consent AT LAUNCH time -
            // the user may have switched the mode to Off (or eligibility
            // changed) between Stop and the queue draining.
            guard
                let manifest = try? store.load(meetingID: meetingID),
                MeetingPostStopCleanupPlan.shouldRun(
                    mode: appState.transcriptionCleanupMode, manifest: manifest
                )
            else {
                // Wave-23 (3840150573): an ineligible job must still release
                // the cleanup handle - a stale task would keep media
                // transcription and transforms disabled indefinitely.
                appState.postStopCleanupTask = nil
                appState.isPostStopCleanupRunning = false
                // Wave-24 (3840273073): ineligible at launch = intent
                // withdrawn; drop the owed marker too.
                appState.clearOwedCleanup(meetingID)
                return
            }
            appState.postStopCleanupMeetingID = meetingID
            // Wave-26 (3842499327): publish the running state so gated
            // views re-render when ownership changes.
            appState.isPostStopCleanupRunning = true
            // Wave-24 (3840273073): the job is launching - its durable job
            // record now governs; the owed marker is consumed.
            appState.clearOwedCleanup(meetingID)
            do {
                let cleanupEngine: any MeetingCleanupEngine
                if manifest.intelligenceConfiguration?.cleanupProvider == .cloud {
                    guard let cloud = manifest.intelligenceConfiguration?.cloudProvider else {
                        throw MeetingSessionStoreError.cloudIntelligenceDisabled
                    }
                    cleanupEngine = CloudMeetingCleanupEngine(
                        meetingID: meetingID,
                        meetingConsent: manifest.aiMode.maySendTranscriptToCloud
                            && manifest.privacySettings.allowsCloudIntelligence,
                        providerSnapshot: cloud,
                        authorizationGate: providerSettings
                    )
                } else {
                    cleanupEngine = EngineService()
                }
                let coordinator = MeetingCleanupCoordinator(
                    store: store,
                    engine: cleanupEngine
                )
                _ = try await coordinator.run(meetingID: meetingID)
            } catch is CancellationError {
                // Wave-20 (3839624993): a job cancelled by a NEW RECORDING
                // still owes its selected run - requeue it. Deletion clears
                // the association BEFORE cancelling, so a deleted meeting is
                // not requeued.
                if appState.postStopCleanupMeetingID == meetingID,
                   appState.cleanupDeletionMeetingID != meetingID,
                   appState.cleanupCancelMeetingID != meetingID {
                    appState.deferredCleanupQueue.insert(meetingID, at: 0)
                    // Wave-25 (3842247805): the marker was consumed at
                    // launch - restore it so an app exit during the capture
                    // wait can still reconstruct the owed run (the durable
                    // job is .cancelled, not resumable).
                    appState.markOwedCleanup(meetingID)
                }
            } catch {
                // A provider or model failure requires a deliberate Retry or
                // local-alternative choice. Clear the owed marker so relaunch
                // cannot silently retry or hot-loop persistent failures.
                appState.clearOwedCleanup(meetingID)
                // Wave-13/20 (3838167622, 3839624996): failures ACCUMULATE
                // at app scope until the user reads them.
                appState.postStopCleanupFailureMessages.append(
                    "Transcript cleanup failed - the original transcript is intact."
                )
                showStopToast(
                    "Transcript cleanup failed - the original transcript is intact."
                )
            }
            appState.postStopCleanupTask = nil
            appState.postStopCleanupMeetingID = nil
            appState.isPostStopCleanupRunning = false
        }
    }

    // MARK: - Timers

    // Autoconnected publishers fire continuously. The .onReceive handlers
    // guard on isMeetingRecording so they're no-ops when not recording.
    // We cannot use manual connect()/cancel() because SwiftUI recreates
    // View structs on every re-render, orphaning stored connections.
    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let meterTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private func startElapsedTimer() {
        // Timer is always autoconnected; guard in .onReceive handles gating
    }

    private func stopElapsedTimer() {
        // Timer is always autoconnected; guard in .onReceive handles gating
    }

    private func startMeterUpdates() {
        // Timer is always autoconnected; guard in .onReceive handles gating
    }

    private func stopMeterUpdates() {
        meetingMeterLevel = 0
    }

    // MARK: - Saved meetings

    private func refreshSavedMeetings() {
        do {
            let meetings = try store.listMeetings()
            savedMeetings = meetings
            if recentMeetingID == nil
                || !meetings.contains(where: { $0.meetingID == recentMeetingID }) {
                recentMeetingID = meetings.first?.meetingID
            }
        } catch {
            showToast("Could not load saved meetings: \(error.localizedDescription)")
        }
    }

    /// lunr-studio/Openbridge-Beta#321 wave-1 (3884760779): cancel a meeting's cleanup THROUGH the
    /// app-scoped cleanup owner - not just the durable job record. Removes
    /// the meeting from the deferred queue, cancels the in-flight task if
    /// it owns this meeting, suppresses the requeue-on-cancel, and clears
    /// the owed marker, so Cancel reliably prevents cleanup from running
    /// again (including after relaunch).
    private func cancelPostStopCleanup(_ meeting: MeetingManifest) {
        let meetingID = meeting.meetingID
        appState.deferredCleanupQueue.removeAll { $0 == meetingID }
        appState.clearOwedCleanup(meetingID)
        if let job = (try? store.load(meetingID: meetingID))?.cleanupJobs.last,
           [.queued, .running].contains(job.state) {
            try? store.cancelCleanupJob(meetingID: meetingID, jobID: job.id)
        }
        guard let task = appState.postStopCleanupTask,
              appState.postStopCleanupMeetingID == meetingID else { return }
        appState.cleanupCancelMeetingID = meetingID
        task.cancel()
        Task { @MainActor in
            _ = await task.value
            if appState.postStopCleanupMeetingID == meetingID {
                appState.postStopCleanupTask = nil
                appState.postStopCleanupMeetingID = nil
            }
            appState.cleanupCancelMeetingID = nil
        }
    }

    /// lunr-studio/Openbridge-Beta#321 wave-1 (3884760787): the toggle was switched OFF - withdraw the
    /// cleanup intent. Any durable job still queued/running is cancelled so
    /// no manifest stays permanently queued and the review surface stops
    /// showing progress for work that will never launch.
    private func withdrawQueuedCleanups() {
        // lunr-studio/Openbridge-Beta#321 wave-3 (3886129361): clear ALL owed
        // markers, not only IDs currently in the in-memory queue - a failed
        // cleanup marks itself owed without re-queueing, and that marker
        // would otherwise re-enqueue a successor after relaunch.
        let owedIDs = appState.owedCleanupMeetingIDs
        for meetingID in owedIDs {
            appState.clearOwedCleanup(meetingID)
            if let job = (try? store.load(meetingID: meetingID))?.cleanupJobs.last,
               [.queued, .running].contains(job.state) {
                try? store.cancelCleanupJob(meetingID: meetingID, jobID: job.id)
            }
        }
        appState.deferredCleanupQueue.removeAll()
        if let task = appState.postStopCleanupTask {
            // lunr-studio/Openbridge-Beta#321 wave-1 (3884760787): suppress the requeue-on-cancel for
            // the in-flight job too - otherwise the CancellationError path
            // would re-queue it and the toggle-Off intent would be undone.
            if let runningID = appState.postStopCleanupMeetingID {
                appState.cleanupCancelMeetingID = runningID
            }
            task.cancel()
            _ = Task { @MainActor in
                _ = await task.value
                appState.cleanupCancelMeetingID = nil
            }
        }
    }

    /// lunr-studio/Openbridge-Beta#219 (review): retry an interrupted post-Stop cleanup — routes the
    /// durable job through retryAvailable → queued, then re-offers it to
    /// the deferred-cleanup queue so the coordinator runs it (serialized
    /// against all capture/engine consumers by the existing pump).
    private func retryInterruptedCleanup(
        _ meeting: MeetingManifest,
        cloudChargeConfirmed: Bool = false
    ) {
        do {
            // lunr-studio/Openbridge-Beta#219 (review): eligibility BEFORE any durable transition —
            // queueing a job the pump would reject leaves it inert and
            // invisible to the recovery surface. Check the same plan the
            // launch path uses, with the CURRENT mode.
            guard
                let manifest = try? store.load(meetingID: meeting.meetingID),
                MeetingPostStopCleanupPlan.shouldRun(
                    mode: appState.transcriptionCleanupMode, manifest: manifest
                )
            else {
                showToast("Cleanup is currently Off or the meeting is no longer eligible — nothing queued.")
                return
            }
            if manifest.intelligenceConfiguration?.cleanupProvider == .cloud,
               !cloudChargeConfirmed {
                pendingCloudRetryMeeting = manifest
                showingCloudRetryConfirmation = true
                return
            }
            guard let job = manifest.cleanupJobs.last(where: {
                [.interrupted, .retryAvailable, .failed].contains($0.state)
            }) else { return }
            if job.state != .retryAvailable {
                try store.makeCleanupRetryAvailable(meetingID: meeting.meetingID, jobID: job.id)
            }
            try store.queueCleanupRetry(meetingID: meeting.meetingID, jobID: job.id)
            runPostStopCleanup(meetingID: meeting.meetingID)
            refreshSavedMeetings()
            showToast(
                manifest.intelligenceConfiguration?.cleanupProvider == .cloud
                    ? "Cloud cleanup retry queued. Another provider charge may occur."
                    : "Local cleanup retry queued."
            )
        } catch {
            showToast("Cleanup retry failed: \(error.localizedDescription)")
        }
    }

    /// lunr-studio/Openbridge-Beta#219: retry transcription for an interrupted meeting from its
    /// PRESERVED audio — the action advertised after a finalize refusal.
    /// Review-wave hardening: configures the transcriber from current app
    /// preferences FIRST (relaunch retry otherwise uses init placeholders),
    /// and runs under an app-owned task that gates meeting Start and
    /// re-retry (the shared transcriber must not be reconfigured or
    /// double-driven mid-recovery).
    private func retryRecoveredTranscription(_ meeting: MeetingManifest) {
        // lunr-studio/Openbridge-Beta#219 (review): refuse while ANY meeting work owns the shared
        // transcriber — recording, starting, stopping, or another retry.
        guard appState.recoveryRetryTask == nil else {
            showToast("A recovery retry is already running.")
            return
        }
        guard !isMeetingRecording, !isMeetingStopping, !appState.isMeetingStarting else {
            showToast("Finish or stop the current meeting before recovering another.")
            return
        }
        // Wave-6 (3849160822): recovery runs a local engine process too —
        // refuse while dictation inference, media transcription, or a
        // post-Stop cleanup owns the engine (same serialization those
        // consumers already apply to each other).
        guard !appState.isTranscribing, !appState.isTranscribingMedia,
              appState.postStopCleanupTask == nil
        else {
            showToast("Finish the current transcription or cleanup before recovering.")
            return
        }
        // lunr-studio/Openbridge-Beta#219 (review): production configuration from appState — the same
        // configure call startMeeting performs, so relaunch retry uses the
        // selected model, dictionary, formatting, and vocabulary settings.
        transcriber.configure(
            store: store,
            modelIdentifier: appState.transcriptionModelID,
            customDictionaryURL: URL(fileURLWithPath: appState.customDictionaryFileLocation),
            cleanupMode: appState.transcriptionCleanupMode,
            formattingEnabled: appState.formattingEnabled,
            vocabularyEnabled: appState.vocabularyCorrectionsEnabled
        )
        // lunr-studio/Openbridge-Beta#219 (review): reset per-meeting state (persisted indices,
        // buffers, generation) so a previous recording's accounting cannot
        // make this meeting's holes look resolved.
        transcriber.start(meetingID: meeting.meetingID)
        showToast("Retrying transcription from preserved audio…")
        appState.activeRecoveryMeetingID = meeting.meetingID
        appState.recoveryRetryTask = Task { @MainActor in
            defer {
                appState.recoveryRetryTask = nil
                appState.activeRecoveryMeetingID = nil
            }
            let outcome = await RecoveryActionRouter.retryTranscription(
                meetingID: meeting.meetingID,
                store: store,
                transcriber: transcriber
            )
            refreshSavedMeetings()
            switch outcome {
            case .retrySucceeded(let n):
                showToast("Recovered \(n) segment\(n == 1 ? "" : "s"). You can now finalize the meeting.")
            case .retryFailed(let message):
                showToast("Retry failed: \(message) — audio preserved.")
            default:
                break
            }
        }
    }

    /// lunr-studio/Openbridge-Beta#219: finalize an interrupted meeting via the RecoveryActionRouter —
    /// verdict-driven, guarded. A transcriptless (audio-only) meeting is
    /// NEVER completed; its audio stays recoverable for retry. Finalize is
    /// also refused while a recovery retry is RUNNING for this meeting — a
    /// partial transcript must not be locked in as final.
    private func finalizeRecoveredMeeting(_ meeting: MeetingManifest) {
        if appState.recoveryRetryTask != nil {
            showToast("A recovery retry is still running — finalize after it completes.")
            return
        }
        do {
            let outcome = try RecoveryActionRouter.route(
                action: .finalize, meetingID: meeting.meetingID, store: store
            )
            switch outcome {
            case .completed:
                // Wave-1 (3875726261): a recovered + finalized meeting must
                // also honor the deleteAudioAfterTranscript policy - the
                // normal Stop path enforces it, so recovery must too.
                do {
                    _ = try store.enforceAudioRetention(meetingID: meeting.meetingID)
                } catch {
                    showToast("Meeting finalized, but audio retention could not be applied - audio preserved.")
                }
                // Wave-12 (3876176432): refresh AFTER enforcement too - the
                // store clears audioSegments once the delete-audio policy runs,
                // and the pre-enforcement refresh would otherwise leave a stale
                // row that opens replay against just-deleted files.
                refreshSavedMeetings()
                showToast("Meeting finalized. Transcript verified and preserved.")
            case .refusedNoTranscript:
                showToast("No transcript to finalize — audio preserved. Retry transcription to recover.")
            case .isolatedProviderFailure:
                showToast("Provider issue recorded — meeting unaffected.")
            case .retrySucceeded, .retryFailed:
                // Retry outcomes surface via retryRecoveredTranscription.
                break
            }
        } catch {
            showToast("Could not finalize meeting: \(error.localizedDescription)")
        }
    }

    /// lunr-studio/Openbridge-Beta#219: reveal the preserved meeting folder in Finder.
    private func revealMeetingFiles(_ meeting: MeetingManifest) {
        NSWorkspace.shared.open(
            store.rootDirectory.appendingPathComponent(meeting.meetingID, isDirectory: true)
        )
    }

    /// Wave-17 (3838661486): suppresses a second delete confirmation for a
    /// meeting whose cleanup cancellation await is still in flight.
    @State private var meetingDeletionInFlight = false
    /// Wave-23 (3840150570): one-shot relaunch reconstruction of the
    /// in-memory deferred-cleanup queue (see reconstructDeferredCleanups).
    @State private var didReconstructDeferredCleanups = false


    /// Wave-23 (3840150570): the deferred queue is in-memory; an app exit
    /// while jobs waited would lose them. On first Meetings appearance we
    /// re-enqueue completed, AI-eligible meetings that have NEVER had a
    /// cleanup job (meetings with existing jobs are governed by their
    /// durable state and relaunch reconciliation instead).
    private func reconstructDeferredCleanups() {
        guard !didReconstructDeferredCleanups else { return }
        didReconstructDeferredCleanups = true
        // Wave-24 (3840273073): reconstruct ONLY durably-marked intents -
        // never infer cleanup from meeting history. Eligibility is
        // re-checked per meeting at enqueue (runPostStopCleanup entry).
        for meetingID in appState.owedCleanupMeetingIDs {
            runPostStopCleanup(meetingID: meetingID)
        }
    }

    /// Explicit user-selected alternative after a cloud failure. This updates
    /// only the meeting's non-secret cleanup choice, then sends the work back
    /// through the same serialized durable coordinator. It is never invoked
    /// automatically by a provider error.
    private func cleanLocallyAfterCloudFailure(_ meeting: MeetingManifest) {
        do {
            try store.selectLocalCleanupAlternative(meetingID: meeting.meetingID)
            runPostStopCleanup(meetingID: meeting.meetingID)
            refreshSavedMeetings()
            showToast("Local Gemma cleanup queued.")
        } catch {
            showToast("Local cleanup could not be queued: \(error.localizedDescription)")
        }
    }

    private func deleteSelectedMeetings() {
        guard !bulkDeletionInFlight, !pendingBulkDelete.isEmpty else { return }
        let confirmed = pendingBulkDelete
        pendingBulkDelete = []
        bulkDeletionInFlight = true
        Task { @MainActor in
            let failed = await MeetingDeletionSelection.run(confirmed) { meeting in
                await withCheckedContinuation { continuation in
                    deleteMeeting(meeting, completion: { continuation.resume(returning: $0) })
                }
            }
            bulkDeletionInFlight = false
            refreshSavedMeetings()
            let deletedCount = confirmed.count - failed.count
            if failed.isEmpty {
                showToast("Deleted \(deletedCount) meetings. Audio and transcripts were permanently removed.")
            } else {
                showToast("Deleted \(deletedCount) of \(confirmed.count) meetings. Could not delete: \(failed.map(\.title).joined(separator: ", ")). Remaining meetings are still in the library; try deleting them again.")
            }
        }
    }

    private func deleteMeeting(_ meeting: MeetingManifest, completion: ((Bool) -> Void)? = nil) {
        guard !meetingDeletionInFlight else { completion?(false); return }
        // Wave-19 (3839500421): remove any QUEUED cleanup for this
        // meeting - deleting must not leave a pump launch behind.
        appState.deferredCleanupQueue.removeAll { $0 == meeting.meetingID }
        appState.clearOwedCleanup(meeting.meetingID)
        // lunr-studio/Openbridge-Beta#219 (review): a running recovery retry for this meeting must be
        // cancelled and awaited before its directory is removed — the engine
        // would otherwise transcribe deleted data and report preserved audio
        // that no longer exists.
        if appState.recoveryRetryTask != nil,
           appState.activeRecoveryMeetingID == meeting.meetingID {
            let retryTask = appState.recoveryRetryTask
            Task { @MainActor in
                meetingDeletionInFlight = true
                retryTask?.cancel()
                _ = await retryTask?.value
                appState.recoveryRetryTask = nil
                appState.activeRecoveryMeetingID = nil
                meetingDeletionInFlight = false
                deleteMeeting(meeting, completion: completion)
            }
            return
        }
        // Wave-15 (3838270706): if the post-Stop cleanup for THIS meeting is
        // still running, cancel it and wait for the engine process to exit
        // before deleting - never infer over deleted data, never misreport
        // "the original transcript is intact" for a deleted meeting.
        if appState.postStopCleanupMeetingID == meeting.meetingID,
           let cleanup = appState.postStopCleanupTask {
            Task { @MainActor in
                // Wave-17 (3838661486): hold BOTH the association and a
                // deletion-in-progress flag until termination AND the
                // deletion complete - a second confirmation during the await
                // must not bypass this branch and delete while Gemma is
                // still terminating.
                // Wave-18 (3839462801): clear the in-flight guard BEFORE the
                // recursive deletion call - a defer would keep it set and the
                // recursive deleteMeeting would no-op, forcing a second
                // confirmation.
                meetingDeletionInFlight = true
                // Wave-21 (3839766694): deletion suppresses requeue via a
                // dedicated flag; the meeting association STAYS so the
                // post-await clear can verify the shared fields still belong
                // to the cancelled job - the pump may already have launched a
                // successor whose ownership must survive (a later recording
                // start must still be able to cancel/await it).
                appState.cleanupDeletionMeetingID = meeting.meetingID
                cleanup.cancel()
                _ = await cleanup.value
                if appState.postStopCleanupMeetingID == meeting.meetingID {
                    appState.postStopCleanupTask = nil
                    appState.postStopCleanupMeetingID = nil
                }
                appState.cleanupDeletionMeetingID = nil
                meetingDeletionInFlight = false
                deleteMeeting(meeting, completion: completion)
            }
            return
        }
        do {
            try store.delete(meetingID: meeting.meetingID)
            refreshSavedMeetings()
            showToast("Meeting deleted.")
            completion?(true)
        } catch {
            showToast("Could not delete meeting: \(error.localizedDescription)")
            completion?(false)
        }
    }

    private func exportMeeting(_ meeting: MeetingManifest) {
        let currentMeeting = (try? store.load(meetingID: meeting.meetingID)) ?? meeting
        let presentation = MeetingProcessingPresentation.make(
            manifest: currentMeeting,
            isCleanupDeferred: appState.deferredCleanupQueue.contains(meeting.meetingID)
        )
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \"\(currentMeeting.title)\". \(presentation.exportDialogMessage)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // lunr-studio/Openbridge-Beta#214 + wave-1 (3875726244): write into a per-meeting subfolder so
        // exporting multiple meetings to one directory never silently
        // overwrites a previous export.
        let safeTitle = currentMeeting.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // Wave-12 (3876176453): bound the UTF-8 length of the folder
        // component - an unrestricted title approaching the filesystem's
        // per-component limit would fail with ENAMETOOLONG and make the
        // meeting unexportable. 64 bytes keeps the path well under the limit.
        var boundedTitle = ""
        for character in safeTitle {
            let next = boundedTitle + String(character)
            if next.utf8.count > 64 { break }
            boundedTitle = next
        }
        let folder = url.appendingPathComponent(
            "\(boundedTitle)-\(meeting.meetingID.prefix(6))", isDirectory: true
        )

        do {
            let result = try store.exportAvailableTranscripts(
                meetingID: meeting.meetingID,
                to: folder
            )
            let exported = result.filenames.joined(separator: " + ")
            if result.includedCleaned {
                showToast("Exported Original + Cleaned to \(folder.lastPathComponent).")
            } else if let latest = try? store.load(meetingID: meeting.meetingID),
                      [MeetingProcessingPhase.cleanupQueued, .cleanupRunning].contains(
                        MeetingProcessingPresentation.make(
                            manifest: latest,
                            isCleanupDeferred: appState.deferredCleanupQueue.contains(meeting.meetingID)
                        ).phase
                      ) {
                showToast(
                    "Exported Original only. Cleanup is still in progress; export again when Cleaned is ready."
                )
            } else {
                showToast("Exported \(exported) to \(folder.lastPathComponent).")
            }
        } catch {
            showToast("Meeting export failed: \(error.localizedDescription)")
        }
    }

    private func dismissToast() {
        withAnimation { meetingStatusToast = nil }
    }

    private func showToast(_ message: String) {
        withAnimation { meetingStatusToast = message }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                withAnimation { meetingStatusToast = nil }
            }
        }
    }
}

extension MeetingProcessingTone {
    var tint: Color {
        switch self {
        case .neutral: return OpenBridgeTheme.mutedInk
        case .working: return OpenBridgeTheme.brandBlue
        case .success: return OpenBridgeTheme.brandTeal
        case .warning: return OpenBridgeTheme.brandGold
        case .failure: return OpenBridgeTheme.brandCoral
        }
    }
}

struct MainLatestMeetingPanel: View {
    let meeting: MeetingManifest
    let presentation: MeetingProcessingPresentation
    let onReplay: () -> Void
    let onExport: () -> Void
    let onRetryCleanup: (() -> Void)?

    var body: some View {
        MainInfoCard("Latest meeting", systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title)
                            .font(OpenBridgeTypography.heading(size: 20))
                            .foregroundStyle(OpenBridgeTheme.ink)
                            .lineLimit(1)
                        Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                    }
                    Spacer(minLength: 0)
                    OpenBridgeStatusPill(
                        text: presentation.badgeText,
                        tint: presentation.tone.tint
                    )
                }

                HStack(alignment: .top, spacing: 9) {
                    if presentation.showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: presentation.systemImage)
                            .foregroundStyle(presentation.tone.tint)
                            .frame(width: 18)
                    }
                    Text(presentation.detailText)
                        .font(OpenBridgeTypography.body(size: 16))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                if let progressValue = presentation.progressValue {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(presentation.badgeText)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        actions
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var actions: some View {
        Button(action: onReplay) {
            Label("Replay", systemImage: "play.circle")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())

        Button(action: onExport) {
            Label(presentation.exportActionTitle, systemImage: "square.and.arrow.down")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: presentation.includesCleanedExport))
        .help(presentation.exportDialogMessage)

        if let onRetryCleanup {
            Button(action: onRetryCleanup) {
                Label("Retry cleanup", systemImage: "arrow.clockwise")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        }
    }
}

struct MainSavedMeetingsCard: View {
    let savedMeetings: [MeetingManifest]
    let onReplay: (MeetingManifest) -> Void
    let onDelete: (MeetingManifest) -> Void
    let onDeleteSelected: ([MeetingManifest]) -> Void
    let onExport: (MeetingManifest) -> Void
    // lunr-studio/Openbridge-Beta#219: optional so existing previews/tests compile unchanged.
    var onFinalizeRecovery: ((MeetingManifest) -> Void)? = nil
    var onRevealRecoveredFiles: ((MeetingManifest) -> Void)? = nil
    var onRetryTranscription: ((MeetingManifest) -> Void)? = nil
    var onRetryCleanup: ((MeetingManifest) -> Void)? = nil
    var isCleanupDeferred: (MeetingManifest) -> Bool = { _ in false }
    @Binding var searchText: String
    @State private var selectedMeetingIDs: Set<String> = []

    private var selectedMeetings: [MeetingManifest] {
        MeetingDeletionSelection.targets(in: filteredMeetings, selected: selectedMeetingIDs)
    }

    private var filteredMeetings: [MeetingManifest] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return savedMeetings
        }
        return savedMeetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.transcriptSpans.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        MainInfoCard("Saved meetings", systemImage: "clock.arrow.circlepath") {
            if savedMeetings.isEmpty {
                MainEmptyState(
                    systemImage: "person.3",
                    title: "No saved meetings yet",
                    subtitle: "Record a meeting and it will appear here. You can export or delete meetings from this list."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search title or transcript", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        Button("Select all shown") { selectedMeetingIDs = Set(filteredMeetings.map(\.meetingID)) }
                            .disabled(filteredMeetings.isEmpty)
                        Button("Clear selection") { selectedMeetingIDs = [] }.disabled(selectedMeetingIDs.isEmpty)
                        Spacer(minLength: 0)
                        Button("Delete selected (\(selectedMeetings.count))", role: .destructive) {
                            onDeleteSelected(selectedMeetings)
                        }
                        .disabled(selectedMeetings.isEmpty)
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())

                    if filteredMeetings.isEmpty {
                        MainEmptyState(
                            systemImage: "magnifyingglass",
                            title: "No meetings match that search",
                            subtitle: "Try a shorter word or different phrase."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredMeetings.enumerated()), id: \.element.meetingID) { index, meeting in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("Select \(meeting.title)", isOn: Binding(
                                get: { selectedMeetingIDs.contains(meeting.meetingID) },
                                set: { selected in
                                    if selected { selectedMeetingIDs.insert(meeting.meetingID) }
                                    else { selectedMeetingIDs.remove(meeting.meetingID) }
                                }
                            ))
                            .toggleStyle(.checkbox).labelsHidden().padding(.top, 14)
                        MainSavedMeetingRow(
                            meeting: meeting,
                            onReplay: { onReplay(meeting) },
                            onExport: { onExport(meeting) },
                            onDelete: { onDelete(meeting) },
                            onFinalizeRecovery: { onFinalizeRecovery?(meeting) },
                            onRevealRecoveredFiles: { onRevealRecoveredFiles?(meeting) },
                            onRetryTranscription: { onRetryTranscription?(meeting) },
                            onRetryCleanup: { onRetryCleanup?(meeting) },
                            isCleanupDeferred: isCleanupDeferred(meeting)
                        )
                        }

                                if index < filteredMeetings.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: searchText) { _, _ in selectedMeetingIDs = [] }
        .onChange(of: savedMeetings.map(\.meetingID)) { _, ids in
            selectedMeetingIDs.formIntersection(Set(ids))
        }
    }
}

struct MainSavedMeetingRow: View {
    let meeting: MeetingManifest
    var onReplay: () -> Void = {}
    let onExport: () -> Void
    let onDelete: () -> Void
    // lunr-studio/Openbridge-Beta#219: recovery actions for interrupted meetings. All optional so
    // existing call sites (and previews/tests) compile unchanged.
    var onFinalizeRecovery: (() -> Void)? = nil
    var onRevealRecoveredFiles: (() -> Void)? = nil
    var onRetryTranscription: (() -> Void)? = nil
    var onRetryCleanup: (() -> Void)? = nil
    var isCleanupDeferred = false

    // Codex P1 (#47): gate on the repository recovery predicate, not
    // the single .interrupted state — force-quit leaves .recording,
    // and .failed/.recoveryNeeded are equally recoverable.
    private var needsRecoveryActions: Bool { meeting.state.needsRecovery }

    private var processing: MeetingProcessingPresentation {
        MeetingProcessingPresentation.make(
            manifest: meeting,
            isCleanupDeferred: isCleanupDeferred
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(meeting.captureMode == .online ? (meeting.captureStatus == .microphoneOnlyFallback ? "Microphone only" : meeting.sources.contains(where: { $0.kind == .microphone }) ? "Microphone + Mac audio" : "Mac audio only") : "Microphone only")
                    .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                Text(meeting.title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .lineLimit(1)

                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)

                Spacer(minLength: 0)

                OpenBridgeStatusPill(text: processing.badgeText, tint: processing.tone.tint)
            }

            // lunr-studio/Openbridge-Beta#219: a clear, safe recovery action for interrupted meetings,
            // and a cleanup-retry banner for interrupted cleanup jobs
            // (surfaced even when the meeting itself completed).
            if needsRecoveryActions {
                recoveryBanner
            }

            processingBanner

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !meeting.audioSegments.isEmpty {
                    Text("\(meeting.audioSegments.count) segment\(meeting.audioSegments.count == 1 ? "" : "s")")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }

                Text(meeting.retentionPolicy.displayName)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    primaryActions
                    Spacer(minLength: 0)
                    deleteAction
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        primaryActions
                    }
                    deleteAction
                }
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private var primaryActions: some View {
        Button(action: onReplay) {
            Label("Replay", systemImage: "play.circle")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())

        Button(action: onExport) {
            Label(processing.exportActionTitle, systemImage: "square.and.arrow.down")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
        .help(processing.exportDialogMessage)

        if processing.allowsCleanupRetry, let onRetryCleanup {
            Button(action: onRetryCleanup) {
                Label("Retry cleanup", systemImage: "arrow.clockwise")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        }

    }

    private var deleteAction: some View {
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }

    @ViewBuilder private var processingBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            if processing.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: processing.systemImage)
                    .foregroundStyle(processing.tone.tint)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(processing.detailText)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if let progressValue = processing.progressValue {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(processing.badgeText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(processing.tone.tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(processing.badgeText). \(processing.detailText)")
    }

    /// lunr-studio/Openbridge-Beta#219: visible recovery card for an interrupted meeting — explains
    /// what was preserved and offers Finalize / Reveal actions (Delete is
    /// the existing row action, behind its confirmation dialog).
    @ViewBuilder private var recoveryBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("This meeting was interrupted. Audio recorded so far is preserved locally.")
            } icon: {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(OpenBridgeTheme.brandGold)
            }
            .font(OpenBridgeTypography.body(size: 13))
            .foregroundStyle(OpenBridgeTheme.mutedInk)
            .accessibilityLabel("Interrupted meeting. Audio preserved.")

            HStack(spacing: 8) {
                if let onFinalizeRecovery {
                    Button(action: onFinalizeRecovery) {
                        Label("Finalize available segments", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .help("Keeps recorded audio and any live segments, marks the meeting complete.")
                    .accessibilityLabel("Finalize available segments")
                }
                if let onRevealRecoveredFiles {
                    Button(action: onRevealRecoveredFiles) {
                        Label("Reveal files", systemImage: "folder")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .help("Opens the preserved meeting folder in Finder.")
                    .accessibilityLabel("Reveal preserved files in Finder")
                }
                if let onRetryTranscription {
                    Button(action: onRetryTranscription) {
                        Label("Retry transcription", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .help("Transcribes the preserved audio for every missing segment.")
                    .accessibilityLabel("Retry transcription from preserved audio")
                }
                Spacer()
            }
        }
        .padding(10)
        .background(OpenBridgeTheme.brandGold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recovery actions")
    }

}
