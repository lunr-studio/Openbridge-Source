import Testing
import Foundation
@testable import OpenBridgeApp

/// Silence-only windows advance the internal fixed-window clock without
/// creating transcription work, and the first real overlap must not extend
/// before meeting start.
@Suite(.serialized) struct MeetingChunkPolicyLatchTests {

    @Test func quietRoomNeverFlushesSilenceOnlyChunks() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var flushed = false
        var t = 0.1
        while t <= 8.0 {
            if acc.feed(time: t, level: 0.02) != nil { flushed = true }
            t += 0.1
        }
        #expect(!flushed)
    }

    @Test func maxDurationDoesNotFlushSilenceOnlyChunk() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var flushed = false
        var t = 0.1
        while t <= 35.0 {
            if acc.feed(time: t, level: 0.02) != nil { flushed = true }
            t += 0.1
        }
        #expect(!flushed)
        #expect(acc.chunkStartOffset == 30)
    }

    @Test func flushOnceThenQuietRoomDoesNotRepeatFlushes() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        var first: MeetingChunkBoundary?
        while t <= 30.5, first == nil {
            first = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(first != nil)
        guard let first else { return }
        acc.beginChunk(at: acc.nextChunkStart(after: first))
        var second = false
        while t <= 65.0 {
            if acc.feed(time: t, level: 0.02) != nil { second = true }
            t += 0.1
        }
        #expect(!second)
    }

    @Test func fixedWindowDoesNotRestartAtFirstSpeech() {
        // Fourteen quiet seconds followed by speech still belongs to the
        // fixed 0...30 second window. Silence must not turn this into a
        // variable 14...44 second utterance window.
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        while t <= 14.0 { _ = acc.feed(time: t, level: 0.02); t += 0.1 }
        var boundary: MeetingChunkBoundary?
        while t <= 31.0, boundary == nil {
            boundary = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        #expect(boundary != nil)
        guard let boundary else { return }
        #expect(boundary.reason == .maxDuration)
        #expect(boundary.startOffset == 0)
        #expect(boundary.endOffset >= 29.9)
        #expect(boundary.endOffset <= 30.2)
    }

    @Test func silenceOnlyWindowAdvancesWithoutCreatingAWAVBoundary() {
        // A full silent window is skipped internally. Later speech belongs
        // to the next fixed window, keeping it inside 35-second retention.
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        while t <= 40.0 { _ = acc.feed(time: t, level: 0.02); t += 0.1 }
        #expect(acc.chunkStartOffset == 30)
        var boundary: MeetingChunkBoundary?
        while t <= 61.0, boundary == nil {
            boundary = acc.feed(time: t, level: 0.5)
            t += 0.1
        }
        guard let boundary else { return }
        #expect(boundary.startOffset == 30)
        #expect(boundary.endOffset - boundary.startOffset <= 30.2)
    }

    @Test func overlapClampedToShortChunk() {
        // A short utterance after a rebase is shorter than the configured
        // overlap window — the available overlap must clamp to the chunk's
        // actual duration (wave-7 3865753030).
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        while t <= 30.1 { _ = acc.feed(time: t, level: 0.02); t += 0.1 }
        while t <= 30.4 { _ = acc.feed(time: t, level: 0.5); t += 0.1 }
        let boundary = acc.forceBoundary(at: 30.4)
        guard let boundary else { return }
        // Window ~0.3-0.4 s long; availableOverlap must be <= that, not the
        // full 1.5 s configured window.
        let window = boundary.endOffset - boundary.startOffset
        #expect(boundary.availableOverlap <= window + 0.001)
        #expect(boundary.availableOverlap < 1.5)
    }

    @Test func forceBoundaryNilWithoutSpeech() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        while t <= 2.0 { _ = acc.feed(time: t, level: 0.02); t += 0.1 }
        let forced = acc.forceBoundary(at: 2.0)
        #expect(forced == nil)
    }

    @Test func forceBoundaryFlushesFinalPartialChunk() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        while t <= 5.0 { _ = acc.feed(time: t, level: 0.5); t += 0.1 }
        let forced = acc.forceBoundary(at: 5.0)
        #expect(forced != nil)
        #expect(forced?.reason == .stop)
        #expect(forced?.endOffset == 5.0)
        #expect(forced?.startOffset == 0.0)
    }

    @Test func firstChunkOverlapClampedToMeetingStart() {
        var acc = MeetingChunkAccumulator()
        acc.beginChunk(at: 0)
        var t = 0.1
        while t <= 0.3 { _ = acc.feed(time: t, level: 0.5); t += 0.1 }
        while t <= 1.3 { _ = acc.feed(time: t, level: 0.02); t += 0.1 }
        let b = acc.forceBoundary(at: 1.3)
        #expect(b != nil)
        guard let b else { return }
        #expect(acc.nextChunkStart(after: b) == 0.0)
    }
}
