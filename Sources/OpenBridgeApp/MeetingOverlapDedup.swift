import Foundation

/// Boundary overlap dedup for consecutive chunk transcripts.
///
/// Chunk windows overlap by the boundary's `overlapSeconds` (the next chunk
/// starts inside the previous chunk's tail), so Parakeet transcribes the
/// shared audio in both files. This trims the duplicated HEAD of the newer
/// transcript when it matches the tail of the previous one after normalizing
/// case and punctuation. The returned suffix always comes from the original
/// recognized text; normalization is used only for comparison.
///
/// This is deliberately not fuzzy alignment. The trim is bounded to the
/// overlap window's word budget so model guesses cannot erase speech outside
/// the shared audio.
enum MeetingOverlapDedup {
    /// Returns `currentText` with the leading words that exactly match the
    /// tail of `previousText` removed, bounded to the word count implied by
    /// `overlapSeconds`. Unchanged when there is no exact boundary match.
    static func trimOverlappingHead(
        from currentText: String,
        previousText: String,
        overlapSeconds: TimeInterval
    ) -> String {
        guard overlapSeconds > 0,
              !currentText.isEmpty,
              !previousText.isEmpty
        else { return currentText }

        // Wave-6 (3865593031): split on ANY whitespace (not just the space
        // character) so a newline/tab at the overlap boundary does not fuse
        // adjacent words into one token and defeat the exact match.
        let newWords = currentText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let prevWords = previousText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !newWords.isEmpty, !prevWords.isEmpty else { return currentText }

        // Standalone punctuation is not a spoken word. Exclude it from the
        // comparison while retaining each current token's original position
        // so a successful trim still returns untouched recognized text.
        let normalizedNewWords = newWords.enumerated().compactMap { index, word in
            let normalized = normalizedToken(word)
            return normalized.isEmpty ? nil : (index: index, token: normalized)
        }
        let normalizedPrevWords = prevWords.compactMap { word -> String? in
            let normalized = normalizedToken(word)
            return normalized.isEmpty ? nil : normalized
        }
        guard !normalizedNewWords.isEmpty, !normalizedPrevWords.isEmpty else {
            return currentText
        }

        // Wave-3 (3864858074): the removable word count is bounded by the
        // ACTUAL overlap audio (~3 words/sec), so a speaker genuinely
        // repeating a long phrase is never over-trimmed. Floored to at least
        // 1 word so a real (if short) overlap still dedups.
        let overlapWordBudget = max(1, Int((overlapSeconds * 3.0).rounded()))
        // Search the FULL match first; the never-empty rule is applied to
        // the trim length separately below.
        let searchLimit = min(normalizedNewWords.count, normalizedPrevWords.count)
        guard searchLimit >= 1 else { return currentText }

        // Longest exact prefix-of-new == suffix-of-prev.
        var longestMatch = 0
        for k in 1...searchLimit {
            let prefix = normalizedNewWords[0..<k].map(\.token)
            let suffix = normalizedPrevWords[(normalizedPrevWords.count - k)...]
            if prefix.elementsEqual(suffix) {
                longestMatch = k
            }
        }
        // Trim ONLY when the whole match fits the overlap window. A match
        // LONGER than the overlap means the speaker genuinely repeated the
        // phrase — trimming it would drop real speech, so leave it.
        guard longestMatch >= 1, longestMatch <= overlapWordBudget else {
            return currentText
        }
        // Never remove the ENTIRE new text (an identical chunk keeps its
        // final word so the segment is never empty).
        let trimCount = min(longestMatch, normalizedNewWords.count - 1)
        guard trimCount > 0 else { return currentText }
        let rawTokensToDrop = normalizedNewWords[trimCount - 1].index + 1

        // Wave-7 (3865753050): remove the matched PREFIX from the ORIGINAL
        // string (preserving the untouched suffix's newlines, tabs, and
        // spacing) instead of re-joining the words with single spaces, which
        // collapsed formatting such as "hello\nworld\n\nNext topic" into
        // "world Next topic".
        var idx = currentText.startIndex
        var tokensSeen = 0
        while tokensSeen < rawTokensToDrop, idx < currentText.endIndex {
            while idx < currentText.endIndex, currentText[idx].isWhitespace {
                idx = currentText.index(after: idx)
            }
            guard idx < currentText.endIndex else { break }
            tokensSeen += 1
            while idx < currentText.endIndex, !currentText[idx].isWhitespace {
                idx = currentText.index(after: idx)
            }
        }
        return String(currentText[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize only presentation punctuation at token boundaries. Interior
    /// apostrophes, hyphens, slashes, and other meaning-bearing punctuation
    /// remain part of lexical identity: `well` must never compare equal to
    /// `we'll`, and `reenter` must not compare equal to `re-enter`.
    private static func normalizedToken(_ token: String) -> String {
        let scalars = Array(token.lowercased().unicodeScalars)
        var lowerBound = 0
        var upperBound = scalars.count
        while lowerBound < upperBound,
              boundaryPunctuation.contains(scalars[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound,
              boundaryPunctuation.contains(scalars[upperBound - 1]) {
            upperBound -= 1
        }
        let kept = scalars[lowerBound..<upperBound]
        guard kept.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return ""
        }
        return kept.map(String.init).joined()
    }

    /// Deliberately conservative: these marks commonly decorate a spoken
    /// token without changing the word. Apostrophes are intentionally absent.
    private static let boundaryPunctuation = Set(
        ".,!?:;\"“”()[]{}<>—–-…".unicodeScalars
    )
}
