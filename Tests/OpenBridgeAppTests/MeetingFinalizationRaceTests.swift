import Testing
import Foundation
@testable import OpenBridgeApp

// MARK: - #303 race test doubles

/// Engine double with per-segment gates, implemented as an actor so its
/// state is async-safe without locks. A call for a segment that has not
/// been released PARKS until the test releases that segment; released
/// segments (and `openAll`) resolve immediately with the given result.
/// This makes "inference in flight at stop time" fully deterministic.
actor GatedMeetingEngine: MeetingEngine {
    private var calls: [URL] = []
    private var callCleanupModes: [TranscriptionCleanupMode] = []
    /// Parked calls keyed by FULL segment path so two meetings reusing the
    /// same segment file NAME stay independently controllable (Round 7).
    private var parked: [String: [CheckedContinuation<TranscriptPayload, Error>]] = [:]
    /// Immediate-resolve overrides keyed by full segment path (Round 7).
    private var openResults: [String: Result<TranscriptPayload, Error>] = [:]
    /// Legacy name-keyed overrides: releasing a name also resolves future
    /// calls with that file name (pre-Round-7 semantics, kept intact for
    /// the name-based tests).
    private var openResultsByName: [String: Result<TranscriptPayload, Error>] = [:]
    private var defaultOpen: Result<TranscriptPayload, Error>?

    /// URLs the engine was asked to transcribe, in call order.
    func callURLs() -> [URL] {
        calls
    }

    /// Number of times a specific segment file was sent to the engine.
    func callCount(forSegmentNamed name: String) -> Int {
        calls.filter { $0.lastPathComponent == name }.count
    }

    /// Cleanup mode the engine was asked to use, per call, in order.
    func recordedCleanupModes() -> [TranscriptionCleanupMode] {
        callCleanupModes
    }

    /// Resume every parked call for `name` and resolve all future calls for
    /// that segment with `result`.
    func release(segment name: String, with result: Result<TranscriptPayload, Error>) {
        let matchingPaths = parked.keys.filter { URL(fileURLWithPath: $0).lastPathComponent == name }
        var waiters: [CheckedContinuation<TranscriptPayload, Error>] = []
        for path in matchingPaths {
            waiters.append(contentsOf: parked[path] ?? [])
            parked[path] = []
            openResults[path] = nil
        }
        openResultsByName[name] = result
        resume(waiters, with: result)
    }

    /// Round 7: resume the parked call(s) for one EXACT segment path and
    /// resolve future calls for that exact path with `result`. Other
    /// meetings' calls that merely share the file NAME stay parked.
    func release(path: String, with result: Result<TranscriptPayload, Error>) {
        let waiters = parked[path] ?? []
        parked[path] = []
        openResults[path] = result
        resume(waiters, with: result)
    }

    /// Clear a per-segment override so future calls for that segment park
    /// again (lets a test fail a segment live, then succeed on retry).
    func reset(segment name: String) {
        openResultsByName[name] = nil
        let matchingPaths = openResults.keys.filter { URL(fileURLWithPath: $0).lastPathComponent == name }
        for path in matchingPaths {
            openResults[path] = nil
        }
    }

    /// Resume every parked call, whatever its segment, and resolve ALL
    /// future calls with `result`.
    func openAll(with result: Result<TranscriptPayload, Error>) {
        let allWaiters = parked.values.flatMap { $0 }
        parked = [:]
        openResults = [:]
        openResultsByName = [:]
        defaultOpen = result
        resume(allWaiters, with: result)
    }

    /// Round 7 / wave-7 review: bounded, awaitable "call(s) arrived" signal
    /// so tests never rely on fixed sleeps before asserting launch counts.
    /// Returns true once at least `expected` engine calls were recorded,
    /// false if the timeout elapsed first.
    func awaitCallCount(
        _ expected: Int,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while calls.count < expected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return calls.count >= expected
    }

    private func resume(
        _ waiters: [CheckedContinuation<TranscriptPayload, Error>],
        with result: Result<TranscriptPayload, Error>
    ) {
        for continuation in waiters {
            switch result {
            case .success(let payload): continuation.resume(returning: payload)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    func transcribe(
        audioURL: URL,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> TranscriptPayload {
        let path = audioURL.path
        let name = audioURL.lastPathComponent
        calls.append(audioURL)
        callCleanupModes.append(cleanupMode)
        let direct = openResults[path] ?? openResultsByName[name] ?? defaultOpen

        if let direct {
            switch direct {
            case .success(let payload): return payload
            case .failure(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            parked[path, default: []].append(continuation)
        }
    }
}

/// Scripted segment source standing in for `MeetingRecorder`: the test moves
/// `completedSegmentCount` exactly like a timer tick (or stop-time
/// finalization) would observe the recorder.
@MainActor
final class ScriptedSegmentSource: MeetingSegmentSource {
    var completedSegmentCount: Int
    init(completedSegmentCount: Int = 0) {
        self.completedSegmentCount = completedSegmentCount
    }
}

/// Mutable box so the test can observe whether finalize has returned while
/// other work is still in flight. Tasks inheriting @MainActor read/write it.
@MainActor
final class FinalizeDoneBox {
    private(set) var result: MeetingFinalizationResult?
    var hasResult: Bool { result != nil }

    func record(_ r: MeetingFinalizationResult) {
        result = r
    }
}

// MARK: - #303 race regression suite

/// Regression tests for the finalization race (Beta #303 acceptance reset):
/// live transcription must not advance durable accounting past unresolved
/// work; stop must await all in-flight segment tasks and retry anything not
/// persisted before completion is allowed.
@Suite(.serialized) struct MeetingFinalizationRaceTests {

    @MainActor
    private func makeMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, meetingID: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Test", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return (store, manifest.meetingID, root)
    }

    /// Stop while a live task is parked on segment 0 and stop finalizes
    /// segment 1. Releasing ONLY segment 1 must not let finalize return —
    /// completion is forbidden while segment 0's work is unresolved. After
    /// segment 0 resolves: exactly one engine call per segment, both spans
    /// persisted BEFORE finalize returns.
    @MainActor
    @Test func stopDuringDelayedLiveSuccessCannotCompleteEarlyOrDuplicate() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // Timer tick observes segment 0 finalized → live task launched and
        // PARKED inside the engine (inference in flight).
        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)

        #expect(await engine.awaitCallCount(1, timeout: 30))
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)

        // Stop: segment 1 finalizes at stop (count 1 → 2) while segment 0's
        // inference is still parked.
        source.completedSegmentCount = 2
        let doneBox = FinalizeDoneBox()
        let finalizeTask = Task { () -> MeetingFinalizationResult in
            let r = await transcriber.finalizeAndTranscribe(recorder: source, meetingID: fixture.meetingID)
            doneBox.record(r)
            return r
        }

        // Give finalize the chance to (wrongly) finish segment 1 alone.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Segment 1 resolves successfully — but segment 0 is still in flight.
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "tail text")))
        try await Task.sleep(nanoseconds: 300_000_000)

        // FIXED behavior: finalize must NOT have returned — segment 0's work
        // is unresolved, so completion is not allowed yet.
        #expect(doneBox.hasResult == false)

        // Now segment 0 resolves successfully.
        await engine.release(segment: "segment_0000.wav", with: .success(TranscriptPayload(text: "head text")))

        let result = await finalizeTask.value
        guard case .completed(let count) = result else {
            Issue.record("Expected .completed after all live work resolved, got \(result)")
            return
        }
        #expect(count == 2)

        // Exact-once: each segment file sent to the engine exactly once.
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 1)

        // Both spans persisted BEFORE finalize returned (stop-time durability).
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 2)
        #expect(manifest.segments.count == 2)
    }

    /// Delayed live FAILURE on the meeting's only segment (sub-60s shape).
    /// Finalize must await the failing task, retry the un-persisted segment
    /// once, and report .failed — never Completed. Audio stays on disk.
    @MainActor
    @Test func stopDuringDelayedLiveFailureKeepsRecoveryStateAndRetries() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(1, timeout: 30))
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)

        // Stop while the only segment's inference is parked.
        let doneBox = FinalizeDoneBox()
        let finalizeTask = Task { () -> MeetingFinalizationResult in
            let r = await transcriber.finalizeAndTranscribe(recorder: source, meetingID: fixture.meetingID)
            doneBox.record(r)
            return r
        }

        // The live task fails late, after stop already started.
        await engine.release(
            segment: "segment_0000.wav",
            with: .failure(EngineServiceError.processFailed("late live failure"))
        )

        let result = await finalizeTask.value

        guard case .failed(let count, let error) = result else {
            Issue.record("Expected .failed when the in-flight live work failed, got \(result)")
            return
        }
        #expect(count == 0)
        #expect(!error.isEmpty)

        // The failed index must have been re-attempted at finalize (initial
        // live call + one finalize retry).
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 2)

        // Nothing persisted; audio preserved for recovery.
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.isEmpty)
        let audio = fixture.store.audioSegmentURL(for: fixture.meetingID, segmentIndex: 0)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    /// The 65-second shape with a NONZERO completed-segment baseline: live
    /// transcription finishes segment 0 before stop; stop finalizes segment
    /// 1; each segment is transcribed exactly once.
    @MainActor
    @Test func sixtyFiveSecondMeetingTranscribesBothSegmentsExactlyOnce() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        await engine.release(segment: "segment_0000.wav", with: .success(TranscriptPayload(text: "first minute")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // First tick: segment 0 finalized; its live transcription runs to
        // completion immediately (gate already open for it).
        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)

        // Await segment 0's persistence landing in the manifest.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try fixture.store.load(meetingID: fixture.meetingID)).transcriptSpans.count == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Stop at 65s: segment 1 finalizes; finalize transcribes the tail.
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "final five seconds")))
        source.completedSegmentCount = 2
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )

        guard case .completed(let count) = result else {
            Issue.record("Expected .completed for the 65s meeting, got \(result)")
            return
        }
        #expect(count == 2)

        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 1)

        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 2)
        #expect(manifest.segments.count == 2)
    }

    /// A failed finalize must leave the failed segment retriable: after the
    /// engine recovers, a second finalize re-attempts the segment and
    /// succeeds — proving failures are never permanently skipped.
    @MainActor
    @Test func failedFinalizeIsRetriedAndSucceedsAfterEngineRecovery() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .failure(EngineServiceError.processFailed("engine down")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        let first = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )
        guard case .failed = first else {
            Issue.record("Expected first finalize to fail while engine is down")
            return
        }
        // At least one attempt was made for the segment.
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") >= 1)

        // Engine recovers (same transcriber, as recovery-within-session).
        await engine.openAll(with: .success(TranscriptPayload(text: "recovered")))

        // A second finalize (the recovery retry) must re-attempt the segment
        // and persist its transcript.
        let second = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )
        guard case .completed(let count) = second else {
            Issue.record("Expected retry finalize to succeed after engine recovery, got \(second)")
            return
        }
        #expect(count == 1)

        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 1)
        #expect(manifest.transcriptSpans.first?.contains("recovered") == true)
    }
}// MARK: - Round 2 (PR #67 Codex review): launch-storm and ordering guards

/// Second-wave regressions from the Codex review of PR #67: ticks during
/// finalize must not duplicate in-flight work; a failed live segment must
/// not be relaunched on every meter tick; persistence must stay in segment
/// order even when inference completes out of order.
@Suite(.serialized) struct MeetingFinalizationRaceTestsRound2 {

    @MainActor
    private func makeMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, meetingID: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race2-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Round 2", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return (store, manifest.meetingID, root)
    }

    /// Codex #1: while finalize awaits in-flight work, the meter timer keeps
    /// ticking. Ticks during finalize must NOT launch duplicate segment
    /// tasks, and finalize must still await everything launched.
    @MainActor
    @Test func ticksDuringFinalizeCannotLaunchDuplicateWork() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(1, timeout: 30))

        source.completedSegmentCount = 2
        let finalizeTask = Task { () -> MeetingFinalizationResult in
            await transcriber.finalizeAndTranscribe(recorder: source, meetingID: fixture.meetingID)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Meter ticks fire while finalize is awaiting the parked segment.
        for _ in 0..<5 {
            transcriber.checkForNewSegments(recorder: source)
        }

        // No duplicates behind finalize's back: segment 0 is the single
        // in-flight task; segment 1 has NOT been launched by the ticks
        // (finalize owns the stop-tail launch in its retry pass).
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 0)

        await engine.openAll(with: .success(TranscriptPayload(text: "resolved")))

        let result = await finalizeTask.value
        guard case .completed(let count) = result else {
            Issue.record("Expected .completed, got \(result)")
            return
        }
        #expect(count == 2)
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 1)
    }

    /// Codex #2: a live engine failure must not be re-submitted on every
    /// meter tick while recording continues. Exactly one live attempt;
    /// stop-time finalize is the retry path.
    @MainActor
    @Test func failedLiveSegmentIsNotRelaunchedEveryTick() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .failure(EngineServiceError.processFailed("engine down")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 1)

        // Meter ticks keep firing for the rest of the meeting.
        for _ in 0..<5 {
            transcriber.checkForNewSegments(recorder: source)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // One live attempt only - no relaunch storm.
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)

        // Engine recovers; stop-time finalize retries exactly once and
        // completes the meeting.
        await engine.openAll(with: .success(TranscriptPayload(text: "recovered")))
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )
        guard case .completed(let count) = result else {
            Issue.record("Expected .completed after engine recovery, got \(result)")
            return
        }
        #expect(count == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 2)
    }

    /// Codex #4: inference stays concurrent, but persistence is strictly
    /// ordered by segment index. A faster later segment must not display or
    /// persist before an earlier in-flight segment.
    @MainActor
    @Test func outOfOrderCompletionPersistsInSegmentOrder() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // Both segments finalized; both live tasks launch concurrently and
        // park inside the engine.
        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        transcriber.checkForNewSegments(recorder: source)

        // Wave-7: await both launches deterministically instead of sleeping.
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Proof of concurrency: both engine calls are in flight.
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 1)

        // Segment 1 finishes FIRST (out of order).
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "second segment")))
        try await Task.sleep(nanoseconds: 300_000_000)

        // Segment 1 must NOT be persisted while segment 0 is unresolved.
        #expect(transcriber.transcriptText.contains("second segment") == false)
        let earlyManifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(earlyManifest.transcriptSpans.isEmpty)

        // Segment 0 finishes; both must now appear in index order 0, 1.
        await engine.release(segment: "segment_0000.wav", with: .success(TranscriptPayload(text: "first segment")))
        try await Task.sleep(nanoseconds: 100_000_000)

        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 2)
        #expect(manifest.transcriptSpans.first?.contains("first segment") == true)
        #expect(manifest.transcriptSpans.last?.contains("second segment") == true)
        #expect(manifest.segments.map(\.sequence) == [0, 1])
    }

    /// A long engine stall may queue many finalized chunks, but only the fixed
    /// number of Parakeet calls may run at once. Completing one call pulls the
    /// next queued chunk without waiting for another meter tick.
    @MainActor
    @Test func liveInferenceConcurrencyIsBoundedAndDrainsQueue() async throws {
        let fixture = try makeMeeting(segmentCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.maxConcurrentLiveTranscriptions = 2
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 3)
        transcriber.checkForNewSegments(recorder: source)

        #expect(await engine.awaitCallCount(2, timeout: 30))
        #expect(await engine.callURLs().count == 2)
        #expect(await engine.callCount(forSegmentNamed: "segment_0002.wav") == 0)

        await engine.release(
            segment: "segment_0000.wav",
            with: .success(TranscriptPayload(text: "first"))
        )
        #expect(await engine.awaitCallCount(3, timeout: 30))
        #expect(await engine.callCount(forSegmentNamed: "segment_0002.wav") == 1)

        await engine.openAll(with: .success(TranscriptPayload(text: "done")))
    }

    @MainActor
    @Test func stopLatchPreventsAutomaticQueueRefill() async throws {
        let fixture = try makeMeeting(segmentCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.maxConcurrentLiveTranscriptions = 2
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 3)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // This is the exact user-visible Stop boundary, before recorder Stop
        // and finalization have finished their awaits.
        transcriber.stopLiveTaps()
        await engine.release(
            segment: "segment_0000.wav",
            with: .success(TranscriptPayload(text: "first"))
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await engine.callURLs().count == 2)
        #expect(await engine.callCount(forSegmentNamed: "segment_0002.wav") == 0)
        await engine.openAll(with: .success(TranscriptPayload(text: "done")))
    }

    @MainActor
    @Test func captureFailureCancellationFreesNextMeetingWorkerSlots() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.maxConcurrentLiveTranscriptions = 2
        transcriber.start(meetingID: fixture.meetingID)
        transcriber.checkForNewSegments(
            recorder: ScriptedSegmentSource(completedSegmentCount: 2)
        )
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Recorder failure abandons the session while both engine calls are
        // still parked. Their tasks may ignore cancellation, but their old
        // dictionary entries must not reserve the next meeting's two slots.
        transcriber.cancelLiveWorkAfterCaptureFailure()

        let nextManifest = MeetingManifest(title: "Next Meeting", state: .recording)
        try fixture.store.create(nextManifest)
        for index in 0..<2 {
            try Data("next-\(index)".utf8).write(
                to: fixture.store.audioSegmentURL(
                    for: nextManifest.meetingID,
                    segmentIndex: index
                )
            )
        }
        transcriber.start(meetingID: nextManifest.meetingID)
        transcriber.checkForNewSegments(
            recorder: ScriptedSegmentSource(completedSegmentCount: 2)
        )

        #expect(await engine.awaitCallCount(4, timeout: 30))
        let paths = await engine.callURLs().map(\.path)
        #expect(paths.filter { $0.contains(nextManifest.meetingID) }.count == 2)
        await engine.openAll(with: .success(TranscriptPayload(text: "done")))
    }
}
// MARK: - Round 3 (Codex review wave 2): retry-skip, flush-order, Gemma serialization

@Suite(.serialized) struct MeetingFinalizationRaceTestsRound3 {

    @MainActor
    private func makeMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, meetingID: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race3-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Round 3", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return (store, manifest.meetingID, root)
    }

    /// Wave-7 fix (P2 3836503102): the stored post-meeting cleanup
    /// preference must NOT serialize live Parakeet launches. Live calls
    /// always run the engine with cleanup `.off` (AGENTS.md L39-42), so a
    /// Fast/Careful selection protects no live Gemma work and deferring
    /// later segments only builds an unnecessary backlog. Live inference
    /// stays concurrent regardless of the selected mode.
    @MainActor
    @Test func cleanupModeDoesNotSerializeLiveLaunches() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            cleanupMode: .fast,
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // Both segments finalized; both live tasks must launch CONCURRENTLY
        // even under a Gemma post-meeting cleanup mode.
        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        transcriber.checkForNewSegments(recorder: source)

        // Wave-7: await the launches deterministically instead of sleeping.
        // 30s bound: the full-suite run schedules suites in parallel, so
        // MainActor task startup can take seconds under load (same lesson
        // as waitForRail's CI-load budget).
        #expect(await engine.awaitCallCount(2, timeout: 30))
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 1)

        // Cleanup preference must never reach the live engine calls.
        let modes = await engine.recordedCleanupModes()
        #expect(modes == [.off, .off])

        await engine.openAll(with: .success(TranscriptPayload(text: "resolved")))
    }

    /// Wave-2 finding B (P2): a segment already buffered (succeeded live
    /// behind an earlier hole) must NOT be re-transcribed by finalize's
    /// retry pass. Exactly-once inference even across the hole.
    @MainActor
    @Test func finalizeRetrySkipsBufferedSuccesses() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Segment 0 fails live (fast failure, gate open with failure).
        await engine.release(segment: "segment_0000.wav", with: .failure(EngineServiceError.processFailed("engine down")))
        // Segment 1 succeeds live - its text buffers behind the hole.
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "later segment")))
        try await Task.sleep(nanoseconds: 100_000_000)

        // Stop. Only segment 0 retries (engine now healthy for it);
        // segment 1's buffered success must be kept, never re-run.
        await engine.release(segment: "segment_0000.wav", with: .success(TranscriptPayload(text: "earlier segment")))
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )

        guard case .completed = result else {
            Issue.record("Expected .completed after hole recovery, got \(result)")
            return
        }
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 2)
        #expect(await engine.callCount(forSegmentNamed: "segment_0001.wav") == 1)

        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 2)
        #expect(manifest.segments.map(\.sequence) == [0, 1])
    }

    /// Wave-2 finding C (P2): after a lossless flush persists later
    /// segments past a permanent hole, a later recovery of the hole must
    /// leave the final transcript in true segment order - not appended
    /// after the flushed segments.
    @MainActor
    @Test func recoveryAfterFlushRestoresSegmentOrder() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Segment 0 fails live; segment 1 succeeds and buffers.
        await engine.release(segment: "segment_0000.wav", with: .failure(EngineServiceError.processFailed("engine down")))
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "later segment")))
        try await Task.sleep(nanoseconds: 100_000_000)

        // Stop with segment 0 STILL failing: flush persists segment 1
        // losslessly and reports .failed.
        let first = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )
        guard case .failed = first else {
            Issue.record("Expected .failed while hole persists, got \(first)")
            return
        }
        var manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 1)

        // Engine recovers; the recovery finalize fills the hole. The final
        // transcript must read in true order: hole text first, then the
        // flushed later segment.
        await engine.openAll(with: .success(TranscriptPayload(text: "earlier segment")))
        let second = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )
        guard case .completed = second else {
            Issue.record("Expected .completed after recovery, got \(second)")
            return
        }

        manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 2)
        #expect(manifest.segments.map(\.sequence) == [0, 1])
        #expect(manifest.segments.first?.text == "earlier segment")
        #expect(manifest.segments.last?.text == "later segment")
        #expect(transcriber.transcriptText.hasPrefix("earlier segment"))
    }
}
import Testing
import Foundation
@testable import OpenBridgeApp

// MARK: - Round 4 (Codex review wave 3): legacy span preservation

@Suite(.serialized) struct MeetingFinalizationRaceTestsRound4 {

    @MainActor
    private func makeMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, meetingID: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race4-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Round 4", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return (store, manifest.meetingID, root)
    }

    /// Wave-3 finding: persisting into a LEGACY manifest (typed segments
    /// empty, transcriptSpans populated verbatim per MeetingSession.swift
    /// L220-221 / L345-361) must never rebuild/erase those legacy spans.
    @MainActor
    @Test func legacySpansSurviveOrderedRebuild() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Simulate a legacy (v1) meeting: spans present, NO typed segments.
        var legacy = try fixture.store.load(meetingID: fixture.meetingID)
        legacy.transcriptSpans = ["[Segment 1] old first", "[Segment 2] old second"]
        legacy.segments = []
        try fixture.store.saveManifest(legacy)

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .success(TranscriptPayload(text: "newly transcribed")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // One retry-path persist into the legacy manifest.
        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        _ = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: fixture.meetingID
        )

        // The legacy spans MUST survive verbatim, with new spans appended
        // (two segments finalize => two appends).
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 4)
        #expect(manifest.transcriptSpans[0] == "[Segment 1] old first")
        #expect(manifest.transcriptSpans[1] == "[Segment 2] old second")
        #expect(manifest.transcriptSpans[2].contains("newly transcribed"))
        #expect(manifest.transcriptSpans[3].contains("newly transcribed"))

        // Wave-4 P2: each new segment must appear in the live transcript
        // exactly once (no double append through the legacy branch).
        let occurrences = transcriber.transcriptText.components(
            separatedBy: "newly transcribed"
        ).count - 1
        #expect(occurrences == 2)
    }
}

// MARK: - Round 5 (Codex review wave 4): live mode + legacy dedup

@Suite(.serialized) struct MeetingFinalizationRaceTestsRound5 {

    /// Wave-4/5: AGENTS.md L39-42 - Parakeet owns live transcription and
    /// cleanup never overwrites the canonical transcript (L40). The
    /// transcriber must send `.off` to the engine at EVERY call site - live
    /// and finalize alike; the selected cleanup belongs to the post-Stop
    /// coordinator revision flow, not engine-level finalize.
    @MainActor
    @Test func transcriberNeverSendsGemmaCleanupToEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race5-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Round 5", state: .recording)
        try store.create(manifest)
        try Data("synthetic-0".utf8).write(
            to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: 0)
        )

        let engine = GatedMeetingEngine()
        // Live attempt fails; the finalize retry succeeds.
        await engine.openAll(with: .failure(EngineServiceError.processFailed("down")))

        let transcriber = MeetingTranscriber(
            store: store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            cleanupMode: .fast,
            engine: engine
        )
        transcriber.start(meetingID: manifest.meetingID)

        // Live tick: engine must be invoked with cleanup `.off`.
        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(1, timeout: 30))
        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        var modes = await engine.recordedCleanupModes()
        #expect(modes == [.off])

        // Stop: the finalize retry must ALSO run raw - no engine-level
        // Gemma anywhere in the transcrier; selected cleanup runs post-Stop
        // as a coordinator revision over the complete transcript.
        await engine.openAll(with: .success(TranscriptPayload(text: "recovered")))
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: manifest.meetingID
        )
        guard case .completed = result else {
            Issue.record("Expected .completed, got \(result)")
            return
        }

        modes = await engine.recordedCleanupModes()
        #expect(modes == [.off, .off])
    }

    /// Wave-5 P2: a migrated manifest can carry legacy spans AND typed
    /// segments written independently (MeetingSessionStore.appendSegment),
    /// so counts can coincide without correspondence. Legacy spans must
    /// stay append-only regardless of counts.
    @MainActor
    @Test func mixedManifestSpansSurviveIndependentTypedSegments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race5b-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Mixed Legacy", state: .recording)
        try store.create(manifest)

        // Legacy spans...
        var legacy = try store.load(meetingID: manifest.meetingID)
        legacy.transcriptSpans = ["[Segment 1] old first", "[Segment 2] old second"]
        try store.saveManifest(legacy)
        // ...plus typed segments appended INDEPENDENTLY (#34 writer) so the
        // counts coincide (2 spans == 2 segments) without correspondence.
        try store.appendSegment(MeetingTranscriptSegment(
            meetingID: manifest.meetingID,
            sequence: 0,
            sourceLabel: "Room",
            text: "typed zero",
            isFinal: true
        ), meetingID: manifest.meetingID)
        try store.appendSegment(MeetingTranscriptSegment(
            meetingID: manifest.meetingID,
            sequence: 1,
            sourceLabel: "Room",
            text: "typed one",
            isFinal: true
        ), meetingID: manifest.meetingID)

        try Data("synthetic-0".utf8).write(
            to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: 0)
        )

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .success(TranscriptPayload(text: "newly transcribed")))

        let transcriber = MeetingTranscriber(
            store: store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: manifest.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        _ = await transcriber.finalizeAndTranscribe(
            recorder: source,
            meetingID: manifest.meetingID
        )

        // The independently-written legacy spans MUST survive verbatim with
        // the new span appended - never rebuilt from typed segments.
        let after = try store.load(meetingID: manifest.meetingID)
        #expect(after.transcriptSpans[0] == "[Segment 1] old first")
        #expect(after.transcriptSpans[1] == "[Segment 2] old second")
        #expect(after.transcriptSpans.count == 3)
        #expect(after.transcriptSpans[2].contains("newly transcribed"))
    }
}
// MARK: - Round 6 (Codex review wave 6): re-entrancy + bounded wait

@Suite(.serialized) struct MeetingFinalizationRaceTestsRound6 {

    @MainActor
    private func makeMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, meetingID: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race6-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Round 6", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return (store, manifest.meetingID, root)
    }

    /// Wave-6 P1a: a second Stop while the first finalization is awaiting
    /// must SHARE the in-progress finalization - exact-once despite re-entry.
    @MainActor
    @Test func reentrantStopSharesOneFinalization() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(1, timeout: 30))

        async let first = transcriber.finalizeAndTranscribe(
            recorder: source, meetingID: fixture.meetingID
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        async let second = transcriber.finalizeAndTranscribe(
            recorder: source, meetingID: fixture.meetingID
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        await engine.openAll(with: .success(TranscriptPayload(text: "only once")))
        let results = await [first, second]
        for result in results {
            guard case .completed = result else {
                Issue.record("Expected .completed, got \(result)")
                return
            }
        }

        #expect(await engine.callCount(forSegmentNamed: "segment_0000.wav") == 1)
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.segments.count == 1)
        #expect(manifest.transcriptSpans.count == 1)
    }

    /// Wave-6 P1b: Stop must not wait forever on a hung live task. At the
    /// wait budget, stuck indices are cancelled and reported as failures.
    @MainActor
    @Test func boundedStopWaitReportsFailure() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)
        transcriber.finalizationWaitTimeout = 0.3

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(1, timeout: 30))

        let outcome = await withRaceTimeout(seconds: 5) {
            await transcriber.finalizeAndTranscribe(
                recorder: source, meetingID: fixture.meetingID
            )
        }
        guard let result = outcome else {
            Issue.record("Finalize hung past its wait budget")
            await engine.openAll(with: .success(TranscriptPayload(text: "cleanup")))
            return
        }
        guard case .failed(_, let message) = result else {
            Issue.record("Expected .failed after wait budget, got \(result)")
            await engine.openAll(with: .success(TranscriptPayload(text: "cleanup")))
            return
        }
        #expect(message.contains("1"))
        await engine.openAll(with: .success(TranscriptPayload(text: "cleanup")))
    }
}

// MARK: - Round 7 (Codex review final batch): queued review fixes

/// RED-first proofs for the wave-7 queued fixes: generation isolation of
/// timed-out live tasks, failure messages naming unresolved segments,
/// clearing recovered errors, live taps at engine-success reusing the
/// persisted segment ID, durable flush of later successes after a live
/// failure, nonzero range starts, and the timeout race escaping
/// non-cooperative bodies.
@Suite(.serialized) struct MeetingFinalizationRaceTestsRound7 {

    @MainActor
    private func makeMeeting(
        segmentCount: Int
    ) throws -> (store: MeetingSessionStore, meetingID: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race7-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: root)
        let manifest = MeetingManifest(title: "Race Round 7", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return (store, manifest.meetingID, root)
    }

    /// Creates a SECOND meeting (own segment files at the same indices) in
    /// the same store, for reused-transcriber scenarios.
    @MainActor
    private func makeSecondMeeting(
        in store: MeetingSessionStore,
        segmentCount: Int
    ) throws -> String {
        let manifest = MeetingManifest(title: "Race Round 7 Second", state: .recording)
        try store.create(manifest)
        for index in 0..<segmentCount {
            try Data("synthetic-b\(index)".utf8).write(
                to: store.audioSegmentURL(for: manifest.meetingID, segmentIndex: index)
            )
        }
        return manifest.meetingID
    }

    /// Wave-7 P1 (3836482855): a live task that timed out at the stop wait
    /// budget is cancelled but may still be parked in the engine. When its
    /// late completion finally lands AFTER the user started a new meeting on
    /// the same transcriber, it must not steal the new meeting's in-flight
    /// registration or mutate its buffers - Stop must keep awaiting the NEW
    /// meeting's own work.
    @MainActor
    @Test func staleTimedOutTaskCannotStealNewMeetingsInFlightWork() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let meetingB = try makeSecondMeeting(in: fixture.store, segmentCount: 1)

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)
        // This is an ownership-isolation test, not a wall-clock benchmark.
        // Expire A's budget deterministically; a busy full suite must not race
        // the product's 300ms sleep against a separate five-second watchdog.
        transcriber.finalizationWaitTimeout = 0

        // Meeting A: live task parks on its segment 0; Stop times out.
        let sourceA = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: sourceA)
        #expect(await engine.awaitCallCount(1, timeout: 30))

        let first = await withRaceTimeout(seconds: 30) {
            await transcriber.finalizeAndTranscribe(
                recorder: sourceA, meetingID: fixture.meetingID
            )
        }
        guard case .failed = first else {
            Issue.record("Expected meeting A finalize to time out and fail")
            await engine.openAll(with: .success(TranscriptPayload(text: "cleanup")))
            return
        }

        // Restore the normal wait budget: only meeting A's phase needed the
        // tiny timeout; B's finalize must await B's own parked task fully.
        transcriber.finalizationWaitTimeout = 120

        // User starts meeting B on the SAME transcriber; its live task
        // parks (distinct path, same file NAME as A's segment 0).
        transcriber.start(meetingID: meetingB)
        let sourceB = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: sourceB)
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Stop B: finalize awaits B's OWN in-flight task.
        let doneBox = FinalizeDoneBox()
        let finalizeB = Task { () -> MeetingFinalizationResult in
            let r = await transcriber.finalizeAndTranscribe(recorder: sourceB, meetingID: meetingB)
            doneBox.record(r)
            return r
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // The STALE A task (cancelled, still parked) now completes with a
        // success - targeting ONLY A's exact segment path.
        let staleURL = fixture.store.audioSegmentURL(for: fixture.meetingID, segmentIndex: 0)
        await engine.release(path: staleURL.path, with: .success(TranscriptPayload(text: "stale A text")))
        try await Task.sleep(nanoseconds: 300_000_000)

        // FIXED: the stale completion is ignored - finalize for B is still
        // awaiting B's own task (registration intact).
        #expect(doneBox.hasResult == false)

        // B's own segment now resolves; finalize may complete.
        let urlB = fixture.store.audioSegmentURL(for: meetingB, segmentIndex: 0)
        await engine.release(path: urlB.path, with: .success(TranscriptPayload(text: "B text")))
        let resultB = await finalizeB.value
        guard case .completed(let countB) = resultB else {
            Issue.record("Expected .completed for meeting B, got \(resultB)")
            return
        }
        #expect(countB == 1)

        // B's manifest carries ONLY B's text; A's manifest gained nothing
        // from the stale completion.
        let manifestB = try fixture.store.load(meetingID: meetingB)
        #expect(manifestB.transcriptSpans.count == 1)
        #expect(manifestB.transcriptSpans.first?.contains("B text") == true)
        let manifestA = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifestA.transcriptSpans.isEmpty)
    }

    /// Wave-7 P2 (3836115275): a stop-time failure must NAME the unresolved
    /// segments in the user-visible error, not just the engine's message.
    @MainActor
    @Test func failureMessageNamesUnresolvedSegments() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .failure(EngineServiceError.processFailed("engine down")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source, meetingID: fixture.meetingID
        )

        guard case .failed(_, let message) = result else {
            Issue.record("Expected .failed while engine is down, got \(result)")
            return
        }
        // The message must keep the engine error AND append the unresolved
        // segment numbers (1-based, as users see them).
        #expect(message.contains("unresolved"))
        #expect(message.contains("1"))
        #expect(message.contains("2"))
    }

    /// Wave-7 P2 (3836115273): when a live failure left `lastError` set but
    /// the stop-time retry resolves every hole, the surfaced error must be
    /// cleared - a .completed verdict cannot keep reporting a stale failure.
    @MainActor
    @Test func completedFinalizeClearsStaleLiveError() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // Live attempt fails: lastError surfaces in the UI.
        await engine.openAll(with: .failure(EngineServiceError.processFailed("live failure")))
        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(1, timeout: 30))
        #expect(transcriber.lastError != nil)

        // Engine recovers; the stop-time retry resolves everything.
        await engine.openAll(with: .success(TranscriptPayload(text: "recovered")))
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source, meetingID: fixture.meetingID
        )
        guard case .completed = result else {
            Issue.record("Expected .completed after recovery, got \(result)")
            return
        }

        // FIXED: completion clears the stale error.
        #expect(transcriber.lastError == nil)
    }

    /// Wave-7 P2 (3834342735): the live Observatory tap must fire at
    /// engine-success time - decoupled from ordered persistence. A later
    /// segment's tap cannot wait behind an earlier in-flight segment.
    @MainActor
    @Test func liveTapFiresAtEngineSuccessBehindAnInFlightEarlierSegment() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        // Record tap invocations.
        @MainActor final class TapLog {
            var segments: [MeetingTranscriptSegment] = []
        }
        let tapLog = TapLog()
        transcriber.liveSegmentTap = { segment in
            tapLog.segments.append(segment)
        }

        // Both live tasks launch; segment 0 stays PARKED (in flight).
        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Segment 1 succeeds - its tap must fire NOW, while segment 0 is
        // still in flight and nothing is persisted yet.
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "second segment")))

        let tapDeadline = Date().addingTimeInterval(30)
        while Date() < tapDeadline && tapLog.segments.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(tapLog.segments.count == 1)
        #expect(tapLog.segments.first?.sequence == 1)
        #expect(tapLog.segments.first?.text == "second segment")

        // Nothing persisted yet (segment 0 unresolved - ordering intact).
        let earlyManifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(earlyManifest.transcriptSpans.isEmpty)

        await engine.openAll(with: .success(TranscriptPayload(text: "first segment")))
    }

    /// Wave-7 P2 (3836115274): the tap must carry the SAME segment ID that
    /// later lands in the manifest, so SpokenInvocation.sourceSpanID points
    /// at a real persisted span (stable source-link contract).
    @MainActor
    @Test func liveTapReusesPersistedSegmentID() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .success(TranscriptPayload(text: "hello")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        @MainActor final class TapLog {
            var ids: [String] = []
        }
        let tapLog = TapLog()
        transcriber.liveSegmentTap = { segment in
            tapLog.ids.append(segment.id)
        }

        let source = ScriptedSegmentSource(completedSegmentCount: 1)
        transcriber.checkForNewSegments(recorder: source)

        let tapDeadline = Date().addingTimeInterval(30)
        while Date() < tapDeadline && tapLog.ids.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let result = await transcriber.finalizeAndTranscribe(
            recorder: source, meetingID: fixture.meetingID
        )
        guard case .completed = result else {
            Issue.record("Expected .completed, got \(result)")
            return
        }

        #expect(tapLog.ids.count == 1)
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.segments.count == 1)
        // FIXED: the tapped ID IS the persisted segment's ID.
        #expect(tapLog.ids.first == manifest.segments.first?.id)
    }

    /// Wave-7 P2 (3834342743): one live failure must not leave later live
    /// successes as volatile transcriber state. They flush durably (in
    /// ascending order) right at the failure; the hole stays for retry.
    @MainActor
    @Test func liveFailureDurablyFlushesLaterBufferedSuccesses() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let source = ScriptedSegmentSource(completedSegmentCount: 2)
        transcriber.checkForNewSegments(recorder: source)
        #expect(await engine.awaitCallCount(2, timeout: 30))

        // Segment 1 succeeds FIRST (buffers behind the in-flight hole),
        // then segment 0 fails PERMANENTLY on the live path.
        await engine.release(segment: "segment_0001.wav", with: .success(TranscriptPayload(text: "later segment")))
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.release(segment: "segment_0000.wav", with: .failure(EngineServiceError.processFailed("engine down")))

        // FIXED: the failure triggers a durable ascending flush of the
        // already-buffered success - it survives a crash-before-Stop.
        let flushDeadline = Date().addingTimeInterval(30)
        var flushed = false
        while Date() < flushDeadline {
            if (try fixture.store.load(meetingID: fixture.meetingID)).transcriptSpans.count == 1 {
                flushed = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(flushed)

        // The hole remains retriable: engine recovers; finalize fills it
        // and the final transcript reads in true order.
        await engine.openAll(with: .success(TranscriptPayload(text: "earlier segment")))
        let result = await transcriber.finalizeAndTranscribe(
            recorder: source, meetingID: fixture.meetingID
        )
        guard case .completed = result else {
            Issue.record("Expected .completed after hole recovery, got \(result)")
            return
        }
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.segments.map(\.sequence) == [0, 1])
        #expect(manifest.segments.first?.text == "earlier segment")
        #expect(manifest.segments.last?.text == "later segment")
    }

    /// Wave-7 P2 (3834342748): `transcribeSegmentRange(fromIndex:toIndex:)`
    /// on a fresh transcriber must persist the REQUESTED range - the drain
    /// may not assume the meeting starts at index 0 of this transcriber.
    @MainActor
    @Test func rangeFromNonzeroIndexPersistsItsSegments() async throws {
        let fixture = try makeMeeting(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        await engine.openAll(with: .success(TranscriptPayload(text: "second minute")))

        let transcriber = MeetingTranscriber(
            store: fixture.store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: engine
        )
        transcriber.start(meetingID: fixture.meetingID)

        let result = await transcriber.transcribeSegmentRange(
            meetingID: fixture.meetingID,
            fromIndex: 1,
            toIndex: 2
        )
        guard case .completed(let count) = result else {
            Issue.record("Expected .completed for range [1, 2), got \(result)")
            return
        }
        #expect(count == 1)

        // FIXED: the range's result is actually persisted.
        let manifest = try fixture.store.load(meetingID: fixture.meetingID)
        #expect(manifest.transcriptSpans.count == 1)
        #expect(manifest.segments.map(\.sequence) == [1])
        #expect(manifest.segments.first?.text == "second minute")
    }

    /// Wave-7 P2 (3836482857): `withRaceTimeout` must return at the
    /// deadline even when the body IGNORES cancellation (e.g. parked in an
    /// engine call). The losing body must not block the helper's return.
    @MainActor
    @Test func raceTimeoutEscapesNonCooperativeBody() async throws {
        let fixture = try makeMeeting(segmentCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let engine = GatedMeetingEngine()
        let parkedURL = fixture.store.audioSegmentURL(for: fixture.meetingID, segmentIndex: 0)

        // Release the parked call 1.5s in, so even a stalled helper returns
        // eventually and the RED run records a clean failure (not a hang).
        let releaser = Task {
            try await Task.sleep(nanoseconds: 8_000_000_000)
            await engine.release(path: parkedURL.path, with: .success(TranscriptPayload(text: "late")))
        }

        let started = Date()
        let outcome = await withRaceTimeout(seconds: 0.5) {
            _ = try? await engine.transcribe(
                audioURL: parkedURL,
                modelIdentifier: "stub-model",
                formattingEnabled: true,
                vocabularyCorrectionsEnabled: true,
                customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
                cleanupMode: .off
            )
            return true
        }

        let elapsed = Date().timeIntervalSince(started)

        // FIXED: the deadline won - nil came back WITHOUT waiting for the
        // still-parked body (which only releases a second later). The old
        // task-group helper stalls on the non-cooperative body until the
        // 8s release: elapsed >= 8 fails this bound.
        #expect(outcome == nil)
        #expect(elapsed < 4.0)
        _ = try? await releaser.value
    }

}

/// Test-only helper: race an async expression against a deadline so a hung
/// finalize FAILS the expectation instead of stalling the suite.
///
/// Wave-7 (3836482857): the body runs as an UNSTRUCTURED task and the race
/// is decided by a once-box, so a body that ignores cancellation (e.g.
/// parked in an engine call) cannot block the helper's return - the losing
/// body is simply cancelled and left to finish on its own.
private final class RaceTimeoutOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

func withRaceTimeout<T: Sendable>(
    seconds: Double,
    _ body: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let once = RaceTimeoutOnce()
        let bodyTask = Task {
            let value = await body()
            if once.claim() { cont.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                bodyTask.cancel()
                cont.resume(returning: nil)
            }
        }
    }
}
