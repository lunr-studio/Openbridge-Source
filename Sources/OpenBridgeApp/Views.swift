import AppKit
import SwiftUI
import OpenBridgeUI
import UniformTypeIdentifiers

struct MenuContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OpenBridgeMenuHero()

                PremiumSection(
                    appState.isMeetingRecording ? "Your meeting is recording" : "Make room for the conversation.",
                    subtitle: appState.isMeetingRecording
                        ? "Return to Home for the transcript, Research, and Stop."
                        : "Use AI running on your Mac to record a meeting."
                ) {
                    Button {
                        openMainWindow(.home)
                    } label: {
                        Label(appState.isMeetingRecording ? "Return to recording" : "New meeting", systemImage: "mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OpenBridgePrimaryButtonStyle())
                }

                if appState.readyForDictation {
                    VoiceActionsMenuSection()
                } else {
                    SetupNeededMenuSection()
                }

                HStack(spacing: 8) {
                    Button { openMainWindow(.transcribe) } label: {
                        Label("Transcribe", systemImage: "doc.text")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    Button { openMainWindow(.history) } label: {
                        Label("Recent text", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                }

                if !appState.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Last transcript")
                                .font(OpenBridgeTypography.heading(size: 16))
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(appState.lastTranscript, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(OpenBridgeMiniButtonStyle())
                            .accessibilityLabel("Copy last transcript")
                        }
                        Text(appState.lastTranscript)
                            .font(OpenBridgeTypography.body)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Button("Open app") { openMainWindow(.home) }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    Button { openMainWindow(.settings) } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .accessibilityLabel("Settings")
                    Button { openMainWindow(.help) } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .accessibilityLabel("Help")
                    Spacer(minLength: 0)
                    Button("Quit") { OpenBridgeQuitController.requestQuit() }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(OpenBridgeTypography.control)
        .background(OpenBridgeTheme.canvas)
        .preferredColorScheme(.light)
        .frame(width: 500, height: appState.readyForDictation ? 640 : 560, alignment: .top)
    }

    private func openMainWindow(_ section: MainWindowSection) {
        OpenBridgeNavigation.shared.request(section)
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        dismiss()
    }
}

enum OnboardingLayout {
    static let windowMinimumSize = NSSize(width: 960, height: 560)
    static let windowPreferredSize = NSSize(width: 1040, height: 600)
}

private struct OpenBridgeMenuHero: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OpenBridgeBrandMark(size: 44)
                .padding(4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(AppIdentity.displayName)
                        .font(OpenBridgeTypography.heading(size: 21))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    MenuHeroStatusPill(
                        text: appState.readyForDictation ? "Ready" : "Setup",
                        tint: appState.readyForDictation ? OpenBridgeTheme.brandTeal : OpenBridgeTheme.brandCoral
                    )
                }
                Text("Local AI, your control.")
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenBridgeTheme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OpenBridgeTheme.border, lineWidth: 1)
        }
    }
}

private struct MenuHeroStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.44))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(OpenBridgeTheme.ink.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SetupNeededMenuSection: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PremiumSection("Setup needed") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open the setup guide to finish permissions and model setup.")
                    .font(OpenBridgeTypography.body(size: 15))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .lineLimit(2)

                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                    dismiss()
                } label: {
                    Label("Open Setup Guide", systemImage: "sparkles")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
            }
        }
    }
}

private struct OpenBridgeSettingsHero: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OpenBridgeBrandMark(size: 38)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Openbridge settings")
                        .font(OpenBridgeTypography.heading(size: 20, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)
                    OpenBridgeStatusPill(text: "Local-first", tint: OpenBridgeTheme.brandTeal)
                }

                Text("Set up dictation first. Tune shortcuts, files, history, and app details when you need them.")
                    .font(OpenBridgeTypography.body(size: 15))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                appState.openHelp()
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
            .help("Open Openbridge Help")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    OpenBridgeTheme.coolSurface.opacity(0.72),
                    OpenBridgeTheme.card.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OpenBridgeTheme.brandBlue.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct VoiceActionsMenuSection: View {
    @EnvironmentObject private var appState: AppState

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    var body: some View {
        PremiumSection(
            "Your words. In any app.",
            subtitle: "Place your cursor, use your shortcut, and speak."
        ) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                Button {
                    Task { await appState.toggleDictation() }
                } label: {
                    Label(appState.isStandardRecording ? "Stop voice typing" : "Start voice typing", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OpenBridgePrimaryButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .disabled(appState.isMeetingRecording || (appState.isRecording && !appState.isStandardRecording))

                Button {
                    Task { await appState.toggleHandsFreeDictation() }
                } label: {
                    Label(appState.isHandsFreeRecording ? "Stop hands-free" : "Hands-free", systemImage: "mic.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OpenBridgeSecondaryButtonStyle())
                .help("Start or stop hands-free dictation")
                .disabled(appState.isMeetingRecording || (appState.isRecording && !appState.isHandsFreeRecording))

                Button {
                    Task { await appState.toggleCommandMode() }
                } label: {
                    Label(appState.isCommandModeRecording ? "Stop text action" : "Text actions", systemImage: "text.cursor")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OpenBridgeSecondaryButtonStyle())
                .help("Transform selected text with a spoken instruction")
                .disabled(appState.isMeetingRecording || (appState.isRecording && !appState.isCommandModeRecording))

                Button {
                    appState.pasteLastTranscript()
                } label: {
                    Label("Paste last", systemImage: "arrow.turn.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OpenBridgeSecondaryButtonStyle())
                .help("Paste the most recent successful transcript")
            }
        }
    }
}

private struct CompactAccessMenuSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        PremiumSection("Access") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(appState.permissions) { permission in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(permission.kind.title)
                                .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)

                            Spacer()

                            Text(permission.value.label)
                                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                                .foregroundStyle(permission.value == .granted ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral)
                        }

                        if permission.value != .granted {
                            HStack(spacing: 8) {
                                Button("Request") {
                                    appState.requestPermission(permission.kind)
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))

                                Button("Open Settings") {
                                    appState.openPrivacySettings(permission.kind)
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }
}

private enum OnboardingSetupStep: Int, CaseIterable {
    case permissions, model, privacy
    var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .model: return "Local model"
        case .privacy: return "Privacy"
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var setupStep: OnboardingSetupStep = .permissions

    private let compatibility = MacCompatibility.current
    private let installLocation = AppInstallLocation.current
    private var introPanelWidth: CGFloat {
        mode == .unsupported ? 430 : 300
    }

    var body: some View {
        GeometryReader { _ in
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    OnboardingIntroPanel(mode: mode)
                    .frame(width: introPanelWidth, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
                .frame(width: introPanelWidth)

                ScrollView {
                    VStack(spacing: 14) {
                        currentPanel
                            .padding(.trailing, 4)

                        if mode != .setup {
                            actionBar
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(OpenBridgeTheme.canvas)
        .font(OpenBridgeTypography.control)
        .background(OnboardingWindowConfigurator())
        .preferredColorScheme(.light)
        .task {
            appState.refresh()
        }
    }

    @ViewBuilder
    private var currentPanel: some View {
        switch mode {
        case .unsupported:
            unsupportedPanel
        case .ready:
            readyPanel
        case .setup:
            setupPanel
        }
    }

    private var mode: OnboardingMode {
        if !compatibility.isSupported {
            return .unsupported
        }
        return appState.readyForDictation && !appState.historyRetentionNeedsChoice ? .ready : .setup
    }

    private var setupPanel: some View {
        VStack(spacing: 16) {
            if installLocation.needsInstallReminder {
                InstallLocationReminderCard(status: installLocation)
            }
            HStack(spacing: 12) {
                ForEach(OnboardingSetupStep.allCases, id: \.self) { step in
                    Button { setupStep = step } label: {
                        HStack(spacing: 6) {
                            Text("\(step.rawValue + 1)")
                                .font(OpenBridgeTypography.mono(size: 13))
                            Text(step.title)
                                .font(OpenBridgeTypography.metadata)
                        }
                        .foregroundStyle(step == setupStep ? OpenBridgeTheme.brandBlue : OpenBridgeTheme.mutedInk)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(step == setupStep ? .isSelected : [])
                    if step != .privacy { Spacer(minLength: 0) }
                }
            }
            OnboardingCard {
                VStack(alignment: .leading, spacing: 20) {
                    switch setupStep {
                    case .permissions:
                        OnboardingCardHeader(title: "Your words need a way in.", subtitle: "Choose the permissions for the features you want to use.")
                        permissionRow(number: 1, kind: .microphone)
                        permissionRow(number: 2, kind: .accessibility)
                        permissionRow(number: 3, kind: .inputMonitoring)
                        Text("Online meetings ask separately for system audio capture when you start one. You can return to System Check after changing permissions.")
                            .font(OpenBridgeTypography.metadata)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    case .model:
                        OnboardingCardHeader(title: "Your Mac does the listening.", subtitle: "A local speech model turns your voice into text.")
                        modelRow(number: 4)
                        Text("Choose a different speed and quality mode later in Settings. Meeting capture uses its own local speech pipeline; model readiness is checked before recording.")
                            .font(OpenBridgeTypography.body)
                            .lineSpacing(5)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    case .privacy:
                        OnboardingCardHeader(title: "Your history, your choice.", subtitle: "Choose whether to keep voice typing text so you can recover it later.")
                        if appState.historyRetentionNeedsChoice {
                            HistoryRetentionChoiceCard()
                        } else {
                            Text("Voice typing history: \(appState.historyRetentionMode.title)")
                                .font(OpenBridgeTypography.body)
                            Text("Change this policy in Settings → Privacy & data. Turning storage off there asks for confirmation before deleting saved dictations.")
                                .font(OpenBridgeTypography.metadata)
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                        }
                        Text("Meeting recordings have their own retention choice on Home. Cloud AI is optional and needs your explicit permission. You can revisit these choices in Settings.")
                            .font(OpenBridgeTypography.body)
                            .lineSpacing(5)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { setupNavigation }
                        VStack(alignment: .leading, spacing: 8) { setupNavigation }
                    }
                }
            }
            Label(compatibility.supportSummary, systemImage: "checkmark.circle")
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var setupNavigation: some View {
        if setupStep != .permissions {
            Button("Back") {
                setupStep = OnboardingSetupStep(rawValue: setupStep.rawValue - 1) ?? .permissions
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        }
        Button("Set up later") {
            appState.deferOnboardingUntilTomorrow()
            openHome()
            dismiss()
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
        if setupStep != .privacy {
            Button("Continue") {
                setupStep = OnboardingSetupStep(rawValue: setupStep.rawValue + 1) ?? .privacy
            }
            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
        } else {
            Button("Check readiness") {
                appState.refresh()
                setupStep = .permissions
            }
            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
        }
    }

    private var unsupportedPanel: some View {
        VStack(spacing: 14) {
            OnboardingCard {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingCardHeader(
                        title: "Compatibility check",
                        subtitle: "Plain-language status before the setup funnel begins."
                    )

                    OnboardingStatusRow(
                        icon: compatibility.isSupportedOS ? "checkmark" : "exclamationmark",
                        iconTint: compatibility.isSupportedOS ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral,
                        title: compatibility.macOSVersionLabel,
                        subtitle: compatibility.isSupportedOS
                            ? "This meets the macOS requirement."
                            : "This build needs macOS 14 or later.",
                        trailingTitle: compatibility.isSupportedOS ? "Supported" : "Not supported",
                        trailingTint: compatibility.isSupportedOS ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral
                    )

                    OnboardingStatusRow(
                        icon: compatibility.isSupportedChip ? "checkmark" : "exclamationmark",
                        iconTint: compatibility.isSupportedChip ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral,
                        title: compatibility.chipKind.label,
                        subtitle: compatibility.isSupportedChip
                            ? "This Mac is ready for local transcription."
                            : "This build needs Apple silicon for local transcription.",
                        trailingTitle: compatibility.isSupportedChip ? "Supported" : "Not supported",
                        trailingTint: compatibility.isSupportedChip ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral
                    )
                }
            }

            OnboardingInfoBanner(
                icon: "info",
                title: "What to do next",
                subtitle: "Use an Apple silicon Mac for this tester build. Intel support would need a separate transcription backend."
            )
        }
    }

    private var readyPanel: some View {
        VStack(spacing: 16) {
            if installLocation.needsInstallReminder {
                InstallLocationReminderCard(status: installLocation)
            }
            OnboardingCard {
                VStack(alignment: .leading, spacing: 20) {
                    OnboardingCardHeader(title: "Make room for the conversation.", subtitle: "Your setup choices are saved. Start a meeting from Home, or try voice typing wherever you already write.", pill: "Ready", pillTint: OpenBridgeTheme.brandTeal)
                    OnboardingStatusRow(icon: "mic", iconTint: OpenBridgeTheme.brandTeal, title: "Meetings start on Home", subtitle: "Choose your capture and processing settings before recording. Stop stays with the live transcript.")
                    OnboardingStatusRow(icon: "keyboard", iconTint: OpenBridgeTheme.brandBlue, title: "Voice typing in any app", subtitle: "Place your cursor and press \(appState.hotkeyDescription). Speak, then press the shortcut again. Check the inserted text before sending.")
                    OnboardingStatusRow(icon: "menubar.rectangle", iconTint: OpenBridgeTheme.brandBlue, title: "Your daily controls stay close", subtitle: "Use the menu bar for voice typing, recent text, and a quick way back to the app.")
                    Text("Voice typing history: \(appState.historyRetentionMode.title)")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            switch mode {
            case .unsupported:
                Button("Check again") {
                    appState.refresh()
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Button("Close for now") {
                    appState.deferOnboardingUntilTomorrow()
                    dismiss()
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))

            case .ready:
                Button("Review Settings") {
                    OpenBridgeNavigation.shared.request(.settings)
                    openWindow(id: "main")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Button("Open Home") {
                    if appState.markOnboardingComplete() {
                        openHome()
                        dismiss()
                    }
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))

            case .setup:
                EmptyView()
            }
        }
    }

    private func openHome() {
        OpenBridgeNavigation.shared.request(.home)
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func permissionRow(number: Int, kind: PermissionKind) -> some View {
        let state = permissionState(kind)
        let isGranted = state == .granted
        let needsFollowUp = appState.needsPermissionFollowUp(for: kind)
        let primaryAction = needsFollowUp
            ? OnboardingAction.checkPermission(kind, title: "Check again")
            : action(for: kind, state: state)
        let secondaryAction = needsFollowUp ? action(for: kind, state: state) : nil

        return OnboardingStatusRow(
            number: number,
            iconTint: setupStepIconTint(number),
            iconForegroundColor: OpenBridgeTheme.ink,
            title: kind.title,
            subtitle: subtitle(for: kind, needsFollowUp: needsFollowUp),
            trailingTitle: isGranted ? "Granted" : (needsFollowUp ? "Waiting for Mac" : nil),
            trailingTint: isGranted ? OpenBridgeTheme.brandGreen : (needsFollowUp ? OpenBridgeTheme.brandGold : OpenBridgeTheme.brandCoral),
            buttonTitle: isGranted ? nil : primaryAction.title,
            buttonProminent: true,
            action: isGranted ? nil : { perform(primaryAction) },
            secondaryButtonTitle: secondaryAction?.title,
            secondaryAction: secondaryAction.map { secondary in { perform(secondary) } }
        )
    }

    private func modelRow(number: Int) -> some View {
        let readiness = appState.modelReadiness
        let modelReady = appState.selectedModelAvailableForTranscription
        let subtitle = modelReady
            ? "\(appState.selectedModelDisplayName) is ready for English dictation."
            : readiness?.summary ?? "Prepare \(appState.selectedModelDisplayName) for English dictation."
        let buttonTitle: String? = {
            if !appState.selectedModelInstalled && !modelReady {
                return appState.isInstallingModel ? "Installing" : "Install"
            }
            if !modelReady {
                return appState.isWarmingSelectedModel ? "Checking" : "Check"
            }
            return nil
        }()

        return OnboardingStatusRow(
            number: number,
            iconTint: setupStepIconTint(number),
            iconForegroundColor: OpenBridgeTheme.ink,
            title: "Speech model",
            subtitle: subtitle,
            buttonTitle: buttonTitle,
            action: buttonTitle == nil ? nil : {
                if appState.selectedModelInstalled {
                    appState.warmSelectedModel()
                } else {
                    appState.installSelectedModel()
                }
            }
        )
    }

    private func setupStepIconTint(_ number: Int) -> Color {
        switch number {
        case 1:
            return OpenBridgeTheme.brandGold.opacity(0.46)
        case 2:
            return OpenBridgeTheme.brandGold.opacity(0.62)
        case 3:
            return OpenBridgeTheme.brandGold.opacity(0.78)
        default:
            return OpenBridgeTheme.brandGold.opacity(0.94)
        }
    }

    private func action(for kind: PermissionKind, state: PermissionStateValue) -> OnboardingAction {
        switch kind {
        case .microphone:
            return state == .unknown
                ? .requestPermission(kind, title: "Request microphone")
                : .openPermissionSettings(kind, title: "Open Microphone")
        case .accessibility:
            return .openPermissionSettings(kind, title: "Open Accessibility")
        case .inputMonitoring:
            return .openPermissionSettings(kind, title: "Open Input Monitoring")
        }
    }

    private func perform(_ action: OnboardingAction) {
        switch action {
        case .requestPermission(let kind, _):
            appState.requestPermission(kind)
        case .openPermissionSettings(let kind, _):
            appState.openPrivacySettings(kind)
        case .checkPermission(let kind, _):
            appState.checkPermission(kind)
        }
    }

    private func permissionState(_ kind: PermissionKind) -> PermissionStateValue {
        appState.permissions.first { $0.kind == kind }?.value ?? .unknown
    }

    private func subtitle(for kind: PermissionKind, needsFollowUp: Bool) -> String {
        if needsFollowUp {
            switch kind {
            case .microphone:
                return "If you approved the Mac prompt, return here and check again."
            case .accessibility:
                return "If you turned Openbridge on in System Settings, return here and check again."
            case .inputMonitoring:
                return "Enable Openbridge if it is listed. If it is missing, reopen it from Applications and press Open Input Monitoring again."
            }
        }

        switch kind {
        case .microphone:
            return "Let Openbridge hear your dictation."
        case .accessibility:
            return "Let Openbridge paste text into the active app."
        case .inputMonitoring:
            return "Allow keyboard shortcuts to work while you are in other apps."
        }
    }

    private func tint(for kind: PermissionKind) -> Color {
        kind == .accessibility ? OpenBridgeTheme.brandCoral : OpenBridgeTheme.brandBlue
    }

}

private enum OnboardingMode {
    case unsupported
    case setup
    case ready
}

private enum OnboardingAction {
    case requestPermission(PermissionKind, title: String)
    case openPermissionSettings(PermissionKind, title: String)
    case checkPermission(PermissionKind, title: String)

    var title: String {
        switch self {
        case .requestPermission(_, let title), .openPermissionSettings(_, let title), .checkPermission(_, let title):
            return title
        }
    }
}

private struct OnboardingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> OnboardingWindowSizingView {
        OnboardingWindowSizingView()
    }

    func updateNSView(_ nsView: OnboardingWindowSizingView, context: Context) {
        nsView.configureWindow()
    }
}

private final class OnboardingWindowSizingView: NSView {
    private let minimumSize = OnboardingLayout.windowMinimumSize
    private let preferredSize = OnboardingLayout.windowPreferredSize
    private var didApplyInitialSize = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else {
            return
        }

        window.styleMask.insert(.resizable)
        window.minSize = minimumSize
        window.contentMinSize = minimumSize

        guard !didApplyInitialSize else {
            return
        }

        let frame = window.frame
        let width = max(frame.width, preferredSize.width)
        let height = preferredSize.height

        guard width != frame.width || height != frame.height else {
            didApplyInitialSize = true
            return
        }

        DispatchQueue.main.async { [weak window] in
            guard let window else {
                return
            }

            var frame = window.frame
            frame.origin.y -= height - frame.height
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
        }

        didApplyInitialSize = true
    }
}

private struct HistoryRetentionChoiceCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingCardHeader(
                    title: "Choose dictation history",
                    subtitle: "Openbridge will not save dictation history until you choose. You can change this later in Settings.",
                    pill: "Privacy",
                    pillTint: OpenBridgeTheme.brandTeal
                )

                VStack(spacing: 10) {
                    ForEach(DictationHistoryRetentionMode.privacyFirstOptions) { mode in
                        historyOption(mode)
                    }
                }
            }
        }
    }

    private func historyOption(_ mode: DictationHistoryRetentionMode) -> some View {
        let isSelected = appState.historyRetentionChoiceMade && appState.historyRetentionMode == mode

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.coolSurface)
                Image(systemName: isSelected ? "checkmark" : "lock")
                    .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : OpenBridgeTheme.brandTeal)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(mode.title)
                        .font(OpenBridgeTypography.body(size: 15, weight: .bold))
                        .foregroundStyle(OpenBridgeTheme.ink)
                    if mode == .autoDeleteAfter24Hours {
                        OpenBridgeStatusPill(text: "Recommended", tint: OpenBridgeTheme.brandGreen)
                    }
                }

                Text(mode.summary)
                    .font(OpenBridgeTypography.body(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(isSelected ? "Selected" : "Use this") {
                appState.setHistoryRetentionMode(mode)
            }
            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: mode == .autoDeleteAfter24Hours && !isSelected))
            .disabled(isSelected)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? OpenBridgeTheme.brandGreen.opacity(0.08) : OpenBridgeTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? OpenBridgeTheme.brandGreen.opacity(0.45) : OpenBridgeTheme.border, lineWidth: 1)
                }
        }
    }
}

private struct InstallLocationReminderCard: View {
    let status: AppInstallLocationStatus

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    InstallReminderGlyph()

                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.reminderTitle)
                            .font(OpenBridgeTypography.heading(size: 20, weight: .bold))
                            .foregroundStyle(OpenBridgeTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(status.reminderSubtitle)
                            .font(OpenBridgeTypography.body(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        openApplicationsButton
                        showThisCopyButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        openApplicationsButton
                        showThisCopyButton
                    }
                }
            }
        }
    }

    private var openApplicationsButton: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        } label: {
            Label("Open Applications", systemImage: "folder")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
    }

    private var showThisCopyButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([status.bundleURL])
        } label: {
            Label("Show this copy", systemImage: "magnifyingglass")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }
}

private struct InstallReminderGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(OpenBridgeTheme.brandGold.opacity(0.98))
            Image(systemName: "folder.badge.plus")
                .font(OpenBridgeTypography.body(size: 17, weight: .bold))
                .foregroundStyle(OpenBridgeTheme.ink)
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }
}

private struct OpenBridgeAppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct OnboardingIntroPanel: View {
    let mode: OnboardingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                OpenBridgeAppIconImage(size: 58)
                    .shadow(color: OpenBridgeTheme.ink.opacity(0.08), radius: 10, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text(AppIdentity.displayName)
                        .font(OpenBridgeTypography.heading(size: 28, weight: .bold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    OpenBridgeStatusPill(text: pillText, tint: pillTint)
                }
            }
            .padding(.bottom, 28)

            Group {
                Text(headline)
                    .font(OpenBridgeTypography.pageTitle)
                    .lineSpacing(0)
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                if let bodyCopy {
                    Text(bodyCopy)
                        .font(OpenBridgeTypography.body(size: 17))
                        .lineSpacing(5)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var pillText: String {
        switch mode {
        case .unsupported:
            return "Compatibility"
        case .setup:
            return "Local-first"
        case .ready:
            return "Ready"
        }
    }

    private var pillTint: Color {
        switch mode {
        case .unsupported:
            return OpenBridgeTheme.brandCoral
        case .setup:
            return OpenBridgeTheme.brandTeal
        case .ready:
            return OpenBridgeTheme.brandGreen
        }
    }

    private var headline: String {
        switch mode {
        case .unsupported:
            return "This Mac is not supported by this build."
        case .setup:
            return "Welcome to OpenBridge."
        case .ready:
            return "Your next thought can start here."
        }
    }

    private var bodyCopy: String? {
        switch mode {
        case .unsupported:
            return "Openbridge's local transcription build needs an Apple silicon Mac running macOS 14 or later. We will not ask for permissions on a Mac that cannot complete setup."
        case .setup:
            return "Capture a conversation. Find what matters. Keep local AI in your control, with optional cloud tools when you choose."
        case .ready:
            return "Start in the main window, or use the menu bar whenever inspiration strikes."
        }
    }
}

private struct OnboardingCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OpenBridgeTheme.card.opacity(0.74))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(OpenBridgeTheme.border.opacity(0.85), lineWidth: 1)
                    }
            }
    }
}

private struct OnboardingCardHeader: View {
    let title: String
    let subtitle: String
    var pill: String?
    var pillTint: Color = OpenBridgeTheme.brandTeal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(OpenBridgeTypography.heading(size: 20, weight: .bold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                Text(subtitle)
                    .font(OpenBridgeTypography.body(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let pill {
                OpenBridgeStatusPill(text: pill, tint: pillTint)
            }
        }
    }
}

private struct OnboardingCompatibilityTile: View {
    let title: String
    let subtitle: String
    let isSupported: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(isSupported ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .bold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                Text(subtitle)
                    .font(OpenBridgeTypography.body(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OpenBridgeTheme.border.opacity(0.85), lineWidth: 1)
                }
        }
    }
}

private struct OnboardingStatusRow: View {
    var number: Int?
    var icon: String?
    let iconTint: Color
    var iconForegroundColor = Color.white
    let title: String
    let subtitle: String
    var trailingTitle: String?
    var trailingTint: Color = OpenBridgeTheme.brandTeal
    var buttonTitle: String?
    var buttonProminent = false
    var action: (() -> Void)?
    var secondaryButtonTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconTint)
                    if let number {
                        Text("\(number)")
                            .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                            .foregroundStyle(iconForegroundColor)
                    } else {
                        Image(systemName: icon ?? "checkmark")
                            .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                            .foregroundStyle(iconForegroundColor)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OpenBridgeTypography.body(size: 15, weight: .bold))
                        .foregroundStyle(OpenBridgeTheme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if let trailingTitle {
                    OpenBridgeStatusPill(text: trailingTitle, tint: trailingTint)
                }

                if secondaryButtonTitle == nil, let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: buttonProminent))
                }
            }

            if secondaryButtonTitle != nil {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    if let buttonTitle, let action {
                        Button(buttonTitle, action: action)
                            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: buttonProminent))
                    }

                    if let secondaryButtonTitle, let secondaryAction {
                        Button(secondaryButtonTitle, action: secondaryAction)
                            .buttonStyle(OpenBridgeMiniButtonStyle())
                    }
                }
            }
        }
        .padding(12)
        .frame(minHeight: 58)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OpenBridgeTheme.border.opacity(0.85), lineWidth: 1)
                }
        }
    }
}

private struct OnboardingInfoBanner: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(OpenBridgeTheme.card)
                Image(systemName: icon)
                    .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                    .foregroundStyle(OpenBridgeTheme.brandTeal)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(OpenBridgeTypography.heading(size: 20, weight: .bold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                Text(subtitle)
                    .font(OpenBridgeTypography.body(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.brandTeal.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OpenBridgeTheme.brandTeal.opacity(0.34), lineWidth: 1)
                }
        }
    }
}

enum SettingsLayout {
    static let contentMaxWidth: CGFloat = 1120
    static let windowMinimumSize = NSSize(width: 860, height: 760)
    static let windowPreferredSize = NSSize(width: 1120, height: 840)
}

/// Compatibility wrapper. All entry points share the main-window hierarchy.
struct SettingsView: View {
    var body: some View {
        MainSettingsPage(navigate: { OpenBridgeNavigation.shared.request($0) })
    }
}

private enum SettingsDisclosureSection: Hashable {
    case shortcutsAndCommands
    case media
    case textControls
    case history
    case general
    case supportDiagnostics

    var title: String {
        switch self {
        case .shortcutsAndCommands:
            return "Shortcuts and commands"
        case .media:
            return "Audio and video files"
        case .textControls:
            return "Text controls"
        case .history:
            return "Dictation history"
        case .general:
            return "General app behavior"
        case .supportDiagnostics:
            return "Support and diagnostics"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let minHeight: CGFloat?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(title: title, summary: subtitle)

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .settingsCardSurface()
    }
}

private struct SettingsDisclosureCard<Content: View>: View {
    let title: String
    let summary: String
    @Binding var isExpanded: Bool
    let content: Content

    init(
        title: String,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    SettingsSectionHeader(title: title, summary: summary)

                    Spacer(minLength: 16)

                    Image(systemName: "chevron.right")
                        .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                SettingsDivider()
                    .padding(.top, 12)
                    .transition(.opacity)

                content
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface()
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(OpenBridgeTypography.heading(size: 16, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(OpenBridgeTypography.body(size: 15))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsGroupLabel: View {
    let title: String
    let summary: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)
                .textCase(.uppercase)

            Text(summary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private struct SettingsSubsectionHeader: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)

            Text(summary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(OpenBridgeTheme.border.opacity(0.85))
            .frame(height: 1)
    }
}

private struct SettingsCardSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OpenBridgeTheme.card.opacity(0.82))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OpenBridgeTheme.border.opacity(0.9), lineWidth: 1)
            }
    }
}

private extension View {
    func settingsCardSurface() -> some View {
        modifier(SettingsCardSurfaceModifier())
    }
}

private struct CommandModePresetMenuSection: View {
    @EnvironmentObject private var appState: AppState

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    var body: some View {
        PremiumSection("Command presets", subtitle: "Fast transformations for selected text.") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(appState.quickCommandModePresets) { preset in
                    Button {
                        Task { await appState.runCommandModePreset(preset) }
                    } label: {
                        Label(preset.title, systemImage: preset.systemImage)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(OpenBridgePresetButtonStyle())
                    .help(preset.summary)
                    .disabled(appState.isRecording || appState.isTranscribing || appState.isStartingRecording || appState.isTranscribingMedia)
                }
            }
        }
    }
}

private struct MediaTranscriptionMenuSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var youtubeURL = ""

    let chooseFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    chooseFile()
                } label: {
                    Label("Transcribe File", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(!appState.canStartMediaTranscription)
                .help("Transcribe a local audio or video file")

                if appState.isTranscribingMedia {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
            }

            HStack(spacing: 8) {
                TextField("YouTube URL", text: $youtubeURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!appState.canStartMediaTranscription)

                Button {
                    Task { await appState.transcribeYouTubeURL(youtubeURL) }
                } label: {
                    Label("Transcribe URL", systemImage: "link")
                }
                .disabled(!appState.canStartMediaTranscription || youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Transcribe a YouTube URL")
            }

            if let result = appState.mediaTranscriptionResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.sourceName)
                        .font(OpenBridgeTypography.heading(size: 16))
                    Text(result.transcript)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button {
                            appState.copyMediaTranscriptionResult()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        Button {
                            appState.saveMediaTranscriptionResult()
                        } label: {
                            Label("Save As", systemImage: "square.and.arrow.down")
                        }
                    }
                    .font(OpenBridgeTypography.body(size: 13))
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

struct GeneralSettingsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Enable Press Enter voice command",
                isOn: Binding(
                    get: { appState.pressEnterVoiceCommandEnabled },
                    set: { appState.setPressEnterVoiceCommandEnabled($0) }
                )
            )

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                )
            )
        }
    }
}

private struct MediaTranscriptionSettingsPanel: View {
    let chooseFile: () -> Void

    var body: some View {
        MediaTranscriptionMenuSection(chooseFile: chooseFile)
    }
}

private struct InstalledModelsSettingsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(appState.installedModels) { model in
                HStack {
                    Text(model.displayName)
                        .font(OpenBridgeTypography.body(size: 15, weight: .medium))
                        .foregroundStyle(OpenBridgeTheme.ink)
                    Spacer()
                    Text(model.installed ? "Installed" : "Not installed")
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(model.installed ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.mutedInk)
                }
            }
        }
    }
}

struct DictationHistorySettingsPanel: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showingClearHistoryConfirmation: Bool
    @Binding var showingHistoryDetails: Bool
    let requestHistoryRetentionChange: (DictationHistoryRetentionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("History retention", selection: Binding(
                get: { appState.historyRetentionMode },
                set: { requestHistoryRetentionChange($0) }
            )) {
                ForEach(DictationHistoryRetentionMode.privacyFirstOptions) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Text(appState.historyRetentionSummary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)

            if appState.historyRetentionNeedsChoice {
                OnboardingInfoBanner(
                    icon: "lock",
                    title: "History is currently off",
                    subtitle: "Choose a retention option before Openbridge saves any dictation history."
                )

                Button {
                    appState.setHistoryRetentionMode(.neverStore)
                } label: {
                    Label("Confirm Never Store", systemImage: "checkmark")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
            }

            LabeledContent("History file") {
                Text(appState.dictationHistoryFileLocation)
                    .font(OpenBridgeTypography.mono(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .textSelection(.enabled)
            }

            if appState.dictationHistory.isEmpty {
                Text("No dictations saved yet")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            } else {
                HStack {
                    Text("\(appState.dictationHistory.count) saved")
                        .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                    Spacer()
                    Button(role: .destructive) {
                        showingClearHistoryConfirmation = true
                    } label: {
                        Label("Clear all", systemImage: "trash")
                    }
                }

                DisclosureGroup(isExpanded: $showingHistoryDetails) {
                    DictationHistoryList(limit: nil, compact: false)
                } label: {
                    Text(showingHistoryDetails ? "Hide saved dictations" : "Show saved dictations")
                }
            }
        }
    }
}

struct AppIdentitySettingsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Version", value: AppIdentity.versionLabel)
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Bundle ID", value: AppIdentity.bundleIdentifier)
                    LabeledContent("Minimum macOS", value: AppIdentity.minimumMacOS)
                }
                .font(OpenBridgeTypography.metadata)
                .padding(.top, 8)
                .textSelection(.enabled)
            }
        }
    }
}

private struct ModelSettingsPanel: View {
    @EnvironmentObject private var appState: AppState
    let compact: Bool

    var body: some View {
        SettingsCard(
            "Speech model",
            subtitle: compact ? nil : "English is the default. Choose the balance of speed and accuracy.",
            minHeight: compact ? nil : 228
        ) {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                Picker("Model", selection: Binding(
                    get: { appState.selectedModelID },
                    set: { appState.setSelectedModelID($0) }
                )) {
                    ForEach(appState.userSelectableCuratedModels) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appState.userSelectableCuratedModels.isEmpty || !appState.canChangeSelectedModel)

                Text(appState.selectedModelSummary)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(appState.selectedModelInstalled ? "\(appState.selectedModelDisplayName) installed" : "\(appState.selectedModelDisplayName) not installed")
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(appState.selectedModelInstalled ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.warningInk)

                    Spacer()

                    Button {
                        if appState.selectedModelInstalled {
                            appState.runSystemCheck()
                        } else {
                            appState.installSelectedModel()
                        }
                    } label: {
                        Label(actionTitle, systemImage: appState.selectedModelInstalled ? "checklist" : "arrow.down.circle")
                    }
                    .disabled(actionDisabled)
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                }

                if !appState.canChangeSelectedModel {
                    if appState.isTranscribing || appState.isTranscribingMedia {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "waveform")
                                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                                .foregroundStyle(OpenBridgeTheme.brandBlue)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appState.isTranscribingMedia
                                     ? "Transcribing media \u{2014} model switching disabled."
                                     : "Transcription in progress \u{2014} model switching disabled.")
                                    .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                                    .foregroundStyle(OpenBridgeTheme.brandBlue)
                                Button(role: .destructive) {
                                    appState.cancelDictation()
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle")
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle())
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.blue.opacity(0.08))
                        }
                    } else {
                        Text("Finish the current recording before changing models.")
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.warningInk)
                    }
                } else if let readiness = appState.modelReadiness {
                    ModelReadinessInlineView(readiness: readiness)
                } else if !compact {
                    Text(appState.modelReadinessStatus)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionTitle: String {
        if appState.selectedModelInstalled {
            return appState.isRunningSystemCheck ? "Checking..." : "System Check"
        }

        return appState.isInstallingModel ? "Installing..." : "Install"
    }

    private var actionDisabled: Bool {
        appState.userSelectableCuratedModels.isEmpty
            || appState.isInstallingModel
            || appState.isWarmingSelectedModel
            || appState.isRunningSystemCheck
            || !appState.canChangeSelectedModel
    }
}

private struct ModelReadinessInlineView: View {
    let readiness: EngineReadinessPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(readiness.summary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: readiness.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(readiness.ready ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral)
            }
            .font(OpenBridgeTypography.body(size: 13, weight: .medium))
            .foregroundStyle(OpenBridgeTheme.mutedInk)

            ForEach(Array(readiness.displayChecks.prefix(3))) { check in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: iconName(for: check.state))
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(tint(for: check.state))
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.message)
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)

                        if let recovery = check.recovery, !recovery.isEmpty {
                            Text(recovery)
                                .font(OpenBridgeTypography.body(size: 13))
                                .foregroundStyle(OpenBridgeTheme.mutedInk.opacity(0.86))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func iconName(for state: String) -> String {
        switch state {
        case "warn":
            return "exclamationmark.circle"
        case "notRun":
            return "circle.dashed"
        case "fail":
            return "xmark.circle"
        default:
            return "checkmark.circle"
        }
    }

    private func tint(for state: String) -> Color {
        switch state {
        case "warn", "notRun":
            return OpenBridgeTheme.brandGold
        case "fail":
            return OpenBridgeTheme.brandCoral
        default:
            return OpenBridgeTheme.brandGreen
        }
    }
}

struct FeedbackSettingsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSubsectionHeader(
                title: "Beta feedback",
                summary: "Email feedback only when you choose. Openbridge does not send hidden analytics or telemetry."
            )

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.badge")
                    .font(OpenBridgeTypography.heading(size: 20, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.brandTeal)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Send feedback to \(FeedbackSupport.emailAddress).")
                        .font(OpenBridgeTypography.body(size: 15, weight: .medium))
                        .foregroundStyle(OpenBridgeTheme.ink)
                    Text(FeedbackSupport.privacyBoundary)
                        .font(OpenBridgeTypography.body(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenBridgeTheme.coolSurface.opacity(0.56))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    feedbackButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    feedbackButtons
                }
            }

            Text("To include setup details, run System Check and press Copy, then paste the summary into the email yourself. That keeps diagnostics optional and reviewable before anything leaves your Mac.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var feedbackButtons: some View {
        Button {
            appState.openFeedbackEmail()
        } label: {
            Label("Send feedback", systemImage: "envelope")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))

        Button {
            appState.copyFeedbackTemplate()
        } label: {
            Label("Copy template", systemImage: "doc.on.doc")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())

        Button {
            appState.copyFeedbackEmailAddress()
        } label: {
            Label("Copy address", systemImage: "at")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }
}

private struct SystemCheckSettingsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSubsectionHeader(
                title: "System Check",
                summary: "Copy a privacy-safe setup summary for support."
            )

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(appState.systemCheckReport?.summary ?? appState.systemCheckMessage)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: statusIconName)
                        .foregroundStyle(statusTint)
                }
                .font(OpenBridgeTypography.body(size: 15, weight: .medium))
                .foregroundStyle(OpenBridgeTheme.ink)

                Spacer(minLength: 12)

                Button {
                    appState.runSystemCheck()
                } label: {
                    Label(appState.isRunningSystemCheck ? "Checking" : "Run", systemImage: "checklist")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                .disabled(appState.isRunningSystemCheck)

                Button {
                    appState.copySystemCheckReport()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
                .disabled(appState.systemCheckReport == nil)
                .help("Copy a privacy-safe System Check summary")
            }

            Text("The copied summary excludes transcripts, audio, selected text, snippets, media contents, saved dictation history contents, credentials, and private keys.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if let report = appState.systemCheckReport {
                VStack(alignment: .leading, spacing: 10) {
                    SystemCheckGroup(title: "Needs attention", state: .fail, items: report.failures)
                    SystemCheckGroup(title: "Notes", state: .warn, items: report.warnings)
                    SystemCheckGroup(
                        title: "Passing",
                        state: .pass,
                        items: report.items.filter { $0.state == .pass }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIconName: String {
        guard let report = appState.systemCheckReport else {
            return "checklist"
        }
        if !report.failures.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        if !report.warnings.isEmpty {
            return "exclamationmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusTint: Color {
        guard let report = appState.systemCheckReport else {
            return OpenBridgeTheme.brandBlue
        }
        if !report.failures.isEmpty {
            return OpenBridgeTheme.brandCoral
        }
        if !report.warnings.isEmpty {
            return OpenBridgeTheme.brandGold
        }
        return OpenBridgeTheme.brandGreen
    }
}

private struct SystemCheckGroup: View {
    let title: String
    let state: SystemCheckState
    let items: [SystemCheckItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(groupTint)

                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconName)
                            .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                            .foregroundStyle(groupTint)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                                .foregroundStyle(OpenBridgeTheme.ink)
                            Text(item.message)
                                .font(OpenBridgeTypography.body(size: 13))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                            if let recovery = item.recovery, !recovery.isEmpty {
                                Text(recovery)
                                    .font(OpenBridgeTypography.body(size: 13))
                                    .foregroundStyle(OpenBridgeTheme.mutedInk.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(groupTint.opacity(0.08))
            }
        }
    }

    private var iconName: String {
        switch state {
        case .pass:
            return "checkmark.circle.fill"
        case .warn:
            return "exclamationmark.circle.fill"
        case .fail:
            return "xmark.circle.fill"
        }
    }

    private var groupTint: Color {
        switch state {
        case .pass:
            return OpenBridgeTheme.brandGreen
        case .warn:
            return OpenBridgeTheme.brandGold
        case .fail:
            return OpenBridgeTheme.brandCoral
        }
    }
}

private struct PermissionSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(
            "Permissions",
            subtitle: "Allow Openbridge to listen, catch shortcuts, and paste text where you are working.",
            minHeight: 228
        ) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionSettingsGuidance()

                ForEach(Array(appState.permissions.enumerated()), id: \.element.id) { index, permission in
                    let needsFollowUp = appState.needsPermissionFollowUp(for: permission.kind)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(permission.kind.title)
                                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                                Text(summary(for: permission.kind, needsFollowUp: needsFollowUp))
                                    .font(OpenBridgeTypography.body(size: 13))
                                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                            }

                            Spacer()

                            Text(label(for: permission.value, needsFollowUp: needsFollowUp))
                                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                                .foregroundStyle(tint(for: permission.value, needsFollowUp: needsFollowUp))
                        }

                        if permission.value != .granted {
                            HStack(spacing: 8) {
                                Button(needsFollowUp ? "Check again" : primaryActionTitle(for: permission.kind, value: permission.value)) {
                                    if needsFollowUp {
                                        appState.checkPermission(permission.kind)
                                    } else {
                                        performPrimaryAction(for: permission.kind, value: permission.value)
                                    }
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))

                                Button(openSettingsTitle(for: permission.kind, compact: needsFollowUp)) {
                                    appState.openPrivacySettings(permission.kind)
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle())
                            }
                        }
                    }

                    if index < appState.permissions.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private func label(for value: PermissionStateValue, needsFollowUp: Bool) -> String {
        if needsFollowUp {
            return "Waiting for Mac"
        }
        return value == .granted ? "Granted" : "Needs one step"
    }

    private func tint(for value: PermissionStateValue, needsFollowUp: Bool) -> Color {
        if needsFollowUp {
            return Color(red: 159 / 255, green: 101 / 255, blue: 9 / 255)
        }
        return value == .granted ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandCoral
    }

    private func summary(for kind: PermissionKind, needsFollowUp: Bool) -> String {
        guard needsFollowUp else {
            return kind.summary
        }

        switch kind {
        case .microphone:
            return "If you approved the Mac prompt, return here and check again."
        case .accessibility:
            return "If you enabled Openbridge in System Settings, return here and check again."
        case .inputMonitoring:
            return "Enable Openbridge if it is listed. If it is missing, reopen it from Applications and press Open Input Monitoring again."
        }
    }

    private func primaryActionTitle(for kind: PermissionKind, value: PermissionStateValue) -> String {
        if kind == .microphone && value == .unknown {
            return "Request"
        }
        return openSettingsTitle(for: kind, compact: true)
    }

    private func performPrimaryAction(for kind: PermissionKind, value: PermissionStateValue) {
        if kind == .microphone && value == .unknown {
            appState.requestPermission(kind)
        } else {
            appState.openPrivacySettings(kind)
        }
    }

    private func openSettingsTitle(for kind: PermissionKind, compact: Bool = false) -> String {
        if compact {
            return "Open"
        }

        switch kind {
        case .microphone:
            return "Open Microphone"
        case .accessibility:
            return "Open Accessibility"
        case .inputMonitoring:
            return "Open Input Monitoring"
        }
    }
}

private struct PermissionSettingsGuidance: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                .foregroundStyle(OpenBridgeTheme.brandBlue)
                .frame(width: 20, height: 20)

            Text("After changing a permission in System Settings, return to Openbridge and press Check again. The app also checks again when you bring it back to the front.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.56))
        }
    }
}

struct AdvancedTranscriptionSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(
            "Transcription cleanup",
            subtitle: "Keep transcripts readable before they are pasted.",
            minHeight: 228
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Formatting cleanup",
                    isOn: Binding(
                        get: { appState.formattingEnabled },
                        set: { appState.setFormattingEnabled($0) }
                    )
                )

                SettingsDivider()

                Picker("Cleanup mode", selection: Binding(
                    get: { appState.transcriptionCleanupMode },
                    set: { appState.setTranscriptionCleanupMode($0) }
                )) {
                    ForEach(TranscriptionCleanupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(appState.transcriptionCleanupMode.summary)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)

                SettingsDivider()

                Label {
                    Text("Names and recurring term corrections are managed in Custom dictionary.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.book.closed")
                        .foregroundStyle(OpenBridgeTheme.brandBlue)
                }
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)

                Text("Local cleanup stays on this Mac. If the cleanup model is unavailable, Openbridge keeps the original transcript.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MicrophoneSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(
            "Microphone",
            subtitle: "Choose the input Openbridge should use. Speak once to confirm the meter moves.",
            minHeight: 228
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Input", selection: Binding(
                    get: { appState.selectedMicrophoneID },
                    set: { appState.setSelectedMicrophoneID($0) }
                )) {
                    ForEach(appState.microphoneDevices) { device in
                        Text(device.pickerTitle).tag(device.id)
                    }
                }
                .disabled(appState.isRecording || appState.isTranscribing)

                HStack {
                    Text("Live meter")
                    Spacer()
                    ProgressView(value: appState.microphoneMeterLevel, total: 1)
                        .frame(width: 220)
                }

                Text(appState.microphoneDiagnosticsMessage)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)

                if let warning = appState.microphoneDiagnosticWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.warningInk)
                }

                Button {
                    appState.refreshMicrophoneDiagnostics()
                } label: {
                    Label("Refresh microphone inputs", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
    }
}

private struct CommandModePresetsSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(appState.commandModePresets.enumerated()), id: \.element.id) { index, preset in
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title)
                                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                                Text(preset.summary)
                                    .font(OpenBridgeTypography.body(size: 13))
                                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                            }
                        } icon: {
                            Image(systemName: preset.systemImage)
                                .foregroundStyle(OpenBridgeTheme.brandBlue)
                        }

                        Spacer()

                        Button {
                            Task { await appState.runCommandModePreset(preset) }
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                        .disabled(appState.isRecording || appState.isTranscribing || appState.isStartingRecording)
                    }

                    if index < appState.commandModePresets.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowSizingView {
        SettingsWindowSizingView()
    }

    func updateNSView(_ nsView: SettingsWindowSizingView, context: Context) {
        nsView.configureWindow()
    }
}

private final class SettingsWindowSizingView: NSView {
    private let minimumSize = SettingsLayout.windowMinimumSize
    private let preferredSize = SettingsLayout.windowPreferredSize
    private var didApplyInitialSize = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else {
            return
        }

        window.styleMask.insert(.resizable)
        window.minSize = minimumSize

        guard !didApplyInitialSize else {
            return
        }

        var frame = window.frame
        let width = max(frame.width, preferredSize.width)
        let height = max(frame.height, preferredSize.height)

        if width != frame.width || height != frame.height {
            frame.origin.y -= height - frame.height
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
        }

        didApplyInitialSize = true
    }
}

private struct ShortcutSettingsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.title)
                                .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                            Text(action.summary)
                                .font(OpenBridgeTypography.body(size: 13))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                                .lineLimit(2)
                        }
                        Spacer()

                        Picker(action.title, selection: Binding(
                            get: { appState.shortcutBinding(for: action) },
                            set: { appState.setShortcutBinding($0, for: action) }
                        )) {
                            ForEach(appState.availableShortcutBindings) { binding in
                                Text(binding.displayName).tag(binding)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                    }

                    if index < ShortcutAction.allCases.count - 1 {
                        SettingsDivider()
                    }
                }
            }

            if let message = appState.shortcutSettingsMessage {
                Text(message)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(message.contains("already used") || message.contains("cannot be used") ? OpenBridgeTheme.warningInk : OpenBridgeTheme.mutedInk)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("For this release, shortcut options stay on Right Option combinations to avoid common macOS system shortcuts.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                Spacer()
                Button("Reset shortcuts to defaults") {
                    appState.resetShortcutBindings()
                }
                .disabled(appState.usesDefaultShortcuts)
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SnippetSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var triggerPhrase = ""
    @State private var expansionText = ""
    @State private var editingSnippet: Snippet?
    @State private var formMessage: String?
    @State private var pendingDeleteSnippet: Snippet?
    @State private var showingDeleteConfirmation = false

    private var filteredSnippets: [Snippet] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return appState.snippets
        }

        return appState.snippets.filter { snippet in
            snippet.triggerPhrase.localizedCaseInsensitiveContains(query)
                || snippet.expansionText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search snippets", text: $searchText)

            TextField("Trigger phrase", text: $triggerPhrase)

            VStack(alignment: .leading, spacing: 6) {
                Text("Expansion text")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                TextEditor(text: $expansionText)
                    .font(OpenBridgeTypography.body(size: 16))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }

            if let formMessage {
                Text(formMessage)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.errorInk)
            }

            HStack {
                Button {
                    saveSnippet()
                } label: {
                    Label(editingSnippet == nil ? "Add snippet" : "Update snippet", systemImage: editingSnippet == nil ? "plus" : "checkmark")
                }
                .disabled(triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if editingSnippet != nil {
                    Button {
                        resetForm()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }

            if filteredSnippets.isEmpty {
                Text(appState.snippets.isEmpty ? "No snippets saved yet" : "No snippets match your search")
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            } else {
                ForEach(filteredSnippets) { snippet in
                    SnippetRow(
                        snippet: snippet,
                        editAction: { beginEditing(snippet) },
                        deleteAction: { requestDelete(snippet) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Delete this snippet?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteSnippet {
                    appState.deleteSnippet(pendingDeleteSnippet)
                }
                pendingDeleteSnippet = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSnippet = nil
            }
        } message: {
            Text("This removes the trigger and expansion text from this Mac.")
        }
    }

    private func saveSnippet() {
        let result: SnippetMutationResult
        if let editingSnippet {
            result = appState.updateSnippet(editingSnippet, triggerPhrase: triggerPhrase, expansionText: expansionText)
        } else {
            result = appState.createSnippet(triggerPhrase: triggerPhrase, expansionText: expansionText)
        }

        if result == .saved {
            resetForm()
        } else {
            formMessage = result.message
        }
    }

    private func beginEditing(_ snippet: Snippet) {
        editingSnippet = snippet
        triggerPhrase = snippet.triggerPhrase
        expansionText = snippet.expansionText
        formMessage = nil
    }

    private func requestDelete(_ snippet: Snippet) {
        pendingDeleteSnippet = snippet
        showingDeleteConfirmation = true
    }

    private func resetForm() {
        editingSnippet = nil
        triggerPhrase = ""
        expansionText = ""
        formMessage = nil
    }
}

private struct CustomDictionarySettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var heardAs = ""
    @State private var replaceWith = ""
    @State private var editingEntry: CustomDictionaryEntry?
    @State private var formMessage: String?
    @State private var pendingDeleteEntry: CustomDictionaryEntry?
    @State private var showingDeleteConfirmation = false

    private var filteredEntries: [CustomDictionaryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return appState.customDictionaryEntries
        }

        return appState.customDictionaryEntries.filter { entry in
            entry.heardAs.localizedCaseInsensitiveContains(query)
                || entry.replaceWith.localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedHeardAs: String {
        heardAs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplaceWith: String {
        replaceWith.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicateEntryExists: Bool {
        guard !trimmedHeardAs.isEmpty else {
            return false
        }
        let normalizedHeardAs = trimmedHeardAs.lowercased()
        return appState.customDictionaryEntries.contains { entry in
            entry.id != editingEntry?.id && entry.heardAs.lowercased() == normalizedHeardAs
        }
    }

    private var validationMessage: String? {
        if !heardAs.isEmpty || !replaceWith.isEmpty {
            if trimmedHeardAs.isEmpty {
                return "Enter the phrase Openbridge hears."
            }
            if trimmedReplaceWith.isEmpty {
                return "Enter the replacement text."
            }
        }
        if duplicateEntryExists {
            return "A custom dictionary entry already exists for that phrase."
        }
        return formMessage
    }

    private var canSave: Bool {
        !trimmedHeardAs.isEmpty && !trimmedReplaceWith.isEmpty && !duplicateEntryExists
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CustomDictionaryToggleRow(
                isEnabled: Binding(
                    get: { appState.vocabularyCorrectionsEnabled },
                    set: { appState.setVocabularyCorrectionsEnabled($0) }
                )
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When Openbridge hears...")
                            .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                        TextField("trishan panch", text: $heardAs)
                            .onChange(of: heardAs) { formMessage = nil }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Replace with...")
                            .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                        TextField("Trishan Panch", text: $replaceWith)
                            .onChange(of: replaceWith) { formMessage = nil }
                    }
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.brandCoral)
                }

                HStack(spacing: 8) {
                    Button {
                        saveEntry()
                    } label: {
                        Label(editingEntry == nil ? "Add entry" : "Update entry", systemImage: editingEntry == nil ? "plus" : "checkmark")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                    .disabled(!canSave)

                    if editingEntry != nil {
                        Button {
                            resetForm()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    }

                    Spacer()

                    Text(appState.customDictionaryFileLocation)
                        .font(OpenBridgeTypography.mono(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            SettingsDivider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Entries are stored locally and applied after transcription, before text is pasted.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                TextField("Search saved entries", text: $searchText)
                    .frame(width: 240)
                    .disabled(appState.customDictionaryEntries.isEmpty)
            }

            if filteredEntries.isEmpty {
                Text(appState.customDictionaryEntries.isEmpty ? "No custom dictionary entries saved yet." : "No custom dictionary entries match your search.")
                    .font(OpenBridgeTypography.body(size: 15))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                        CustomDictionaryEntryRow(
                            entry: entry,
                            editAction: { beginEditing(entry) },
                            deleteAction: { requestDelete(entry) }
                        )

                        if index < filteredEntries.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Delete this dictionary entry?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteEntry {
                    appState.deleteCustomDictionaryEntry(pendingDeleteEntry)
                }
                pendingDeleteEntry = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            Text("This removes the local correction from this Mac.")
        }
    }

    private func saveEntry() {
        let result: CustomDictionaryMutationResult
        if let editingEntry {
            result = appState.updateCustomDictionaryEntry(
                editingEntry,
                heardAs: heardAs,
                replaceWith: replaceWith
            )
        } else {
            result = appState.createCustomDictionaryEntry(heardAs: heardAs, replaceWith: replaceWith)
        }

        if result == .saved {
            resetForm()
        } else {
            formMessage = result.message
        }
    }

    private func beginEditing(_ entry: CustomDictionaryEntry) {
        editingEntry = entry
        heardAs = entry.heardAs
        replaceWith = entry.replaceWith
        formMessage = nil
    }

    private func requestDelete(_ entry: CustomDictionaryEntry) {
        pendingDeleteEntry = entry
        showingDeleteConfirmation = true
    }

    private func resetForm() {
        editingEntry = nil
        heardAs = ""
        replaceWith = ""
        formMessage = nil
    }
}

private struct CustomDictionaryToggleRow: View {
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Use custom dictionary")
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                Text("Turns on saved entries and Openbridge's built-in vocabulary cleanup.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("Use custom dictionary", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.45))
        }
    }
}

private struct CustomDictionaryEntryRow: View {
    let entry: CustomDictionaryEntry
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.heardAs)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .lineLimit(1)

                Text("Replaces with \(entry.replaceWith)")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    editAction()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
        .padding(.vertical, 10)
    }
}

private struct SpokenFormattingSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    private let commandRows = [
        SpokenFormattingCommandRow(spokenPhrase: "new line", result: "line break"),
        SpokenFormattingCommandRow(spokenPhrase: "new paragraph", result: "blank line"),
        SpokenFormattingCommandRow(spokenPhrase: "period", result: "."),
        SpokenFormattingCommandRow(spokenPhrase: "comma", result: ","),
        SpokenFormattingCommandRow(spokenPhrase: "question mark", result: "?"),
    ]

    private let commandColumns = [
        GridItem(.flexible(), spacing: 8, alignment: .top),
        GridItem(.flexible(), spacing: 8, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpokenFormattingToggleRow(
                isEnabled: Binding(
                    get: { appState.spokenFormattingCommandsEnabled },
                    set: { appState.setSpokenFormattingCommandsEnabled($0) }
                )
            )

            SettingsDivider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Supported commands")
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    LazyVGrid(columns: commandColumns, alignment: .leading, spacing: 8) {
                        ForEach(commandRows) { row in
                            SpokenFormattingCommandChip(row: row)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Preview")
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("\"hello comma world period\"")
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                        Text("hello, world.")
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                            .foregroundStyle(OpenBridgeTheme.ink)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(OpenBridgeTheme.canvas)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OpenBridgeTheme.border.opacity(0.86), lineWidth: 1)
                    }
                }
                .frame(width: 250, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpokenFormattingToggleRow: View {
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Use spoken formatting commands")
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                Text("Off by default. When enabled, Openbridge converts the phrases below before pasting your dictation.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("Use spoken formatting commands", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.45))
        }
    }
}

private struct SpokenFormattingCommandRow: Identifiable {
    var id: String { spokenPhrase }
    let spokenPhrase: String
    let result: String
}

private struct SpokenFormattingCommandChip: View {
    let row: SpokenFormattingCommandRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.spokenPhrase)
                .foregroundStyle(OpenBridgeTheme.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.result)
                .fontWeight(.semibold)
                .foregroundStyle(OpenBridgeTheme.brandBlue)
                .lineLimit(1)
        }
        .font(OpenBridgeTypography.body(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OpenBridgeTheme.canvas)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.86), lineWidth: 1)
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snippet.triggerPhrase)
                .font(OpenBridgeTypography.heading(size: 16))
            Text(snippet.expansionText)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    editAction()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Spacer()

                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .font(OpenBridgeTypography.body(size: 13))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}

private struct DictationHistoryList: View {
    @EnvironmentObject private var appState: AppState

    let limit: Int?
    let compact: Bool

    private var entries: [DictationHistoryEntry] {
        guard let limit else {
            return appState.dictationHistory
        }
        return Array(appState.dictationHistory.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            ForEach(entries) { entry in
                DictationHistoryRow(entry: entry, compact: compact)
            }
        }
    }
}

private struct DictationHistoryRow: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingDeleteConfirmation = false

    let entry: DictationHistoryEntry
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.transcript)
                .font(compact ? .caption : .callout)
                .lineLimit(compact ? 6 : 8)
                .fixedSize(horizontal: false, vertical: true)

            Text(metadataText)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .lineLimit(compact ? 2 : 1)

            HStack(spacing: 8) {
                Button {
                    appState.copyHistoryEntry(entry)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy transcript")

                Button {
                    appState.repasteHistoryEntry(entry)
                } label: {
                    Label("Paste", systemImage: "arrow.turn.down.right")
                }
                .help("Paste transcript into the active app")

                Spacer()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete from history")
            }
            .font(OpenBridgeTypography.body(size: 13))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, compact ? 2 : 6)
        .alert("Delete this dictation?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                appState.deleteHistoryEntry(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved history entry from this Mac.")
        }
    }

    private var metadataText: String {
        var parts = [entry.createdAt.formatted(date: .abbreviated, time: .shortened)]

        if let duration = durationLabel {
            parts.append(duration)
        }

        parts.append(entry.modelLabel?.isEmpty == false ? entry.modelLabel! : entry.modelIdentifier)

        if let sourceApplication = entry.sourceApplication, !sourceApplication.isEmpty {
            parts.append("From \(sourceApplication)")
        }

        return parts.joined(separator: " - ")
    }

    private var durationLabel: String? {
        guard let durationSeconds = entry.durationSeconds else {
            return nil
        }
        let totalSeconds = max(0, Int(durationSeconds.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }
}
