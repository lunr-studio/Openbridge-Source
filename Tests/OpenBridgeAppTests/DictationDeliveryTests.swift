import Foundation
import ApplicationServices
import Testing
@testable import OpenBridgeApp

@Suite struct DictationDeliveryWiringTests {
    private func appSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeApp/AppState.swift"), encoding: .utf8)
    }

    // Wiring guards supplement the behavioral delivery tests and native QA.
    @Test func normalDictationDoesNotUseUntargetedFireAndForgetPaste() throws {
        let source = try appSource()
        #expect(!source.contains("PasteboardService.paste(pastedText)"))
        #expect(source.contains("target: dictationPasteTarget"))
    }

    @Test func emptyOutputIsRejectedBeforeLastTranscriptAndHistoryAreChanged() throws {
        let source = try appSource()
        let stop = try #require(source.range(of: "private func stopAndTranscribe()"))
        let processing = String(source[stop.lowerBound...])
        let validation = processing.range(of: "guard DictationDelivery.hasUsableText(pastedText)")
        let remember = try #require(processing.range(of: "rememberLastTranscript(pastedText"))
        #expect(validation != nil)
        if let validation { #expect(validation.lowerBound < remember.lowerBound) }
    }

    @Test func historyIsSavedBeforeDeliveryAndItsFailureIsNotHidden() throws {
        let source = try appSource()
        let stop = try #require(source.range(of: "private func stopAndTranscribe()"))
        let processing = String(source[stop.lowerBound...])
        let save = try #require(processing.range(of: "let savedToHistory = saveSuccessfulDictation("))
        let delivery = try #require(processing.range(of: "let delivery = await PasteboardService.deliverDictation("))
        #expect(save.lowerBound < delivery.lowerBound)
        #expect(processing.contains("showDictationDeliveryResult(delivery, deliveredText: pastedText, historyFailure: historyFailure)"))
    }

    @Test func rememberingThePasteTargetProactivelyPreparesEditorAccessibility() throws {
        let source = try appSource()
        let start = try #require(source.range(of: "private func rememberPasteTargetApplication(_ application: NSRunningApplication)"))
        let following = source[start.lowerBound...]
        let end = try #require(following.range(of: "private func throwIfProcessingCancelled()"))
        let tracking = following[..<end.lowerBound]
        #expect(tracking.contains("PasteboardService.prepareDictationAccessibility(for: application)"))
    }

    @Test func everyNewFlowBarPhaseResetsRecoveryToneBeforePresentation() throws {
        let source = try appSource()
        #expect(source.contains("var flowBarRecoveryTone: DictationRecoveryTone = .attention"))
        let start = try #require(source.range(of: "private func setFlowBarPhase(_ phase: FlowBarPhase)"))
        let following = source[start.lowerBound...]
        let end = try #require(following.range(of: "private func showTransientFlowBar("))
        let transition = following[..<end.lowerBound]
        let reset = try #require(transition.range(of: "flowBarRecoveryTone = .attention"))
        let presentation = try #require(transition.range(of: "flowBarPhase = phase"))
        #expect(reset.lowerBound < presentation.lowerBound)
        #expect(transition.contains("flowBarRecoveryText = nil"))
    }

    @Test func deliveryRecoveryUsesTonePolicyAfterThePhaseResetAndKeepsCurrentText() throws {
        let source = try appSource()
        let start = try #require(source.range(of: "private func showDictationDeliveryResult("))
        let following = source[start.lowerBound...]
        let end = try #require(following.range(of: "func copyFlowBarRecoveryText()"))
        let recovery = following[..<end.lowerBound]
        let phase = try #require(recovery.range(of: "setFlowBarPhase(.error(statusMessage))"))
        let tone = try #require(recovery.range(of: "flowBarRecoveryTone = DictationFlowRecovery.tone(for: result, historyFailure: historyFailure)"))
        #expect(phase.lowerBound < tone.lowerBound)
        #expect(recovery.contains("DictationFlowRecovery.text(for: result, deliveredText: deliveredText)"))
        #expect(recovery.contains("flowBarRecoveryText = recoveryText"))
    }
}

@Suite struct DictationRecoveryPresentationTests {
    @Test func unverifiedPasteWithoutHistoryFailureUsesNeutralPresentation() {
        let tone = DictationFlowRecovery.tone(for: .unverified, historyFailure: nil)
        #expect(tone == .unconfirmed)
        #expect(tone.title == "Check your text")
        #expect(tone.iconName == "doc.text")
    }

    @Test func copyFallbackAndChangedClipboardAlwaysNeedAttention() {
        for result: DictationDeliveryResult in [.copiedToClipboard, .clipboardChanged] {
            for failure: String? in [nil, "History could not be saved."] {
                let tone = DictationFlowRecovery.tone(for: result, historyFailure: failure)
                #expect(tone == .attention)
                #expect(tone.title == "Your text is ready")
                #expect(tone.iconName == "exclamationmark.triangle")
            }
        }
    }

    @Test func historyFailureNeverReceivesNeutralPresentation() {
        let results: [DictationDeliveryResult] = [
            .empty, .verified(enterSent: false), .verified(enterSent: true),
            .unverified, .copiedToClipboard, .clipboardChanged
        ]
        for result in results {
            // Presence of a History failure still matters if its message is empty.
            for failure in ["History could not be saved.", ""] {
                #expect(DictationFlowRecovery.tone(for: result, historyFailure: failure) == .attention)
            }
        }
    }

    @Test func emptyAndVerifiedOutcomesNeverOptIntoUnconfirmedRecovery() {
        for result: DictationDeliveryResult in [.empty, .verified(enterSent: false), .verified(enterSent: true)] {
            #expect(DictationFlowRecovery.tone(for: result, historyFailure: nil) == .attention)
            #expect(DictationFlowRecovery.text(for: result, deliveredText: "Current words") == nil)
        }
    }

    @Test func neutralAndAttentionRecoveryRetainTheExactCurrentText() {
        let currentText = "  Current words 😀\nSecond line.  "
        for result: DictationDeliveryResult in [.unverified, .copiedToClipboard, .clipboardChanged] {
            #expect(DictationFlowRecovery.text(for: result, deliveredText: currentText) == currentText)
            for unavailableText: String? in [nil, "", "  \n\t"] {
                #expect(DictationFlowRecovery.text(for: result, deliveredText: unavailableText) == nil)
            }
        }
    }
}

@Suite struct DictationInsertionVerificationTests {
    @Test func codexEmptyComposerConfirmsWholeDeliveredTextWithoutReturn() {
        for prompt in ["Do anything…", "Écrivez ici…", "你好 👋"] {
            let text = "Hello 😀\nSecond line."
            let result = DictationInsertionVerification.result(
                original: prompt, expected: text + prompt, actual: text,
                bundleIdentifier: "com.openai.codex", deliveredText: text,
                capturedCodexPlaceholder: true)
            #expect(result == .codexEmptyComposer)
            #expect(result.isVerified)
            #expect(!result.allowsReturn)
        }
    }

    @Test func codexProofRequiresMarkerAndCompleteUnalteredText() {
        let text = "Hello 😀\nSecond line."
        for actual: String? in [nil, "", "Hello 😀", text + "extra", text + "\n", "Do anything…"] {
            #expect(!DictationInsertionVerification.result(
                original: "Do anything…", expected: text + "Do anything…", actual: actual,
                bundleIdentifier: "com.openai.codex", deliveredText: text,
                capturedCodexPlaceholder: true).isVerified)
        }
        for bundle: String? in [nil, "com.openai.chat", "com.openai.codex.other", "com.google.Chrome"] {
            #expect(!DictationInsertionVerification.result(
                original: "Prompt", expected: text + "Prompt", actual: text,
                bundleIdentifier: bundle, deliveredText: text,
                capturedCodexPlaceholder: true).isVerified)
        }
        #expect(!DictationInsertionVerification.result(
            original: "Existing draft", expected: text + "Existing draft", actual: text,
            bundleIdentifier: "com.openai.codex", deliveredText: text).isVerified)
        for expected: String? in [nil, "different", "Prompt" + text] {
            #expect(!DictationInsertionVerification.result(
                original: "Prompt", expected: expected, actual: text,
                bundleIdentifier: "com.openai.codex", deliveredText: text,
                capturedCodexPlaceholder: true).isVerified)
        }
        for delivered: String? in [nil, "", " ", "wrong"] {
            #expect(!DictationInsertionVerification.result(
                original: "Prompt", expected: "HelloPrompt", actual: "Hello",
                bundleIdentifier: "com.openai.codex", deliveredText: delivered,
                capturedCodexPlaceholder: true).isVerified)
        }
        for original: String? in [nil, "", " "] {
            #expect(!DictationInsertionVerification.result(
                original: original, expected: text + (original ?? ""), actual: text,
                bundleIdentifier: "com.openai.codex", deliveredText: text,
                capturedCodexPlaceholder: true).isVerified)
        }
        // A retained generated prompt is not proof of document content or
        // permission to submit, even if the raw expected value matches.
        #expect(!DictationInsertionVerification.result(
            original: "Prompt", expected: text + "Prompt", actual: text + "Prompt",
            bundleIdentifier: "com.openai.codex", deliveredText: text,
            capturedCodexPlaceholder: true).isVerified)
    }

    @Test func placeholderEvidenceRequiresExactEditorStructureAndEmptySelection() {
        func matches(bundle: String? = "com.openai.codex", value: String? = "Any prompt",
                     range: CFRange? = CFRange(location: 0, length: 0),
                     editor: [String]? = ["ProseMirror"], children: Int? = 1,
                     paragraph: [String]? = ["placeholder"]) -> Bool {
            DictationCodexPlaceholder.matches(bundleIdentifier: bundle, value: value, range: range,
                editorClasses: editor, childCount: children, paragraphClasses: paragraph)
        }
        #expect(matches())
        #expect(!matches(bundle: "com.openai.codex.other"))
        #expect(!matches(bundle: nil))
        #expect(!matches(value: nil))
        #expect(!matches(value: ""))
        #expect(!matches(range: nil))
        #expect(!matches(range: CFRange(location: 1, length: 0)))
        #expect(!matches(range: CFRange(location: 0, length: 1)))
        #expect(!matches(editor: nil))
        #expect(!matches(editor: ["prosemirror"]))
        for count: Int? in [nil, 0, 2] { #expect(!matches(children: count)) }
        #expect(!matches(paragraph: nil))
        #expect(!matches(paragraph: []))
        #expect(!matches(paragraph: ["prosemirror-placeholder"]))
        // Literal placeholder-looking user text has no empty-document marker.
        #expect(!matches(value: "Do anything…", paragraph: []))
    }

    @Test func changedExactMatchesVerifyAndAllowReturnInEveryApplication() {
        let expected = "Hello 😀\nNew words."
        for bundle: String? in [nil, "com.google.Chrome", "com.google.Chrome.canary", "com.evernote.Evernote", "com.apple.TextEdit"] {
            for original in ["", "Hello 😀"] {
                let result = DictationInsertionVerification.result(original: original, expected: expected, actual: expected, bundleIdentifier: bundle)
                #expect(result == .exact)
                #expect(result.isVerified)
                #expect(result.allowsReturn)
            }
        }
    }

    @Test func chromeAcceptsOneMissingExpectedTerminalLineFeed() {
        let result = DictationInsertionVerification.result(original: "Hello", expected: "Hello new words.\n", actual: "Hello new words.", bundleIdentifier: "com.google.Chrome")
        #expect(result == .chromeTerminalNewline)
        #expect(result.isVerified)
        #expect(!result.allowsReturn)
    }

    @Test func missingOrUnchangedObservationsNeverVerify() {
        let observations: [(String?, String?, String?)] = [
            (nil, "New words", "New words"), ("Original", nil, "New words"),
            ("Original", "New words", nil), (nil, nil, nil),
            ("Original", "New words", "Original"), ("Same", "Same", "Same"),
            ("Same", "Same\n", "Same"), ("Same\n", "Same", "Same\n")
        ]
        for (original, expected, actual) in observations {
            let result = DictationInsertionVerification.result(original: original, expected: expected, actual: actual, bundleIdentifier: "com.google.Chrome")
            #expect(result == .unverified)
            #expect(!result.isVerified)
            #expect(!result.allowsReturn)
        }
    }

    @Test func terminalLineFeedToleranceNeverExtendsToOtherApplications() {
        for bundle: String? in [nil, "", "com.apple.TextEdit", "com.apple.Safari", "com.evernote.Evernote", "com.google.Chrome.canary", "com.google.Chrome.unrelated"] {
            for (expected, actual) in [("New words\n", "New words"), ("New words", "New words\n")] {
                let result = DictationInsertionVerification.result(original: "Original", expected: expected, actual: actual, bundleIdentifier: bundle)
                #expect(result == .unverified)
                #expect(!result.isVerified)
                #expect(!result.allowsReturn)
            }
        }
    }

    @Test func chromeRejectsOtherWhitespaceChangesAndIncompleteOrDuplicatedText() {
        let nearMatches = [
            ("Hello brave world", "Hello brave world\n"),
            ("Hello brave world", "Hello brave world\n\n"),
            ("Hello brave world\n\n", "Hello brave world"),
            ("Hello brave world\n\n", "Hello brave world\n"),
            ("Hello brave world", "\nHello brave world"),
            ("Hello brave world", "Hello\nbrave world"),
            ("Hello brave\nworld", "Hello brave world"),
            ("Hello brave world", "Hello brave world "),
            ("Hello brave world", " Hello brave world"),
            ("Hello brave world", "Hello brave\u{00a0}world"),
            ("Hello brave world", "Hello brave world\r\n"),
            ("Hello brave world\n", "Hello brave world\r\n"),
            ("Hello brave world\r", "Hello brave world\r\n"),
            ("Hello brave world\r\n", "Hello brave world\r"),
            ("Hello brave world", "Hello brave worl"),
            ("Hello brave world", "Hello world"),
            ("Hello brave world", "Hello brave worldHello brave world")
        ]
        for (expected, actual) in nearMatches {
            let result = DictationInsertionVerification.result(original: "Original", expected: expected, actual: actual, bundleIdentifier: "com.google.Chrome")
            #expect(result == .unverified)
            #expect(!result.isVerified)
            #expect(!result.allowsReturn)
        }
    }

    @Test func chromeTerminalLineFeedProofPreservesTheEntireUnicodeText() {
        let text = "A😀e\u{301}\n你好 — new words."
        let result = DictationInsertionVerification.result(original: "A😀", expected: text + "\n", actual: text, bundleIdentifier: "com.google.Chrome")
        #expect(result == .chromeTerminalNewline)
        #expect(result.isVerified)
        #expect(!result.allowsReturn)
        let altered = DictationInsertionVerification.result(original: "A😀", expected: text, actual: "Ae\u{301}\n你好 — new words.\n", bundleIdentifier: "com.google.Chrome")
        #expect(altered == .unverified)
    }

    @Test func chromeNeverVerifiesEmptyOrWhitespaceOnlyTextUsingLineFeedTolerance() {
        for actual in ["", " ", "\t ", "\u{00a0}"] {
            let result = DictationInsertionVerification.result(original: "old", expected: actual + "\n", actual: actual, bundleIdentifier: "com.google.Chrome")
            #expect(result == .unverified)
            #expect(!result.isVerified)
            #expect(!result.allowsReturn)
        }
    }

    @Test func onlyExactProofAuthorizesReturn() {
        #expect(DictationInsertionVerification.exact.isVerified)
        #expect(DictationInsertionVerification.exact.allowsReturn)
        #expect(DictationInsertionVerification.chromeTerminalNewline.isVerified)
        #expect(!DictationInsertionVerification.chromeTerminalNewline.allowsReturn)
        #expect(!DictationInsertionVerification.unverified.isVerified)
        #expect(!DictationInsertionVerification.unverified.allowsReturn)
    }
}

@MainActor private final class DeliveryProbe {
    var events: [String] = []
    var unchanged = true
    var temporarilyUnreadable = false
    var unavailable = false
    var clipboardCurrent = true
    var focused = true
    var writable = false
    var posted = true
    var verified = false
    var cancelled = false
    var waits = 0
    var uptime: TimeInterval = 0
    var afterWait: (() -> Void)?
    var afterAXAttempt: (() -> Void)?
    var afterTargetRead: (() -> Void)?
    var afterPaste: (() -> Void)?
    var insertionStrategy: DictationInsertionStrategy = .accessibilityThenKeyboard
    var allowsReturn = true

    var context: DictationDeliveryContext {
        DictationDeliveryContext(
            copy: { _ in self.events.append("copy") },
            targetReadiness: {
                defer { self.afterTargetRead?() }
                if !self.unchanged { return .changed }
                if self.unavailable { return .unavailable }
                return self.temporarilyUnreadable ? .temporarilyUnavailable : .ready
            },
            insertSelection: { _ in
                self.events.append("AX")
                self.afterAXAttempt?()
                return self.writable
            },
            postPaste: { self.events.append("paste"); self.afterPaste?(); return self.posted },
            insertionIsVerified: { self.verified },
            targetIsFocused: { self.focused },
            pressEnter: { self.events.append("enter"); return true },
            waitForTarget: { self.waits += 1; self.uptime += 0.15; self.afterWait?() },
            isCancelled: { self.cancelled },
            clipboardIsCurrent: { self.clipboardCurrent },
            uptime: { self.uptime },
            insertionStrategy: self.insertionStrategy,
            insertionAllowsReturn: { self.allowsReturn }
        )
    }
}

@Suite @MainActor struct DictationDeliveryTests {
    @Test func disappearingPlaceholderStopsPasteEvenWhenRawTextAndCaretMatch() async {
        let range = CFRange(location: 0, length: 0)
        let readiness = DictationTargetValidation.readiness(
            focus: .ready, originalValue: "Do anything…", currentValue: .value("Do anything…"),
            originalRange: range, currentRange: .value(range), placeholderIsUnchanged: false)
        #expect(readiness == .changed)
        let fixture = DeliveryProbe()
        fixture.insertionStrategy = .keyboardOnly
        fixture.unchanged = readiness == .ready
        let result = await DictationDelivery.deliver("Hello", context: fixture.context)
        #expect(result == .copiedToClipboard)
        #expect(fixture.events == ["copy"])
    }

    @Test func codexEmptyComposerProofDeliversOnceAndNeverSubmits() async {
        let fixture = DeliveryProbe()
        let proof = DictationInsertionVerification.result(
            original: "Prompt", expected: "HelloPrompt", actual: "Hello",
            bundleIdentifier: "com.openai.codex", deliveredText: "Hello",
            capturedCodexPlaceholder: true)
        fixture.insertionStrategy = .keyboardOnly
        fixture.verified = proof.isVerified
        fixture.allowsReturn = proof.allowsReturn
        let result = await DictationDelivery.deliver("Hello", pressEnter: true, context: fixture.context)
        #expect(result == .verified(enterSent: false))
        #expect(fixture.events == ["copy", "paste"])
    }
    @Test func preparesOnlyTrustedKnownEvernoteProcessesOncePerLaunch() {
        var tracker = DictationAccessibilityPreparationTracker()
        let launch = Date(timeIntervalSince1970: 1_000)
        let untrusted = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 10, launchDate: launch, isTrusted: false)
        #expect(!untrusted)
        let unrelatedApp = tracker.shouldPrepare(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 10, launchDate: launch, isTrusted: true)
        #expect(!unrelatedApp)
        let similarIdentifier = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote.unrelated", processIdentifier: 10, launchDate: launch, isTrusted: true)
        #expect(!similarIdentifier)
        let missingLaunch = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 10, launchDate: nil, isTrusted: true)
        #expect(!missingLaunch)
        #expect(tracker.trackedProcessCount == 0)
        let firstAttempt = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 10, launchDate: launch, isTrusted: true)
        #expect(firstAttempt)
        let repeatedAttempt = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 10, launchDate: launch, isTrusted: true)
        #expect(!repeatedAttempt)
        // PID reuse represents a new process and must not inherit the old preparation.
        let newLaunch = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 10, launchDate: launch.addingTimeInterval(20), isTrusted: true)
        #expect(newLaunch)
    }

    @Test func preparesCodexAccessibilityOnceForEachTrustedLaunch() {
        var tracker = DictationAccessibilityPreparationTracker()
        let launch = Date(timeIntervalSince1970: 2_000)
        let first = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: true)
        #expect(first)
        let repeatActivation = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: true)
        #expect(!repeatActivation)
        let reusedPID = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch.addingTimeInterval(1), isTrusted: true)
        #expect(reusedPID)
    }

    @Test func codexPreparationNeverExpandsToUntrustedOrSimilarApps() {
        var tracker = DictationAccessibilityPreparationTracker()
        let launch = Date(timeIntervalSince1970: 2_000)
        for bundle: String? in [nil, "com.openai.chat", "com.openai.codex.other", "com.google.Chrome"] {
            let result = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: true)
            #expect(!result)
        }
        let untrusted = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: false)
        #expect(!untrusted)
        let noDate = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: nil, isTrusted: true)
        #expect(!noDate)
        let noPID = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 0, launchDate: launch, isTrusted: true)
        #expect(!noPID)
        #expect(tracker.trackedProcessCount == 0)
    }

    @Test func accessibilityPreparationTrackingIsBounded() {
        var tracker = DictationAccessibilityPreparationTracker(capacity: 2)
        let launch = Date(timeIntervalSince1970: 1_000)
        for pid: Int32 in [10, 11, 12] {
            let firstAttempt = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: pid, launchDate: launch, isTrusted: true)
            #expect(firstAttempt)
        }
        #expect(tracker.trackedProcessCount == 2)
        let retainedProcess = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 12, launchDate: launch, isTrusted: true)
        #expect(!retainedProcess)
        let evictedProcess = tracker.shouldPrepare(bundleIdentifier: "com.evernote.Evernote", processIdentifier: 10, launchDate: launch, isTrusted: true)
        #expect(evictedProcess)
        #expect(tracker.trackedProcessCount == 2)
    }

    @Test func codexUnsupportedManualPreparationUsesChromiumSwitch() {
        var attributes: [String] = []
        let result = DictationAccessibilityPreparation.prepare(bundleIdentifier: "com.openai.codex") { attribute in
            attributes.append(attribute)
            return attribute == "AXManualAccessibility" ? .attributeUnsupported : .success
        }
        #expect(attributes == ["AXManualAccessibility", "AXEnhancedUserInterface"])
        #expect(result == .success)
    }

    @Test func preparationFallbackIsRestrictedToExactCodexUnsupportedResult() {
        for bundle: String? in [nil, "com.evernote.Evernote", "com.openai.codex.other", "com.openai.chat"] {
            var attributes: [String] = []
            let result = DictationAccessibilityPreparation.prepare(bundleIdentifier: bundle) { attribute in
                attributes.append(attribute)
                return .attributeUnsupported
            }
            #expect(attributes == ["AXManualAccessibility"])
            #expect(result == .attributeUnsupported)
        }
        for firstResult in [AXError.success, .cannotComplete, .apiDisabled, .invalidUIElement, .failure, .noValue] {
            var attributes: [String] = []
            let result = DictationAccessibilityPreparation.prepare(bundleIdentifier: "com.openai.codex") { attribute in
                attributes.append(attribute)
                return firstResult
            }
            #expect(attributes == ["AXManualAccessibility"])
            #expect(result == firstResult)
        }
    }

    @Test func chromiumPreparationFailureIsReturnedWithoutFurtherRequests() {
        for fallbackResult in [AXError.cannotComplete, .attributeUnsupported, .apiDisabled] {
            var attributes: [String] = []
            let result = DictationAccessibilityPreparation.prepare(bundleIdentifier: "com.openai.codex") { attribute in
                attributes.append(attribute)
                return attribute == "AXManualAccessibility" ? .attributeUnsupported : fallbackResult
            }
            #expect(attributes == ["AXManualAccessibility", "AXEnhancedUserInterface"])
            #expect(result == fallbackResult)
        }
    }

    @Test func temporaryPreparationFailureCanRetryAfterCooldownThenStopsOnSuccess() {
        for bundle in ["com.openai.codex", "com.evernote.Evernote"] {
            var tracker = DictationAccessibilityPreparationTracker()
            let launch = Date(timeIntervalSince1970: 2_000)
            let firstAttempt = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: true, now: 10)
            #expect(firstAttempt)
            tracker.recordResult(.cannotComplete, processIdentifier: 20, launchDate: launch)
            let tooSoon = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: true, now: 10.9)
            #expect(!tooSoon)
            let untrusted = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: false, now: 11)
            #expect(!untrusted)
            let retry = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: true, now: 11)
            #expect(retry)
            // An admitted request cannot be repeated until its result is recorded.
            let pending = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: true, now: 12)
            #expect(!pending)
            tracker.recordResult(.success, processIdentifier: 20, launchDate: launch)
            let afterSuccess = tracker.shouldPrepare(bundleIdentifier: bundle, processIdentifier: 20, launchDate: launch, isTrusted: true, now: 100)
            #expect(!afterSuccess)
        }
    }

    @Test func preparationFailuresHaveAThreeAttemptLimitPerLaunch() {
        var tracker = DictationAccessibilityPreparationTracker()
        let launch = Date(timeIntervalSince1970: 2_000)
        for attempt in 0..<3 {
            let attemptAllowed = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: true, now: Double(attempt))
            #expect(attemptAllowed)
            tracker.recordResult(.cannotComplete, processIdentifier: 20, launchDate: launch)
        }
        let exhausted = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: true, now: 100)
        #expect(!exhausted)
        let newLaunch = launch.addingTimeInterval(1)
        let newProcess = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: newLaunch, isTrusted: true, now: 101)
        #expect(newProcess)
        // A result for the old PID incarnation cannot unlock the new request.
        tracker.recordResult(.cannotComplete, processIdentifier: 20, launchDate: launch)
        let staleResult = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: newLaunch, isTrusted: true, now: 102)
        #expect(!staleResult)
    }

    @Test func unsupportedAndOtherPreparationResultsNeverLoop() {
        for result in [AXError.success, .attributeUnsupported, .apiDisabled, .notImplemented, .invalidUIElement, .failure, .noValue] {
            var tracker = DictationAccessibilityPreparationTracker()
            let launch = Date(timeIntervalSince1970: 2_000)
            let firstAttempt = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: true, now: 0)
            #expect(firstAttempt)
            tracker.recordResult(result, processIdentifier: 20, launchDate: launch)
            let repeatAttempt = tracker.shouldPrepare(bundleIdentifier: "com.openai.codex", processIdentifier: 20, launchDate: launch, isTrusted: true, now: 100)
            #expect(!repeatAttempt)
        }
    }

    @Test func systemWideFocusFallbackNeverAcceptsAnotherAppOrPermanentFailure() {
        for error in [AXError.noValue, .cannotComplete] {
            #expect(DictationFocusFallbackPolicy.allowsSystemWideFallback(applicationReadError: error, expectedPID: 10, elementPID: 10, frontmostPID: 10))
            #expect(!DictationFocusFallbackPolicy.allowsSystemWideFallback(applicationReadError: error, expectedPID: 10, elementPID: 11, frontmostPID: 10))
            #expect(!DictationFocusFallbackPolicy.allowsSystemWideFallback(applicationReadError: error, expectedPID: 10, elementPID: 10, frontmostPID: 11))
            #expect(!DictationFocusFallbackPolicy.allowsSystemWideFallback(applicationReadError: error, expectedPID: 10, elementPID: nil, frontmostPID: 10))
            #expect(!DictationFocusFallbackPolicy.allowsSystemWideFallback(applicationReadError: error, expectedPID: 10, elementPID: 10, frontmostPID: nil))
        }
        for error in [AXError.success, .apiDisabled, .attributeUnsupported, .notImplemented, .invalidUIElement] {
            #expect(!DictationFocusFallbackPolicy.allowsSystemWideFallback(applicationReadError: error, expectedPID: 10, elementPID: 10, frontmostPID: 10))
        }
    }

    @Test func evernoteUsesOneKeyboardInsertionWithoutAnAXMutation() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .forApplication(bundleIdentifier: "com.evernote.Evernote")
        probe.writable = true
        probe.afterPaste = { probe.verified = true }
        #expect(probe.insertionStrategy == .keyboardOnly)
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "paste"])
    }

    @Test func codexNeverAttemptsAcceptedButIneffectiveAXWrite() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .forApplication(bundleIdentifier: "com.openai.codex")
        probe.writable = true // Build 30 accepted AXSelectedText but left Codex unchanged.
        probe.afterPaste = { probe.verified = true }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "paste"])
    }

    @Test func unverifiedCodexPasteNeverRetriesOrSendsReturn() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .forApplication(bundleIdentifier: "com.openai.codex")
        probe.writable = true
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .unverified)
        #expect(probe.events == ["copy", "paste"])
    }

    @Test func onlyObservedBundlesUseKeyboardFirst() {
        #expect(DictationInsertionStrategy.forApplication(bundleIdentifier: "com.google.Chrome") == .keyboardOnly)
        for identifier in [nil, "", "com.apple.TextEdit", "com.apple.Safari", "com.microsoft.edgemac",
                           "com.google.Chrome.canary", "com.google.Chrome.unrelated",
                           "com.openai.codex.unrelated", "com.openai.chat"] as [String?] {
            #expect(DictationInsertionStrategy.forApplication(bundleIdentifier: identifier) == .accessibilityThenKeyboard)
        }
    }

    @Test func chromeNeverAttemptsAcceptedButIneffectiveAXWrite() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .forApplication(bundleIdentifier: "com.google.Chrome")
        probe.writable = true // Simulate the observed accepted AX no-op.
        probe.afterPaste = { probe.verified = true }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "paste"])
    }

    @Test func unverifiedChromePasteNeverRetriesOrSendsReturn() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .keyboardOnly
        probe.writable = true
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .unverified)
        #expect(probe.events == ["copy", "paste"])
    }

    @Test func chromeRechecksDestinationBeforeOnlyPaste() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .keyboardOnly
        probe.afterTargetRead = { probe.unchanged = false }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
    }

    @Test func chromeKeepsClipboardAndCancellationGuards() async {
        for stop in ["clipboard", "cancel", "target"] {
            let probe = DeliveryProbe()
            probe.insertionStrategy = .keyboardOnly
            probe.temporarilyUnreadable = true
            probe.afterWait = {
                probe.temporarilyUnreadable = false
                if stop == "clipboard" { probe.clipboardCurrent = false }
                if stop == "cancel" { probe.cancelled = true }
                if stop == "target" { probe.unchanged = false }
            }
            let result = await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context)
            #expect(result == (stop == "clipboard" ? .clipboardChanged : .copiedToClipboard))
            #expect(probe.events == ["copy"])
        }
    }

    @Test func emptySpeechDoesNotTouchClipboardOrDestination() async {
        for text in ["", "  \n\t", "\u{00a0}"] {
            let probe = DeliveryProbe()
            #expect(await DictationDelivery.deliver(text, pressEnter: true, context: probe.context) == .empty)
            #expect(probe.events.isEmpty)
        }
    }

    @Test func changedAppFieldOrSelectionFallsBackToClipboardWithoutKeys() async {
        let probe = DeliveryProbe()
        probe.unchanged = false
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
    }

    @Test func verifiedAccessibilityInsertionDoesNotAlsoPaste() async {
        let probe = DeliveryProbe()
        probe.writable = true
        probe.verified = true
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "AX"])
    }

    @Test func slowKeyboardPasteWaitsForReadbackBeforeReturn() async {
        let probe = DeliveryProbe()
        probe.afterWait = { if probe.waits == 2 { probe.verified = true } }
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .verified(enterSent: true))
        #expect(probe.waits == 2)
        #expect(probe.events == ["copy", "AX", "paste", "enter"])
    }

    @Test func verifiedInsertionWithoutReturnAuthorizationPastesOnceAndNeverSubmits() async {
        let probe = DeliveryProbe()
        probe.insertionStrategy = .keyboardOnly
        probe.afterPaste = { probe.verified = true }
        probe.allowsReturn = false
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "paste"])
        #expect(probe.waits == 0)
    }

    @Test func eventCreationFailureIsNotSuccess() async {
        let probe = DeliveryProbe()
        probe.posted = false
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy", "AX", "paste"])
        #expect(probe.waits == 0)
    }

    @Test func unchangedDestinationRecoversFromTemporaryReadFailureBeforePasting() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.afterWait = {
            probe.temporarilyUnreadable = false
            probe.verified = true
        }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "AX", "paste"])
        #expect(probe.waits == 1)
    }

    @Test func insertionAtFinalReadbackDeadlineIsRecognizedWithoutDuplicatePaste() async {
        let probe = DeliveryProbe()
        probe.afterWait = { if probe.waits == 6 { probe.verified = true } }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "AX", "paste"])
        #expect(probe.waits == 6)
    }

    @Test func validationAndInsertionRecoverIndependently() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.afterWait = {
            if probe.events.contains("paste") { probe.verified = true }
            else { probe.temporarilyUnreadable = false }
        }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "AX", "paste"])
        #expect(probe.waits == 2)
    }

    @Test func targetRecoveryAtFinalDeadlineStillPastesOnlyOnce() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.writable = true
        probe.afterAXAttempt = { probe.verified = true }
        probe.afterWait = { if probe.waits == 6 { probe.temporarilyUnreadable = false } }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "AX"])
        #expect(probe.waits == 6)
    }

    @Test func persistentReadFailureIsBoundedAndDoesNotSendKeys() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
        #expect(probe.waits == 6)
    }

    @Test func permanentReadFailureDoesNotRetry() async {
        let probe = DeliveryProbe()
        probe.unavailable = true
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
        #expect(probe.waits == 0)
    }

    @Test func slowAXReadExhaustsRetryBudgetWithoutFurtherReadsOrKeys() async {
        for initiallyUnreadable in [true, false] {
            let probe = DeliveryProbe()
            probe.temporarilyUnreadable = initiallyUnreadable
            var reads = 0
            probe.afterTargetRead = { reads += 1; probe.uptime += 1.1 }
            #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .copiedToClipboard)
            #expect(probe.events == ["copy"])
            #expect(probe.waits == 0)
            #expect(reads == 1)
        }
    }

    @Test func timeSpentInReadsCountsTowardRetryBudget() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        var reads = 0
        probe.afterTargetRead = { reads += 1; probe.uptime += 0.4 }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
        #expect(probe.waits == 2)
        #expect(reads == 2)
    }

    @Test func realChangeDuringReadRetryStopsImmediately() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.afterWait = { probe.unchanged = false }
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
        #expect(probe.waits == 1)
    }

    @Test func cancellationDuringReadRetryStopsImmediately() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.afterWait = { probe.cancelled = true; probe.temporarilyUnreadable = false }
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy"])
        #expect(probe.waits == 1)
    }

    @Test func failedAXWriteRevalidatesOriginalSnapshotBeforeSinglePaste() async {
        let probe = DeliveryProbe()
        probe.afterAXAttempt = { probe.temporarilyUnreadable = true }
        probe.afterWait = {
            if probe.events.contains("paste") { probe.verified = true }
            else { probe.temporarilyUnreadable = false }
        }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        #expect(probe.events == ["copy", "AX", "paste"])
        #expect(probe.waits == 2)
    }

    @Test func newClipboardDuringReadRetryIsNeitherOverwrittenNorPasted() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.afterWait = { probe.clipboardCurrent = false; probe.temporarilyUnreadable = false }
        let result = await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context)
        #expect(result == .clipboardChanged)
        #expect(probe.events == ["copy", "AX"])
        #expect(DictationFlowRecovery.text(for: result, deliveredText: "Hello") == "Hello")
        #expect(result.message.contains("Copy text"))
    }

    @Test func changedTargetAndNewClipboardDoNotClaimTranscriptIsCopied() async {
        let probe = DeliveryProbe()
        probe.temporarilyUnreadable = true
        probe.afterWait = { probe.clipboardCurrent = false; probe.unchanged = false }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .clipboardChanged)
        #expect(probe.events == ["copy"])
    }

    @Test func unverifiedKeyboardPasteNeverRetriesOrSendsReturn() async {
        let probe = DeliveryProbe()
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .unverified)
        #expect(probe.events == ["copy", "AX", "paste"])
        #expect(probe.waits == 6)
    }

    @Test func unreadableSuccessfulAXWriteIsNotDuplicatedWithKeyboardPaste() async {
        let probe = DeliveryProbe()
        probe.writable = true
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .unverified)
        #expect(probe.events == ["copy", "AX"])
    }

    @Test func targetIsRecheckedBeforeKeyboardFallback() async {
        let probe = DeliveryProbe()
        probe.afterAXAttempt = { probe.unchanged = false }
        #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .copiedToClipboard)
        #expect(probe.events == ["copy", "AX"])
    }

    @Test func focusMovingAfterInsertionPreventsReturnInAnotherApp() async {
        let probe = DeliveryProbe()
        probe.afterWait = { probe.verified = true; probe.focused = false }
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: probe.context) == .verified(enterSent: false))
        #expect(!probe.events.contains("enter"))
    }

    @Test func cancellationPreventsInsertionAndLaterReturn() async {
        let before = DeliveryProbe()
        before.cancelled = true
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: before.context) == .copiedToClipboard)
        #expect(before.events == ["copy"])
        let after = DeliveryProbe()
        after.afterWait = { after.cancelled = true; after.verified = true }
        #expect(await DictationDelivery.deliver("Hello", pressEnter: true, context: after.context) == .verified(enterSent: false))
        #expect(!after.events.contains("enter"))
    }

    @Test func genuineRepeatedRequestsAreEachDeliveredOnce() async {
        let probe = DeliveryProbe()
        probe.writable = true
        probe.verified = true
        for _ in 0..<2 {
            #expect(await DictationDelivery.deliver("Hello", context: probe.context) == .verified(enterSent: false))
        }
        #expect(probe.events == ["copy", "AX", "copy", "AX"])
    }

    @Test func replacementVerificationPreservesSurroundingUnicodeAndRejectsBadRanges() {
        #expect(DictationDelivery.replacing("A😀B", range: CFRange(location: 1, length: 2), with: "Hi") == "AHiB")
        #expect(DictationDelivery.replacing("AB", range: CFRange(location: 1, length: 0), with: "Hi") == "AHiB")
        for range in [CFRange(location: -1, length: 1), CFRange(location: 0, length: -1),
                      CFRange(location: 100, length: 0), CFRange(location: 1, length: Int.max)] {
            #expect(DictationDelivery.replacing("AB", range: range, with: "Hi") == nil)
        }
        #expect(DictationDelivery.replacing("😀", range: CFRange(location: 1, length: 0), with: "Hi") == nil)
    }
}

@Suite struct DictationTargetValidationTests {
    private let originalRange = CFRange(location: 4, length: 0)

    private func readiness(
        focus: DictationTargetReadiness = .ready,
        value: DictationAccessibilityRead<String> = .value("Text"),
        range: DictationAccessibilityRead<CFRange> = .value(CFRange(location: 4, length: 0))
    ) -> DictationTargetReadiness {
        DictationTargetValidation.readiness(
            focus: focus, originalValue: "Text", currentValue: value,
            originalRange: originalRange, currentRange: range
        )
    }

    @Test func sameSnapshotRemainsReady() {
        #expect(readiness() == .ready)
    }

    @Test func missingObservationIsNotMisclassifiedAsAnEdit() {
        #expect(readiness(focus: .temporarilyUnavailable) == .temporarilyUnavailable)
        #expect(readiness(value: .temporarilyUnavailable) == .temporarilyUnavailable)
        #expect(readiness(range: .temporarilyUnavailable) == .temporarilyUnavailable)
        #expect(readiness() == .ready)
    }

    @Test func everyConfirmedMismatchWinsOverOtherUnreadableAttributes() {
        #expect(readiness(focus: .changed, value: .temporarilyUnavailable) == .changed)
        #expect(readiness(focus: .temporarilyUnavailable, value: .value("Edited")) == .changed)
        #expect(readiness(value: .temporarilyUnavailable, range: .value(CFRange(location: 0, length: 0))) == .changed)
        #expect(readiness(value: .unavailable, range: .value(CFRange(location: 4, length: 1))) == .changed)
    }

    @Test func unsupportedPreviouslyReadableAttributesFailClosed() {
        #expect(readiness(focus: .unavailable) == .unavailable)
        #expect(readiness(value: .unavailable) == .unavailable)
        #expect(readiness(range: .unavailable) == .unavailable)
    }

    @Test func attributesAbsentAtCaptureAreNotInventedDuringValidation() {
        #expect(DictationTargetValidation.readiness(
            focus: .ready, originalValue: nil, currentValue: .unavailable,
            originalRange: nil, currentRange: .unavailable
        ) == .ready)
        #expect(DictationTargetValidation.readiness(
            focus: .changed, originalValue: nil, currentValue: .unavailable,
            originalRange: nil, currentRange: .unavailable
        ) == .changed)
    }

    @Test func onlyTransientAXFailuresAreRetryable() {
        for error in [AXError.cannotComplete, .noValue] {
            #expect(readiness(value: .failure(error)) == .temporarilyUnavailable)
        }
        for error in [AXError.attributeUnsupported, .invalidUIElement, .apiDisabled, .notImplemented] {
            #expect(readiness(value: .failure(error)) == .unavailable)
        }
    }
}
