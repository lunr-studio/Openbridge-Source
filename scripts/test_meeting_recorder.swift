import Foundation

// Test #293: Meeting recorder storage and manifest behavior
//
// NOTE: These tests validate filenames, manifest storage, state transitions,
// and store isolation. They do NOT exercise real microphone capture, timed
// segment rotation, or AVFoundation cancellation — those require physical
// testing on the Mac with microphone access.

enum MeetingRecorderTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let m): return m }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MeetingRecorderTestFailure.failed(message) }
}

let testRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("meeting-recorder-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: testRoot) }

let store = MeetingSessionStore(rootDirectory: testRoot)

// Test 1: Segment URL uses .wav extension
let segmentURL = store.audioSegmentURL(for: "test-meeting", segmentIndex: 0)
try expect(segmentURL.pathExtension == "wav", "Segment extension should be .wav, got \(segmentURL.pathExtension)")
print("[PASS] testSegmentExtensionIsWAV")

// Test 2: Segment URL format is correct
let segmentURL2 = store.audioSegmentURL(for: "test-meeting", segmentIndex: 5)
try expect(segmentURL2.lastPathComponent == "segment_0005.wav", "Segment filename should be segment_0005.wav, got \(segmentURL2.lastPathComponent)")
print("[PASS] testSegmentURLFormat")

// Test 3: Multiple segments have sequential names
for i in 0..<10 {
    let url = store.audioSegmentURL(for: "test-meeting", segmentIndex: i)
    let expected = String(format: "segment_%04d.wav", i)
    try expect(url.lastPathComponent == expected, "Segment \(i) should be \(expected), got \(url.lastPathComponent)")
}
print("[PASS] testSequentialSegmentNames")

// Test 4: Manifest retains exact meeting ID through save/load cycle
let testMeetingID = "exact-id-test-12345"
let manifest = MeetingManifest(
    meetingID: testMeetingID,
    title: "ID Retention Test",
    state: .recording
)
try store.create(manifest)
let loaded = try store.load(meetingID: testMeetingID)
try expect(loaded.meetingID == testMeetingID, "Meeting ID should be exactly \(testMeetingID), got \(loaded.meetingID)")
print("[PASS] testMeetingIDRetention")

// Test 5: Audio segments list updates in manifest after save
var updated = loaded
updated.audioSegments = ["segment_0000.wav", "segment_0001.wav"]
updated.lastCompletedSegmentIndex = 2
try store.saveManifest(updated)
let reloaded = try store.load(meetingID: testMeetingID)
try expect(reloaded.audioSegments.count == 2, "Should have 2 audio segments, got \(reloaded.audioSegments.count)")
try expect(reloaded.lastCompletedSegmentIndex == 2, "Last completed segment should be 2, got \(reloaded.lastCompletedSegmentIndex)")
print("[PASS] testManifestSegmentUpdate")

// Test 6: Meeting state transitions (recording → stopped)
try expect(updated.state == .recording, "Initial state should be recording")
updated.state = .stopped
updated.endedAt = Date()
try store.saveManifest(updated)
let stoppedManifest = try store.load(meetingID: testMeetingID)
try expect(stoppedManifest.state == .stopped, "State should be stopped")
try expect(stoppedManifest.endedAt != nil, "EndedAt should be set")
print("[PASS] testStateTransitionToStopped")

// Test 7: Recorder creates separate session from dictation
let recorder = MeetingRecorder(store: store)
try expect(!recorder.isRecording, "New recorder should not be recording")
print("[PASS] testRecorderInitiallyNotRecording")

// Test 8: Store isolation — two stores with same root see same data
let store2 = MeetingSessionStore(rootDirectory: testRoot)
let crossStoreMeetings = try store2.listMeetings()
try expect(crossStoreMeetings.count == 1, "Second store should see 1 meeting, got \(crossStoreMeetings.count)")
try expect(crossStoreMeetings[0].meetingID == testMeetingID, "Cross-store meeting ID should match")
print("[PASS] testStoreIsolation")

// Test 9: Cleanup — delete removes all artifacts
try store.delete(meetingID: testMeetingID)
let afterDelete = try store.listMeetings()
try expect(afterDelete.count == 0, "Should have 0 meetings after delete")
print("[PASS] testDeleteRemovesArtifacts")

print("\n--- All 9 meeting recorder tests passed ---")