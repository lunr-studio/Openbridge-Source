import Foundation

// MARK: - Spoken Wake-Phrase Detector (#309 / EXT-01)
//
// Detects explicit spoken "OpenBridge, …" (and optional "Hey OpenBridge, …")
// invocations in FINAL transcript spans, exactly once per invocation.
//
// Grammar: direct wake requests plus deliberate sentence-start Ask forms.
//   invocation := ("hey")? "openbridge" punctuation? commandText
//              | ("i want to" | "can i" | "please")? "ask openbridge" commandText
//   commandText := { word }+   (bounded)
//
// Rules:
//   - One invocation produces one request (handled-signature memory).
//   - A product mention that is not a command does not trigger.
//   - False starts (wake phrase with no command) do not trigger.
//   - Quoted/parenthetical mentions do not trigger.
//   - Sentence starts allow conversational fillers. Inside a poorly punctuated
//     span, explicit so/and/but transitions additionally require a request head;
//     quoted, reported, negated and ordinary product mentions do not trigger.
//   - Corrected/superseded text cannot double-trigger: span revisions
//     supersede prior invocations from that span; identical replayed text
//     never triggers twice.
//   - Routes through #296 via the returned invocation; the detector never
//     calls providers or the web, and holds no reference to capture or
//     transcription (detection failure cannot affect them).

// MARK: - Result

/// One detected invocation, ready to route through #296.
struct SpokenInvocation: Equatable, Sendable {
    let requestID: String
    /// The command text after the wake phrase (trimmed, bounded).
    let commandText: String
    /// The final span the invocation was extracted from.
    let sourceSpanID: String
    /// "openbridge," or "hey openbridge,".
    let form: String
    /// Position within the source span, stable across replay/correction.
    var commandIndex: Int = 0
}

struct SpokenPendingRequest: Equatable, Sendable {
    let invocation: SpokenInvocation
    let sequence: Int
    let deadline: Date
}

struct SpokenDetectionUpdate: Equatable, Sendable {
    var invocations: [SpokenInvocation] = []
    var pending: SpokenPendingRequest?
    var needsRepeat = false
}

// MARK: - Configuration

struct WakePhraseConfiguration: Equatable, Sendable {
    /// Enable/disable detection entirely.
    var enabled = true
    /// Allow the optional "Hey" prefix.
    var allowHeyPrefix = true
    /// Minimum words required in commandText for a valid command.
    var minimumCommandWords = 1
    /// Maximum words retained in commandText (bounded context).
    var maximumCommandWords = 40
    /// Recent final spans kept for revision detection (bounded).
    var revisionWindow = 8

    static let `default` = WakePhraseConfiguration()
}

// MARK: - Detector

/// Terminal wake-phrase detector over final transcript spans.
actor SpokenWakePhraseDetector {
    private let configuration: WakePhraseConfiguration

    /// Consumed span signatures (spanID + normalized text): exactly-once.
    private var handledSignatures = Set<String>()
    /// Latest text per recent span ID for revision detection.
    private var spanTexts: [String: String] = [:]
    /// Emitted invocations, newest last (for supersession/review).
    private var recentInvocations: [SpokenInvocation] = []
    private var meetingID: String?
    private var pending: SpokenPendingRequest?

    init(configuration: WakePhraseConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Ingest

    /// Processes one final span. Returns the invocation when a NEW one is
    /// detected, nil otherwise. Never throws.
    func process(_ segment: MeetingTranscriptSegment) -> SpokenInvocation? {
        processAll(segment).first
    }

    /// Production intake consumes the whole batch; one ASR window is not
    /// necessarily one utterance. Pending fragments can cross one adjacent
    /// final span, never a meeting boundary or a missing span.
    func processAll(_ segment: MeetingTranscriptSegment) -> [SpokenInvocation] {
        processUpdate(segment).invocations
    }

    /// Status and invocations are one atomic result, never separate actor reads.
    func processUpdate(_ segment: MeetingTranscriptSegment, now: Date = Date()) -> SpokenDetectionUpdate {
        guard configuration.enabled, segment.isFinal else { return .init(pending: pending) }
        if meetingID != segment.meetingID {
            handledSignatures.removeAll()
            spanTexts.removeAll()
            recentInvocations.removeAll()
            pending = nil
            meetingID = segment.meetingID
        }

        let normalizedText = Self.normalized(segment.text)
        let signature = segment.id + "|" + normalizedText

        // Revision handling: re-ingested span with DIFFERENT text supersedes
        // any prior invocation from that span (corrections); the new text is
        // a fresh candidate. Identical text replay never re-triggers.
        if let previousText = spanTexts[segment.id], previousText != normalizedText {
            handledSignatures.remove(segment.id + "|" + previousText)
            recentInvocations.removeAll { $0.sourceSpanID == segment.id }
            if pending?.invocation.sourceSpanID == segment.id { pending = nil }
        }
        spanTexts[segment.id] = normalizedText
        pruneState()

        var needsRepeat = pending.map { now >= $0.deadline } ?? false
        if needsRepeat { pending = nil }
        guard !handledSignatures.contains(signature) else { return .init(pending: pending, needsRepeat: needsRepeat) }
        handledSignatures.insert(signature)
        let candidates = Self.candidates(in: normalizedText, configuration: configuration)
        var invocations: [SpokenInvocation] = []
        if let fragment = pending {
            let prefix = Self.cleanSpeech(String(normalizedText[..<(candidates.first?.start ?? normalizedText.endIndex)]))
            let joined = Self.command(from: fragment.invocation.commandText + " " + prefix)
            if segment.sequence == fragment.sequence + 1,
               Self.validContinuation(prefix),
               Self.isComplete(joined, minimumWords: configuration.minimumCommandWords) {
                let original = fragment.invocation
                invocations.append(SpokenInvocation(requestID: original.requestID,
                    commandText: Self.bounded(joined, configuration: configuration),
                    sourceSpanID: original.sourceSpanID, form: original.form, commandIndex: original.commandIndex))
            } else {
                needsRepeat = true
            }
        }
        pending = nil
        for (index, candidate) in candidates.enumerated() {
            let end = index + 1 < candidates.count ? candidates[index + 1].start : normalizedText.endIndex
            let command = Self.command(from: String(normalizedText[candidate.end..<end]))
            guard Self.validHead(command, form: candidate.form, configuration: configuration) else { continue }
            let invocation = SpokenInvocation(requestID: UUID().uuidString,
                commandText: Self.bounded(command, configuration: configuration), sourceSpanID: segment.id,
                form: candidate.form, commandIndex: index)
            if Self.isComplete(command, minimumWords: configuration.minimumCommandWords) {
                invocations.append(invocation)
            } else if index == candidates.count - 1, !command.isEmpty {
                pending = SpokenPendingRequest(invocation: invocation, sequence: segment.sequence,
                                               deadline: now.addingTimeInterval(60))
            }
        }
        recentInvocations.append(contentsOf: invocations)
        return .init(invocations: invocations, pending: pending, needsRepeat: needsRepeat)
    }

    /// The intake timer supplies the same identity; an old timer cannot expire
    /// a replacement question. No provider call occurs on this transition.
    func expirePending(requestID: String, now: Date = Date()) -> SpokenDetectionUpdate? {
        guard let pending, pending.invocation.requestID == requestID, now >= pending.deadline else { return nil }
        self.pending = nil
        return .init(needsRepeat: true)
    }

    /// Invocations currently live (not superseded by corrections).
    var activeInvocations: [SpokenInvocation] {
        recentInvocations
    }

    // MARK: - Pure Detection

    /// Stateless grammar match. Exported for direct fixture testing.
    nonisolated static func detect(
        in raw: String,
        spanID: String,
        configuration: WakePhraseConfiguration
    ) -> SpokenInvocation? {
        let text = normalized(raw)
        let matches = candidates(in: text, configuration: configuration)
        for (index, match) in matches.enumerated() {
            let end = index + 1 < matches.count ? matches[index + 1].start : text.endIndex
            let command = command(from: String(text[match.end..<end]))
            guard validHead(command, form: match.form, configuration: configuration),
                  isComplete(command, minimumWords: configuration.minimumCommandWords) else { continue }
            return SpokenInvocation(requestID: UUID().uuidString,
                commandText: bounded(command, configuration: configuration), sourceSpanID: spanID,
                form: match.form, commandIndex: index)
        }
        return nil
    }

    private static func candidates(in text: String, configuration: WakePhraseConfiguration)
        -> [(start: String.Index, end: String.Index, form: String)] {
        wakeForms(allowHey: configuration.allowHeyPrefix).flatMap { form in
            findCommandStarts(text: text, form: form).map { match in
                (start: match.start, end: match.end, form: form)
            }
        }.sorted { $0.start < $1.start }
    }

    /// Join only an incomplete sentence opener, not all later conversation.
    /// ASR can punctuate "What? is an induction loop?" inside one question.
    private static func command(from raw: String) -> String {
        let text = String(cleanSpeech(raw).drop(while: { " ,.:?!".contains($0) || $0.isWhitespace }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, stop in
            guard let sentence else { return }
            if !result.isEmpty {
                result = result.trimmingCharacters(in: .punctuationCharacters) + " "
            }
            result += sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.hasPrefix("to ") { result.removeFirst(3) }
            stop = isComplete(result, minimumWords: 1)
        }
        return result
    }

    private static func isComplete(_ text: String, minimumWords: Int) -> Bool {
        let words = text.trimmingCharacters(in: .punctuationCharacters).split(whereSeparator: \.isWhitespace)
        guard words.count >= max(2, minimumWords) else { return false }
        let fragments: Set<String> = ["can you", "could you", "would you", "will you", "tell me", "show me", "what is", "what are", "who is", "where is", "how do", "how can", "can you tell me", "could you tell me", "would you tell me", "will you tell me", "can you show me", "could you show me"]
        guard !fragments.contains(words.joined(separator: " ")) else { return false }
        let trailing: Set<String> = ["a", "an", "the", "to", "of", "about", "with", "and", "or", "what", "which", "whose"]
        return !trailing.contains(String(words.last!))
    }

    /// Remove disfluencies, not arbitrary content words such as "well".
    /// A dangling "you [know]" after a request opener is still an opener.
    private static func cleanSpeech(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\b(?:um|uh)\b[,\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*you know[,\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b((?:can|could|would|will) you (?:tell|show) me|tell me|show me)[,\s]+you know[,\s]+"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*((?:(?:can|could|would|will) you )?(?:tell|show) me)[,\s]+you(?: know)?[,.?!\s]*$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validContinuation(_ text: String) -> Bool {
        let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return ["tell", "show", "explain", "find", "summarize", "compare", "list", "search", "what", "what's", "who", "who's", "where", "when", "why", "how", "which", "whether", "if", "about", "the", "a", "an", "is", "are"].contains(first)
    }

    private static func validHead(_ command: String, form: String, configuration: WakePhraseConfiguration) -> Bool {
        guard form.hasSuffix(" ") || form.hasSuffix("?") else { return true }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        var heads: Set<String> = ["what", "what's", "who", "who's", "when", "where", "why", "how", "which", "tell", "show", "find", "summarize", "explain", "search", "compare", "list"]
        if form.contains("ask ") || form.hasSuffix("?") {
            heads.formUnion(["whether", "if", "is", "are", "was", "were", "did", "does", "do", "can", "could", "will", "would"])
        } else if command == "can you" || command == "could you"
                    || command.hasPrefix("can you ") || command.hasPrefix("could you ") {
            heads.formUnion(["can", "could"])
        }
        return words.first.map(heads.contains) == true
    }

    private static func bounded(_ command: String, configuration: WakePhraseConfiguration) -> String {
        command.split(whereSeparator: \.isWhitespace).prefix(configuration.maximumCommandWords).joined(separator: " ")
    }

    // MARK: - State Helpers

    private func pruneState() {
        guard spanTexts.count > configuration.revisionWindow else { return }
        let keys = Array(spanTexts.keys)
        for key in keys.prefix(spanTexts.count - configuration.revisionWindow) {
            spanTexts.removeValue(forKey: key)
        }
    }

    // MARK: - Text Helpers

    private static func wakeForms(allowHey: Bool) -> [String] {
        // #309 runtime evidence: Parakeet transcribes the wake phrase as
        // "open bridge" (two words) and emits a PERIOD after the phrase
        // ("Open bridge. What did…" — 74D489F3 rows 4/7), not always a
        // comma. Spacing, hyphenation, and trailing comma/period/colon
        // variants are accepted, including ASR's question-mark separator.
        // Question-mark forms require an explicit request head. A wake form
        // still requires a command after it (minimum word rule), which
        // guards against sentence-final bare mentions.
        let cores = allowHey
            ? ["hey openbridge", "openbridge", "hey open bridge", "open bridge", "hey open-bridge", "open-bridge"]
            : ["openbridge", "open bridge", "open-bridge"]
        let direct = cores.flatMap { core in [",", ".", ":", "?", " "].map { core + $0 } }
        let ask = ["ask", "please ask", "i want to ask", "can i ask"].flatMap { prefix in
            ["openbridge", "open bridge", "open-bridge"].flatMap { core in
                [",", ":", " "].map { "\(prefix) \(core)\($0)" }
            }
        }
        return direct + ask
    }

    /// Finds where the command begins after a VALID wake-phrase position.
    /// Valid: string start, or immediately after '.', '!', '?' (+ space).
    private static func findCommandStarts(text: String, form: String) -> [(start: String.Index, end: String.Index)] {
        var searchStart = text.startIndex
        var starts: [(start: String.Index, end: String.Index)] = []
        while let found = text.range(of: form, range: searchStart..<text.endIndex) {
            let previous = String(text[..<found.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clause = previous.split(whereSeparator: { ".!?".contains($0) }).last.map(String.init) ?? ""
            let afterPunctuation = previous.last.map { ".!?".contains($0) } ?? true
            var words = afterPunctuation ? [] : clause.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            let fillers: Set<String> = ["so", "uh", "um", "okay", "ok", "well", "but", "and"]
            var removed: [String] = []
            while let last = words.last, fillers.contains(last) { removed.append(words.removeLast()) }
            let blocked: Set<String> = ["said", "says", "saying", "asked", "ask", "told", "quote", "example", "not", "never", "don't", "doesn't", "didn't", "can't", "cannot", "won't", "wouldn't", "shouldn't"]
            let isTransition = !removed.isEmpty && removed.contains(where: { ["so", "and", "but"].contains($0) })
                && !words.contains(where: blocked.contains)
            let atBoundary = words.isEmpty || isTransition
            // Relaxed boundaries require a genuine request head even when
            // ASR inserted a comma: "So OpenBridge, our app" is not a request.
            let following = command(from: String(text[found.upperBound...]))
            let hasHead = removed.isEmpty || validHead(following, form: "openbridge ", configuration: .default)
            let wordBoundary = found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isLetter
            // Quoted or parenthesized examples are not authorization to ask.
            let doubleQuotes = previous.filter { $0 == "\"" }.count
            let characters = Array(previous)
            let singleQuotes = characters.indices.filter { index in
                guard characters[index] == "'" else { return false }
                // Apostrophes within words (didn't/that's) are not quotes.
                return !(index > 0 && index + 1 < characters.count
                    && characters[index - 1].isLetter && characters[index + 1].isLetter)
            }.count
            let openParens = previous.filter { $0 == "(" }.count
            let closeParens = previous.filter { $0 == ")" }.count
            if atBoundary, hasHead, wordBoundary, doubleQuotes.isMultiple(of: 2), singleQuotes.isMultiple(of: 2), openParens <= closeParens {
                // The next request's filler belongs to that request, not to
                // the preceding answer payload or a pending continuation.
                let prefix = String(text[..<found.lowerBound])
                let filler = prefix.range(of: #"\b(?:so|uh|um|okay|ok|well|but|and)(?:[,\s]+(?:so|uh|um|okay|ok|well|but|and))*[,\s]*$"#, options: .regularExpression)
                let start = filler.map { text.index(text.startIndex, offsetBy: prefix.distance(from: prefix.startIndex, to: $0.lowerBound)) } ?? found.lowerBound
                starts.append((start, found.upperBound))
            }
            searchStart = found.upperBound
        }
        return starts
    }

    private static func normalized(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "…", with: ".")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
