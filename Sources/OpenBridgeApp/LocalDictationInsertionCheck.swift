import AppKit
import ApplicationServices
import OSLog
import SwiftUI

/// Opt-in local-package diagnostics. No microphone, model, History, or Return.
@MainActor
enum LocalDictationInsertionCheck {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "OpenBridgeLocalTest") as? Bool == true
    }

    enum Action: String {
        case insertion, inspectAccessibility, prepareAccessibility
    }

    enum Destination: String, CaseIterable {
        case textEdit = "com.apple.TextEdit"
        case evernote = "com.evernote.Evernote"
        case chrome = "com.google.Chrome"
        var title: String {
            switch self {
            case .textEdit: "TextEdit"
            case .evernote: "Evernote"
            case .chrome: "Chrome"
            }
        }
    }

    private static let logger = Logger(subsystem: "studio.lunr.openbridge", category: "LocalDictationCheck")
    private static var isRunning = false
    private static var preparedProcesses: Set<pid_t> = []

    static func schedule(_ action: Action, destination: Destination) {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        logger.notice("Scheduled local check: \(action.rawValue, privacy: .public); delay: 5 seconds")
        // A menu command must not leave this app's main window holding key focus.
        // This is diagnostic setup, not the normal dictation delivery path.
        NSApp.hide(nil)
        Task { @MainActor in
            defer { isRunning = false }
            do {
                try await Task.sleep(for: .seconds(5))
                guard isEnabled, let application = externalFrontmostApplication(),
                      application.bundleIdentifier == destination.rawValue else {
                    logger.notice("Local check stopped: named destination is not frontmost")
                    return
                }
                logPermissions(application)
                guard AXIsProcessTrusted() else {
                    logger.notice("Local check stopped: accessibility not trusted")
                    return
                }
                switch action {
                case .insertion:
                    let target = PasteboardService.captureDictationTarget(application: application)
                    logger.notice("Local insertion target captured: \(target != nil)")
                    guard let target, isStillFrontmost(application) else { return }
                    try await Task.sleep(for: .seconds(1))
                    guard isStillFrontmost(application) else {
                        logger.notice("Local insertion stopped: destination changed")
                        return
                    }
                    let result = await PasteboardService.deliverDictation(
                        "OpenBridge automatic insertion check.", target: target, pressEnter: false,
                        isCancelled: { !isStillFrontmost(application) }
                    )
                    logger.notice("Local insertion result: \(String(describing: result), privacy: .public); post-event access: \(CGPreflightPostEventAccess())")
                case .inspectAccessibility:
                    inspectAccessibility(application)
                case .prepareAccessibility:
                    guard let bundle = application.bundleIdentifier,
                          ["com.evernote.Evernote", "com.google.Chrome"].contains(bundle),
                          isStillFrontmost(application) else {
                        logger.notice("Accessibility preparation stopped: unsupported or changed application")
                        return
                    }
                    guard preparedProcesses.insert(application.processIdentifier).inserted else {
                        logger.notice("Accessibility preparation already attempted for this process")
                        inspectAccessibility(application)
                        return
                    }
                    // Enables the Electron/Chromium accessibility tree under
                    // existing AX trust. This does not request an OS permission.
                    let appElement = AXUIElementCreateApplication(application.processIdentifier)
                    let error = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    logger.notice("Accessibility tree preparation: bundle=\(bundle, privacy: .public); AX error=\(error.rawValue)")
                    try await Task.sleep(for: .milliseconds(2500))
                    guard isStillFrontmost(application) else {
                        logger.notice("Accessibility inspection stopped: destination changed")
                        return
                    }
                    inspectAccessibility(application)
                }
            } catch {
                logger.notice("Local check cancelled")
            }
        }
    }

    private static func externalFrontmostApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundle = application.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier else { return nil }
        return application
    }

    private static func isStillFrontmost(_ application: NSRunningApplication) -> Bool {
        isEnabled && !Task.isCancelled && !application.isTerminated
            && externalFrontmostApplication()?.processIdentifier == application.processIdentifier
    }

    private static func logPermissions(_ application: NSRunningApplication) {
        logger.notice("Local check destination: bundle=\(application.bundleIdentifier ?? "unknown", privacy: .public); AX trusted=\(AXIsProcessTrusted()); post-event access=\(CGPreflightPostEventAccess())")
    }

    private static func inspectAccessibility(_ application: NSRunningApplication) {
        inspectFocusedElement(AXUIElementCreateSystemWide(), scope: "system", application: application)
        inspectFocusedElement(AXUIElementCreateApplication(application.processIdentifier), scope: "application", application: application)
    }

    private static func inspectFocusedElement(_ root: AXUIElement, scope: String, application: NSRunningApplication) {
        guard isStillFrontmost(application), AXIsProcessTrusted() else { return }
        var focusedValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard isStillFrontmost(application) else { return }
        let isElement = focusedValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
        logger.notice("Accessibility focus observation: scope=\(scope, privacy: .public); AX error=\(focusError.rawValue); element available=\(isElement)")
        guard focusError == .success, isElement, let focusedValue else { return }
        let focusedElement = focusedValue as! AXUIElement
        var focusedPID: pid_t = 0
        let pidError = AXUIElementGetPid(focusedElement, &focusedPID)
        let matchesTarget = pidError == .success && focusedPID == application.processIdentifier
        logger.notice("Accessibility focus process: scope=\(scope, privacy: .public); AX error=\(pidError.rawValue); matches target=\(matchesTarget)")
        guard matchesTarget, isStillFrontmost(application) else { return }
        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleValue)
        guard isStillFrontmost(application) else { return }
        // Never read/log values, text, selections, titles, or element descriptions.
        let role = roleValue as? String ?? "unavailable"
        logger.notice("Accessibility role observation: scope=\(scope, privacy: .public); AX error=\(roleError.rawValue); role=\(role, privacy: .public)")
    }
}

@MainActor
struct LocalDictationInsertionCommands: Commands {
    var body: some Commands {
        if LocalDictationInsertionCheck.isEnabled {
            CommandMenu("Local dictation check") {
                ForEach(LocalDictationInsertionCheck.Destination.allCases, id: \.rawValue) { destination in
                    Menu(destination.title) {
                        Button("Check automatic insertion (5 seconds)") {
                            LocalDictationInsertionCheck.schedule(.insertion, destination: destination)
                        }
                        Button("Inspect editor accessibility (5 seconds)") {
                            LocalDictationInsertionCheck.schedule(.inspectAccessibility, destination: destination)
                        }
                        Button("Prepare Electron editor accessibility (5 seconds)") {
                            LocalDictationInsertionCheck.schedule(.prepareAccessibility, destination: destination)
                        }
                    }
                }
            }
        }
    }
}
