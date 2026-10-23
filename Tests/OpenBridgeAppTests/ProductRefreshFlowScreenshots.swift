import AppKit
import SwiftUI
import Testing
@testable import OpenBridgeApp

/// Real production flow surface, fictional presentation data and inert actions.
/// No AppState, capture session, model, storage or provider is constructed.
@Suite(.serialized) @MainActor struct ProductRefreshFlowScreenshots {
    @Test func successTitlesDoNotClaimInsertionAfterCopyOrUnverifiedReplacement() {
        #expect(FlowBarPresentation.successTitle(for: "Text copied. Paste it into your app when you’re ready.", context: .dictation) == "Text copied")
        #expect(FlowBarPresentation.successTitle(for: "Replacement requested. Press Command-V if it did not appear.", context: .commandMode) == "Replacement requested")
        #expect(FlowBarPresentation.successTitle(for: "Selected text replaced with local AI. Use Undo to revert.", context: .commandMode) == "Text action complete")
    }

    @Test func nativeFlowSurfacesAtTheirActualContentHeight() throws {
        guard let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_DESIGN_SCREENSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        let listening = FlowBarPresentation(phase: .listening, title: "Listening",
            detail: "Your next thought, in your own words.", recordingStartedAt: now.addingTimeInterval(-8))
        let processing = FlowBarPresentation(phase: .processing, title: "Preparing transcript",
            detail: "Your Mac is turning your words into text.", processingStartedAt: now.addingTimeInterval(-3), allowsCancellation: true)
        let scenarios: [(String, FlowBarPresentation, Bool)] = [
            ("listening", listening, false),
            ("processing", processing, false),
            ("success", .init(phase: .success("Your words were inserted into the original app."), title: "Pasted into place",
                detail: "Your words were inserted into the original app."), false),
            ("error", .init(phase: .error("Microphone permission is required."), title: "Needs attention",
                detail: "Allow microphone access in System Settings, then try again."), false),
            ("recovery", .init(phase: .error("Text retained."), title: "Your text is ready",
                detail: "We could not confirm insertion. Copy your text, then paste it into the original app.", hasRecoveryText: true), false),
            ("hands-free-warning", .init(phase: .listening, title: "Listening",
                detail: "Recording will stop in 15 seconds. Finish your thought, or choose Stop when you are ready.",
                privacyLabel: "On your Mac · Hands-free", recordingStartedAt: now.addingTimeInterval(-105)), false),
            ("long-recovery", .init(phase: .error("Text retained."), title: "Your text is ready",
                detail: "Your text is safe. The original app is no longer available, so OpenBridge could not confirm that your words reached the right place. Copy this text, open the app where you want it, and paste when you are ready.", hasRecoveryText: true), false),
            ("listening-reduced-motion", listening, true),
            ("processing-reduced-motion", processing, true),
        ]
        var heights: [String: CGFloat] = [:]
        for (name, presentation, reducedMotion) in scenarios {
            let content = FlowBarSurface(presentation: presentation, inputLevel: { 0.45 }, reduceMotionOverride: reducedMotion)
                .frame(width: 600)
                .fixedSize(horizontal: false, vertical: true)
            let host = NSHostingView(rootView: content)
            host.setFrameSize(.init(width: 600, height: 112))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderOut(nil)
            settle(host)
            let height = max(112, ceil(host.fittingSize.height))
            heights[name] = height
            host.setFrameSize(.init(width: 600, height: height))
            window.setContentSize(host.frame.size)
            settle(host)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 2_000)
            try data.write(to: root.appendingPathComponent("native-flow-\(name)-600x\(Int(height)).png"))
            window.contentView = nil
        }
        let longHeight = try #require(heights["long-recovery"])
        let listeningHeight = try #require(heights["listening"])
        #expect(longHeight > listeningHeight, "Long recovery copy must grow the surface, not overlap controls")
        let summary = heights.sorted { $0.key < $1.key }.map { "\($0.key): 600 × \(Int($0.value)) pt" }.joined(separator: "\n")
        try ("Fictional native presentation fixtures. No audio or real app data.\n" + summary + "\n").write(to: root.appendingPathComponent("native-flow-sizes.txt"), atomically: true, encoding: .utf8)
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
}
