import AppKit
import SwiftUI

@MainActor
final class FlowBarWindowController: NSObject, NSWindowDelegate {
    private static let panelSize = NSSize(width: 600, height: 112)
    private static let positionXKey = "flowBarPositionX"
    private static let positionYKey = "flowBarPositionY"

    private let panel: NSPanel
    private let hostingView: NSHostingView<FlowBarOverlayViewWithState>
    private var isPositioning = false
    private var preferredOrigin: NSPoint?

    init(appState: AppState) {
        hostingView = NSHostingView(rootView: FlowBarOverlayViewWithState(appState: appState))
        panel = FlowBarPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.positionXKey) != nil,
           defaults.object(forKey: Self.positionYKey) != nil {
            preferredOrigin = NSPoint(x: defaults.double(forKey: Self.positionXKey),
                                      y: defaults.double(forKey: Self.positionYKey))
        }
        panel.delegate = self
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.level = .floating

        hostingView.rootView = FlowBarOverlayViewWithState(appState: appState) { [weak self] height in
            self?.resizeToContent(height)
        }
        panel.contentView = hostingView

    }

    func updateVisibility(for phase: FlowBarPhase) {
        if phase.isVisible {
            // Fit long recovery/help copy instead of squeezing it over the timer
            // and actions. The width stays predictable across every phase.
            hostingView.layoutSubtreeIfNeeded()
            resizeToContent(hostingView.fittingSize.height)
            positionPanel()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func resizeToContent(_ height: CGFloat) {
        let contentHeight = max(112, ceil(height))
        guard abs(panel.frame.height - contentHeight) > 1 else { return }
        isPositioning = true
        panel.setContentSize(NSSize(width: Self.panelSize.width, height: contentHeight))
        isPositioning = false
        positionPanel()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frames = [screen.visibleFrame] + NSScreen.screens.filter { $0 != screen }.map(\.visibleFrame)
        guard let origin = FlowBarPlacement.origin(preferred: preferredOrigin,
                                                   size: panel.frame.size, screens: frames) else { return }
        isPositioning = true
        panel.setFrameOrigin(origin)
        isPositioning = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, panel.isVisible else { return }
        preferredOrigin = panel.frame.origin
        UserDefaults.standard.set(panel.frame.minX, forKey: Self.positionXKey)
        UserDefaults.standard.set(panel.frame.minY, forKey: Self.positionYKey)
    }
}

private struct FlowBarOverlayViewWithState: View {
    @ObservedObject var appState: AppState
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        FlowBarOverlayView()
            .environmentObject(appState)
            .frame(width: 600)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                        onHeightChange(height)
                    }
                }
            }
    }
}
