import Foundation

enum DictationRecoveryTone {
    case attention
    case unconfirmed

    var title: String { self == .unconfirmed ? "Check your text" : "Your text is ready" }
    var iconName: String { self == .unconfirmed ? "doc.text" : "exclamationmark.triangle" }
}

/// Recovery must refer to the text from this delivery attempt, never History.
enum DictationFlowRecovery {
    // A dispatched but unconfirmed paste is neither a verified success nor a
    // known failure. A separate History failure must still receive attention.
    static func tone(for result: DictationDeliveryResult, historyFailure: String?) -> DictationRecoveryTone {
        result == .unverified && historyFailure == nil ? .unconfirmed : .attention
    }

    static func text(for result: DictationDeliveryResult, deliveredText: String?) -> String? {
        guard let deliveredText, DictationDelivery.hasUsableText(deliveredText) else { return nil }
        switch result {
        case .unverified, .copiedToClipboard, .clipboardChanged: return deliveredText
        case .empty, .verified: return nil
        }
    }
}
