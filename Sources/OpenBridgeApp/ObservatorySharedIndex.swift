import Foundation

/// Shared production workspace retrieval index. All callers still gate work
/// on the user-visible Research rail setting, which defaults Off.
/// One SQLite store at a fixed path so live meetings are indexed and
/// the Observatory coordinator searches the same database.
enum ObservatorySharedIndex {
    /// Serialize individual SQLite replacements/removals. The background
    /// rebuild never holds this across corpus reads or multiple meetings, so
    /// a main-actor deletion waits for at most one short index transaction.
    private static let mutationLock = NSLock()

    static let databaseURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Openbridge/Research/research.sqlite")
    }()

    static let shared: WorkspaceRetrievalIndex? = {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try? WorkspaceRetrievalIndex(databaseURL: databaseURL)
    }()

    /// Re-index a meeting manifest (idempotent per meeting ID — the
    /// index deletes and reinserts the meeting's rows, so filtered
    /// garbage self-heals on the next segment save).
    static func indexMeeting(_ manifest: MeetingManifest) {
        indexMeeting(manifest, into: shared)
    }

    static func indexMeeting(
        _ manifest: MeetingManifest,
        into index: WorkspaceRetrievalIndex?
    ) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        indexMeetingWithoutLock(manifest, into: index)
    }

    private static func indexMeetingWithoutLock(
        _ manifest: MeetingManifest,
        into index: WorkspaceRetrievalIndex?
    ) {
        // New meetings persist an explicit intelligence boundary. A meeting
        // created as transcription-only (or with local intelligence revoked)
        // must remove any previously copied rows as well as block new rows.
        // Legacy manifests have no build-19 snapshot and remain eligible when
        // their backward-compatible local-intelligence setting permits it.
        let isNewTranscriptionOnly = manifest.intelligenceConfiguration != nil
            && manifest.aiMode == .transcriptionOnly
        guard manifest.privacySettings.allowsLocalIntelligence,
              !isNewTranscriptionOnly else {
            try? index?.removeMeeting(meetingID: manifest.meetingID)
            return
        }
        // Empty/engine-repr segments never enter the index (round-6
        // evidence: "AlignedResult(text='', sentences=[])" rows).
        var cleaned = manifest
        cleaned.segments = manifest.segments.filter { !Self.isEngineRepr($0.text) }
        // Round-7 root cause: live manifests carry no workspaceID, so
        // rows indexed as "" never match the coordinator's workspace-
        // scoped search — every question abstained even with the fact
        // indexed. Default to the default workspace so scoped search
        // finds live meeting content.
        if cleaned.workspaceID == nil || cleaned.workspaceID?.isEmpty == true {
            cleaned.workspaceID = Workspace.defaultWorkspace.id
        }
        try? index?.index(meeting: cleaned)
    }

    /// Re-index every saved meeting when the opt-in Beta is enabled so
    /// the corpus is never tiny (IDF epsilon collapse) and prior
    /// meetings are searchable immediately instead of self-healing
    /// only as segments save.
    static func reindexAllSavedMeetings(
        store: MeetingSessionStore = MeetingSessionStore(),
        index: WorkspaceRetrievalIndex? = shared,
        now: Date = Date(),
        shouldCancel: () -> Bool = { false }
    ) {
        guard !shouldCancel() else { return }
        // Retention is a data-lifecycle boundary, not merely a UI refresh.
        // Prune expired meetings before copying any transcript text into the
        // in-memory/file-backed search index. The orphan sweep below then
        // removes rows for every successfully deleted meeting.
        _ = try? store.enforceRetentionPolicy(now: now)
        guard !shouldCancel() else { return }
        guard let meetings = try? store.listMeetings() else { return }
        for meeting in meetings {
            guard !shouldCancel() else { return }
            replaceMeetingIfStillStored(
                meetingID: meeting.meetingID,
                store: store,
                into: index
            )
        }
        // #62: orphan sweep — remove index rows whose meeting no longer
        // exists in the store (deleted meetings previously left rows
        // in research.sqlite forever, re-saturating terms).
        let liveIDs = Set(meetings.map(\.meetingID))
        if let indexedIDs = index?.indexedMeetingIDs {
            for indexedID in indexedIDs where !liveIDs.contains(indexedID) {
                guard !shouldCancel() else { return }
                removeOrphanIfStillMissing(
                    meetingID: indexedID,
                    store: store,
                    from: index
                )
            }
        }
        #if DEBUG
        print("[observatory] startup re-index: \(meetings.count) meetings, \(index?.indexedSegmentCount ?? 0) segments")
        #endif
    }

    /// #62: remove a single meeting's rows from the research index after any
    /// durable store deletion (manual, retention, or recovery cleanup).
    static func purgeMeeting(meetingID: String) {
        // Do not create an index merely because a never-enabled user deleted
        // a meeting. If the database exists from an earlier enabled session,
        // opening it is required to enforce the deletion invariant.
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        purgeMeeting(meetingID: meetingID, from: shared)
    }

    static func purgeMeeting(meetingID: String, from index: WorkspaceRetrievalIndex?) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try? index?.removeMeeting(meetingID: meetingID)
    }

    private static func removeOrphanIfStillMissing(
        meetingID: String,
        store: MeetingSessionStore,
        from index: WorkspaceRetrievalIndex?
    ) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // Recheck inside the same short critical section as removal. If a
        // creation is concurrently waiting to index, its replacement runs
        // immediately afterward and remains authoritative.
        guard (try? store.load(meetingID: meetingID)) == nil else { return }
        try? index?.removeMeeting(meetingID: meetingID)
    }

    private static func replaceMeetingIfStillStored(
        meetingID: String,
        store: MeetingSessionStore,
        into index: WorkspaceRetrievalIndex?
    ) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // Reload at the replacement boundary. If deletion finished after the
        // rebuild's listMeetings snapshot, remove any older derived row and
        // never reinsert the stale captured manifest. If the meeting changed,
        // the current durable manifest—not the snapshot—is authoritative.
        guard let current = try? store.load(meetingID: meetingID) else {
            try? index?.removeMeeting(meetingID: meetingID)
            return
        }
        indexMeetingWithoutLock(current, into: index)
    }

    private static func isEngineRepr(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("AlignedResult(")
    }
}
