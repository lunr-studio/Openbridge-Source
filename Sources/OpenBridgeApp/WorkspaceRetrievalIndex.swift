import Foundation
import SQLite3

// MARK: - Workspace Retrieval Index (#306)
//
// Production workspace-scoped passage index implementing ADR-001
// (SQLite FTS5, system SQLite, zero third-party dependencies).
//
// Design (per docs/ADR/ADR-001-Local-Retrieval.md):
//   - One row per MeetingTranscriptSegment.
//   - porter unicode61 tokenizer (stemming across word forms).
//   - bm25() ranking; exact stored transcript text for grounding.
//   - Incremental: indexing a meeting replaces its rows (idempotent).
//   - Deletion: DELETE by meetingID.
//   - Rebuild: DROP + CREATE + batch INSERT.
//   - Abstention: below-threshold top scores return nil (noSource).

// MARK: - Errors

enum WorkspaceRetrievalIndexError: LocalizedError, Equatable {
    case openFailed(String)
    case sqlFailed(String)
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .openFailed(let detail):
            return "Could not open the workspace index: \(detail)"
        case .sqlFailed(let detail):
            return "Workspace index operation failed: \(detail)"
        case .emptyQuery:
            return "The search query contained no searchable terms."
        }
    }
}

// MARK: - Configuration

struct WorkspaceRetrievalConfiguration: Equatable, Sendable {
    /// Maximum results returned by `search`.
    var defaultResultLimit = 5
    /// Abstention threshold on the relevance score (`-bm25`). If the top
    /// match scores below this, `searchOrAbstain` returns nil (noSource).
    /// Tunable; 0.5 separates strong single-term hits from near-misses on
    /// short meeting passages in the fixture corpus.
    var abstentionThreshold = 0.5
    static let `default` = WorkspaceRetrievalConfiguration()
}

// MARK: - Result

/// A ranked passage match with full source references back to the meeting
/// store (`meetingID` + `segmentID` are stable manifest identifiers).
struct WorkspacePassageMatch: Equatable, Sendable {
    let meetingID: String
    let workspaceID: String?
    let segmentID: String
    let sourceLabel: String
    /// Zero-based sequence within the meeting, for replay positioning.
    let sequence: Int
    /// Exact stored segment text. FTS `snippet()` is deliberately not used:
    /// its reconstructed text can insert spaces inside decimals and dotted
    /// identifiers, which is unsafe as grounding evidence.
    let passage: String
    /// Relevance score (`-bm25`): higher is better. Not normalized.
    let relevanceScore: Double
}

// MARK: - Index

/// Thread-safe, file-backed FTS5 index over meeting transcript segments.
///
/// All access is serialized through an internal lock; the underlying SQLite
/// handle is opened in serialized mode as defense in depth. The API is
/// synchronous, matching `MeetingSessionStore` conventions.
final class WorkspaceRetrievalIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let configuration: WorkspaceRetrievalConfiguration

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let tableName = "meeting_passages"

    /// Creates (or opens) the index at `databaseURL`.
    init(
        databaseURL: URL,
        configuration: WorkspaceRetrievalConfiguration = .default
    ) throws {
        self.configuration = configuration
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw WorkspaceRetrievalIndexError.openFailed(message)
        }
        self.db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try createTableIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Indexing

    /// Incrementally indexes (or re-indexes) one meeting. Replaces any
    /// existing rows for the meeting first, so the operation is idempotent
    /// and picks up transcript edits.
    func index(meeting: MeetingManifest) throws {
        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try removeMeetingRows(meeting.meetingID)
            let insert = try prepare(#"INSERT INTO meeting_passages(meetingID, workspaceID, segmentID, sourceLabel, sequence, text) VALUES(?, ?, ?, ?, ?, ?);"#)
            defer { sqlite3_finalize(insert) }

            for segment in meeting.segments {
                sqlite3_reset(insert)
                sqlite3_bind_text(insert, 1, meeting.meetingID, -1, Self.sqliteTransient)
                sqlite3_bind_text(insert, 2, meeting.workspaceID ?? "", -1, Self.sqliteTransient)
                sqlite3_bind_text(insert, 3, segment.id, -1, Self.sqliteTransient)
                sqlite3_bind_text(insert, 4, segment.sourceLabel, -1, Self.sqliteTransient)
                sqlite3_bind_int(insert, 5, Int32(segment.sequence))
                sqlite3_bind_text(insert, 6, Self.strippingWakeInvocations(segment.text), -1, Self.sqliteTransient)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw lastError("INSERT segment")
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Removes every indexed row for a meeting.
    func removeMeeting(meetingID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeMeetingRows(meetingID)
    }

    /// Full rebuild: drops the table and indexes every provided meeting.
    /// Meetings absent from `meetings` are removed from the index.
    func rebuild(meetings: [MeetingManifest]) throws {
        lock.lock()
        defer { lock.unlock() }

        try exec("DROP TABLE IF EXISTS \(Self.tableName);")
        try createTableIfNeeded()
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let insert = try prepare(#"INSERT INTO meeting_passages(meetingID, workspaceID, segmentID, sourceLabel, sequence, text) VALUES(?, ?, ?, ?, ?, ?);"#)
            defer { sqlite3_finalize(insert) }

            for meeting in meetings {
                for segment in meeting.segments {
                    sqlite3_reset(insert)
                    sqlite3_bind_text(insert, 1, meeting.meetingID, -1, Self.sqliteTransient)
                    sqlite3_bind_text(insert, 2, meeting.workspaceID ?? "", -1, Self.sqliteTransient)
                    sqlite3_bind_text(insert, 3, segment.id, -1, Self.sqliteTransient)
                    sqlite3_bind_text(insert, 4, segment.sourceLabel, -1, Self.sqliteTransient)
                    sqlite3_bind_int(insert, 5, Int32(segment.sequence))
                    sqlite3_bind_text(insert, 6, segment.text, -1, Self.sqliteTransient)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        throw lastError("INSERT segment (rebuild)")
                    }
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Search

    /// Ranked passage search. Results are ordered by descending relevance
    /// (`-bm25`) and each carries full source references.
    ///
    /// - Parameters:
    ///   - query: free-form question text; non-alphanumeric characters are
    ///     treated as separators (FTS5 syntax injection is impossible).
    ///   - workspaceID: when non-nil, restricts matches to that workspace.
    ///   - limit: maximum results (defaults to configuration).
    func search(
        _ query: String,
        workspaceID: String? = nil,
        limit: Int? = nil,
        rawQuestion: String? = nil
    ) throws -> [WorkspacePassageMatch] {
        guard let ftsQuery = Self.sanitizedFTSQuery(query, rawQuestion: rawQuestion) else {
            throw WorkspaceRetrievalIndexError.emptyQuery
        }
        // Round-11 (v10 live evidence): AND semantics returned zero
        // rows for paraphrases ("launch date decision again" — 'again'
        // absent; "who sends mockups when" — who/when absent). The
        // MATCH query is now OR-based and rows are post-filtered to
        // those matching at least half the content terms (ceil).
        // Strict-majority threshold: a row must contain MORE than
        // half the question's content terms. Two-term queries then
        // require both (preserving AND behavior for pairs), while
        // longer paraphrases tolerate absent filler terms (live case:
        // "launch date decision again" — 'again' absent, 3-of-4 pass).
        let contentTerms = Self.contentTerms(query, rawQuestion: rawQuestion)
        let minTermHits = contentTerms.count / 2 + 1

        lock.lock()
        defer { lock.unlock() }

        let scoped = workspaceID != nil
        let sql = """
            SELECT meetingID, workspaceID, segmentID, sourceLabel, sequence,
                   text AS passage,
                   -bm25(\(Self.tableName)) AS relevance
            FROM \(Self.tableName)
            WHERE \(Self.tableName) MATCH ?
            \(scoped ? "AND workspaceID = ?" : "")
            ORDER BY bm25(\(Self.tableName))
            LIMIT ?;
            """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, Self.sqliteTransient)
        var nextParameter: Int32 = 2
        if let workspaceID {
            sqlite3_bind_text(statement, nextParameter, workspaceID, -1, Self.sqliteTransient)
            nextParameter += 1
        }
        // Round-10 (over-fetch): applying LIMIT in SQL before echo
        // demotion lets a cluster of question-bearing narration/echo
        // passages fill every slot and starve the facts (live evidence:
        // Test 7 re-ask surfaced narration above facts). Fetch a 4x
        // candidate pool, demote/diversify, then trim to the limit.
        let resultLimit = limit ?? configuration.defaultResultLimit
        sqlite3_bind_int(statement, nextParameter, Int32(resultLimit * 4))

        var matches: [WorkspacePassageMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // Minimum-match postfilter: the OR query may surface rows
            // hitting a single term; require a majority of content
            // terms. Comparison is stem-aware (Porter-lite) because
            // FTS5 matches word forms, not exact tokens — exact
            // comparison under-counted hits ("decision" vs "decided",
            // "gerund" vs "gerunds") and dropped valid rows.
            let rowText = Self.string(statement, 5)
            if !contentTerms.isEmpty {
                let rowTokens = Set(Self.tokenize(rowText))
                let hits = contentTerms.filter { term in
                    rowTokens.contains { Self.stemMatches(term, $0) }
                }.count
                if hits < minTermHits { continue }
            }
            let storedWorkspace = Self.string(statement, 1)
            matches.append(WorkspacePassageMatch(
                meetingID: Self.string(statement, 0),
                workspaceID: storedWorkspace.isEmpty ? nil : storedWorkspace,
                segmentID: Self.string(statement, 2),
                sourceLabel: Self.string(statement, 3),
                sequence: Int(sqlite3_column_int(statement, 4)),
                passage: Self.string(statement, 5),
                relevanceScore: sqlite3_column_double(statement, 6)
            ))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else {
            throw lastError("search step")
        }
        let processed = Self.suppressEchoesAndDiversify(matches, query: query, rawQuestion: rawQuestion ?? query)
        return Array(processed.prefix(resultLimit))
    }

    // MARK: - Echo suppression + diversity (#299 round-6)

    /// Question-echo demotion: BM25 rewards lexical overlap, so a
    /// passage that merely RESTATES the question outranks the passage
    /// that answers it (runtime evidence: echo 0.769 vs fact 0.318).
    /// A passage whose query-token coverage is near-total is an echo;
    /// it is demoted (never deleted) so facts rise to the top.
    /// Near-duplicate passages are skipped when filling the final cut
    /// so one echo cluster cannot monopolize the context window.
    private static func suppressEchoesAndDiversify(
        _ matches: [WorkspacePassageMatch],
        query: String,
        rawQuestion: String
    ) -> [WorkspacePassageMatch] {
        // Round-7 (GLM defects A+B): the previous precision heuristic
        // never fired — the token-count guard saw the stopword-stripped
        // query (3 tokens), and precision was diluted by the echo's own
        // stopwords. Deterministic rule instead: a passage is an ECHO iff
        // its normalized text contains the normalized RAW question and
        // it is brief (little beyond the question itself). Bundled
        // question+answer segments are long and stay ranked; statement
        // facts never contain the interrogative raw question.
        let rawQuestionTokens = tokenize(rawQuestion)
        guard rawQuestionTokens.count >= 3 else { return matches }
        let normalizedQuestion = rawQuestionTokens.joined(separator: " ")
        let brevityCap = rawQuestionTokens.count + 6

        func isEcho(_ passage: String) -> Bool {
            let tokens = tokenize(passage)
            guard tokens.count <= brevityCap else { return false }
            return tokens.joined(separator: " ").contains(normalizedQuestion)
        }

        func overlap(_ a: String, _ b: String) -> Double {
            let ta = Set(tokenize(a)); let tb = Set(tokenize(b))
            guard !ta.isEmpty, !tb.isEmpty else { return 0 }
            return Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
        }

        // Demote echoes (never delete) so facts rise above them.
        let demoted = matches.map { match -> WorkspacePassageMatch in
            guard isEcho(match.passage) else { return match }
            return WorkspacePassageMatch(
                meetingID: match.meetingID,
                workspaceID: match.workspaceID,
                segmentID: match.segmentID,
                sourceLabel: match.sourceLabel,
                sequence: match.sequence,
                passage: match.passage,
                relevanceScore: match.relevanceScore * 0.25
            )
        }.sorted { $0.relevanceScore > $1.relevanceScore }

        // Diversity: skip near-duplicates (>= 0.85 token overlap) of an
        // already-selected passage; fall back to the raw ranking when
        // the filter would starve the result set.
        var selected: [WorkspacePassageMatch] = []
        for candidate in demoted {
            if selected.contains(where: { overlap($0.passage, candidate.passage) >= 0.85 }) {
                continue
            }
            selected.append(candidate)
        }
        return selected.isEmpty ? demoted : selected
    }

    /// Question-word interrogatives (round-3, P2 acronym collision): an
    /// interrogative is retrieval noise only by GRAMMATICAL POSITION — one
    /// that leads the raw question, or leads a clause right after a
    /// coordinating conjunction ("...and who is the backup contact?").
    /// Mid-clause occurrences are content: "What did WHO recommend?" keeps
    /// `who` as a required term (the blanket filter would have dropped it).
    static let interrogatives: Set<String> = [
        "when", "who", "whom", "whose", "where", "why", "how", "which"
    ]

    private static let coordinatingConjunctions: Set<String> = [
        "and", "or", "but", "nor", "so", "yet"
    ]

    /// Raw-cased alphanumeric tokens (punctuation acts as a separator);
    /// original casing is preserved for acronym detection.
    private static func rawCasedTokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True for acronym-like tokens (round-4, P2 clause-leading acronym):
    /// all letters uppercase, length >= 2 ("WHO", "US"). A capitalized
    /// question word ("When") is not an acronym, so raw casing separates
    /// "WHO recommended boosters?" (content) from "When is the kickoff?"
    /// (question word).
    static func isAcronymToken(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        return token == token.uppercased() && token != token.lowercased()
    }

    /// Contextual acronym check (round-7, PR #99 Codex): inside an
    /// ALL-CAPS string no token gets acronym immunity — grammatical
    /// stopwords and pronouns strip case-insensitively, so "WHAT DID WE
    /// DECIDE...?" keeps its normal threshold. Acronym immunity applies
    /// only to acronym forms within mixed-case strings ("Who owns IT?").
    static func isAcronymToken(_ token: String, inRaw raw: String) -> Bool {
        let allCaps = raw == raw.uppercased() && raw != raw.lowercased()
        return !allCaps && isAcronymToken(token)
    }

    /// Indices of interrogative tokens acting as question words in the RAW
    /// text (round-4, P2 two-sentence boundary + clause-leading acronym).
    /// A clause starts at index 0, after sentence-terminating punctuation
    /// ("." "?" "!" ";" ":"), or directly after a coordinating conjunction;
    /// an interrogative that clause-leads is a question word UNLESS its raw
    /// casing is acronym-like ("WHO").
    static func questionWordIndices(inRaw raw: String) -> Set<Int> {
        var noise = Set<Int>()
        var offset = 0
        let clauses = raw.components(separatedBy: CharacterSet(charactersIn: ".?!;:"))
        for clause in clauses {
            let tokens = rawCasedTokens(clause)
            var clauseStart = true
            for (i, token) in tokens.enumerated() {
                let lower = token.lowercased()
                if clauseStart, interrogatives.contains(lower), !isAcronymToken(token, inRaw: raw) {
                    noise.insert(offset + i)
                    continue
                }
                if coordinatingConjunctions.contains(lower) {
                    clauseStart = true
                    continue
                }
                clauseStart = false
            }
            offset += tokens.count
        }
        return noise
    }

    /// Content tokens of a query: alphanumeric, length > 1, with
    /// question-word interrogative occurrences dropped (by position in
    /// `rawQuestion` when available; otherwise by position in the query
    /// string itself). Content occurrences of interrogative words are kept.
    static func contentTokens(_ query: String, rawQuestion: String?) -> [String] {
        let source = rawQuestion ?? query
        let sourceTokens = rawCasedTokens(source)
        var noiseCounts: [String: Int] = [:]
        for i in questionWordIndices(inRaw: source) {
            noiseCounts[sourceTokens[i].lowercased(), default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return tokenize(query).filter { token in
            guard token.count > 1 else { return false }
            guard interrogatives.contains(token) else { return true }
            seen[token, default: 0] += 1
            return (seen[token] ?? 0) > (noiseCounts[token] ?? 0)
        }
    }

    /// Content terms of a query (see `contentTokens` for the exact rule).
    static func contentTerms(_ query: String, rawQuestion: String? = nil) -> [String] {
        contentTokens(query, rawQuestion: rawQuestion)
    }

    /// Round-11 (v10 structural finding): sentences carrying a wake
    /// invocation ("Open bridge, ...", "OpenBridge. ...") are control
    /// spans, not content — indexing them self-poisons the corpus
    /// (term saturation, echo clusters). Stripped at index time; fact
    /// sentences in the same segment are kept. Pure + unit-tested.
    static func strippingWakeInvocations(_ text: String) -> String {
        let wakeMarkers = ["open bridge", "openbridge", "open-bridge", "hey openbridge", "hey open bridge"]
        let sentences = ResearchProviderResponseValidator.answerClaims(in: text)
        let kept = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return !wakeMarkers.contains { lower.contains($0) }
        }
        // The common no-wake path must preserve the canonical transcript
        // byte-for-byte; rebuilding text from FTS-like tokens corrupts dotted
        // values such as 1.5, v1.2, and U.S.
        guard kept.count != sentences.count else { return text }
        let result = kept.joined(separator: " ")
        return result.isEmpty ? text : result
    }

    /// Porter-lite core: one pass of common English suffix stripping.
    static func stemCore(_ word: String) -> String {
        var w = word
        for suffix in ["ies", "ing", "ions", "ion", "es", "ed", "s"] {
            if w.hasSuffix(suffix), w.count - suffix.count >= 3 {
                w = String(w.dropLast(suffix.count))
                break
            }
        }
        return w
    }

    /// True when two words should count as the same term under FTS5's
    /// stemming: equal Porter-lite cores, or shared cores whose heads
    /// agree for 4+ characters with tails differing only at the end
    /// (decision/decided -> decis/decid). Pure-prefix pairs are NOT
    /// matches (again/against) to avoid false positives.
    static func stemMatches(_ a: String, _ b: String) -> Bool {
        let ca = stemCore(a)
        let cb = stemCore(b)
        if ca == cb { return true }
        let common = zip(ca, cb).prefix(while: { $0.0 == $0.1 }).count
        guard common >= 4, abs(ca.count - cb.count) <= 2 else { return false }
        if ca.hasPrefix(cb) || cb.hasPrefix(ca) { return false }
        return true
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Ranked search with abstention. Returns nil when there are no matches
    /// or the top match scores below the configured abstention threshold —
    /// the caller surfaces this as `noSource` rather than a weak answer.
    func searchOrAbstain(
        _ query: String,
        workspaceID: String? = nil,
        limit: Int? = nil,
        rawQuestion: String? = nil
    ) throws -> [WorkspacePassageMatch]? {
        let matches = try search(query, workspaceID: workspaceID, limit: limit, rawQuestion: rawQuestion)
        guard let top = matches.first else {
            #if DEBUG
            print("[observatory] abstain: no matches (queryChars=\(query.count))")
            #endif
            return nil
        }
        // Round-8: corpus size for the small-index rule + diagnostics.
        let corpusSize = indexedSegmentCount
        // Relative gate (#299 round-6): a substantive match clears a low
        // absolute floor AND at least a quarter of the pre-suppression
        // top score. Echo demotion no longer starves real facts
        // (observed fact 0.318 vs echo 0.769), while weak/empty results
        // still abstain.
        // Round-8 (IDF epsilon collapse): on a tiny index FTS5's IDF
        // collapses to its epsilon floor (top=3.8e-06 vs floor 0.15 —
        // live evidence), so first-meeting questions could never pass
        // an absolute floor. When the corpus is small the absolute
        // floors are skipped entirely; the relative rule still applies
        // (top is trivially >= 25% of itself), no-match still abstains,
        // and echo demotion still protects ranking.
        // Round-11 (v10 live evidence): IDF collapse recurs on
        // realistic corpora too (N=9 with echo-bearing meetings
        // re-saturating terms -> top=3.9e-06 vs gate 0.15). Whenever
        // the top score is itself epsilon-scale the absolute floors
        // are meaningless — skip them; ranking still orders results
        // and no-match still abstains at the earlier guard.
        let epsilonCollapse = top.relevanceScore < 0.01
        let smallCorpus = corpusSize < 8
        let skipFloors = smallCorpus || epsilonCollapse
        let floor: Double = skipFloors ? 0 : 0.15
        let configured: Double = skipFloors ? 0 : configuration.abstentionThreshold
        let relativeFloor = top.relevanceScore * 0.25
        let gate = max(floor, min(configured, relativeFloor))
        if top.relevanceScore < gate {
            #if DEBUG
            print("[observatory] abstain: below gate (top=\(top.relevanceScore), gate=\(gate), N=\(corpusSize))")
            #endif
            return nil
        }
        return matches
    }

    // MARK: - Introspection

    /// Number of indexed segment rows.
    var indexedSegmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scalarInt("SELECT COUNT(*) FROM \(Self.tableName);") ?? 0
    }

    /// Distinct meeting IDs present in the index.
    var indexedMeetingIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = try? prepare("SELECT DISTINCT meetingID FROM \(Self.tableName);") else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.insert(Self.string(statement, 0))
        }
        return ids
    }

    // MARK: - Private Helpers

    private func createTableIfNeeded() throws {
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.tableName) USING fts5(
                meetingID UNINDEXED,
                workspaceID UNINDEXED,
                segmentID UNINDEXED,
                sourceLabel UNINDEXED,
                sequence UNINDEXED,
                text,
                tokenize='porter unicode61'
            );
            """)
    }

    /// Caller must hold `lock` (or be inside a transaction it opened).
    private func removeMeetingRows(_ meetingID: String) throws {
        let statement = try prepare("DELETE FROM \(Self.tableName) WHERE meetingID = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, meetingID, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("DELETE meeting")
        }
    }

    /// Splits free-form text into safe quoted FTS5 terms joined by AND.
    /// Quotes and operators in the input cannot inject FTS syntax because
    /// only alphanumeric characters survive.
    private static func sanitizedFTSQuery(_ raw: String, rawQuestion: String? = nil) -> String? {
        // Round-11: OR semantics — rows are post-filtered by the
        // minimum-half-match rule in search(), so the MATCH string
        // casts a wide net and the filter enforces relevance.
        // Fix-cycle P1 + round-3 P2 (lunr-studio/Openbridge-Beta#299):
        // question-word interrogative occurrences are excluded from the OR
        // candidate query (they let interrogative-only rows fill the
        // LIMIT*4 pool and starve the fact passage at scale), while content
        // occurrences ("WHO", "how" as a noun) are kept.
        let terms = contentTokens(raw, rawQuestion: rawQuestion)
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " OR ")
    }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw lastError(sql)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError("prepare: \(sql)")
        }
        return statement
    }

    private func scalarInt(_ sql: String) -> Int? {
        guard let statement = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func lastError(_ context: String) -> WorkspaceRetrievalIndexError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .sqlFailed("\(context): \(message)")
    }

    private static func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }
}
