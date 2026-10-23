import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBridgeUI

struct MainDictationPage: View {
    @EnvironmentObject private var appState: AppState
    let navigate: (MainWindowSection) -> Void

    var body: some View {
        MainPageScaffold {
            MainPageHeader(
                title: "A little less typing.",
                subtitle: appState.readyForDictation
                    ? "Speak naturally. Keep your words, your rhythm, and your focus."
                    : appState.dictationSetupMessage,
                statusText: appState.readyForDictation ? "Ready" : "Needs setup",
                statusTint: appState.readyForDictation ? OpenBridgeTheme.brandTeal : OpenBridgeTheme.brandCoral
            )

            MainVoiceTypingIntroduction(navigate: navigate)

            MainDictationReadinessPanel(navigate: navigate)

            MainTwoColumnGrid {
                MainMicrophonePreferenceCard()

                MainPasteBehaviorPreferenceCard()
            }

            MainShortcutPreferenceCard()

            MainVoiceCleanupPreferenceCard(navigate: navigate)

            MainTwoColumnGrid {
                MainHandsFreePreferenceCard()

                MainSpokenFormattingPreferenceCard()
            }
        }
    }
}

struct MainDictationReadinessPanel: View {
    @EnvironmentObject private var appState: AppState
    let navigate: (MainWindowSection) -> Void

    private var permissionsNeedingAttention: [PermissionState] {
        appState.permissions.filter { $0.value != .granted }
    }

    var body: some View {
        MainInfoCard("Readiness", systemImage: appState.readyForDictation ? "checkmark.circle" : "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(appState.readyForDictation ? "Dictation is ready on this Mac." : appState.dictationSetupMessage)
                    .font(OpenBridgeTypography.body)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if permissionsNeedingAttention.isEmpty {
                    MainFactRow(label: "Permissions", value: "Microphone, Accessibility, and Input Monitoring are ready.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(permissionsNeedingAttention) { permission in
                            MainPermissionPreferenceRow(permission: permission)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        readinessActions
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        readinessActions
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var readinessActions: some View {
        Button {
            appState.refresh()
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: !appState.readyForDictation))

        Button {
            navigate(.systemCheck)
        } label: {
            Label("System Check", systemImage: "checklist")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())

        Button {
            navigate(.help)
        } label: {
            Label("Help", systemImage: "questionmark.circle")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }
}

struct MainPermissionPreferenceRow: View {
    @EnvironmentObject private var appState: AppState
    let permission: PermissionState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.value == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                .foregroundStyle(permission.value == .granted ? OpenBridgeTheme.brandTeal : OpenBridgeTheme.brandCoral)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.kind.title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(permission.kind.summary)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                appState.openPrivacySettings(permission.kind)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.44))
        }
    }
}

struct MainMicrophonePreferenceCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Microphone", systemImage: "mic") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Input", selection: Binding(
                    get: { appState.selectedMicrophoneID },
                    set: { appState.setSelectedMicrophoneID($0) }
                )) {
                    ForEach(appState.microphoneDevices) { device in
                        Text(device.pickerTitle).tag(device.id)
                    }
                }
                .disabled(appState.isRecording || appState.isTranscribing)

                HStack(spacing: 12) {
                    Text("Live meter")
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)

                    ProgressView(value: appState.microphoneMeterLevel, total: 1)
                        .frame(maxWidth: .infinity)
                }

                Text(microphoneStatusMessage)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if let warning = appState.microphoneDiagnosticWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.brandGold)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    appState.refreshMicrophoneDiagnostics()
                } label: {
                    Label("Refresh Inputs", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
        .task {
            appState.startMicrophoneDiagnostics(for: .mainDictationPreferences)
        }
        .onDisappear {
            appState.stopMicrophoneDiagnostics(for: .mainDictationPreferences)
        }
    }

    private var microphoneStatusMessage: String {
        if appState.microphoneDiagnosticsMessage == "Open Settings to test microphone input." {
            return "Use Refresh Inputs to test microphone input on this page."
        }
        return appState.microphoneDiagnosticsMessage
    }
}

struct MainPasteBehaviorPreferenceCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Paste behavior", systemImage: "arrow.turn.down.right") {
            VStack(alignment: .leading, spacing: 12) {
                MainTogglePreferenceRow(
                    title: "Formatting cleanup",
                    subtitle: "Clean punctuation and spacing before text is pasted.",
                    isOn: Binding(
                        get: { appState.formattingEnabled },
                        set: { appState.setFormattingEnabled($0) }
                    )
                )

                MainTogglePreferenceRow(
                    title: "Press Enter voice command",
                    subtitle: "When enabled, a terminal phrase can paste the transcript and press Enter.",
                    isOn: Binding(
                        get: { appState.pressEnterVoiceCommandEnabled },
                        set: { appState.setPressEnterVoiceCommandEnabled($0) }
                    )
                )

                MainFactRow(label: "Paste last", value: appState.pasteLastShortcutDescription)

                Button {
                    appState.pasteLastTranscript()
                } label: {
                    Label("Paste Last Transcript", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: appState.hasPasteableLastTranscript))
                .disabled(!appState.hasPasteableLastTranscript)
            }
        }
    }
}

struct MainShortcutPreferenceCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Shortcuts", systemImage: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                    MainShortcutPreferenceRow(action: action)

                    if index < ShortcutAction.allCases.count - 1 {
                        Divider()
                    }
                }

                if let message = appState.shortcutSettingsMessage {
                    Text(message)
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(shortcutMessageTint(for: message))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Shortcut options stay on Right Option combinations to avoid common macOS conflicts.")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button {
                        appState.resetShortcutBindings()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .disabled(appState.usesDefaultShortcuts)
                }
            }
        }
    }

    private func shortcutMessageTint(for message: String) -> Color {
        message.contains("already used") || message.contains("cannot be used")
            ? OpenBridgeTheme.brandGold
            : OpenBridgeTheme.mutedInk
    }
}

struct MainShortcutPreferenceRow: View {
    @EnvironmentObject private var appState: AppState
    let action: ShortcutAction

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(action.summary)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker(action.title, selection: Binding(
                get: { appState.shortcutBinding(for: action) },
                set: { appState.setShortcutBinding($0, for: action) }
            )) {
                ForEach(appState.availableShortcutBindings) { binding in
                    Text(binding.displayName).tag(binding)
                }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }
}

struct MainHandsFreePreferenceCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Hands-free", systemImage: "mic.badge.plus") {
            VStack(alignment: .leading, spacing: 12) {
                MainFactRow(label: "Shortcut", value: appState.handsFreeShortcutDescription)
                MainFactRow(label: "Auto-stop", value: appState.handsFreeMaxDurationLabel)
                MainFactRow(label: "Warning", value: appState.handsFreeWarningLeadLabel)

                Text("Hands-free recording stops automatically and keeps the recording local on this Mac.")
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await appState.toggleHandsFreeDictation() }
                } label: {
                    Label(appState.isHandsFreeRecording ? "Stop Hands-Free" : "Start Hands-Free", systemImage: "mic.badge.plus")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: appState.isHandsFreeRecording))
                .disabled(appState.isRecording && !appState.isHandsFreeRecording)
            }
        }
    }
}

struct MainSpokenFormattingPreferenceCard: View {
    @EnvironmentObject private var appState: AppState

    private let examples = [
        ("new line", "line break"),
        ("new paragraph", "blank line"),
        ("period", "."),
        ("comma", ","),
        ("question mark", "?"),
    ]

    var body: some View {
        MainInfoCard("Spoken formatting", systemImage: "textformat") {
            VStack(alignment: .leading, spacing: 12) {
                MainTogglePreferenceRow(
                    title: "Use spoken formatting commands",
                    subtitle: "Convert phrases like comma and new paragraph before pasting.",
                    isOn: Binding(
                        get: { appState.spokenFormattingCommandsEnabled },
                        set: { appState.setSpokenFormattingCommandsEnabled($0) }
                    )
                )

                LazyVGrid(columns: MainGridColumns.two, alignment: .leading, spacing: 8) {
                    ForEach(examples, id: \.0) { phrase, result in
                        MainFormattingExampleChip(phrase: phrase, result: result)
                    }
                }
            }
        }
    }
}

struct MainTogglePreferenceRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(subtitle)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.44))
        }
    }
}

struct MainFormattingExampleChip: View {
    let phrase: String
    let result: String

    var body: some View {
        HStack(spacing: 8) {
            Text(phrase)
                .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                .foregroundStyle(OpenBridgeTheme.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(result)
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OpenBridgeTheme.card.opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.8), lineWidth: 1)
        }
    }
}

