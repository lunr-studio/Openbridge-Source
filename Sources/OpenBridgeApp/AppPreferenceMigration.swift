import Foundation

enum ModelPreferenceSource: String {
    case appDefault
    case user
}

struct AppPreferenceMigrationPlan: Equatable {
    let selectedModelID: String
    let shouldPersistSelectedModelID: Bool
    let shouldApplyParakeetDefaultSettings: Bool
    let shouldMarkLegacyTinyDefaultMigrated: Bool
    let shouldMarkLegacyBaseDefaultMigrated: Bool
    let shouldPersistAllDefaults: Bool
    let performanceModeSource: ModelPreferenceSource
    let needsSchemaVersionBump: Bool
}

enum AppPreferenceMigration {
    static let defaultSelectedModelID = "parakeet-tdt-0.6b-v3-mlx-bf16"
    static let legacyTinyModelID = "whisper-tiny"
    static let legacyBaseModelID = "whisper-base"
    static let currentSchemaVersion = 2

    static func plan(
        storedSelectedModelID: String?,
        didMigrateLegacyTinyDefault: Bool,
        didMigrateLegacyBaseDefault: Bool,
        storedPerformanceModeRawValue: String?,
        storedCleanupModeRawValue: String?,
        storedSchemaVersion: Int,
        storedPerformanceModeSource: String?
    ) -> AppPreferenceMigrationPlan {
        let isPristineInstall = storedSelectedModelID == nil
        let isMigratingLegacyTinyDefault =
            storedSelectedModelID == legacyTinyModelID && !didMigrateLegacyTinyDefault
        let isMigratingLegacyBaseDefault =
            storedSelectedModelID == legacyBaseModelID && !didMigrateLegacyBaseDefault
        let isMigratingLegacyDefault = isMigratingLegacyTinyDefault || isMigratingLegacyBaseDefault
        let selectedModelID = isMigratingLegacyDefault
            ? defaultSelectedModelID
            : (storedSelectedModelID ?? defaultSelectedModelID)

        let isRepairingAlreadyMigratedBaseDefault =
            !isMigratingLegacyDefault
            && didMigrateLegacyBaseDefault
            && storedSelectedModelID == defaultSelectedModelID
            && storedPerformanceModeRawValue == TranscriptionPerformanceMode.balanced.rawValue
            && storedCleanupModeRawValue == TranscriptionCleanupMode.fast.rawValue

        let shouldPersistAllDefaults = isPristineInstall || isMigratingLegacyDefault

        let performanceModeSource: ModelPreferenceSource
        if isPristineInstall || isMigratingLegacyDefault || isRepairingAlreadyMigratedBaseDefault {
            performanceModeSource = .appDefault
        } else if let stored = storedPerformanceModeSource,
                  let source = ModelPreferenceSource(rawValue: stored) {
            performanceModeSource = source
        } else {
            performanceModeSource = .appDefault
        }

        let needsSchemaVersionBump = storedSchemaVersion < currentSchemaVersion

        return AppPreferenceMigrationPlan(
            selectedModelID: selectedModelID,
            shouldPersistSelectedModelID: shouldPersistAllDefaults,
            shouldApplyParakeetDefaultSettings: shouldPersistAllDefaults || isRepairingAlreadyMigratedBaseDefault,
            shouldMarkLegacyTinyDefaultMigrated: !didMigrateLegacyTinyDefault,
            shouldMarkLegacyBaseDefaultMigrated: !didMigrateLegacyBaseDefault,
            shouldPersistAllDefaults: shouldPersistAllDefaults,
            performanceModeSource: performanceModeSource,
            needsSchemaVersionBump: needsSchemaVersionBump
        )
    }
}
