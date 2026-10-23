import AppKit

@MainActor
enum OpenBridgeQuitController {
    static func requestQuit() {
        // MenuBarExtra-hosted SwiftUI alerts can render correctly while routing actions unreliably.
        // Use an AppKit modal response so confirmation and termination stay on the same path.
        let alert = NSAlert()
        alert.messageText = "Turn off Openbridge?"
        alert.informativeText = "This quits Openbridge. To use dictation again, open Openbridge from Applications."
        alert.alertStyle = .warning

        let turnOffButton = alert.addButton(withTitle: "Turn Off")
        turnOffButton.hasDestructiveAction = true
        turnOffButton.keyEquivalent = ""

        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}
