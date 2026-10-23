import XCTest
@testable import OpenBridgeApp
@testable import OpenBridgeUI

/// lunr-studio/Openbridge-Beta#299 (Build 24): evidence cards must show the
/// exact meeting identity + timestamp resolved from the meeting store
/// (store-owned title/date/segment offset, never model-generated), with a
/// safe fallback to the generic source-type label.
final class ResearchEvidenceIdentityTests: XCTestCase {

    private func makeTempStore() -> (MeetingSessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-identity-\(UUID().uuidString)", isDirectory: true)
        return (MeetingSessionStore(rootDirectory: dir), dir)
    }

    /// Exact identity: "<title> · <date> · <mm:ss offset>" from the manifest.
    func testSourceTitleResolvesMeetingTitleDateAndSegmentOffset() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 4
        components.hour = 10
        let startedAt = Calendar.current.date(from: components)!
        let segment = MeetingTranscriptSegment(
            id: "seg-1",
            meetingID: "m1",
            sequence: 0,
            startOffset: 254,
            endOffset: 280,
            sourceLabel: "Room",
            text: "The launch code is falcon-seven-two.",
            isFinal: true
        )
        let manifest = MeetingManifest(
            meetingID: "m1",
            title: "Kickoff Sync",
            startedAt: startedAt,
            segments: [segment]
        )
        try store.create(manifest)

        let title = ObservatoryRailBridge.sourceTitle(
            meetingID: "m1",
            segmentID: "seg-1",
            store: store
        )
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.hasPrefix("Kickoff Sync · "), "expected meeting title first, got: \(title!)")
        XCTAssertTrue(title!.contains("2026"), "expected meeting date, got: \(title!)")
        XCTAssertTrue(title!.hasSuffix("· 00:04:14"), "expected exact segment timestamp 00:04:14, got: \(title!)")
    }

    /// Missing/unknown segment falls back to title + date (no timestamp part).
    func testSourceTitleOmitsTimestampWhenSegmentOffsetUnknown() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = MeetingManifest(
            meetingID: "m2",
            title: "Standup",
            startedAt: Date()
        )
        try store.create(manifest)

        let title = ObservatoryRailBridge.sourceTitle(
            meetingID: "m2",
            segmentID: nil,
            store: store
        )
        XCTAssertEqual(title, title?.hasPrefix("Standup · ") == true ? title : nil)
        XCTAssertFalse(title?.contains(":") ?? true, "no timestamp expected without a segment offset")
    }

    /// Fix-cycle P2: fractional offsets truncate (254.6 -> 00:04:14), never
    /// round (00:04:15) — matching the transcript display conversion.
    func testSourceTitleTruncatesFractionalOffset() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segment = MeetingTranscriptSegment(
            id: "seg-f", meetingID: "m1", sequence: 0, startOffset: 254.6,
            endOffset: 280, sourceLabel: "Room",
            text: "Fractional offset segment.", isFinal: true
        )
        try store.create(MeetingManifest(
            meetingID: "m1", title: "T", segments: [segment]
        ))

        let title = ObservatoryRailBridge.sourceTitle(
            meetingID: "m1", segmentID: "seg-f", store: store
        )
        XCTAssertTrue(title!.hasSuffix("· 00:04:14"), "expected truncated 00:04:14, got: \(title!)")
    }

    /// Round-3 (P2): N evidence rows from one meeting decode the manifest
    /// exactly once via the per-meeting cache.
    func testTitleCacheDecodesEachMeetingOnce() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments = [
            MeetingTranscriptSegment(id: "s1", meetingID: "m1", sequence: 0, startOffset: 10, endOffset: 20, sourceLabel: "Room", text: "one", isFinal: true),
            MeetingTranscriptSegment(id: "s2", meetingID: "m1", sequence: 1, startOffset: 30, endOffset: 40, sourceLabel: "Room", text: "two", isFinal: true)
        ]
        try store.create(MeetingManifest(meetingID: "m1", title: "Cached", segments: segments))

        let cache = EvidenceTitleCache(store: store)
        XCTAssertNotNil(ObservatoryRailBridge.sourceTitle(meetingID: "m1", segmentID: "s1", cache: cache))
        XCTAssertNotNil(ObservatoryRailBridge.sourceTitle(meetingID: "m1", segmentID: "s2", cache: cache))
        XCTAssertEqual(cache.decodeCounts(), ["m1": 1])
    }

    /// Round-4 (P2 stale cache): a renamed meeting evicts its cached
    /// manifest, so the evidence title never goes stale.
    func testTitleCacheEvictsOnManifestChange() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.create(MeetingManifest(meetingID: "m1", title: "Old Title"))

        let cache = EvidenceTitleCache(store: store)
        let before = ObservatoryRailBridge.sourceTitle(meetingID: "m1", segmentID: nil, cache: cache)
        XCTAssertTrue(before!.hasPrefix("Old Title · "))

        try store.rename(meetingID: "m1", newTitle: "New Title")
        let after = ObservatoryRailBridge.sourceTitle(meetingID: "m1", segmentID: nil, cache: cache)
        XCTAssertTrue(after!.hasPrefix("New Title · "), "stale cached title served: \(after!)")
    }

    /// Missing manifest resolves nil, so the UI keeps the generic label.
    func testSourceTitleIsNilWhenManifestMissing() {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(ObservatoryRailBridge.sourceTitle(
            meetingID: "does-not-exist",
            segmentID: "seg-1",
            store: store
        ))
    }

    /// The UI model defaults to nil so existing fixture/preview evidence
    /// keeps rendering the generic source-type label.
    func testResearchEvidenceDefaultsToGenericLabel() {
        let evidence = ResearchEvidence(
            type: .priorMeeting,
            passage: "verbatim excerpt",
            sourceLocator: .priorMeeting(meetingID: "m1", segmentID: "seg-1"),
            confidence: 1.0
        )
        XCTAssertNil(evidence.sourceTitle)
        XCTAssertEqual(evidence.type.displayName, "Prior meeting")
    }
}