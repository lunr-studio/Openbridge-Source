import Foundation
import SQLite3
import Testing
@testable import OpenBridgeApp

// MARK: - Retrieval Benchmark Tests (#305)
//
// This suite is a runnable benchmark for the local retrieval strategy
// evaluation (ADR-001). It is NOT a production index. It generates synthetic
// meeting corpora, builds an FTS5 index, and measures build time, query
// latency, and index size.

@Suite(.serialized) struct RetrievalBenchmarkTests {

    // MARK: - FTS5 Availability

    @Test func fts5IsAvailableOnMacOS() throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)

        let createSQL = "CREATE VIRTUAL TABLE test_fts USING fts5(content);"
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, createSQL, nil, nil, &errorMsg)
        if result != SQLITE_OK {
            if let errorMsg {
                let message = String(cString: errorMsg)
                sqlite3_free(errorMsg)
                Issue.record("FTS5 not available: \(message)")
            } else {
                Issue.record("FTS5 not available: unknown error")
            }
            return
        }
        #expect(result == SQLITE_OK)
    }

    // MARK: - Benchmark: 10 Meetings

    @Test func benchmarkTenMeetings() throws {
        let results = try runBenchmark(meetingCount: 10, label: "10-meetings")
        printResults("10 Meetings", results: results)

        #expect(results.queryResultCount > 0)
        #expect(results.buildTimeMS < 1000)
        #expect(results.meanQueryMS < 50)
    }

    // MARK: - Benchmark: 100 Meetings

    @Test func benchmarkHundredMeetings() throws {
        let results = try runBenchmark(meetingCount: 100, label: "100-meetings")
        printResults("100 Meetings", results: results)

        #expect(results.queryResultCount > 0)
        #expect(results.buildTimeMS < 5000)
        #expect(results.meanQueryMS < 50)
    }

    // MARK: - Benchmark: 1000 Meetings

    @Test func benchmarkThousandMeetings() throws {
        let results = try runBenchmark(meetingCount: 1000, label: "1000-meetings")
        printResults("1000 Meetings", results: results)

        #expect(results.queryResultCount > 0)
        #expect(results.buildTimeMS < 10_000)
        #expect(results.meanQueryMS < 50)
    }

    // MARK: - Benchmark: Incremental Deletion

    @Test func benchmarkDeletionBehavior() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-bench-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("bench.sqlite").path
        let corpus = SyntheticCorpus.generate(meetingCount: 100)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        try createFTS5Table(db: db)
        try insertCorpus(db: db, corpus: corpus)

        let sizeBefore = fileSize(at: dbPath)

        let deleteStart = Date()
        try rawExec(db, sql: "DELETE FROM meeting_segments WHERE meetingID LIKE 'meeting-0%';")
        let deleteElapsed = Date().timeIntervalSince(deleteStart) * 1000

        let sizeAfter = fileSize(at: dbPath)
        let remaining = try countRows(db: db)
        #expect(remaining < corpus.totalSegments)

        print("Benchmark Deletion: \(Int(deleteElapsed))ms, size \(sizeBefore) to \(sizeAfter) bytes, remaining rows: \(remaining)")
    }

    // MARK: - Benchmark: Rebuild

    @Test func benchmarkRebuildBehavior() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-bench-rebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("bench.sqlite").path
        let corpus = SyntheticCorpus.generate(meetingCount: 50)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        try createFTS5Table(db: db)
        try insertCorpus(db: db, corpus: corpus)

        let rebuildStart = Date()
        try rawExec(db, sql: "DROP TABLE meeting_segments;")
        try createFTS5Table(db: db)
        try insertCorpus(db: db, corpus: corpus)
        let rebuildElapsed = Date().timeIntervalSince(rebuildStart) * 1000

        let count = try countRows(db: db)
        #expect(count == corpus.totalSegments)

        print("Benchmark Rebuild (50 meetings): \(Int(rebuildElapsed))ms, \(count) rows")
    }

    // MARK: - Helpers

    private struct BenchmarkResults {
        let buildTimeMS: Int
        let meanQueryMS: Double
        let indexSizeBytes: Int
        let queryResultCount: Int
    }

    private func runBenchmark(meetingCount: Int, label: String) throws -> BenchmarkResults {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-bench-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("bench.sqlite").path
        let corpus = SyntheticCorpus.generate(meetingCount: meetingCount)

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw BenchmarkError.openFailed
        }

        let buildStart = Date()
        try createFTS5Table(db: db)
        try insertCorpus(db: db, corpus: corpus)
        let buildTime = Date().timeIntervalSince(buildStart) * 1000

        let indexSize = fileSize(at: dbPath)

        let queries = [
            "launch date", "budget approval", "design review",
            "action item", "decision", "follow up",
            "timeline", "testing", "deployment", "roadmap"
        ]
        var totalQueryTime: TimeInterval = 0
        var totalResults = 0
        for query in queries {
            let qStart = Date()
            let results = try queryFTS5(db: db, searchTerm: query, limit: 5)
            totalQueryTime += Date().timeIntervalSince(qStart)
            totalResults += results.count
        }
        let meanQuery = totalQueryTime / Double(queries.count) * 1000

        return BenchmarkResults(
            buildTimeMS: Int(buildTime),
            meanQueryMS: meanQuery,
            indexSizeBytes: indexSize,
            queryResultCount: totalResults
        )
    }

    private func printResults(_ label: String, results: BenchmarkResults) {
        print("""
        Benchmark: \(label)
           Build: \(results.buildTimeMS)ms
           Mean query: \(String(format: "%.3f", results.meanQueryMS))ms
           Index size: \(formatBytes(results.indexSizeBytes))
           Total results across 10 queries: \(results.queryResultCount)
        """)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func fileSize(at path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? 0
    }

    // MARK: - SQLite Helpers

    private enum BenchmarkError: Error {
        case openFailed
        case execFailed(String)
        case prepareFailed(String)
    }

    private func rawExec(_ db: OpaquePointer?, sql: String) throws {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if result != SQLITE_OK {
            let message = errorMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMsg)
            throw BenchmarkError.execFailed(message)
        }
    }

    private func createFTS5Table(db: OpaquePointer?) throws {
        try rawExec(db, sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS meeting_segments USING fts5(
                meetingID UNINDEXED,
                segmentID UNINDEXED,
                sourceLabel UNINDEXED,
                text,
                tokenize='porter unicode61'
            );
            """)
    }

    private func insertCorpus(db: OpaquePointer?, corpus: SyntheticCorpus) throws {
        try rawExec(db, sql: "BEGIN TRANSACTION;")

        var stmt: OpaquePointer?
        let insertSQL = "INSERT INTO meeting_segments(meetingID, segmentID, sourceLabel, text) VALUES(?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            try? rawExec(db, sql: "ROLLBACK;")
            throw BenchmarkError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for row in corpus.rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.meetingID, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, row.segmentID, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, row.sourceLabel, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, row.text, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                try? rawExec(db, sql: "ROLLBACK;")
                throw BenchmarkError.execFailed("INSERT failed: \(msg)")
            }
        }

        try rawExec(db, sql: "COMMIT;")
    }

    private func queryFTS5(db: OpaquePointer?, searchTerm: String, limit: Int) throws -> [String] {
        var stmt: OpaquePointer?
        let sql = """
            SELECT snippet(meeting_segments, 3, '<<', '>>', '...', 16)
            FROM meeting_segments
            WHERE meeting_segments MATCH ?
            ORDER BY bm25(meeting_segments)
            LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw BenchmarkError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, searchTerm, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cString))
            }
        }
        return results
    }

    private func countRows(db: OpaquePointer?) throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meeting_segments;", -1, &stmt, nil) == SQLITE_OK else {
            throw BenchmarkError.prepareFailed("COUNT query failed")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

// MARK: - Synthetic Corpus Generator

struct SyntheticCorpus {
    struct Row {
        let meetingID: String
        let segmentID: String
        let sourceLabel: String
        let text: String
    }

    let rows: [Row]
    let totalSegments: Int

    static func generate(meetingCount: Int) -> SyntheticCorpus {
        let templates = [
            "We decided to move the launch date to September.",
            "The budget approval is pending from finance.",
            "Action item: follow up with the design team on the mockups.",
            "We reviewed the testing roadmap and identified key milestones.",
            "The deployment timeline needs to be updated after the review.",
            "Decision: we will use Swift for the new module.",
            "Let us revisit the architecture decision next week.",
            "The roadmap includes three major releases this quarter.",
            "We need to schedule a design review before the launch.",
            "The follow up from last week sync is still open.",
            "Budget constraints may impact the timeline.",
            "Testing revealed issues with the deployment pipeline.",
            "The team agreed on the new API design approach.",
            "We should document this decision for future reference.",
            "The next milestone is the beta release in October.",
        ]

        var rows: [Row] = []
        for meetingIndex in 0..<meetingCount {
            let meetingID = "meeting-\(meetingIndex)"
            let segmentCount = 8 + (meetingIndex % 5)
            for segIndex in 0..<segmentCount {
                let text = templates[segIndex % templates.count]
                rows.append(Row(
                    meetingID: meetingID,
                    segmentID: "seg-\(meetingIndex)-\(segIndex)",
                    sourceLabel: "Room",
                    text: text
                ))
            }
        }

        return SyntheticCorpus(rows: rows, totalSegments: rows.count)
    }
}