import Foundation

// Test Part A: Atomic model default migration with provenance.
// Verifies that AppPreferenceMigration.plan() produces the correct
// migration plan for pristine installs, legacy defaults, and user choices.

// These are needed from the app source (compiled alongside)
// We reference them directly since the test is compiled with the source files.

enum MigrationTestFailure: Error, CustomStringConvertible {
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
        throw MigrationTestFailure.failed(message)
    }
}

func testPristineInstallGetsParakeetDefault() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: nil,
        didMigrateLegacyTinyDefault: false,
        didMigrateLegacyBaseDefault: false,
        storedPerformanceModeRawValue: nil,
        storedCleanupModeRawValue: nil,
        storedSchemaVersion: 0,
        storedPerformanceModeSource: nil
    )

    try expect(plan.selectedModelID == AppPreferenceMigration.defaultSelectedModelID,
               "Pristine install should get Parakeet default")
    try expect(plan.shouldPersistAllDefaults == true,
               "Pristine install should persist all defaults atomically")
    try expect(plan.performanceModeSource == .appDefault,
               "Pristine install should mark source as appDefault")
    try expect(plan.needsSchemaVersionBump == true,
               "Pristine install should bump schema version")

    print("[PASS] testPristineInstallGetsParakeetDefault")
}

func testLegacyTinyMigration() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.legacyTinyModelID,
        didMigrateLegacyTinyDefault: false,
        didMigrateLegacyBaseDefault: true,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.balanced.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.fast.rawValue,
        storedSchemaVersion: 1,
        storedPerformanceModeSource: ModelPreferenceSource.user.rawValue
    )

    try expect(plan.selectedModelID == AppPreferenceMigration.defaultSelectedModelID,
               "Legacy Tiny should migrate to Parakeet default")
    try expect(plan.shouldPersistAllDefaults == true,
               "Legacy migration should persist all defaults atomically")
    try expect(plan.shouldMarkLegacyTinyDefaultMigrated == true,
               "Legacy Tiny should be marked as migrated")

    print("[PASS] testLegacyTinyMigration")
}

func testLegacyBaseMigration() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.legacyBaseModelID,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: false,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.balanced.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.fast.rawValue,
        storedSchemaVersion: 1,
        storedPerformanceModeSource: ModelPreferenceSource.user.rawValue
    )

    try expect(plan.selectedModelID == AppPreferenceMigration.defaultSelectedModelID,
               "Legacy Base should migrate to Parakeet default")
    try expect(plan.shouldPersistAllDefaults == true,
               "Legacy Base migration should persist all defaults")
    try expect(plan.shouldMarkLegacyBaseDefaultMigrated == true,
               "Legacy Base should be marked as migrated")

    print("[PASS] testLegacyBaseMigration")
}

func testUserChoicePreserved() throws {
    let userModel = "whisper-large-v3"
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: userModel,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: true,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.accurate.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.off.rawValue,
        storedSchemaVersion: 2,
        storedPerformanceModeSource: ModelPreferenceSource.user.rawValue
    )

    try expect(plan.selectedModelID == userModel,
               "User model choice should be preserved")
    try expect(plan.shouldPersistAllDefaults == false,
               "User choice should not trigger full preset write")
    try expect(plan.performanceModeSource == .user,
               "User choice should keep source as user")

    print("[PASS] testUserChoicePreserved")
}

func testSchemaVersionBumpFromV1() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.defaultSelectedModelID,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: true,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.experimental.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.off.rawValue,
        storedSchemaVersion: 1,
        storedPerformanceModeSource: ModelPreferenceSource.appDefault.rawValue
    )

    try expect(plan.needsSchemaVersionBump == true,
               "Schema v1 should need bump to v\(AppPreferenceMigration.currentSchemaVersion)")
    try expect(plan.shouldPersistAllDefaults == false,
               "Already-migrated Parakeet should not re-persist")

    print("[PASS] testSchemaVersionBumpFromV1")
}

func testRepairAlreadyMigratedBaseDefault() throws {
    let plan = AppPreferenceMigration.plan(
        storedSelectedModelID: AppPreferenceMigration.defaultSelectedModelID,
        didMigrateLegacyTinyDefault: true,
        didMigrateLegacyBaseDefault: true,
        storedPerformanceModeRawValue: TranscriptionPerformanceMode.balanced.rawValue,
        storedCleanupModeRawValue: TranscriptionCleanupMode.fast.rawValue,
        storedSchemaVersion: 2,
        storedPerformanceModeSource: nil
    )

    try expect(plan.shouldApplyParakeetDefaultSettings == true,
               "Already-migrated Base with balanced+fast should trigger repair")
    try expect(plan.performanceModeSource == .appDefault,
               "Repair should set source to appDefault")

    print("[PASS] testRepairAlreadyMigratedBaseDefault")
}

// Run all tests
do {
    try testPristineInstallGetsParakeetDefault()
    try testLegacyTinyMigration()
    try testLegacyBaseMigration()
    try testUserChoicePreserved()
    try testSchemaVersionBumpFromV1()
    try testRepairAlreadyMigratedBaseDefault()
    print("\n--- All migration provenance tests passed ---")
} catch {
    print("\n--- TEST FAILURE ---")
    print(error)
    exit(1)
}