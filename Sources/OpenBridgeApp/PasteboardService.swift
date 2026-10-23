import AppKit
import ApplicationServices
import Foundation
import OSLog

struct PasteboardSnapshot {
    fileprivate let items: [PasteboardItemSnapshot]
}

final class AccessibilitySelectionReference: @unchecked Sendable {
    fileprivate let element: AXUIElement
    fileprivate let selectedRange: CFRange?

    fileprivate init(element: AXUIElement, selectedRange: CFRange?) {
        self.element = element
        self.selectedRange = selectedRange
    }
}

private struct PasteboardItemSnapshot {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
}

private struct AccessibilitySelectionSnapshot {
    let reference: AccessibilitySelectionReference
    let selectedText: String?
}

enum SelectedTextCaptureResult {
    case captured(
        text: String,
        accessibilityReference: AccessibilitySelectionReference?
    )
    case noSelection
    case failed
}

enum SelectedTextReplacementResult {
    case replaced
    case pasteRequested
    case copiedToClipboard
}

enum DictationDeliveryResult: Equatable {
    case empty
    case verified(enterSent: Bool)
    case unverified
    case copiedToClipboard
    case clipboardChanged

    var message: String {
        switch self {
        case .empty: "No speech was recognized. Try again closer to the microphone. Nothing was pasted or added to History."
        case .verified(let enterSent): enterSent ? "Dictation pasted and Return sent." : "Dictation pasted."
        case .unverified: "OpenBridge couldn’t confirm insertion. If your words are in place, you’re done. Use Copy text only if they’re missing."
        case .copiedToClipboard: "Text copied. Focus the intended text box and press ⌘V. Automatic paste was unavailable or the destination changed."
        case .clipboardChanged: "The clipboard was unavailable or changed before paste. Automatic paste was stopped. Choose Copy text, then paste into the intended text box."
        }
    }
}

enum DictationDeliveryError: LocalizedError {
    case noSpeech
    var errorDescription: String? { DictationDeliveryResult.empty.message }
}

/// Confirmation of content is separate from permission to submit it with Return.
enum DictationInsertionVerification {
    case unverified
    case exact
    case chromeTerminalNewline
    case codexEmptyComposer

    var isVerified: Bool { self != .unverified }
    var allowsReturn: Bool { self == .exact }

    static func result(
        original: String?, expected: String?, actual: String?, bundleIdentifier: String?,
        deliveredText: String? = nil, capturedCodexPlaceholder: Bool = false
    ) -> Self {
        guard let original, let expected, let actual,
              expected != original, actual != original else { return .unverified }
        if capturedCodexPlaceholder {
            // Preserve raw capture/readiness checks, but the empty composer's
            // generated prompt is not document content. Require the WHOLE
            // delivered value, never a substring or whitespace normalization.
            guard bundleIdentifier == "com.openai.codex",
                  DictationDelivery.hasUsableText(original),
                  let deliveredText, DictationDelivery.hasUsableText(deliveredText),
                  expected == deliveredText + original,
                  actual == deliveredText else { return .unverified }
            return .codexEmptyComposer
        }
        if actual == expected { return .exact }
        // Observed Outlook/Chrome AX readback drops one final paragraph LF.
        // Compare the ENTIRE value; do not trim/collapse whitespace, accept
        // extra text, or extend this rule to other apps. This proof never
        // authorizes Return because the field is not an exact-value match.
        if bundleIdentifier == "com.google.Chrome",
           DictationDelivery.hasUsableText(actual),
           !actual.hasSuffix("\n"), !actual.hasSuffix("\r"),
           expected == actual + "\n" {
            return .chromeTerminalNewline
        }
        return .unverified
    }
}

/// Codex decorates its sole empty paragraph with this marker. Unlike the
/// generated prompt's value/count, this comes from the editor's empty-doc state.
enum DictationCodexPlaceholder {
    static func matches(
        bundleIdentifier: String?, value: String?, range: CFRange?,
        editorClasses: [String]?, childCount: Int?, paragraphClasses: [String]?
    ) -> Bool {
        bundleIdentifier == "com.openai.codex"
            && value.map(DictationDelivery.hasUsableText) == true
            && range?.location == 0 && range?.length == 0
            && editorClasses?.contains("ProseMirror") == true
            && childCount == 1 && paragraphClasses?.contains("placeholder") == true
    }
}

enum DictationInsertionStrategy: Equatable {
    case accessibilityThenKeyboard
    case keyboardOnly

    static func forApplication(bundleIdentifier: String?) -> Self {
        // Chrome/Outlook and Codex accepted AX writes without inserting.
        // Evernote uses the same Chromium editor family. Choose keyboard delivery BEFORE any
        // mutation; retrying an accepted AX write could duplicate the text.
        switch bundleIdentifier {
        case "com.google.Chrome", "com.evernote.Evernote", "com.openai.codex": .keyboardOnly
        default: .accessibilityThenKeyboard
        }
    }
}

enum DictationAccessibilityPreparation {
    /// Request the documented Electron switch first. A compatibility fallback
    /// must not hide a permission/communication error or target another app.
    static func prepare(bundleIdentifier: String?, setAttribute: (String) -> AXError) -> AXError {
        let result = setAttribute("AXManualAccessibility")
        guard bundleIdentifier == "com.openai.codex", result == .attributeUnsupported else { return result }
        // Chromium provides this alternative switch. Its full tree is enabled
        // after a short debounce; acceptance is not proof of focused content.
        return setAttribute("AXEnhancedUserInterface")
    }
}

/// Successful preparation can rebuild Electron's tree, so do it once per launch.
/// A busy/unresponsive app may fail the request: retry only that result on a
/// later activation/recording start, with a cooldown and a finite attempt budget.
struct DictationAccessibilityPreparationTracker {
    private struct ProcessIdentity: Equatable {
        let processIdentifier: pid_t
        let launchDate: Date
    }

    private struct Attempt {
        let identity: ProcessIdentity
        var count = 1
        var lastAttempt: TimeInterval
        var canRetry = false
    }

    private let capacity: Int
    private var attempts: [Attempt] = []

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    var trackedProcessCount: Int { attempts.count }

    mutating func shouldPrepare(
        bundleIdentifier: String?, processIdentifier: pid_t,
        launchDate: Date?, isTrusted: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard isTrusted,
              bundleIdentifier == "com.evernote.Evernote" || bundleIdentifier == "com.openai.codex",
              processIdentifier > 0, let launchDate else { return false }
        let identity = ProcessIdentity(processIdentifier: processIdentifier, launchDate: launchDate)
        if let index = attempts.firstIndex(where: { $0.identity == identity }) {
            guard attempts[index].canRetry, attempts[index].count < 3,
                  now - attempts[index].lastAttempt >= 1 else { return false }
            attempts[index].count += 1
            attempts[index].lastAttempt = now
            attempts[index].canRetry = false
            return true
        }
        // A reused PID is a different process; retain no stale identity for it.
        attempts.removeAll { $0.identity.processIdentifier == processIdentifier }
        if attempts.count >= capacity { attempts.removeFirst() }
        attempts.append(Attempt(identity: identity, lastAttempt: now))
        return true
    }

    mutating func recordResult(_ result: AXError, processIdentifier: pid_t, launchDate: Date?) {
        guard let launchDate,
              let index = attempts.firstIndex(where: {
                $0.identity == ProcessIdentity(processIdentifier: processIdentifier, launchDate: launchDate)
              }) else { return }
        // Unsupported attributes and permission errors cannot be repaired by
        // repeating the request. Success must never restart preparation either.
        attempts[index].canRetry = result == .cannotComplete
    }
}

enum DictationFocusFallbackPolicy {
    static func allowsSystemWideFallback(
        applicationReadError: AXError, expectedPID: pid_t,
        elementPID: pid_t?, frontmostPID: pid_t?
    ) -> Bool {
        [.noValue, .cannotComplete].contains(applicationReadError)
            && expectedPID > 0 && elementPID == expectedPID && frontmostPID == expectedPID
    }
}

/// Injectable side effects keep delivery decisions testable without posting keys
/// into the developer's active application during unit tests.
@MainActor struct DictationDeliveryContext {
    var copy: (String) -> Void
    var targetReadiness: () -> DictationTargetReadiness
    var insertSelection: (String) -> Bool
    var postPaste: () -> Bool
    var insertionIsVerified: () -> Bool
    var targetIsFocused: () -> Bool
    var pressEnter: () -> Bool
    var waitForTarget: () async -> Void
    var isCancelled: () -> Bool = { false }
    var clipboardIsCurrent: () -> Bool = { true }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var insertionStrategy: DictationInsertionStrategy = .accessibilityThenKeyboard
    var insertionAllowsReturn: () -> Bool = { true }
}

enum DictationTargetReadiness: Equatable {
    case ready, temporarilyUnavailable, changed, unavailable
}

/// A missing observation is not evidence that the user edited their text.
/// Keep AX failures until validation, rather than flattening all of them to nil.
enum DictationAccessibilityRead<Value> {
    case value(Value)
    case temporarilyUnavailable
    case unavailable

    static func failure(_ error: AXError) -> Self {
        switch error {
        case .cannotComplete, .noValue: .temporarilyUnavailable
        default: .unavailable
        }
    }
}

enum DictationTargetValidation {
    static func readiness(
        focus: DictationTargetReadiness,
        originalValue: String?, currentValue: DictationAccessibilityRead<String>,
        originalRange: CFRange?, currentRange: DictationAccessibilityRead<CFRange>,
        placeholderIsUnchanged: Bool = true
    ) -> DictationTargetReadiness {
        let states: [DictationTargetReadiness] = [
            focus,
            placeholderIsUnchanged ? .ready : .changed,
            compare(originalValue, currentValue, equal: ==),
            compare(originalRange, currentRange) {
                $0.location == $1.location && $0.length == $1.length
            },
        ]
        // A confirmed mismatch wins even if a different attribute is unreadable.
        if states.contains(.changed) { return .changed }
        if states.contains(.unavailable) { return .unavailable }
        if states.contains(.temporarilyUnavailable) { return .temporarilyUnavailable }
        return .ready
    }

    private static func compare<Value>(
        _ original: Value?, _ current: DictationAccessibilityRead<Value>,
        equal: (Value, Value) -> Bool
    ) -> DictationTargetReadiness {
        // Preserve capture-time capability: do not invent an original value.
        guard let original else { return .ready }
        switch current {
        case .value(let value): return equal(original, value) ? .ready : .changed
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .unavailable: return .unavailable
        }
    }
}

enum DictationDelivery {
    static func hasUsableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor static func deliver(
        _ text: String, pressEnter: Bool = false, context: DictationDeliveryContext
    ) async -> DictationDeliveryResult {
        guard hasUsableText(text) else { return .empty }
        context.copy(text)
        guard await waitForOriginalTarget(context) else { return copyFallback(context) }

        // Pick the route before mutation. Never follow an accepted AX write
        // with a keyboard paste: unreadable success could otherwise duplicate.
        if context.insertionStrategy == .keyboardOnly || !context.insertSelection(text) {
            guard await waitForOriginalTarget(context) else { return copyFallback(context) }
            // A copy in another app during the read-only wait must not become
            // the text we paste. Do not overwrite that newer clipboard either.
            guard context.clipboardIsCurrent() else { return .clipboardChanged }
            guard !context.isCancelled(), context.postPaste() else {
                return .copiedToClipboard
            }
        }
        for attempt in 0...6 {
            if context.insertionIsVerified() {
                let enterSent = pressEnter && context.insertionAllowsReturn() && !context.isCancelled()
                    && context.targetIsFocused() && context.pressEnter()
                return .verified(enterSent: enterSent)
            }
            if attempt < 6 { await context.waitForTarget() }
        }
        // Sending Cmd-V is not evidence of insertion. Do not send Return or
        // automatically retry an ambiguous result (which could duplicate text).
        return .unverified
    }

    @MainActor private static func copyFallback(_ context: DictationDeliveryContext) -> DictationDeliveryResult {
        context.clipboardIsCurrent() ? .copiedToClipboard : .clipboardChanged
    }

    @MainActor private static func waitForOriginalTarget(_ context: DictationDeliveryContext) async -> Bool {
        // Include synchronous AX read time, not just the sleeps, in the retry
        // budget. A stalled application must not trigger six more slow reads.
        let deadline = context.uptime() + 1.0
        for attempt in 0...6 {
            guard !context.isCancelled(), context.uptime() <= deadline else { return false }
            let readiness = context.targetReadiness()
            guard context.uptime() <= deadline else { return false }
            switch readiness {
            case .ready: return !context.isCancelled()
            case .changed, .unavailable: return false
            case .temporarilyUnavailable:
                guard attempt < 6 else { return false }
                await context.waitForTarget()
            }
        }
        return false
    }

    static func replacing(_ value: String, range: CFRange, with text: String) -> String? {
        guard range.location >= 0, range.length >= 0,
              range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location else { return nil }
        let start16 = value.utf16.index(value.utf16.startIndex, offsetBy: range.location)
        let end16 = value.utf16.index(start16, offsetBy: range.length)
        guard let start = String.Index(start16, within: value),
              let end = String.Index(end16, within: value) else { return nil }
        return value.replacingCharacters(in: start..<end, with: text)
    }
}

@MainActor final class DictationPasteTarget {
    fileprivate let application: NSRunningApplication
    fileprivate let element: AXUIElement
    fileprivate let range: CFRange?
    fileprivate let value: String?
    fileprivate let allowActivation: Bool
    fileprivate let isCodexPlaceholder: Bool

    fileprivate init(application: NSRunningApplication, element: AXUIElement,
                     range: CFRange?, value: String?, allowActivation: Bool,
                     isCodexPlaceholder: Bool) {
        self.application = application
        self.element = element
        self.range = range
        self.value = value
        self.allowActivation = allowActivation
        self.isCodexPlaceholder = isCodexPlaceholder
    }
}

enum PasteboardService {
    // Delivery metadata only: never log text, selections, field values, or
    // destination titles. A dispatched request is not proof of insertion.
    private static let deliveryLogger = Logger(subsystem: "studio.lunr.openbridge", category: "DictationDelivery")
    private static let copyVirtualKey: CGKeyCode = 8
    private static let pasteVirtualKey: CGKeyCode = 9
    private static let returnVirtualKey: CGKeyCode = 36
    private static let focusedReadTimeout: Float = 0.25
    @MainActor private static var accessibilityPreparation = DictationAccessibilityPreparationTracker()

    @MainActor static func prepareDictationAccessibility(for application: NSRunningApplication) {
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              accessibilityPreparation.shouldPrepare(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier,
                launchDate: application.launchDate, isTrusted: AXIsProcessTrusted()
              ) else { return }
        // Electron documents this app-scoped switch for assistive technology.
        // It does not request/change macOS permissions. Do it at activation so
        // the tree can settle before recording, never while delivering text.
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, focusedReadTimeout)
        let result = DictationAccessibilityPreparation.prepare(bundleIdentifier: application.bundleIdentifier) { attribute in
            let response = AXUIElementSetAttributeValue(applicationElement, attribute as CFString, kCFBooleanTrue)
            deliveryLogger.notice("Editor accessibility setup attribute: \(attribute, privacy: .public); target PID: \(application.processIdentifier); result: \(response.rawValue)")
            return response
        }
        accessibilityPreparation.recordResult(
            result, processIdentifier: application.processIdentifier, launchDate: application.launchDate
        )
        deliveryLogger.notice("Editor accessibility preparation result: \(result.rawValue); Codex: \(application.bundleIdentifier == "com.openai.codex")")
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor static func captureDictationTarget(
        application: NSRunningApplication?, allowActivation: Bool = false
    ) -> DictationPasteTarget? {
        guard AXIsProcessTrusted() else {
            deliveryLogger.notice("Target capture rejected: accessibility not trusted")
            return nil
        }
        guard let application, !application.isTerminated,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            deliveryLogger.notice("Target capture rejected: destination app unavailable")
            return nil
        }
        let element: AXUIElement
        switch readFocusedElement(in: application) {
        case .value(let focused): element = focused
        case .temporarilyUnavailable:
            deliveryLogger.notice("Target capture rejected: focused element temporarily unreadable")
            return nil
        case .unavailable:
            deliveryLogger.notice("Target capture rejected: focused element unavailable")
            return nil
        }
        guard stringAttribute(kAXSubroleAttribute, on: element) != kAXSecureTextFieldSubrole else {
            deliveryLogger.notice("Target capture rejected: protected field")
            return nil
        }
        let range = selectedTextRange(for: element)
        let role = stringAttribute(kAXRoleAttribute, on: element) ?? ""
        guard range != nil || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            deliveryLogger.notice("Target capture rejected: no text role or selection range")
            return nil
        }
        deliveryLogger.notice("Target captured; selection range available: \(range != nil)")
        let value = stringAttribute(kAXValueAttribute, on: element)
        let isPlaceholder = isCodexPlaceholderEditor(
            element, bundleIdentifier: application.bundleIdentifier, value: value, range: range)
        deliveryLogger.notice("Captured Codex empty-composer marker: \(isPlaceholder)")
        return DictationPasteTarget(
            application: application, element: element, range: range,
            value: value, allowActivation: allowActivation, isCodexPlaceholder: isPlaceholder
        )
    }

    /// Read only the captured field and its sole direct paragraph. Any missing
    /// attribute or changed editor structure leaves ordinary verification intact.
    private static func isCodexPlaceholderEditor(
        _ editor: AXUIElement, bundleIdentifier: String?, value: String?, range: CFRange?
    ) -> Bool {
        guard bundleIdentifier == "com.openai.codex", let value,
              DictationDelivery.hasUsableText(value),
              range?.location == 0, range?.length == 0 else { return false }
        var rawClasses: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, "AXDOMClassList" as CFString, &rawClasses) == .success,
              let editorClasses = rawClasses as? [String],
              editorClasses.contains("ProseMirror") else { return false }
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement], children.count == 1 else { return false }
        var rawParagraphClasses: CFTypeRef?
        guard AXUIElementCopyAttributeValue(children[0], "AXDOMClassList" as CFString, &rawParagraphClasses) == .success,
              let paragraphClasses = rawParagraphClasses as? [String] else { return false }
        return DictationCodexPlaceholder.matches(
            bundleIdentifier: bundleIdentifier, value: value, range: range,
            editorClasses: editorClasses, childCount: children.count, paragraphClasses: paragraphClasses)
    }

    @MainActor static func deliverDictation(
        _ text: String, target: DictationPasteTarget?, pressEnter: Bool = false,
        isCancelled: @escaping () -> Bool = { false }
    ) async -> DictationDeliveryResult {
        guard DictationDelivery.hasUsableText(text) else { return .empty }
        guard let target else {
            deliveryLogger.notice("Automatic delivery unavailable: no captured target")
            copy(text)
            return .copiedToClipboard
        }
        deliveryLogger.notice("Automatic delivery started; OpenBridge owns key window: \(NSApp.keyWindow != nil)")
        if target.allowActivation,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            activate(target.application)
            try? await Task.sleep(for: .milliseconds(250))
        }
        let expected = target.value.flatMap { value in
            target.range.flatMap { DictationDelivery.replacing(value, range: $0, with: text) }
        }
        var clipboardChangeCount: Int?
        var lastVerificationValue: String?
        var verification: DictationInsertionVerification = .unverified
        let context = DictationDeliveryContext(
            copy: { text in
                copy(text)
                let changeCount = NSPasteboard.general.changeCount
                if NSPasteboard.general.string(forType: .string) == text,
                   NSPasteboard.general.changeCount == changeCount {
                    clipboardChangeCount = changeCount
                }
            },
            targetReadiness: {
                let focus = dictationTargetFocusReadiness(target)
                guard focus != .changed, focus != .unavailable else { return focus }
                return DictationTargetValidation.readiness(
                    focus: focus,
                    originalValue: target.value,
                    currentValue: readStringAttribute(kAXValueAttribute, on: target.element),
                    originalRange: target.range,
                    currentRange: readSelectedTextRange(for: target.element),
                    placeholderIsUnchanged: !target.isCodexPlaceholder || isCodexPlaceholderEditor(
                        target.element, bundleIdentifier: target.application.bundleIdentifier,
                        value: target.value, range: target.range)
                )
            },
            insertSelection: { replacement in
                // AXSelectedText preserves rich text outside the selection.
                // Never replace the whole field via AXValue as a fallback.
                guard expected != nil else { return false }
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
                      settable.boolValue else { return false }
                let accepted = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success
                deliveryLogger.notice("Selected-text request accepted: \(accepted)")
                return accepted
            },
            postPaste: {
                let posted = postKeyboardShortcut(virtualKey: pasteVirtualKey, to: target.application)
                deliveryLogger.notice("Keyboard paste dispatched: \(posted)")
                return posted
            },
            insertionIsVerified: {
                guard let expected, expected != target.value else { return false }
                lastVerificationValue = stringAttribute(kAXValueAttribute, on: target.element)
                verification = DictationInsertionVerification.result(
                    original: target.value, expected: expected, actual: lastVerificationValue,
                    bundleIdentifier: target.application.bundleIdentifier,
                    deliveredText: text, capturedCodexPlaceholder: target.isCodexPlaceholder
                )
                return verification.isVerified
            },
            targetIsFocused: { dictationTargetIsFocused(target) },
            pressEnter: { postKey(virtualKey: returnVirtualKey, to: target.application) },
            waitForTarget: { try? await Task.sleep(for: .milliseconds(150)) },
            isCancelled: isCancelled,
            clipboardIsCurrent: {
                clipboardChangeCount == NSPasteboard.general.changeCount
            },
            insertionStrategy: .forApplication(bundleIdentifier: target.application.bundleIdentifier),
            insertionAllowsReturn: { verification.allowsReturn }
        )
        deliveryLogger.notice("Keyboard-only strategy selected: \(context.insertionStrategy == .keyboardOnly)")
        let result = await DictationDelivery.deliver(text, pressEnter: pressEnter, context: context)
        switch result {
        case .verified:
            deliveryLogger.notice("Automatic delivery verified; Chrome terminal newline equivalence: \(verification == .chromeTerminalNewline); Codex empty composer: \(verification == .codexEmptyComposer)")
        case .unverified:
            deliveryLogger.notice("Automatic delivery unverified; no retry")
            deliveryLogger.notice("Readback metadata: original available=\(target.value != nil); expected available=\(expected != nil); actual available=\(lastVerificationValue != nil); original UTF16=\(target.value?.utf16.count ?? -1); expected UTF16=\(expected?.utf16.count ?? -1); actual UTF16=\(lastVerificationValue?.utf16.count ?? -1)")
            if let expected, let actual = lastVerificationValue {
                deliveryLogger.notice("Readback content comparison: actual matches delivered text=\(actual == text)")
                let lineEndingsMatch = actual.replacingOccurrences(of: "\r\n", with: "\n") == expected.replacingOccurrences(of: "\r\n", with: "\n")
                let nonbreakingSpacesMatch = actual.replacingOccurrences(of: "\u{00A0}", with: " ") == expected.replacingOccurrences(of: "\u{00A0}", with: " ")
                let terminalNewlineMatch = actual == expected + "\n" || expected == actual + "\n"
                deliveryLogger.notice("Readback comparisons: unchanged=\(actual == target.value); line endings only=\(lineEndingsMatch); nonbreaking spaces only=\(nonbreakingSpacesMatch); single terminal newline only=\(terminalNewlineMatch)")
            }
        case .copiedToClipboard: deliveryLogger.notice("Automatic delivery stopped before insertion")
        case .clipboardChanged: deliveryLogger.notice("Automatic delivery stopped: clipboard changed")
        case .empty: deliveryLogger.notice("Automatic delivery skipped: empty output")
        }
        return result
    }

    @MainActor private static func dictationTargetIsFocused(_ target: DictationPasteTarget) -> Bool {
        dictationTargetFocusReadiness(target) == .ready
    }

    @MainActor private static func dictationTargetFocusReadiness(_ target: DictationPasteTarget) -> DictationTargetReadiness {
        guard AXIsProcessTrusted(), !target.application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier else { return .changed }
        switch readFocusedElement(in: target.application) {
        case .value(let focused): return CFEqual(focused, target.element) ? .ready : .changed
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .unavailable: return .unavailable
        }
    }

    @MainActor private static func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        if case .value(let value) = readFocusedElement(in: application) { return value }
        return nil
    }

    @MainActor private static func readFocusedElement(in application: NSRunningApplication) -> DictationAccessibilityRead<AXUIElement> {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, focusedReadTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(applicationElement,
                                                  kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success else {
            deliveryLogger.notice("Focused-element read failed; scope application; error: \(result.rawValue)")
            guard result == .noValue || result == .cannotComplete else { return .failure(result) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                return .unavailable
            }
            // Read the actual system focus, not an arbitrary editable child.
            // Both its owner and the still-foreground app must match the target.
            let systemElement = AXUIElementCreateSystemWide()
            var systemValue: CFTypeRef?
            let systemResult: AXError = {
                // A system-wide timeout is process-global. Restore the default
                // before any later read/write, including unrelated Command Mode.
                AXUIElementSetMessagingTimeout(systemElement, focusedReadTimeout)
                defer { AXUIElementSetMessagingTimeout(systemElement, 0) }
                return AXUIElementCopyAttributeValue(
                    systemElement, kAXFocusedUIElementAttribute as CFString, &systemValue
                )
            }()
            guard systemResult == .success else {
                deliveryLogger.notice("Focused-element read failed; scope system; error: \(systemResult.rawValue)")
                return .failure(systemResult)
            }
            guard let systemValue, CFGetTypeID(systemValue) == AXUIElementGetTypeID() else { return .unavailable }
            let element = systemValue as! AXUIElement
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success,
                  DictationFocusFallbackPolicy.allowsSystemWideFallback(
                    applicationReadError: result, expectedPID: application.processIdentifier,
                    elementPID: elementPID,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
                  ) else { return .unavailable }
            deliveryLogger.notice("Focused-element read recovered through matching system focus")
            return .value(element)
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        return .value(value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        if case .value(let value) = readStringAttribute(attribute, on: element) { return value }
        return nil
    }

    private static func readStringAttribute(_ attribute: String, on element: AXUIElement) -> DictationAccessibilityRead<String> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return .failure(result) }
        guard let value = value as? String else { return .unavailable }
        return .value(value)
    }

    @discardableResult
    static func paste(
        _ text: String,
        activating application: NSRunningApplication? = nil,
        restoring snapshot: PasteboardSnapshot? = nil
    ) -> Bool {
        copy(text)

        if let application, !application.isTerminated {
            activate(application)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                _ = postKeyboardShortcut(virtualKey: pasteVirtualKey)
            }
            if let snapshot {
                restore(snapshot, after: 2.0)
            }
            return true
        }

        let didPost = postKeyboardShortcut(virtualKey: pasteVirtualKey)
        if didPost, let snapshot {
            restore(snapshot, after: 0.8)
        }
        return didPost
    }

    static func pressEnter(
        after seconds: TimeInterval = 0.45,
        activating application: NSRunningApplication? = nil
    ) {
        if let application, !application.isTerminated {
            activate(application)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            _ = postKey(virtualKey: returnVirtualKey, to: application)
        }
    }

    static func replaceSelectedText(
        _ text: String,
        activating application: NSRunningApplication?,
        accessibilityReference: AccessibilitySelectionReference?
    ) async -> SelectedTextReplacementResult {
        if let application, !application.isTerminated {
            activate(application)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        if let accessibilityReference,
           replaceSelectionWithAccessibility(text, reference: accessibilityReference) {
            return .replaced
        }

        if replaceFocusedSelectionWithAccessibility(text) {
            return .replaced
        }

        copy(text)
        if let application, !application.isTerminated {
            activate(application)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        let didPost = postKeyboardShortcut(virtualKey: pasteVirtualKey)
        if didPost {
            return .pasteRequested
        }
        return .copiedToClipboard
    }

    static func captureSelectedText(activating application: NSRunningApplication?) async -> SelectedTextCaptureResult {
        let originalSnapshot = snapshot()

        if let application, !application.isTerminated {
            activate(application)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let accessibilitySnapshot = accessibilitySelectionSnapshot()
        if let selectedText = accessibilitySnapshot?.selectedText,
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .captured(
                text: selectedText,
                accessibilityReference: accessibilitySnapshot?.reference
            )
        }

        let sentinel = "openbridge-selection-\(UUID().uuidString)"
        copy(sentinel)
        let didPostCopy = postKeyboardShortcut(virtualKey: copyVirtualKey, to: application)
        guard didPostCopy else {
            restore(originalSnapshot)
            return .failed
        }

        try? await Task.sleep(nanoseconds: 220_000_000)

        let copiedText = NSPasteboard.general.string(forType: .string) ?? ""
        restore(originalSnapshot)

        let selectedText = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty, copiedText != sentinel else {
            return .noSelection
        }

        return .captured(
            text: copiedText,
            accessibilityReference: accessibilitySnapshot?.reference
        )
    }

    static func snapshot() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items: [PasteboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            let values = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }
            return PasteboardItemSnapshot(values: values)
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    static func restore(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { itemSnapshot in
            let item = NSPasteboardItem()
            for value in itemSnapshot.values {
                item.setData(value.data, forType: value.type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func restore(_ snapshot: PasteboardSnapshot, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            restore(snapshot)
        }
    }

    private static func activate(_ application: NSRunningApplication) {
        application.activate(options: [.activateAllWindows])
    }

    private static func postKeyboardShortcut(
        virtualKey: CGKeyCode,
        to application: NSRunningApplication? = nil
    ) -> Bool {
        postKey(virtualKey: virtualKey, flags: .maskCommand, to: application)
    }

    private static func postKey(
        virtualKey: CGKeyCode,
        flags: CGEventFlags = [],
        to application: NSRunningApplication? = nil
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }

        down.flags = flags
        up.flags = flags

        if let application, !application.isTerminated {
            down.postToPid(application.processIdentifier)
            up.postToPid(application.processIdentifier)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func accessibilitySelectionSnapshot() -> AccessibilitySelectionSnapshot? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedError == .success,
              let focusedElement = focusedElementValue else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        let reference = AccessibilitySelectionReference(
            element: element,
            selectedRange: selectedTextRange(for: element)
        )

        var selectedTextValue: CFTypeRef?
        let selectedTextError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        return AccessibilitySelectionSnapshot(
            reference: reference,
            selectedText: selectedTextError == .success ? selectedTextValue as? String : nil
        )
    }

    private static func selectedTextRange(for element: AXUIElement) -> CFRange? {
        if case .value(let value) = readSelectedTextRange(for: element) { return value }
        return nil
    }

    private static func readSelectedTextRange(for element: AXUIElement) -> DictationAccessibilityRead<CFRange> {
        var selectedRangeValue: CFTypeRef?
        let selectedRangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard selectedRangeError == .success else { return .failure(selectedRangeError) }
        guard let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return .unavailable
        }

        let axValue = selectedRangeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return .unavailable
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return .unavailable
        }
        return .value(range)
    }

    private static func replaceFocusedSelectionWithAccessibility(_ replacement: String) -> Bool {
        guard let snapshot = accessibilitySelectionSnapshot() else {
            return false
        }
        return replaceSelectionWithAccessibility(replacement, reference: snapshot.reference)
    }

    private static func replaceSelectionWithAccessibility(
        _ replacement: String,
        reference: AccessibilitySelectionReference
    ) -> Bool {
        if let selectedRange = reference.selectedRange {
            _ = setSelectedTextRange(selectedRange, on: reference.element)
        }

        if replaceSelectedTextAttribute(replacement, on: reference.element) {
            return true
        }

        if let selectedRange = reference.selectedRange,
           replaceValueAttribute(replacement, on: reference.element, selectedRange: selectedRange) {
            return true
        }

        return false
    }

    private static func replaceSelectedTextAttribute(_ replacement: String, on element: AXUIElement) -> Bool {
        var selectedTextValue: CFTypeRef?
        let selectedTextError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )
        guard selectedTextError == .success,
              let selectedText = selectedTextValue as? String,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let replaceError = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )
        return replaceError == .success
    }

    private static func replaceValueAttribute(
        _ replacement: String,
        on element: AXUIElement,
        selectedRange: CFRange
    ) -> Bool {
        var currentValueRef: CFTypeRef?
        let currentValueError = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValueRef
        )
        guard currentValueError == .success,
              let currentValue = currentValueRef as? String,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location + selectedRange.length <= currentValue.utf16.count else {
            return false
        }

        let start = String.Index(utf16Offset: selectedRange.location, in: currentValue)
        let end = String.Index(utf16Offset: selectedRange.location + selectedRange.length, in: currentValue)
        let updatedValue = String(currentValue[..<start]) + replacement + String(currentValue[end...])

        let valueError = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        )
        guard valueError == .success else {
            return false
        }

        let cursorRange = CFRange(location: selectedRange.location + replacement.utf16.count, length: 0)
        _ = setSelectedTextRange(cursorRange, on: element)
        return true
    }

    private static func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return false
        }

        let rangeError = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        return rangeError == .success
    }
}
