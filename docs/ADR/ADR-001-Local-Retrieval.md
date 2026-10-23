# ADR-001: Local Meeting Retrieval Strategy

**Status:** Accepted  
**Date:** 2026-08-14  
**Issue:** lunr-studio/Openbridge-Dev #305  
**Decider:** Engineering  

## Context

The Research Observatory rail (#318) needs to surface relevant passages from
prior meetings in response to user questions. The retrieval system must:

1. **Run entirely locally** — no cloud dependency for search queries.
2. **Be fast** — sub-100 ms latency for interactive use at up to 1,000 meetings.
3. **Be lightweight** — minimal memory overhead beyond the index itself.
4. **Support incremental updates** — adding, editing, or deleting meetings
   should not require a full rebuild.
5. **Work on macOS 14+** — the deployment target, with the system SQLite
   (which includes FTS5).
6. **Produce ranked results** with source references
   (`ResearchSourceLocator`) and abstention below a confidence threshold.

The production index is built in #306. This ADR defines the strategy that
#306 will implement.

## Options Considered

### Option A: SQLite FTS5 (Full-Text Search)

**How it works:** Use SQLite's built-in FTS5 virtual table module to create
a full-text index over meeting transcript segments. Query with `MATCH` and
rank by BM25.

**Pros:**
- **Zero dependencies** — SQLite + FTS5 ship with macOS 14+ (verified:
  `SELECT sqlite_compileoption_used('ENABLE_FTS5')` returns 1).
- **Fast** — BM25 ranking in microseconds for small corpora; single-digit
  milliseconds at 1,000 meetings (see benchmark below).
- **Incremental** — `INSERT`, `DELETE`, and `UPDATE` are native operations.
  No rebuild needed for single-meeting changes.
- **Trivial persistence** — the index is a single `.sqlite` file on disk.
- **Built-in ranking** — `bm25()` and `rank` columns provide relevance
  scoring out of the box.
- **Snippets** — `snippet()` function returns context windows around matches,
  perfect for `ResearchEvidence.passage`.

**Cons:**
- **Lexical only** — no semantic understanding. "launch" won't match
  "release" unless the user types the same word.
- **No fuzzy matching** by default — typos require additional configuration
  (trigram tokenizer or external spell correction).
- **Ranking is keyword-frequency based** — not as nuanced as embedding
  similarity for complex queries.

### Option B: Local Embeddings (e.g., all-MiniLM via MLX)

**How it works:** Embed each transcript segment into a dense vector using a
local sentence-transformer model. Store vectors in memory or on disk. At
query time, embed the question and compute cosine similarity against all
stored vectors.

**Pros:**
- **Semantic matching** — "launch date" matches "when do we ship."
- **Better recall for paraphrased questions.**

**Cons:**
- **Heavyweight** — requires a model download (~90 MB for MiniLM),
  inference at index time, and vector storage (~384 floats × segment count).
- **Slow indexing** — embedding 1,000 meetings (~10,000 segments) at
  ~50 ms/segment = ~500 seconds.
- **Query latency** — brute-force cosine similarity over 10K vectors is
  ~5–20 ms, but requires loading the full matrix into memory (~15 MB).
- **Rebuild cost** — changing the model requires re-embedding everything.
- **Privacy surface** — model file is a large opaque binary that must be
  audited and version-pinned.
- **Complex incremental updates** — need to manage vector store growth,
  deletion tombstones, and defragmentation.

### Option C: Hybrid (FTS5 + Embedding Re-rank)

**How it works:** Use FTS5 for initial retrieval (fast, keyword-based),
then re-rank the top-K results using embedding similarity.

**Pros:**
- **Best of both worlds** — fast first-pass, semantic quality improvement.
- **Lazy embedding** — only embed query + top-K passages, not the full corpus.

**Cons:**
- **All of Option B's complexity** — model download, inference, version pinning.
- **Additional latency** — 50–100 ms for the re-rank pass.
- **Premature optimization** — at our corpus size (< 10K segments), FTS5
  alone has sufficient recall for the most common question types
  (decision lookups, action item recall, topic search).

## Decision

**We choose Option A: SQLite FTS5.**

### Rationale

1. **Zero-dependency constraint is paramount.** OpenBridge's local-first
   philosophy means every dependency is a privacy and maintenance liability.
   FTS5 is already compiled into the system SQLite on every Mac we support.

2. **Latency is critical for interactive use.** The benchmark below shows
   sub-1 ms query latency at 1,000 meetings. Embedding-based approaches
   cannot match this without complex ANN index infrastructure.

3. **Corpus size is bounded.** A workspace with 1,000 meetings is an extreme
   case. Most users will have 10–100. FTS5 handles all three sizes with
   negligible performance differences.

4. **Incremental updates are trivial.** Adding a meeting is an `INSERT`.
   Deleting is a `DELETE`. No rebuild, no re-embedding, no defragmentation.

5. **The non-goal is explicit.** #305 says: *"Do not build the production
   index."* We are choosing the strategy, not optimizing it. FTS5 is the
   lowest-risk starting point. If semantic matching proves necessary later,
   Option C (hybrid re-rank) can be layered on top without replacing the
   FTS5 index.

### When to revisit

- If users report that FTS5 misses semantically related discussions (e.g.,
  searching "budget" doesn't find "financial plan"), we will prototype a
  hybrid re-rank layer in a new ADR.
- If corpus size exceeds 10,000 meetings and latency degrades beyond 50 ms,
  we will benchmark ANN libraries (e.g., usearch, FAISS) against FTS5.

## Benchmark Results

The benchmark is in `Tests/OpenBridgeAppTests/RetrievalBenchmarkTests.swift`.
It generates synthetic meeting corpora at three sizes and measures:

- **Index build time** (wall clock)
- **Query latency** (mean of 10 queries)
- **Index file size** on disk

### Results on macOS (Apple Silicon, measured 2026-08-14)

| Corpus Size | Segments | Build Time | Mean Query | Index Size |
|-------------|----------|------------|------------|------------|
| 10 meetings | ~100     | 1 ms       | 0.040 ms   | 48 KB      |
| 100 meetings| ~1,000   | 1 ms       | 0.069 ms   | 172 KB     |
| 1,000 meetings | ~10,000 | 14 ms     | 0.740 ms   | 1.4 MB     |

Additional measurements:
- **Deletion** of ~50 meetings (500 rows) from a 100-meeting index: < 1 ms.
- **Full rebuild** of a 50-meeting index: 1 ms.

All queries returned correct results for keyword-based lookups (50 hits
across 10 queries at every corpus size). The BM25 ranking correctly
prioritized passages with exact term matches.

### FTS5 availability verification

```
sqlite> SELECT sqlite_compileoption_used('ENABLE_FTS5');
1
```

Confirmed on macOS 14 (Sonoma) and macOS 15 (Sequoia) via the system
SQLite at `/usr/bin/sqlite3`.

## Consequences

- **#306** will implement the production index using SQLite FTS5 via
  Swift's `SQLite3` C interface (no SwiftData, no GRDB, no third-party ORM).
- The index will store one row per `MeetingTranscriptSegment` with columns
  for `meetingID`, `segmentID`, `sourceLabel`, `text`, and `workspaceID`.
- Queries will use `MATCH` with `bm25()` ranking and `snippet()` for
  passage extraction.
- Deletion is handled by `DELETE FROM ... WHERE meetingID = ?`.
- Rebuild is `DROP TABLE` + `CREATE TABLE` + batch `INSERT`.
- Abstention threshold: if the top result's BM25 score is below a tuned
  cutoff (default TBD in #306), the system returns `noSource` rather than
  a low-confidence result.
- The index file lives in the workspace's application support directory,
  alongside existing meeting storage.