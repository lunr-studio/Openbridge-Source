import AppKit
import Foundation

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case dictation
    case handsFree
    case cancel
    case pasteLast
    case commandMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation:
            return "Dictation"
        case .handsFree:
            return "Hands-free dictation"
        case .cancel:
            return "Cancel recording"
        case .pasteLast:
            return "Paste last transcript"
        case .commandMode:
            return "Command Mode"
        }
    }

    var summary: String {
        switch self {
        case .dictation:
            return "Start or stop the regular dictate-and-paste flow."
        case .handsFree:
            return "Start or stop longer hands-free recording."
        case .cancel:
            return "Discard the current recording without pasting."
        case .pasteLast:
            return "Paste the most recent successful output again."
        case .commandMode:
            return "Transform selected text with a spoken instruction."
        }
    }
}

enum ShortcutBinding: String, CaseIterable, Codable, Identifiable {
    case rightOption
    case controlRightOption
    case shiftRightOption
    case controlShiftRightOption
    case commandRightOption
    case commandShiftRightOption
    case commandControlRightOption

    static let rightOptionKeyCode: UInt16 = 61
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption:
            return "Right Option"
        case .controlRightOption:
            return "Control + Right Option"
        case .shiftRightOption:
            return "Shift + Right Option"
        case .controlShiftRightOption:
            return "Control + Shift + Right Option"
        case .commandRightOption:
            return "Command + Right Option"
        case .commandShiftRightOption:
            return "Command + Shift + Right Option"
        case .commandControlRightOption:
            return "Command + Control + Right Option"
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .rightOption:
            return [.option]
        case .controlRightOption:
            return [.control, .option]
        case .shiftRightOption:
            return [.shift, .option]
        case .controlShiftRightOption:
            return [.control, .shift, .option]
        case .commandRightOption:
            return [.command, .option]
        case .commandShiftRightOption:
            return [.command, .shift, .option]
        case .commandControlRightOption:
            return [.command, .control, .option]
        }
    }

    var systemConflictReason: String? {
        nil
    }

    func matches(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers == modifierFlags
    }

    static func normalizedModifiers(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(relevantModifiers)
    }
}

struct ShortcutSettings: Codable, Equatable {
    var dictation: ShortcutBinding
    var handsFree: ShortcutBinding
    var cancel: ShortcutBinding
    var pasteLast: ShortcutBinding
    var commandMode: ShortcutBinding

    static let defaults = ShortcutSettings(
        dictation: .rightOption,
        handsFree: .controlRightOption,
        cancel: .controlShiftRightOption,
        pasteLast: .shiftRightOption,
        commandMode: .commandRightOption
    )

    init(
        dictation: ShortcutBinding,
        handsFree: ShortcutBinding,
        cancel: ShortcutBinding,
        pasteLast: ShortcutBinding,
        commandMode: ShortcutBinding
    ) {
        self.dictation = dictation
        self.handsFree = handsFree
        self.cancel = cancel
        self.pasteLast = pasteLast
        self.commandMode = commandMode
    }

    private enum CodingKeys: String, CodingKey {
        case dictation
        case handsFree
        case cancel
        case pasteLast
        case commandMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.dictation = try container.decode(ShortcutBinding.self, forKey: .dictation)
        self.handsFree = try container.decode(ShortcutBinding.self, forKey: .handsFree)
        self.cancel = try container.decode(ShortcutBinding.self, forKey: .cancel)
        self.pasteLast = try container.decode(ShortcutBinding.self, forKey: .pasteLast)
        self.commandMode = try container.decodeIfPresent(ShortcutBinding.self, forKey: .commandMode) ?? .commandRightOption
    }

    var hasUniqueBindings: Bool {
        Set(ShortcutAction.allCases.map { binding(for: $0) }).count == ShortcutAction.allCases.count
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        switch action {
        case .dictation:
            return dictation
        case .handsFree:
            return handsFree
        case .cancel:
            return cancel
        case .pasteLast:
            return pasteLast
        case .commandMode:
            return commandMode
        }
    }

    mutating func set(_ binding: ShortcutBinding, for action: ShortcutAction) {
        switch action {
        case .dictation:
            dictation = binding
        case .handsFree:
            handsFree = binding
        case .cancel:
            cancel = binding
        case .pasteLast:
            pasteLast = binding
        case .commandMode:
            commandMode = binding
        }
    }

    func action(matching modifiers: NSEvent.ModifierFlags) -> ShortcutAction? {
        ShortcutAction.allCases.first { action in
            binding(for: action).matches(modifiers)
        }
    }

    func action(using binding: ShortcutBinding, excluding excludedAction: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { action in
            action != excludedAction && self.binding(for: action) == binding
        }
    }
}
