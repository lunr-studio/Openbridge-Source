import Foundation
import OpenBridgeUI

/// Abstraction over the transcription engine so meeting finalization can be
/// tested with deterministic success/failure without invoking the real Python
/// engine. `EngineService` conforms at its declaration site.
protocol MeetingEngine: Sendable {
    func transcribe(
        audioURL: URL,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> TranscriptPayload
}

/// Minimal read-only view of a recorder's finalized-segment progress.
/// Production conforms `MeetingRecorder`; tests inject a controllable source
/// so live/stop races can be exercised without `AVCaptureSession`.
@MainActor
protocol MeetingSegmentSource: AnyObject {
    var captureMode: MeetingCaptureMode { get }
    var audioArtifacts: [MeetingAudioArtifact] { get }
    var completedSegmentCount: Int { get }
    /// #294 (3864613545): per-chunk boundaries; the transcriber uses the
    /// previous chunk's overlap window to dedup repeated overlap text.
    var chunkBoundaries: [MeetingChunkBoundary] { get }
}

extension MeetingSegmentSource {
    var captureMode: MeetingCaptureMode { .inPerson }
    var audioArtifacts: [MeetingAudioArtifact] { [] }
    /// Default so existing test doubles (e.g. `ScriptedSegmentSource`) keep
    /// compiling without changes — dedup simply no-ops when unavailable.
    var chunkBoundaries: [MeetingChunkBoundary] { [] }
}

extension MeetingRecorder: MeetingSegmentSource {}

/// Result of finalizing a meeting's remaining segments at stop time.
enum MeetingFinalizationResult {
    /// Every pending segment was transcribed and persisted successfully.
    case completed(transcribedSegmentCount: Int)
    /// One or more segments could not be transcribed. Source audio is left on
    /// disk so the user can retry; the meeting must NOT be marked complete.
    case failed(transcribedSegmentCount: Int, lastError: String)
}
/// Transcribes meeting audio segments as they're finalized by the recorder.
///
/// Watches `completedSegmentCount` on the recorder and transcribes each new
/// segment using the existing `EngineService`. Transcript spans are appended
/// to the meeting manifest and published to the UI via `@Published`.
///
/// #303 guarantees (round 2, PR #67 review): concurrent inference with
/// strictly ordered persistence; one live attempt per segment; finalize
/// awaits all work and blocks ticks; live taps are an opt-in seam.
@MainActor
final class MeetingTranscriber: ObservableObject {
    @Published var transcriptText: String = ""
    @Published var isTranscribing: Bool = false
    @Published var lastError: String?

    /// Completed-but-not-yet-durable segment result awaiting its turn in
    /// the ordered persistence buffer.
    private struct BufferedSegment {
        /// The durable segment instance created at engine-success time.
        /// The live tap fires with THIS instance immediately; ordered
        /// persistence later writes the SAME id (stable sourceSpanID,
        /// wave-7 3836115274).
        let segment: MeetingTranscriptSegment
        let fromLive: Bool
        /// Wave-7 (3865752988): whether the overlap was ACTUALLY deduped
        /// before buffering. If the predecessor had not landed yet, dedup
        /// could not run even though `fromLive` is true — persistence must
        /// re-run it then. `fromLive` alone is a false positive.
        let wasDeduped: Bool
    }

    private var onlineTranscriber: OnlineMeetingTranscriber?
    var researchTranscriptionProgress: ResearchTranscriptionProgress {
        if let onlineTranscriber { return onlineTranscriber.researchTranscriptionProgress }
        let failed = missingAudioSegmentIndices.union(liveAttemptedIndices
            .subtracting(persistedSegmentIndices).subtracting(Set(inFlightTasks.keys))
            .subtracting(Set(bufferedSegments.keys)))
        return ResearchTranscriptionProgress(
            completed: Set(persistedSegmentIndices.subtracting(missingAudioSegmentIndices).map { "room:\($0)" }),
            failed: Set(failed.map { "room:\($0)" }))
    }
    private var store: MeetingSessionStore
    private let engine: any MeetingEngine
    private var meetingID: String?
    /// Wave-7 (3836482855): stamped on every `start`. Live tasks capture
    /// the generation they were launched under; a timed-out (cancelled but
    /// still parked) task completing after a NEW meeting started on the
    /// same transcriber is ignored - it cannot steal the new meeting's
    /// in-flight registration or mutate its buffers.
    private var meetingGeneration = UUID()
    /// Durable accounting: index present ONLY after its transcript was
    /// written to the manifest (or its audio file doesn't exist).
    private var persistedSegmentIndices: Set<Int> = []
    /// In-flight segment tasks. Entries stay registered until their task
    /// completes - never cleared ahead of an await.
    private var inFlightTasks: [Int: Task<Void, Never>] = [:]
    /// Parakeet inference is process-backed. A fixed cap prevents a delayed
    /// engine from spawning one process per queued chunk and exhausting memory.
    /// Two keeps the existing low-latency overlap while making the resource
    /// cost independent of meeting length.
    var maxConcurrentLiveTranscriptions = 2
    /// Indices already attempted by the live path (one attempt each; the
    /// stop-time finalize is the retry path).
    private var liveAttemptedIndices: Set<Int> = []
    /// Ordered persistence buffer, keyed by segment index.
    private var bufferedSegments: [Int: BufferedSegment] = [:]
    /// True while stop-time finalize owns the meeting: meter ticks no-op.
    private var isFinalizing = false
    /// Wave-9 (3837588531): latched by the UI at the ACTUAL Stop boundary -
    /// before the recorder await - so an in-flight live call that lands
    /// during that window keeps its transcript but fires no Observatory
    /// tap. `isFinalizing` alone was too late (set only at finalize).
    /// Reset by the next `start(meetingID:)`.
    private var suppressLiveTaps = false
    /// Admission latch set at the same user-visible Stop boundary. It blocks
    /// both timer launches and automatic queue refills until the next meeting.
    private var stopRequested = false
    /// Wave-19 (3839500424): recorder-counted WAVs that vanished before
    /// finalization. Their indices resolve (nothing to transcribe) but they
    /// must NOT be reported as transcribed - no transcript exists.
    private var missingAudioSegmentIndices: Set<Int> = []
    /// Wave-15 (3838270695): in-flight fire-and-forget tap tasks. A tap can
    /// suspend inside ObservatorySpokenIntake.ingest when Stop lands; these
    /// are cancelled at the Stop boundary so the continuation dies at the
    /// suspension instead of submitting a spoken invocation after Stop.
    private var liveTapTasks: [Task<Void, Never>] = []
    /// Wave-4 (3865266521): live taps whose overlap head could not yet be
    /// deduped (the predecessor had not completed). Fired once the
    /// predecessor lands (persisted), with the deduped text.
    private var pendingLiveTaps: [Int: MeetingTranscriptSegment] = [:]
    /// Wave-7 (3876716820): ephemeral per-meeting predecessor text for the
    /// never-store policy (which never writes durably, so dedup has no
    /// manifest to consult). Index -> text, cleared on start().
    private var neverStorePredecessorText: [Int: String] = [:]

    /// #294 (3864613545): the recorder whose chunk boundaries drive overlap
    /// dedup. Updated whenever the transcriber is handed a segment source.
    private weak var segmentSource: (any MeetingSegmentSource)?


    /// Wave-6 review: one finalization at a time. A second Stop while the
    /// first is awaiting SHARES the in-progress task (identical result,
    /// exact-once persistence) instead of running a second finalizer.
    /// Cleared by the creating caller after the await so a later recovery
    /// retry starts a fresh finalization.
    private var finalizationTask: Task<MeetingFinalizationResult, Never>?

    /// Wave-6 review: Stop must not wait forever on a hung live engine call.
    /// Budget for awaiting in-flight live tasks before cancelling them and
    /// reporting their indices as finalization failures. Injectable so
    /// tests can exercise the timeout path quickly.
    var finalizationWaitTimeout: TimeInterval = 120

    /// #299/#309 live taps (Observatory spoken intake + shared index).
    /// Opt-in: nil by default so tests never touch the persistent research
    /// index; the production recording path wires it.
    var liveSegmentTap: ((MeetingTranscriptSegment) async -> Void)?

    /// Wave-9 (3837588531): the UI calls this the moment Stop is confirmed
    /// (before awaiting the recorder) so late-landing live successes keep
    /// their transcript but never tap Observatory after Stop.
    func stopLiveTaps() {
        onlineTranscriber?.stopLive()
        suppressLiveTaps = true
        stopRequested = true
        // Wave-15 (3838270695): cancel every tap already in flight - a task
        // parked inside ingest must not resume into submitSpoken/index work.
        for task in liveTapTasks { task.cancel() }
        liveTapTasks.removeAll()
    }

    /// A recorder-level fatal error has already made normal Stop/finalization
    /// impossible. Invalidate and cancel every live segment task now so its
    /// dictionary entry cannot consume the next meeting's concurrency slots.
    func cancelLiveWorkAfterCaptureFailure() {
        onlineTranscriber?.cancel()
        stopLiveTaps()
        meetingGeneration = UUID()
        for task in inFlightTasks.values { task.cancel() }
        inFlightTasks.removeAll()
        segmentSource = nil
        isTranscribing = false
    }

    /// Wave-9 (3837560681): opt-in reindex hook fired when the persistence
    /// paths (flush / ordered drain) write segments whose engine-success tap
    /// indexed the manifest BEFORE the write - the shared index must catch
    /// up to durability. Nil in tests; the production recording path wires
    /// it (DEBUG-gated inside the factory).
    var postPersistIndexTap: ((_ meetingID: String) async -> Void)?

    private var modelIdentifier: String
    private var customDictionaryURL: URL
    private var cleanupMode: TranscriptionCleanupMode
    private var formattingEnabled: Bool
    private var vocabularyEnabled: Bool

    init(
        store: MeetingSessionStore,
        modelIdentifier: String,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode = .off,
        formattingEnabled: Bool = true,
        vocabularyEnabled: Bool = true,
        engine: (any MeetingEngine)? = nil
    ) {
        self.store = store
        self.modelIdentifier = modelIdentifier
        self.customDictionaryURL = customDictionaryURL
        self.cleanupMode = cleanupMode
        self.formattingEnabled = formattingEnabled
        self.vocabularyEnabled = vocabularyEnabled
        // Default to the real engine; tests inject a stub.
        self.engine = engine ?? EngineService()
    }

    func configure(
        store: MeetingSessionStore,
        modelIdentifier: String,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode = .off,
        formattingEnabled: Bool = true,
        vocabularyEnabled: Bool = true
    ) {
        self.store = store
        self.modelIdentifier = modelIdentifier
        self.customDictionaryURL = customDictionaryURL
        self.cleanupMode = cleanupMode
        self.formattingEnabled = formattingEnabled
        self.vocabularyEnabled = vocabularyEnabled
    }

    func start(meetingID: String) {
        onlineTranscriber?.cancel()
        onlineTranscriber = nil
        self.meetingID = meetingID
        self.meetingGeneration = UUID()
        self.suppressLiveTaps = false
        self.stopRequested = false
        // Wave-20 (3839624999): per-meeting accounting - a vanished WAV in
        // one meeting must not exclude a successfully persisted segment at
        // the same index in the next meeting.
        self.missingAudioSegmentIndices.removeAll()
        self.persistedSegmentIndices = []
        self.liveAttemptedIndices = []
        self.bufferedSegments = [:]
        self.pendingLiveTaps = [:]
        self.neverStorePredecessorText = [:]
        self.transcriptText = ""
        self.lastError = nil
    }

    /// True while any segment task is running; completion is forbidden.
    var hasUnresolvedSegmentWork: Bool {
        !inFlightTasks.isEmpty || (onlineTranscriber?.hasUnresolvedWork ?? false)
    }
/// Called periodically (e.g. from the meter timer) to launch tracked
    /// live transcription for finalized-but-unpersisted segments. Each index
    /// gets exactly ONE live attempt; no-op while finalize owns the stop.
    private func prepareOnlineTranscriber(meetingID: String) -> OnlineMeetingTranscriber {
        if let onlineTranscriber { return onlineTranscriber }
        let next = OnlineMeetingTranscriber(store: store, engine: engine, meetingID: meetingID,
            model: modelIdentifier, dictionary: customDictionaryURL,
            formatting: formattingEnabled, vocabulary: vocabularyEnabled)
        next.maximumConcurrent = maxConcurrentLiveTranscriptions
        next.waitTimeout = finalizationWaitTimeout
        next.liveTap = liveSegmentTap
        next.indexTap = postPersistIndexTap
        next.onChange = { [weak self] text, busy, error in
            guard let self, self.meetingID == meetingID else { return }
            self.transcriptText = text; self.isTranscribing = busy; self.lastError = error
        }
        if stopRequested { next.stopLive() }
        onlineTranscriber = next
        return next
    }

    func retryOnlineArtifacts(meetingID: String) async -> MeetingFinalizationResult {
        do {
            let manifest = try store.reconcileOnlineAudio(meetingID: meetingID)
            return await prepareOnlineTranscriber(meetingID: meetingID).finalize(manifest.audioArtifacts)
        } catch {
            return .failed(transcribedSegmentCount: 0, lastError: error.localizedDescription)
        }
    }

    func checkForNewSegments(recorder: any MeetingSegmentSource) {
        if recorder.captureMode == .online, let meetingID {
            guard !stopRequested else { return }
            prepareOnlineTranscriber(meetingID: meetingID).ingest(recorder.audioArtifacts)
            return
        }
        self.segmentSource = recorder
        guard !isFinalizing, !stopRequested else { return }
        guard inFlightTasks.count < maxConcurrentLiveTranscriptions else { return }
        let currentCount = recorder.completedSegmentCount
        guard let meetingID else { return }

        for index in 0..<currentCount
        where !persistedSegmentIndices.contains(index)
            && inFlightTasks[index] == nil
            && !liveAttemptedIndices.contains(index) {
            // Wave-7 (3836503102): the stored cleanup preference no longer
            // serializes live launches - live calls always run the engine
            // with cleanup `.off` (AGENTS.md L39-42), so no live Gemma work
            // is being protected; the selected cleanup runs post-Stop via
            // the coordinator instead.
            let segmentURL = store.audioSegmentURL(for: meetingID, segmentIndex: index)
            guard FileManager.default.fileExists(atPath: segmentURL.path) else {
                // No audio on disk: nothing to transcribe for this index.
                persistedSegmentIndices.insert(index)
                missingAudioSegmentIndices.insert(index)
                continue
            }

            liveAttemptedIndices.insert(index)
            isTranscribing = true
            let generation = meetingGeneration
            inFlightTasks[index] = Task { [weak self] in
                await self?.runLiveSegment(
                    url: segmentURL, index: index, meetingID: meetingID, generation: generation
                )
                self?.segmentTaskDidFinish(index: index, generation: generation)
            }
            if inFlightTasks.count >= maxConcurrentLiveTranscriptions {
                break
            }
        }
    }

    /// Finalize and transcribe every remaining unprocessed segment at stop
    /// time. The single source of truth for "the meeting is done
    /// transcribing": awaits ALL in-flight work, retries every unresolved
    /// index once through the ordered path, and only reports `.completed`
    /// when every finalized segment is durably persisted. Audio is NEVER
    /// deleted here - failures keep files on disk for recovery.
    func finalizeAndTranscribe(recorder: any MeetingSegmentSource, meetingID: String) async -> MeetingFinalizationResult {
        if recorder.captureMode == .online {
            return await prepareOnlineTranscriber(meetingID: meetingID).finalize(recorder.audioArtifacts)
        }
        self.segmentSource = recorder
        // Wave-6 review: share one in-progress finalization across repeated
        // Stop confirmations. Check-and-create is MainActor-synchronous (no
        // await between), so exactly one task can exist.
        if let existing = finalizationTask {
            return await existing.value
        }
        // Guard ticks SYNCHRONOUSLY, before the task is even scheduled: a
        // meter tick landing between this call and the task's first hop must
        // already see finalization owning the meeting. (Wave-6 CI regression:
        // moving the flag set inside the task opened that window and ticks
        // launched duplicate work.)
        isFinalizing = true
        defer { isFinalizing = false }
        let task = Task<MeetingFinalizationResult, Never> {
            await self.performFinalization(recorder: recorder, meetingID: meetingID)
        }
        finalizationTask = task
        let result = await task.value
        // Clear after the await: a LATER retry (e.g. recovery after .failed)
        // starts a fresh finalization rather than replaying this result.
        finalizationTask = nil
        return result
    }

    private func performFinalization(recorder: any MeetingSegmentSource, meetingID: String) async -> MeetingFinalizationResult {
        let currentCount = recorder.completedSegmentCount

        // 1. Await every in-flight segment task, bounded by the wait budget.
        //    Entries stay registered until each task itself removes them;
        //    ticks during this await are blocked by `isFinalizing`. Tasks
        //    still parked at the budget are cancelled (the engine honors
        //    cancellation and terminates its child) and their indices are
        //    reported as unresolved - never an infinite wait.
        let stuckIndices = await awaitInFlightSegmentWork(budget: finalizationWaitTimeout)
        // Wave-16 (3838384609): timed-out tasks may STILL return later (an
        // engine that ignores cancellation). Invalidating the generation now
        // drops those same-meeting late completions at the guard in
        // runLiveSegment, so they can no longer mutate buffers/manifest
        // after finalization already reported the segment unresolved.
        if !stuckIndices.isEmpty {
            meetingGeneration = UUID()
        }

        // 2. One ordered retry pass over every finalized-but-unpersisted
        //    index (live failures + the stop-time tail). This path runs the
        //    engine and buffers results; it NEVER runs live taps.
        var firstError: String?
        var transcribed = 0
        for index in 0..<currentCount
        where !persistedSegmentIndices.contains(index)
            && bufferedSegments[index] == nil
            && !stuckIndices.contains(index) {

            let segmentURL = store.audioSegmentURL(for: meetingID, segmentIndex: index)
            guard FileManager.default.fileExists(atPath: segmentURL.path) else {
                persistedSegmentIndices.insert(index)
                missingAudioSegmentIndices.insert(index)
                continue
            }
            // Wave-5: engine-level cleanup is Parakeet-only everywhere;
            // selected cleanup runs post-Stop as a coordinator revision.
            switch await engineTranscribe(url: segmentURL, cleanupMode: .off) {
            case .success(let text):
                transcribed += 1
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Wave-3 (3864858081): the recovery path has no live recorder
                // — dedup + offsets come from the persisted manifest copy.
                let manifest = try? store.load(meetingID: meetingID)
                let deduped = dedupText(trimmed, at: index, meetingID: meetingID, manifest: manifest)
                let o = offsets(at: index, manifest: manifest)
                bufferedSegments[index] = BufferedSegment(
                    segment: MeetingTranscriptSegment(
                        meetingID: meetingID,
                        sequence: index,
                        startOffset: o.0,
                        endOffset: o.1,
                        sourceLabel: "Room",
                        text: deduped,
                        isFinal: true
                    ),
                    fromLive: false,
                    wasDeduped: deduped != trimmed
                )
            case .failure(let failure):
                if firstError == nil { firstError = failure.message }
            }
        }

        // 3. Verdict. Every finalized segment must be durably persisted
        //    (buffer drained with no holes) for completion.
        let unresolved = (0..<currentCount).filter { !persistedSegmentIndices.contains($0) }
        let holes = unresolved.filter { bufferedSegments[$0] == nil }

        if holes.isEmpty {
            drainOrderedBuffer()
            // Wave-17 (3838661483): the drain itself persists - and a save
            // can FAIL (disk full, unwritable). Recompute the verdict AFTER
            // it: any index still unpersisted means the completion verdict
            // was wrong and must degrade to failure with the segment named,
            // keeping recovery state truthful.
            let stillUnpersisted = (0..<currentCount).filter {
                !persistedSegmentIndices.contains($0)
            }
            if stillUnpersisted.isEmpty {
                // Wave-7 (3836115273): a recovered meeting must not keep
                // displaying a live failure the stop-time retry just resolved.
                lastError = nil
                // Wave-18 (3839462805): report segments actually transcribed
                // (durably persisted), not the recorder's count - a missing
                // WAV resolves its index without any transcript existing.
                let persistedCount = (0..<currentCount)
                    .filter {
                        persistedSegmentIndices.contains($0)
                            && !missingAudioSegmentIndices.contains($0)
                    }.count
                return .completed(transcribedSegmentCount: persistedCount)
            }
            let numbers = stillUnpersisted.map { $0 + 1 }.sorted()
            let msg = "Transcription could not be saved "
                + "(unresolved segment\(numbers.count == 1 ? "" : "s"): "
                + "\(numbers.map(String.init).joined(separator: ", ")))"
            lastError = msg
            return .failed(transcribedSegmentCount: transcribed, lastError: msg)
        }

        // Lossless flush: a permanent hole must not discard the buffered
        // transcripts behind it. Persist everything buffered in ascending
        // index order, then report failure naming the hole.
        flushBufferedSegmentsAscending()
        // Wave-18 (3839462803): the flush itself can fail to save a buffered
        // segment - recompute unresolved AFTER it so diagnostics name every
        // index needing recovery, not just the pre-flush engine failures.
        let unresolvedAfterFlush = (0..<currentCount).filter {
            !persistedSegmentIndices.contains($0)
        }
        // Wave-7 (3836115275): always NAME the unresolved segments; keep
        // the engine's error when one exists.
        let unresolvedNumbers = unresolvedAfterFlush.map { $0 + 1 }.sorted()
        let message = "\(firstError ?? "Transcription failed") "
            + "(unresolved segment\(unresolvedNumbers.count == 1 ? "" : "s"): "
            + "\(unresolvedNumbers.map(String.init).joined(separator: ", ")))"
        lastError = message
        return .failed(transcribedSegmentCount: transcribed, lastError: message)
    }

    /// Awaits tracked in-flight tasks within `budget` seconds. Tasks remove
    /// their own entries on completion; this polls (50ms) so a hung engine
    /// call cannot stall Stop forever. Anything still parked at the budget
    /// is cancelled (the engine's cancellation handler terminates its child
    /// process) and returned as stuck indices for failure reporting.
    private func awaitInFlightSegmentWork(budget: TimeInterval) async -> Set<Int> {
        let deadline = Date().addingTimeInterval(budget)
        while !inFlightTasks.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var stuck = Set<Int>()
        for (index, task) in inFlightTasks {
            task.cancel()
            stuck.insert(index)
            inFlightTasks[index] = nil
        }
        isTranscribing = false
        return stuck
    }

    private func segmentTaskDidFinish(index: Int, generation: UUID) {
        // Wave-7 (3836482855): stale completions (timed out under an older
        // meeting generation) must not unregister or drain the CURRENT
        // meeting's work.
        guard generation == meetingGeneration else { return }
        inFlightTasks[index] = nil
        drainOrderedBuffer()
        if inFlightTasks.isEmpty { isTranscribing = false }
        // Pull the next queued segment immediately instead of waiting for the
        // next UI meter tick. The cap stays enforced because the finished task
        // was removed before this launch attempt.
        if !isFinalizing, !stopRequested, let segmentSource {
            checkForNewSegments(recorder: segmentSource)
        }
    }
/// Production persistence-path reindex. Disabled at runtime unless the
/// user has enabled the Research rail Beta.
static func productionIndexRefreshTap(
    store: MeetingSessionStore
) -> (String) async -> Void {
    return { meetingID in
        guard ResearchObservatoryFeatureFlag.isEnabled else { return }
        if let manifest = try? store.load(meetingID: meetingID) {
            ObservatorySharedIndex.indexMeeting(manifest)
        }
    }
}

/// Production live tap factory (#299/#309): feeds final segments to the
    /// Observatory spoken-intake detector and the shared retrieval index.
    /// Disabled at runtime unless the user has enabled the Beta.
    static func productionLiveTap(
        store: MeetingSessionStore
    ) -> (MeetingTranscriptSegment) async -> Void {
        return { segment in
            guard ResearchObservatoryFeatureFlag.isEnabled else { return }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("AlignedResult(") else { return }
            // Meeting research is explicitly submitted in the rail. Speech is
            // evidence only and must never initiate a cloud request.
            // Wave-15 (3838270695): Stop may have landed while ingest was
            // suspended - a cancelled tap must not resume into submitSpoken
            // or an index refresh after Stop or an explicit Beta opt-out.
            guard !Task.isCancelled,
                  ResearchObservatoryFeatureFlag.isEnabled else { return }
            if let manifest = try? store.load(meetingID: segment.meetingID) {
                ObservatorySharedIndex.indexMeeting(manifest)
            }
        }
    }

    /// Drains the ordered buffer left-to-right from the lowest unpersisted
    /// index. Stops at the first hole - later segments stay buffered until
    /// the hole is filled (by a retry or the lossless flush).
    private func drainOrderedBuffer(from start: Int? = nil) {
        // Wave-7 (3834342748): an explicit start drains relative to it so a
        // range call [fromIndex, toIndex) persists its own results instead
        // of assuming this transcriber began at index 0.
        var next = start ?? nextUnpersistedIndex()
        var persistedMeetingID: String?
        while let buffered = bufferedSegments[next] {
            bufferedSegments[next] = nil
            // Wave-6 (3865593065) + wave-7 (3865752988): pass whether dedup
            // ACTUALLY ran (not merely `fromLive`). If the predecessor was
            // missing at live time, persistence re-runs dedup against the
            // now-available predecessor.
            persistSegment(index: next, segment: buffered.segment, wasDedupedLive: buffered.wasDeduped)
            persistedMeetingID = buffered.segment.meetingID
            next += 1
        }
        // Wave-10 (3837632198): the ordered drain persists recovered
        // segments (e.g. a Stop-time retry of a failed earlier index)
        // with no live tap - refresh the shared index so they become
        // searchable immediately, not after a restart.
        if let persistedMeetingID, let postPersistIndexTap {
            let id = persistedMeetingID
            Task { await postPersistIndexTap(id) }
        }
    }

    /// Lossless flush for permanent holes: persist everything still
    /// buffered, in ascending index order, skipping nothing.
    private func flushBufferedSegmentsAscending() {
        var persistedMeetingID: String?
        for index in bufferedSegments.keys.sorted() {
            guard let buffered = bufferedSegments[index] else { continue }
            bufferedSegments[index] = nil
            // Wave-7 (3865753025): this alternate persistence path must also
            // honor whether dedup already ran — otherwise a live segment that
            // WAS deduped once is trimmed a second time here (e.g. "go go
            // now" reduced to "now").
            persistSegment(index: index, segment: buffered.segment, wasDedupedLive: buffered.wasDeduped)
            persistedMeetingID = buffered.segment.meetingID
        }
        // Wave-9 (3837560681): the engine-success tap indexed the manifest
        // BEFORE this write; refresh the shared index so durable segments
        // are searchable immediately (not just after a later tap/restart).
        if let persistedMeetingID, let postPersistIndexTap {
            let id = persistedMeetingID
            Task { await postPersistIndexTap(id) }
        }
    }

    /// True when an earlier live attempt PERMANENTLY failed (attempted,
    /// finished, neither persisted nor buffered) below `index` - i.e. a
    /// hole the ordered drain would stall on. In-flight (parked) earlier
    /// segments do NOT count: ordering must hold while they may still land.
    private func hasPermanentLiveHole(below index: Int) -> Bool {
        liveAttemptedIndices.contains { hole in
            hole < index
                && !persistedSegmentIndices.contains(hole)
                && bufferedSegments[hole] == nil
                && inFlightTasks[hole] == nil
        }
    }

    /// Smallest index not yet durably persisted (0 if none persisted).
    private func nextUnpersistedIndex() -> Int {
        var index = 0
        while persistedSegmentIndices.contains(index) { index += 1 }
        return index
    }

    // MARK: - Wave-3 overlap metadata helpers

    /// The boundary for a chunk — from the live recorder source when present,
    /// else the persisted manifest copy (recovery path, 3864858081).
    private func chunkBoundary(at index: Int, manifest: MeetingManifest?) -> MeetingChunkBoundary? {
        if let source = segmentSource, source.chunkBoundaries.indices.contains(index) {
            return source.chunkBoundaries[index]
        }
        if let manifest, manifest.chunkBoundaries.indices.contains(index) {
            return manifest.chunkBoundaries[index]
        }
        return nil
    }

    /// Text of the segment before `index`, for overlap dedup — from the
    /// ordered buffer first, else the durable manifest. Wave-4 (3865266516):
    /// the meeting is passed explicitly because the recovery path never sets
    /// `self.meetingID`.
    private func previousSegmentText(before index: Int, meetingID: String) -> String? {
        if let buffered = bufferedSegments[index - 1] {
            return buffered.segment.text
        }
        if let cached = neverStorePredecessorText[index - 1] {
            return cached
        }
        guard let manifest = try? store.load(meetingID: meetingID) else { return nil }
        // Wave-6 (3865593058): PREFER the recovered (canonically valid)
        // replacement over an invalid duplicate. Recovery appends the valid
        // replacement before reconciliation removes the old invalid entry,
        // so `first(where:)` could still pick the stale text.
        return manifest.segments
            .filter { $0.sequence == index - 1 && RecoveryActionRouter.segmentIsValid($0, meetingID: meetingID) }
            .sorted { $0.id < $1.id }
            .last?
            .text
            ?? manifest.segments.first(where: { $0.sequence == index - 1 })?.text
    }

    /// Exact-match overlap dedup for `index` against its predecessor.
    private func dedupText(_ text: String, at index: Int, meetingID: String, manifest: MeetingManifest?) -> String {
        guard index > 0,
              let previousBoundary = chunkBoundary(at: index - 1, manifest: manifest),
              let prevText = previousSegmentText(before: index, meetingID: meetingID)
        else { return text }
        let overlap = chunkBoundary(at: index, manifest: manifest).map {
            MeetingChunkBoundary.actualOverlap(from: previousBoundary, into: $0)
        } ?? previousBoundary.availableOverlap
        guard overlap > 0 else { return text }
        return MeetingOverlapDedup.trimOverlappingHead(
            from: text, previousText: prevText, overlapSeconds: overlap
        )
    }

    /// Span offsets for a chunk from its boundary (3864858088).
    private func offsets(at index: Int, manifest: MeetingManifest?) -> (TimeInterval?, TimeInterval?) {
        guard let b = chunkBoundary(at: index, manifest: manifest) else { return (nil, nil) }
        return (b.startOffset, b.endOffset)
    }

    /// Re-run dedup for segments persisted earlier behind a hole once the
    /// hole is recovered (3864858099): their overlap head could not be
    /// deduped while the predecessor was missing. Wave-6 (3865593045): a
    /// failed save of the re-deduped successors THROWS so finalization
    /// cannot report success with duplicated text still durable.
    private func rededupPersistedSuccessors(in manifest: inout MeetingManifest, after index: Int) throws {
        // Wave-4 (3865266529): capture derivability BEFORE mutating — the
        // mutation invalidates the equality we need to test.
        let spansDeriveFromTypedSegments =
            manifest.transcriptSpans == manifest.segments.map {
                "[Segment \($0.sequence + 1)] \($0.text)"
            }
        var changed = false
        for j in (index + 1)...max(index + 1, manifest.segments.map({ $0.sequence }).max() ?? index) {
            guard let seg = manifest.segments.first(where: { $0.sequence == j }),
                  let prev = manifest.segments.first(where: { $0.sequence == j - 1 }),
                  let previousBoundary = chunkBoundary(at: j - 1, manifest: manifest)
            else { continue }
            let overlap = chunkBoundary(at: j, manifest: manifest).map {
                MeetingChunkBoundary.actualOverlap(from: previousBoundary, into: $0)
            } ?? previousBoundary.availableOverlap
            guard overlap > 0 else { continue }
            let deduped = MeetingOverlapDedup.trimOverlappingHead(
                from: seg.text, previousText: prev.text, overlapSeconds: overlap
            )
            if deduped != seg.text, let idx = manifest.segments.firstIndex(where: { $0.sequence == j }) {
                manifest.segments[idx] = MeetingTranscriptSegment(
                    id: seg.id, meetingID: seg.meetingID, sequence: seg.sequence,
                    startOffset: seg.startOffset, endOffset: seg.endOffset,
                    sourceLabel: seg.sourceLabel, text: deduped, isFinal: seg.isFinal)
                changed = true
            }
        }
        if changed {
            if spansDeriveFromTypedSegments {
                let ordered = manifest.segments.sorted { $0.sequence < $1.sequence }
                manifest.segments = ordered
                manifest.transcriptSpans = ordered.map { "[Segment \($0.sequence + 1)] \($0.text)" }
                transcriptText = ordered.map { $0.text }.joined(separator: "\n\n")
            }
            // Wave-6 (3865593045): propagate the save failure to the caller.
            try store.saveManifest(manifest)
        }
    }

/// Writes one segment's transcript to transcriptText + the manifest.
    /// This is the ONLY place durable accounting advances.
    private func persistSegment(index: Int, segment: MeetingTranscriptSegment, wasDedupedLive: Bool = false) {
        store.withManifestTransaction(meetingID: segment.meetingID) {
            persistSegmentInTransaction(index: index, segment: segment, wasDedupedLive: wasDedupedLive)
        }
    }

    private func persistSegmentInTransaction(index: Int, segment: MeetingTranscriptSegment, wasDedupedLive: Bool) {
        var segment = segment
        var trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty transcripts resolve the index without writing anything.
            persistedSegmentIndices.insert(index)
            // Wave-5 (3865416022): an empty predecessor needs no dedup — fire
            // any held tap for the next chunk immediately.
            drainPendingLiveTap(after: index, manifest: nil)
            return
        }

        // Wave-16 (3838384606): durable accounting advances ONLY after the
        // manifest actually saves. A failed load or save leaves the index
        // unresolved and retryable - never a hollow .completed.
        guard var manifest = try? store.load(meetingID: segment.meetingID) else {
            return
        }

        // Wave-2 (3876240282): under neverStoreTranscript the transcript is
        // NEVER written durably - resolve the index without appending text
        // (the policy is enforced here, on the persistence path, not just by
        // a later pruning pass). transcriptText stays empty too.
        if manifest.retentionPolicy == .neverStoreTranscript {
            persistedSegmentIndices.insert(index)
            // Wave-9 (3876794393): record the durable per-index retry-success
            // marker (event only - NO transcript text is stored) so the
            // finalize route can verify every preserved chunk was retried.
            if var ev = try? store.load(meetingID: segment.meetingID) {
                ev.events.append("NEVER_STORE_RETRY_OK:\(index)")
                try? store.saveManifest(ev)
            }
            // Wave-8 (3876762099): cache the predecessor BEFORE draining any
            // deferred overlap tap - the drain calls dedupText, which needs
            // the predecessor to be findable. Wave-7 (3876716820) placed this
            // after the drain, so a deferred tap still could not dedup.
            neverStorePredecessorText[index] = trimmed
            drainPendingLiveTap(after: index, manifest: manifest)
            // Wave-6 (3876623266): still show the LIVE transcript during the
            // current meeting (in-memory only) - the Start dialog promises it
            // and the view would otherwise stay on "Listening...". Nothing
            // is written durably.
            // Wave-11 (3876962660): apply the cached predecessor to the LIVE
            // text too. drainPendingLiveTap deduplicates only the tap copy, so
            // a buffered out-of-order chunk that arrived BEFORE its
            // predecessor (wasDedupedLive == false) would otherwise repeat the
            // overlap here. Mirrors the ordinary persistence-time dedup below.
            let liveText = wasDedupedLive
                ? trimmed
                : dedupText(trimmed, at: index, meetingID: segment.meetingID, manifest: manifest)
            if transcriptText.isEmpty {
                transcriptText = liveText
            } else {
                // Real newline separator (the prior escaped text rendered a
                // literal backslash-n pair into the live transcript).
                transcriptText += "\n\n" + liveText
            }
            return
        }

        // Wave-2 (3864613545) + wave-3 (3864858081): exact-match trim the
        // duplicated overlap head. The boundary comes from the live recorder
        // OR the persisted manifest copy (recovery path).
        // Wave-6 (3865593065): a segment already deduped on the LIVE path is
        // NOT trimmed again here — applying the same transformation twice
        // deletes the speaker's genuine repeated word (e.g. "go go now"
        // after "go" would become "now"). Only trim when the segment was NOT
        // deduped live.
        var deduped = trimmed
        if !wasDedupedLive {
            deduped = dedupText(trimmed, at: index, meetingID: segment.meetingID, manifest: manifest)
        }
        if deduped != trimmed {
            trimmed = deduped
            // Rebuild the segment with the trimmed text but the SAME stable
            // id (wave-7 3836115274) so the durable record still matches
            // what the live tap carried.
            segment = MeetingTranscriptSegment(
                id: segment.id, meetingID: segment.meetingID, sequence: segment.sequence,
                startOffset: segment.startOffset, endOffset: segment.endOffset,
                sourceLabel: segment.sourceLabel, text: deduped, isFinal: segment.isFinal)
        }
        // Wave-3 (3864858088): populate span offsets from the chunk boundary
        // if the durable segment did not already carry them.
        if segment.startOffset == nil || segment.endOffset == nil {
            let o = offsets(at: index, manifest: manifest)
            if o.0 != nil || o.1 != nil {
                segment = MeetingTranscriptSegment(
                    id: segment.id, meetingID: segment.meetingID, sequence: segment.sequence,
                    startOffset: o.0, endOffset: o.1,
                    sourceLabel: segment.sourceLabel, text: segment.text, isFinal: segment.isFinal)
            }
        }

        if transcriptText.isEmpty {
            transcriptText = trimmed
        } else {
            transcriptText += "\n\n" + trimmed
        }

        do_w16: do {
            // Wave-3 review: legacy (v1) manifests carry transcriptSpans
            // verbatim with NO typed segments (MeetingSession.swift L220-225,
            // L345-361). Never rebuild those - append only, per the
            // "preserved verbatim" invariant.
            // Rebuild is safe ONLY when the existing spans are exactly the
            // spans derivable from the typed segments (true under every
            // this-PR writer). Mere count equality is unsound: #34's
            // appendSegment writes typed segments independently of legacy
            // spans, so a mixed migrated manifest can have equal counts
            // without correspondence. Anything else: append-only.
            let spansDeriveFromTypedSegments =
                manifest.transcriptSpans == manifest.segments.map {
                    "[Segment \($0.sequence + 1)] \($0.text)"
                }

            // Wave-7 (3836115274): append the SAME durable instance the
            // live tap already saw - one stable id end-to-end.
            manifest.segments.append(segment)

            if spansDeriveFromTypedSegments {
                // Wave-2 review: a hole recovered AFTER a lossless flush
                // appends a lower sequence than already-persisted segments.
                // Normalize by sequence so transcriptText/spans/segments
                // always read in true segment order (no-op for the normal
                // in-order append path).
                let ordered = manifest.segments.sorted { $0.sequence < $1.sequence }
                manifest.segments = ordered
                manifest.transcriptSpans = ordered.map { "[Segment \($0.sequence + 1)] \($0.text)" }
                transcriptText = ordered.map { $0.text }.joined(separator: "\n\n")
            } else {
                // Legacy manifest: preserve existing spans verbatim and append
                // the new span. transcriptText was already grown above - the
                // rebuild branch overwrites it wholesale; this one must not
                // append again (wave-4 review: double append).
                manifest.transcriptSpans.append("[Segment \(index + 1)] \(trimmed)")
            }
            // Wave-16 (3838384606): a failed save (disk full, unwritable
            // directory) must NOT resolve the index.
            do { try store.saveManifest(manifest) } catch { break do_w16 }
            // Wave-3 (3864858099): if `index` was a recovered hole, successors
            // persisted earlier may still carry undeduped overlap heads.
            // Wave-6 (3865593045) + wave-7 (3865753015): a failed successor
            // save must NOT resolve this index. The insert happens ONLY after
            // re-deduplication saves successfully — otherwise the index was
            // already in `persistedSegmentIndices` when the catch fired, so
            // finalization could still report completion with duplicated text
            // durable.
            do { try rededupPersistedSuccessors(in: &manifest, after: index) }
            catch { break do_w16 }
            persistedSegmentIndices.insert(index)
            // Wave-4 (3865266521): the predecessor just landed — fire any
            // held tap for the next chunk with its now-deduped text.
            drainPendingLiveTap(after: index, manifest: manifest)
            return
        }
        // Unreachable defensive tail (kept for clarity): no accounting
        // without a successful save.
    }

    /// Live-path runner: engine call, buffer the result; ordering is
    /// guaranteed by the drain. Failures surface an error and leave the
    /// index for the stop-time finalize retry.
    private func runLiveSegment(
        url: URL, index: Int, meetingID: String, generation: UUID
    ) async {
        let started = ProcessInfo.processInfo.systemUptime
        defer { MeetingPerformance.record("transcription-to-interface", since: started) }
        // AGENTS.md L39-42: Parakeet owns live transcription; no production
        // Gemma reasoning during recording. Live calls always run with
        // cleanup off - the configured mode applies only at finalize.
        switch await engineTranscribe(url: url, cleanupMode: .off) {
        case .success(let text):
            // Wave-7 (3836482855): ignore completions from a superseded
            // meeting generation (timed-out tasks on a reused transcriber).
            guard generation == meetingGeneration else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Wave-3 (3864858093): dedup BEFORE buffering/tap so the live
            // tap never fires the duplicated overlap head (an invocation
            // there must not trigger twice).
            let deduped = dedupText(trimmed, at: index, meetingID: meetingID, manifest: nil)
            let o = offsets(at: index, manifest: nil)
            let segment = MeetingTranscriptSegment(
                meetingID: meetingID,
                sequence: index,
                startOffset: o.0,
                endOffset: o.1,
                sourceLabel: "Room",
                text: deduped,
                isFinal: true
            )
            bufferedSegments[index] = BufferedSegment(
                segment: segment, fromLive: true, wasDeduped: deduped != trimmed
            )
            // Wave-7 (3834342735): the Observatory tap fires at
            // ENGINE-SUCCESS time, decoupled from ordered persistence - a
            // later segment's tap no longer waits behind an earlier hole,
            // and nothing taps after Stop. It carries the durable id that
            // persistence will write (3836115274).
            // Wave-8 (3837539271) + Wave-9 (3837588531): a call landing
            // after Stop began (recorder-await window OR finalize) must NOT
            // tap - the result is kept for persistence, the tap is
            // suppressed at the true Stop boundary.
            // Wave-4 (3865266521): only defer the tap when a REAL overlap
            // boundary needs dedup and the predecessor hasn't landed — then
            // hold the tap and fire it (deduped) once the predecessor is
            // persisted, so a spoken invocation in the overlap cannot
            // trigger twice. Without an overlap boundary (legacy/no chunk
            // metadata) the Wave-7 tap-at-engine-success behavior is
            // unchanged.
            if !isFinalizing && !suppressLiveTaps {
                let overlapBoundary = chunkBoundary(at: index - 1, manifest: nil)
                if index > 0, let overlapBoundary, overlapBoundary.availableOverlap > 0,
                   previousSegmentText(before: index, meetingID: meetingID) == nil {
                    pendingLiveTaps[index] = segment
                } else {
                    runLiveTapIfWired(segment)
                }
            }
            // Wave-8 (3837539268): a success arriving after an earlier
            // PERMANENT live failure must not sit volatile behind the hole -
            // flush durably now (ascending, lossless; the hole stays open
            // for the stop-time retry).
            if hasPermanentLiveHole(below: index) {
                flushBufferedSegmentsAscending()
            }
        case .failure(let failure):
            guard generation == meetingGeneration else { return }
            lastError = failure.message
            // Wave-7 (3834342743): a permanent live failure must not leave
            // later buffered successes volatile - flush them durably now
            // (ascending, lossless); this index stays open for the
            // stop-time retry.
            flushBufferedSegmentsAscending()
        }
    }

    /// Wave-4 (3865266521) + wave-5 (3865416022): fire a held tap once its
    /// predecessor has been persisted. An EMPTY predecessor needs no dedup,
    /// so the tap is released on that path too — it must never sit
    /// permanently un-fired.
    private func drainPendingLiveTap(after index: Int, manifest: MeetingManifest?) {
        guard let pending = pendingLiveTaps[index + 1] else { return }
        pendingLiveTaps[index + 1] = nil
        let d = dedupText(pending.text, at: index + 1, meetingID: pending.meetingID, manifest: manifest)
        var tappable = pending
        if d != pending.text {
            tappable = MeetingTranscriptSegment(
                id: pending.id, meetingID: pending.meetingID, sequence: pending.sequence,
                startOffset: pending.startOffset, endOffset: pending.endOffset,
                sourceLabel: pending.sourceLabel, text: d, isFinal: pending.isFinal)
        }
        if !isFinalizing && !suppressLiveTaps {
            runLiveTapIfWired(tappable)
        }
    }

    /// Wrapper so a surfaced message can ride in a Result's error position.
    private struct PersistFailure: Error { let message: String }

    /// One engine call returning the segment's OWN transcript text (never a
    /// reconstructed tail). Success with empty text is still success.
    private func engineTranscribe(
        url: URL,
        cleanupMode mode: TranscriptionCleanupMode
    ) async -> Result<String, PersistFailure> {
        let started = ProcessInfo.processInfo.systemUptime
        defer { MeetingPerformance.record("transcription-engine", since: started) }
        do {
            let payload = try await engine.transcribe(
                audioURL: url,
                modelIdentifier: modelIdentifier,
                formattingEnabled: formattingEnabled,
                vocabularyCorrectionsEnabled: vocabularyEnabled,
                customDictionaryURL: customDictionaryURL,
                cleanupMode: mode
            )
            return .success(payload.text)
        } catch {
            return .failure(PersistFailure(
                message: "Transcription failed: \(error.localizedDescription)"
            ))
        }
    }

    /// Fires the opt-in live tap (#299/#309 Observatory). Nil in tests.
    private func runLiveTapIfWired(_ segment: MeetingTranscriptSegment) {
        guard let liveSegmentTap else { return }
        // Wave-14 (3838221468): the tap task may start AFTER stopLiveTaps()
        // latched (task scheduling vs the Stop boundary race). Recheck the
        // latch inside the task so no Observatory intake/indexing runs
        // after the user pressed Stop.
        let task = Task { [weak self] in
            guard let self, !self.suppressLiveTaps, !self.isFinalizing else { return }
            await liveSegmentTap(segment)
        }
        // Wave-15 (3838270695): track the tap so stopLiveTaps() can cancel
        // it if Stop lands while it is suspended inside ingest.
        liveTapTasks.append(task)
        Task { [weak self] in _ = await task.value; self?.liveTapTasks.removeAll { $0 == task } }
    }
/// Compatibility entry used by existing finalization tests: transcribes
    /// [fromIndex, toIndex) through the ordered persistence path with
    /// persist-success-only accounting.
    func transcribeSegmentRange(
        meetingID: String,
        fromIndex: Int,
        toIndex: Int
    ) async -> MeetingFinalizationResult {
        var transcribed = 0
        var firstError: String?
        for index in fromIndex..<toIndex {
            let segmentURL = store.audioSegmentURL(for: meetingID, segmentIndex: index)
            guard FileManager.default.fileExists(atPath: segmentURL.path) else {
                persistedSegmentIndices.insert(index)
                missingAudioSegmentIndices.insert(index)
                continue
            }
            // Wave-5: engine-level cleanup is Parakeet-only everywhere;
            // selected cleanup runs post-Stop as a coordinator revision.
            switch await engineTranscribe(url: segmentURL, cleanupMode: .off) {
            case .success(let text):
                transcribed += 1
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                bufferedSegments[index] = BufferedSegment(
                    segment: MeetingTranscriptSegment(
                        meetingID: meetingID,
                        sequence: index,
                        sourceLabel: "Room",
                        text: trimmed,
                        isFinal: true
                    ),
                    fromLive: false,
                    wasDeduped: false
                )
            case .failure(let failure):
                if firstError == nil { firstError = failure.message }
            }
        }

        let holes = (fromIndex..<toIndex).filter {
            bufferedSegments[$0] == nil && !persistedSegmentIndices.contains($0)
        }
        if holes.isEmpty {
            // Wave-7 (3834342748): drain relative to the REQUESTED range.
            drainOrderedBuffer(from: fromIndex)
            // Wave-22 (3839803892): a save can fail DURING the drain -
            // recompute persisted coverage before deciding the verdict, same
            // guard performFinalization gained (wave-17).
            let stillUnpersisted = (fromIndex..<toIndex).filter {
                !persistedSegmentIndices.contains($0)
            }
            if stillUnpersisted.isEmpty {
                return .completed(transcribedSegmentCount: transcribed)
            }
            let numbers = stillUnpersisted.map { $0 + 1 }.sorted()
            let msg = "Transcription could not be saved "
                + "(unresolved segment\(numbers.count == 1 ? "" : "s"): "
                + "\(numbers.map(String.init).joined(separator: ", ")))"
            lastError = msg
            return .failed(transcribedSegmentCount: transcribed, lastError: msg)
        }
        flushBufferedSegmentsAscending()
        // Wave-22 (3839803892): recompute unresolved AFTER the flush too - a
        // save that fails inside the flush must be named in the failure.
        let unresolvedAfterFlush = (fromIndex..<toIndex).filter {
            !persistedSegmentIndices.contains($0)
        }
        // Wave-7 (3836115275): always NAME the unresolved segments; keep
        // the engine's error when one exists.
        let unresolvedNumbers = unresolvedAfterFlush.map { $0 + 1 }.sorted()
        let message = "\(firstError ?? "Transcription failed") "
            + "(unresolved segment\(unresolvedNumbers.count == 1 ? "" : "s"): "
            + "\(unresolvedNumbers.map(String.init).joined(separator: ", ")))"
        lastError = message
        return .failed(transcribedSegmentCount: transcribed, lastError: message)
    }
}
