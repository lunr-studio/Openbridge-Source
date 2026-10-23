import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBridgeUI

struct MainNavigationTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.brandBlue)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenBridgeTheme.coolSurface.opacity(0.38))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OpenBridgeTheme.border.opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct MainRecentActivityPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Latest transcript", systemImage: "doc.text") {
            if let latestActivity {
                switch latestActivity {
                case .media(let mediaResult):
                    MainMediaTranscriptionResultSummary(result: mediaResult)
                case .history(let latest):
                    MainFactRow(label: "Last dictation", value: latest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text(latest.transcript)
                        .font(OpenBridgeTypography.body(size: 16))
                        .lineLimit(3)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            appState.copyHistoryEntry(latest)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())

                        Button {
                            appState.repasteHistoryEntry(latest)
                        } label: {
                            Label("Paste", systemImage: "arrow.turn.down.right")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    }
                case .transcript(let text, let createdAt):
                    MainLastTranscriptSummary(transcript: text, createdAt: createdAt)
                }
            } else {
                MainEmptyState(
                    systemImage: "clock",
                    title: "No local activity yet",
                    subtitle: "Start dictation or transcribe a file and the latest local result will appear here."
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var latestActivity: MainRecentActivity? {
        var latestDatedActivity: (date: Date, activity: MainRecentActivity)?

        if let mediaResult = appState.mediaTranscriptionResult {
            latestDatedActivity = (mediaResult.createdAt, .media(mediaResult))
        }

        if let historyEntry = appState.dictationHistory.first,
           historyEntry.createdAt > (latestDatedActivity?.date ?? .distantPast) {
            latestDatedActivity = (historyEntry.createdAt, .history(historyEntry))
        }

        let transcript = appState.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return latestDatedActivity?.activity
        }

        guard let transcriptCreatedAt = appState.lastTranscriptCreatedAt else {
            return latestDatedActivity?.activity ?? .transcript(text: appState.lastTranscript, createdAt: nil)
        }

        if transcriptCreatedAt > (latestDatedActivity?.date ?? .distantPast) {
            latestDatedActivity = (transcriptCreatedAt, .transcript(text: appState.lastTranscript, createdAt: transcriptCreatedAt))
        }

        return latestDatedActivity?.activity
    }
}

enum MainRecentActivity {
    case media(MediaTranscriptionResult)
    case history(DictationHistoryEntry)
    case transcript(text: String, createdAt: Date?)
}

struct MainMediaTranscriptionResultSummary: View {
    @EnvironmentObject private var appState: AppState

    let result: MediaTranscriptionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MainFactRow(label: "Media", value: result.sourceName)
            MainFactRow(label: "Created", value: result.createdAt.formatted(date: .abbreviated, time: .shortened))

            if !result.modelLabel.isEmpty {
                MainFactRow(label: "Model", value: result.modelLabel)
            }

            Text(result.transcript)
                .font(OpenBridgeTypography.body(size: 16))
                .lineLimit(5)
                .foregroundStyle(OpenBridgeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    appState.copyMediaTranscriptionResult()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Button {
                    appState.saveMediaTranscriptionResult()
                } label: {
                    Label("Save As", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Latest media transcript")
    }
}

struct MainPageScaffold<Content: View>: View {
    @EnvironmentObject private var appState: AppState

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MainRuntimeStateBanner(state: MainRuntimeState.current(for: appState))

                content
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OpenBridgeTheme.card)
    }
}

struct MainRuntimeState {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    @MainActor
    static func current(for appState: AppState) -> MainRuntimeState? {
        if appState.isInstallingModel {
            return MainRuntimeState(
                title: "Installing model",
                message: appState.maintenanceStatus ?? appState.statusMessage,
                systemImage: "arrow.down.circle",
                tint: OpenBridgeTheme.brandBlue
            )
        }

        if appState.isRunningSystemCheck {
            return MainRuntimeState(
                title: "Running System Check",
                message: appState.maintenanceStatus ?? appState.statusMessage,
                systemImage: "arrow.clockwise",
                tint: OpenBridgeTheme.brandBlue
            )
        }

        if appState.isTranscribingMedia {
            return MainRuntimeState(
                title: "Transcribing media",
                message: appState.foregroundStatus ?? appState.statusMessage,
                systemImage: "waveform",
                tint: OpenBridgeTheme.brandBlue
            )
        }

        if appState.isTranscribing {
            return MainRuntimeState(
                title: "Processing dictation",
                message: appState.foregroundStatus ?? appState.statusMessage,
                systemImage: "text.bubble",
                tint: OpenBridgeTheme.brandBlue
            )
        }

        if appState.isStartingRecording || appState.isRecording {
            return MainRuntimeState(
                title: "Listening",
                message: appState.foregroundStatus ?? appState.statusMessage,
                systemImage: "mic.fill",
                tint: OpenBridgeTheme.brandTeal
            )
        }

        let normalizedMessage = appState.statusMessage.lowercased()
        if normalizedMessage.hasPrefix("loading") {
            return MainRuntimeState(
                title: "Loading",
                message: appState.statusMessage,
                systemImage: "hourglass",
                tint: OpenBridgeTheme.brandBlue
            )
        }

        if normalizedMessage.contains("failed")
            || normalizedMessage.contains("could not")
            || normalizedMessage.contains("error") {
            return MainRuntimeState(
                title: "Needs attention",
                message: appState.statusMessage,
                systemImage: "exclamationmark.triangle",
                tint: OpenBridgeTheme.brandCoral
            )
        }

        return nil
    }
}

struct MainRuntimeStateBanner: View {
    let state: MainRuntimeState?

    var body: some View {
        if let state {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.systemImage)
                    .font(OpenBridgeTypography.heading(size: 20, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.ink)

                    Text(state.message)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(state.tint.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(state.tint.opacity(0.24), lineWidth: 1)
            }
        }
    }
}

struct MainHeroPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let statusText: String
    let statusTint: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        statusText: String,
        statusTint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusTint = statusTint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MainPageHeader(
                title: title,
                subtitle: subtitle,
                statusText: statusText,
                statusTint: statusTint
            )

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenBridgeTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OpenBridgeTheme.border, lineWidth: 1))
    }
}

struct MainPageHeader: View {
    let title: String
    let subtitle: String
    let statusText: String
    let statusTint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(OpenBridgeTypography.pageTitle)
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(subtitle)
                    .font(OpenBridgeTypography.body(size: 16))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if !statusText.isEmpty {
                OpenBridgeStatusPill(text: statusText, tint: statusTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MainTwoColumnGrid<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: MainGridColumns.two, alignment: .leading, spacing: 24) {
            content
        }
    }
}

enum MainGridColumns {
    static let two = [
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
    ]
    static let adaptiveModeCards = [
        GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top),
    ]
}

struct MainInfoCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(OpenBridgeTypography.heading(size: 20, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.card.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.9), lineWidth: 1)
        }
    }
}

struct MainSmallCard: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.brandBlue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .lineLimit(1)

                Text(subtitle)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.card.opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.82), lineWidth: 1)
        }
    }
}

struct MainPlaceholderPanel: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.forward.circle")
                .font(OpenBridgeTypography.heading(size: 18, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.brandTeal)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(subtitle)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.brandTeal.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OpenBridgeTheme.brandTeal.opacity(0.26), lineWidth: 1)
        }
    }
}

struct MainFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .frame(width: 112, alignment: .leading)

            Text(value)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.ink)
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }
}

struct MainLastTranscriptSummary: View {
    let transcript: String
    let createdAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MainFactRow(
                label: "Last transcript",
                value: createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "This session"
            )

            Text(transcript)
                .font(OpenBridgeTypography.body(size: 16))
                .lineLimit(3)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainMetricRow: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(OpenBridgeTypography.heading(size: 30, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)

            Text(label)
                .font(OpenBridgeTypography.body(size: 13, weight: .medium))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
        }
    }
}

struct MainEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(OpenBridgeTypography.heading(size: 18, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.brandBlue)

            Text(title)
                .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.ink)

            Text(subtitle)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.36))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.78), lineWidth: 1)
        }
    }
}

enum MainLocalDataExport {
    static func historyText(_ entries: [DictationHistoryEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = [
            "Openbridge dictation history",
            "Exported: \(formatter.string(from: Date()))",
            "Entries: \(entries.count)",
        ].joined(separator: "\n")

        guard !entries.isEmpty else {
            return "\(header)\n\nNo entries exported.\n"
        }

        let blocks = entries.map { entry in
            var lines = [
                "Date: \(formatter.string(from: entry.createdAt))",
                "Model: \(entry.modelLabel ?? entry.modelIdentifier)",
            ]

            if let sourceApplication = entry.sourceApplication, !sourceApplication.isEmpty {
                lines.append("Source app: \(sourceApplication)")
            }

            if let durationSeconds = entry.durationSeconds {
                lines.append("Duration: \(durationLabel(durationSeconds))")
            }

            lines.append("")
            lines.append(entry.transcript)
            return lines.joined(separator: "\n")
        }

        return "\(header)\n\n\(blocks.joined(separator: "\n\n---\n\n"))\n"
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let roundedSeconds = max(0, Int(seconds.rounded()))
        if roundedSeconds < 60 {
            return "\(roundedSeconds)s"
        }

        let minutes = roundedSeconds / 60
        let remainingSeconds = roundedSeconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

extension JSONEncoder {
    static var openBridgePretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
