import Testing
import Foundation
@testable import OpenBridgeApp

/// Build 21: fixed 30-second Parakeet windows. Silence identifies whether
/// speech exists but never creates short transcription chunks.
@Suite(.serialized) struct MeetingChunkPolicyTests {

    @Test func liveConfigurationIsBuild21Policy() {
        let configuration = MeetingChunkPolicyConfiguration.live
        #expect(configuration.maxChunkDurationSeconds == 30)
        #expect(configuration.overlapSeconds == 1.5)
        #expect(configuration.ringRetentionSeconds == 35)
        #expect(!configuration.flushesAtUtteranceBoundary)
    }

    private func feedSpeech(
        _ acc: inout MeetingChunkAccumulator, from: TimeInterval, to: TimeInterval
    ) {
        var t = from
        while t <= to {
            _ = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
    }

    private func feedSilence(
        _ acc: inout MeetingChunkAccumulator, from: TimeInterval, to: TimeInterval
    ) {
        var t = from
        while t <= to {
            _ = acc.feed(time: t, level: 0.02)
            t += 0.1
        }
    }

    @Test func sustainedSilenceDoesNotCutWindowShort() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        feedSpeech(&acc, from: 0.1, to: 3.0)
        var boundary: MeetingChunkBoundary?
        var t = 3.1
        while t <= 4.0, boundary == nil {
            boundary = acc.feed(time: t, level: 0.02)
            t += 0.1
        }
        #expect(boundary == nil)
    }

    @Test func briefSilenceDoesNotFlush() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        feedSpeech(&acc, from: 0.1, to: 2.0)
        feedSilence(&acc, from: 2.1, to: 2.5)
        var flushed = false
        var t = 2.6
        while t <= 5.0 {
            if acc.feed(time: t, level: 0.5) != nil { flushed = true }
            t += 0.1
        }
        #expect(!flushed)
    }

    @Test func continuousSpeechFlushesAtMaxDuration() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var boundary: MeetingChunkBoundary?
        var t = 0.1
        while t <= 30.5, boundary == nil {
            boundary = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(boundary != nil)
        #expect(boundary?.reason == .maxDuration)
        #expect((boundary?.endOffset ?? -1) >= 29.9)
        #expect((boundary?.endOffset ?? -1) <= 30.2)
    }

    @Test func overlapWithinSpecRange() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var boundary: MeetingChunkBoundary?
        var t = 0.1
        while t <= 30.5, boundary == nil {
            boundary = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        let overlap = boundary?.overlapSeconds ?? -1
        #expect(overlap == 1.5)
    }

    @Test func callbackOvershootClampsToScheduledBoundaryAndCarriesSpeech() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)

        // A coarse callback cadence deliberately misses 30.0 seconds. The
        // persisted window must still end at the scheduled boundary rather
        // than drifting to the 30.4-second callback timestamp.
        _ = acc.feed(time: 0.4, level: 0.5)
        let first = acc.feed(time: 30.4, level: 0.5)
        #expect(first?.startOffset == 0)
        #expect(first?.endOffset == 30)

        guard let first else { return }
        acc.beginChunk(at: acc.nextChunkStart(after: first))

        // MeetingRecorder re-feeds the same straddling buffer after the old
        // writer is sealed. A Stop before another callback must therefore
        // preserve the real audio after 30.0 instead of dropping the tail.
        _ = acc.feed(time: 30.4, level: 0.5)
        let tail = acc.forceBoundary(at: 30.4)
        #expect(tail?.startOffset == 28.5)
        #expect(tail?.endOffset == 30.4)
        #expect(tail?.reason == .stop)
    }

    @Test func boundariesAdvanceMonotonicallyWithOverlap() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var first: MeetingChunkBoundary?
        var t = 0.1
        while t <= 30.5, first == nil {
            first = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(first != nil)
        guard let first else { return }
        acc.beginChunk(at: acc.nextChunkStart(after: first))
        var second: MeetingChunkBoundary?
        while t <= 60.5, second == nil {
            second = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(second != nil)
        guard let second else { return }
        #expect(second.chunkIndex == first.chunkIndex + 1)
        #expect(second.startOffset > first.startOffset)
        // The next chunk starts inside the previous chunk's overlap window.
        #expect(second.startOffset == first.endOffset - first.overlapSeconds)
        #expect(first.endOffset == 30)
        #expect(second.startOffset == 28.5)
        #expect(second.endOffset == 58.5)
        #expect(second.endOffset > first.endOffset)
    }

    @Test func stopFlushesSpeechAfterInterveningSilence() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        feedSpeech(&acc, from: 0.1, to: 1.0)
        feedSilence(&acc, from: 1.1, to: 1.5)   // 0.5 s — below threshold
        feedSpeech(&acc, from: 1.6, to: 2.0)
        feedSilence(&acc, from: 2.1, to: 3.4)
        let boundary = acc.forceBoundary(at: 3.4)
        #expect(boundary != nil)
        #expect(boundary?.reason == .stop)
    }

    @Test func rebasedWindowReportsZeroActualOverlap() {
        let previous = MeetingChunkBoundary(
            chunkIndex: 0,
            startOffset: 0,
            endOffset: 30,
            overlapSeconds: 1.5,
            reason: .maxDuration,
            availableOverlap: 1.5
        )
        let rebased = MeetingChunkBoundary(
            chunkIndex: 1,
            startOffset: 35,
            endOffset: 40,
            overlapSeconds: 1.5,
            reason: .stop,
            availableOverlap: 1.5
        )
        #expect(MeetingChunkBoundary.actualOverlap(from: previous, into: rebased) == 0)
    }
}
