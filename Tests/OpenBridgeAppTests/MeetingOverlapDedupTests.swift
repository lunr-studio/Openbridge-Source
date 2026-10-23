import Testing
import Foundation
@testable import OpenBridgeApp

/// #294 (3864613545): exact-match overlap dedup. The current chunk's window
/// overlaps the previous chunk's tail; the duplicated HEAD is trimmed only
/// when it exactly matches the previous tail, bounded to the overlap window's
/// word budget.
@Suite(.serialized) struct MeetingOverlapDedupTests {

    @Test func trimsExactOverlappingHead() {
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "hello world today we discuss",
            previousText: "and then hello world",
            overlapSeconds: 0.6
        )
        #expect(result == "today we discuss")
    }

    @Test func leavesUnmatchedTextUntouched() {
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "completely different start",
            previousText: "and then hello world",
            overlapSeconds: 0.6
        )
        #expect(result == "completely different start")
    }

    @Test func matchesCaseAndPunctuationButPreservesRecognizedSuffix() {
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "HELLO, world!\nKeep  This formatting.",
            previousText: "The speaker said hello world",
            overlapSeconds: 1.5
        )
        #expect(result == "Keep  This formatting.")
    }

    @Test func standalonePunctuationDoesNotDisableBoundaryMatch() {
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "— HELLO, world! Continue here.",
            previousText: "The speaker said hello world —",
            overlapSeconds: 1.5
        )
        #expect(result == "Continue here.")
    }

    @Test func apostropheChangesLexicalIdentityAndPreventsTrim() {
        let contraction = MeetingOverlapDedup.trimOverlappingHead(
            from: "we'll continue tomorrow",
            previousText: "I think this will end well",
            overlapSeconds: 1.5
        )
        #expect(contraction == "we'll continue tomorrow")

        let secondContraction = MeetingOverlapDedup.trimOverlappingHead(
            from: "we're ready now",
            previousText: "they said we were",
            overlapSeconds: 1.5
        )
        #expect(secondContraction == "we're ready now")
    }

    @Test func interiorHyphenChangesLexicalIdentityAndPreventsTrim() {
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "re-enter the room",
            previousText: "please reenter",
            overlapSeconds: 1.5
        )
        #expect(result == "re-enter the room")
    }

    @Test func matchLongerThanOverlapIsLeftUntouched() {
        // overlap 0.6 s ~= 2 words, but the actual duplicated phrase is 3
        // words — LONGER than the overlap. That is genuine repetition, not
        // overlap audio, so nothing is trimmed (3864858074).
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "one two three four five",
            previousText: "say one two three",
            overlapSeconds: 0.6
        )
        #expect(result == "one two three four five")
    }

    @Test func longRepeatedPhraseNotOverTrimmed() {
        // A speaker genuinely repeats a long phrase across chunks, but only
        // ~0.6 s overlaps — the whole 10-word match exceeds the 2-word
        // budget, so it is real speech and must NOT be trimmed.
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "one two three four five six seven eight nine ten",
            previousText: "then one two three four five six seven eight nine ten",
            overlapSeconds: 0.6
        )
        #expect(result == "one two three four five six seven eight nine ten")
    }

    @Test func overlapWithinBudgetIsTrimmed() {
        // 2.0 s overlap ~= 6 words; the 5-word duplicate fits the window.
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "one two three four five six",
            previousText: "then one two three four five six",
            overlapSeconds: 2.0
        )
        #expect(result == "six")
    }

    @Test func zeroOverlapIsNoop() {
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "hello world",
            previousText: "hello world",
            overlapSeconds: 0
        )
        #expect(result == "hello world")
    }

    @Test func emptyInputsAreNoop() {
        #expect(MeetingOverlapDedup.trimOverlappingHead(from: "", previousText: "x", overlapSeconds: 0.6) == "")
        #expect(MeetingOverlapDedup.trimOverlappingHead(from: "x", previousText: "", overlapSeconds: 0.6) == "x")
    }

    @Test func preservesFormattingOfSuffix() {
        // The overlap head "hello" is trimmed from the ORIGINAL string — the
        // suffix keeps its newlines/paragraph structure instead of being
        // re-joined with single spaces (wave-7 3865753050).
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "hello\nworld\n\nNext topic",
            previousText: "say hello",
            overlapSeconds: 0.6
        )
        #expect(result == "world\n\nNext topic")
    }

    @Test func neverTrimsTheEntireNewText() {
        // Identical consecutive transcripts: still leaves one word so the
        // segment is never reduced to nothing.
        let result = MeetingOverlapDedup.trimOverlappingHead(
            from: "the meeting continues",
            previousText: "the meeting continues",
            overlapSeconds: 0.6
        )
        #expect(!result.isEmpty)
    }
}
