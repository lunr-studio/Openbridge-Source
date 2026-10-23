import AppKit

/// Transient dictation controls, separate from the main application window.
@MainActor
final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool {
        // Nonactivating is not the same as non-key: clicking Stop must not
        // take keyboard focus away from the editor that will receive paste.
        // The flow bar has actions, not text inputs. Mouse/accessibility
        // actions and the existing global Stop/Cancel shortcuts remain the
        // interaction paths; keyboard navigation lives in the main window.
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// A dedicated drag region keeps Stop/Cancel clicks out of window dragging.
@MainActor
final class FlowBarDragHandle: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

enum FlowBarPlacement {
    static func origin(preferred: NSPoint?, size: NSSize, screens: [NSRect]) -> NSPoint? {
        guard let fallback = screens.first else { return nil }
        let preferred = preferred.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let screen = preferred.flatMap { point in
            screens.first { $0.intersects(NSRect(origin: point, size: size)) }
        } ?? fallback
        let point = preferred ?? NSPoint(x: screen.midX - size.width / 2,
                                         y: screen.maxY - size.height - 24)
        // Recover saved positions after a display is disconnected, and keep
        // taller recovery messages reachable after the panel changes size.
        return NSPoint(x: min(max(point.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                       y: min(max(point.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }
}
