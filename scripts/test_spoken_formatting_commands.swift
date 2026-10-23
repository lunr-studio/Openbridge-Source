import Foundation

enum SpokenFormattingTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SpokenFormattingTestFailure.failed(message)
    }
}

func expectFormatted(_ input: String, _ expected: String) throws {
    let actual = SpokenFormattingCommands.apply(to: input, enabled: true)
    try expect(actual == expected, "Expected \(String(reflecting: expected)), received \(String(reflecting: actual)).")
}

func testSupportedSpokenFormattingCommands() throws {
    try expectFormatted("hello comma world period", "hello, world.")
    try expectFormatted("are you there question mark", "are you there?")
    try expectFormatted("first new line second", "first\nsecond")
    try expectFormatted("first new paragraph second", "first\n\nsecond")
    try expectFormatted("first new line second comma third period", "first\nsecond, third.")
}

func testDisabledSettingLeavesTextUnchanged() throws {
    let input = "hello comma world period"
    let output = SpokenFormattingCommands.apply(to: input, enabled: false)
    try expect(output == input, "Disabled spoken formatting should leave text unchanged.")
}

func testLiteralPhraseProtection() throws {
    try expectFormatted("write the word period here", "write the word period here")
    try expectFormatted("write the word comma here", "write the word comma here")
    try expectFormatted("write the phrase new line here", "write the phrase new line here")
}

func testPressEnterRemainsTerminalOnly() throws {
    let disabled = PressEnterVoiceCommand.apply(to: "hello press enter", enabled: false)
    try expect(disabled == PressEnterCommandResult(text: "hello press enter", shouldPressEnter: false), "Disabled press-enter command should not change text.")

    let terminal = PressEnterVoiceCommand.apply(to: "hello period press enter", enabled: true)
    try expect(terminal == PressEnterCommandResult(text: "hello period", shouldPressEnter: true), "Terminal press-enter command should be removed.")

    let middle = PressEnterVoiceCommand.apply(to: "hello press enter then continue", enabled: true)
    try expect(middle == PressEnterCommandResult(text: "hello press enter then continue", shouldPressEnter: false), "Middle press-enter phrase should stay literal.")
}

@main
enum SpokenFormattingCommandsTestRunner {
    static func main() throws {
        try testSupportedSpokenFormattingCommands()
        try testDisabledSettingLeavesTextUnchanged()
        try testLiteralPhraseProtection()
        try testPressEnterRemainsTerminalOnly()
        print("Spoken formatting command tests passed.")
    }
}
