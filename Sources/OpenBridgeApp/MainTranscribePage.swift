import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenBridgeUI

enum MainTranscribeTab: String, CaseIterable, Identifiable {
    case files, youtube
    var id: String { rawValue }
    var title: String { self == .files ? "Files" : "YouTube" }
    var section: MainWindowSection { self == .files ? .transcribe : .transcribeYouTube }
}

struct MainTranscribePage: View {
    @EnvironmentObject private var appState: AppState
    var initialTab: MainTranscribeTab = .files
    let navigate: (MainWindowSection) -> Void
    @State private var selectedFileURL: URL?
    @State private var youtubeURL = ""
    @State private var showingFileImporter = false
    @State private var showingReplaceConfirmation = false
    @State private var selectedVariant: MediaTranscriptVariant = .cleaned
    @State private var fileImportMessage: String?

    private var isReadyToStart: Bool {
        appState.canStartMediaTranscription && (initialTab == .files
            ? selectedFileURL != nil
            : !youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            MainWorkflowTabs(options: MainTranscribeTab.allCases, selected: initialTab,
                             title: { $0.title }, select: { navigate($0.section) })
                .accessibilityLabel("Transcription sources")

            MainPageScaffold {
                MainPageHeader(
                    title: initialTab == .files ? "Capture the signal. Learn with AI." : "A video, in your own time.",
                    subtitle: initialTab == .files ? "Give an existing recording a useful second life." : "Turn a video into words you can read, revisit, and use.",
                    statusText: "Local transcription",
                    statusTint: OpenBridgeTheme.brandTeal
                )

                if !appState.readyForMediaTranscription {
                    MainInfoCard("A little setup first", systemImage: "arrow.down.circle") {
                        Text(appState.mediaSetupMessage)
                            .font(OpenBridgeTypography.body)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { navigate(.models) } label: {
                            Label("Models & performance", systemImage: "arrow.right")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    }
                }

                sourceCard
                if let result = appState.mediaTranscriptionResult {
                    resultCard(result)
                } else if !appState.isTranscribingMedia {
                    MainTwoColumnGrid {
                        MainInfoCard("A clear result, without the clutter.", systemImage: "text.alignleft") {
                            Text("Review the current transcript, copy the text, or save it before starting another file. Transcribe keeps your latest result in this session.")
                                .font(OpenBridgeTypography.body)
                                .lineSpacing(8)
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        MainInfoCard("Your recording stays yours.", systemImage: "lock") {
                            Text(initialTab == .files
                                 ? "Speech recognition and transcript cleanup run on your Mac. Your recording is not sent to an AI provider."
                                 : "OpenBridge downloads audio from YouTube, then transcribes and cleans the words on your Mac. YouTube requires an internet connection.")
                                .font(OpenBridgeTypography.body)
                                .lineSpacing(8)
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url):
                selectedFileURL = url
                fileImportMessage = nil
            case .failure(let error):
                fileImportMessage = "The file could not be opened: \(error.localizedDescription)"
            }
        }
        .alert("Replace the current transcript?", isPresented: $showingReplaceConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Transcribe new source") { startTranscription() }
        } message: {
            Text("Copy or save the current result first if you want to keep it. Starting a new transcription replaces this session’s result.")
        }
        .onChange(of: appState.mediaTranscriptionResult?.id) { _, _ in
            selectedVariant = .cleaned
        }
    }

    private var sourceCard: some View {
        MainInfoCard(initialTab == .files ? "Bring a recording" : "Bring a YouTube link",
                     systemImage: initialTab == .files ? "doc.text" : "play.rectangle") {
            VStack(alignment: .leading, spacing: 24) {
                if initialTab == .files {
                    fileInput
                } else {
                    youtubeInput
                }
                Divider()
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
                        .disabled(!appState.canStartMediaTranscription)
                        .font(OpenBridgeTypography.control)
                        Text("Fast and Careful currently use the same local cleanup pass. This preference is also used by voice typing.")
                            .font(OpenBridgeTypography.metadata)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    OpenBridgeStatusPill(text: "On your Mac", tint: OpenBridgeTheme.brandTeal)
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dictionary corrections apply here too.")
                            .font(OpenBridgeTypography.metadata)
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                        Button { navigate(.dictionary) } label: {
                            Label("Review shared Dictionary", systemImage: "arrow.right")
                        }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    }
                    Spacer(minLength: 0)
                    Button {
                        if appState.mediaTranscriptionResult != nil {
                            showingReplaceConfirmation = true
                        } else {
                            startTranscription()
                        }
                    } label: {
                        Label(initialTab == .files ? "Transcribe file" : "Transcribe video", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                    .disabled(!isReadyToStart)
                }

                if let fileImportMessage {
                    Label(fileImportMessage, systemImage: "exclamationmark.circle")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.brandCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if appState.isTranscribingMedia {
                    HStack(alignment: .top, spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preparing your transcript")
                                .font(OpenBridgeTypography.heading(size: 18))
                            Text(appState.statusMessage)
                                .font(OpenBridgeTypography.metadata)
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } else if isMediaStatusMessage {
                    Text(appState.statusMessage)
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var fileInput: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedFileURL == nil ? "folder" : "doc.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(OpenBridgeTheme.ink)
            Text(selectedFileURL?.lastPathComponent ?? "A recording, ready to read.")
                .font(OpenBridgeTypography.heading(size: 18))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Audio and video files become a readable transcript.")
                .font(OpenBridgeTypography.control)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
            Button { showingFileImporter = true } label: {
                Label(selectedFileURL == nil ? "Choose a file" : "Choose another file", systemImage: "folder")
            }
            .buttonStyle(OpenBridgeMiniButtonStyle(prominent: selectedFileURL == nil))
            .disabled(!appState.canStartMediaTranscription)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(OpenBridgeTheme.coolSurface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(OpenBridgeTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private var youtubeInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YouTube URL")
                .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
            TextField("https://www.youtube.com/watch?v=…", text: $youtubeURL)
                .textFieldStyle(.roundedBorder)
                .font(OpenBridgeTypography.control)
                .disabled(!appState.canStartMediaTranscription)
                .accessibilityLabel("YouTube URL")
            Text("Paste the full link to a video you can access. OpenBridge downloads its audio and processes it locally.")
                .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultCard(_ result: MediaTranscriptionResult) -> some View {
        MainInfoCard(result.sourceName, systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    if result.hasCleanedTranscript {
                        Picker("Transcript version", selection: $selectedVariant) {
                            ForEach(MediaTranscriptVariant.allCases) { variant in
                                Text(variant.title).tag(variant)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    } else {
                        Text(result.hasOriginalTranscript ? "Original transcript" : "Transcript")
                            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                    Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(OpenBridgeTypography.mono(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
                Text(result.text(for: selectedVariant))
                    .font(OpenBridgeTypography.body)
                    .lineSpacing(12)
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: 12) {
                    Text(result.hasCleanedTranscript ? "Original stays available. Copy and Save use the selected version." : "Copy or save this transcript before starting another source.")
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        PasteboardService.copy(result.text(for: selectedVariant))
                        appState.statusMessage = "Copied media transcript."
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(OpenBridgeMiniButtonStyle())
                    Button { save(result) } label: {
                        Label("Save As", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                }
            }
        }
    }

    private var isMediaStatusMessage: Bool {
        ["File transcription failed:", "YouTube transcription failed:", "Enter a full YouTube URL.",
         "File transcript ready:", "YouTube transcript ready:", "Copied media transcript.",
         "Saved media transcript", "Media transcript could not be saved:"]
            .contains { appState.statusMessage.hasPrefix($0) }
    }

    private func startTranscription() {
        fileImportMessage = nil
        switch initialTab {
        case .files:
            guard let selectedFileURL else { return }
            Task { await appState.transcribeMediaFile(selectedFileURL) }
        case .youtube:
            Task { await appState.transcribeYouTubeURL(youtubeURL) }
        }
    }

    private func save(_ result: MediaTranscriptionResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = result.defaultFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.text(for: selectedVariant).write(to: url, atomically: true, encoding: .utf8)
            appState.statusMessage = "Saved media transcript to \(url.lastPathComponent)."
        } catch {
            appState.statusMessage = "Media transcript could not be saved: \(error.localizedDescription)"
        }
    }
}
