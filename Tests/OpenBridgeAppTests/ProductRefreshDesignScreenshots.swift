import AppKit
import SwiftUI
import Testing
@testable import OpenBridgeUI

/// Opt-in review artifacts from actual SwiftUI/AppKit controls and fictional
/// data. This harness does not construct AppState or any audio/provider service.
@Suite(.serialized) @MainActor struct ProductRefreshDesignScreenshots {
    @Test func researchAndTypographyReviewArtifacts() throws {
        guard let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_DESIGN_SCREENSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(OpenBridgeTypography.registerFonts().count == OpenBridgeTypography.bundledFontNames.count)

        for width in [300, 360, 420] {
            for enabled in [true, false] {
                let question = MeetingQuestionCard(id: "design-review", question: "What is our next step?", phase: .answered,
                    answer: "Start the pilot with a smaller group, learn from the first week, and make the next step clear for everyone.",
                    evidence: [ResearchObservatoryFixtures.currentMeetingEvidence], coverage: "Original transcript through 00:24:00")
                var snapshot = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil,
                    meetingQuestions: enabled ? [question] : [], meetingTitle: "Pilot planning · Fictional design fixture")
                snapshot.researchAccess = .init(canAsk: enabled, canEnable: !enabled,
                        detail: enabled ? "Cloud research is enabled for this meeting. Only selected transcript passages are sent."
                            : "Your transcript stays on this Mac. Enable cloud research to ask questions about this meeting.",
                        provider: enabled ? "Configured cloud provider" : "Cloud off")
                let view = ResearchRailView(viewModel: .init(snapshot: snapshot))
                try capture(view, size: .init(width: width, height: 680),
                    to: root.appendingPathComponent("native-research-\(enabled ? "answered" : "cloud-off")-\(width).png"))
            }
        }
        try capture(typographySheet, size: .init(width: 760, height: 620), to: root.appendingPathComponent("native-typography.png"))
    }

    private var typographySheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("OpenBridge, at home on your Mac.").font(OpenBridgeTypography.pageTitle)
                Text("Native typography review · Official bundled font originals").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Capture the signal. Learn with AI.").font(OpenBridgeTypography.sectionTitle)
                Text("Use AI running on your Mac to record a meeting. Keep the original words, explore the ideas, and return to the passages that matter.")
                    .font(OpenBridgeTypography.body).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button("Start meeting") {}.buttonStyle(.borderedProminent).tint(OpenBridgePalette.ink)
                Button("Review setup") {}.buttonStyle(.bordered)
                Button("Not ready") {}.buttonStyle(.bordered).disabled(true)
            }.font(OpenBridgeTypography.control).controlSize(.large)
            HStack(spacing: 20) {
                Label("On your Mac", systemImage: "lock").foregroundStyle(OpenBridgePalette.localInk)
                Label("Cloud off", systemImage: "cloud").foregroundStyle(OpenBridgePalette.cloudInk)
            }.font(OpenBridgeTypography.metadata)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text("00:24:08").font(OpenBridgeTypography.mono(size: 16, weight: .medium))
                Text("Today, 10:30 AM · Original transcript").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            }
            Text("Fictional fixture · No recording, model, provider or real transcript access.")
                .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            Spacer(minLength: 0)
        }
        .padding(32)
        .foregroundStyle(OpenBridgePalette.ink)
        .background(OpenBridgePalette.surface)
        .preferredColorScheme(.light)
    }

    private func capture<Content: View>(_ content: Content, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.setFrameSize(size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderOut(nil)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 2_000)
        try data.write(to: url)
        window.contentView = nil
    }
}
