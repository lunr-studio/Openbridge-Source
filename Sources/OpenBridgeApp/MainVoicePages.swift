import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBridgeUI

struct MainTransformsPage: View {
    @EnvironmentObject private var appState: AppState

    private var canRunTransform: Bool {
        appState.readyForDictation
            && !appState.isRecording
            && !appState.isTranscribing
            && !appState.isStartingRecording
            && !appState.isTranscribingMedia
            // Wave-23 (3840150569): a running post-Stop cleanup occupies the
            // same local Gemma engine - transforms wait for it to finish.
            && appState.postStopCleanupTask == nil
    }

    private var transformUnavailableMessage: String {
        if appState.isTranscribingMedia {
            return "Finish the current file or YouTube transcription before running a text action."
        }
        if appState.isRecording || appState.isTranscribing || appState.isStartingRecording {
            return "Finish the current OpenBridge task before running a text action."
        }
        return appState.commandModeSetupMessage
    }

    private var statusText: String {
        if appState.isCommandModeRecording {
            return "Listening"
        }
        if appState.isTranscribing || appState.isTranscribingMedia {
            return "Working"
        }
        return appState.readyForDictation ? "Built-ins" : "Needs setup"
    }

    private var statusTint: Color {
        if appState.isCommandModeRecording || appState.isTranscribing || appState.isTranscribingMedia {
            return OpenBridgeTheme.brandBlue
        }
        return appState.readyForDictation ? OpenBridgeTheme.brandTeal : OpenBridgeTheme.brandCoral
    }

    var body: some View {
        MainPageScaffold {
            MainPageHeader(
                title: "Say it a little better.",
                subtitle: "Text actions rewrite selected text in any app. No dictation required.",
                statusText: statusText,
                statusTint: statusTint
            )

            MainTransformWorkflowPanel(
                canRunTransform: canRunTransform,
                unavailableMessage: transformUnavailableMessage
            )

            MainTransformsCatalog(
                canRunTransform: canRunTransform,
                unavailableMessage: transformUnavailableMessage
            )

            MainTwoColumnGrid {
                MainTransformLocalExecutionCard()

                MainTransformCustomStateCard()
            }
        }
    }
}

struct MainTransformWorkflowPanel: View {
    let canRunTransform: Bool
    let unavailableMessage: String

    var body: some View {
        MainInfoCard("Select. Rewrite. Keep your flow.", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                Text(canRunTransform ? "Select text in another app, then choose a text action below." : unavailableMessage)
                    .font(OpenBridgeTypography.body)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: MainGridColumns.two, alignment: .leading, spacing: 8) {
                    MainTransformWorkflowStep(
                        number: "1",
                        title: "Select text",
                        subtitle: "Highlight text in the app where you are working."
                    )

                    MainTransformWorkflowStep(
                        number: "2",
                        title: "Choose a text action",
                        subtitle: "OpenBridge reads the selection and applies the local preset."
                    )

                    MainTransformWorkflowStep(
                        number: "3",
                        title: "Review result",
                        subtitle: "The replacement is pasted back, or left on the clipboard if paste is blocked."
                    )

                    MainTransformWorkflowStep(
                        number: "4",
                        title: "Undo if needed",
                        subtitle: "Use the target app's Undo command to revert the replacement."
                    )
                }
            }
        }
    }
}

struct MainTransformWorkflowStep: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(OpenBridgeTypography.body(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background {
                    Circle()
                        .fill(OpenBridgeTheme.brandBlue)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.44))
        }
    }
}

struct MainTransformsCatalog: View {
    @EnvironmentObject private var appState: AppState
    let canRunTransform: Bool
    let unavailableMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Label("Text actions", systemImage: "wand.and.stars")
                    .font(OpenBridgeTypography.heading(size: 20))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Spacer(minLength: 8)

                OpenBridgeStatusPill(text: "\(appState.commandModePresets.count) local presets", tint: OpenBridgeTheme.brandTeal)
            }

            LazyVGrid(columns: MainGridColumns.adaptiveModeCards, alignment: .leading, spacing: 10) {
                ForEach(Array(appState.commandModePresets.enumerated()), id: \.element.id) { index, preset in
                    MainTransformPresetCard(
                        preset: preset,
                        isCoreV2Transform: index < 4,
                        canRunTransform: canRunTransform,
                        unavailableMessage: unavailableMessage
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MainTransformPresetCard: View {
    @EnvironmentObject private var appState: AppState
    let preset: CommandModePreset
    let isCoreV2Transform: Bool
    let canRunTransform: Bool
    let unavailableMessage: String

    private var example: MainTransformExample {
        MainTransformExample.example(for: preset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: preset.systemImage)
                    .font(OpenBridgeTypography.body(size: 16, weight: .semibold))
                    .foregroundStyle(isCoreV2Transform ? OpenBridgeTheme.brandBlue : OpenBridgeTheme.brandTeal)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(preset.title)
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                            .foregroundStyle(OpenBridgeTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        OpenBridgeStatusPill(
                            text: "On your Mac",
                            tint: isCoreV2Transform ? OpenBridgeTheme.brandBlue : OpenBridgeTheme.brandTeal
                        )
                    }

                    Text(preset.summary)
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            MainTransformExampleView(example: example)

            Button {
                Task { await appState.runCommandModePreset(preset) }
            } label: {
                Label("Run text action", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: canRunTransform && isCoreV2Transform))
            .disabled(!canRunTransform)
            .help(canRunTransform ? "Run \(preset.title) on selected text" : unavailableMessage)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 238, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenBridgeTheme.card.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.88), lineWidth: 1)
        }
    }
}

struct MainTransformExample {
    let before: String
    let after: String

    static func example(for preset: CommandModePreset) -> MainTransformExample {
        switch preset.id {
        case "clean-text":
            return MainTransformExample(
                before: "patient says um the pain is worse comma new paragraph",
                after: "The pain is worse."
            )
        case "polish-message":
            return MainTransformExample(
                before: "i can send it over later today if that works",
                after: "I can send this over later today if that works for you."
            )
        case "format-notes":
            return MainTransformExample(
                before: "follow up labs next week call if symptoms worsen",
                after: "Plan: follow up labs next week; call if symptoms worsen."
            )
        case "code-comment-cleanup":
            return MainTransformExample(
                before: "todo this helper is confusing and returns nil sometimes",
                after: "TODO: clarify when this helper can return nil."
            )
        case "concise":
            return MainTransformExample(
                before: "I wanted to check in because there are a few things we should discuss.",
                after: "A few things need discussion."
            )
        case "professional":
            return MainTransformExample(
                before: "can you get this done soon",
                after: "Could you complete this as soon as practical?"
            )
        case "friendly":
            return MainTransformExample(
                before: "Send me the update today.",
                after: "Could you send me the update today when you get a chance?"
            )
        case "translate":
            return MainTransformExample(
                before: "Merci, je vous envoie le document demain.",
                after: "Thank you, I will send you the document tomorrow."
            )
        case "summarize":
            return MainTransformExample(
                before: "Long note with background, decision, and next steps.",
                after: "Decision and next steps."
            )
        case "outline":
            return MainTransformExample(
                before: "We need onboarding, testing, and release notes.",
                after: "1. Onboarding\n2. Testing\n3. Release notes"
            )
        case "grammar":
            return MainTransformExample(
                before: "this dont read clean and need fixing",
                after: "This does not read clearly and needs fixing."
            )
        default:
            return MainTransformExample(
                before: "Rough dictated text",
                after: "Clear replacement text"
            )
        }
    }
}

struct MainTransformExampleView: View {
    let example: MainTransformExample

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MainTransformExampleRow(label: "Before", text: example.before)
            MainTransformExampleRow(label: "After", text: example.after)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OpenBridgeTheme.coolSurface.opacity(0.38))
        }
    }
}

struct MainTransformExampleRow: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .frame(width: 42, alignment: .leading)

            Text(text)
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(label == "After" ? OpenBridgeTheme.ink : OpenBridgeTheme.mutedInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainTransformLocalExecutionCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MainInfoCard("Local execution", systemImage: "lock") {
            MainFactRow(label: "Processing", value: "On your Mac")
            MainFactRow(label: "Input", value: "Selected text from the active app")
            MainFactRow(label: "Output", value: "Replace selection or keep replacement on clipboard")
            MainFactRow(label: "Cleanup", value: appState.transcriptionCleanupMode.title)

            Text("Your result stays available as the latest text, ready to copy or paste again from Home.")
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainTransformCustomStateCard: View {
    var body: some View {
        MainInfoCard("Custom text actions", systemImage: "slider.horizontal.3") {
            HStack {
                OpenBridgeStatusPill(text: "Built-ins only", tint: OpenBridgeTheme.brandGold)
                Spacer(minLength: 0)
            }

            Text("Choose a ready-made action above, or select text in any app and use your spoken text action shortcut to give your own instruction.")
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Text("Saved custom actions are not available yet. Your selected text is rewritten locally on this Mac.")
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MainHistoryPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var drafts: MainVoiceTypingDrafts

    private var searchText: String {
        get { drafts.historySearchText }
        nonmutating set { drafts.historySearchText = newValue }
    }
    @State private var retentionModePendingDelete: DictationHistoryRetentionMode?
    @State private var showingNeverStoreConfirmation = false
    @State private var showingClearHistoryConfirmation = false

    private var filteredHistory: [DictationHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return appState.dictationHistory
        }

        return appState.dictationHistory.filter { entry in
            entry.transcript.localizedCaseInsensitiveContains(query)
                || (entry.sourceApplication?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.modelLabel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        MainPageScaffold {
            MainPageHeader(
                title: "Your words, within reach.",
                subtitle: appState.historyRetentionSummary,
                statusText: appState.historyRetentionNeedsChoice ? "Choose" : appState.historyRetentionMode.title,
                statusTint: appState.historyRetentionNeedsChoice ? OpenBridgeTheme.brandGold : OpenBridgeTheme.brandTeal
            )

            MainTwoColumnGrid {
                MainInfoCard("Local storage", systemImage: "lock") {
                    MainMetricRow(value: "\(appState.dictationHistory.count)", label: "saved entries")
                    MainFactRow(label: "Retention", value: appState.historyRetentionMode.title)
                    DisclosureGroup("Storage details") {
                        MainFactRow(label: "File", value: appState.dictationHistoryFileLocation)
                    }
                    .font(OpenBridgeTypography.metadata)

                    Text("Voice typing history stays on this Mac. Its retention policy is separate from each meeting’s retention settings.")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MainInfoCard("Privacy controls", systemImage: "shield") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Retention")
                            .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                            .foregroundStyle(OpenBridgeTheme.mutedInk)

                        Picker("Retention", selection: Binding(
                            get: { appState.historyRetentionMode },
                            set: { requestRetentionChange($0) }
                        )) {
                            ForEach(DictationHistoryRetentionMode.privacyFirstOptions) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    Text(appState.historyRetentionMode.summary)
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        showingClearHistoryConfirmation = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .disabled(appState.dictationHistory.isEmpty)
                }
            }

            MainInfoCard("Saved dictations", systemImage: "clock.arrow.circlepath") {
                let visibleHistory = filteredHistory

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        TextField("Search transcript, app, or model", text: $drafts.historySearchText)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            exportHistory(visibleHistory)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                        .disabled(visibleHistory.isEmpty)
                    }

                    if visibleHistory.isEmpty {
                        MainEmptyState(
                            systemImage: "clock",
                            title: appState.dictationHistory.isEmpty ? "No retained dictations yet" : "No history matches that search",
                            subtitle: appState.dictationHistory.isEmpty
                                ? "Successful dictations will appear here when history storage is enabled."
                                : "Try a shorter word, app name, or model label."
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleHistory.enumerated()), id: \.element.id) { index, entry in
                                MainHistoryEntryRow(entry: entry)

                                if index < visibleHistory.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert("Turn off history storage?", isPresented: $showingNeverStoreConfirmation) {
            Button("Turn Off and Delete", role: .destructive) {
                appState.setHistoryRetentionMode(retentionModePendingDelete ?? .neverStore)
                retentionModePendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                retentionModePendingDelete = nil
            }
        } message: {
            Text("OpenBridge will delete saved dictations from this Mac and stop storing new history.")
        }
        .alert("Clear dictation history?", isPresented: $showingClearHistoryConfirmation) {
            Button("Clear History", role: .destructive) {
                appState.clearDictationHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved dictation history entry from this Mac.")
        }
    }

    private func requestRetentionChange(_ mode: DictationHistoryRetentionMode) {
        guard mode == .neverStore, !appState.dictationHistory.isEmpty else {
            appState.setHistoryRetentionMode(mode)
            return
        }

        retentionModePendingDelete = mode
        showingNeverStoreConfirmation = true
    }

    private func exportHistory(_ entries: [DictationHistoryEntry]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "OpenBridge history.txt"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try MainLocalDataExport.historyText(entries).write(to: url, atomically: true, encoding: .utf8)
            appState.statusMessage = "Exported dictation history to \(url.lastPathComponent)."
        } catch {
            appState.statusMessage = "History export failed: \(error.localizedDescription)"
        }
    }
}

struct MainHistoryEntryRow: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingDeleteConfirmation = false

    let entry: DictationHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)

                Text(metadataText)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            Text(entry.transcript)
                .font(OpenBridgeTypography.body)
                .lineSpacing(8)
                .textSelection(.enabled)
                .foregroundStyle(OpenBridgeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    appState.copyHistoryEntry(entry)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Button {
                    appState.repasteHistoryEntry(entry)
                } label: {
                    Label("Paste", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Spacer()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
        .padding(.vertical, 12)
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
        var parts: [String] = []
        if let sourceApplication = entry.sourceApplication, !sourceApplication.isEmpty {
            parts.append(sourceApplication)
        }
        let rawModelName = entry.modelLabel?.isEmpty == false ? entry.modelLabel! : entry.modelIdentifier
        parts.append(modelDisplayName(rawModelName))
        if let durationSeconds = entry.durationSeconds {
            parts.append(MainLocalDataExport.durationLabel(durationSeconds))
        }
        return parts.joined(separator: " / ")
    }

    private func modelDisplayName(_ rawValue: String) -> String {
        guard rawValue.contains("/") else {
            return rawValue
        }

        return URL(fileURLWithPath: rawValue).lastPathComponent
    }
}

struct MainSnippetsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var drafts: MainVoiceTypingDrafts

    private var searchText: String {
        get { drafts.snippetSearchText }
        nonmutating set { drafts.snippetSearchText = newValue }
    }
    private var triggerPhrase: String {
        get { drafts.snippetTriggerPhrase }
        nonmutating set { drafts.snippetTriggerPhrase = newValue }
    }
    private var expansionText: String {
        get { drafts.snippetExpansionText }
        nonmutating set { drafts.snippetExpansionText = newValue }
    }
    private var editingSnippet: Snippet? {
        get { drafts.editingSnippet }
        nonmutating set { drafts.editingSnippet = newValue }
    }
    private var formMessage: String? {
        get { drafts.snippetFormMessage }
        nonmutating set { drafts.snippetFormMessage = newValue }
    }
    private var testPhrase: String {
        get { drafts.snippetTestPhrase }
        nonmutating set { drafts.snippetTestPhrase = newValue }
    }
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
        MainPageScaffold {
            MainPageHeader(
                title: "A few words. A whole thought.",
                subtitle: "Say a short phrase. Let OpenBridge fill in the words you use often.",
                statusText: appState.snippets.isEmpty ? "Empty" : "\(appState.snippets.count) saved",
                statusTint: appState.snippets.isEmpty ? OpenBridgeTheme.brandGold : OpenBridgeTheme.brandTeal
            )

            MainTwoColumnGrid {
                MainInfoCard(editingSnippet == nil ? "Create snippet" : "Edit snippet", systemImage: "text.badge.plus") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Trigger phrase")
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        TextField("For example, my sign off", text: $drafts.snippetTriggerPhrase)
                            .textFieldStyle(.roundedBorder)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Expansion text")
                                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)

                            TextEditor(text: $drafts.snippetExpansionText)
                                .font(OpenBridgeTypography.body)
                                .frame(minHeight: 132)
                                .scrollContentBackground(.hidden)
                                .background(OpenBridgeTheme.card.opacity(0.92))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(OpenBridgeTheme.border.opacity(0.86), lineWidth: 1)
                                }
                        }

                        if let formMessage {
                            Text(formMessage)
                                .font(OpenBridgeTypography.metadata)
                                .foregroundStyle(OpenBridgeTheme.brandCoral)
                        }

                        HStack(spacing: 8) {
                            Button {
                                saveSnippet()
                            } label: {
                                Label(editingSnippet == nil ? "Add Snippet" : "Update Snippet", systemImage: editingSnippet == nil ? "plus" : "checkmark")
                            }
                            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                            .disabled(!canSaveSnippet)

                            if editingSnippet != nil {
                                Button {
                                    resetSnippetForm()
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle())
                            }
                        }
                    }
                }

                MainInfoCard("Test snippet", systemImage: "sparkles") {
                    MainMetricRow(value: "\(appState.snippets.count)", label: "local snippets")

                    TextField("Trigger phrase to test", text: $drafts.snippetTestPhrase)
                        .textFieldStyle(.roundedBorder)

                    if let matchedTestSnippet {
                        MainFactRow(label: "Match", value: matchedTestSnippet.triggerPhrase)

                        Text(matchedTestSnippet.expansionText)
                            .font(OpenBridgeTypography.body)
                            .foregroundStyle(OpenBridgeTheme.ink)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            copyTestSnippetResult(matchedTestSnippet)
                        } label: {
                            Label("Copy Test Result", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    } else {
                        Text(testPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Enter a saved trigger phrase to preview its expansion."
                            : "No saved snippet matches that trigger.")
                            .font(OpenBridgeTypography.metadata)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        exportSnippets()
                    } label: {
                        Label("Export JSON", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .disabled(appState.snippets.isEmpty)
                }
            }

            MainInfoCard("Saved snippets", systemImage: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search trigger or expansion", text: $drafts.snippetSearchText)
                        .textFieldStyle(.roundedBorder)

                    if filteredSnippets.isEmpty {
                        MainEmptyState(
                            systemImage: "text.badge.plus",
                            title: appState.snippets.isEmpty ? "No snippets saved yet" : "No snippets match that search",
                            subtitle: appState.snippets.isEmpty
                                ? "Create a local trigger and expansion to speed up repeated phrases."
                                : "Try a shorter trigger or phrase from the expansion."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                                MainSnippetEntryRow(
                                    snippet: snippet,
                                    editAction: { beginEditing(snippet) },
                                    copyAction: { copySnippetExpansion(snippet) },
                                    deleteAction: { requestDelete(snippet) }
                                )

                                if index < filteredSnippets.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
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
            Text("This removes the trigger and expansion from this Mac.")
        }
    }

    private var canSaveSnippet: Bool {
        !triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expansionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchedTestSnippet: Snippet? {
        let normalizedTestPhrase = normalizedSnippetTrigger(testPhrase)
        guard !normalizedTestPhrase.isEmpty else {
            return nil
        }

        return appState.snippets.first { snippet in
            normalizedSnippetTrigger(snippet.triggerPhrase) == normalizedTestPhrase
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
            resetSnippetForm()
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

    private func copySnippetExpansion(_ snippet: Snippet) {
        PasteboardService.copy(snippet.expansionText)
        appState.statusMessage = "Copied snippet expansion."
    }

    private func copyTestSnippetResult(_ snippet: Snippet) {
        PasteboardService.copy(snippet.expansionText)
        appState.statusMessage = "Copied test snippet result."
    }

    private func requestDelete(_ snippet: Snippet) {
        pendingDeleteSnippet = snippet
        showingDeleteConfirmation = true
    }

    private func resetSnippetForm() {
        editingSnippet = nil
        triggerPhrase = ""
        expansionText = ""
        formMessage = nil
    }

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "OpenBridge snippets.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try JSONEncoder.openBridgePretty.encode(appState.snippets)
            try data.write(to: url, options: .atomic)
            appState.statusMessage = "Exported snippets to \(url.lastPathComponent)."
        } catch {
            appState.statusMessage = "Snippet export failed: \(error.localizedDescription)"
        }
    }

    private func normalizedSnippetTrigger(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let allowedCharacters = CharacterSet.alphanumerics
        let tokenized = folded.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? String(scalar) : " "
        }.joined()

        return tokenized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct MainSnippetEntryRow: View {
    let snippet: Snippet
    let editAction: () -> Void
    let copyAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snippet.triggerPhrase)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("updated \(snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            Text(snippet.expansionText)
                .font(OpenBridgeTypography.body)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: copyAction) {
                    Label("Copy Expansion", systemImage: "doc.on.doc")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Button(action: editAction) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())

                Spacer()

                Button(role: .destructive, action: deleteAction) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
        .padding(.vertical, 12)
    }
}

struct MainDictionaryPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var drafts: MainVoiceTypingDrafts

    private var searchText: String {
        get { drafts.dictionarySearchText }
        nonmutating set { drafts.dictionarySearchText = newValue }
    }
    private var heardAs: String {
        get { drafts.dictionaryHeardAs }
        nonmutating set { drafts.dictionaryHeardAs = newValue }
    }
    private var replaceWith: String {
        get { drafts.dictionaryReplaceWith }
        nonmutating set { drafts.dictionaryReplaceWith = newValue }
    }
    private var editingEntry: CustomDictionaryEntry? {
        get { drafts.editingDictionaryEntry }
        nonmutating set { drafts.editingDictionaryEntry = newValue }
    }
    private var formMessage: String? {
        get { drafts.dictionaryFormMessage }
        nonmutating set { drafts.dictionaryFormMessage = newValue }
    }
    @State private var pendingDeleteEntry: CustomDictionaryEntry?
    @State private var showingDeleteConfirmation = false
    @State private var showingDictionaryImporter = false

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

    var body: some View {
        MainPageScaffold {
            MainPageHeader(
                title: "The right words, every time.",
                subtitle: "Shared across OpenBridge: voice typing, meetings, and file transcription.",
                statusText: appState.vocabularyCorrectionsEnabled ? "On" : "Off",
                statusTint: appState.vocabularyCorrectionsEnabled ? OpenBridgeTheme.brandTeal : OpenBridgeTheme.brandGold
            )

            MainTwoColumnGrid {
                MainInfoCard("Vocabulary", systemImage: "book") {
                    MainTogglePreferenceRow(
                        title: "Use custom dictionary",
                        subtitle: "Use these names and terms across OpenBridge, including meetings and files.",
                        isOn: Binding(
                            get: { appState.vocabularyCorrectionsEnabled },
                            set: { appState.setVocabularyCorrectionsEnabled($0) }
                        )
                    )

                    MainMetricRow(value: "\(appState.customDictionaryEntries.count)", label: "saved entries")
                    DisclosureGroup("Storage details") {
                        MainFactRow(label: "File", value: appState.customDictionaryFileLocation)
                    }
                    .font(OpenBridgeTypography.metadata)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            dictionaryDataActions
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            dictionaryDataActions
                        }
                    }
                }

                MainInfoCard(editingEntry == nil ? "Add entry" : "Edit entry", systemImage: "text.book.closed") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("When OpenBridge hears")
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        TextField("Phrase to recognize", text: $drafts.dictionaryHeardAs)
                            .textFieldStyle(.roundedBorder)

                        Text("Replace with")
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                        TextField("Preferred spelling", text: $drafts.dictionaryReplaceWith)
                            .textFieldStyle(.roundedBorder)

                        if let validationMessage {
                            Text(validationMessage)
                                .font(OpenBridgeTypography.metadata)
                                .foregroundStyle(OpenBridgeTheme.brandCoral)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 8) {
                            Button {
                                saveDictionaryEntry()
                            } label: {
                                Label(editingEntry == nil ? "Add Entry" : "Update Entry", systemImage: editingEntry == nil ? "plus" : "checkmark")
                            }
                            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                            .disabled(!canSaveDictionaryEntry)

                            if editingEntry != nil {
                                Button {
                                    resetDictionaryForm()
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                                .buttonStyle(OpenBridgeMiniButtonStyle())
                            }
                        }

                        Text("Example: hear `trishan panch`, replace with `Trishan Panch`.")
                            .font(OpenBridgeTypography.metadata)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            MainInfoCard("Saved entries", systemImage: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search phrase or replacement", text: $drafts.dictionarySearchText)
                        .textFieldStyle(.roundedBorder)

                    if filteredEntries.isEmpty {
                        MainEmptyState(
                            systemImage: "book",
                            title: appState.customDictionaryEntries.isEmpty ? "No dictionary entries yet" : "No entries match that search",
                            subtitle: appState.customDictionaryEntries.isEmpty
                                ? "Add names, terms, and corrections OpenBridge should preserve locally."
                                : "Try a shorter phrase or replacement."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                MainDictionaryEntryRow(
                                    entry: entry,
                                    editAction: { beginEditing(entry) },
                                    deleteAction: { requestDelete(entry) }
                                )

                                if index < filteredEntries.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingDictionaryImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importDictionary
        )
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

    @ViewBuilder
    private var dictionaryDataActions: some View {
        Button {
            exportDictionary()
        } label: {
            Label("Export JSON", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
        .disabled(appState.customDictionaryEntries.isEmpty)

        Button {
            showingDictionaryImporter = true
        } label: {
            Label("Import JSON", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())

        Button {
            PasteboardService.copy(appState.customDictionaryFileLocation)
            appState.statusMessage = "Copied dictionary storage path."
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        .buttonStyle(OpenBridgeMiniButtonStyle())
    }

    private var trimmedHeardAs: String {
        heardAs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplaceWith: String {
        replaceWith.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicateDictionaryEntryExists: Bool {
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
                return "Enter the phrase OpenBridge hears."
            }
            if trimmedReplaceWith.isEmpty {
                return "Enter the replacement text."
            }
        }
        if duplicateDictionaryEntryExists {
            return "A custom dictionary entry already exists for that phrase."
        }
        return formMessage
    }

    private var canSaveDictionaryEntry: Bool {
        !trimmedHeardAs.isEmpty && !trimmedReplaceWith.isEmpty && !duplicateDictionaryEntryExists
    }

    private func saveDictionaryEntry() {
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
            resetDictionaryForm()
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

    private func resetDictionaryForm() {
        editingEntry = nil
        heardAs = ""
        replaceWith = ""
        formMessage = nil
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "OpenBridge dictionary.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let payload = Dictionary(uniqueKeysWithValues: appState.customDictionaryEntries.map { ($0.heardAs, $0.replaceWith) })
            let data = try JSONEncoder.openBridgePretty.encode(payload)
            try data.write(to: url, options: .atomic)
            appState.statusMessage = "Exported dictionary to \(url.lastPathComponent)."
        } catch {
            appState.statusMessage = "Dictionary export failed: \(error.localizedDescription)"
        }
    }

    private func importDictionary(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStartSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode([String: String].self, from: data)
                mergeDictionaryEntries(imported)
            } catch {
                appState.statusMessage = "Dictionary import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            appState.statusMessage = "Dictionary import failed: \(error.localizedDescription)"
        }
    }

    private func mergeDictionaryEntries(_ imported: [String: String]) {
        var savedCount = 0
        for pair in imported.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            if let existingEntry = appState.customDictionaryEntries.first(where: { $0.heardAs.caseInsensitiveCompare(pair.key) == .orderedSame }) {
                if appState.updateCustomDictionaryEntry(existingEntry, heardAs: pair.key, replaceWith: pair.value) == .saved {
                    savedCount += 1
                }
            } else if appState.createCustomDictionaryEntry(heardAs: pair.key, replaceWith: pair.value) == .saved {
                savedCount += 1
            }
        }
        appState.statusMessage = "Imported \(savedCount) dictionary entries."
    }
}

struct MainDictionaryEntryRow: View {
    let entry: CustomDictionaryEntry
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.heardAs)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Replaces with \(entry.replaceWith)")
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: editAction) {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())

            Button(role: .destructive, action: deleteAction) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        }
        .padding(.vertical, 12)
    }
}

