import SwiftUI
import OpenBridgeUI

/// Pure policy shared by sidebar and in-page links. Capture owns Home until
/// finalization finishes; changing a view must never destroy its recorder.
enum MeetingHomeNavigation {
    static func blocker(leavingHome: Bool, starting: Bool, recording: Bool) -> String? {
        guard leavingHome else { return nil }
        if starting { return "Wait for the meeting to finish starting before leaving Home." }
        if recording { return "Stop the meeting and wait for it to finish saving before leaving Home." }
        return nil
    }

    static func recentMeetings(_ meetings: [MeetingManifest]) -> [MeetingManifest] {
        Array(meetings.sorted {
            if $0.startedAt == $1.startedAt { return $0.meetingID < $1.meetingID }
            return $0.startedAt > $1.startedAt
        }.prefix(3))
    }
}

struct MeetingHomeMetrics: Equatable {
    let width: CGFloat
    var isSplit: Bool { width >= 760 }
    var setupWidth: CGFloat { isSplit ? 260 : width }
    var meetingWidth: CGFloat { isSplit ? width - setupWidth - 16 : width }
}

enum MeetingDeletionSelection {
    /// Freeze only explicitly selected, currently visible records for confirmation.
    static func targets(in meetings: [MeetingManifest], selected: Set<String>) -> [MeetingManifest] {
        var seen = Set<String>()
        return meetings.filter { selected.contains($0.meetingID) && seen.insert($0.meetingID).inserted }
    }

    static func confirmation(_ meetings: [MeetingManifest]) -> String {
        let names = meetings.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
        let more = meetings.count > 5 ? "\n…and \(meetings.count - 5) more selected meetings." : ""
        return "\(names)\(more)\n\nThis permanently removes these meetings, their audio, transcripts and saved intelligence conversations from this Mac. Answers in other meetings that rely on these meetings are also removed. This cannot be undone. Export anything you want to keep first."
    }

    /// Serial completion prevents a cleanup/recovery cancellation for one record
    /// from skipping other selected records. A failed deletion does not abort the rest.
    @MainActor static func run(_ meetings: [MeetingManifest], delete: @MainActor (MeetingManifest) async -> Bool) async -> [MeetingManifest] {
        var failed: [MeetingManifest] = []
        for meeting in meetings {
            if !(await delete(meeting)) { failed.append(meeting) }
        }
        return failed
    }
}

/// Measure both native columns without a height-guessing GeometryReader.
struct MeetingHomeColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = MeetingHomeMetrics(width: proposal.width ?? 880)
        guard subviews.count == 2 else { return .zero }
        let main = subviews[0].sizeThatFits(.init(width: metrics.meetingWidth, height: nil))
        let setup = subviews[1].sizeThatFits(.init(width: metrics.setupWidth, height: nil))
        return CGSize(width: metrics.width, height: metrics.isSplit ? max(main.height, setup.height) : main.height + 16 + setup.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let metrics = MeetingHomeMetrics(width: bounds.width)
        let mainProposal = ProposedViewSize(width: metrics.meetingWidth, height: nil)
        subviews[0].place(at: bounds.origin, proposal: mainProposal)
        let setupOrigin = metrics.isSplit
            ? CGPoint(x: bounds.minX + metrics.meetingWidth + 16, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + subviews[0].sizeThatFits(mainProposal).height + 16)
        subviews[1].place(at: setupOrigin, proposal: .init(width: metrics.setupWidth, height: nil))
    }
}

struct MeetingHomePanel<Content: View>: View {
    let title: String
    var titleBadge: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(OpenBridgeTypography.heading(size: 20)).foregroundStyle(OpenBridgeTheme.ink)
                if let titleBadge {
                    Text(titleBadge)
                        .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(OpenBridgeTheme.ink.opacity(0.06), in: Capsule())
                        .fixedSize()
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(OpenBridgeTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OpenBridgeTheme.border.opacity(0.75)))
    }
}

/// Presentation only. Research consent and later global preferences do not
/// determine the cleanup selected when this recording began.
struct MeetingLiveTranscriptPresentation {
    let accuracyNote = "Focus on the conversation. AI may mishear names and technical terms; review important details afterwards."
    let cleanupLabel: String
    let cleanupExplanation: String?

    init(configuration: MeetingIntelligenceConfiguration?) {
        guard let configuration else {
            cleanupLabel = "Cleanup setting unavailable"
            cleanupExplanation = nil
            return
        }
        guard configuration.cleanupEnabled else {
            cleanupLabel = "Cleanup off"
            cleanupExplanation = nil
            return
        }
        cleanupLabel = configuration.cleanupProvider == .cloud
            ? "Cloud cleanup after the meeting" : "Local cleanup after the meeting"
        cleanupExplanation = "Cleanup can improve punctuation and readability."
    }
}

/// Kept above the transcript ScrollView, including while listening or processing.
/// Pure inputs make this safe to render without capture, storage or cloud access.
struct MeetingLiveTranscriptNotice: View {
    let configuration: MeetingIntelligenceConfiguration?

    var body: some View {
        let copy = MeetingLiveTranscriptPresentation(configuration: configuration)
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.accuracyNote)
            Text(copy.cleanupExplanation.map { "\(copy.cleanupLabel) · \($0)" } ?? copy.cleanupLabel)
        }
        .font(OpenBridgeTypography.body(size: 13))
        .foregroundStyle(OpenBridgeTheme.mutedInk)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meeting.liveTranscriptNotice")
    }
}

/// Production form also used by synthetic native previews. All actions are
/// injected: rendering this component cannot start capture or call a provider.
struct MeetingHomeForm<Devices: View, Options: View>: View {
    @Binding var title: String
    @Binding var cloudAllowed: Bool
    @Binding var optionsExpanded: Bool
    let helperText: String
    let canStart: Bool
    let isStarting: Bool
    let providerLabel: String
    let optionsSummary: String
    var cleanup: Binding<MeetingAIMode> = .constant(.transcriptionOnly)
    var showsStartButton = true
    var onSettings: () -> Void = {}
    let onStart: () -> Void
    @ViewBuilder var devices: Devices
    @ViewBuilder var options: Options

    var body: some View {
        MeetingHomePanel(title: "New meeting") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Meeting name").font(OpenBridgeTypography.body(size: 15, weight: .medium))
                TextField("e.g. Team planning", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Meeting name")
            }
            devices
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Cloud research", isOn: $cloudAllowed)
                    .font(OpenBridgeTypography.body(size: 15, weight: .medium))
                Text("Ask about this meeting or approved saved meetings. Your question, relevant transcript excerpts and recent conversation are sent. No audio.")
                    .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcript cleanup").font(OpenBridgeTypography.body(size: 15, weight: .medium))
                Picker("Transcript cleanup", selection: cleanup) {
                    Text("Off").tag(MeetingAIMode.transcriptionOnly)
                    Text("Local").tag(MeetingAIMode.localOnly)
                    Text("Cloud").tag(MeetingAIMode.cloudOptIn)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300, alignment: .leading)
                Text(cleanup.wrappedValue == .cloudOptIn
                    ? "After Stop, sends transcript text for cleanup, not audio. Original stays available."
                    : "Runs after recording stops. Your original transcript is always preserved.")
                    .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
            }
            if cloudAllowed || cleanup.wrappedValue == .cloudOptIn {
                MeetingCloudPrivacyNotice(provider: providerLabel, onSettings: onSettings)
            }
            DisclosureGroup(isExpanded: $optionsExpanded) {
                options.padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace, retention & vocabulary").font(OpenBridgeTypography.body(size: 15, weight: .medium))
                    Text(optionsSummary).font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(helperText).font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                if showsStartButton {
                Button(action: onStart) {
                    HStack(spacing: 8) {
                        if isStarting { ProgressView().controlSize(.small) }
                        Label(isStarting ? "Starting meeting…" : "Start meeting", systemImage: "mic.fill")
                    }
                }
                .buttonStyle(OpenBridgePrimaryButtonStyle())
                .disabled(!canStart)
                .accessibilityHint(helperText)
                }
            }
        }
        .disabled(isStarting)
    }
}

struct MeetingHomeSetupSummary: View {
    let microphone: String
    let model: String
    let modelStatus: String
    let readiness: String
    let onSystemCheck: () -> Void
    let onModels: () -> Void
    let onSettings: () -> Void

    var body: some View {
        MeetingHomePanel(title: "Your setup") {
            VStack(alignment: .leading, spacing: 16) {
                summary("Microphone", microphone)
                summary("Speech model", model)
                Text(modelStatus).font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                Divider()
                Text(readiness).font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("System Check", action: onSystemCheck)
                Button("Models & Performance", action: onModels)
                Button("Settings", action: onSettings)
            }
            .buttonStyle(.link)
        }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
            Text(value).font(OpenBridgeTypography.body(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Outside the Research focus container: Stop remains reachable even in
/// Research-only mode or after resizing the transcript out of view.
struct MeetingHomeRecordingHeader: View {
    let title: String
    let elapsed: String
    let isStopping: Bool
    let microphone: String
    let microphoneLevel: Double
    let systemLevel: Double?
    let configurationSummary: String
    let onStop: () -> Void
    var includesMicrophone: Bool = true
    var systemStatus: String? = nil
    var microphoneStatus: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(OpenBridgeTypography.heading(size: 20, weight: .semibold)).lineLimit(1)
                    Label(isStopping ? "Finalizing transcript" : "Recording", systemImage: isStopping ? "hourglass" : "record.circle")
                        .font(OpenBridgeTypography.body(size: 15)).foregroundStyle(OpenBridgeTheme.ink)
                }
                Spacer(minLength: 0)
                Text(elapsed).font(OpenBridgeTypography.mono(size: 16)).accessibilityLabel("Elapsed time \(elapsed)")
                Button(isStopping ? "Finalizing…" : "Stop meeting", action: onStop)
                    .buttonStyle(.borderedProminent).tint(OpenBridgeTheme.ink)
                    .disabled(isStopping)
                    .accessibilityHint("Stops recording and saves the final transcript.")
            }
            HStack(spacing: 16) {
                if includesMicrophone { meter(systemLevel == nil ? "Microphone" : "Me", microphoneLevel) }
                if let systemLevel { meter("Mac audio", systemLevel) }
            }
            if includesMicrophone, let microphoneStatus { Text("Microphone: " + microphoneStatus).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk) }
            if let systemStatus { Text("Mac audio: " + systemStatus).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk) }
            Text("\(microphone) · \(configurationSummary)")
                .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
                .lineLimit(2)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(OpenBridgeTheme.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active meeting controls")
    }

    private func meter(_ name: String, _ level: Double) -> some View {
        HStack(spacing: 8) {
            Text(name).font(OpenBridgeTypography.body(size: 13))
            ProgressView(value: level, total: 1).accessibilityLabel("\(name) audio level")
        }
    }
}

/// The production page heading is shared with safe native layout fixtures.
struct MeetingHomeSetupHeading: View {
    let canStart: Bool
    let isStarting: Bool
    let helperText: String
    let onStart: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR PRIVATE WORKSPACE")
                    .font(OpenBridgeTypography.body(size: 11, weight: .semibold))
                    .tracking(1).foregroundStyle(OpenBridgeTheme.mutedInk)
                MainPageHeader(title: "Let’s capture a conversation.",
                    subtitle: "Use AI running on your Mac to record a meeting.",
                    statusText: "", statusTint: OpenBridgeTheme.brandGreen)
            }
            VStack(alignment: .trailing, spacing: 8) {
                Button(action: onStart) {
                    HStack(spacing: 8) {
                        if isStarting { ProgressView().controlSize(.small) }
                        Label(isStarting ? "Starting…" : "Start meeting", systemImage: "mic")
                    }
                }
                .buttonStyle(OpenBridgePrimaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!canStart)
                .accessibilityHint(helperText)
                .accessibilityIdentifier("meeting.start")
                Text(helperText)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting.start.help")
            }
        }
    }
}

/// Pure recovery policy used by the real Start action and synthetic tests.
enum MeetingStartRecovery: Equatable, Identifiable {
    case cloudSetup(String), macAudioAccess, unsupportedMacAudio

    var id: String {
        switch self {
        case .cloudSetup: "cloud"
        case .macAudioAccess: "audio-permission"
        case .unsupportedMacAudio: "audio-support"
        }
    }

    static func resolve(audio: MeetingAudioSelection, supportsMacAudio: Bool,
                        hasMacAudioPermission: Bool, cloudBlocker: String?) -> Self? {
        if audio.includesMacAudio {
            if !supportsMacAudio { return .unsupportedMacAudio }
            if !hasMacAudioPermission { return .macAudioAccess }
        }
        return cloudBlocker.map(Self.cloudSetup)
    }

    static func localCleanupChoice(_ choice: MeetingAIMode) -> MeetingAIMode {
        choice == .cloudOptIn ? .transcriptionOnly : choice
    }

    var title: String {
        switch self {
        case .cloudSetup: "Record now or set up cloud AI"
        case .macAudioAccess: "Allow Mac audio before recording"
        case .unsupportedMacAudio: "Mac audio needs macOS 15 or later"
        }
    }

    var summary: String {
        switch self {
        case .cloudSetup: "Cloud AI needs setup. Start offers local recording or cloud settings."
        case .macAudioAccess: "Mac audio needs permission. Start will help you enable it."
        case .unsupportedMacAudio: "Mac audio is unavailable on this macOS version. Start shows your options."
        }
    }

    var message: String {
        switch self {
        case .cloudSetup(let detail):
            "\(detail)\n\nUse local recording turns off cloud research and cloud cleanup in this meeting setup. Your global cloud settings, selected audio source and any local cleanup stay unchanged."
        case .macAudioAccess:
            "Openbridge needs Screen & System Audio Recording access to capture your Mac’s playback. No screen or video is saved.\n\nIf you already enabled access in System Settings, choose Check again. If access is still unavailable, quit and reopen Openbridge. We will not switch to your microphone automatically."
        case .unsupportedMacAudio:
            "You can explicitly choose microphone-only recording, or update macOS to capture Mac playback. Microphone-only recording does not capture other participants through headphones."
        }
    }

    var actions: [MeetingStartRecoveryAction] {
        switch self {
        case .cloudSetup: [.useLocalRecording, .configureCloud]
        case .macAudioAccess: [.requestMacAudioAccess, .openMacAudioSettings, .checkMacAudioAccess, .chooseMicrophone]
        case .unsupportedMacAudio: [.chooseMicrophone]
        }
    }
}

enum MeetingStartRecoveryAction: String, Identifiable {
    case configureCloud, useLocalRecording, requestMacAudioAccess, openMacAudioSettings, checkMacAudioAccess, chooseMicrophone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .configureCloud: "Configure cloud AI"
        case .useLocalRecording: "Use local recording"
        case .requestMacAudioAccess: "Request Mac audio access"
        case .openMacAudioSettings: "Open System Settings"
        case .checkMacAudioAccess: "Check again"
        case .chooseMicrophone: "Choose microphone only instead"
        }
    }
}

struct MeetingStartRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    let recovery: MeetingStartRecovery
    let onChoose: (MeetingStartRecoveryAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(recovery.title).font(OpenBridgeTypography.heading(size: 22))
            Text(recovery.message).font(OpenBridgeTypography.body)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recovery.actions) { action in
                    Button(action.title) {
                        onChoose(action)
                        dismiss()
                    }
                    .accessibilityIdentifier("meeting.start.recovery.\(action.rawValue)")
                }
            }.buttonStyle(.bordered).controlSize(.large)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(OpenBridgeTheme.canvas)
    }
}
