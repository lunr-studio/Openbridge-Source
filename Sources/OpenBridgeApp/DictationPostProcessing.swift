import Foundation

struct PressEnterCommandResult: Equatable {
    let text: String
    let shouldPressEnter: Bool
}

enum PressEnterVoiceCommand {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s,.;:!?\-]+)press\s+enter[\s.?!]*$"#,
        options: [.caseInsensitive]
    )
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",.;:!?-"))

    static func apply(to transcriptText: String, enabled: Bool) -> PressEnterCommandResult {
        guard enabled else {
            return PressEnterCommandResult(text: transcriptText, shouldPressEnter: false)
        }

        let trimmedText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return PressEnterCommandResult(text: transcriptText, shouldPressEnter: false)
        }

        let fullRange = NSRange(trimmedText.startIndex..<trimmedText.endIndex, in: trimmedText)
        guard let match = pattern.firstMatch(
            in: trimmedText,
            options: [],
            range: fullRange
        ),
            match.range.location != NSNotFound,
            match.range.location + match.range.length == fullRange.location + fullRange.length,
            let commandRange = Range(match.range, in: trimmedText) else {
            return PressEnterCommandResult(text: transcriptText, shouldPressEnter: false)
        }

        let cleanedText = String(trimmedText[..<commandRange.lowerBound])
            .trimmingCharacters(in: trimCharacters)

        guard !cleanedText.isEmpty else {
            return PressEnterCommandResult(text: transcriptText, shouldPressEnter: false)
        }

        return PressEnterCommandResult(text: cleanedText, shouldPressEnter: true)
    }
}

enum SpokenFormattingCommands {
    private static let commandPattern = try! NSRegularExpression(
        pattern: #"\b(new\s+paragraph|question\s+mark|new\s+line|period|comma)\b"#,
        options: [.caseInsensitive]
    )

    static func apply(to text: String, enabled: Bool) -> String {
        guard enabled, !text.isEmpty else {
            return text
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var output = ""
        var cursor = 0

        commandPattern.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            guard match.range.location >= cursor else { return }

            let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
            output += nsText.substring(with: prefixRange)

            let commandText = normalizedCommand(nsText.substring(with: match.range))
            if isLiteralCommandReference(before: match.range, in: nsText) {
                output += nsText.substring(with: match.range)
            } else {
                output += replacement(for: commandText)
            }

            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            output += nsText.substring(from: cursor)
        }

        return normalizeSpacing(output)
    }

    private static func normalizedCommand(_ command: String) -> String {
        command
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacement(for command: String) -> String {
        switch command {
        case "new paragraph":
            return "\n\n"
        case "new line":
            return "\n"
        case "period":
            return "."
        case "comma":
            return ","
        case "question mark":
            return "?"
        default:
            return command
        }
    }

    private static func isLiteralCommandReference(before range: NSRange, in text: NSString) -> Bool {
        let prefixLength = min(range.location, 32)
        guard prefixLength > 0 else {
            return false
        }

        let prefix = text.substring(with: NSRange(location: range.location - prefixLength, length: prefixLength))
        return prefix.range(
            of: #"(?i)(?:^|[\s,.;:!?\-])the\s+(?:word|words|phrase)\s+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizeSpacing(_ text: String) -> String {
        var value = text
        value = replacing(value, pattern: #"[ \t]+([,.?])"#, template: "$1")
        value = replacing(value, pattern: #"([,.?])([^\s\n,.?])"#, template: "$1 $2")
        value = replacing(value, pattern: #"[ \t]*\n[ \t]*"#, template: "\n")
        value = replacing(value, pattern: #"\.{2,}"#, template: ".")
        value = replacing(value, pattern: #",{2,}"#, template: ",")
        value = replacing(value, pattern: #"\?{2,}"#, template: "?")
        value = replacing(value, pattern: #"[ \t]{2,}"#, template: " ")
        return replacing(value, pattern: #"\n{3,}"#, template: "\n\n")
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
