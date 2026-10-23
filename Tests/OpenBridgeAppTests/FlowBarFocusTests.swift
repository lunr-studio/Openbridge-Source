import AppKit
import Testing
@testable import OpenBridgeApp

@Suite @MainActor struct FlowBarFocusTests {
    @Test func transientControlsCannotBecomeTheKeyboardDestination() {
        // Do not show a window or send input to another app. Exercise the real
        // AppKit subclass, not a boolean copied into a mock panel.
        let panel = FlowBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isVisible)
    }

    @Test func dragHandleDoesNotRequireKeyboardFocus() {
        let handle = FlowBarDragHandle()
        #expect(!handle.acceptsFirstResponder)
        #expect(!handle.needsPanelToBecomeKey)
        #expect(handle.acceptsFirstMouse(for: nil))
    }

    @Test func defaultPositionKeepsTheBottomComposerClear() {
        let origin = FlowBarPlacement.origin(preferred: nil, size: NSSize(width: 600, height: 112),
                                              screens: [NSRect(x: 0, y: 40, width: 1440, height: 860)])
        #expect(origin == NSPoint(x: 420, y: 764))
    }

    @Test func userPositionSurvivesPhaseSizeChanges() {
        let frames = [NSRect(x: 0, y: 40, width: 1440, height: 860)]
        for height in [112.0, 160.0] {
            #expect(FlowBarPlacement.origin(preferred: NSPoint(x: 120, y: 300),
                size: NSSize(width: 600, height: height), screens: frames) == NSPoint(x: 120, y: 300))
        }
    }

    @Test func savedPositionRemainsReachableAfterDisplayOrSizeChanges() {
        let main = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let left = NSRect(x: -1440, y: 40, width: 1440, height: 860)
        let size = NSSize(width: 600, height: 160)
        #expect(FlowBarPlacement.origin(preferred: NSPoint(x: -1300, y: 300), size: size,
                                       screens: [main, left]) == NSPoint(x: -1300, y: 300))
        #expect(FlowBarPlacement.origin(preferred: NSPoint(x: -1300, y: 300), size: size,
                                       screens: [main]) == NSPoint(x: 0, y: 300))
        #expect(FlowBarPlacement.origin(preferred: NSPoint(x: 1300, y: 850), size: size,
                                       screens: [main]) == NSPoint(x: 840, y: 740))
        #expect(FlowBarPlacement.origin(preferred: NSPoint(x: CGFloat.infinity, y: 300), size: size,
                                       screens: [main]) == NSPoint(x: 420, y: 716))
    }
}
