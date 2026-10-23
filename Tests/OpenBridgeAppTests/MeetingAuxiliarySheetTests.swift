import Foundation
import Testing
@testable import OpenBridgeApp

/// A source integration guard for modal handoff order, not native interaction
/// acceptance. Offscreen SwiftUI hosting does not expose a reliable AX tree;
/// live Stop availability while permissions save remains a manual native gate.
struct MeetingAuxiliarySheetTests {
    @Test func bothModalStopRequestsWaitUntilDismissal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeApp/MainWindowView.swift"), encoding: .utf8)
        for (start, end, flag, dismiss) in [
            (".sheet(item: $selectedReplayMeeting, onDismiss:", ".onReceive(NotificationCenter.default.publisher(for: ResearchSourceNavigationRequest.notification))", "stopAfterReplayDismissal", "selectedReplayMeeting = nil"),
            (".sheet(isPresented: $showingResearchPermissions, onDismiss:", "private var workspacePage:", "stopAfterResearchDismissal", "showingResearchPermissions = false")
        ] {
            let startRange = try #require(source.range(of: start))
            let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
            let sheet = String(source[startRange.lowerBound..<endRange.lowerBound])
            let wrapper = try #require(sheet.range(of: "MeetingAuxiliarySheet("))
            let dismissal = String(sheet[..<wrapper.lowerBound])
            let content = String(sheet[wrapper.lowerBound...])
            #expect(dismissal.contains("if \(flag)"))
            #expect(dismissal.contains("OpenBridgeNavigation.shared.stopMeetingRequests.send(())"))
            #expect(content.contains("\(flag) = true"))
            #expect(content.contains(dismiss))
            #expect(!content.contains("stopMeetingRequests.send"))
        }
    }

}
