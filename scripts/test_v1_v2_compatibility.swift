import Foundation

enum V1V2CompatibilityTestFailure: Error, CustomStringConvertible {
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
        throw V1V2CompatibilityTestFailure.failed(message)
    }
}

func posixPermissions(for url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.posixPermissions] as? NSNumber else {
        throw V1V2CompatibilityTestFailure.failed("Missing POSIX permissions for \(url.path)")
    }
    return value.intValue & 0o777
}

func writeFixture(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.data(using: .utf8)?.write(to: url)
}

func testV1LocalDataLoadsInV2Stores() throws {
    let supportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openbridge-v1-v2-compat-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: supportURL) }

    let appDataURL = supportURL.appendingPathComponent("OpenBridge", isDirectory: true)
    try writeFixture(
        """
        [
          {
            "id": "7FEC2955-70D7-4F06-8A64-D0AF1167D1E1",
            "transcript": "Existing V1 transcript",
            "createdAt": "2026-01-02T03:04:05Z",
            "durationSeconds": 2.4,
            "modelIdentifier": "whisper-base",
            "modelLabel": "Whisper Base",
            "sourceApplication": "TextEdit"
          }
        ]
        """,
        to: appDataURL.appendingPathComponent("dictation_history.json")
    )
    try writeFixture(
        """
        [
          {
            "id": "0FCD68A8-E891-4A83-9A5A-D7C250F76727",
            "triggerPhrase": "open bridge",
            "expansionText": "OpenBridge",
            "createdAt": "2026-01-02T03:04:05Z",
            "updatedAt": "2026-01-03T03:04:05Z"
          }
        ]
        """,
        to: appDataURL.appendingPathComponent("snippets.json")
    )
    try writeFixture(
        """
        {
          "open bridge": "OpenBridge",
          "trishan panch": "Trishan Panch"
        }
        """,
        to: appDataURL.appendingPathComponent("custom_dictionary.json")
    )

    let history = try DictationHistoryStore(applicationSupportDirectory: supportURL).load()
    try expect(history.count == 1, "V1 dictation history should load.")
    try expect(history[0].transcript == "Existing V1 transcript", "V1 history transcript should be preserved.")
    try expect(history[0].modelIdentifier == "whisper-base", "V1 history model identifier should be preserved.")
    try expect(history[0].modelLabel == "Whisper Base", "V1 history model label should be preserved.")
    try expect(history[0].sourceApplication == "TextEdit", "V1 history source app should be preserved.")

    let snippets = try SnippetStore(applicationSupportDirectory: supportURL).load()
    try expect(snippets.count == 1, "V1 snippets should load.")
    try expect(snippets[0].triggerPhrase == "open bridge", "V1 snippet trigger should be preserved.")
    try expect(snippets[0].expansionText == "OpenBridge", "V1 snippet expansion should be preserved.")

    let dictionary = try CustomDictionaryStore(applicationSupportDirectory: supportURL).load()
    try expect(dictionary.count == 2, "V1 custom dictionary entries should load.")
    try expect(
        dictionary.contains { $0.heardAs == "open bridge" && $0.replaceWith == "OpenBridge" },
        "V1 custom dictionary phrase should be preserved."
    )
}

func testV2SnippetPersistenceUsesPrivateStoragePermissions() throws {
    let supportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openbridge-v2-snippet-permissions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: supportURL) }

    let store = SnippetStore(applicationSupportDirectory: supportURL)
    let snippet = Snippet(
        id: UUID(uuidString: "DD9B6603-C755-41C5-8980-8534838B681D") ?? UUID(),
        triggerPhrase: "follow up",
        expansionText: "Please follow up when you have a moment.",
        createdAt: Date(timeIntervalSince1970: 1_767_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_767_000_060)
    )
    try store.save([snippet])

    let loaded = try store.load()
    let directoryPermissions = try posixPermissions(for: store.fileURL.deletingLastPathComponent())
    let filePermissions = try posixPermissions(for: store.fileURL)

    try expect(loaded == [snippet], "V2 snippets should round-trip through JSON.")
    try expect(directoryPermissions == SnippetStore.Permissions.directory, "Snippet directory permissions should be 0700.")
    try expect(filePermissions == SnippetStore.Permissions.file, "Snippet file permissions should be 0600.")
}

func testLegacyShortcutSettingsGainCommandModeDefault() throws {
    let legacyJSON = """
    {
      "dictation": "rightOption",
      "handsFree": "controlRightOption",
      "cancel": "controlShiftRightOption",
      "pasteLast": "shiftRightOption"
    }
    """
    let data = Data(legacyJSON.utf8)
    let settings = try JSONDecoder().decode(ShortcutSettings.self, from: data)

    try expect(settings.binding(for: .dictation) == .rightOption, "Legacy dictation shortcut should be preserved.")
    try expect(settings.binding(for: .handsFree) == .controlRightOption, "Legacy hands-free shortcut should be preserved.")
    try expect(settings.binding(for: .cancel) == .controlShiftRightOption, "Legacy cancel shortcut should be preserved.")
    try expect(settings.binding(for: .pasteLast) == .shiftRightOption, "Legacy paste-last shortcut should be preserved.")
    try expect(settings.binding(for: .commandMode) == .commandRightOption, "V2 Command Mode shortcut should get the default.")
    try expect(settings.hasUniqueBindings, "Migrated shortcut settings should stay conflict-free.")
}

func testLegacyBaseDefaultMigrationPairsParakeetDefaults() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.legacyBaseModelID,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: false,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.balanced.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.fast.rawValue
    )

    try expect(plan.selectedModelID == AppPreferenceMigration.defaultSelectedModelID, "Legacy Whisper Base default should migrate to Parakeet.")
    try expect(plan.shouldPersistSelectedModelID, "Legacy Base migration should persist the new selected model.")
    try expect(plan.shouldApplyParakeetDefaultSettings, "Legacy Base migration should pair Parakeet with Experimental mode and cleanup Off.")
}

func testAlreadyMigratedParakeetDefaultRepairsBalancedCleanup() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.defaultSelectedModelID,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: true,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.balanced.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.fast.rawValue
    )

    try expect(plan.selectedModelID == AppPreferenceMigration.defaultSelectedModelID, "Already-migrated Parakeet selection should be preserved.")
    try expect(!plan.shouldPersistSelectedModelID, "Already-migrated Parakeet repair should not rewrite the selected model.")
    try expect(plan.shouldApplyParakeetDefaultSettings, "Already-migrated Parakeet with old Balanced/Fast defaults should be repaired.")
}

func testManualParakeetCleanupIsNotRepairedAsLegacyDefault() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.defaultSelectedModelID,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: true,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.experimental.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.fast.rawValue
    )

    try expect(plan.selectedModelID == AppPreferenceMigration.defaultSelectedModelID, "Manual Parakeet selection should be preserved.")
    try expect(!plan.shouldApplyParakeetDefaultSettings, "Manual Parakeet cleanup choices should not be clobbered.")
}

@main
enum V1V2CompatibilityTestRunner {
    static func main() throws {
        try testV1LocalDataLoadsInV2Stores()
        try testV2SnippetPersistenceUsesPrivateStoragePermissions()
        try testLegacyShortcutSettingsGainCommandModeDefault()
        try testLegacyBaseDefaultMigrationPairsParakeetDefaults()
        try testAlreadyMigratedParakeetDefaultRepairsBalancedCleanup()
        try testManualParakeetCleanupIsNotRepairedAsLegacyDefault()
        print("V1-to-V2 compatibility tests passed.")
    }
}
