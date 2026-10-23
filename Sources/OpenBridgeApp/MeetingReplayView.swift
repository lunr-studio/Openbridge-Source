import AVFoundation
import AppKit
import Foundation
import OpenBridgeUI
import SwiftUI

// MARK: - Meeting player

/// Plays back meeting audio segments sequentially using AVAudioPlayer.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentSegmentIndex = 0
    @Published var progress: Double = 0
    @Published var totalSegments: Int = 0

    private var onlinePlayer: AVPlayer?
    private var onlineComposition: AVMutableComposition?
    private(set) var onlineDuration: TimeInterval = 0
    private var onlineOffsets: [TimeInterval] = []
    private var player: AVAudioPlayer?
    private var segmentURLs: [URL] = []
    /// Wave-4 (3865266541): seconds to skip at the START of each segment —
    /// the overlap window carried into this chunk from the previous one, so
    /// playback does not repeat speech at each transition.
    private var segmentLeadingTrims: [TimeInterval] = []
    private var timer: Timer?

    func load(segments: [URL], leadingTrims: [TimeInterval] = []) {
        stop()
        onlineComposition = nil
        onlineOffsets = []
        segmentURLs = segments
        segmentLeadingTrims = leadingTrims
        totalSegments = segments.count
        currentSegmentIndex = 0
        progress = 0
    }

    func loadOnline(artifacts: [MeetingAudioArtifact], audioDirectory: URL) async throws {
        stop()
        onlineComposition = nil
        let ordered = artifacts.sorted { $0.startOffset < $1.startOffset }
        let (composition, duration) = try await Self.prepareOnlineComposition(
            artifacts: ordered, audioDirectory: audioDirectory)
        onlineComposition = composition
        onlineDuration = duration
        onlineOffsets = ordered.map(\.startOffset)
        segmentURLs = ordered.map { audioDirectory.appendingPathComponent($0.relativePath) }
        totalSegments = ordered.count
    }

    // Older AVFoundation SDKs return non-Sendable asset tracks. Keep those
    // tracks and all composition edits task-local, then transfer exclusive
    // ownership of the completed composition to the main-actor player.
    nonisolated private static func prepareOnlineComposition(
        artifacts: [MeetingAudioArtifact], audioDirectory: URL
    ) async throws -> sending (AVMutableComposition, TimeInterval) {
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        var lastEnds: [String: TimeInterval] = [:]
        for artifact in artifacts {
            let url = audioDirectory.appendingPathComponent(artifact.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let trim = max(0, (lastEnds[artifact.sourceID] ?? artifact.startOffset) - artifact.startOffset)
            let length = min(duration, artifact.endOffset - artifact.startOffset) - trim
            guard length > 0 else { continue }
            let target: AVMutableCompositionTrack
            if let existing = tracks[artifact.sourceID] { target = existing }
            else {
                guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                tracks[artifact.sourceID] = added; target = added
            }
            try target.insertTimeRange(CMTimeRange(start: CMTime(seconds: trim, preferredTimescale: 48_000),
                duration: CMTime(seconds: length, preferredTimescale: 48_000)), of: sourceTrack,
                at: CMTime(seconds: artifact.startOffset + trim, preferredTimescale: 48_000))
            lastEnds[artifact.sourceID] = artifact.startOffset + trim + length
        }
        return (composition, lastEnds.values.max() ?? 0)
    }

    func play() {
        if let onlineComposition {
            if onlinePlayer == nil { onlinePlayer = AVPlayer(playerItem: AVPlayerItem(asset: onlineComposition)) }
            onlinePlayer?.play(); isPlaying = true; startProgressTimer(); return
        }
        guard !segmentURLs.isEmpty else { return }

        if player == nil {
            loadSegment(at: currentSegmentIndex)
        }

        player?.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        onlinePlayer?.pause()
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        onlinePlayer?.pause()
        onlinePlayer = nil
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        currentSegmentIndex = 0
        stopProgressTimer()
    }

    func nextSegment() {
        guard currentSegmentIndex < segmentURLs.count - 1 else { return }
        currentSegmentIndex += 1
        if onlineComposition != nil {
            seekOnlineSegment(); return
        }
        let wasPlaying = isPlaying
        loadSegment(at: currentSegmentIndex)
        progress = 0
        if wasPlaying {
            player?.play()
        }
    }

    func previousSegment() {
        guard currentSegmentIndex > 0 else { return }
        currentSegmentIndex -= 1
        if onlineComposition != nil {
            seekOnlineSegment(); return
        }
        let wasPlaying = isPlaying
        loadSegment(at: currentSegmentIndex)
        progress = 0
        if wasPlaying {
            player?.play()
        }
    }

    private func seekOnlineSegment() {
        guard onlineOffsets.indices.contains(currentSegmentIndex) else { return }
        if onlinePlayer == nil, let onlineComposition { onlinePlayer = AVPlayer(playerItem: AVPlayerItem(asset: onlineComposition)) }
        onlinePlayer?.seek(to: CMTime(seconds: onlineOffsets[currentSegmentIndex], preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var currentSegmentName: String {
        if onlineComposition != nil { return "Online meeting · both sources" }
        guard currentSegmentIndex < segmentURLs.count else { return "—" }
        return "Segment \(currentSegmentIndex + 1) of \(segmentURLs.count)"
    }

    private func loadSegment(at index: Int) {
        guard index < segmentURLs.count else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: segmentURLs[index])
            // Wave-4 (3865266541): skip this chunk's leading overlap so the
            // shared audio is not replayed at each boundary.
            if index > 0, segmentLeadingTrims.indices.contains(index),
               segmentLeadingTrims[index] > 0, p.duration > 0 {
                p.currentTime = min(segmentLeadingTrims[index], p.duration)
            }
            player = p
        } catch {
            // Non-fatal — segment may be missing or corrupt
        }
    }

    private func handleSegmentFinished() {
        guard currentSegmentIndex < segmentURLs.count - 1 else {
            // Last segment — stop
            stop()
            return
        }
        nextSegment()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let online = self.onlinePlayer {
                    let time = CMTimeGetSeconds(online.currentTime())
                    self.progress = self.onlineDuration > 0 ? time / self.onlineDuration : 0
                    self.currentSegmentIndex = self.onlineOffsets.lastIndex(where: { $0 <= time }) ?? 0
                    if self.onlineDuration > 0, time >= self.onlineDuration { self.stop() }
                    return
                }
                guard let player = self.player else { return }

                // Update progress
                if player.duration > 0 {
                    self.progress = player.currentTime / player.duration
                }

                // Auto-advance when segment finishes (player stops naturally)
                if !player.isPlaying, self.isPlaying {
                    self.handleSegmentFinished()
                }
            }
        }
    }

    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Replay view

/// Shows a saved meeting's metadata and audio segments with playback controls.
struct MeetingReplayView: View {
    let manifest: MeetingManifest
    let store: MeetingSessionStore
    /// Exact canonical segment selected from a Research rail citation.
    var researchSourceSegmentID: String? = nil
    /// Opens the session-local rail composer for an explicit question.
    var onAskAnything: ((MeetingManifest) -> Void)? = nil
    /// lunr-studio/Openbridge-Beta#321 (AC5/AC6): retry delegates to the caller so the durable job
    /// re-queues through the app-scoped deferred-cleanup pump (serialized
    /// against all capture/engine consumers) instead of racing it.
    var onRetryCleanup: ((MeetingManifest) -> Void)? = nil
    /// lunr-studio/Openbridge-Beta#321 wave-1 (3884760779): cancel delegates to the app-scoped cleanup
    /// owner so it stops the deferred queue + in-flight task and suppresses
    /// requeue - not just the durable job record.
    var onCancelCleanup: ((MeetingManifest) -> Void)? = nil
    /// Explicit local alternative offered only after a new meeting's cloud
    /// cleanup fails. The caller changes the meeting snapshot deliberately;
    /// provider errors never trigger this path automatically.
    var onCleanLocally: ((MeetingManifest) -> Void)? = nil
    /// lunr-studio/Openbridge-Beta#321 wave-3 (3886129358): whether this meeting is currently in the
    /// app-scoped deferred-cleanup queue (owed but not yet launched) so the
    /// card can surface it as Queued instead of "No cleanup has run".
    var isCleanupDeferred: ((MeetingManifest) -> Bool)? = nil

    @StateObject private var player = MeetingPlayer()
    @State private var segmentURLs: [URL] = []
    @State private var loadError: String?
    /// lunr-studio/Openbridge-Beta#321 (AC6): Cleaned is the default review revision when a valid
    /// active revision exists; Original is always one click away.
    @State private var showingCleaned = false
    /// lunr-studio/Openbridge-Beta#321 wave-2 (3884981313): preserve an explicit user revision choice
    /// once made - polling auto-selects Cleaned only the FIRST time it
    /// observes a valid completed revision, never after the user switches.
    @State private var hasUserToggledRevision = false
    /// Reloaded copy so durable cleanup actions (cancel/retry) reflect
    /// immediately without re-opening the sheet.
    @State private var displayedManifest: MeetingManifest?
    /// lunr-studio/Openbridge-Beta#321 wave-4 (3886251008): CACHED active revision -
    /// activeCleanupRevision() reads + decodes the manifest synchronously on
    /// every access, and the view recomputes during audio playback ticks;
    /// cache it alongside displayedManifest and refresh only on state change.
    @State private var cachedActiveRevision: MeetingCleanupRevision?
    /// lunr-studio/Openbridge-Beta#321 wave-4 (3886250992): last observed
    /// deferred flag, so a deferred-to-running transition can reload.
    @State private var lastDeferredState = false
    @State private var intelligenceSidecar: MeetingIntelligenceSidecar?
    @State private var activeIntelligenceAction: MeetingIntelligenceArtifactKind?
    @State private var intelligenceMessage: String?
    @State private var intelligenceTask: Task<Void, Never>?
    @State private var pendingIntelligenceDeletion: MeetingIntelligenceArtifactKind?
    @EnvironmentObject private var providerSettings: ProviderSettingsController
    @Environment(\.dismiss) private var dismiss

    init(
        manifest: MeetingManifest,
        store: MeetingSessionStore,
        researchSourceSegmentID: String? = nil,
        onAskAnything: ((MeetingManifest) -> Void)? = nil,
        onRetryCleanup: ((MeetingManifest) -> Void)? = nil,
        onCancelCleanup: ((MeetingManifest) -> Void)? = nil,
        onCleanLocally: ((MeetingManifest) -> Void)? = nil,
        isCleanupDeferred: ((MeetingManifest) -> Bool)? = nil
    ) {
        self.manifest = manifest
        self.store = store
        self.researchSourceSegmentID = researchSourceSegmentID
        self.onAskAnything = onAskAnything
        self.onRetryCleanup = onRetryCleanup
        self.onCancelCleanup = onCancelCleanup
        self.onCleanLocally = onCleanLocally
        self.isCleanupDeferred = isCleanupDeferred
    }

    private var currentManifest: MeetingManifest {
        displayedManifest ?? manifest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — PINNED above the scroll region so the title, status
            // and the Done/close button are always reachable (Alex QA: a
            // long meeting's segment list pushed the header off-screen and
            // the box could not be closed except via Esc).
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(manifest.title)
                        .font(OpenBridgeTypography.pageTitle)
                        .foregroundStyle(OpenBridgeTheme.ink)

                    Text(manifest.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(OpenBridgeTypography.body(size: 16))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }

                Spacer(minLength: 12)

                OpenBridgeStatusPill(text: manifest.state.rawValue.capitalized, tint: OpenBridgeTheme.brandTeal)

                Button("Done") {
                    player.stop()
                    dismiss()
                }
                .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
            }
            .padding(24)

            Divider()

            // Content — scrollable so a long meeting's segment list and
            // transcript never overflow the window (Alex QA: could not
            // scroll to the transcript lines).
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if researchSourceSegment != nil {
                        replayResearchSourceCard
                    }

                    DisclosureGroup("Meeting details") {
                        replayMetadataCard.padding(.top, 12)
                    }.font(OpenBridgeTypography.control)

                    // Audio player
                    replayPlayerCard

                    // lunr-studio/Openbridge-Beta#321 (AC4-AC7): local cleanup state + revision review
                    replayCleanupCard

                    // The transcript remains the main reading surface.
                    replayTranscriptCard
                    // Research has its own current permission. Older/local
                    // meetings may have no recorded cleanup configuration.
                    if ResearchObservatoryFeatureFlag.isEnabled {
                        replayResearchCard
                    }
                    if currentManifest.intelligenceConfiguration != nil {
                        replayIntelligenceCard
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: 1040, alignment: .topLeading)
        .font(OpenBridgeTypography.control)
        .background(OpenBridgeTheme.card)
        .preferredColorScheme(.light)
        .onAppear {
            loadSegments()
            // lunr-studio/Openbridge-Beta#321 wave-1 (3884760784): reload the manifest on appearance -
            // the sheet can open on a snapshot taken before runPostStopCleanup
            // created the job, which would otherwise claim no cleanup ran.
            displayedManifest = try? store.load(meetingID: manifest.meetingID)
            cachedActiveRevision = try? store.activeCleanupRevision(meetingID: manifest.meetingID)
            reloadIntelligenceSidecar()
            lastDeferredState = isCleanupDeferred?(manifest) == true
            // lunr-studio/Openbridge-Beta#321 (AC6 + AC8): a valid active revision defaults the review
            // to Cleaned (the SAME validity predicate the lunr-studio/Openbridge-Beta#214 export gate
            // uses - one shared decision, cannot drift); Original is always
            // one obvious action away.
            showingCleaned = MeetingRevisionReviewValidity.shouldDefaultToCleaned(
                try? store.activeCleanupRevision(meetingID: currentManifest.meetingID)
            )
        }
        // lunr-studio/Openbridge-Beta#321 wave-1 (3884760784): while the cleanup is queued/running,
        // poll the durable job so the card reflects progress without needing
        // a manual reopen. Restarts whenever the job state changes.
        .task(id: currentManifest.cleanupJobs.last?.state) {
            // lunr-studio/Openbridge-Beta#321 wave-2 (3884981302): a cancelled task (sheet dismissed)
            // must stop polling - swallowing the sleep's CancellationError
            // made the loop tight-spin on disk I/O for the rest of a long
            // cleanup. Exit on cancellation.
            while let job = currentManifest.cleanupJobs.last,
                  job.state == .queued || job.state == .running {
                if Task.isCancelled { break }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                reloadManifest()
                // lunr-studio/Openbridge-Beta#321 wave-2 (3884981313): when polling first observes a
                // valid completed revision, honor the Cleaned-by-default
                // contract - but only before the user made an explicit choice.
                if !hasUserToggledRevision,
                   MeetingRevisionReviewValidity.shouldDefaultToCleaned(activeCleanupRevision) {
                    showingCleaned = true
                }
            }
        }
        .onDisappear {
            player.stop()
            intelligenceTask?.cancel()
        }
        .confirmationDialog(
            "Delete saved meeting output?",
            isPresented: Binding(
                get: { pendingIntelligenceDeletion != nil },
                set: { if !$0 { pendingIntelligenceDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete saved output", role: .destructive) {
                if let kind = pendingIntelligenceDeletion {
                    deleteIntelligenceArtifact(kind)
                }
                pendingIntelligenceDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingIntelligenceDeletion = nil
            }
        } message: {
            Text("This removes the saved cloud result. The Original transcript is not changed.")
        }
    }

    private var replayMetadataCard: some View {
        MainReplayInfoCard("Meeting details", systemImage: "info.circle") {
            MainReplayFactRow(label: "Started", value: manifest.startedAt.formatted(date: .abbreviated, time: .shortened))

            if let endedAt = manifest.endedAt {
                MainReplayFactRow(label: "Ended", value: endedAt.formatted(date: .abbreviated, time: .shortened))
                let duration = endedAt.timeIntervalSince(manifest.startedAt)
                MainReplayFactRow(label: "Duration", value: formatDuration(duration))
            }

            MainReplayFactRow(label: "Meeting type", value: manifest.captureMode.title + (manifest.captureStatus == .microphoneOnlyFallback ? " · microphone only" : ""))
            MainReplayFactRow(label: "Segments", value: "\(manifest.audioSegments.count)")
            MainReplayFactRow(label: "Retention", value: manifest.retentionPolicy.rawValue)
        }
    }

    private var replayPlayerCard: some View {
        MainReplayInfoCard("Audio playback", systemImage: "play.circle") {
            if segmentURLs.isEmpty {
                Text(loadError ?? "No audio segments found for this meeting.")
                    .font(OpenBridgeTypography.body(size: 16))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Progress bar
                    ProgressView(value: player.progress, total: 1)
                        .frame(maxWidth: .infinity)

                    Text(player.currentSegmentName)
                        .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)

                    // Playback controls
                    HStack(spacing: 16) {
                        Button {
                            player.previousSegment()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(OpenBridgeTypography.heading(size: 18))
                        }
                        .disabled(player.currentSegmentIndex == 0)
                        .buttonStyle(.plain)

                        Button {
                            if player.isPlaying {
                                player.pause()
                            } else {
                                player.play()
                            }
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(OpenBridgeTypography.heading(size: 28))
                                .foregroundStyle(OpenBridgeTheme.brandBlue)
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.nextSegment()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(OpenBridgeTypography.heading(size: 18))
                        }
                        .disabled(player.currentSegmentIndex >= segmentURLs.count - 1)
                        .buttonStyle(.plain)

                        Spacer()

                        Button(role: .destructive) {
                            player.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(OpenBridgeTypography.heading(size: 18))
                        }
                        .disabled(!player.isPlaying && player.progress == 0)
                        .buttonStyle(.plain)
                    }

                    // Segment list
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(segmentURLs.enumerated()), id: \.offset) { index, url in
                            HStack(spacing: 8) {
                                Image(systemName: index == player.currentSegmentIndex && player.isPlaying ? "speaker.wave.2.fill" : "waveform")
                                    .font(OpenBridgeTypography.body(size: 13))
                                    .foregroundStyle(index == player.currentSegmentIndex ? OpenBridgeTheme.brandBlue : OpenBridgeTheme.mutedInk)
                                    .frame(width: 16)

                                Text(url.lastPathComponent)
                                    .font(OpenBridgeTypography.body(size: 13))
                                    .foregroundStyle(index == player.currentSegmentIndex ? OpenBridgeTheme.ink : OpenBridgeTheme.mutedInk)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    private var replayTranscriptCard: some View {
        MainReplayInfoCard("Transcript", systemImage: "text.bubble") {
            let text = selectedTranscriptText
            if text.isEmpty {
                Text("No transcript is available yet. If recording was interrupted, use the recovery actions in Meetings.")
                    .font(OpenBridgeTypography.body(size: 16))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
            } else {
                // lunr-studio/Openbridge-Beta#321 (AC7): display-only switching - the canonical segments
                // are never mutated, so switching revisions cannot overwrite
                // the Original.
                Text(text)
                    .font(OpenBridgeTypography.body)
                    .lineSpacing(10)
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .frame(maxWidth: 700, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// lunr-studio/Openbridge-Beta#321 (AC4): durable cleanup job state + revision review card.
    private var replayCleanupCard: some View {
        MainReplayInfoCard("Cleanup", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                let cleanupPresentation = MeetingProcessingPresentation.make(
                    manifest: currentManifest,
                    isCleanupDeferred: isCleanupDeferred?(currentManifest) == true
                )
                // lunr-studio/Openbridge-Beta#321 wave-3 (3886129358): a meeting that is owed but
                // not yet launched has no durable job yet - surface it as
                // Queued with a cancel control instead of claiming no cleanup.
                if isCleanupDeferred?(currentManifest) == true {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(cleanupPresentation.detailText)
                            .font(OpenBridgeTypography.body(size: 16))
                            .foregroundStyle(OpenBridgeTheme.ink)
                        Spacer()
                    }
                    Button("Cancel cleanup", role: .destructive) {
                        onCancelCleanup?(currentManifest)
                    }
                    .font(OpenBridgeTypography.body(size: 13))
                } else if let job = currentManifest.cleanupJobs.last {
                    HStack(spacing: 8) {
                        if job.state == .queued || job.state == .running {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: cleanupStateIcon(job.state))
                                .font(OpenBridgeTypography.body(size: 13))
                                .foregroundStyle(cleanupStateTint(job.state))
                        }
                        Text(cleanupPresentation.detailText)
                            .font(OpenBridgeTypography.body(size: 16))
                            .foregroundStyle(OpenBridgeTheme.ink)
                        Spacer()
                    }

                    if job.state == .queued || job.state == .running {
                        Button("Cancel cleanup", role: .destructive) {
                            onCancelCleanup?(currentManifest)
                        }
                        .font(OpenBridgeTypography.body(size: 13))
                        // lunr-studio/Openbridge-Beta#321 (AC9): VoiceOver hint - the original transcript
                        // always remains available.
                        .accessibilityHint("Cancels the local cleanup. The original transcript remains available.")
                    } else if job.state == .failed || job.state == .interrupted || job.state == .retryAvailable {
                        HStack(spacing: 12) {
                            // lunr-studio/Openbridge-Beta#321 wave-4 (3886251010): when the master
                            // toggle is Off the handler rejects the retry and the
                            // rejection toast is hidden behind this modal - disable
                            // the control and say why instead of a dead button.
                            Button(latestCleanupProvider == .cloud ? "Retry cloud" : "Retry cleanup") {
                                requestCleanupRetry()
                            }
                            .disabled(!MeetingCleanupSettings.isCleanupEnabled)
                            .font(OpenBridgeTypography.body(size: 13))
                            // lunr-studio/Openbridge-Beta#321 (AC9): VoiceOver hint for the retry action.
                            .accessibilityHint(
                                latestCleanupProvider == .cloud
                                    ? "Retries cleanup with this meeting's snapshotted cloud provider."
                                    : "Re-runs local cleanup for this meeting's transcript."
                            )
                            if latestCleanupProvider == .cloud,
                               currentManifest.intelligenceConfiguration != nil {
                                Button("Clean locally with Gemma") {
                                    onCleanLocally?(currentManifest)
                                }
                                .disabled(!MeetingCleanupSettings.isCleanupEnabled)
                                .font(OpenBridgeTypography.body(size: 13))
                                .accessibilityHint("Uses the local Gemma model. No transcript text leaves this Mac.")
                            }
                        }
                    }
                } else {
                    Text(cleanupPresentation.detailText)
                        .font(OpenBridgeTypography.body(size: 16))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }

                if let progressValue = cleanupPresentation.progressValue {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(cleanupPresentation.badgeText)
                }

                if let revision = activeCleanupRevision,
                   MeetingRevisionReviewValidity.shouldDefaultToCleaned(revision) {
                    Picker("Revision", selection: Binding(
                        get: { showingCleaned },
                        set: { showingCleaned = $0; hasUserToggledRevision = true }
                    )) {
                        Text("Cleaned").tag(true)
                        Text("Original").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Text("Cleaned is shown by default; Original is one click away and is never modified.")
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }
            }
        }
    }

    // MARK: - Helpers

    // MARK: lunr-studio/Openbridge-Beta#321 revision review (AC6/AC7)

    private var activeCleanupRevision: MeetingCleanupRevision? {
        cachedActiveRevision
    }

    private var researchSourceSegment: MeetingTranscriptSegment? {
        guard let researchSourceSegmentID, !researchSourceSegmentID.isEmpty else { return nil }
        return currentManifest.segments.first { $0.id == researchSourceSegmentID }
    }

    private var replayResearchSourceCard: some View {
        MainReplayInfoCard("Research source", systemImage: "scope") {
            if let segment = researchSourceSegment {
                Text("This is the exact Original transcript segment cited by the Research rail.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                Text(lineText(for: segment))
                    .font(OpenBridgeTypography.body)
                    .lineSpacing(10)
                    .foregroundStyle(OpenBridgeTheme.ink)
                    .frame(maxWidth: 700, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var replayResearchCard: some View {
        MainReplayInfoCard("Meeting Intelligence", systemImage: "binoculars") {
            Text("Ask about this meeting or research the web. Review cloud access before sending a question; web searches require a separate query approval.")
                .font(OpenBridgeTypography.body(size: 16))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
            Button("Ask anything") {
                onAskAnything?(currentManifest)
                dismiss()
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
            .disabled(onAskAnything == nil)
            .accessibilityHint("Opens Meeting Intelligence for this saved meeting. Nothing is sent automatically.")
        }
    }

    private var replayIntelligenceCard: some View {
        MainReplayInfoCard("Meeting tools", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing is sent automatically. Summarize and Extract send transcript text—not audio—to this meeting's saved cloud provider.")
                    .font(OpenBridgeTypography.body(size: 16))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        intelligenceActionButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        intelligenceActionButtons
                    }
                }

                if let blocker = cloudIntelligenceBlocker {
                    Text(blocker)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.brandGold)
                } else if let intelligenceMessage {
                    Text(intelligenceMessage)
                        .font(OpenBridgeTypography.body(size: 13))
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                }

                if let summary = intelligenceSidecar?.summary {
                    Divider()
                    intelligenceArtifactHeader(
                        title: "Summary",
                        isStale: summary.isStale(for: currentManifest),
                        provenance: summary.provenance,
                        createdAt: summary.createdAt
                    )
                    Text(summary.text)
                        .font(OpenBridgeTypography.body(size: 16))
                        .foregroundStyle(OpenBridgeTheme.ink)
                        .textSelection(.enabled)
                    intelligenceArtifactControls(
                        kind: .summary,
                        copyText: summary.text,
                        document: MeetingIntelligenceArtifactExporter.summaryDocument(
                            meeting: currentManifest,
                            artifact: summary
                        )
                    )
                }

                if let extraction = intelligenceSidecar?.actionsAndDecisions {
                    Divider()
                    intelligenceArtifactHeader(
                        title: "Actions and decisions",
                        isStale: extraction.isStale(for: currentManifest),
                        provenance: extraction.provenance,
                        createdAt: extraction.createdAt
                    )

                    Text("Decisions")
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    if extraction.decisions.isEmpty {
                        Text("None identified.")
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                    } else {
                        ForEach(extraction.decisions) { decision in
                            Text("• \(decision.summary)")
                                .textSelection(.enabled)
                        }
                    }

                    Text("Actions")
                        .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
                    if extraction.actions.isEmpty {
                        Text("None identified.")
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                    } else {
                        ForEach(extraction.actions) { action in
                            Text(actionDisplayText(action))
                                .textSelection(.enabled)
                        }
                    }

                    let document = MeetingIntelligenceArtifactExporter.actionsAndDecisionsDocument(
                        meeting: currentManifest,
                        artifact: extraction
                    )
                    intelligenceArtifactControls(
                        kind: .actionsAndDecisions,
                        copyText: document.text,
                        document: document
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var intelligenceActionButtons: some View {
        Button(intelligenceSidecar?.summary == nil ? "Summarize" : "Regenerate summary") {
            runIntelligenceAction(.summary)
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: intelligenceSidecar?.summary == nil))
        .disabled(activeIntelligenceAction != nil || cloudIntelligenceBlocker != nil)
        .accessibilityHint("Explicitly sends this meeting's transcript text to its saved cloud provider and saves the returned summary locally.")

        Button(intelligenceSidecar?.actionsAndDecisions == nil
               ? "Extract actions and decisions"
               : "Regenerate actions and decisions") {
            runIntelligenceAction(.actionsAndDecisions)
        }
        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: intelligenceSidecar?.actionsAndDecisions == nil))
        .disabled(activeIntelligenceAction != nil || cloudIntelligenceBlocker != nil)
        .accessibilityHint("Explicitly sends this meeting's transcript text to its saved cloud provider and saves validated actions and decisions locally.")

        if activeIntelligenceAction != nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") {
                    intelligenceTask?.cancel()
                }
                .buttonStyle(OpenBridgeMiniButtonStyle())
            }
        }

    }

    private func actionDisplayText(_ action: MeetingIntelligenceAction) -> String {
        guard let assignee = action.assignee, !assignee.isEmpty else {
            return "• \(action.description)"
        }
        return "• \(action.description) — \(assignee)"
    }

    @ViewBuilder
    private func intelligenceArtifactHeader(
        title: String,
        isStale: Bool,
        provenance: MeetingIntelligenceProvenance,
        createdAt: Date
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(OpenBridgeTypography.heading(size: 20))
            if isStale {
                OpenBridgeStatusPill(text: "Stale", tint: OpenBridgeTheme.brandGold)
            }
            Spacer()
        }
        Text("\(provenance.provider.displayName) · \(provenance.model) · \(createdAt.formatted(date: .abbreviated, time: .shortened))")
            .font(OpenBridgeTypography.body(size: 13))
            .foregroundStyle(OpenBridgeTheme.mutedInk)
        if isStale {
            Text("The source transcript changed after this was generated. Regenerate before relying on it.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.brandGold)
        }
    }

    @ViewBuilder
    private func intelligenceArtifactControls(
        kind: MeetingIntelligenceArtifactKind,
        copyText: String,
        document: (filename: String, text: String)
    ) -> some View {
        HStack(spacing: 10) {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                intelligenceMessage = "Copied to the clipboard."
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())

            Button("Export…") {
                exportIntelligenceDocument(document)
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())

            Button("Delete", role: .destructive) {
                pendingIntelligenceDeletion = kind
            }
            .buttonStyle(OpenBridgeMiniButtonStyle())
            .accessibilityHint("Deletes this saved output. It does not delete or change the original transcript.")
        }
    }

    private var cloudIntelligenceBlocker: String? {
        guard currentManifest.state == .completed else {
            return "Finish or recover this meeting before using meeting tools."
        }
        guard currentManifest.aiMode.maySendTranscriptToCloud,
              currentManifest.privacySettings.allowsCloudIntelligence else {
            return "Cloud tools were not authorized when this meeting was created."
        }
        guard let snapshot = currentManifest.intelligenceConfiguration?.cloudProvider else {
            return "No cloud provider was saved for this meeting."
        }
        guard providerSettings.settings.cloudEnabled,
              providerSettings.settings.consentGranted else {
            return "Enable Cloud intelligence in Settings to use these actions."
        }
        guard providerSettings.hasCredential else {
            return "Add the API key for this meeting's provider in Settings."
        }
        guard providerSettings.settings.configuration.hasSameProviderIdentity(as: snapshot.configuration) else {
            return "Restore this meeting's saved provider and model in Settings. OpenBridge will not silently switch providers."
        }
        guard providerSettings.hasCurrentTestAttestation else {
            return "Test this provider successfully in Settings before sending transcript text."
        }
        return nil
    }

    private func runIntelligenceAction(_ kind: MeetingIntelligenceArtifactKind) {
        guard activeIntelligenceAction == nil, cloudIntelligenceBlocker == nil else { return }
        intelligenceTask?.cancel()
        activeIntelligenceAction = kind
        intelligenceMessage = kind == .summary
            ? "Generating summary…"
            : "Extracting actions and decisions…"

        let meeting = currentManifest
        let providerWasTested = providerSettings.hasCurrentTestAttestation
        let service = CloudMeetingIntelligenceService(authorizationGate: providerSettings)
        intelligenceTask = Task { @MainActor in
            defer {
                activeIntelligenceAction = nil
                intelligenceTask = nil
            }
            do {
                switch kind {
                case .summary:
                    let artifact = try await service.summarize(
                        meeting: meeting,
                        providerWasTested: providerWasTested
                    )
                    try store.saveSummary(artifact, meetingID: meeting.meetingID)
                    intelligenceMessage = "Summary saved locally."
                case .actionsAndDecisions:
                    let artifact = try await service.extractActionsAndDecisions(
                        meeting: meeting,
                        providerWasTested: providerWasTested
                    )
                    try store.saveActionsAndDecisions(artifact, meetingID: meeting.meetingID)
                    intelligenceMessage = "Actions and decisions saved locally."
                }
                reloadIntelligenceSidecar()
            } catch is CancellationError {
                intelligenceMessage = "Cloud action cancelled. No saved result was changed."
            } catch {
                intelligenceMessage = error.localizedDescription
            }
        }
    }

    private func reloadIntelligenceSidecar() {
        do {
            intelligenceSidecar = try store.loadIntelligenceSidecar(meetingID: currentManifest.meetingID)
        } catch {
            intelligenceSidecar = nil
            intelligenceMessage = error.localizedDescription
        }
    }

    private func deleteIntelligenceArtifact(_ kind: MeetingIntelligenceArtifactKind) {
        do {
            try store.deleteIntelligenceArtifact(kind, meetingID: currentManifest.meetingID)
            reloadIntelligenceSidecar()
            intelligenceMessage = "Saved output deleted. The Original transcript was not changed."
        } catch {
            intelligenceMessage = error.localizedDescription
        }
    }

    private func exportIntelligenceDocument(_ document: (filename: String, text: String)) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try MeetingIntelligenceArtifactExporter.write(document, to: destination)
            intelligenceMessage = "Exported \(destination.lastPathComponent)."
        } catch {
            intelligenceMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private var latestCleanupProvider: MeetingCleanupProvider {
        guard let job = currentManifest.cleanupJobs.last,
              let revision = currentManifest.cleanupRevisions.first(where: { $0.id == job.revisionID }) else {
            return currentManifest.intelligenceConfiguration?.cleanupProvider ?? .localGemma
        }
        return revision.resolvedProvenance.producer
    }

    private var selectedTranscriptText: String {
        if showingCleaned, let revision = activeCleanupRevision,
           MeetingRevisionReviewValidity.shouldDefaultToCleaned(revision) {
            return cleanedText(for: revision)
        }
        return originalText
    }

    private var originalText: String {
        let segments = currentManifest.segments
        if !segments.isEmpty {
            return segments
                .sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
                .map { lineText(for: $0) }
                .joined(separator: "\n")
        }
        return currentManifest.transcriptSpans.joined(separator: "\n")
    }

    private func cleanedText(for revision: MeetingCleanupRevision) -> String {
        let cleanedBySourceID = Dictionary(
            revision.cleanedSegments.map { ($0.sourceSegmentID, $0.cleanedText) },
            uniquingKeysWith: { first, _ in first }
        )
        let sources = currentManifest.segments.sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
        if !sources.isEmpty {
            return sources.compactMap { source in
                guard let cleaned = cleanedBySourceID[source.id] else { return nil }
                return cleanedLineText(source: source, cleanedText: cleaned)
            }
            .joined(separator: "\n")
        }
        return revision.cleanedSegments.map(\.cleanedText).joined(separator: "\n")
    }

    private func lineText(for segment: MeetingTranscriptSegment) -> String {
        var prefix = ""
        if let start = segment.startOffset {
            prefix = "[\(formattedOffset(start))] \(segment.sourceLabel) — "
        } else if !segment.sourceLabel.isEmpty {
            prefix = "\(segment.sourceLabel) — "
        }
        return prefix + segment.text
    }

    private func cleanedLineText(source: MeetingTranscriptSegment, cleanedText: String) -> String {
        var prefix = ""
        if let start = source.startOffset {
            prefix = "[\(formattedOffset(start))] \(source.sourceLabel) — "
        } else if !source.sourceLabel.isEmpty {
            prefix = "\(source.sourceLabel) — "
        }
        return prefix + cleanedText
    }

    private func formattedOffset(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: lunr-studio/Openbridge-Beta#321 cleanup job state (AC4/AC5)

    private func cleanupStateIcon(_ state: MeetingCleanupJobState) -> String {
        switch state {
        case .completed: return "checkmark.circle.fill"
        case .failed, .interrupted: return "exclamationmark.triangle.fill"
        case .stale: return "clock.arrow.circlepath"
        case .retryAvailable: return "arrow.clockwise.circle"
        case .cancelled: return "xmark.circle"
        default: return "sparkles"
        }
    }

    private func cleanupStateTint(_ state: MeetingCleanupJobState) -> Color {
        switch state {
        case .completed: return OpenBridgeTheme.brandTeal
        case .failed, .interrupted, .cancelled: return OpenBridgeTheme.brandCoral
        case .stale: return OpenBridgeTheme.brandGold
        default: return OpenBridgeTheme.brandBlue
        }
    }

    private func cancelCleanup(_ job: MeetingCleanupJob) {
        // lunr-studio/Openbridge-Beta#321 (AC5): cancel is idempotent - the store no-ops on
        // completed/failed/cancelled/stale jobs. The meeting stays completed.
        try? store.cancelCleanupJob(meetingID: currentManifest.meetingID, jobID: job.id)
        reloadManifest()
    }

    private func requestCleanupRetry() {
        // lunr-studio/Openbridge-Beta#321 (AC5): retry delegates to the app-scoped pump so the durable
        // job re-queues serialized against capture/engine consumers.
        onRetryCleanup?(currentManifest)
        reloadManifest()
    }

    private func reloadManifest() {
        displayedManifest = try? store.load(meetingID: manifest.meetingID)
        // lunr-studio/Openbridge-Beta#321 wave-4 (3886251008): refresh the cached
        // validated revision only when cleanup state changes.
        cachedActiveRevision = try? store.activeCleanupRevision(meetingID: manifest.meetingID)
        // lunr-studio/Openbridge-Beta#321 wave-4 (3886250992): detect the
        // deferred-to-running transition (job now exists) and reload.
        let deferredNow = isCleanupDeferred?(currentManifest) == true
        if lastDeferredState && !deferredNow {
            displayedManifest = try? store.load(meetingID: manifest.meetingID)
            cachedActiveRevision = try? store.activeCleanupRevision(meetingID: manifest.meetingID)
        }
        lastDeferredState = deferredNow
    }

    private func loadSegments() {
        let audioDir = store.audioDirectory(for: manifest.meetingID)
        if manifest.captureMode == .online {
            segmentURLs = manifest.audioArtifacts.map { audioDir.appendingPathComponent($0.relativePath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if segmentURLs.isEmpty { loadError = "Audio files for this meeting were not found on disk."; return }
            Task { @MainActor in
                do { try await player.loadOnline(artifacts: manifest.audioArtifacts, audioDirectory: audioDir) }
                catch { loadError = "Online audio could not be loaded: \(error.localizedDescription)" }
            }
            return
        }
        // Wave-5 (3865416033): keep each URL paired with its ORIGINAL
        // manifest index — an intermediate missing file must not shift the
        // boundary metadata used for overlap trimming.
        let present: [(index: Int, url: URL)] = manifest.audioSegments.indices.compactMap { i in
            let url = audioDir.appendingPathComponent(manifest.audioSegments[i])
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (i, url)
        }
        segmentURLs = present.map { $0.url }

        if segmentURLs.isEmpty {
            loadError = "Audio files for this meeting were not found on disk."
        }

        // Wave-4 (3865266541) + wave-5 (3865416033): each chunk after the
        // first carries the previous boundary's overlap at its start. Trim
        // ONLY when the immediately preceding manifest segment is ALSO
        // present — if it is missing, this is the only replayable copy of
        // that audio and its leading overlap must be kept.
        let leadingTrims = present.map { entry -> TimeInterval in
            guard entry.index > 0,
                  present.contains(where: { $0.index == entry.index - 1 }),
                  manifest.chunkBoundaries.indices.contains(entry.index - 1)
            else { return 0 }
            let previous = manifest.chunkBoundaries[entry.index - 1]
            guard manifest.chunkBoundaries.indices.contains(entry.index) else {
                return previous.availableOverlap
            }
            return MeetingChunkBoundary.actualOverlap(
                from: previous,
                into: manifest.chunkBoundaries[entry.index]
            )
        }
        player.load(segments: segmentURLs, leadingTrims: leadingTrims)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Replay UI components (private to this file)

private struct MainReplayInfoCard<Content: View>: View {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenBridgeTheme.card.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.9), lineWidth: 1)
        }
    }
}

private struct MainReplayFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.ink)

            Spacer(minLength: 0)
        }
    }
}
