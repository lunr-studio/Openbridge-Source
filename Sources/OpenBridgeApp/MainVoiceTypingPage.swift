import SwiftUI
import Combine
import OpenBridgeUI

enum MainVoiceTypingTab: String, CaseIterable, Identifiable {
    case preferences, history, textActions, snippets, dictionary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferences: "Preferences"
        case .history: "History"
        case .textActions: "Text actions"
        case .snippets: "Snippets"
        case .dictionary: "Dictionary"
        }
    }

    var section: MainWindowSection {
        switch self {
        case .preferences: .dictation
        case .history: .history
        case .textActions: .transforms
        case .snippets: .snippets
        case .dictionary: .dictionary
        }
    }
}

/// Drafts live above the conditional tab content. Leaving a tab must not discard
/// an unsaved phrase or a search, and need not keep its microphone task mounted.
@MainActor
final class MainVoiceTypingDrafts: ObservableObject {
    @Published var historySearchText = ""
    @Published var snippetSearchText = ""
    @Published var snippetTriggerPhrase = ""
    @Published var snippetExpansionText = ""
    @Published var editingSnippet: Snippet?
    @Published var snippetFormMessage: String?
    @Published var snippetTestPhrase = ""
    @Published var dictionarySearchText = ""
    @Published var dictionaryHeardAs = ""
    @Published var dictionaryReplaceWith = ""
    @Published var editingDictionaryEntry: CustomDictionaryEntry?
    @Published var dictionaryFormMessage: String?
}

/// Existing section routes remain usable from the menu, shortcuts, and recovery links.
/// The local tab row reveals the rest of the workflow without expanding the sidebar.
struct MainVoiceTypingPage: View {
    @StateObject private var drafts = MainVoiceTypingDrafts()
    var initialTab: MainVoiceTypingTab = .preferences
    let navigate: (MainWindowSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            MainWorkflowTabs(
                options: MainVoiceTypingTab.allCases,
                selected: initialTab,
                title: { $0.title },
                select: { navigate($0.section) }
            )
            .accessibilityLabel("Voice typing pages")

            switch initialTab {
            case .preferences: MainDictationPage(navigate: navigate)
            case .history: MainHistoryPage(drafts: drafts)
            case .textActions: MainTransformsPage()
            case .snippets: MainSnippetsPage(drafts: drafts)
            case .dictionary: MainDictionaryPage(drafts: drafts)
            }
        }
    }
}

struct MainWorkflowTabs<Option: Hashable>: View {
    @FocusState private var focusedOption: Option?
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    let select: (Option) -> Void

    var body: some View {
        HStack(spacing: 24) {
            ForEach(options, id: \.self) { option in
                Button {
                    focusedOption = option
                    select(option)
                } label: {
                    Text(title(option))
                        .font(OpenBridgeTypography.body(size: 15, weight: selected == option ? .semibold : .medium))
                        .foregroundStyle(selected == option ? OpenBridgeTheme.ink : OpenBridgeTheme.mutedInk)
                        .padding(.vertical, 16)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected == option ? OpenBridgeTheme.brandBlue : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedOption, equals: option)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selected == option ? [.isSelected] : [])
                .onMoveCommand { direction in
                    guard let index = options.firstIndex(of: option) else { return }
                    switch direction {
                    case .left:
                        let next = options[(index - 1 + options.count) % options.count]
                        focusedOption = next
                        select(next)
                    case .right:
                        let next = options[(index + 1) % options.count]
                        focusedOption = next
                        select(next)
                    default: break
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenBridgeTheme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenBridgeTheme.border).frame(height: 1)
        }
    }
}

struct MainVoiceTypingIntroduction: View {
    @EnvironmentObject private var appState: AppState
    let navigate: (MainWindowSection) -> Void

    var body: some View {
        MainInfoCard("Speak where you write", systemImage: "keyboard") {
            Text("Place your cursor in a text box and press \(appState.hotkeyDescription) to start. Press it again to finish.")
                .font(OpenBridgeTypography.body)
                .lineSpacing(8)
                .foregroundStyle(OpenBridgeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your words return to the original text box. If insertion needs attention, copy or paste the last transcript from History.")
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Button { navigate(.history) } label: {
                Label("View recent text", systemImage: "arrow.right")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
        }
    }
}

struct MainVoiceCleanupPreferenceCard: View {
    @EnvironmentObject private var appState: AppState
    let navigate: (MainWindowSection) -> Void

    var body: some View {
        MainInfoCard("Keep it readable", systemImage: "text.badge.checkmark") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Local transcript cleanup", selection: Binding(
                        get: { appState.transcriptionCleanupMode },
                        set: { appState.setTranscriptionCleanupMode($0) }
                    )) {
                        ForEach(TranscriptionCleanupMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .font(OpenBridgeTypography.control)
                    .disabled(appState.isRecording || appState.isStartingRecording || appState.isTranscribing || appState.isTranscribingMedia)
                    Text("Fast and Careful currently use the same full-transcript cleanup pass. If cleanup is unavailable, OpenBridge keeps the original words.")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OpenBridgeStatusPill(text: "On your Mac", tint: OpenBridgeTheme.brandTeal)
            }
            Divider()
            HStack(spacing: 16) {
                Text("Names and recurring terms are shared across OpenBridge.")
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                Spacer(minLength: 0)
                Button { navigate(.dictionary) } label: {
                    Label("Open Dictionary", systemImage: "arrow.right")
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }
    }
}
