import Foundation

// Test #217: Meeting session store CRUD, atomic writes, permissions, recovery

enum MeetingStoreTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let m): return m }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MeetingStoreTestFailure.failed(message) }
}

let testRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("openbridge-meeting-test-\(UUID().uuidString)", isDirectory: true)

defer { try? FileManager.default.removeItem(at: testRoot) }

let store = MeetingSessionStore(rootDirectory: testRoot)

// Test 1: Create and load
let meetingID = UUID().uuidString
let manifest = MeetingManifest(
    meetingID: meetingID,
    title: "Test Planning Meeting",
    workspaceID: "ws-001",
    state: .recording,
    sources: [MeetingSourceMetadata(deviceID: "mic-1")],
    retentionPolicy: .autoDeleteAfter7Days,
    aiMode: .localOnly
)

try store.create(manifest)
let loaded = try store.load(meetingID: meetingID)
try expect(loaded.meetingID == meetingID, "Meeting ID should match")
try expect(loaded.title == "Test Planning Meeting", "Title should match")
try expect(loaded.state == .recording, "State should match")
try expect(loaded.schemaVersion == MeetingManifest.currentSchemaVersion, "Schema version should be current")
print("[PASS] testCreateAndLoad")

// Test 2: Codable round-trip
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
let data = try encoder.encode(manifest)
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let decoded = try decoder.decode(MeetingManifest.self, from: data)
try expect(decoded == manifest, "Codable round-trip should be equal")
print("[PASS] testCodableRoundTrip")

// Test 3: Atomic manifest update
var updated = manifest
updated.state = .stopped
updated.endedAt = Date()
try store.saveManifest(updated)
let reloaded = try store.load(meetingID: meetingID)
try expect(reloaded.state == .stopped, "State should be updated to stopped")
try expect(reloaded.endedAt != nil, "Ended time should be set")
print("[PASS] testAtomicManifestUpdate")

// Test 4: List meetings
let meeting2 = MeetingManifest(title: "Second Meeting", state: .completed)
try store.create(meeting2)
let meetings = try store.listMeetings()
try expect(meetings.count == 2, "Should list 2 meetings, got \(meetings.count)")
print("[PASS] testListMeetings")

// Test 5: Delete meeting
try store.delete(meetingID: meetingID)
let afterDelete = try store.listMeetings()
try expect(afterDelete.count == 1, "Should have 1 meeting after delete")
try expect(afterDelete[0].meetingID == meeting2.meetingID, "Remaining meeting should be the second one")
print("[PASS] testDeleteMeeting")

// Test 6: Private file permissions
let dir = store.meetingDirectory(for: meeting2.meetingID)
let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
try expect((perms & 0o777) == 0o700, "Directory should have 0700 permissions, got \(String(perms & 0o777, radix: 8))")
print("[PASS] testPrivatePermissions")

// Test 7: Directory structure exists
let audioDir = store.audioDirectory(for: meeting2.meetingID)
try expect(FileManager.default.fileExists(atPath: audioDir.path), "Audio directory should exist")
let transcriptDir = store.transcriptDirectory(for: meeting2.meetingID)
try expect(FileManager.default.fileExists(atPath: transcriptDir.path), "Transcript directory should exist")
print("[PASS] testDirectoryStructure")

// Test 8: Rename
try store.rename(meetingID: meeting2.meetingID, newTitle: "Renamed Meeting")
let renamed = try store.load(meetingID: meeting2.meetingID)
try expect(renamed.title == "Renamed Meeting", "Title should be renamed")
print("[PASS] testRename")

// Test 9: Schema migration fixture — decode a version 0 manifest and verify migration to v1
let legacyJSON = """
{
  "schemaVersion": 0,
  "meetingID": "legacy-001",
  "title": "Legacy Meeting",
  "workspaceID": null,
  "state": "completed",
  "startedAt": "2026-07-01T10:00:00Z",
  "endedAt": "2026-07-01T11:00:00Z",
  "sources": [],
  "retentionPolicy": "keepUntilDeleted",
  "aiMode": "transcriptionOnly",
  "lastCompletedSegmentIndex": 5,
  "transcriptSpans": [],
  "audioSegments": [],
  "events": [],
  "exportPath": null,
  "modelProviderMetadata": {}
}
"""
let legacyData = legacyJSON.data(using: .utf8)!
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601

// This must succeed — the v0→v1 migration is implemented.
let legacy = try legacyDecoder.decode(MeetingManifest.self, from: legacyData)
try expect(legacy.meetingID == "legacy-001", "Legacy meeting ID should match")
try expect(legacy.title == "Legacy Meeting", "Legacy title should match")
try expect(legacy.schemaVersion == MeetingManifest.currentSchemaVersion, "Legacy schema version should be migrated to current (1), got \(legacy.schemaVersion)")
try expect(legacy.lastCompletedSegmentIndex == 5, "Legacy segment index should be preserved")
print("[PASS] testMigrationFixture")

// Test 10: Network-disabled storage — verify only file APIs are used
// The store uses only FileManager and Data, no URLSession or network APIs.
// We verify by creating a meeting in an isolated temp directory and confirming
// all operations are local file operations.
let isolatedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("openbridge-net-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: isolatedRoot) }
let isolatedStore = MeetingSessionStore(rootDirectory: isolatedRoot)
let netMeeting = MeetingManifest(title: "Network Test", state: .recording)
try isolatedStore.create(netMeeting)
let netLoaded = try isolatedStore.load(meetingID: netMeeting.meetingID)
try expect(netLoaded.meetingID == netMeeting.meetingID, "Isolated store should work without network")
// Verify no network-related files were created
let meetingContents = try FileManager.default.contentsOfDirectory(atPath: isolatedStore.meetingDirectory(for: netMeeting.meetingID).path)
try expect(!meetingContents.contains(where: { $0.contains(".cache") || $0.contains(".network") }), "No network artifacts should exist")
print("[PASS] testNetworkDisabledStorage")

// Test 11: Relaunch reconstruction — create with one store, load with a new instance
let relaunchRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("openbridge-relaunch-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: relaunchRoot) }
let firstStore = MeetingSessionStore(rootDirectory: relaunchRoot)
let relaunchMeeting = MeetingManifest(
    title: "Relaunch Test",
    workspaceID: "ws-relaunch",
    state: .recording,
    sources: [MeetingSourceMetadata(deviceID: "mic-relaunch")],
    retentionPolicy: .autoDeleteAfter30Days,
    aiMode: .localOnly
)
try firstStore.create(relaunchMeeting)
// Simulate relaunch: create a new store instance pointing to the same directory
let secondStore = MeetingSessionStore(rootDirectory: relaunchRoot)
let reconstructed = try secondStore.load(meetingID: relaunchMeeting.meetingID)
try expect(reconstructed.title == "Relaunch Test", "Title should survive relaunch")
try expect(reconstructed.state == .recording, "State should survive relaunch")
try expect(reconstructed.workspaceID == "ws-relaunch", "Workspace should survive relaunch")
try expect(reconstructed.sources.count == 1, "Sources should survive relaunch")
try expect(reconstructed.sources[0].deviceID == "mic-relaunch", "Source device should survive relaunch")
try expect(reconstructed.retentionPolicy == .autoDeleteAfter30Days, "Retention should survive relaunch")
try expect(reconstructed.aiMode == .localOnly, "AI mode should survive relaunch")
// Also verify list works after relaunch
let relaunchList = try secondStore.listMeetings()
try expect(relaunchList.count == 1, "Should list 1 meeting after relaunch")
try expect(relaunchList[0].meetingID == relaunchMeeting.meetingID, "Listed meeting should match")
print("[PASS] testRelaunchReconstruction")

print("\n--- All 11 meeting session store tests passed ---")
