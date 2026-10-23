import SwiftUI
import Testing
@testable import OpenBridgeApp

/// #321 design gate: renders the fixture review surface to PNGs so
/// screenshots can be attached to the issue for Trishan's approval.
/// Synthetic data only — DEBUG fixture views, never production UI.
@Suite(.serialized)
@MainActor
struct MeetingCleanupDesignGateScreenshots {

    @Test @MainActor func renderGalleryAndCards() async throws {
        let output = URL(fileURLWithPath: "/tmp/gate321", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func settle(_ view: NSView) async throws {
            // Offscreen window + runloop tick so SwiftUI layout settles
            // before the bitmap capture.
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            window.orderOut(nil)
            try await settleNativeLayout(view, ticks: 50)
        }

        func render(_ view: NSView, name: String, size: CGSize) async throws {
            view.setFrameSize(size)
            try await settle(view)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let tiff = try #require(rep.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("\(name).png"))
        }

        let gallery = NSHostingView(
            rootView: FixtureCleanupReviewGallery().frame(width: 560, height: 3200)
        )
        try await render(gallery, name: "00-gallery-full", size: CGSize(width: 560, height: 3200))

        let names: [MeetingCleanupReviewState: String] = [
            .toggleOff: "01-toggle-off",
            .toggleOnPreStop: "02-toggle-on-prestop",
            .originalShownImmediately: "03-original-immediately",
            .queued: "04-queued",
            .running: "05-running",
            .cancelled: "06-cancelled",
            .missingModel: "07-missing-model",
            .failed: "08-failed",
            .retryAvailable: "09-retry-available",
            .stale: "10-stale",
            .completedCleanedDefault: "11-completed-cleaned",
            .completedOriginalView: "12-completed-original",
        ]
        for (state, name) in names.sorted(by: { $0.value < $1.value }) {
            let card = NSHostingView(
                rootView: FixtureCleanupCard(
                    state: state,
                    toggleEnabled: state != .toggleOff
                )
                .frame(width: 520)
                .padding(12)
            )
            try await render(card, name: name, size: CGSize(width: 560, height: 340))
        }

        let produced = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasSuffix(".png") }
        #expect(produced.count >= 13)
        for file in produced {
            let attrs = try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(file).path)
            let size = attrs[.size] as? Int ?? 0
            #expect(size > 1_000, "\(file) looks empty")
        }
    }
}
