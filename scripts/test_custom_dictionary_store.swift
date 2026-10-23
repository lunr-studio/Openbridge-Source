import Foundation

enum CustomDictionaryTestFailure: Error, CustomStringConvertible {
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
        throw CustomDictionaryTestFailure.failed(message)
    }
}

func posixPermissions(for url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.posixPermissions] as? NSNumber else {
        throw CustomDictionaryTestFailure.failed("Missing POSIX permissions for \(url.path)")
    }
    return value.intValue & 0o777
}

func expectValidationError(
    _ expected: CustomDictionaryStore.ValidationError,
    _ work: () throws -> Void
) throws {
    do {
        try work()
        throw CustomDictionaryTestFailure.failed("Expected validation error \(expected).")
    } catch let error as CustomDictionaryStore.ValidationError {
        try expect(error == expected, "Expected \(expected), received \(error).")
    }
}

func testCustomDictionaryRoundTripAndPermissions() throws {
    let supportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openbridge-custom-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: supportURL) }

    let store = CustomDictionaryStore(applicationSupportDirectory: supportURL)
    let entries = [
        CustomDictionaryEntry(
            id: UUID(uuidString: "6E43F3D9-0F16-46B2-9F56-B9BD30CF0171") ?? UUID(),
            heardAs: " trishan panch ",
            replaceWith: " Trishan Panch "
        ),
        CustomDictionaryEntry(
            id: UUID(uuidString: "C6CF5B7F-03C1-4A4F-A829-E4629633AFD7") ?? UUID(),
            heardAs: "open bridge",
            replaceWith: "OpenBridge"
        ),
    ]

    let savedEntries = try store.save(entries)
    let loadedEntries = try store.load()
    let directoryPermissions = try posixPermissions(for: store.fileURL.deletingLastPathComponent())
    let filePermissions = try posixPermissions(for: store.fileURL)
    let data = try Data(contentsOf: store.fileURL)
    let pairs = try JSONDecoder().decode([String: String].self, from: data)

    try expect(savedEntries.count == 2, "Both custom dictionary entries should be saved.")
    try expect(savedEntries[0].heardAs == "trishan panch", "Store should trim the heard-as phrase.")
    try expect(savedEntries[0].replaceWith == "Trishan Panch", "Store should trim the replacement text.")
    try expect(
        Set(loadedEntries.map(\.heardAs)) == Set(["open bridge", "trishan panch"]),
        "Saved custom dictionary entries should round-trip through JSON."
    )
    try expect(pairs["trishan panch"] == "Trishan Panch", "JSON should store heard-as to replacement pairs.")
    try expect(
        directoryPermissions == CustomDictionaryStore.Permissions.directory,
        "Custom dictionary directory permissions should be 0700."
    )
    try expect(
        filePermissions == CustomDictionaryStore.Permissions.file,
        "Custom dictionary file permissions should be 0600."
    )
}

func testCustomDictionaryValidation() throws {
    try expectValidationError(.emptyHeardAs) {
        _ = try CustomDictionaryStore.validatedEntries([
            CustomDictionaryEntry(heardAs: " ", replaceWith: "OpenBridge"),
        ])
    }

    try expectValidationError(.emptyReplaceWith) {
        _ = try CustomDictionaryStore.validatedEntries([
            CustomDictionaryEntry(heardAs: "open bridge", replaceWith: " "),
        ])
    }

    try expectValidationError(.duplicateHeardAs("Open Bridge")) {
        _ = try CustomDictionaryStore.validatedEntries([
            CustomDictionaryEntry(heardAs: "open bridge", replaceWith: "OpenBridge"),
            CustomDictionaryEntry(heardAs: "Open Bridge", replaceWith: "OpenBridge App"),
        ])
    }
}

@main
enum CustomDictionaryStoreTestRunner {
    static func main() throws {
        try testCustomDictionaryRoundTripAndPermissions()
        try testCustomDictionaryValidation()
        print("Custom dictionary storage tests passed.")
    }
}
