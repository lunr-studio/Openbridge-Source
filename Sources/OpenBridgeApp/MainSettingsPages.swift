import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBridgeUI

struct MainModelsPage: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainPageScaffold {
            MainPageHeader(
                title: "Models & performance",
                subtitle: appState.transcriptionPerformanceModeSummary,
                statusText: appState.transcriptionPerformanceMode.title,
                statusTint: performanceStatusTint
            )

            MainPerformanceModePanel()
            AdvancedTranscriptionSettingsSection()

            MainTwoColumnGrid {
                MainActiveModelPanel()

                MainModelReadinessPanel()
            }

            MainInstalledModelsPanel()

            DisclosureGroup("Advanced runtime details") {
                VStack(alignment: .leading, spacing: 16) {
                    MainParakeetHookPanel()
                    MainBenchmarkPanel()
                }
                .padding(.top, 16)
            }
            .font(OpenBridgeTypography.control)
        }
    }

    private var performanceStatusTint: Color {
        if appState.transcriptionPerformanceMode == .custom {
            return OpenBridgeTheme.brandGold
        }
        if appState.selectedModelAvailableForTranscription {
            return OpenBridgeTheme.brandTeal
        }
        return appState.selectedModelInstalled ? OpenBridgeTheme.brandGold : OpenBridgeTheme.brandCoral
    }
}

struct MainPerformanceModePanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Speed & quality mode", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: MainGridColumns.adaptiveModeCards, alignment: .leading, spacing: 10) {
                    ForEach(appState.userSelectablePerformanceModes) { mode in
                        MainPerformanceModeButton(
                            mode: mode,
                            isSelected: appState.transcriptionPerformanceMode == mode,
                            modelName: modelDisplayName(for: mode),
                            installState: installState(for: mode)
                        ) {
                            appState.setTranscriptionPerformanceMode(mode)
                        }
                        .disabled(!appState.canChangeSelectedModel || appState.isInstallingModel)
                    }
                }

                if appState.transcriptionPerformanceMode == .custom {
                    Label("Custom model settings are active. Choose a mode above to return to a managed preset.", systemImage: "slider.horizontal.3")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.warningInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
        }
    }

    private func modelDisplayName(for mode: TranscriptionPerformanceMode) -> String {
        guard let identifier = mode.targetModelIdentifier else {
            return "Planned"
        }
        if let model = appState.curatedModels.first(where: { $0.identifier == identifier }) {
            return model.displayName
        }
        switch identifier {
        case "whisper-tiny":
            return "Whisper Tiny"
        case "whisper-base":
            return "Whisper Base"
        case "whisper-large-v3":
            return "Whisper Large v3"
        default:
            return identifier
        }
    }

    private func installState(for mode: TranscriptionPerformanceMode) -> String {
        guard let identifier = mode.targetModelIdentifier else {
            return "Planned"
        }
        if identifier.localizedCaseInsensitiveContains("parakeet") {
            return appState.installedModels.first(where: { $0.identifier == identifier })?.installed == true
                ? "Candidate installed"
                : "Candidate"
        }
        return appState.installedModels.first(where: { $0.identifier == identifier })?.installed == true
            ? "Installed"
            : "Install when selected"
    }
}

struct MainPerformanceModeButton: View {
    let mode: TranscriptionPerformanceMode
    let isSelected: Bool
    let modelName: String
    let installState: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.systemImage)
                    .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : OpenBridgeTheme.brandBlue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(mode.title)
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : OpenBridgeTheme.ink)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(mode.useCase)
                            .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : OpenBridgeTheme.mutedInk)
                            .lineLimit(1)
                    }

                    Text(mode.summary)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.86) : OpenBridgeTheme.mutedInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(modelName) / \(mode.targetCleanupMode?.title ?? "Planned") cleanup / \(installState)")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.76) : OpenBridgeTheme.mutedInk.opacity(0.86))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? OpenBridgeTheme.ink : OpenBridgeTheme.coolSurface.opacity(0.42))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? OpenBridgeTheme.ink.opacity(0.2) : OpenBridgeTheme.border.opacity(0.82), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct MainPerformanceModeHookRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: TranscriptionPerformanceMode.experimental.systemImage)
                .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.brandTeal)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Experimental")
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    OpenBridgeStatusPill(text: "Planned", tint: OpenBridgeTheme.brandTeal)
                }

                Text(TranscriptionPerformanceMode.experimental.summary)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.brandTeal.opacity(0.08))
        }
    }
}

struct MainActiveModelPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Active voice typing model", systemImage: "waveform") {
            Picker("Speech model", selection: Binding(get: { appState.selectedModelID }, set: { appState.setSelectedModelID($0) })) {
                ForEach(appState.userSelectableCuratedModels) { model in
                    Text(model.displayName).tag(model.identifier)
                }
            }
            .pickerStyle(.menu)
            .disabled(appState.userSelectableCuratedModels.isEmpty || !appState.canChangeSelectedModel)
            MainFactRow(label: "Mode", value: appState.transcriptionPerformanceMode.title)
            MainFactRow(label: "Speech", value: appState.selectedModelDisplayName)
            MainFactRow(label: "Model ID", value: appState.selectedModelID)
            MainFactRow(label: "Install", value: appState.selectedModelInstallStatusLabel)
            MainFactRow(label: "Runtime", value: appState.selectedModelRuntimeStatusLabel)

            Text(appState.selectedModelSummary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    modelActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    modelActions
                }
            }
        }
    }

    @ViewBuilder
    private var modelActions: some View {
        Button {
            if appState.selectedModelInstalled {
                appState.runSystemCheck()
            } else {
                appState.installSelectedModel()
            }
        } label: {
            Label(appState.selectedModelInstalled ? "Check Model" : "Install Model", systemImage: appState.selectedModelInstalled ? "checklist" : "arrow.down.circle")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: !appState.selectedModelInstalled))
        .disabled(appState.isInstallingModel || appState.isRunningSystemCheck || !appState.canChangeSelectedModel)

        Button {
            appState.warmSelectedModel()
        } label: {
            Label(appState.isWarmingSelectedModel ? "Warming..." : "Warm Model", systemImage: "flame")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
        .disabled(!appState.selectedModelInstalled || appState.isWarmingSelectedModel || appState.isInstallingModel)
    }
}

struct MainModelReadinessPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Runtime & cleanup", systemImage: "cpu") {
            MainFactRow(label: "Readiness", value: appState.selectedModelRuntimeStatusSummary)
            MainFactRow(label: "Cleanup", value: appState.transcriptionCleanupMode.title)

            Text(appState.localCleanupStatusSummary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if let readiness = appState.modelReadiness {
                let checks = readiness.displayChecks
                if checks.isEmpty {
                    Label("No model or cleanup issues reported.", systemImage: "checkmark.circle.fill")
                        .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                        .foregroundStyle(OpenBridgeTheme.brandGreen)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(checks) { check in
                            MainReadinessCheckRow(check: check)
                        }
                    }
                }
            } else {
                Text(appState.modelReadinessStatus)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MainReadinessCheckRow: View {
    let check: EngineReadinessCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

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

    private var iconName: String {
        switch check.state {
        case "pass":
            return "checkmark.circle.fill"
        case "fail":
            return "exclamationmark.triangle.fill"
        default:
            return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch check.state {
        case "pass":
            return OpenBridgeTheme.brandGreen
        case "fail":
            return OpenBridgeTheme.brandCoral
        default:
            return OpenBridgeTheme.brandGold
        }
    }
}

struct MainInstalledModelsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Installed models", systemImage: "externaldrive") {
            if appState.installedModels.isEmpty {
                Text(appState.managedModelStatus)
                    .font(OpenBridgeTypography.body(size: 15))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(appState.installedModels) { model in
                        MainInstalledModelRow(model: model, isSelected: model.identifier == appState.selectedModelID)
                    }
                }
            }
        }
    }
}

struct MainInstalledModelRow: View {
    let model: InstalledModel
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                .foregroundStyle(model.installed ? OpenBridgeTheme.brandGreen : OpenBridgeTheme.brandGold)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)
                        .lineLimit(1)

                    if isSelected {
                        OpenBridgeStatusPill(text: "Active", tint: OpenBridgeTheme.brandBlue)
                    }

                    if model.isParakeetCandidate {
                        OpenBridgeStatusPill(text: "V2 default", tint: OpenBridgeTheme.brandTeal)
                    }
                }

                Text(model.summary)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? OpenBridgeTheme.coolSurface.opacity(0.54) : OpenBridgeTheme.cardSoft.opacity(0.8))
        }
    }
}

struct MainBenchmarkPanel: View {
    var body: some View {
        MainInfoCard("Benchmark baseline", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            MainFactRow(label: "Current fallback", value: "Whisper Base")
            MainFactRow(label: "V2 default", value: "Parakeet TDT 0.6B v3 MLX BF16")
            MainFactRow(label: "Measured by", value: "engine benchmark")
            MainFactRow(label: "Local table", value: "V2 optimization roadmap")

            Text("Benchmarks are captured outside the app so Parakeet default and Whisper fallback stay measurable.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Text("Run `make engine-benchmark` to add local timing rows.")
                .font(OpenBridgeTypography.mono(size: 13))
                .foregroundStyle(OpenBridgeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainParakeetHookPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Parakeet V2 default", systemImage: "testtube.2") {
            HStack(alignment: .top, spacing: 12) {
                OpenBridgeStatusPill(text: "V2 default", tint: OpenBridgeTheme.brandTeal)
                OpenBridgeStatusPill(text: "Local runtime", tint: OpenBridgeTheme.brandGold)
                OpenBridgeStatusPill(text: "Whisper fallback", tint: OpenBridgeTheme.brandBlue)
            }

            Text(appState.parakeetExperimentalStatus)
                .font(OpenBridgeTypography.body(size: 15))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Text("Local runtime information helps support identify model-readiness issues.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.parakeetCandidateSelectable {
                Text("If Parakeet is not ready, OpenBridge can use Whisper Base fallback while setup finishes.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MainSystemCheckPage: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainPageScaffold {
            MainPageHeader(
                title: "A clear picture of your setup.",
                subtitle: systemCheckSubtitle,
                statusText: systemCheckStatusText,
                statusTint: systemCheckStatusTint
            )

            MainHeroPanel(
                title: "Local setup readiness",
                subtitle: appState.systemCheckReport?.summary ?? "Run a check before sharing setup details with support.",
                statusText: systemCheckStatusText,
                statusTint: systemCheckStatusTint
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        systemCheckActions
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        systemCheckActions
                    }
                }

                Text("The copied support summary includes setup state only. It leaves out audio, transcript text, selected text, snippets, media contents, saved history contents, credentials, and private keys.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MainTwoColumnGrid {
                MainSystemPermissionsCard()
                MainSystemModelCard()
                MainSystemStorageCard()
                MainSystemSupportCard()
            }

            if let report = appState.systemCheckReport {
                MainSystemCheckReportPanel(report: report)
            } else {
                MainEmptyState(
                    systemImage: "checklist",
                    title: "System Check has not run yet",
                    subtitle: "Run System Check to see permission, model, Help, shortcut, app, and storage readiness in one place."
                )
            }
        }
    }

    @ViewBuilder
    private var systemCheckActions: some View {
        Button {
            appState.runSystemCheck()
        } label: {
            Label(appState.isRunningSystemCheck ? "Checking..." : "Run System Check", systemImage: "arrow.clockwise")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
        .disabled(appState.isRunningSystemCheck)

        Button {
            appState.copySystemCheckReport()
        } label: {
            Label("Copy Summary", systemImage: "doc.on.doc")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
        .disabled(appState.systemCheckReport == nil)

        Button {
            appState.openHelp()
        } label: {
            Label("Open Help", systemImage: "questionmark.circle")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }

    private var systemCheckSubtitle: String {
        if let report = appState.systemCheckReport {
            return report.summary
        }
        return appState.readyForDictation
            ? "Dictation is ready. Run System Check when you want a privacy-safe setup summary."
            : appState.dictationSetupMessage
    }

    private var systemCheckStatusText: String {
        guard let report = appState.systemCheckReport else {
            return appState.isRunningSystemCheck ? "Running" : "Not run"
        }
        return report.isReady ? "Ready" : "Attention"
    }

    private var systemCheckStatusTint: Color {
        guard let report = appState.systemCheckReport else {
            return appState.isRunningSystemCheck ? OpenBridgeTheme.brandBlue : OpenBridgeTheme.brandGold
        }
        return report.isReady ? OpenBridgeTheme.brandTeal : OpenBridgeTheme.brandCoral
    }
}

struct MainSystemPermissionsCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Permissions", systemImage: "hand.raised") {
            ForEach(appState.permissions) { permission in
                MainPermissionCheckRow(permission: permission)
            }
        }
    }
}

struct MainPermissionCheckRow: View {
    @EnvironmentObject private var appState: AppState
    let permission: PermissionState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permissionIconName)
                .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                .foregroundStyle(permissionTint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(permission.kind.title)
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    OpenBridgeStatusPill(text: permission.value.label, tint: permissionTint)
                }

                Text(permission.kind.summary)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if permission.value != .granted {
                    Button {
                        appState.openPrivacySettings(permission.kind)
                    } label: {
                        Label("Open Settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var permissionIconName: String {
        permission.value == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var permissionTint: Color {
        switch permission.value {
        case .granted:
            return OpenBridgeTheme.brandGreen
        case .needsAttention:
            return OpenBridgeTheme.brandCoral
        case .unknown:
            return OpenBridgeTheme.brandGold
        }
    }
}

struct MainSystemModelCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Model & runtime", systemImage: "cpu") {
            MainFactRow(label: "Speech", value: appState.selectedModelDisplayName)
            MainFactRow(label: "Mode", value: appState.transcriptionPerformanceMode.title)
            MainFactRow(label: "Install", value: appState.selectedModelInstallStatusLabel)
            MainFactRow(label: "Runtime", value: appState.selectedModelRuntimeStatusLabel)
            MainFactRow(label: "Cleanup", value: appState.transcriptionCleanupMode.title)

            Text(appState.selectedModelRuntimeStatusSummary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(appState.localCleanupStatusSummary)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainSystemStorageCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("App & local storage", systemImage: "internaldrive") {
            MainFactRow(label: "Version", value: AppIdentity.versionLabel)
            MainFactRow(label: "History", value: appState.historyRetentionMode.title)
            MainFactRow(label: "Saved", value: "\(appState.dictationHistory.count) dictations")
            MainFactRow(label: "History file", value: appState.dictationHistoryFileLocation)
            MainFactRow(label: "Dictionary", value: appState.customDictionaryFileLocation)

            Text("Paths are shown as local setup locations, not as uploaded diagnostics.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainSystemSupportCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Support boundary", systemImage: "lock.shield") {
            MainFactRow(label: "Help", value: OpenBridgeHelpController.shared.availabilityStatus().available ? "Available" : "Needs reinstall")
            MainFactRow(label: "Dictation", value: appState.readyForDictation ? "Ready" : "Needs setup")
            MainFactRow(label: "Files", value: appState.readyForMediaTranscription ? "Ready" : "Needs model")

            Text("Support details stay reviewable: run System Check, copy the summary, and paste only what you choose to send.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                appState.copySystemCheckReport()
            } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
            .disabled(appState.systemCheckReport == nil)
        }
    }
}

struct MainSystemCheckReportPanel: View {
    let report: SystemCheckReport

    var body: some View {
        MainInfoCard("Latest report", systemImage: "list.bullet.rectangle") {
            MainFactRow(label: "Generated", value: report.generatedAt.formatted(date: .abbreviated, time: .shortened))
            MainFactRow(label: "Summary", value: report.summary)

            MainSystemCheckGroup(title: "Needs attention", state: .fail, items: report.failures)
            MainSystemCheckGroup(title: "Notes", state: .warn, items: report.warnings)
            MainSystemCheckGroup(
                title: "Passing",
                state: .pass,
                items: report.items.filter { $0.state == .pass }
            )
        }
    }
}

struct MainSystemCheckGroup: View {
    let title: String
    let state: SystemCheckState
    let items: [SystemCheckItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(state.mainWindowTint)

                ForEach(items) { item in
                    MainSystemCheckItemRow(item: item)
                }
            }
            .padding(.top, 2)
        }
    }
}

struct MainSystemCheckItemRow: View {
    let item: SystemCheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.state.mainWindowIconName)
                .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                .foregroundStyle(item.state.mainWindowTint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    OpenBridgeStatusPill(text: item.state.label, tint: item.state.mainWindowTint)
                }

                Text(item.message)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if let recovery = item.recovery, !recovery.isEmpty {
                    Text(recovery)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

struct MainHelpPage: View {
    @EnvironmentObject private var appState: AppState
    let navigate: (MainWindowSection) -> Void
    @State private var query = ""

    private var topics: [MainHelpTopic] {
        [
            MainHelpTopic(title: "Get started", symbol: "checklist", summary: "Permissions, a local model, and your first meeting.", details: [
                "Start a meeting from Home. Choose the microphone and whether to capture system audio for an online meeting.",
                "Voice typing also uses Accessibility to insert text and Input Monitoring for global shortcuts.",
                "After changing a macOS permission, return to OpenBridge and check again."
            ], destination: .systemCheck, actionTitle: "Review System Check"),
            MainHelpTopic(title: "Recover text that did not paste", symbol: "keyboard", summary: "Recognized text can still be available when insertion needs attention.", details: [
                "Check recent text or History before repeating a dictation. A saved transcript and a successful paste are separate outcomes.",
                "Copy the text you need, place the cursor in the intended app, and paste once. Check the destination before sending or submitting.",
                "If Accessibility needs attention, reopen OpenBridge from Applications and run System Check."
            ], destination: .history, actionTitle: "Open History"),
            MainHelpTopic(title: "Meetings, playback & recovery", symbol: "calendar", summary: "Find a recording, read the Original, and return to a cited passage.", details: [
                "Meetings contains saved recordings. Select one for playback, Original and Cleaned transcripts, and export.",
                "Citations point to the Original transcript. Cleanup keeps the Original available.",
                "If a recording was interrupted, use its available recovery action in Meetings. Keep the recording until recovery finishes."
            ], destination: .meetings, actionTitle: "Open Meetings"),
            MainHelpTopic(title: "Transcribe a file or YouTube video", symbol: "doc.text", summary: "Give a recording a useful second life.", details: [
                "File transcription uses a local speech model and does not need microphone permission.",
                "Transcribe shows the current result. Copy the text or save it before starting another file; it is not a persistent media library.",
                "The shared Dictionary applies to file transcription too."
            ], destination: .transcribe, actionTitle: "Open Transcribe"),
            MainHelpTopic(title: "Local AI & optional cloud", symbol: "lock.shield", summary: "Know which part stays on your Mac and which choice sends text.", details: [
                "Local recording and transcription stay on this Mac. Local cleanup is separate from optional cloud Research.",
                "Cloud cleanup sends transcript text. Research sends the question and authorized transcript excerpts to the configured provider.",
                "Each meeting keeps its own access and retention choices. Voice typing history has a separate policy."
            ], destination: .settings, actionTitle: "Open Settings"),
            MainHelpTopic(title: "Models & cleanup", symbol: "waveform", summary: appState.selectedModelRuntimeStatusSummary, details: [
                "\(appState.selectedModelDisplayName) is the selected voice typing speech model.",
                appState.localCleanupStatusSummary,
                "Finish the active recording or transcription before switching models."
            ], destination: .models, actionTitle: "Review Models & performance")
        ]
    }

    private var matchingTopics: [MainHelpTopic] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? topics : topics.filter {
            ([$0.title, $0.summary] + $0.details).joined(separator: " ").localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        MainPageScaffold {
            MainPageHeader(title: "A little help, right here.", subtitle: "Clear answers for setup, recording, and getting your words where they belong.", statusText: "Local guidance", statusTint: OpenBridgeTheme.brandTeal)
            TextField("Search help topics", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(OpenBridgeTypography.control)
                .accessibilityLabel("Search help topics")
            if matchingTopics.isEmpty {
                MainEmptyState(systemImage: "magnifyingglass", title: "No matching topics", subtitle: "Try paste, permissions, cleanup, or privacy.")
                Button("Show all topics") { query = "" }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
            } else {
                ForEach(matchingTopics) { topic in
                    MainInfoCard(topic.title, systemImage: topic.symbol) {
                        Text(topic.summary)
                            .font(OpenBridgeTypography.body)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("Read guidance") {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(topic.details, id: \.self) { detail in
                                    Text(detail)
                                        .font(OpenBridgeTypography.body)
                                        .lineSpacing(6)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Button(topic.actionTitle) { navigate(topic.destination) }
                                    .buttonStyle(OpenBridgeMiniButtonStyle())
                            }
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.top, 12)
                        }
                        .font(OpenBridgeTypography.control)
                    }
                }
            }
            MainInfoCard("Still need a hand?", systemImage: "questionmark.circle") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { supportActions }
                    VStack(alignment: .leading, spacing: 8) { supportActions }
                }
                Divider().padding(.vertical, 8)
                FeedbackSettingsPanel()
            }
        }
    }

    @ViewBuilder private var supportActions: some View {
        Button {
            appState.runSystemCheck()
            navigate(.systemCheck)
        } label: {
            Label(appState.isRunningSystemCheck ? "Checking…" : "Run System Check", systemImage: "checklist")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
        .disabled(appState.isRunningSystemCheck)
        Button { appState.openHelp() } label: {
            Label("Open local help page", systemImage: "book")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }
}

private struct MainHelpTopic: Identifiable {
    let title: String
    let symbol: String
    let summary: String
    let details: [String]
    let destination: MainWindowSection
    let actionTitle: String
    var id: String { title }
}

struct MainHelpTopicCard: View {
    let title: String
    let systemImage: String
    let summary: String
    let details: [String]
    let tint: Color

    var body: some View {
        MainInfoCard(title, systemImage: systemImage) {
            Text(summary)
                .font(OpenBridgeTypography.body(size: 15))
                .foregroundStyle(OpenBridgeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(details, id: \.self) { detail in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 16, height: 16)

                        Text(detail)
                            .font(OpenBridgeTypography.body(size: 13))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

extension SystemCheckState {
    var mainWindowIconName: String {
        switch self {
        case .pass:
            return "checkmark.circle.fill"
        case .warn:
            return "exclamationmark.circle.fill"
        case .fail:
            return "xmark.circle.fill"
        }
    }

    var mainWindowTint: Color {
        switch self {
        case .pass:
            return OpenBridgeTheme.brandGreen
        case .warn:
            return OpenBridgeTheme.brandGold
        case .fail:
            return OpenBridgeTheme.brandCoral
        }
    }
}

enum MainSettingsSection: String, CaseIterable, Identifiable {
    case general, models, cloud, privacy, systemCheck

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models & performance"
        case .cloud: return "Cloud AI"
        case .privacy: return "Privacy & data"
        case .systemCheck: return "System Check"
        }
    }
}

struct MainSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var providerDrafts = ProviderSettingsDrafts()
    let navigate: (MainWindowSection) -> Void
    let initialSection: MainSettingsSection
    @State private var selectedSection: MainSettingsSection

    init(navigate: @escaping (MainWindowSection) -> Void, initialSection: MainSettingsSection = .general) {
        self.navigate = navigate
        self.initialSection = initialSection
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MainWorkflowTabs(options: MainSettingsSection.allCases, selected: selectedSection, title: { $0.title }, select: { selectedSection = $0 })
                .accessibilityLabel("Settings pages")
            Group {
                switch selectedSection {
                case .general:
                    MainGeneralSettingsPage(navigate: navigate)
                case .models:
                    MainModelsPage()
                case .cloud:
                    MainPageScaffold {
                        MainPageHeader(title: "Cloud AI, by choice.", subtitle: "Local transcription works without a provider. Choose cloud AI only for the tools you want.", statusText: "Optional cloud", statusTint: OpenBridgeTheme.brandBlue)
                        ProviderSettingsView(drafts: providerDrafts, braveResearch: appState.braveResearch)
                    }
                case .privacy:
                    MainPrivacySettingsPage(navigate: navigate)
                case .systemCheck:
                    MainSystemCheckPage()
                }
            }
        }
        .font(OpenBridgeTypography.control)
        .onChange(of: initialSection) { _, section in selectedSection = section }
    }
}

private struct MainGeneralSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let navigate: (MainWindowSection) -> Void

    var body: some View {
        MainPageScaffold {
            MainPageHeader(title: "Make yourself at home.", subtitle: "A few preferences for how OpenBridge fits into your day.", statusText: "On your Mac", statusTint: OpenBridgeTheme.brandTeal)
            MainInfoCard("App behavior", systemImage: "gearshape") {
                MainTogglePreferenceRow(title: "Launch at login", subtitle: "Open OpenBridge when you sign in to this Mac.", isOn: Binding(get: { appState.launchAtLogin }, set: { appState.setLaunchAtLogin($0) }))
                Button { openWindow(id: "onboarding") } label: {
                    Label("Review setup guide", systemImage: "checklist")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
            MainInfoCard("Voice typing", systemImage: "waveform") {
                Text("Shortcuts, microphone, spoken formatting, and the explicit Press Enter voice command live together in Voice typing preferences.")
                    .font(OpenBridgeTypography.body)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button { navigate(.dictation) } label: {
                    Label("Open Voice typing preferences", systemImage: "arrow.right")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
            MainInfoCard("About \(AppIdentity.displayName)", systemImage: "info.circle") {
                HStack(spacing: 12) {
                    OpenBridgeBrandMark(size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppIdentity.displayName).font(OpenBridgeTypography.sectionTitle)
                        Text("Local AI, your control.").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk)
                    }
                }
                AppIdentitySettingsPanel()
                Button { navigate(.help) } label: { Label("Help & feedback", systemImage: "questionmark.circle") }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
    }
}

private struct MainPrivacySettingsPage: View {
    @EnvironmentObject private var appState: AppState
    let navigate: (MainWindowSection) -> Void
    @State private var pendingRetentionMode: DictationHistoryRetentionMode?
    @State private var showingNeverStoreConfirmation = false
    @State private var showingClearHistoryConfirmation = false
    @State private var showingHistoryDetails = false

    var body: some View {
        MainPageScaffold {
            MainPageHeader(title: "Keep what you need.", subtitle: "Separate choices for brief dictations and lasting conversations.", statusText: "Stored locally", statusTint: OpenBridgeTheme.brandTeal)
            MainInfoCard("Voice typing history", systemImage: "clock.arrow.circlepath") {
                Text("A safety net for recent dictations, including recognized text that did not paste.")
                    .font(OpenBridgeTypography.body)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                DictationHistorySettingsPanel(showingClearHistoryConfirmation: $showingClearHistoryConfirmation, showingHistoryDetails: $showingHistoryDetails, requestHistoryRetentionChange: requestHistoryRetentionChange)
                Button { navigate(.history) } label: { Label("Open History", systemImage: "arrow.right") }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
            }
            MainInfoCard("Meeting retention", systemImage: "calendar") {
                Text("Choose a retention policy when starting each meeting on Home. Every saved meeting keeps its own policy; changing voice typing history does not delete meetings.")
                    .font(OpenBridgeTypography.body)
                    .lineSpacing(5)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { meetingActions }
                    VStack(alignment: .leading, spacing: 8) { meetingActions }
                }
            }
            MainInfoCard("On this Mac", systemImage: "lock.shield") {
                MainFactRow(label: "Saved dictations", value: "\(appState.dictationHistory.count)")
                MainFactRow(label: "Snippets", value: "\(appState.snippets.count)")
                MainFactRow(label: "Shared dictionary", value: "\(appState.customDictionaryEntries.count) entries")
                Text("Dictionary and snippets remain separate from history. Manage meeting recordings in Meetings and speech models in Models & performance.")
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Turn off history storage?", isPresented: $showingNeverStoreConfirmation) {
            Button("Turn off storage", role: .destructive) {
                appState.setHistoryRetentionMode(pendingRetentionMode ?? .neverStore)
                pendingRetentionMode = nil
            }
            Button("Cancel", role: .cancel) { pendingRetentionMode = nil }
        } message: {
            Text("This deletes saved voice typing history from this Mac and stops future dictations from being saved. Meetings, snippets, and dictionary entries are kept.")
        }
        .alert("Clear all voice typing history?", isPresented: $showingClearHistoryConfirmation) {
            Button("Clear history", role: .destructive) { appState.clearDictationHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved dictations from this Mac. Meetings, snippets, and dictionary entries are kept.")
        }
    }

    @ViewBuilder private var meetingActions: some View {
        Button { navigate(.home) } label: { Label("Set up a meeting", systemImage: "mic") }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        Button { navigate(.meetings) } label: { Label("Review saved meetings", systemImage: "arrow.right") }
            .buttonStyle(OpenBridgeMiniButtonStyle())
    }

    private func requestHistoryRetentionChange(_ mode: DictationHistoryRetentionMode) {
        guard mode != appState.historyRetentionMode || appState.historyRetentionNeedsChoice else { return }
        if mode == .neverStore {
            pendingRetentionMode = mode
            showingNeverStoreConfirmation = true
        } else {
            appState.setHistoryRetentionMode(mode)
        }
    }
}
