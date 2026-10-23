import Foundation

// MARK: - Build 21 fixed-window chunking policy

/// Why a chunk was flushed. `utteranceBoundary` is retained so manifests
/// written by builds 18–20 continue to decode, but Build 21's live policy
/// rotates only at the fixed-duration boundary or Stop.
enum MeetingChunkFlushReason: String, Codable, Equatable, Sendable {
    case utteranceBoundary
    case maxDuration
    /// Wave-2 (3864613534): forced at Stop for the final partial chunk
    /// that never reached a boundary on its own.
    case stop
}

/// Boundary record for one flushed chunk. `startOffset`/`endOffset` are
/// seconds from the meeting start; `overlapSeconds` is the audio context
/// the NEXT chunk's transcription will include from this chunk's tail.
/// Build 21 uses 1.5 seconds. Slice 2 consumes these to populate
/// span timestamps and drive exact-match overlap dedup.
struct MeetingChunkBoundary: Equatable, Sendable, Codable {
    let chunkIndex: Int
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let overlapSeconds: TimeInterval
    let reason: MeetingChunkFlushReason
    /// Overlap actually available: the configured window clamped to audio
    /// that exists before `endOffset` (a first utterance ending less than
    /// one window after start cannot borrow audio from before the meeting).
    let availableOverlap: TimeInterval

    /// Real shared audio between consecutive persisted windows. A long quiet
    /// gap can rebase the next window after the previous one ended; in that
    /// case configured overlap must not be used for transcript dedup or replay.
    static func actualOverlap(
        from previous: MeetingChunkBoundary,
        into current: MeetingChunkBoundary
    ) -> TimeInterval {
        min(
            previous.availableOverlap,
            max(0, previous.endOffset - current.startOffset)
        )
    }
}

/// Tunables for the meeting chunking policy. Build 21 restores longer,
/// context-rich Parakeet input: one 30-second window with 1.5 seconds of
/// real audio overlap. Silence still controls whether a window contains
/// speech, but it no longer cuts a spoken window into tiny utterances.
struct MeetingChunkPolicyConfiguration: Equatable, Sendable {
    var silenceThresholdSeconds: TimeInterval = 0.85
    var maxChunkDurationSeconds: TimeInterval = 30.0
    var overlapSeconds: TimeInterval = 1.5
    var flushesAtUtteranceBoundary = false
    /// Normalized meter level (0...1) below which a sample counts as
    /// silence. Normalized levels come from the recorder's meter
    /// (`-60...0 dB` mapped to `0...1`).
    var silenceLevelThreshold: Double = 0.12
    /// Wave-7 (3865753003): the recorder's ring-buffer retention — the chunk
    /// window (speechless pause + max duration) must never exceed it, or the
    /// WAV would be truncated from the front while offsets claim it exists.
    var ringRetentionSeconds: TimeInterval = 35

    static let live = MeetingChunkPolicyConfiguration()
}

/// Pure, deterministic accumulator that decides when the current recording
/// chunk should be flushed, from a stream of (meeting-relative time,
/// normalized level) samples. The recorder feeds it from its 0.1 s meter
/// tick; tests feed synthetic streams. No clocks, no audio hardware —
/// every decision is reproducible from the sample stream alone.
struct MeetingChunkAccumulator: Sendable {
    private let configuration: MeetingChunkPolicyConfiguration
    private var chunkIndex: Int = 0
    private(set) var chunkStartOffset: TimeInterval = 0
    private var lastSampleTime: TimeInterval?
    private var consecutiveSilenceSeconds: TimeInterval = 0
    /// Wave-1 (3857377354): set once the chunk has heard speech; silence
    /// before any speech must not arm a boundary flush (quiet-room spam).
    private var hasSpeechInChunk = false
    /// Wave-2 (3864613534): public so Stop can force-flush a final chunk.
    var hasHeardSpeech: Bool { hasSpeechInChunk }
    /// Meeting-relative time speech last stopped — the utterance boundary.
    /// Tracked explicitly (not derived by subtraction) so float drift in
    /// the accumulated run cannot shift the boundary.
    private var silenceStartTime: TimeInterval?

    init(configuration: MeetingChunkPolicyConfiguration = .live) {
        self.configuration = configuration
    }

    /// Begin a new chunk at `startOffset` (meeting-relative seconds).
    /// Called at recording start and immediately after each flush, with
    /// `startOffset = boundary.endOffset - boundary.overlapSeconds` so the
    /// next chunk's transcription window overlaps this chunk's tail.
    mutating func beginChunk(at startOffset: TimeInterval) {
        chunkStartOffset = startOffset
        consecutiveSilenceSeconds = 0
        lastSampleTime = nil
        silenceStartTime = nil
        // Wave-1 (3857377354): a chunk with no speech must NEVER flush.
        hasSpeechInChunk = false
    }

    /// Feed one meter sample. Returns the boundary when the current chunk
    /// should be flushed, or nil while the chunk continues.
    mutating func feed(time: TimeInterval, level: Double) -> MeetingChunkBoundary? {
        // Samples are fed on the recorder's 0.1 s meter tick; use the
        // sample delta so synthetic streams and the live recorder share
        // one silence-run accounting path.
        let lastSampleTimeBeforeUpdate = lastSampleTime
        let delta = time - (lastSampleTime ?? time)
        lastSampleTime = time
        if level >= configuration.silenceLevelThreshold {
            hasSpeechInChunk = true
        }
        if delta > 0 {
            if level < configuration.silenceLevelThreshold {
                if consecutiveSilenceSeconds == 0 {
                    silenceStartTime = lastSampleTimeBeforeUpdate
                }
                consecutiveSilenceSeconds += min(delta, 0.5)
            } else {
                consecutiveSilenceSeconds = 0
                silenceStartTime = nil
            }
        }

        // Utterance boundary: sustained silence past the threshold flushes
        // AT the moment speech stopped (the boundary is where silence
        // began, not where the flush fires). A chunk that never heard
        // speech (quiet room, or a pause right after a flush) must NOT
        // flush — wave-1 (3857377354).
        if configuration.flushesAtUtteranceBoundary,
           hasSpeechInChunk,
           consecutiveSilenceSeconds >= configuration.silenceThresholdSeconds {
            let end = silenceStartTime ?? (time - consecutiveSilenceSeconds)
            let b = boundary(reason: .utteranceBoundary, endOffset: end)
            chunkIndex += 1
            return b
        }

        // Fixed-duration boundary measured from the window start, not from
        // the first detected word. This is the key Build 21 regression fix:
        // silence may decide whether a window is worth transcribing, but it
        // cannot change the 30-second context supplied to Parakeet.
        if hasSpeechInChunk,
           time - chunkStartOffset >= configuration.maxChunkDurationSeconds {
            // Capture callbacks report the end of a buffer and rarely land
            // on the exact deadline. Clamp to the scheduled boundary so
            // callback-size overshoot cannot accumulate across windows. The
            // recorder retains the straddling audio and carries this sample's
            // speech state into the new overlapping accumulator.
            let scheduledEnd = chunkStartOffset
                + configuration.maxChunkDurationSeconds
            let b = boundary(reason: .maxDuration, endOffset: scheduledEnd)
            chunkIndex += 1
            return b
        }

        // Do not create WAVs for silence-only windows. Advance the internal
        // fixed-window clock so speech that begins later still belongs to a
        // bounded 30-second window and can never outrun the 35-second ring.
        if !hasSpeechInChunk,
           time - chunkStartOffset >= configuration.maxChunkDurationSeconds {
            let elapsed = time - chunkStartOffset
            let elapsedWindows = max(
                1,
                Int(elapsed / configuration.maxChunkDurationSeconds)
            )
            chunkStartOffset += Double(elapsedWindows)
                * configuration.maxChunkDurationSeconds
        }
        return nil
    }

    private func boundary(reason: MeetingChunkFlushReason, endOffset: TimeInterval) -> MeetingChunkBoundary {
        MeetingChunkBoundary(
            chunkIndex: chunkIndex,
            startOffset: chunkStartOffset,
            endOffset: endOffset,
            overlapSeconds: configuration.overlapSeconds,
            reason: reason,
            // Wave-1 (3857377384): report only the overlap that actually
            // exists before `endOffset` (clamped to meeting start).
            // Wave-7 (3865753030): also clamp to the CURRENT CHUNK duration —
            // after a speechless-pause rebase a short utterance can be
            // shorter than the configured window, and claiming the full
            // overlap would make the next chunk start before this WAV starts
            // and let dedup trim words the files do not truly share.
            availableOverlap: min(configuration.overlapSeconds, max(0, endOffset - chunkStartOffset))
        )
    }

    /// Meeting-relative offset the next chunk should start at, given a
    /// boundary (its end minus the overlap window). Wave-1 (3857377384):
    /// clamped to meeting start — a first utterance ending less than one
    /// window after start cannot borrow audio from before the meeting.
    func nextChunkStart(after boundary: MeetingChunkBoundary) -> TimeInterval {
        max(0, boundary.endOffset - boundary.overlapSeconds)
    }

    /// Wave-2 (3864613534): a final boundary at `endOffset`, used when Stop
    /// arrives before the chunk reached max duration or a silence boundary.
    /// Only meaningful when the chunk actually heard speech — a silent
    /// meeting produces no final chunk. Mutates like `feed` (advances the
    /// chunk index) so the caller can immediately begin the next window.
    mutating func forceBoundary(at endOffset: TimeInterval) -> MeetingChunkBoundary? {
        guard hasSpeechInChunk else { return nil }
        let b = boundary(reason: .stop, endOffset: endOffset)
        chunkIndex += 1
        return b
    }
}
