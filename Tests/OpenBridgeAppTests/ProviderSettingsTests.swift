import Foundation
import Testing
@testable import OpenBridgeApp

private final class CapturedProviderRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock()
        stored = request
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor DelayedSuccessConnectionTester: ProviderConnectionTester {
    func test(
        settings: ProviderSettings,
        apiKey: String?
    ) async -> ProviderConnectionTestResult {
        try? await Task.sleep(for: .milliseconds(50))
        return .success(latencyMS: 50)
    }
}

/// No Security.framework calls: records premature secret reads deterministically.
private final class FirstRunCredentialSpy: ProviderCredentialStore, @unchecked Sendable {
    var key: String? = "synthetic-existing-key"
    var reads = 0
    var writes = 0
    var failReads = false
    var failWrites = false

    func readAPIKey() throws -> String? {
        reads += 1
        if failReads { throw ProviderSettingsError.keychainFailure("synthetic denied access") }
        return key
    }

    func writeAPIKey(_ key: String?) throws {
        writes += 1
        if failWrites { throw ProviderSettingsError.keychainFailure("synthetic denied write") }
        self.key = key
    }
}

// MARK: - Provider Settings Tests (#310 / EXT-02)
//
// Acceptance coverage: TLS-only endpoints, timeout bounds, Keychain-backed
// credentials behind a protocol (never in defaults/manifests), consent
// gating, disable/delete flows, distinguishable connection-test outcomes,
// immediate blocking on disable, and the local-only guarantee.
//
// Every test uses a UNIQUE UserDefaults suite so persisted settings can
// never leak between tests.

@Suite(.serialized) struct ProviderSettingsTests {

    /// Fresh, isolated defaults per test.
    private func freshDefaults() -> UserDefaults {
        let name = "provider-settings-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    @Test func firstLaunchAndPassiveReadinessNeverReadCredentials() {
        let store = FirstRunCredentialSpy()
        let controller = ProviderSettingsController(credentialStore: store, defaults: freshDefaults())
        for _ in 0..<3 {
            #expect(!controller.hasCredential)
            #expect(controller.maskedCredentialPreview == nil)
            #expect(!controller.hasCurrentTestAttestation)
            #expect(controller.beginExternalRequest(requestID: "local-only") == nil)
        }
        #expect(store.reads == 0)
        #expect(store.writes == 0)
        #expect(!controller.settings.cloudEnabled)
        #expect(!controller.settings.consentGranted)
    }

    @MainActor
    @Test func savedProfileLaunchDoesNotReadEvenWhenKeychainWouldDenyAccess() throws {
        let defaults = freshDefaults()
        defaults.set(try JSONEncoder().encode(ProviderSettings(cloudEnabled: true, consentGranted: true)),
                     forKey: "research.provider.settings.v1")
        let store = FirstRunCredentialSpy()
        store.failReads = true
        let controller = ProviderSettingsController(credentialStore: store, defaults: defaults)
        #expect(!controller.hasCredential)
        #expect(!controller.hasCurrentTestAttestation)
        #expect(controller.maskedCredentialPreview == nil)
        #expect(store.reads == 0)
    }

    @MainActor
    @Test func explicitSavedKeyLoadDenialRemainsRetryableWithoutChangingConsent() throws {
        let profile = ProviderSettings(cloudEnabled: false, consentGranted: false)
        let store = FirstRunCredentialSpy()
        store.failReads = true
        let controller = ProviderSettingsController(
            settings: profile, credentialStore: store, defaults: freshDefaults()
        )
        #expect(controller.canLoadSavedCredential)
        #expect(throws: ProviderSettingsError.self) { try controller.loadSavedCredential() }
        #expect(!controller.hasCredential)
        #expect(controller.canLoadSavedCredential)
        #expect(controller.maskedCredentialPreview == nil)
        #expect(controller.settings == profile)
        #expect(controller.cloudActivity == .idle)
        #expect(store.reads == 1)
        #expect(store.writes == 0)

        store.failReads = false
        try controller.loadSavedCredential()
        #expect(controller.hasCredential)
        #expect(controller.canLoadSavedCredential)
        #expect(controller.settings == profile)
        #expect(controller.cloudActivity == .idle)
        #expect(store.reads == 2)
        #expect(store.writes == 0)
    }

    @MainActor
    @Test func explicitMissingKeyLoadPersistsAbsenceAndDoesNotKeepProbing() throws {
        let defaults = freshDefaults()
        let store = FirstRunCredentialSpy()
        store.key = nil
        let controller = ProviderSettingsController(
            settings: ProviderSettings(), credentialStore: store, defaults: defaults
        )
        try controller.loadSavedCredential()
        #expect(!controller.hasCredential)
        #expect(!controller.canLoadSavedCredential)
        #expect(controller.maskedCredentialPreview == nil)
        #expect(!controller.hasCurrentTestAttestation)
        #expect(store.reads == 1)
        try controller.loadSavedCredential()
        #expect(store.reads == 1)

        let reloaded = ProviderSettingsController(credentialStore: store, defaults: defaults)
        #expect(!reloaded.canLoadSavedCredential)
        try reloaded.loadSavedCredential()
        #expect(store.reads == 1)
        #expect(store.writes == 0)
    }

    @MainActor
    @Test func freshProfileIgnoresForeignKeyEvenAfterConsentAndRelaunch() async throws {
        let defaults = freshDefaults()
        let store = FirstRunCredentialSpy()
        let controller = ProviderSettingsController(credentialStore: store, defaults: defaults)
        try controller.grantConsent()
        try controller.loadSavedCredential()
        #expect(!controller.canLoadSavedCredential)
        #expect(!controller.hasCredential)
        #expect(controller.beginExternalRequest(requestID: "fresh-local-key") == nil)
        await #expect(throws: CloudRequestAuthorizationError.missingCredential) {
            _ = try await controller.authorizeCloudRequest(requestID: "fresh-cloud-key", meetingConsent: true)
        }
        let tester = StubConnectionTester(result: .success(latencyMS: 5))
        #expect(await controller.testConnection(using: tester) == .notConfigured)
        #expect(await tester.callCount == 0)

        let reloaded = ProviderSettingsController(credentialStore: store, defaults: defaults)
        #expect(!reloaded.canLoadSavedCredential)
        try reloaded.loadSavedCredential()
        #expect(!reloaded.hasCredential)
        #expect(store.reads == 0)
        #expect(store.writes == 0)
        #expect(store.key == "synthetic-existing-key")
    }

    @MainActor
    @Test func deletingAnUnloadedSavedKeyPersistsNoKeyHint() throws {
        let defaults = freshDefaults()
        let store = FirstRunCredentialSpy()
        let controller = ProviderSettingsController(
            settings: ProviderSettings(), credentialStore: store, defaults: defaults
        )
        #expect(controller.canLoadSavedCredential)
        #expect(!controller.hasCredential)
        try controller.deleteCredential()
        #expect(!controller.canLoadSavedCredential)
        #expect(!controller.hasCredential)
        #expect(store.key == nil)
        #expect(store.reads == 0)
        #expect(store.writes == 1)

        // Another process creating an item must not silently enroll this profile.
        store.key = "synthetic-unrelated-replacement"
        let reloaded = ProviderSettingsController(credentialStore: store, defaults: defaults)
        try reloaded.loadSavedCredential()
        #expect(!reloaded.canLoadSavedCredential)
        #expect(!reloaded.hasCredential)
        #expect(store.reads == 0)
    }

    @MainActor
    @Test func providerAndEndpointSwitchDeleteUnloadedKeysBeforeSavingNewIdentity() throws {
        for changePreset in [true, false] {
            let defaults = freshDefaults()
            let store = FirstRunCredentialSpy()
            let controller = ProviderSettingsController(
                settings: ProviderSettings(), credentialStore: store, defaults: defaults
            )
            #expect(controller.canLoadSavedCredential)
            #expect(!controller.hasCredential)
            var updated = controller.settings
            if changePreset {
                updated = updated.applying(.deepSeek)
            } else {
                updated.baseURL = URL(string: "https://different-provider.example/v1")!
            }
            try controller.update(updated)
            #expect(controller.settings == updated)
            #expect(store.key == nil)
            #expect(store.reads == 0)
            #expect(store.writes == 1)
            #expect(!controller.canLoadSavedCredential)
            #expect(!controller.hasCredential)
            let reloaded = ProviderSettingsController(credentialStore: store, defaults: defaults)
            #expect(!reloaded.canLoadSavedCredential)
            try reloaded.loadSavedCredential()
            #expect(store.reads == 0)
        }
    }

    @MainActor
    @Test func unloadedProviderSwitchDeletionFailureLeavesOriginalIdentityAndKey() throws {
        let defaults = freshDefaults()
        let original = ProviderSettings(cloudEnabled: true, consentGranted: true)
        defaults.set(try JSONEncoder().encode(original), forKey: "research.provider.settings.v1")
        let store = FirstRunCredentialSpy()
        store.failWrites = true
        let controller = ProviderSettingsController(credentialStore: store, defaults: defaults)
        #expect(throws: ProviderSettingsError.self) { try controller.selectPreset(.deepSeek) }
        #expect(controller.settings == original)
        #expect(controller.canLoadSavedCredential)
        #expect(!controller.hasCredential)
        #expect(store.key == "synthetic-existing-key")
        #expect(store.reads == 0)
        #expect(store.writes == 1)
        let reloaded = ProviderSettingsController(credentialStore: store, defaults: defaults)
        #expect(reloaded.settings == original)
        #expect(reloaded.canLoadSavedCredential)
    }

    @MainActor
    @Test func explicitlyLoadedReadinessAndPreviewRemainCacheOnly() throws {
        let store = FirstRunCredentialSpy()
        var profile = ProviderSettings(cloudEnabled: true, consentGranted: true)
        profile.lastSuccessfulTest = ProviderTestAttestation(
            configuration: profile.configuration, testedAt: Date(),
            credentialFingerprint: ProviderTestAttestation.fingerprint(for: "synthetic-existing-key")
        )
        let controller = ProviderSettingsController(
            settings: profile, credentialStore: store, defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        store.failReads = true
        for _ in 0..<10 {
            #expect(controller.hasCredential)
            #expect(controller.hasCurrentTestAttestation)
            #expect(controller.maskedCredentialPreview == "••••-key")
        }
        #expect(store.reads == 1)
        #expect(store.writes == 0)
    }

    @MainActor
    @Test func disabledRequestDoesNotReleaseAnAlreadyActiveRequestSlot() throws {
        let store = FirstRunCredentialSpy()
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: store, defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        #expect(controller.beginExternalRequest(requestID: "first") != nil)
        try controller.revokeConsent()
        #expect(controller.beginExternalRequest(requestID: "blocked") == nil)
        #expect(controller.cloudActivity == .active(requestID: "first"))
        try controller.grantConsent()
        #expect(controller.beginExternalRequest(requestID: "second") == nil)
        #expect(store.reads == 2)
    }

    @MainActor
    @Test func transportRejectsOutOfBandReplacementDespiteCachedReadiness() async throws {
        let store = FirstRunCredentialSpy()
        var profile = ProviderSettings(cloudEnabled: true, consentGranted: true)
        profile.lastSuccessfulTest = ProviderTestAttestation(
            configuration: profile.configuration, testedAt: Date(),
            credentialFingerprint: ProviderTestAttestation.fingerprint(for: "synthetic-existing-key")
        )
        let controller = ProviderSettingsController(
            settings: profile, credentialStore: store, defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        #expect(controller.hasCurrentTestAttestation)
        store.key = "synthetic-out-of-band-replacement"
        await #expect(throws: CloudRequestAuthorizationError.connectionTestRequired) {
            _ = try await controller.authorizeCloudRequest(requestID: "changed-key", meetingConsent: true)
        }
        #expect(!controller.hasCurrentTestAttestation)
        #expect(controller.cloudActivity == .idle)
        #expect(store.reads == 2)
        #expect(store.writes == 0)
    }

    // MARK: - Validation

    @Test func httpEndpointsAreRejected() throws {
        let insecure = ProviderSettings(baseURL: URL(string: "http://openrouter.ai/api/v1")!)
        #expect(throws: ProviderSettingsError.endpointNotTLS) {
            _ = try insecure.validated()
        }
    }

    @Test func tlsEndpointsAreAccepted() throws {
        let secure = ProviderSettings(baseURL: URL(string: "https://openrouter.ai/api/v1")!)
        let validated = try secure.validated()
        #expect(validated.baseURL.scheme == "https")
    }

    @Test func timeoutBoundsAreEnforced() throws {
        let tooFast = ProviderSettings(timeout: 0.5)
        #expect(throws: ProviderSettingsError.timeoutOutOfRange) {
            _ = try tooFast.validated()
        }
        let tooSlow = ProviderSettings(timeout: 121)
        #expect(throws: ProviderSettingsError.timeoutOutOfRange) {
            _ = try tooSlow.validated()
        }
        let bounded = try ProviderSettings(timeout: 120).validated()
        #expect(bounded.timeout == 120)
    }

    @Test func providerPresetsMatchDocumentedEndpointsAndModels() {
        #expect(ProviderSettings.defaultTimeout == 120)
        #expect(ProviderPreset.openRouter.defaultBaseURL?.absoluteString == "https://openrouter.ai/api/v1")
        #expect(ProviderPreset.openRouter.defaultModel == "deepseek/deepseek-v4-flash")
        #expect(ProviderPreset.deepSeek.defaultBaseURL?.absoluteString == "https://api.deepseek.com")
        #expect(ProviderPreset.deepSeek.defaultModel == "deepseek-v4-flash")
        #expect(ProviderPreset.custom.defaultBaseURL == nil)
        #expect(ProviderPreset.custom.defaultModel == nil)
    }

    @Test func build18SettingsDecodeWithoutPresetAndGainSafeDefaultModel() throws {
        let legacyJSON = """
        {
          "providerLabel": "OpenRouter",
          "baseURL": "https://openrouter.ai/api/v1",
          "model": "",
          "timeout": 30,
          "cloudEnabled": false,
          "consentGranted": false
        }
        """
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.preset == .openRouter)
        #expect(decoded.model == "deepseek/deepseek-v4-flash")
    }

    @MainActor
    @Test func build23MigratesOnlyTheLegacyBuiltInOpenRouterTimeoutOnce() throws {
        let defaults = freshDefaults()
        var legacy = ProviderSettings(
            timeout: 30,
            cloudEnabled: true,
            consentGranted: true
        )
        legacy.lastSuccessfulTest = ProviderTestAttestation(
            configuration: legacy.configuration,
            testedAt: Date(timeIntervalSince1970: 1),
            credentialFingerprint: ProviderTestAttestation.fingerprint(for: "sk-existing")
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: "research.provider.settings.v1"
        )

        let firstLoad = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-existing"),
            defaults: defaults
        )
        try firstLoad.loadSavedCredential()
        #expect(firstLoad.settings.timeout == 120)
        #expect(firstLoad.hasCurrentTestAttestation)

        var deliberatelyShorter = firstLoad.settings
        deliberatelyShorter.timeout = 30
        try firstLoad.update(deliberatelyShorter)

        let secondLoad = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-existing"),
            defaults: defaults
        )
        #expect(secondLoad.settings.timeout == 30)
    }

    @MainActor
    @Test func build23DoesNotMigrateCustomThirtySecondTimeout() throws {
        let defaults = freshDefaults()
        let custom = ProviderSettings(
            preset: .custom,
            providerLabel: "Custom",
            baseURL: URL(string: "https://custom.example/v1")!,
            model: "custom-model",
            timeout: 30
        )
        defaults.set(
            try JSONEncoder().encode(custom),
            forKey: "research.provider.settings.v1"
        )

        let controller = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: defaults
        )
        #expect(controller.settings.timeout == 30)
    }

    // MARK: - Request Gate

    @Test func gateRequiresCloudConsentAndCredential() throws {
        let none = ProviderSettings(cloudEnabled: false, consentGranted: false)
        #expect(!none.mayStartExternalRequest(hasCredential: true))

        let cloudOnly = ProviderSettings(cloudEnabled: true, consentGranted: false)
        #expect(!cloudOnly.mayStartExternalRequest(hasCredential: true))

        let consented = ProviderSettings(cloudEnabled: true, consentGranted: true)
        #expect(!consented.mayStartExternalRequest(hasCredential: false))
        #expect(consented.mayStartExternalRequest(hasCredential: true))
    }

    // MARK: - Credentials

    @Test func credentialsRoundTripThroughStore() throws {
        let store = InMemoryProviderCredentialStore()
        #expect(try store.readAPIKey() == nil)

        try store.writeAPIKey("sk-test-123")
        #expect(try store.readAPIKey() == "sk-test-123")

        try store.writeAPIKey(nil)
        #expect(try store.readAPIKey() == nil)
    }

    @Test func storeFailuresSurfaceAsKeychainErrors() throws {
        let store = InMemoryProviderCredentialStore()
        store.shouldFail = true
        #expect(throws: ProviderSettingsError.self) {
            _ = try store.readAPIKey()
        }
        #expect(throws: ProviderSettingsError.self) {
            try store.writeAPIKey("x")
        }
    }

    // MARK: - Controller: Save / Delete

    @MainActor
    @Test func saveAndDeleteCredentialUpdateIndicator() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(),
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: freshDefaults()
        )
        #expect(controller.hasCredential == false)

        try controller.saveAPIKey("sk-live-key")
        #expect(controller.hasCredential == true)

        try controller.deleteCredential()
        #expect(controller.hasCredential == false)
    }

    @MainActor
    @Test func deletingCredentialImmediatelyBlocksRequests() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: freshDefaults()
        )
        try controller.saveAPIKey("sk-live-key")
        #expect(controller.beginExternalRequest(requestID: "r1") != nil)

        try controller.deleteCredential()
        #expect(controller.beginExternalRequest(requestID: "r2") == nil,
                "Deleting the credential must immediately block new external requests")
    }

    @MainActor
    @Test func disablingCloudImmediatelyBlocksRequests() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        #expect(controller.beginExternalRequest(requestID: "r1") != nil)

        try controller.update(ProviderSettings(cloudEnabled: false, consentGranted: true))
        #expect(controller.beginExternalRequest(requestID: "r2") == nil,
                "Disabling cloud must immediately block new external requests")
    }

    // MARK: - Consent

    @MainActor
    @Test func consentGateBlocksUntilGranted() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: false),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        #expect(controller.beginExternalRequest(requestID: "r1") == nil)

        try controller.grantConsent()
        #expect(controller.settings.consentGranted == true)
        #expect(controller.beginExternalRequest(requestID: "r2") != nil)

        try controller.revokeConsent()
        #expect(controller.beginExternalRequest(requestID: "r3") == nil)
    }

    // MARK: - Settings Persistence

    @MainActor
    @Test func settingsPersistAndReloadWithoutCredentials() throws {
        let defaults = freshDefaults()

        let controller = ProviderSettingsController(
            settings: ProviderSettings(model: "gpt-x"),
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: defaults
        )
        try controller.update(ProviderSettings(model: "gpt-y", cloudEnabled: true))

        let reloaded = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: defaults
        )
        #expect(reloaded.settings.model == "gpt-y")
        #expect(reloaded.settings.cloudEnabled == true)

        // Credentials never live in defaults: the persisted blob must not
        // contain any key material even after a key is saved.
        try controller.saveAPIKey("sk-secret-material")
        if let data = defaults.data(forKey: "research.provider.settings.v1") {
            let json = String(data: data, encoding: .utf8) ?? ""
            #expect(!json.contains("sk-secret-material"),
                    "Credential must never appear in settings persistence")
        }
    }

    @MainActor
    @Test func invalidUpdatesLeaveStoredStateUntouched() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(baseURL: URL(string: "https://good.example.com")!),
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: freshDefaults()
        )
        #expect(throws: ProviderSettingsError.endpointNotTLS) {
            try controller.update(ProviderSettings(baseURL: URL(string: "http://bad.example.com")!))
        }
        #expect(controller.settings.baseURL.absoluteString.contains("good.example.com"))
    }

    @MainActor
    @Test func providerOrEndpointChangeClearsCredentialButModelChangeDoesNot() throws {
        let store = InMemoryProviderCredentialStore(initialKey: "sk-original")
        let controller = ProviderSettingsController(
            settings: ProviderSettings(),
            credentialStore: store,
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()

        var modelOnly = controller.settings
        modelOnly.model = "another/model"
        try controller.update(modelOnly)
        #expect(controller.hasCredential)

        try controller.selectPreset(.deepSeek)
        #expect(!controller.hasCredential)
        #expect(try store.readAPIKey() == nil)

        try controller.saveAPIKey("sk-deepseek")
        var newEndpoint = controller.settings
        newEndpoint.baseURL = URL(string: "https://compatible.example/v1")!
        try controller.update(newEndpoint)
        #expect(!controller.hasCredential)
        #expect(try store.readAPIKey() == nil)
    }

    // MARK: - Connection Test

    @MainActor
    @Test func connectionTestRequiresConfiguration() async throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: false),
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: freshDefaults()
        )
        let tester = StubConnectionTester(result: .success(latencyMS: 10))
        let result = await controller.testConnection(using: tester)
        #expect(result == .notConfigured)
        #expect(await tester.callCount == 0, "No network probe without configuration")
    }

    @MainActor
    @Test func connectionTestOutcomesAreDistinguishable() async throws {
        let outcomes: [ProviderConnectionTestResult] = [
            .success(latencyMS: 42),
            .authenticationFailed,
            .timeout,
            .offline,
            .providerError("rate limited"),
        ]
        var descriptions = Set<String>()
        for outcome in outcomes {
            #expect(!outcome.userDescription.isEmpty)
            descriptions.insert(outcome.userDescription)
        }
        #expect(descriptions.count == outcomes.count)
    }

    @MainActor
    @Test func connectionTestUpdatesActivityIndicator() async throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        let failing = StubConnectionTester(result: .timeout)
        _ = await controller.testConnection(using: failing)
        if case .failed = controller.cloudActivity {
            // expected
        } else {
            Issue.record("Expected failed activity after connection test timeout")
        }

        let succeeding = StubConnectionTester(result: .success(latencyMS: 12))
        _ = await controller.testConnection(using: succeeding)
        #expect(controller.cloudActivity == .idle)
    }

    @MainActor
    @Test func successfulConnectionAttestationPersistsAndConfigurationOrKeyChangeClearsIt() async throws {
        let defaults = freshDefaults()
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-tested"),
            defaults: defaults
        )
        try controller.loadSavedCredential()

        let result = await controller.testConnection(
            using: StubConnectionTester(result: .success(latencyMS: 12))
        )
        #expect(result == .success(latencyMS: 12))
        #expect(controller.hasCurrentTestAttestation)

        let reloaded = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-tested"),
            defaults: defaults
        )
        try reloaded.loadSavedCredential()
        #expect(reloaded.hasCurrentTestAttestation)

        var changedTimeout = controller.settings
        changedTimeout.timeout = 60
        try controller.update(changedTimeout)
        #expect(controller.hasCurrentTestAttestation)

        var changedModel = controller.settings
        changedModel.model = "different-model"
        try controller.update(changedModel)
        #expect(!controller.hasCurrentTestAttestation)

        _ = await controller.testConnection(
            using: StubConnectionTester(result: .success(latencyMS: 10))
        )
        #expect(controller.hasCurrentTestAttestation)
        try controller.saveAPIKey("sk-replacement")
        #expect(!controller.hasCurrentTestAttestation)
    }

    @MainActor
    @Test func connectionTestCannotAttestSettingsChangedWhileRequestWasRunning() async throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-before"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        let task = Task {
            await controller.testConnection(using: DelayedSuccessConnectionTester())
        }
        await Task.yield()

        var changed = controller.settings
        changed.model = "changed-while-testing"
        try controller.update(changed)

        let result = await task.value
        #expect(result.isFailure)
        #expect(!controller.hasCurrentTestAttestation)
    }

    @Test func productionProbeUsesConfiguredEndpointModelTimeoutAndNoTranscript() async throws {
        let captured = CapturedProviderRequest()
        let tester = OpenAICompatibleConnectionTester { request in
            captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let content = #"{"segments":[{"index":1,"cleanedText":"Hello everyone."},{"index":2,"cleanedText":"The design draft is ready."},{"index":3,"cleanedText":"Jordan will confirm the schedule."},{"index":4,"cleanedText":"Send a status note today."},{"index":5,"cleanedText":"Simplify the opening paragraph."},{"index":6,"cleanedText":"Morgan will run the final checks."},{"index":7,"cleanedText":"Pause if new issues appear."},{"index":8,"cleanedText":"Share updates in writing."}]}"#
            let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return (data, response)
        }
        let settings = ProviderSettings(
            preset: .deepSeek,
            providerLabel: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-v4-flash",
            timeout: 17,
            cloudEnabled: true,
            consentGranted: true
        )

        let result = await tester.test(settings: settings, apiKey: "secret-key")
        guard case .success = result else {
            Issue.record("Expected successful production probe, got \(result)")
            return
        }
        let request = try #require(captured.get())
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.timeoutInterval == 17)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        let body = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(body.contains("deepseek-v4-flash"))
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == OpenAICompatibleConnectionTester.probePrompt)
        #expect(!body.localizedCaseInsensitiveContains("transcript"))
        #expect(!body.localizedCaseInsensitiveContains("meeting"))
    }

    @Test func productionProbeDistinguishesHTTPAndNetworkFailures() async {
        func tester(status: Int, data: Data = Data()) -> OpenAICompatibleConnectionTester {
            OpenAICompatibleConnectionTester { request in
                (
                    data,
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
        }
        let settings = ProviderSettings(cloudEnabled: true, consentGranted: true)

        #expect(await tester(status: 401).test(settings: settings, apiKey: "x") == .authenticationFailed)
        #expect(await tester(status: 402).test(settings: settings, apiKey: "x")
            == .creditOrRateLimited("The provider reports that credit or billing is unavailable."))
        #expect(await tester(status: 429).test(settings: settings, apiKey: "x")
            == .creditOrRateLimited("The provider rate limit has been reached. Try again later."))
        #expect(await tester(status: 200, data: Data("{}".utf8)).test(settings: settings, apiKey: "x")
            == .malformedResponse)

        let timeout = OpenAICompatibleConnectionTester { _ in throw URLError(.timedOut) }
        let offline = OpenAICompatibleConnectionTester { _ in throw URLError(.notConnectedToInternet) }
        let cancelled = OpenAICompatibleConnectionTester { _ in throw CancellationError() }
        #expect(await timeout.test(settings: settings, apiKey: "x") == .timeout)
        #expect(await offline.test(settings: settings, apiKey: "x") == .offline)
        #expect(await cancelled.test(settings: settings, apiKey: "x") == .cancelled)
    }

    @Test func openRouterStrictCleanupRequestRequiresSchemaCapableRouting() throws {
        let configuration = ProviderConfiguration(
            preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/deepseek-v4-flash",
            timeout: 30
        )
        let request = try OpenAICompatibleCloudModelClient.makeURLRequest(
            CloudChatCompletionRequest(
                messages: [CloudChatMessage(role: .user, content: "synthetic")],
                maxTokens: 100,
                temperature: 0,
                responseFormat: .strictCleanupSchema(itemCount: 2),
                reasoning: .disabled
            ),
            authorization: AuthorizedCloudRequest(
                requestID: "schema-test",
                configuration: configuration,
                apiKey: "test-key"
            )
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let routing = try #require(json["provider"] as? [String: Any])
        #expect(routing["require_parameters"] as? Bool == true)
        #expect(routing["sort"] as? String == "throughput")
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["enabled"] as? Bool == false)
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let wrapper = try #require(format["json_schema"] as? [String: Any])
        #expect(wrapper["strict"] as? Bool == true)
        let schema = try #require(wrapper["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let segments = try #require(properties["segments"] as? [String: Any])
        #expect(segments["minItems"] as? Int == 2)
        #expect(segments["maxItems"] as? Int == 2)
    }

    @Test func directDeepSeekCleanupUsesJSONObjectFormatWithoutOpenRouterRouting() throws {
        let configuration = ProviderConfiguration(
            preset: .deepSeek,
            baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-v4-flash",
            timeout: 30
        )
        let request = try OpenAICompatibleCloudModelClient.makeURLRequest(
            CloudChatCompletionRequest(
                messages: [CloudChatMessage(role: .user, content: "synthetic")],
                maxTokens: 100,
                temperature: 0,
                responseFormat: .jsonObject
            ),
            authorization: AuthorizedCloudRequest(
                requestID: "json-object-test",
                configuration: configuration,
                apiKey: "test-key"
            )
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        #expect(json["provider"] == nil)
        #expect(json["reasoning"] == nil)
    }

    @Test func cloudClientEnforcesConfiguredWallClockTimeout() async throws {
        let configuration = ProviderConfiguration(
            preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/deepseek-v4-flash",
            timeout: 1
        )
        let client = OpenAICompatibleCloudModelClient { request in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        let started = ContinuousClock.now
        await #expect(throws: CloudModelClientError.timeout) {
            _ = try await client.complete(
                CloudChatCompletionRequest(
                    messages: [CloudChatMessage(role: .user, content: "synthetic")],
                    maxTokens: 10,
                    temperature: 0
                ),
                authorization: AuthorizedCloudRequest(
                    requestID: "wall-clock-timeout",
                    configuration: configuration,
                    apiKey: "test-key"
                )
            )
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(2))
    }

    @Test func timeoutDoesNotAwaitCancellationIgnoringTransport() async throws {
        let configuration = ProviderConfiguration(
            preset: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/deepseek-v4-flash",
            timeout: 1
        )
        let gate = CancellationIgnoringTransportGate()
        let client = OpenAICompatibleCloudModelClient { request in
            // `wait` deliberately ignores Task cancellation. A structured
            // task group would keep `complete` suspended until `release`.
            await gate.wait()
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let started = ContinuousClock.now
        await #expect(throws: CloudModelClientError.timeout) {
            _ = try await client.complete(
                CloudChatCompletionRequest(
                    messages: [CloudChatMessage(role: .user, content: "synthetic")],
                    maxTokens: 10,
                    temperature: 0
                ),
                authorization: AuthorizedCloudRequest(
                    requestID: "non-cooperative-timeout",
                    configuration: configuration,
                    apiKey: "test-key"
                )
            )
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(2))

        // Let the deliberately detached test transport finish cleanly. Its
        // late result must be ignored by the one-shot production relay.
        await gate.release()
    }

    // MARK: - Activity Lifecycle

    @MainActor
    @Test func requestLifecycleDrivesActivity() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        let key = controller.beginExternalRequest(requestID: "req-1")
        #expect(key != nil)
        #expect(controller.cloudActivity == .active(requestID: "req-1"))

        controller.endExternalRequest()
        #expect(controller.cloudActivity == .idle)
    }

    @MainActor
    @Test func requestGateAllowsOnlyOneCloudRequestAtATime() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        #expect(controller.beginExternalRequest(requestID: "first") != nil)
        #expect(controller.beginExternalRequest(requestID: "second") == nil)
        #expect(controller.cloudActivity == .active(requestID: "first"))
    }

    @MainActor
    @Test func centralAuthorizationSnapshotsSavedConfigurationAndKey() async throws {
        var configured = ProviderSettings(
            preset: .custom,
            providerLabel: "Custom",
            baseURL: URL(string: "https://saved.example/v2")!,
            model: "saved-model",
            timeout: 44,
            cloudEnabled: true,
            consentGranted: true
        )
        configured.lastSuccessfulTest = ProviderTestAttestation(
            configuration: configured.configuration,
            testedAt: Date(),
            credentialFingerprint: ProviderTestAttestation.fingerprint(for: "saved-key")
        )
        let controller = ProviderSettingsController(
            settings: configured,
            credentialStore: InMemoryProviderCredentialStore(initialKey: "saved-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()

        let authorization = try await controller.authorizeCloudRequest(
            requestID: "cloud-1",
            meetingConsent: true
        )
        #expect(authorization.configuration == configured.configuration)
        #expect(authorization.apiKey == "saved-key")
        #expect(!String(describing: authorization).contains("saved-key"))
        #expect(controller.cloudActivity == .active(requestID: "cloud-1"))

        await controller.finishCloudRequest(requestID: "cloud-1")
        #expect(controller.cloudActivity == .idle)
    }

    @MainActor
    @Test func legacyMeetingRetryUsesTheCurrentLongerTimeoutWithoutChangingProviderIdentity() async throws {
        var current = ProviderSettings(
            timeout: 120,
            cloudEnabled: true,
            consentGranted: true
        )
        current.lastSuccessfulTest = ProviderTestAttestation(
            configuration: current.configuration,
            testedAt: Date(timeIntervalSince1970: 1),
            credentialFingerprint: ProviderTestAttestation.fingerprint(for: "sk-key")
        )
        let controller = ProviderSettingsController(
            settings: current,
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        var legacySnapshot = current.configuration
        legacySnapshot.timeout = 30

        let authorization = try await controller.authorizeCloudRequest(
            requestID: "legacy-timeout-retry",
            meetingConsent: true,
            expectedConfiguration: legacySnapshot
        )
        #expect(authorization.configuration.timeout == 120)
        #expect(authorization.configuration.hasSameProviderIdentity(as: legacySnapshot))
        await controller.finishCloudRequest(requestID: authorization.requestID)
    }

    @MainActor
    @Test func replacingATestedCredentialBlocksAuthorizationUntilRetested() async throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "tested-key"),
            defaults: freshDefaults()
        )
        try controller.loadSavedCredential()
        _ = await controller.testConnection(
            using: StubConnectionTester(result: .success(latencyMS: 5))
        )
        #expect(controller.hasCurrentTestAttestation)

        try controller.saveAPIKey("replacement-key")
        #expect(!controller.hasCurrentTestAttestation)
        await #expect(throws: CloudRequestAuthorizationError.connectionTestRequired) {
            _ = try await controller.authorizeCloudRequest(
                requestID: "replacement",
                meetingConsent: true
            )
        }
        #expect(controller.cloudActivity == .idle)
    }

    @MainActor
    @Test func centralAuthorizationRequiresGlobalAndPerMeetingConsent() async {
        let noGlobal = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: false, consentGranted: false),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "key"),
            defaults: freshDefaults()
        )
        await #expect(throws: CloudRequestAuthorizationError.cloudDisabled) {
            _ = try await noGlobal.authorizeCloudRequest(requestID: "r1", meetingConsent: true)
        }

        let noMeeting = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "key"),
            defaults: freshDefaults()
        )
        await #expect(throws: CloudRequestAuthorizationError.meetingConsentRequired) {
            _ = try await noMeeting.authorizeCloudRequest(requestID: "r2", meetingConsent: false)
        }
        #expect(noMeeting.cloudActivity == .idle)
    }

    // MARK: - Privacy Copy

    @Test func privacyExplanationCoversTextAndAudio() throws {
        let copy = ProviderSettingsController.privacyExplanation
        #expect(copy.contains("never uploaded"))
        #expect(copy.contains("audio") || copy.contains("Audio"))
        #expect(copy.contains("disable") || copy.contains("delete"))
        #expect(copy.contains("transcript") || copy.contains("question"))
    }

    // MARK: - Local-Only Guarantee

    @MainActor
    @Test func localOnlyOperationRequiresNoKeyOrNetwork() throws {
        // With cloud disabled and no credential, every gate refuses, and
        // nothing in the model reaches recording/transcription/export —
        // those facilities have no entry point here at all.
        let controller = ProviderSettingsController(
            settings: ProviderSettings(cloudEnabled: false, consentGranted: false),
            credentialStore: InMemoryProviderCredentialStore(),
            defaults: freshDefaults()
        )
        #expect(controller.beginExternalRequest(requestID: "x") == nil)
        #expect(controller.settings.mayStartExternalRequest(hasCredential: false) == false)
    }
    // MARK: - #310 masked key preview

    @Test func maskedPreviewNilForNilAndEmptyKeys() {
        #expect(ProviderSettings.maskedKeyPreview(nil) == nil)
        #expect(ProviderSettings.maskedKeyPreview("") == nil)
        #expect(ProviderSettings.maskedKeyPreview("   ") == nil)
    }

    @Test func maskedPreviewShowsOnlyLastFour() {
        #expect(ProviderSettings.maskedKeyPreview("sk-abcdef123456") == "••••3456")
        #expect(ProviderSettings.maskedKeyPreview("sk-test-1234") == "••••1234")
    }

    @Test func maskedPreviewNeverLeaksPrefixForShortKeys() {
        // A 4-char key shows just bullets + its own length class, no usable secret.
        let preview = ProviderSettings.maskedKeyPreview("abcd")
        #expect(preview == "••••abcd")
    }

    @Test func maskedPreviewThroughStoreNeverReturnsRawKey() {
        let store = InMemoryProviderCredentialStore()
        try? store.writeAPIKey("sk-supersecret-value-9988")
        let key = try? store.readAPIKey()
        let preview = ProviderSettings.maskedKeyPreview(key)
        #expect(preview == "••••9988")
        #expect(preview != "sk-supersecret-value-9988")
    }

}

private actor CancellationIgnoringTransportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
