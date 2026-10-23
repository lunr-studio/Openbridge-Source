import Foundation

private final class MeetingManifestTransactionLocks: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func lock(for url: URL) -> NSRecursiveLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = url.standardizedFileURL.path
        if let existing = locks[key] { return existing }
        let lock = NSRecursiveLock()
        locks[key] = lock
        return lock
    }
}

struct MeetingTranscriptBundleExportResult: Equatable, Sendable {
    let urls: [URL]
    let includedCleaned: Bool

    var filenames: [String] {
        urls.map(\.lastPathComponent)
    }
}

/// Manages durable local meeting session storage under Application Support.
///
/// Each meeting gets its own directory with:
/// - manifest.json (atomic writes, versioned schema)
/// - audio/ (segmented recordings)
/// - transcripts/ (incremental spans)
/// - events/ (meeting event logs)
///
/// All operations are local-only. No network access.
struct MeetingSessionStore: Sendable {
    // Capture and transcription now write from different executors. Protect
    // complete read/modify/write transactions, not only the final rename.
    // Recursive because existing repository operations call saveManifest.
    private static let manifestTransactionLocks = MeetingManifestTransactionLocks()

    func withManifestTransaction<T>(meetingID: String, _ operation: () throws -> T) rethrows -> T {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static let manifestDidChangeNotification = Notification.Name(
        "studio.lunr.openbridge.meetingManifestDidChange"
    )
    static let changedMeetingIDUserInfoKey = "meetingID"

    let rootDirectory: URL
    // FileManager.default is thread-safe but not annotated Sendable by Apple.
    private nonisolated(unsafe) let fileManager = FileManager.default
    private let manifestFilename = "manifest.json"
    private let intelligenceFilename = "intelligence.json"
    private let saveFaultInjector: @Sendable (MeetingSessionStoreFaultPoint) throws -> Void
    private let meetingDeletionObserver: @Sendable (String) -> Void

    init(
        rootDirectory: URL? = nil,
        saveFaultInjector: @Sendable @escaping (MeetingSessionStoreFaultPoint) throws -> Void = { _ in },
        meetingDeletionObserver: @Sendable @escaping (String) -> Void = {
            ObservatorySharedIndex.purgeMeeting(meetingID: $0)
        }
    ) {
        self.saveFaultInjector = saveFaultInjector
        self.meetingDeletionObserver = meetingDeletionObserver
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootDirectory = appSupport
                .appendingPathComponent("OpenBridge", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }
    }

    // MARK: - Directory structure

    func meetingDirectory(for meetingID: String) -> URL {
        rootDirectory.appendingPathComponent(meetingID, isDirectory: true)
    }

    func manifestURL(for meetingID: String) -> URL {
        meetingDirectory(for: meetingID).appendingPathComponent(manifestFilename)
    }

    func audioDirectory(for meetingID: String) -> URL {
        meetingDirectory(for: meetingID).appendingPathComponent("audio", isDirectory: true)
    }

    func transcriptDirectory(for meetingID: String) -> URL {
        meetingDirectory(for: meetingID).appendingPathComponent("transcripts", isDirectory: true)
    }

    func intelligenceSidecarURL(for meetingID: String) -> URL {
        meetingDirectory(for: meetingID).appendingPathComponent(intelligenceFilename)
    }

    /// Recover each persisted active journal without guessing timing or discarding audio.
    func reconcileOnlineAudio(meetingID: String) throws -> MeetingManifest {
        try withManifestTransaction(meetingID: meetingID) {
            var manifest = try load(meetingID: meetingID)
            for (sourceID, journal) in manifest.activeSourceJournals {
                guard let source = manifest.sources.first(where: { $0.sourceID == sourceID }) else { continue }
                let url = audioDirectory(for: meetingID).appendingPathComponent(journal.filename)
                guard fileManager.fileExists(atPath: url.path) else {
                    // The marker is committed before the WAV is opened. A crash
                    // between those steps leaves no audio to recover.
                    manifest.activeSourceJournals.removeValue(forKey: sourceID)
                    continue
                }
                _ = try MeetingWAVFile.repairHeaderIfNeeded(at: url)
                guard let duration = try MeetingWAVFile.durationSeconds(at: url),
                      let recordedRate = try MeetingWAVFile.sampleRate(at: url) else { continue }
                if duration == 0 {
                    // A valid header with no PCM is another pre-first-sample crash.
                    try fileManager.removeItem(at: url)
                    manifest.activeSourceJournals.removeValue(forKey: sourceID)
                    continue
                }
                let id = "\(sourceID)-\(journal.segmentIndex)"
                if !manifest.audioArtifacts.contains(where: { $0.id == id }) {
                    manifest.audioArtifacts.append(MeetingAudioArtifact(id: id, sourceID: sourceID,
                        sourceKind: source.kind, sequence: journal.segmentIndex, relativePath: journal.filename,
                        startOffset: journal.startOffset, endOffset: journal.startOffset + duration,
                        sampleRate: recordedRate, channelCount: 1))
                }
                manifest.activeSourceJournals.removeValue(forKey: sourceID)
            }
            manifest.audioSegments = manifest.audioArtifacts.map(\.relativePath)
            try saveManifest(manifest)
            return manifest
        }
    }

    func completeOnlineRecovery(meetingID: String) throws -> Bool {
        try withManifestTransaction(meetingID: meetingID) {
            var manifest = try reconcileOnlineAudio(meetingID: meetingID)
            guard onlineArtifactCoverageIsComplete(manifest) else { return false }
            manifest.state = .completed
            manifest.endedAt = manifest.endedAt ?? Date()
            try saveManifest(manifest)
            return true
        }
    }

    /// A receipt and its raw result (including successful silence) are one
    /// transaction. Inspect nested WAVs as well as the manifest: unrecognized
    /// files or active journals must never disappear through retention/recovery.
    func onlineArtifactCoverageIsComplete(_ manifest: MeetingManifest) -> Bool {
        guard !manifest.audioArtifacts.isEmpty, manifest.activeSourceJournals.isEmpty else { return false }
        let artifacts = manifest.audioArtifacts
        guard Set(artifacts.map(\.id)).count == artifacts.count,
              Set(artifacts.map(\.relativePath)).count == artifacts.count else { return false }
        let receipts = Set(manifest.transcribedArtifactIDs)
        for artifact in artifacts {
            guard receipts.contains(artifact.id), artifact.startOffset.isFinite, artifact.endOffset.isFinite,
                  artifact.endOffset >= artifact.startOffset,
                  let source = manifest.sources.first(where: { $0.sourceID == artifact.sourceID }),
                  source.kind == artifact.sourceKind else { return false }
            if manifest.retentionPolicy != .neverStoreTranscript {
                guard let raw = manifest.rawArtifactSegments[artifact.id], raw.allSatisfy({
                    $0.meetingID == manifest.meetingID && $0.isFinal && $0.artifactID == artifact.id
                        && $0.sourceID == artifact.sourceID && $0.sourceSequence == artifact.sequence
                        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) else { return false }
            }
        }
        guard Set(manifest.segments.map(\.id)).count == manifest.segments.count,
              Set(manifest.segments.map(\.sequence)).count == manifest.segments.count,
              manifest.segments.allSatisfy({ segment in
                  segment.meetingID == manifest.meetingID && segment.isFinal
                      && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && artifacts.contains { $0.id == segment.artifactID && $0.sourceID == segment.sourceID }
              }) else { return false }
        let directory = audioDirectory(for: manifest.meetingID)
        guard fileManager.fileExists(atPath: directory.path) else { return true }
        var enumerationFailed = false
        guard let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { return false }
        let knownPaths = Set(artifacts.map { directory.appendingPathComponent($0.relativePath).standardizedFileURL.path })
        for case let file as URL in files where file.pathExtension.lowercased() == "wav" {
            guard knownPaths.contains(file.standardizedFileURL.path) else { return false }
        }
        return !enumerationFailed
    }

    /// One transaction merges each track without losing concurrent transcript writes.
    func saveSourceCaptureProgress(meetingID: String, sourceID: String,
                                   artifacts: [MeetingAudioArtifact], journal: MeetingActiveJournal?) throws {
        try withManifestTransaction(meetingID: meetingID) {
            var manifest = try load(meetingID: meetingID)
            let known = Set(manifest.audioArtifacts.map(\.id))
            manifest.audioArtifacts.append(contentsOf: artifacts.filter { !known.contains($0.id) })
            manifest.activeSourceJournals[sourceID] = journal
            manifest.audioSegments = manifest.audioArtifacts.map(\.relativePath)
            manifest.lastCompletedSegmentIndex = manifest.audioArtifacts.count
            try saveManifest(manifest)
        }
    }

    // MARK: - CRUD operations

    func create(_ manifest: MeetingManifest) throws {
        let dir = meetingDirectory(for: manifest.meetingID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectory(for: manifest.meetingID), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transcriptDirectory(for: manifest.meetingID), withIntermediateDirectories: true)
        try setPrivatePermissions(dir)
        try saveManifest(manifest)
    }

    func load(meetingID: String) throws -> MeetingManifest {
        let url = manifestURL(for: meetingID)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(MeetingManifest.self, from: data)
        // Build 21 could persist a fully valid cloud cleanup revision with a
        // nil activation pointer because the save-time validator compared its
        // provider model against the local Gemma repository. Reconcile the
        // derived pointer in memory on read so the already-completed result is
        // immediately available without another provider request or charge.
        reconcileActiveCleanupRevision(in: &manifest)
        return manifest
    }

    func saveManifest(_ manifest: MeetingManifest) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: manifest.meetingID))
        lock.lock()
        defer { lock.unlock() }
        let dir = meetingDirectory(for: manifest.meetingID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        // Reconcile derived cleanup data on every repository write. This is a
        // safety net for older callers that still load/mutate/save a manifest:
        // if their canonical transcript changed, no cleanup based on the old
        // source can remain active.
        var persistedManifest = manifest
        reconcileCleanupStaleness(in: &persistedManifest)
        reconcileActiveCleanupRevision(in: &persistedManifest)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(persistedManifest)

        // Crash-safe replacement: write to temp file, then atomically swap.
        // Uses FileManager.replaceItem so the old manifest stays valid
        // until the new one is fully in place — no data-loss window.
        let finalURL = manifestURL(for: manifest.meetingID)
        let tempURL = dir.appendingPathComponent(".manifest.json.tmp")

        // Write the new manifest to a temp file first
        try data.write(to: tempURL, options: [Data.WritingOptions.atomic])
        try setPrivatePermissions(tempURL)
        try saveFaultInjector(.beforeManifestReplacement)

        if fileManager.fileExists(atPath: finalURL.path) {
            // Atomically replace the existing file — old manifest remains
            // valid until the swap completes
            var resultingURL: NSURL?
            try fileManager.replaceItem(
                at: finalURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultingURL
            )
        } else {
            // No existing manifest — just move the temp into place
            try fileManager.moveItem(at: tempURL, to: finalURL)
        }
        try setPrivatePermissions(finalURL)
        NotificationCenter.default.post(
            name: Self.manifestDidChangeNotification,
            object: nil,
            userInfo: [Self.changedMeetingIDUserInfoKey: manifest.meetingID]
        )
    }

    /// Saves recorder-owned progress as one manifest transaction. Including
    /// completed filenames and boundaries whenever the active-journal pointer
    /// advances prevents that pointer from outrunning an earlier failed save.
    func saveCaptureProgress(
        meetingID: String,
        completedSegmentFilenames: [String],
        chunkBoundaries: [MeetingChunkBoundary],
        activeJournal: MeetingActiveJournal?
    ) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        manifest.lastCompletedSegmentIndex = completedSegmentFilenames.count
        manifest.audioSegments = completedSegmentFilenames
        manifest.chunkBoundaries = chunkBoundaries
        manifest.activeJournal = activeJournal
        try saveManifest(manifest)
    }

    func listMeetings() throws -> [MeetingManifest] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        var meetings: [MeetingManifest] = []

        for dir in contents where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let manifestPath = dir.appendingPathComponent(manifestFilename)
            guard fileManager.fileExists(atPath: manifestPath.path) else { continue }
            do {
                let manifest = try load(meetingID: dir.lastPathComponent)
                meetings.append(manifest)
            } catch {
                // Skip corrupted manifests
                continue
            }
        }

        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    func rename(meetingID: String, newTitle: String) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        manifest.title = newTitle
        try saveManifest(manifest)
    }

    func delete(meetingID: String) throws {
        try MeetingConversationStore.locked(self) {
        let dir = meetingDirectory(for: meetingID)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        // Deletion is the durable source-of-truth boundary. Always purge
        // derived retrieval rows here, including retention/recovery callers
        // and calls made while the Research Beta is disabled.
        meetingDeletionObserver(meetingID)
        NotificationCenter.default.post(
            name: Self.manifestDidChangeNotification,
            object: nil,
            userInfo: [Self.changedMeetingIDUserInfoKey: meetingID]
        )
        try MeetingConversationStore(store: self).purgeReferences(to: meetingID)
        }
    }

    func deleteAll() throws {
        try MeetingConversationStore.locked(self) {
        let meetingIDs = (try? listMeetings().map(\.meetingID)) ?? []
        if fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.removeItem(at: rootDirectory)
        }
        meetingIDs.forEach(meetingDeletionObserver)
        NotificationCenter.default.post(
            name: Self.manifestDidChangeNotification,
            object: nil
        )
        }
    }

    // MARK: - Saved meeting intelligence

    /// Loads the meeting-scoped derived intelligence file. A missing file is
    /// expected for older meetings and for meetings whose tools have not run.
    func loadIntelligenceSidecar(meetingID: String) throws -> MeetingIntelligenceSidecar? {
        let url = intelligenceSidecarURL(for: meetingID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(MeetingIntelligenceSidecar.self, from: Data(contentsOf: url))
        guard sidecar.schemaVersion == MeetingIntelligenceSidecar.currentSchemaVersion else {
            throw MeetingIntelligenceArtifactError.unsupportedSidecarSchema
        }
        guard sidecar.meetingID == meetingID else {
            throw MeetingIntelligenceArtifactError.sidecarMeetingMismatch
        }
        return sidecar
    }

    /// Persists one complete sidecar transaction. A temp-file swap means a
    /// crash leaves either the old valid result or the new valid result,
    /// never a partially written JSON document.
    func saveIntelligenceSidecar(_ sidecar: MeetingIntelligenceSidecar) throws {
        let meetingURL = meetingDirectory(for: sidecar.meetingID)
        guard fileManager.fileExists(atPath: manifestURL(for: sidecar.meetingID).path) else {
            throw MeetingSessionStoreError.meetingNotFound(sidecar.meetingID)
        }
        guard sidecar.schemaVersion == MeetingIntelligenceSidecar.currentSchemaVersion else {
            throw MeetingIntelligenceArtifactError.unsupportedSidecarSchema
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        let finalURL = intelligenceSidecarURL(for: sidecar.meetingID)
        let tempURL = meetingURL.appendingPathComponent(".intelligence.json.tmp")
        try data.write(to: tempURL, options: [.atomic])
        try setPrivatePermissions(tempURL)

        if fileManager.fileExists(atPath: finalURL.path) {
            var resultingURL: NSURL?
            try fileManager.replaceItem(
                at: finalURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultingURL
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: finalURL)
        }
        try setPrivatePermissions(finalURL)
    }

    func saveSummary(_ artifact: MeetingSummaryArtifact, meetingID: String) throws {
        var sidecar = try loadIntelligenceSidecar(meetingID: meetingID)
            ?? MeetingIntelligenceSidecar(meetingID: meetingID)
        sidecar.summary = artifact
        try saveIntelligenceSidecar(sidecar)
    }

    func saveActionsAndDecisions(
        _ artifact: MeetingActionsDecisionsArtifact,
        meetingID: String
    ) throws {
        var sidecar = try loadIntelligenceSidecar(meetingID: meetingID)
            ?? MeetingIntelligenceSidecar(meetingID: meetingID)
        sidecar.actionsAndDecisions = artifact
        try saveIntelligenceSidecar(sidecar)
    }

    func deleteIntelligenceArtifact(_ kind: MeetingIntelligenceArtifactKind, meetingID: String) throws {
        guard var sidecar = try loadIntelligenceSidecar(meetingID: meetingID) else { return }
        switch kind {
        case .summary:
            sidecar.summary = nil
        case .actionsAndDecisions:
            sidecar.actionsAndDecisions = nil
        }

        let sidecarURL = intelligenceSidecarURL(for: meetingID)
        if sidecar.summary == nil, sidecar.actionsAndDecisions == nil {
            try fileManager.removeItem(at: sidecarURL)
        } else {
            try saveIntelligenceSidecar(sidecar)
        }
    }

    // MARK: - Retention enforcement

    /// Deletes meetings whose retention policy has expired.
    ///
    /// A meeting is expired when `endedAt ?? startedAt` plus the policy's
    /// retention window is in the past. `.keepUntilDeleted` and
    /// `.deleteAudioAfterTranscript` meetings are never fully pruned by this
    /// method — the latter deletes only the raw audio once a safe transcript
    /// exists (see `enforceAudioRetention`).
    ///
    /// Returns the number of meetings removed.
    @discardableResult
    func enforceRetentionPolicy(now: Date = Date()) throws -> Int {
        let meetings = try listMeetings()
        var deletedCount = 0
        var firstPruneFailure: Error?

        for manifest in meetings {
            // deleteAudioAfterTranscript and keepUntilDeleted both return nil
            // from retentionDays and are never fully pruned here.
            guard let retentionDays = manifest.retentionPolicy.retentionDays else {
                continue
            }

            let referenceDate = manifest.endedAt ?? manifest.startedAt
            let expirationDate = referenceDate.addingTimeInterval(TimeInterval(retentionDays) * 24 * 60 * 60)

            if expirationDate <= now {
                // Wave-11 (3876962676): isolate per-meeting prune failures.
                // A temporary failure (e.g. an unwritable directory) must not
                // abort the whole pass BEFORE the pending-audio reconciliation
                // below runs - other meetings still get pruned and reconciled;
                // the first failure is rethrown after the pass so the caller
                // knows a prune did not complete.
                do {
                    try delete(meetingID: manifest.meetingID)
                    deletedCount += 1
                } catch {
                    if firstPruneFailure == nil { firstPruneFailure = error }
                }
            }
        }

        // Wave-10 (3876862720): reconcile pending retention after relaunch. If
        // the process exited after the completed manifest was saved but before
        // the stop-time enforcement block ran, the meeting is terminal while
        // its raw audio remains - completed meetings are not offered recovery
        // and never return retentionDays above, so no other path would ever
        // enforce the selected policy. Re-run the same safety-gated enforcement;
        // a failure is non-fatal (retried on the next launch).
        let pendingAudioDeletion = meetings.filter {
            $0.retentionPolicy == .deleteAudioAfterTranscript && $0.state == .completed
        }
        for manifest in pendingAudioDeletion {
            let dir = audioDirectory(for: manifest.meetingID)
            if fileManager.fileExists(atPath: dir.path) {
                try? enforceAudioRetention(meetingID: manifest.meetingID)
            }
        }

        if let firstPruneFailure { throw firstPruneFailure }
        return deletedCount
    }

    /// Enforces `.deleteAudioAfterTranscript` for a single meeting by removing
    /// raw audio files once a valid canonical transcript exists.
    ///
    /// **Safety gates — audio is never deleted when:**
    /// 1. The meeting has no final typed segments AND no legacy transcript
    ///    spans (transcription failed or never ran).
    /// 2. The meeting state is `.interrupted` (recovery is still pending).
    ///
    /// Cleanup failure does not block deletion when a valid original
    /// transcript already exists — the safety decision is based on the
    /// canonical transcript, not on cleanup results.
    ///
    /// Returns `true` when audio was deleted, `false` when a safety gate
    /// prevented deletion.
    @discardableResult
    func enforceAudioRetention(meetingID: String, now: Date = Date()) throws -> Bool {
        let manifest = try load(meetingID: meetingID)
        guard manifest.retentionPolicy == .deleteAudioAfterTranscript else {
            return false
        }
        guard canSafelyDeleteAudio(manifest) else {
            return false
        }

        let audioDir = audioDirectory(for: meetingID)

        // Wave-12 (3876176424): persist the CLEARED manifest BEFORE removing
        // the audio directory, so a failure before removal leaves everything
        // intact and the manifest never advertises segments whose audio was
        // deleted (a post-removal save failure previously produced that
        // inconsistent state AND made the "audio preserved" message a lie).
        // Removal is the LAST step - if it fails, audio stays on disk (harmless,
        // reconciled on the next launch) with a consistent manifest.
        var updated = try load(meetingID: meetingID)
        // Retain source/timing metadata and receipts after deleting the bytes.
        // If removal fails, the next launch can still prove coverage of both tracks.
        updated.activeSourceJournals = [:]
        updated.audioSegments = []
        try saveManifest(updated)

        if fileManager.fileExists(atPath: audioDir.path) {
            try fileManager.removeItem(at: audioDir)
        }

        // Re-create the empty audio directory so future structure is intact.
        // Non-fatal: the audio is already gone and the manifest is consistent.
        try? fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return true
    }

    /// Evaluates the safety gates for audio deletion without performing any
    /// I/O. Exposed for tests and UI to explain why audio is being preserved.
    func canSafelyDeleteAudio(_ manifest: MeetingManifest) -> Bool {
        if manifest.captureMode == .online {
            return manifest.state == .completed && onlineArtifactCoverageIsComplete(manifest)
        }
        // Gate 1: recovery still pending — never delete audio.
        if manifest.state == .interrupted {
            return false
        }

        // Gate 2: a usable transcript must exist. Wave-4 (3876353121): a
        // PARTIAL transcript is NOT enough — if recorded audio is on disk,
        // EVERY recorded audio index (parsed from segment_NNNN.wav filenames,
        // never assumed contiguous — same semantics as the recovery router)
        // must have a canonically-valid usable final segment. Otherwise
        // finalizing a partially-recovered meeting would irreversibly delete
        // every still-untranscribed segment.
        let audioDir = audioDirectory(for: manifest.meetingID)
        let diskIndices: [Int]
        if let contents = try? fileManager.contentsOfDirectory(atPath: audioDir.path) {
            // Wave-14 (3884384378): reject unparseable WAV names BEFORE
            // deletion. A WAV whose name is not a parseable segment_<Int>.wav
            // (e.g. a legacy/recovered segment_backup.wav) is silently dropped
            // by the compactMap below - if the remaining indices are covered,
            // or the malformed file is the ONLY audio with an otherwise valid
            // typed transcript, deletion would remove audio whose transcript
            // coverage was never established. Treat ANY unrecognized or
            // unparseable WAV as a safety-gate refusal.
            let unparseableWAV = contents.contains { name in
                guard name.lowercased().hasSuffix(".wav") else { return false }
                guard name.hasPrefix("segment_") else { return true }
                let stem = name.dropFirst("segment_".count).dropLast(".wav".count)
                return Int(stem) == nil
            }
            guard !unparseableWAV else { return false }
            diskIndices = contents
                .filter { $0.hasPrefix("segment_") && $0.lowercased().hasSuffix(".wav") }
                .compactMap { name -> Int? in
                    let stem = name.dropFirst("segment_".count).dropLast(".wav".count)
                    return Int(stem)
                }
        } else if fileManager.fileExists(atPath: audioDir.path) {
            // Wave-13 (3877338958): fail CLOSED. A failed enumeration (e.g. a
            // temporarily unreadable audio directory) must NOT read as "no
            // audio on disk" - a canonically valid but partial transcript
            // could otherwise pass the no-disk branch and removeItem might
            // still succeed (deletion depends on the PARENT directory's
            // permissions), irreversibly removing unverified recordings.
            return false
        } else {
            // Genuinely absent/empty - nothing recorded to protect.
            diskIndices = []
        }

        let usableSegmentIndices = Set(
            manifest.segments
                .filter {
                    $0.meetingID == manifest.meetingID && $0.isFinal
                        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .map { $0.sequence }
        )
        // Wave-10 (3876862709): deletion requires the WHOLE typed set to be
        // canonically valid (the same predicate the finalize path enforces).
        // usableSegmentIndices silently filters bad entries, so a foreign /
        // non-final / empty / duplicate typed segment next to valid ones would
        // otherwise pass coverage while the Original export still contains the
        // corrupt entry and the finalize predicate rejects it.
        let allTypedValid = manifest.segments.allSatisfy {
            $0.meetingID == manifest.meetingID && $0.isFinal
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let ids = Set(manifest.segments.map(\.id))
        let sequences = Set(manifest.segments.map(\.sequence))
        let typedSetCanonicallyValid = allTypedValid
            && ids.count == manifest.segments.count
            && sequences.count == manifest.segments.count

        if !diskIndices.isEmpty {
            // Full coverage required: every on-disk audio index must have a
            // usable final segment AND the typed set must be canonically valid.
            if diskIndices.allSatisfy({ usableSegmentIndices.contains($0) }),
               typedSetCanonicallyValid {
                return true
            }
            // Wave-8 (3876762103): the legacy-span fallback applies ONLY when
            // there are NO typed segments - canonical export uses the typed
            // array whenever it is nonempty (legacy spans are omitted), so
            // deletion coverage must match that same representation. A
            // migrated/recovered manifest with typed segments + legacy spans
            // must not delete audio the Original export would omit.
            guard manifest.segments.isEmpty else {
                return false
            }
            // Legacy fallback: map each MEANINGFUL legacy span to its
            // segment index (spans are stored as "[Segment N] text" -> index
            // N-1) and require INDEX-AWARE coverage of every recorded audio
            // file. Wave-5 (3876574873): a count-only match is not enough -
            // one span + a lone segment_0005.wav would falsely pass. A span
            // whose index cannot be parsed does not count as coverage (the
            // audio is preserved rather than risking deletion).
            let coveredIndices = Set(manifest.transcriptSpans.compactMap { span -> Int? in
                let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                // Wave-6 (3876623273): validate the TEXT AFTER the closing
                // bracket - "[Segment 1]   " has a nonempty trimmed span
                // but NO transcript text, and must not count as coverage.
                guard trimmed.hasPrefix("[Segment "), let close = trimmed.firstIndex(of: "]") else {
                    return nil
                }
                let number = trimmed[
                    trimmed.index(trimmed.startIndex, offsetBy: "[Segment ".count)..<close
                ]
                guard let n = Int(number) else { return nil }
                let suffix = trimmed[trimmed.index(after: close)...]
                guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return n - 1
            })
            return diskIndices.allSatisfy { coveredIndices.contains($0) }
        }

        // No recorded audio on disk (already pruned or legacy/no audio):
        // require a canonically valid typed set (Wave-10 3876862709) or a
        // meaningful legacy span - an invalid entry next to valid ones cannot
        // authorize a safe-deletion claim.
        if !manifest.segments.isEmpty {
            return typedSetCanonicallyValid
        }
        // Wave-3 (3876301205): legacy spans must contain MEANINGFUL text.
        return manifest.transcriptSpans.contains { span in
            !span.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Export

    /// Copies a meeting's manifest, saved intelligence, and audio segments to a destination directory.
    ///
    /// The destination receives:
    /// - `manifest.json`
    /// - `audio/` (all segment WAV files)
    /// - `transcripts/` (if present)
    /// - `intelligence.json` (if the user saved meeting outputs)
    ///
    /// Returns the URL of the exported directory.
    func export(meetingID: String, to destinationDirectory: URL) throws -> URL {
        let sourceDir = meetingDirectory(for: meetingID)
        guard fileManager.fileExists(atPath: sourceDir.path) else {
            throw MeetingSessionStoreError.meetingNotFound(meetingID)
        }

        let exportDir = destinationDirectory
            .appendingPathComponent("OpenBridge Meeting \(meetingID)", isDirectory: true)
        try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)

        // Copy manifest
        let manifestURL = sourceDir.appendingPathComponent(manifestFilename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.copyItem(
                at: manifestURL,
                to: exportDir.appendingPathComponent(manifestFilename)
            )
        }

        // Copy audio directory
        let audioDir = audioDirectory(for: meetingID)
        if fileManager.fileExists(atPath: audioDir.path) {
            try fileManager.copyItem(
                at: audioDir,
                to: exportDir.appendingPathComponent("audio", isDirectory: true)
            )
        }

        // Copy transcripts directory (if it exists and has content)
        let transcriptDir = transcriptDirectory(for: meetingID)
        if fileManager.fileExists(atPath: transcriptDir.path),
           let contents = try? fileManager.contentsOfDirectory(atPath: transcriptDir.path),
           !contents.isEmpty {
            try fileManager.copyItem(
                at: transcriptDir,
                to: exportDir.appendingPathComponent("transcripts", isDirectory: true)
            )
        }

        let intelligenceURL = intelligenceSidecarURL(for: meetingID)
        if fileManager.fileExists(atPath: intelligenceURL.path) {
            try fileManager.copyItem(
                at: intelligenceURL,
                to: exportDir.appendingPathComponent(intelligenceFilename)
            )
        }

        return exportDir
    }

    // MARK: - Transcript export (TXT / Markdown)

    /// Export the transcript as plain text or Markdown to a destination
    /// directory. The output preserves meeting title/date, timestamps, source
    /// labels, and — when a cleaned revision is active and valid — cleanup
    /// provenance (revision ID, model, model revision, contract version).
    ///
    /// By default (`.cleaned`) the export uses the active cleanup revision when
    /// one is valid and current. If no valid revision exists the export falls
    /// back to the canonical original transcript. An explicit `.original`
    /// request always exports the canonical typed segments.
    ///
    /// Returns the URL of the written transcript file.
    @discardableResult
    func exportTranscript(
        meetingID: String,
        to destinationDirectory: URL,
        format: MeetingTranscriptExportFormat,
        source requestedSource: MeetingTranscriptExportSource = .cleaned,
        filename: String? = nil
    ) throws -> (url: URL, document: MeetingTranscriptDocument) {
        let manifest = try load(meetingID: meetingID)
        let activeRevision = try activeCleanupRevision(meetingID: meetingID)
        let document = MeetingTranscriptExporter.makeDocument(
            manifest: manifest,
            format: format,
            requestedSource: requestedSource,
            activeRevision: activeRevision
        )

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let outputFile = destinationDirectory.appendingPathComponent(filename ?? document.filename)
        try document.text.data(using: .utf8)?.write(to: outputFile, options: [.atomic])
        try setPrivatePermissions(outputFile)
        return (outputFile, document)
    }

    /// Exports every transcript artifact currently available for a meeting.
    /// Original is always written. Cleaned is added only when the same valid,
    /// active revision used by Replay is present at export time.
    func exportAvailableTranscripts(
        meetingID: String,
        to destinationDirectory: URL
    ) throws -> MeetingTranscriptBundleExportResult {
        let originalTXT = try exportTranscript(
            meetingID: meetingID,
            to: destinationDirectory,
            format: .txt,
            source: .original,
            filename: "Original.txt"
        )
        let originalMarkdown = try exportTranscript(
            meetingID: meetingID,
            to: destinationDirectory,
            format: .markdown,
            source: .original,
            filename: "Original.md"
        )
        var urls = [originalTXT.url, originalMarkdown.url]

        if try activeCleanupRevision(meetingID: meetingID) != nil {
            let cleanedTXT = try exportTranscript(
                meetingID: meetingID,
                to: destinationDirectory,
                format: .txt,
                source: .cleaned,
                filename: "Cleaned.txt"
            )
            let cleanedMarkdown = try exportTranscript(
                meetingID: meetingID,
                to: destinationDirectory,
                format: .markdown,
                source: .cleaned,
                filename: "Cleaned.md"
            )
            // Each document reports whether the cleaned request still
            // resolved to a valid active revision at its own write boundary.
            // Fail closed if state changed between files: remove both derived
            // names rather than mislabel Original text as Cleaned.
            if cleanedTXT.document.effectiveSource == .cleaned,
               cleanedMarkdown.document.effectiveSource == .cleaned {
                urls.append(contentsOf: [cleanedTXT.url, cleanedMarkdown.url])
                return MeetingTranscriptBundleExportResult(urls: urls, includedCleaned: true)
            }
        }

        // A reused per-meeting destination may contain Cleaned files from a
        // previous export. Remove only those known derived filenames so the
        // folder cannot imply that a current Cleaned revision exists.
        for staleName in ["Cleaned.txt", "Cleaned.md"] {
            let staleURL = destinationDirectory.appendingPathComponent(staleName)
            if fileManager.fileExists(atPath: staleURL.path) {
                try fileManager.removeItem(at: staleURL)
            }
        }
        return MeetingTranscriptBundleExportResult(urls: urls, includedCleaned: false)
    }

    // MARK: - Segment and artifact paths

    func audioSegmentURL(for meetingID: String, segmentIndex: Int) -> URL {
        audioDirectory(for: meetingID).appendingPathComponent("segment_\(String(format: "%04d", segmentIndex)).wav")
    }

    func transcriptSpanURL(for meetingID: String, spanIndex: Int) -> URL {
        transcriptDirectory(for: meetingID).appendingPathComponent("span_\(String(format: "%04d", spanIndex)).json")
    }

    // MARK: - Schema v2: Repository operations

    /// Append a typed transcript segment to a meeting. The segment is stored
    /// on the manifest atomically — callers never mutate meeting files directly.
    func appendSegment(_ segment: MeetingTranscriptSegment, meetingID: String) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        manifest.segments.append(segment)
        try saveManifest(manifest)
    }

    /// Mark a meeting as finalized (state = .completed). No further segment
    /// appends are expected after this.
    func finalizeMeeting(meetingID: String) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        manifest.state = .completed
        manifest.endedAt = Date()
        try saveManifest(manifest)
    }

    /// Return all typed transcript segments for a meeting, in sequence order.
    func fetchSegments(meetingID: String) throws -> [MeetingTranscriptSegment] {
        let manifest = try load(meetingID: meetingID)
        return manifest.segments.sorted { $0.sequence < $1.sequence }
    }

    /// Enumerate all meetings and their segments for indexing purposes.
    /// Used by future retrieval/search without exposing raw file paths.
    func enumerateForIndexing() throws -> [(meetingID: String, segments: [MeetingTranscriptSegment])] {
        let meetings = try listMeetings()
        return meetings.map { manifest in
            (meetingID: manifest.meetingID, segments: manifest.segments)
        }
    }

    /// Update meeting metadata through the repository — callers do not
    /// directly mutate arbitrary meeting files. Only non-nil parameters
    /// are applied; nil parameters leave the existing value unchanged.
    func updateMetadata(
        meetingID: String,
        title: String? = nil,
        participants: [MeetingParticipant]? = nil,
        agenda: [MeetingAgendaItem]? = nil,
        objectives: [MeetingObjective]? = nil,
        notes: String? = nil,
        context: String? = nil
    ) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        if let title { manifest.title = title }
        if let participants { manifest.participants = participants }
        if let agenda { manifest.agenda = agenda }
        if let objectives { manifest.objectives = objectives }
        if let notes { manifest.manualNotes = notes }
        if let context { manifest.contextBackground = context }
        try saveManifest(manifest)
    }

    // MARK: - Schema v3: Durable post-meeting cleanup

    /// Create a pending cleanup revision and queued job for a completed
    /// meeting. Repeating this call while the same source is already queued,
    /// running, or valid returns the existing job instead of duplicating work.
    @discardableResult
    func createCleanupJob(
        meetingID: String,
        provenance: MeetingCleanupProvenance = .localGemma,
        now: Date = Date()
    ) throws -> MeetingCleanupJob {
        var manifest = try load(meetingID: meetingID)
        guard manifest.state == .completed else {
            throw MeetingSessionStoreError.cleanupRequiresCompletedMeeting
        }
        // Wave-2 (3876240282): neverStoreTranscript means NO transcript is
        // stored - never create cleanup jobs/revisions from it (cleanup
        // would persist a derived revision of the un-stored transcript).
        guard manifest.retentionPolicy != .neverStoreTranscript else {
            throw MeetingSessionStoreError.neverStoreTranscriptNoCleanup
        }
        switch provenance.producer {
        case .localGemma:
            guard manifest.privacySettings.allowsLocalIntelligence else {
                throw MeetingSessionStoreError.localIntelligenceDisabled
            }
        case .cloud:
            guard manifest.aiMode.maySendTranscriptToCloud,
                  manifest.privacySettings.allowsCloudIntelligence,
                  let intelligence = manifest.intelligenceConfiguration,
                  intelligence.cleanupEnabled,
                  intelligence.cleanupProvider == .cloud,
                  let cloud = intelligence.cloudProvider,
                  MeetingCleanupProvenance.cloud(cloud) == provenance else {
                throw MeetingSessionStoreError.cloudIntelligenceDisabled
            }
        }

        let source = try validatedCanonicalSegments(in: manifest)
        let fingerprint = MeetingTranscriptFingerprint.make(for: source)

        if let existing = manifest.cleanupJobs.last(where: { job in
            guard [.queued, .running, .completed].contains(job.state),
                  let revision = manifest.cleanupRevisions.first(where: { $0.id == job.revisionID }) else {
                return false
            }
            return revision.sourceTranscriptFingerprint == fingerprint
                && revision.contractVersion == MeetingCleanupContract.version
                && revision.resolvedProvenance == provenance
                && revision.chunkSize == MeetingCleanupContract.chunkSize
                && (job.state == .completed ? revision.state == .valid : revision.state == .pending)
        }) {
            return existing
        }

        let revisionID = UUID().uuidString
        let revision = MeetingCleanupRevision(
            id: revisionID,
            meetingID: meetingID,
            sourceTranscriptFingerprint: fingerprint,
            sourceSegmentIDs: source.map(\.id),
            contractVersion: MeetingCleanupContract.version,
            modelRepository: provenance.model,
            modelRevision: nil,
            producer: provenance.producer,
            providerIdentifier: provenance.providerIdentifier,
            providerEndpoint: provenance.endpoint,
            providerModel: provenance.model,
            chunkSize: MeetingCleanupContract.chunkSize,
            state: .pending,
            createdAt: now,
            completedAt: nil,
            cleanedSegments: []
        )
        let job = MeetingCleanupJob(
            id: UUID().uuidString,
            meetingID: meetingID,
            revisionID: revisionID,
            state: .queued,
            createdAt: now,
            updatedAt: now,
            attempt: 1,
            completedChunkCount: 0,
            totalChunkCount: (source.count + MeetingCleanupContract.chunkSize - 1) / MeetingCleanupContract.chunkSize,
            errorMessage: nil
        )
        manifest.cleanupRevisions.append(revision)
        manifest.cleanupJobs.append(job)
        try saveManifest(manifest)
        return try load(meetingID: meetingID).cleanupJobs.first(where: { $0.id == job.id }) ?? job
    }

    @discardableResult
    func markCleanupJobRunning(
        meetingID: String,
        jobID: String,
        now: Date = Date()
    ) throws -> MeetingCleanupJob {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        switch manifest.cleanupJobs[jobIndex].state {
        case .queued:
            manifest.cleanupJobs[jobIndex].state = .running
            manifest.cleanupJobs[jobIndex].updatedAt = now
            try saveManifest(manifest)
        case .running:
            break
        default:
            throw MeetingSessionStoreError.invalidCleanupTransition(
                from: manifest.cleanupJobs[jobIndex].state,
                to: .running
            )
        }
        return manifest.cleanupJobs[jobIndex]
    }

    /// Append one engine result chunk. Writes are ordered and idempotent: an
    /// identical retry of an already-durable chunk is a no-op, while a
    /// conflicting retry is rejected.
    func persistCleanupChunk(
        meetingID: String,
        jobID: String,
        chunkIndex: Int,
        results: [MeetingCleanedSegment],
        now: Date = Date()
    ) throws {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        guard manifest.cleanupJobs[jobIndex].state == .running else {
            throw MeetingSessionStoreError.invalidCleanupTransition(
                from: manifest.cleanupJobs[jobIndex].state,
                to: .running
            )
        }
        let revisionIndex = try cleanupRevisionIndex(
            manifest.cleanupJobs[jobIndex].revisionID,
            in: manifest
        )
        guard chunkIndex >= 0, chunkIndex < manifest.cleanupJobs[jobIndex].totalChunkCount else {
            throw MeetingSessionStoreError.invalidCleanupChunk("Chunk index is outside the job range.")
        }

        let revision = manifest.cleanupRevisions[revisionIndex]
        let start = chunkIndex * revision.chunkSize
        let end = min(start + revision.chunkSize, revision.sourceSegmentIDs.count)
        let expectedIDs = Array(revision.sourceSegmentIDs[start..<end])
        let normalizedResults = try validateCleanupResults(results, expectedIDs: expectedIDs)

        if start < revision.cleanedSegments.count {
            guard end <= revision.cleanedSegments.count,
                  Array(revision.cleanedSegments[start..<end]) == normalizedResults else {
                throw MeetingSessionStoreError.conflictingCleanupWrite
            }
            return
        }
        guard start == revision.cleanedSegments.count else {
            throw MeetingSessionStoreError.invalidCleanupChunk("Cleanup chunks must be persisted in source order.")
        }

        manifest.cleanupRevisions[revisionIndex].cleanedSegments.append(contentsOf: normalizedResults)
        manifest.cleanupJobs[jobIndex].completedChunkCount = chunkIndex + 1
        manifest.cleanupJobs[jobIndex].updatedAt = now
        try saveManifest(manifest)
    }

    /// Atomically validates and activates a complete derived revision. The
    /// original typed transcript is read for alignment but never rewritten.
    @discardableResult
    func completeCleanupJob(
        meetingID: String,
        jobID: String,
        modelRevision: String,
        now: Date = Date()
    ) throws -> MeetingCleanupRevision {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        let revisionIndex = try cleanupRevisionIndex(
            manifest.cleanupJobs[jobIndex].revisionID,
            in: manifest
        )

        if manifest.cleanupJobs[jobIndex].state == .completed,
           manifest.cleanupRevisions[revisionIndex].state == .valid {
            return manifest.cleanupRevisions[revisionIndex]
        }
        guard manifest.cleanupJobs[jobIndex].state == .running else {
            throw MeetingSessionStoreError.invalidCleanupTransition(
                from: manifest.cleanupJobs[jobIndex].state,
                to: .completed
            )
        }

        let source = try validatedCanonicalSegments(in: manifest)
        let currentFingerprint = MeetingTranscriptFingerprint.make(for: source)
        guard manifest.cleanupRevisions[revisionIndex].sourceTranscriptFingerprint == currentFingerprint else {
            manifest.cleanupRevisions[revisionIndex].state = .stale
            manifest.cleanupJobs[jobIndex].state = .stale
            manifest.cleanupJobs[jobIndex].updatedAt = now
            if manifest.activeCleanupRevisionID == manifest.cleanupRevisions[revisionIndex].id {
                manifest.activeCleanupRevisionID = nil
            }
            try saveManifest(manifest)
            throw MeetingSessionStoreError.staleCleanupSource
        }

        let expectedIDs = source.map(\.id)
        let revision = manifest.cleanupRevisions[revisionIndex]
        guard revision.meetingID == meetingID,
              revision.sourceSegmentIDs == expectedIDs,
              revision.contractVersion == MeetingCleanupContract.version,
              revision.modelRepository == revision.resolvedProvenance.model,
              revision.chunkSize == MeetingCleanupContract.chunkSize else {
            throw MeetingSessionStoreError.invalidCleanupResult(
                "The cleanup revision metadata does not match the accepted contract."
            )
        }
        _ = try validateCleanupResults(
            revision.cleanedSegments,
            expectedIDs: expectedIDs
        )
        guard manifest.cleanupJobs[jobIndex].completedChunkCount == manifest.cleanupJobs[jobIndex].totalChunkCount else {
            throw MeetingSessionStoreError.incompleteCleanupResult
        }
        let normalizedModelRevision = modelRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelRevision.isEmpty else {
            throw MeetingSessionStoreError.invalidCleanupResult("The cleanup model revision is missing.")
        }

        manifest.cleanupRevisions[revisionIndex].modelRevision = normalizedModelRevision
        manifest.cleanupRevisions[revisionIndex].state = .valid
        manifest.cleanupRevisions[revisionIndex].completedAt = now
        manifest.cleanupJobs[jobIndex].state = .completed
        manifest.cleanupJobs[jobIndex].updatedAt = now
        manifest.cleanupJobs[jobIndex].errorMessage = nil
        manifest.activeCleanupRevisionID = manifest.cleanupRevisions[revisionIndex].id
        try saveManifest(manifest)
        let reloaded = try load(meetingID: meetingID)
        return reloaded.cleanupRevisions.first(where: { $0.id == manifest.cleanupRevisions[revisionIndex].id })
            ?? manifest.cleanupRevisions[revisionIndex]
    }

    func failCleanupJob(
        meetingID: String,
        jobID: String,
        reason: CleanupFailureReason,
        now: Date = Date()
    ) throws {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        switch manifest.cleanupJobs[jobIndex].state {
        case .completed, .failed, .cancelled, .stale:
            return
        default:
            break
        }
        manifest.cleanupJobs[jobIndex].state = .failed
        manifest.cleanupJobs[jobIndex].updatedAt = now
        manifest.cleanupJobs[jobIndex].failureReason = reason
        manifest.cleanupJobs[jobIndex].errorMessage = reason.rawValue
        try saveManifest(manifest)
    }

    func cancelCleanupJob(
        meetingID: String,
        jobID: String,
        now: Date = Date()
    ) throws {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        switch manifest.cleanupJobs[jobIndex].state {
        case .completed, .failed, .cancelled, .stale:
            return
        default:
            manifest.cleanupJobs[jobIndex].state = .cancelled
            manifest.cleanupJobs[jobIndex].updatedAt = now
            try saveManifest(manifest)
        }
    }

    /// On relaunch, a job that was `running` cannot still own a live process,
    /// so it becomes explicitly `interrupted` rather than looking hung.
    func reconcileCleanupJobsAfterRelaunch(
        meetingID: String,
        now: Date = Date()
    ) throws {
        var manifest = try load(meetingID: meetingID)
        var changed = false
        for index in manifest.cleanupJobs.indices where manifest.cleanupJobs[index].state == .running {
            manifest.cleanupJobs[index].state = .interrupted
            manifest.cleanupJobs[index].updatedAt = now
            changed = true
        }
        if changed { try saveManifest(manifest) }
    }

    func makeCleanupRetryAvailable(
        meetingID: String,
        jobID: String,
        now: Date = Date()
    ) throws {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        guard [.failed, .interrupted].contains(manifest.cleanupJobs[jobIndex].state) else {
            throw MeetingSessionStoreError.invalidCleanupTransition(
                from: manifest.cleanupJobs[jobIndex].state,
                to: .retryAvailable
            )
        }
        manifest.cleanupJobs[jobIndex].state = .retryAvailable
        manifest.cleanupJobs[jobIndex].updatedAt = now
        try saveManifest(manifest)
    }

    /// Reset the same durable job/revision for a deliberate retry. Clearing a
    /// partial result and re-queuing happen in one atomic manifest replacement.
    func queueCleanupRetry(
        meetingID: String,
        jobID: String,
        now: Date = Date()
    ) throws {
        var manifest = try load(meetingID: meetingID)
        let jobIndex = try cleanupJobIndex(jobID, in: manifest)
        guard manifest.cleanupJobs[jobIndex].state == .retryAvailable else {
            throw MeetingSessionStoreError.invalidCleanupTransition(
                from: manifest.cleanupJobs[jobIndex].state,
                to: .queued
            )
        }
        let revisionIndex = try cleanupRevisionIndex(
            manifest.cleanupJobs[jobIndex].revisionID,
            in: manifest
        )
        let currentFingerprint = MeetingTranscriptFingerprint.make(for: manifest.segments)
        guard manifest.cleanupRevisions[revisionIndex].sourceTranscriptFingerprint == currentFingerprint else {
            manifest.cleanupJobs[jobIndex].state = .stale
            manifest.cleanupRevisions[revisionIndex].state = .stale
            try saveManifest(manifest)
            throw MeetingSessionStoreError.staleCleanupSource
        }

        manifest.cleanupRevisions[revisionIndex].state = .pending
        manifest.cleanupRevisions[revisionIndex].modelRevision = nil
        manifest.cleanupRevisions[revisionIndex].completedAt = nil
        manifest.cleanupRevisions[revisionIndex].cleanedSegments = []
        manifest.cleanupJobs[jobIndex].state = .queued
        manifest.cleanupJobs[jobIndex].updatedAt = now
        manifest.cleanupJobs[jobIndex].attempt += 1
        manifest.cleanupJobs[jobIndex].completedChunkCount = 0
        manifest.cleanupJobs[jobIndex].errorMessage = nil
        manifest.cleanupJobs[jobIndex].failureReason = nil
        try saveManifest(manifest)
    }

    func activeCleanupRevision(meetingID: String) throws -> MeetingCleanupRevision? {
        let manifest = try load(meetingID: meetingID)
        guard let source = try? validatedCanonicalSegments(in: manifest) else {
            return nil
        }
        let expectedIDs = source.map(\.id)
        guard let activeID = manifest.activeCleanupRevisionID,
              let revision = manifest.cleanupRevisions.first(where: { $0.id == activeID }),
              revision.state == .valid,
              revision.meetingID == meetingID,
              revision.sourceTranscriptFingerprint == MeetingTranscriptFingerprint.make(for: source),
              revision.sourceSegmentIDs == expectedIDs,
              revision.contractVersion == MeetingCleanupContract.version,
              revision.modelRepository == revision.resolvedProvenance.model,
              revision.chunkSize == MeetingCleanupContract.chunkSize,
              revision.modelRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              (try? validateCleanupResults(revision.cleanedSegments, expectedIDs: expectedIDs)) != nil else {
            return nil
        }
        return revision
    }

    /// Records the user's explicit decision to stop using the snapshotted
    /// cloud provider for this meeting and use local Gemma instead. This does
    /// not start work by itself and is unavailable to legacy meetings.
    func selectLocalCleanupAlternative(meetingID: String) throws {
        var manifest = try load(meetingID: meetingID)
        guard let configuration = manifest.intelligenceConfiguration else {
            throw MeetingSessionStoreError.intelligenceConfigurationUnavailable
        }
        manifest.intelligenceConfiguration = MeetingIntelligenceConfiguration(
            cleanupEnabled: true,
            cleanupProvider: .localGemma,
            cloudProvider: configuration.cloudProvider
        )
        try saveManifest(manifest)
    }

    /// Source-compatible helper for older tests/callers. The free-form text
    /// is intentionally not persisted; Build 21 stores a content-free class.
    func failCleanupJob(
        meetingID: String,
        jobID: String,
        message: String,
        now: Date = Date()
    ) throws {
        _ = message
        try failCleanupJob(
            meetingID: meetingID,
            jobID: jobID,
            reason: .unknown,
            now: now
        )
    }

    // MARK: - Schema v3.1 (#219): Recovery

    /// Detects incomplete meeting sessions at relaunch. Returns meetings that
    /// are in a non-terminal state (recording, stopped, interrupted, failed,
    /// etc.) and need user action.
    ///
    /// Also reconciles interrupted cleanup jobs: any cleanup job left in
    /// `.running` from a previous session is moved to `.interrupted`.
    func detectIncompleteSessions(now: Date = Date()) throws -> [MeetingManifest] {
        let meetings = try listMeetings()
        var incomplete: [MeetingManifest] = []

        for listedManifest in meetings {
            // #294 recovery hardening: the active segment is streamed to its
            // final WAV path during capture. A force-quit can interrupt the
            // tiny header-size refresh after PCM bytes were appended; repair
            // those sizes from the actual file length before the recovery UI
            // or retry engine opens the audio.
            repairMeetingWAVHeaders(meetingID: listedManifest.meetingID)
            try reconcileActiveJournalAfterRelaunch(meetingID: listedManifest.meetingID)
            var manifest = try load(meetingID: listedManifest.meetingID)

            // Reconcile interrupted cleanup jobs for ALL meetings — even
            // completed ones can have a cleanup job left in .running.
            let hasRunningJob = manifest.cleanupJobs.contains { $0.state == .running }
            if hasRunningJob {
                try reconcileCleanupJobsAfterRelaunch(meetingID: manifest.meetingID, now: now)
                manifest = try load(meetingID: manifest.meetingID)
            }

            // #294 (Alex QA): a force-quit leaves the manifest in a
            // live/transient state (.recording/.transcribingLive/.finalizing/
            // .setup) — the app died before transitioning it. No process can
            // still own the session after relaunch, so transition these to
            // .interrupted. Otherwise the state pill keeps reading
            // "Recording" for a meeting that no longer IS recording — the
            // #219 "never lie about state" invariant.
            let transientStates: [MeetingSessionState] = [
                .setup, .recording, .transcribingLive, .finalizing
            ]
            if transientStates.contains(manifest.state) {
                manifest.state = .interrupted
                try saveManifest(manifest)
            }

            // #219: surface meetings that need recovery OR whose cleanup was
            // interrupted — an interrupted job owes the user a retry decision
            // even when the meeting itself is .completed. Surfacing is the
            // rebuilt flow's detection step (previously a silent flip).
            let hasInterruptedCleanup = manifest.cleanupJobs.contains {
                $0.state == .interrupted || $0.state == .retryAvailable
            }
            if manifest.state.needsRecovery || hasRunningJob || hasInterruptedCleanup {
                let reconciled = try load(meetingID: manifest.meetingID)
                incomplete.append(reconciled)
            }
        }

        return incomplete
    }

    /// Finalizes the durable timing record for a WAV that was active when the
    /// process exited. The start offset was saved when the writer was opened;
    /// the repaired WAV's actual duration supplies its end offset.
    private func reconcileActiveJournalAfterRelaunch(meetingID: String) throws {
        var manifest = try load(meetingID: meetingID)
        guard let journal = manifest.activeJournal else { return }
        let url = audioDirectory(for: meetingID).appendingPathComponent(journal.filename)
        guard fileManager.fileExists(atPath: url.path) else {
            manifest.activeJournal = nil
            try saveManifest(manifest)
            return
        }
        guard let duration = try MeetingWAVFile.durationSeconds(at: url),
              duration > 0
        else { return }

        // A marker ahead of saved history cannot be indexed safely. New
        // recorder writes prevent this by saving completed progress and the
        // marker atomically; preserve older/inconsistent markers for a future
        // recovery pass instead of clearing the only timing evidence.
        guard journal.segmentIndex <= manifest.chunkBoundaries.count else { return }

        if journal.segmentIndex == manifest.chunkBoundaries.count {
            let endOffset = journal.startOffset + duration
            let overlap = MeetingChunkPolicyConfiguration.live.overlapSeconds
            manifest.chunkBoundaries.append(MeetingChunkBoundary(
                chunkIndex: journal.segmentIndex,
                startOffset: journal.startOffset,
                endOffset: endOffset,
                overlapSeconds: overlap,
                reason: .stop,
                availableOverlap: min(overlap, duration)
            ))
        }
        if !manifest.audioSegments.contains(journal.filename) {
            manifest.audioSegments.append(journal.filename)
            manifest.audioSegments.sort()
        }
        manifest.lastCompletedSegmentIndex = max(
            manifest.lastCompletedSegmentIndex,
            journal.segmentIndex + 1
        )
        manifest.activeJournal = nil
        try saveManifest(manifest)
    }

    private func repairMeetingWAVHeaders(meetingID: String) {
        let audioDir = audioDirectory(for: meetingID)
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: audioDir.path) else {
            return
        }
        for filename in filenames
        where filename.hasPrefix("segment_") && filename.lowercased().hasSuffix(".wav") {
            let url = audioDir.appendingPathComponent(filename)
            _ = try? MeetingWAVFile.repairHeaderIfNeeded(at: url)
        }
    }

    /// #219: record an isolated recovery-boundary event (e.g. a provider
    /// failure) WITHOUT touching the meeting's state — provider failures
    /// must never read as capture/transcription/cleanup failure.
    func recordRecoveryEvent(meetingID: String, kind: String, detail: String, now: Date = Date()) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        manifest.events.append("[\(isoString(now))] \(kind) \(detail)")
        try saveManifest(manifest)
    }

    /// #219 (review): recovery reconciliation after a successful retry.
    /// - REPLACES canonically invalid typed segments at the retried
    ///   sequences (a corrupt entry must not linger beside its replacement).
    /// - RECONCILES the discovered on-disk `segment_NNNN.wav` filenames into
    ///   `audioSegments` (a force-quit before the recorder's progress save
    ///   leaves the list empty; replay builds URLs from it, so recovered
    ///   audio would be invisible without this write-back).
    func reconcileRecoveredMeeting(
        meetingID: String,
        retriedSequences: [Int],
        segmentIsValid: (MeetingTranscriptSegment) -> Bool,
        discoveredAudioFilenames: [String]
    ) throws {
        var manifest = try load(meetingID: meetingID)
        let retried = Set(retriedSequences)
        if !retried.isEmpty {
            manifest.segments.removeAll {
                retried.contains($0.sequence) && !segmentIsValid($0)
            }
        }
        for name in discoveredAudioFilenames where !manifest.audioSegments.contains(name) {
            manifest.audioSegments.append(name)
        }
        manifest.audioSegments.sort()
        try saveManifest(manifest)
    }

    /// Marks a meeting as failed (capture/transcription/provider failure).
    /// Source audio and any partial transcript are preserved — this only
    /// changes the state so the UI can offer recovery actions.
    func markMeetingAsFailed(meetingID: String, reason: String, now: Date = Date()) throws {
        let lock = Self.manifestTransactionLocks.lock(for: manifestURL(for: meetingID))
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(meetingID: meetingID)
        guard manifest.state != .completed else {
            // Never downgrade a completed meeting
            return
        }
        manifest.state = .failed
        manifest.events.append("[\(isoString(now))] FAILED: \(reason)")
        try saveManifest(manifest)
    }

    /// Marks a meeting as needing recovery. This is the state surfaced at
    /// relaunch when a session is incomplete.
    func markMeetingRecoveryNeeded(meetingID: String, now: Date = Date()) throws {
        var manifest = try load(meetingID: meetingID)
        guard manifest.state != .completed else { return }
        manifest.state = .recoveryNeeded
        manifest.events.append("[\(isoString(now))] RECOVERY_NEEDED")
        try saveManifest(manifest)
    }

    /// Attempt to finalize an incomplete session by checking whether audio
    /// segments exist on disk. If audio files are present, the meeting is
    /// marked `.captured` (ready for transcription retry). If no audio exists,
    /// the meeting is marked `.failed` (nothing to recover).
    ///
    /// This does NOT auto-transcribe — it only evaluates what's recoverable.
    /// The caller decides whether to retry transcription or delete.
    func evaluateRecovery(meetingID: String) throws -> MeetingRecoveryAssessment {
        let manifest = try load(meetingID: meetingID)
        let audioDir = audioDirectory(for: meetingID)

        let hasAudioFiles: Bool
        if FileManager.default.fileExists(atPath: audioDir.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []
            hasAudioFiles = contents.contains { $0.hasSuffix(".wav") } || manifest.audioArtifacts.contains { fileManager.fileExists(atPath: audioDir.appendingPathComponent($0.relativePath).path) } || manifest.activeSourceJournals.values.contains { fileManager.fileExists(atPath: audioDir.appendingPathComponent($0.filename).path) }
        } else {
            hasAudioFiles = false
        }

        let hasPartialTranscript = !manifest.segments.isEmpty || !manifest.transcriptSpans.isEmpty
        let hasActiveCleanup = manifest.activeCleanupRevisionID != nil
        let hasInterruptedCleanup = manifest.cleanupJobs.contains {
            $0.state == .interrupted || $0.state == .failed
        }

        return MeetingRecoveryAssessment(
            meetingID: meetingID,
            state: manifest.state,
            hasAudioFiles: hasAudioFiles,
            audioSegmentCount: manifest.audioSegments.count,
            hasPartialTranscript: hasPartialTranscript,
            hasActiveCleanup: hasActiveCleanup,
            hasInterruptedCleanup: hasInterruptedCleanup
        )
    }

    /// Explicitly delete an unrecoverable session after user confirmation.
    /// This is the same atomic directory removal as `delete(meetingID:)` but
    /// records an event first so the deletion is traceable.
    func deleteUnrecoverableSession(meetingID: String, now: Date = Date()) throws {
        // Record the deletion intent in a sibling log before removing.
        // (The manifest itself will be deleted, so we can't write to it.)
        let parentDir = meetingDirectory(for: meetingID).deletingLastPathComponent()
        let logURL = parentDir.appendingPathComponent(".recovery-deletions.log")
        let logEntry = "\(isoString(now)) DELETED_UNRECOVERABLE \(meetingID)\n"
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
        try delete(meetingID: meetingID)
    }

    /// Mark a meeting that has a valid transcript as `.completed`. Used after
    /// successful retry/finalization when the transcript is confirmed.
    func completeRecoveredMeeting(
        meetingID: String,
        now: Date = Date(),
        allowsEmptyTranscript: Bool = false
    ) throws {
        var manifest = try load(meetingID: meetingID)
        // Wave-11 (3876962658): neverStoreTranscript meetings store NO text by
        // design - their finalize success is proven by the durable per-index
        // retry markers the router verified, not by transcript presence. The
        // caller passes allowsEmptyTranscript ONLY for that marker-verified
        // path; every other caller keeps the guard.
        if !allowsEmptyTranscript {
            guard !manifest.segments.isEmpty || !manifest.transcriptSpans.isEmpty else {
                throw MeetingSessionStoreError.recoveryFailed("Cannot complete a meeting with no transcript.")
            }
        }
        manifest.state = .completed
        manifest.endedAt = now
        manifest.events.append("[\(isoString(now))] RECOVERED_COMPLETED")
        try saveManifest(manifest)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Private permissions

    private func setPrivatePermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func reconcileCleanupStaleness(in manifest: inout MeetingManifest) {
        guard !manifest.cleanupRevisions.isEmpty else { return }
        let fingerprint = MeetingTranscriptFingerprint.make(for: manifest.segments)
        var staleRevisionIDs: Set<String> = []
        for index in manifest.cleanupRevisions.indices
            where manifest.cleanupRevisions[index].sourceTranscriptFingerprint != fingerprint {
            manifest.cleanupRevisions[index].state = .stale
            staleRevisionIDs.insert(manifest.cleanupRevisions[index].id)
        }
        guard !staleRevisionIDs.isEmpty else { return }
        for index in manifest.cleanupJobs.indices
            where staleRevisionIDs.contains(manifest.cleanupJobs[index].revisionID) {
            manifest.cleanupJobs[index].state = .stale
        }
        if let activeID = manifest.activeCleanupRevisionID, staleRevisionIDs.contains(activeID) {
            manifest.activeCleanupRevisionID = nil
        }
    }

    private func reconcileActiveCleanupRevision(in manifest: inout MeetingManifest) {
        guard let source = try? validatedCanonicalSegments(in: manifest) else {
            manifest.activeCleanupRevisionID = nil
            return
        }
        let expectedIDs = source.map(\.id)
        let fingerprint = MeetingTranscriptFingerprint.make(for: source)
        let meetingID = manifest.meetingID
        let isValid: (MeetingCleanupRevision) -> Bool = { revision in
            revision.state == .valid
                && revision.meetingID == meetingID
                && revision.sourceTranscriptFingerprint == fingerprint
                && revision.sourceSegmentIDs == expectedIDs
                && revision.contractVersion == MeetingCleanupContract.version
                && revision.modelRepository == revision.resolvedProvenance.model
                && revision.chunkSize == MeetingCleanupContract.chunkSize
                && revision.modelRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && (try? validateCleanupResults(revision.cleanedSegments, expectedIDs: expectedIDs)) != nil
        }

        if let activeID = manifest.activeCleanupRevisionID {
            guard let revision = manifest.cleanupRevisions.first(where: { $0.id == activeID }),
                  isValid(revision) else {
                manifest.activeCleanupRevisionID = nil
                return
            }
            return
        }

        // Compatibility repair for the Build 21 cloud-activation defect.
        // Only a fully completed job with a currently valid, aligned revision
        // is eligible; failed, partial, stale, or cancelled output stays hidden.
        guard let completedJob = manifest.cleanupJobs.reversed().first(where: { job in
            job.state == .completed
                && job.totalChunkCount > 0
                && job.completedChunkCount == job.totalChunkCount
        }),
              let revision = manifest.cleanupRevisions.first(where: { $0.id == completedJob.revisionID }),
              isValid(revision) else {
            return
        }
        manifest.activeCleanupRevisionID = revision.id
    }

    private func validatedCanonicalSegments(in manifest: MeetingManifest) throws -> [MeetingTranscriptSegment] {
        let segments = manifest.segments.sorted(by: MeetingTranscriptFingerprint.canonicalOrder)
        guard !segments.isEmpty else { throw MeetingSessionStoreError.emptyCleanupSource }
        guard Set(segments.map(\.id)).count == segments.count else {
            throw MeetingSessionStoreError.invalidCleanupSource("Source segment IDs must be unique.")
        }
        guard Set(segments.map(\.sequence)).count == segments.count else {
            throw MeetingSessionStoreError.invalidCleanupSource("Source segment sequence numbers must be unique.")
        }
        guard segments.allSatisfy({ $0.meetingID == manifest.meetingID }) else {
            throw MeetingSessionStoreError.invalidCleanupSource("Every source segment must belong to the meeting.")
        }
        guard segments.allSatisfy(\.isFinal) else {
            throw MeetingSessionStoreError.invalidCleanupSource("Every source segment must be final.")
        }
        guard segments.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MeetingSessionStoreError.invalidCleanupSource("Source transcript text cannot be empty.")
        }
        return segments
    }

    private func validateCleanupResults(
        _ results: [MeetingCleanedSegment],
        expectedIDs: [String]
    ) throws -> [MeetingCleanedSegment] {
        guard results.count == expectedIDs.count else {
            throw MeetingSessionStoreError.incompleteCleanupResult
        }
        guard Set(results.map(\.sourceSegmentID)).count == results.count else {
            throw MeetingSessionStoreError.invalidCleanupResult("Cleanup result IDs must be unique.")
        }
        return try zip(results, expectedIDs).map { result, expectedID in
            guard result.sourceSegmentID == expectedID else {
                throw MeetingSessionStoreError.invalidCleanupResult(
                    "Cleanup results must preserve every source ID in order."
                )
            }
            let text = result.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw MeetingSessionStoreError.invalidCleanupResult("Cleaned text cannot be empty.")
            }
            return MeetingCleanedSegment(sourceSegmentID: result.sourceSegmentID, cleanedText: text)
        }
    }

    private func cleanupJobIndex(_ jobID: String, in manifest: MeetingManifest) throws -> Int {
        guard let index = manifest.cleanupJobs.firstIndex(where: { $0.id == jobID }) else {
            throw MeetingSessionStoreError.cleanupJobNotFound(jobID)
        }
        return index
    }

    private func cleanupRevisionIndex(_ revisionID: String, in manifest: MeetingManifest) throws -> Int {
        guard let index = manifest.cleanupRevisions.firstIndex(where: { $0.id == revisionID }) else {
            throw MeetingSessionStoreError.cleanupRevisionNotFound(revisionID)
        }
        return index
    }
}

// MARK: - Errors

enum MeetingSessionStoreError: LocalizedError {
    case meetingNotFound(String)
    case cleanupRequiresCompletedMeeting
    case localIntelligenceDisabled
    case cloudIntelligenceDisabled
    case intelligenceConfigurationUnavailable
    case neverStoreTranscriptNoCleanup
    case emptyCleanupSource
    case invalidCleanupSource(String)
    case cleanupJobNotFound(String)
    case cleanupRevisionNotFound(String)
    case invalidCleanupTransition(from: MeetingCleanupJobState, to: MeetingCleanupJobState)
    case invalidCleanupChunk(String)
    case conflictingCleanupWrite
    case incompleteCleanupResult
    case invalidCleanupResult(String)
    case staleCleanupSource
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .meetingNotFound(let meetingID):
            return "Meeting \(meetingID) could not be found for export."
        case .cleanupRequiresCompletedMeeting:
            return "Transcript cleanup can start only after the meeting is completed."
        case .localIntelligenceDisabled:
            return "Local intelligence is disabled for this meeting."
        case .cloudIntelligenceDisabled:
            return "Cloud intelligence is not authorized for this meeting or its provider snapshot no longer matches."
        case .intelligenceConfigurationUnavailable:
            return "This meeting predates the build 19 intelligence controls."
        case .neverStoreTranscriptNoCleanup:
            return "This meeting's retention policy never stores the transcript, so cleanup cannot run on it."
        case .emptyCleanupSource:
            return "The completed meeting has no typed transcript segments to clean."
        case .invalidCleanupSource(let reason):
            return reason
        case .cleanupJobNotFound(let jobID):
            return "Cleanup job \(jobID) could not be found."
        case .cleanupRevisionNotFound(let revisionID):
            return "Cleanup revision \(revisionID) could not be found."
        case .invalidCleanupTransition(let current, let requested):
            return "Cleanup cannot move from \(current.rawValue) to \(requested.rawValue)."
        case .invalidCleanupChunk(let reason):
            return reason
        case .conflictingCleanupWrite:
            return "A repeated cleanup write conflicts with the durable result."
        case .incompleteCleanupResult:
            return "Cleanup must return exactly one result for every source segment."
        case .invalidCleanupResult(let reason):
            return reason
        case .staleCleanupSource:
            return "The source transcript changed, so this cleanup revision is stale."
        case .recoveryFailed(let reason):
            return reason
        }
    }
}

/// Describes what's recoverable for an incomplete session (#219).
struct MeetingRecoveryAssessment: Equatable, Sendable {
    let meetingID: String
    let state: MeetingSessionState
    let hasAudioFiles: Bool
    let audioSegmentCount: Int
    let hasPartialTranscript: Bool
    let hasActiveCleanup: Bool
    let hasInterruptedCleanup: Bool

    /// True when the meeting has audio that can be re-transcribed.
    var canRetryTranscription: Bool {
        hasAudioFiles
    }

    /// True when there's nothing left to recover — no audio and no transcript.
    var isUnrecoverable: Bool {
        !hasAudioFiles && !hasPartialTranscript
    }
}

enum MeetingSessionStoreFaultPoint: Equatable {
    case beforeManifestReplacement
}
