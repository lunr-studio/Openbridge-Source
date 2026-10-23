import Testing
import Foundation
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingSchemaTests {

    // MARK: - v1 → current schema migration with fixture

    @Test func v1ManifestMigratesToCurrentSchemaDeterministically() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-v1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)

        // Hardcoded v1 fixture JSON (schemaVersion: 1, has transcriptSpans)
        let v1JSON = """
        {
            "schemaVersion": 1,
            "meetingID": "v1-fixture-meeting",
            "title": "Legacy Meeting",
            "state": "completed",
            "startedAt": "2025-08-01T10:00:00Z",
            "endedAt": "2025-08-01T11:00:00Z",
            "sources": [],
            "retentionPolicy": "keepUntilDeleted",
            "aiMode": "transcriptionOnly",
            "lastCompletedSegmentIndex": 2,
            "transcriptSpans": ["[Segment 1] hello", "[Segment 2] world"],
            "audioSegments": ["segment_0000.wav", "segment_0001.wav"],
            "events": [],
            "modelProviderMetadata": {}
        }
        """.data(using: .utf8)!

        // Write the v1 fixture directly to disk
        let meetingDir = testRoot.appendingPathComponent("v1-fixture-meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetingDir.appendingPathComponent("audio", isDirectory: true), withIntermediateDirectories: true)
        try v1JSON.write(to: meetingDir.appendingPathComponent("manifest.json"))

        // Decode through the store — should migrate to the current schema
        let manifest = try store.load(meetingID: "v1-fixture-meeting")

        // v1 fields preserved
        #expect(manifest.schemaVersion == 4)
        #expect(manifest.meetingID == "v1-fixture-meeting")
        #expect(manifest.title == "Legacy Meeting")
        #expect(manifest.transcriptSpans == ["[Segment 1] hello", "[Segment 2] world"])
        #expect(manifest.audioSegments == ["segment_0000.wav", "segment_0001.wav"])

        // v2 fields defaulted to empty
        #expect(manifest.segments.isEmpty)
        #expect(manifest.participants.isEmpty)
        #expect(manifest.agenda.isEmpty)
        #expect(manifest.objectives.isEmpty)
        #expect(manifest.contextBackground == nil)
        #expect(manifest.manualNotes == nil)
        #expect(manifest.privacySettings == MeetingPrivacySettings())
        #expect(manifest.cleanupJobs.isEmpty)
        #expect(manifest.cleanupRevisions.isEmpty)
        #expect(manifest.activeCleanupRevisionID == nil)
    }

    // MARK: - Current-schema round-trip with stable IDs and timestamps

    @Test func currentManifestRoundTripsWithStableSegmentIDs() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let meetingID = "roundtrip-test"

        let segment1 = MeetingTranscriptSegment(
            id: "seg-001",
            meetingID: meetingID,
            sequence: 0,
            startOffset: 0,
            endOffset: 60,
            sourceLabel: "Room",
            text: "first segment",
            isFinal: true
        )
        let segment2 = MeetingTranscriptSegment(
            id: "seg-002",
            meetingID: meetingID,
            sequence: 1,
            startOffset: 60,
            endOffset: 120,
            sourceLabel: "Room",
            text: "second segment",
            isFinal: true
        )

        let manifest = MeetingManifest(
            meetingID: meetingID,
            title: "Round Trip",
            state: .completed,
            segments: [segment1, segment2],
            participants: [MeetingParticipant(label: "Participant 1")],
            agenda: [MeetingAgendaItem(text: "Discuss plan")],
            objectives: [MeetingObjective(text: "Decide timeline")]
        )
        try store.create(manifest)

        // Reload and verify stable IDs and timestamps
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.schemaVersion == 4)
        #expect(loaded.segments.count == 2)
        #expect(loaded.segments[0].id == "seg-001")
        #expect(loaded.segments[1].id == "seg-002")
        #expect(loaded.segments[0].startOffset == 0)
        #expect(loaded.segments[0].endOffset == 60)
        #expect(loaded.segments[1].startOffset == 60)
        #expect(loaded.segments[1].endOffset == 120)
        #expect(loaded.participants.count == 1)
        #expect(loaded.participants[0].label == "Participant 1")
        #expect(loaded.agenda.count == 1)
        #expect(loaded.objectives.count == 1)
    }

    // MARK: - appendSegment + finalize + fetchSegments

    @Test func appendSegmentAndFinalizeWorks() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-append-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let meetingID = "append-test"
        let manifest = MeetingManifest(meetingID: meetingID, title: "Append Test", state: .recording)
        try store.create(manifest)

        // Append two segments
        let seg1 = MeetingTranscriptSegment(meetingID: meetingID, sequence: 0, text: "first")
        let seg2 = MeetingTranscriptSegment(meetingID: meetingID, sequence: 1, text: "second")
        try store.appendSegment(seg1, meetingID: meetingID)
        try store.appendSegment(seg2, meetingID: meetingID)

        // Fetch and verify order
        let segments = try store.fetchSegments(meetingID: meetingID)
        #expect(segments.count == 2)
        #expect(segments[0].text == "first")
        #expect(segments[1].text == "second")

        // Finalize
        try store.finalizeMeeting(meetingID: meetingID)
        let finalized = try store.load(meetingID: meetingID)
        #expect(finalized.state == .completed)
        #expect(finalized.endedAt != nil)
    }

    // MARK: - Corrupt manifest skipped without breaking valid ones

    @Test func corruptManifestSkipsWithoutBreakingValidOnes() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)

        // Create a valid meeting
        let validManifest = MeetingManifest(meetingID: "valid-meeting", title: "Valid", state: .completed)
        try store.create(validManifest)

        // Create a corrupt meeting directory with garbage JSON
        let corruptDir = testRoot.appendingPathComponent("corrupt-meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        try Data("NOT VALID JSON".utf8).write(to: corruptDir.appendingPathComponent("manifest.json"))

        // listMeetings should return only the valid one
        let meetings = try store.listMeetings()
        #expect(meetings.count == 1)
        #expect(meetings[0].meetingID == "valid-meeting")
    }

    // MARK: - Idempotent migration

    @Test func migrationIsIdempotent() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-idempotent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)

        // Write a v1 fixture
        let v1JSON = """
        {
            "schemaVersion": 1,
            "meetingID": "idempotent-test",
            "title": "Idempotent",
            "state": "completed",
            "startedAt": "2025-08-01T10:00:00Z",
            "sources": [],
            "retentionPolicy": "keepUntilDeleted",
            "aiMode": "transcriptionOnly",
            "lastCompletedSegmentIndex": 0,
            "transcriptSpans": ["[Segment 1] test"],
            "audioSegments": [],
            "events": [],
            "modelProviderMetadata": {}
        }
        """.data(using: .utf8)!

        let meetingDir = testRoot.appendingPathComponent("idempotent-test", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try v1JSON.write(to: meetingDir.appendingPathComponent("manifest.json"))

        // First decode → save (migrates to the current schema)
        let manifest = try store.load(meetingID: "idempotent-test")
        #expect(manifest.schemaVersion == 4)
        try store.saveManifest(manifest)

        // Second decode (should be identical)
        let reloaded = try store.load(meetingID: "idempotent-test")
        #expect(reloaded.schemaVersion == 4)
        #expect(reloaded.title == manifest.title)
        #expect(reloaded.transcriptSpans == manifest.transcriptSpans)
        #expect(reloaded.segments == manifest.segments)

        // Save again and decode again — still idempotent
        try store.saveManifest(reloaded)
        let reloaded2 = try store.load(meetingID: "idempotent-test")
        #expect(reloaded2 == reloaded)
    }

    // MARK: - Legacy transcriptSpans preserved after v2 save

    @Test func legacyTranscriptSpansPreservedAfterV2Save() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)

        // Create a v1 fixture with transcriptSpans and audio
        let v1JSON = """
        {
            "schemaVersion": 1,
            "meetingID": "legacy-preserve",
            "title": "Legacy Preserve",
            "state": "completed",
            "startedAt": "2025-08-01T10:00:00Z",
            "sources": [],
            "retentionPolicy": "keepUntilDeleted",
            "aiMode": "transcriptionOnly",
            "lastCompletedSegmentIndex": 1,
            "transcriptSpans": ["[Segment 1] important legacy text"],
            "audioSegments": ["segment_0000.wav"],
            "events": [],
            "modelProviderMetadata": {}
        }
        """.data(using: .utf8)!

        let meetingDir = testRoot.appendingPathComponent("legacy-preserve", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let audioDir = meetingDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("fake-audio".utf8).write(to: audioDir.appendingPathComponent("segment_0000.wav"))
        try v1JSON.write(to: meetingDir.appendingPathComponent("manifest.json"))

        // Migrate: load + save as v2
        let migrated = try store.load(meetingID: "legacy-preserve")
        try store.saveManifest(migrated)

        // Reload and verify legacy data intact
        let reloaded = try store.load(meetingID: "legacy-preserve")
        #expect(reloaded.transcriptSpans == ["[Segment 1] important legacy text"])
        #expect(reloaded.audioSegments == ["segment_0000.wav"])

        // Audio file still on disk
        let audioPath = store.audioDirectory(for: "legacy-preserve").appendingPathComponent("segment_0000.wav")
        #expect(FileManager.default.fileExists(atPath: audioPath.path))
    }

    // MARK: - Dual-write: transcriber produces both legacy spans and typed segments

    @MainActor
    @Test func transcriberDualWritesLegacySpansAndTypedSegments() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-dual-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let manifest = MeetingManifest(title: "Dual Write Test", state: .recording)
        try store.create(manifest)

        // Write a fake segment audio file
        let segmentURL = store.audioSegmentURL(for: manifest.meetingID, segmentIndex: 0)
        try Data("synthetic-audio".utf8).write(to: segmentURL)

        let stub = StubMeetingEngine(mode: .success(text: "dual write check"))
        let transcriber = MeetingTranscriber(
            store: store,
            modelIdentifier: "stub-model",
            customDictionaryURL: URL(fileURLWithPath: "/dev/null"),
            engine: stub
        )
        transcriber.start(meetingID: manifest.meetingID)

        // Transcribe one segment
        _ = await transcriber.transcribeSegmentRange(
            meetingID: manifest.meetingID,
            fromIndex: 0,
            toIndex: 1
        )

        // Reload the manifest and verify BOTH fields are populated
        let loaded = try store.load(meetingID: manifest.meetingID)

        // Legacy span written
        #expect(loaded.transcriptSpans.count == 1)
        #expect(loaded.transcriptSpans[0].contains("dual write check"))

        // Typed segment written
        #expect(loaded.segments.count == 1)
        #expect(loaded.segments[0].text == "dual write check")
        #expect(loaded.segments[0].sourceLabel == "Room")
        #expect(loaded.segments[0].isFinal == true)
        #expect(loaded.segments[0].sequence == 0)
    }

    // MARK: - updateMetadata via repository

    @Test func updateMetadataAppliesChangesThroughRepository() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-meta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let meetingID = "metadata-test"
        let manifest = MeetingManifest(meetingID: meetingID, title: "Original Title", state: .completed)
        try store.create(manifest)

        // Update metadata
        try store.updateMetadata(
            meetingID: meetingID,
            title: "Updated Title",
            participants: [MeetingParticipant(label: "Host")],
            agenda: [MeetingAgendaItem(text: "Review plan")],
            objectives: [MeetingObjective(text: "Ship feature")],
            notes: "Manual note",
            context: "Background context"
        )

        // Reload and verify
        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.title == "Updated Title")
        #expect(loaded.participants.count == 1)
        #expect(loaded.participants[0].label == "Host")
        #expect(loaded.agenda.count == 1)
        #expect(loaded.objectives.count == 1)
        #expect(loaded.manualNotes == "Manual note")
        #expect(loaded.contextBackground == "Background context")
    }
}
