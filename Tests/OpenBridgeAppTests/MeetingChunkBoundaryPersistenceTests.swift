import Testing
import Foundation
@testable import OpenBridgeApp

/// #294 wave-3 (3864858081): chunk boundary metadata round-trips through the
/// manifest so the recovery path can dedup overlaps + populate offsets even
/// after the recorder is gone.
@Suite(.serialized) struct MeetingChunkBoundaryPersistenceTests {

    @Test func boundaryCodableRoundTrips() throws {
        let b = MeetingChunkBoundary(
            chunkIndex: 2,
            startOffset: 3.5,
            endOffset: 14.2,
            overlapSeconds: 0.6,
            reason: .maxDuration,
            availableOverlap: 0.6
        )
        let data = try JSONEncoder().encode(b)
        let decoded = try JSONDecoder().decode(MeetingChunkBoundary.self, from: data)
        #expect(decoded == b)
        #expect(decoded.reason == .maxDuration)
    }

    @Test func manifestRoundTripsChunkBoundaries() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-chunkb-\\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let meetingID = "chunkb-test"
        var manifest = MeetingManifest(meetingID: meetingID, title: "Chunk B", state: .recording)
        manifest.chunkBoundaries = [
            MeetingChunkBoundary(chunkIndex: 0, startOffset: 0, endOffset: 5.0, overlapSeconds: 0.6, reason: .utteranceBoundary, availableOverlap: 0.6),
            MeetingChunkBoundary(chunkIndex: 1, startOffset: 4.4, endOffset: 11.0, overlapSeconds: 0.6, reason: .maxDuration, availableOverlap: 0.6),
        ]
        try store.create(manifest)

        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.chunkBoundaries.count == 2)
        #expect(loaded.chunkBoundaries[0].reason == .utteranceBoundary)
        #expect(loaded.chunkBoundaries[1].endOffset == 11.0)
        #expect(loaded.chunkBoundaries[1].startOffset == 4.4)
    }

    @Test func legacyManifestWithoutBoundariesMigratesEmpty() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-chunkb-legacy-\\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = MeetingSessionStore(rootDirectory: testRoot)
        let meetingID = "chunkb-legacy"
        // Build a manifest, then strip the chunkBoundaries key to simulate a
        // pre-#294 persisted file.
        var manifest = MeetingManifest(meetingID: meetingID, title: "Legacy", state: .completed)
        try store.create(manifest)
        let url = store.manifestURL(for: meetingID)
        var data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        data.removeValue(forKey: "chunkBoundaries")
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]).write(to: url, options: .atomic)

        let loaded = try store.load(meetingID: meetingID)
        #expect(loaded.chunkBoundaries.isEmpty)
    }
}
