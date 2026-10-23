import Testing
@testable import OpenBridgeApp

struct DictationFlowRecoveryTests {
    @Test func recoveryUsesOnlyCurrentAttemptText() {
        #expect(DictationFlowRecovery.text(for: .unverified, deliveredText: "This attempt") == "This attempt")
        #expect(DictationFlowRecovery.text(for: .copiedToClipboard, deliveredText: "Clipboard text") == "Clipboard text")
        #expect(DictationFlowRecovery.text(for: .copiedToClipboard, deliveredText: nil) == nil)
        #expect(DictationFlowRecovery.text(for: .copiedToClipboard, deliveredText: "  ") == nil)
        #expect(DictationFlowRecovery.text(for: .empty, deliveredText: "Old transcript") == nil)
        #expect(DictationFlowRecovery.text(for: .verified(enterSent: false), deliveredText: "Delivered") == nil)
    }
}
