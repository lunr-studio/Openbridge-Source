import Foundation
import Testing
@testable import OpenBridgeApp

@Suite struct MeetingHomeTests {
    @Test func homeIsAllowedDuringEveryCaptureTransition() {
        for starting in [false, true] {
            for recording in [false, true] {
                #expect(MeetingHomeNavigation.blocker(leavingHome: false, starting: starting, recording: recording) == nil)
            }
        }
    }

    @Test func allOtherRoutesWaitUntilCaptureAndFinalizationFinish() {
        #expect(MeetingHomeNavigation.blocker(leavingHome: true, starting: false, recording: false) == nil)
        #expect(MeetingHomeNavigation.blocker(leavingHome: true, starting: true, recording: false)?.contains("starting") == true)
        // The existing orchestration keeps recording true through finalization.
        #expect(MeetingHomeNavigation.blocker(leavingHome: true, starting: false, recording: true)?.contains("saving") == true)
        #expect(MeetingHomeNavigation.blocker(leavingHome: true, starting: true, recording: true) != nil)
    }

    @Test func recentMeetingsAreThreeNewestWithStableTies() {
        let records = [
            MeetingManifest(meetingID: "old", title: "Old", startedAt: Date(timeIntervalSince1970: 1)),
            MeetingManifest(meetingID: "b", title: "B", startedAt: Date(timeIntervalSince1970: 3)),
            MeetingManifest(meetingID: "latest", title: "Latest", startedAt: Date(timeIntervalSince1970: 4)),
            MeetingManifest(meetingID: "a", title: "A", startedAt: Date(timeIntervalSince1970: 3))
        ]
        #expect(MeetingHomeNavigation.recentMeetings(records).map(\.meetingID) == ["latest", "a", "b"])
        #expect(records.first?.meetingID == "old")
        #expect(MeetingHomeNavigation.recentMeetings([]).isEmpty)
        #expect(MeetingHomeNavigation.recentMeetings(Array(records.prefix(1))).count == 1)
    }

    @Test func columnsFitAtAndAroundTheBreakpoint() {
        for width in [CGFloat(630), 759, 760, 882, 1180] {
            let layout = MeetingHomeMetrics(width: width)
            if width < 760 {
                #expect(!layout.isSplit)
                #expect(layout.meetingWidth == width)
                #expect(layout.setupWidth == width)
            } else {
                #expect(layout.isSplit)
                #expect(layout.meetingWidth + 16 + layout.setupWidth == width)
                #expect(layout.setupWidth == 260)
            }
        }
    }

    @Test func deletionTargetsExcludeHiddenStaleAndDuplicateSelections() {
        let visible = [MeetingManifest(meetingID: "a", title: "A"), MeetingManifest(meetingID: "b", title: "B")]
        #expect(MeetingDeletionSelection.targets(in: visible + visible, selected: ["b", "hidden", "missing"]).map(\.meetingID) == ["b"])
        #expect(MeetingDeletionSelection.targets(in: visible, selected: []).isEmpty)
        let confirmation = MeetingDeletionSelection.confirmation(visible)
        #expect(confirmation.contains("• A\n• B"))
        #expect(confirmation.contains("cannot be undone"))
        #expect(confirmation.contains("audio, transcripts and saved intelligence conversations"))
        #expect(confirmation.contains("Answers in other meetings that rely on these meetings are also removed"))
    }

    @MainActor @Test func bulkDeletionWaitsForEachCompletionAndReportsPartialFailures() async {
        let meetings = [MeetingManifest(meetingID: "a", title: "A"), MeetingManifest(meetingID: "b", title: "B"), MeetingManifest(meetingID: "c", title: "C")]
        var events: [String] = []
        let failed = await MeetingDeletionSelection.run(meetings) { meeting in
            events.append("start-\(meeting.meetingID)")
            await Task.yield()
            events.append("end-\(meeting.meetingID)")
            return meeting.meetingID != "b"
        }
        #expect(events == ["start-a", "end-a", "start-b", "end-b", "start-c", "end-c"])
        #expect(failed.map(\.meetingID) == ["b"])
    }

    @MainActor @Test func bulkDeletionRemovesOnlySelectedSyntheticRecordsAndTheirFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-home-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let meetings = ["a", "b", "keep"].map { MeetingManifest(meetingID: $0, title: "Synthetic \($0)", state: .completed) }
        for meeting in meetings {
            try store.create(meeting)
            try Data("synthetic-audio".utf8).write(to: store.audioSegmentURL(for: meeting.meetingID, segmentIndex: 0))
        }
        let targets = MeetingDeletionSelection.targets(in: meetings, selected: ["a", "b"])
        let failed = await MeetingDeletionSelection.run(targets) { meeting in
            do { try store.delete(meetingID: meeting.meetingID); return true } catch { return false }
        }
        #expect(failed.isEmpty)
        #expect(throws: (any Error).self) { try store.load(meetingID: "a") }
        #expect(throws: (any Error).self) { try store.load(meetingID: "b") }
        #expect(!FileManager.default.fileExists(atPath: store.audioSegmentURL(for: "a", segmentIndex: 0).path))
        #expect(try store.load(meetingID: "keep").title == "Synthetic keep")
        #expect(FileManager.default.fileExists(atPath: store.audioSegmentURL(for: "keep", segmentIndex: 0).path))
    }

    /// Source composition guard, not a substitute for installed recording proof.
    @Test func oneWorkspaceOwnsCaptureAboveBothPresentationsAndResearchFocus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeApp/MainWindowView.swift"), encoding: .utf8)
        #expect(source.contains("case .home, .meetings:"))
        #expect(source.contains("if cloudAnswersEnabled { ResearchObservatoryFeatureFlag.setEnabled(true) }"))
        #expect(source.components(separatedBy: "MainMeetingWorkspace(").count == 2)
        #expect(source.contains("if isLibrary { meetingLibraryView } else { meetingSetupView }"))
        let owner = try #require(source.range(of: "struct MainMeetingWorkspace"))
        let ownerSource = String(source[owner.lowerBound...])
        let header = try #require(ownerSource.range(of: "MeetingHomeRecordingHeader("))
        let adaptive = try #require(ownerSource.range(of: "ResearchGatedMeetingsContent("))
        #expect(header.lowerBound < adaptive.lowerBound)
        #expect(source.contains("appState.beginMeetingStart()"))
        #expect(source.contains(".alert(\"Stop meeting?\""))
        #expect(source.contains(".alert(\"Change retention policy?\""))
        #expect(source.contains("MeetingHomeNavigation.blocker("))
        #expect(!source.contains("MainMeetingsPage("))
    }
}
