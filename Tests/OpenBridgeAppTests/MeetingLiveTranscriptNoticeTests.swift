import SwiftUI
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

@Suite struct MeetingLiveTranscriptNoticeTests {
    @Test func cleanupOffDoesNotPromiseImprovementsEvenWithResearchCloudConfiguration() {
        let cloud = MeetingCloudProviderSnapshot(preset: .openRouter,
            endpoint: URL(string: "https://openrouter.ai/api/v1")!, model: "synthetic", timeout: 30)
        for provider in [MeetingCleanupProvider.localGemma, .cloud] {
            let copy = MeetingLiveTranscriptPresentation(configuration: .init(
                cleanupEnabled: false, cleanupProvider: provider, cloudProvider: cloud))
            #expect(copy.cleanupLabel == "Cleanup off")
            #expect(copy.cleanupExplanation == nil)
        }
    }

    @Test func cleanupCopyFollowsTheMeetingSnapshot() {
        var configuration = MeetingIntelligenceConfiguration(
            cleanupEnabled: true, cleanupProvider: .localGemma, cloudProvider: nil)
        let local = MeetingLiveTranscriptPresentation(configuration: configuration)
        configuration = .init(cleanupEnabled: true, cleanupProvider: .cloud, cloudProvider: nil)
        let cloud = MeetingLiveTranscriptPresentation(configuration: configuration)
        #expect(local.cleanupLabel == "Local cleanup after the meeting")
        #expect(cloud.cleanupLabel == "Cloud cleanup after the meeting")
        #expect(local.cleanupExplanation == "Cleanup can improve punctuation and readability.")
        #expect(cloud.cleanupExplanation == local.cleanupExplanation)
        #expect(local.accuracyNote == "Focus on the conversation. AI may mishear names and technical terms; review important details afterwards.")
    }

    @Test func cloudResearchDoesNotRelabelLocalCleanup() {
        let cloud = MeetingCloudProviderSnapshot(preset: .openRouter,
            endpoint: URL(string: "https://openrouter.ai/api/v1")!, model: "synthetic", timeout: 30)
        let copy = MeetingLiveTranscriptPresentation(configuration: .init(
            cleanupEnabled: true, cleanupProvider: .localGemma, cloudProvider: cloud))
        #expect(copy.cleanupLabel == "Local cleanup after the meeting")
    }

    @Test func absentSnapshotDoesNotInventACleanupChoice() {
        let copy = MeetingLiveTranscriptPresentation(configuration: nil)
        #expect(copy.cleanupLabel == "Cleanup setting unavailable")
        #expect(copy.cleanupExplanation == nil)
    }

    /// Structural proof only: full installed-app capture remains a separate gate.
    @Test func noticeUsesCaptureSnapshotAndRemainsOutsideTranscriptScroll() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeApp/MainWindowView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private var activeMeetingView:"))
        let end = try #require(source.range(of: "private var meetingStatusToastView:"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        let notice = try #require(view.range(of: "MeetingLiveTranscriptNotice(configuration: recordingIntelligenceConfiguration)"))
        let scroll = try #require(view.range(of: "ScrollView {"))
        let empty = try #require(view.range(of: "if transcriber.transcriptText.isEmpty"))
        #expect(notice.lowerBound < scroll.lowerBound)
        #expect(notice.lowerBound < empty.lowerBound)
        #expect(view.contains("titleBadge: \"Draft\""))
        #expect(!view.contains("store.load"))
        #expect(!view.contains("aiMode"))
        #expect(source.contains("recordingIntelligenceConfiguration = manifest.intelligenceConfiguration"))
        // Normal Stop, missing-ID recovery and failed capture all drop the snapshot.
        #expect(source.components(separatedBy: "recordingIntelligenceConfiguration = nil").count == 4)
    }
}

/// Genuine AppKit/SwiftUI component renders, using synthetic text only.
@Suite(.serialized) @MainActor struct MeetingLiveTranscriptNoticeRenderTests {
    @Test func noticeRendersWithLongTranscriptAtNarrowAndWideSizes() async throws {
        for width in [360, 760] {
            for mode in ["off", "local", "cloud", "unavailable"] {
                let configuration: MeetingIntelligenceConfiguration? = mode == "unavailable" ? nil : .init(
                    cleanupEnabled: mode != "off", cleanupProvider: mode == "cloud" ? .cloud : .localGemma,
                    cloudProvider: nil)
                let size = CGSize(width: width, height: 530)
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                    MeetingHomePanel(title: "Live transcript", titleBadge: "Draft") {
                        MeetingLiveTranscriptNotice(configuration: configuration)
                        ScrollView {
                            Text(String(repeating: "The project codename is Cedar. We agreed to review the design on Friday.\n\n", count: 20))
                                .font(OpenBridgeTypography.body).lineSpacing(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    Text("Synthetic native fixture · Not a live recording")
                        .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk)
                }.padding(16).frame(width: size.width, height: size.height)
                    .background(OpenBridgeTheme.canvas).preferredColorScheme(.light))
                host.setFrameSize(size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderOut(nil)
                defer { window.contentView = nil }
                try await settleNativeLayout(host)
                #expect(host.bounds.size == size)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 2_000)
                if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_TRANSCRIPT_NOTICE_RENDER_DIR"] {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try png.write(to: root.appendingPathComponent("live-transcript-\(mode)-\(width).png"))
                }
            }
        }
    }
}
