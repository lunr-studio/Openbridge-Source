import Foundation

enum TestFailure: Error, CustomStringConvertible {
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
        throw TestFailure.failed(message)
    }
}

func posixPermissions(for url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.posixPermissions] as? NSNumber else {
        throw TestFailure.failed("Missing POSIX permissions for \(url.path)")
    }
    return value.intValue & 0o777
}

func testHistoryStorePermissions() throws {
    let supportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openbridge-history-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: supportURL) }

    let store = DictationHistoryStore(applicationSupportDirectory: supportURL)
    let entry = DictationHistoryEntry(
        id: UUID(uuidString: "0F1020B0-BC20-43D7-9A40-8A6453325C33") ?? UUID(),
        transcript: "A local test transcript.",
        createdAt: Date(timeIntervalSince1970: 1_779_000_000),
        durationSeconds: 1.2,
        modelIdentifier: "whisper-base",
        modelLabel: "Whisper Base",
        sourceApplication: "History Test"
    )

    try store.save([entry])

    let directoryPermissions = try posixPermissions(for: store.fileURL.deletingLastPathComponent())
    let filePermissions = try posixPermissions(for: store.fileURL)
    let loadedEntries = try store.load()

    try expect(directoryPermissions == DictationHistoryStore.Permissions.directory, "History directory permissions should be 0700.")
    try expect(filePermissions == DictationHistoryStore.Permissions.file, "History file permissions should be 0600.")
    try expect(store.hasSavedHistoryFile, "Saved history file should exist after save.")
    try expect(loadedEntries == [entry], "Saved history should round-trip through JSON.")
}

func testRetentionStartupResolution() throws {
    let newUser = HistoryRetentionStartupResolver.resolve(
        storedModeRawValue: nil,
        storedChoiceMade: nil,
        historyFileExists: false,
        onboardingCompleted: false
    )
    try expect(newUser.mode == .neverStore, "New users should start with history unsaved.")
    try expect(!newUser.choiceMade, "New users should still need to choose history retention.")
    try expect(!newUser.shouldPersistMigration, "New users should not be migrated silently.")

    let existingImplicitUser = HistoryRetentionStartupResolver.resolve(
        storedModeRawValue: nil,
        storedChoiceMade: nil,
        historyFileExists: true,
        onboardingCompleted: false
    )
    try expect(existingImplicitUser.mode == .storeNormally, "Existing implicit history users should be preserved.")
    try expect(existingImplicitUser.choiceMade, "Existing implicit history users should be marked as migrated.")
    try expect(existingImplicitUser.shouldPersistMigration, "Existing implicit history users should persist migration.")

    let completedOnboardingUser = HistoryRetentionStartupResolver.resolve(
        storedModeRawValue: nil,
        storedChoiceMade: nil,
        historyFileExists: false,
        onboardingCompleted: true
    )
    try expect(completedOnboardingUser.mode == .storeNormally, "Existing onboarded users should keep old default storage.")
    try expect(completedOnboardingUser.choiceMade, "Existing onboarded users should be marked as migrated.")
    try expect(completedOnboardingUser.shouldPersistMigration, "Existing onboarded users should persist migration.")

    let explicitChoice = HistoryRetentionStartupResolver.resolve(
        storedModeRawValue: DictationHistoryRetentionMode.autoDeleteAfter24Hours.rawValue,
        storedChoiceMade: true,
        historyFileExists: false,
        onboardingCompleted: false
    )
    try expect(explicitChoice.mode == .autoDeleteAfter24Hours, "Explicit retention mode should be preserved.")
    try expect(explicitChoice.choiceMade, "Explicit retention choice should remain confirmed.")
    try expect(!explicitChoice.shouldPersistMigration, "Explicit retention choice should not need migration.")
}

@main
enum HistoryRetentionStorageTestRunner {
    static func main() throws {
        try testHistoryStorePermissions()
        try testRetentionStartupResolution()
        print("History retention storage tests passed.")
    }
}
