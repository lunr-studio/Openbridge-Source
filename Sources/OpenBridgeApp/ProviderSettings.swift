import CryptoKit
import Foundation

// MARK: - Provider Settings (#310 / EXT-02)
//
// Provider label, base URL, model, timeout, and API key for the opt-in
// cloud path (#296 provider abstraction).
//
// Guarantees:
//   - Credentials live in the Keychain behind a protocol — never in
//     UserDefaults, settings files, manifests, or logs.
//   - TLS-only endpoints and explicit timeouts are enforced at the model
//     boundary.
//   - Explicit consent is required before any external request gate opens.
//   - Disabling cloud immediately blocks new external requests.
//   - Everything (recording, transcription, history, retrieval, export)
//     stays fully functional with no key and no network.

// MARK: - Errors

enum ProviderSettingsError: LocalizedError, Equatable {
    case endpointNotTLS
    case invalidEndpoint
    case modelRequired
    case timeoutOutOfRange
    case keychainFailure(String)
    case consentRequired

    var errorDescription: String? {
        switch self {
        case .endpointNotTLS:
            return "The provider endpoint must use HTTPS."
        case .invalidEndpoint:
            return "The provider endpoint is not a valid URL."
        case .modelRequired:
            return "Enter the model name supplied by your provider."
        case .timeoutOutOfRange:
            return "The timeout must be between 1 and 120 seconds."
        case .keychainFailure(let detail):
            return "Keychain operation failed: \(detail)"
        case .consentRequired:
            return "Explicit consent is required before external requests."
        }
    }
}

// MARK: - Settings Model

/// The supported starting points for an OpenAI-compatible cloud provider.
/// Presets only fill non-secret configuration; the user always supplies
/// their own credential and explicitly authorizes cloud use.
enum ProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter
    case deepSeek
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek"
        case .custom: return "Custom"
        }
    }

    var defaultBaseURL: URL? {
        switch self {
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1")
        case .deepSeek:
            return URL(string: "https://api.deepseek.com")
        case .custom:
            return nil
        }
    }

    var defaultModel: String? {
        switch self {
        case .openRouter: return "deepseek/deepseek-v4-flash"
        case .deepSeek: return "deepseek-v4-flash"
        case .custom: return nil
        }
    }

    static func infer(providerLabel: String, baseURL: URL) -> ProviderPreset {
        let host = baseURL.host?.lowercased()
        if host == "openrouter.ai" || providerLabel.caseInsensitiveCompare("OpenRouter") == .orderedSame {
            return .openRouter
        }
        if host == "api.deepseek.com" || providerLabel.caseInsensitiveCompare("DeepSeek") == .orderedSame {
            return .deepSeek
        }
        return .custom
    }
}

/// Provider-neutral, non-secret configuration used by connection tests and,
/// in the following delivery slice, every production chat-completions call.
struct ProviderConfiguration: Codable, Equatable, Sendable {
    var preset: ProviderPreset
    var baseURL: URL
    var model: String
    var timeout: TimeInterval

    func validated() throws -> ProviderConfiguration {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw ProviderSettingsError.endpointNotTLS
        }
        guard baseURL.host?.isEmpty == false else {
            throw ProviderSettingsError.invalidEndpoint
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderSettingsError.modelRequired
        }
        guard timeout >= 1 && timeout <= 120 else {
            throw ProviderSettingsError.timeoutOutOfRange
        }
        return self
    }

    var chatCompletionsURL: URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.lowercased().hasSuffix("chat/completions") {
            return baseURL
        }
        return baseURL
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions", isDirectory: false)
    }

    /// Endpoint/model identity used for provider-drift protection. Timeout is
    /// an execution preference, not a provider switch, and a trailing slash
    /// does not identify a different host.
    func hasSameProviderIdentity(as other: ProviderConfiguration) -> Bool {
        preset == other.preset
            && normalizedIdentityURL == other.normalizedIdentityURL
            && model.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedIdentityURL: String {
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// A non-secret record that the provider identity passed Test Connection.
/// Replacing the credential or changing the provider/endpoint/model invalidates
/// it, so cleanup cannot rely on stale readiness. Timeout remains an execution
/// preference and may be increased without sending data to a different host.
struct ProviderTestAttestation: Codable, Equatable, Sendable {
    let configuration: ProviderConfiguration
    let testedAt: Date
    /// One-way binding to the exact tested Keychain value. API keys are
    /// high-entropy secrets; this domain-separated digest is sufficient to
    /// detect replacement without persisting or exposing the credential.
    let credentialFingerprint: String?

    init(
        configuration: ProviderConfiguration,
        testedAt: Date,
        credentialFingerprint: String? = nil
    ) {
        self.configuration = configuration
        self.testedAt = testedAt
        self.credentialFingerprint = credentialFingerprint
    }

    static func fingerprint(for apiKey: String) -> String {
        let payload = Data("openbridge-provider-credential-v1:\(apiKey)".utf8)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Non-secret provider configuration. Persisted in UserDefaults (contains
/// no credential material).
struct ProviderSettings: Codable, Equatable, Sendable {
    var preset: ProviderPreset
    var providerLabel: String
    var baseURL: URL
    var model: String
    /// Request timeout in seconds (1–120, enforced on save).
    var timeout: TimeInterval
    /// Master switch: when false, no new external request may start.
    var cloudEnabled: Bool
    /// Explicit consent to send transcript/context text to the provider.
    /// Required before the first external request; independent of
    /// cloudEnabled so disabling never silently revokes consent state.
    var consentGranted: Bool
    var lastSuccessfulTest: ProviderTestAttestation?

    /// Build 22's 30-second default passed the tiny capability probe but timed
    /// out on ordinary multi-segment cleanup. Cloud inference latency is not a
    /// connection latency, so new configurations receive the full supported
    /// window. Users can still deliberately choose a shorter value.
    static let defaultTimeout: TimeInterval = 120

    init(
        preset: ProviderPreset = .openRouter,
        providerLabel: String = "OpenRouter",
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        model: String = "deepseek/deepseek-v4-flash",
        timeout: TimeInterval = ProviderSettings.defaultTimeout,
        cloudEnabled: Bool = false,
        consentGranted: Bool = false,
        lastSuccessfulTest: ProviderTestAttestation? = nil
    ) {
        self.preset = preset
        self.providerLabel = providerLabel
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.cloudEnabled = cloudEnabled
        self.consentGranted = consentGranted
        self.lastSuccessfulTest = lastSuccessfulTest
    }

    var configuration: ProviderConfiguration {
        ProviderConfiguration(preset: preset, baseURL: baseURL, model: model, timeout: timeout)
    }

    /// Applies a preset atomically. Custom keeps the current endpoint and
    /// model so the user can edit them without inventing unsafe placeholders.
    func applying(_ preset: ProviderPreset) -> ProviderSettings {
        var updated = self
        updated.preset = preset
        updated.providerLabel = preset.displayName
        if let baseURL = preset.defaultBaseURL {
            updated.baseURL = baseURL
        }
        if let model = preset.defaultModel {
            updated.model = model
        }
        return updated
    }

    /// Validates TLS and timeout invariants.
    func validated() throws -> ProviderSettings {
        _ = try configuration.validated()
        return self
    }

    /// The gate every external request must pass: cloud enabled, consent
    /// granted, and a credential present.
    func mayStartExternalRequest(hasCredential: Bool) -> Bool {
        cloudEnabled && consentGranted && hasCredential
    }

    var hasCurrentTestAttestation: Bool {
        guard let attestation = lastSuccessfulTest else { return false }
        return attestation.configuration.hasSameProviderIdentity(as: configuration)
            && attestation.credentialFingerprint != nil
    }

    func hasCurrentTestAttestation(forAPIKey apiKey: String?) -> Bool {
        guard let apiKey, !apiKey.isEmpty,
              let attestation = lastSuccessfulTest,
              attestation.configuration.hasSameProviderIdentity(as: configuration),
              let expectedFingerprint = attestation.credentialFingerprint else {
            return false
        }
        return expectedFingerprint == ProviderTestAttestation.fingerprint(for: apiKey)
    }

    /// #310: Redacted preview of a stored API key for settings UI display —
    /// never exposes more than the last 4 characters ("…1234").
    /// Nil/blank key yields nil so callers show "no key stored".
    static func maskedKeyPreview(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "••••\(trimmed.suffix(4))"
    }

    private enum CodingKeys: String, CodingKey {
        case preset, providerLabel, baseURL, model, timeout, cloudEnabled, consentGranted
        case lastSuccessfulTest
    }

    /// Backward-compatible decoding is deliberate: settings written by build
    /// 18 did not contain `preset`, so build 19 infers it without migration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel) ?? "OpenRouter"
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL)
            ?? ProviderPreset.openRouter.defaultBaseURL!
        preset = try container.decodeIfPresent(ProviderPreset.self, forKey: .preset)
            ?? ProviderPreset.infer(providerLabel: providerLabel, baseURL: baseURL)
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        model = decodedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (preset.defaultModel ?? decodedModel)
            : decodedModel
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? Self.defaultTimeout
        cloudEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudEnabled) ?? false
        consentGranted = try container.decodeIfPresent(Bool.self, forKey: .consentGranted) ?? false
        lastSuccessfulTest = try container.decodeIfPresent(
            ProviderTestAttestation.self,
            forKey: .lastSuccessfulTest
        )
    }
}

// MARK: - Keychain Protocol

/// Credential storage abstraction. The production implementation wraps
/// `Security.framework`; tests inject an in-memory version so no test
/// ever touches the real Keychain.
protocol ProviderCredentialStore: Sendable {
    /// Returns the stored API key, or nil when none exists.
    func readAPIKey() throws -> String?
    /// Stores the API key. Pass nil to delete.
    func writeAPIKey(_ key: String?) throws
}

// MARK: - In-Memory Store (tests / preview)

/// Deterministic credential store for tests. Never touches the Keychain.
final class InMemoryProviderCredentialStore: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    /// When set, all operations throw — used to exercise failure paths.
    var shouldFail = false

    init(initialKey: String? = nil) {
        self.key = initialKey
    }

    func readAPIKey() throws -> String? {
        if shouldFail { throw ProviderSettingsError.keychainFailure("injected read failure") }
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func writeAPIKey(_ key: String?) throws {
        if shouldFail { throw ProviderSettingsError.keychainFailure("injected write failure") }
        lock.lock()
        defer { lock.unlock() }
        self.key = key
    }
}

// MARK: - Connection Test Result

/// Distinguishable outcomes for the Test connection action and the
/// cloud activity indicator. None of these carry credential or content.
enum ProviderConnectionTestResult: Equatable, Sendable {
    case success(latencyMS: Int)
    case authenticationFailed
    case creditOrRateLimited(String)
    case timeout
    case offline
    case malformedResponse
    case cancelled
    case busy
    case providerError(String)
    case notConfigured

    var isFailure: Bool {
        switch self {
        case .success: return false
        default: return true
        }
    }

    var userDescription: String {
        switch self {
        case .success(let latency):
            return "Connected (\(latency) ms)."
        case .authenticationFailed:
            return "The API key was rejected."
        case .creditOrRateLimited(let detail):
            return detail
        case .timeout:
            return "The connection timed out."
        case .offline:
            return "No network connection is available."
        case .malformedResponse:
            return "The provider returned a response OpenBridge could not read."
        case .cancelled:
            return "The connection test was cancelled."
        case .busy:
            return "Another cloud request is already running."
        case .providerError(let detail):
            return "The provider reported an error: \(detail)"
        case .notConfigured:
            return "Add an API key and enable cloud first."
        }
    }
}

// MARK: - Connection Tester Protocol

/// Abstraction over the network probe so tests never perform real I/O.
/// The production implementation sends a minimal, non-transcript chat
/// completion with the configured timeout and maps failures to safe outcomes.
protocol ProviderConnectionTester: Sendable {
    func test(settings: ProviderSettings, apiKey: String?) async -> ProviderConnectionTestResult
}

/// Tester used in tests: returns a preconfigured result, records calls.
actor StubConnectionTester: ProviderConnectionTester {
    private let result: ProviderConnectionTestResult
    private(set) var callCount = 0

    init(result: ProviderConnectionTestResult) {
        self.result = result
    }

    func test(settings: ProviderSettings, apiKey: String?) async -> ProviderConnectionTestResult {
        callCount += 1
        return result
    }
}

// MARK: - Activity Indicator Model

/// Per-request cloud activity state for the persistent indicator.
enum CloudRequestActivity: Equatable, Sendable {
    case idle
    case connecting
    case active(requestID: String)
    case failed(kind: String)
}

/// Compatibility name for the already-shipped settings tests and call sites.
typealias ProviderCloudActivity = CloudRequestActivity

/// A one-request authorization snapshot. It contains the credential only in
/// memory and is never persisted, encoded, described, or logged.
struct AuthorizedCloudRequest: Sendable, CustomStringConvertible {
    let requestID: String
    let configuration: ProviderConfiguration
    let apiKey: String

    var description: String {
        "AuthorizedCloudRequest(requestID: \(requestID), provider: \(configuration.preset.rawValue), apiKey: <redacted>)"
    }
}

enum CloudRequestAuthorizationError: LocalizedError, Equatable, Sendable {
    case cloudDisabled
    case globalConsentRequired
    case meetingConsentRequired
    case missingCredential
    case connectionTestRequired
    case invalidConfiguration(String)
    case configurationChanged
    case requestAlreadyActive

    var errorDescription: String? {
        switch self {
        case .cloudDisabled:
            return "Cloud intelligence is disabled in Settings."
        case .globalConsentRequired:
            return "Authorize cloud intelligence in Settings first."
        case .meetingConsentRequired:
            return "This meeting has not authorized a cloud action."
        case .missingCredential:
            return "Load your saved key or enter your own API key in Cloud AI Settings."
        case .connectionTestRequired:
            return "Test this API key successfully in Settings before sending transcript text."
        case .invalidConfiguration(let detail):
            return detail
        case .configurationChanged:
            return "This meeting was configured for a different cloud provider or model. Restore that configuration or clean locally with Gemma."
        case .requestAlreadyActive:
            return "Another cloud request is already running."
        }
    }
}

/// The sole production gate used before transcript or question text may be
/// handed to a cloud model client.
protocol CloudRequestAuthorizing: Sendable {
    func authorizeCloudRequest(
        requestID: String,
        meetingConsent: Bool
    ) async throws -> AuthorizedCloudRequest

    func finishCloudRequest(requestID: String) async
}

extension CloudRequestAuthorizing {
    func authorizeCloudRequest(
        requestID: String,
        meetingConsent: Bool,
        expectedConfiguration: ProviderConfiguration
    ) async throws -> AuthorizedCloudRequest {
        let authorization = try await authorizeCloudRequest(
            requestID: requestID,
            meetingConsent: meetingConsent
        )
        guard authorization.configuration.hasSameProviderIdentity(as: expectedConfiguration) else {
            await finishCloudRequest(requestID: requestID)
            throw CloudRequestAuthorizationError.configurationChanged
        }
        return authorization
    }
}

// MARK: - Controller

/// Owns settings persistence, credential storage, and the request gate.
/// Observable so settings UI and the cloud indicator can bind.
@MainActor
final class ProviderSettingsController: ObservableObject {
    @Published private(set) var settings: ProviderSettings
    @Published private(set) var hasCredential: Bool = false
    /// A saved profile may have a key, but startup must never open Keychain.
    @Published private(set) var canLoadSavedCredential: Bool = false
    @Published private(set) var maskedCredentialPreview: String?
    @Published private(set) var cloudActivity: ProviderCloudActivity = .idle

    private var loadedCredentialFingerprint: String?

    private let credentialStore: any ProviderCredentialStore
    private let defaults: UserDefaults
    private static let settingsKey = "research.provider.settings.v1"
    private static let credentialConfiguredKey = "research.provider.credential-configured.v1"
    private static let build23TimeoutMigrationKey = "research.provider.timeout.build23-migrated"
    private static let legacyDefaultTimeout: TimeInterval = 30

    /// Display readiness uses only the explicitly loaded key's fingerprint.
    /// Transport still rereads and verifies the actual key before every request.
    /// SwiftUI may evaluate this repeatedly, even during local-only recording.
    var hasCurrentTestAttestation: Bool {
        hasCredential && settings.hasCurrentTestAttestation
            && loadedCredentialFingerprint == settings.lastSuccessfulTest?.credentialFingerprint
    }

    init(
        settings: ProviderSettings? = nil,
        credentialStore: any ProviderCredentialStore = InMemoryProviderCredentialStore(),
        defaults: UserDefaults = UserDefaults.standard
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
        var hasSavedProfile = settings != nil

        if let data = defaults.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(ProviderSettings.self, from: data) {
            hasSavedProfile = true
            var loaded = stored
            if !defaults.bool(forKey: Self.build23TimeoutMigrationKey),
               Self.shouldMigrateLegacyOpenRouterTimeout(loaded) {
                // One-time, narrowly scoped correction for the exact built-in
                // OpenRouter preset. Provider, endpoint, model, credential,
                // consent, and attestation remain unchanged.
                loaded.timeout = ProviderSettings.defaultTimeout
                if let encoded = try? JSONEncoder().encode(loaded) {
                    defaults.set(encoded, forKey: Self.settingsKey)
                }
            }
            self.settings = loaded
        } else {
            self.settings = settings ?? ProviderSettings()
        }
        // Mark every initialized profile so a later intentional choice of 30
        // seconds is respected rather than mistaken for the legacy default.
        defaults.set(true, forKey: Self.build23TimeoutMigrationKey)
        // This non-secret hint preserves legacy profiles without probing an
        // unrelated Keychain item on a fresh install. A denied read is not absence.
        canLoadSavedCredential = hasSavedProfile
            && ((defaults.object(forKey: Self.credentialConfiguredKey) as? Bool) ?? true)
    }

    private static func shouldMigrateLegacyOpenRouterTimeout(
        _ settings: ProviderSettings
    ) -> Bool {
        settings.preset == .openRouter
            && settings.timeout == legacyDefaultTimeout
            && settings.baseURL.absoluteString
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .caseInsensitiveCompare("https://openrouter.ai/api/v1") == .orderedSame
            && settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
                == ProviderPreset.openRouter.defaultModel
    }

    // MARK: - Settings Mutation

    /// Validates and persists new settings. Throws on TLS/timeout
    /// violations without touching stored state.
    func update(_ newSettings: ProviderSettings) throws {
        var validated = try newSettings.validated()
        if !settings.configuration.hasSameProviderIdentity(as: validated.configuration) {
            validated.lastSuccessfulTest = nil
        }

        // A credential is scoped to one provider/endpoint identity. Deleting
        // it before committing the new settings prevents a key from ever
        // being sent to a host the user did not originally save it for.
        let identityChanged = settings.preset != validated.preset
            || normalizedEndpoint(settings.baseURL) != normalizedEndpoint(validated.baseURL)
        if identityChanged, canLoadSavedCredential || hasCredential {
            do {
                try credentialStore.writeAPIKey(nil)
                cacheCredentialState(nil)
                canLoadSavedCredential = false
            } catch {
                throw ProviderSettingsError.keychainFailure(String(describing: error))
            }
        }

        settings = validated
        persistSettings()
    }

    func selectPreset(_ preset: ProviderPreset) throws {
        try update(settings.applying(preset))
    }

    // MARK: - Credentials

    /// Called only by the explicit Settings action. No network request, consent
    /// change, provider change or connection test occurs as a side effect.
    func loadSavedCredential() throws {
        guard canLoadSavedCredential else { return }
        do {
            let key = try credentialStore.readAPIKey()
            cacheCredentialState(key)
            canLoadSavedCredential = hasCredential
            persistSettings()
        } catch {
            cacheCredentialState(nil)
            // Retain the saved-key hint so denial/cancellation remains retryable.
            throw ProviderSettingsError.keychainFailure("Access was not granted. Try Load saved key again, enter a replacement, or continue locally.")
        }
    }

    private func cacheCredentialState(_ key: String?) {
        hasCredential = key?.isEmpty == false
        maskedCredentialPreview = ProviderSettings.maskedKeyPreview(key)
        loadedCredentialFingerprint = hasCredential
            ? key.map(ProviderTestAttestation.fingerprint(for:)) : nil
    }

    /// Stores the API key in the Keychain-backed store and refreshes
    /// the credential indicator.
    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentialStore.writeAPIKey(trimmed)
            cacheCredentialState(trimmed)
            canLoadSavedCredential = true
            settings.lastSuccessfulTest = nil
            persistSettings()
        } catch {
            throw ProviderSettingsError.keychainFailure(String(describing: error))
        }
    }

    /// Deletes the credential and immediately blocks external requests.
    func deleteCredential() throws {
        do {
            try credentialStore.writeAPIKey(nil)
            cacheCredentialState(nil)
            canLoadSavedCredential = false
            settings.lastSuccessfulTest = nil
            persistSettings()
        } catch {
            throw ProviderSettingsError.keychainFailure(String(describing: error))
        }
    }

    // MARK: - Consent

    /// Grants explicit consent (the UI presents exactly what text may be
    /// sent and that audio is never uploaded before calling this).
    /// Cloud enablement and consent move together through the single
    /// settings toggle: on = authorized, off = local only.
    func grantConsent() throws {
        var updated = settings
        updated.consentGranted = true
        updated.cloudEnabled = true
        try update(updated)
    }

    func revokeConsent() throws {
        var updated = settings
        updated.consentGranted = false
        updated.cloudEnabled = false
        try update(updated)
    }

    // MARK: - Request Gate

    /// The single gate external request initiators must consult. Returns
    /// the API key when the request may proceed, nil otherwise, and
    /// updates the activity indicator accordingly.
    func beginExternalRequest(requestID: String) -> String? {
        switch cloudActivity {
        case .connecting, .active:
            return nil
        case .idle, .failed:
            break
        }
        guard settings.mayStartExternalRequest(hasCredential: hasCredential) else {
            cloudActivity = .failed(kind: "notConfigured")
            return nil
        }
        let key = (try? credentialStore.readAPIKey()) ?? nil
        cacheCredentialState(key)
        guard settings.mayStartExternalRequest(hasCredential: key?.isEmpty == false),
              let key, !key.isEmpty else {
            cloudActivity = .failed(kind: "notConfigured")
            return nil
        }
        cloudActivity = .active(requestID: requestID)
        return key
    }

    func endExternalRequest() {
        cloudActivity = .idle
    }

    // MARK: - Provider-Neutral Cloud Authorization

    func authorizeCloudRequest(
        requestID: String,
        meetingConsent: Bool
    ) async throws -> AuthorizedCloudRequest {
        guard settings.cloudEnabled else {
            throw CloudRequestAuthorizationError.cloudDisabled
        }
        guard settings.consentGranted else {
            throw CloudRequestAuthorizationError.globalConsentRequired
        }
        guard meetingConsent else {
            throw CloudRequestAuthorizationError.meetingConsentRequired
        }
        guard hasCredential else {
            throw CloudRequestAuthorizationError.missingCredential
        }
        switch cloudActivity {
        case .connecting, .active:
            throw CloudRequestAuthorizationError.requestAlreadyActive
        case .idle, .failed:
            break
        }

        let configuration: ProviderConfiguration
        do {
            configuration = try settings.configuration.validated()
        } catch {
            throw CloudRequestAuthorizationError.invalidConfiguration(error.localizedDescription)
        }
        let key: String?
        do {
            key = try credentialStore.readAPIKey()
            cacheCredentialState(key)
        } catch {
            cacheCredentialState(nil)
            throw CloudRequestAuthorizationError.missingCredential
        }
        guard let key, !key.isEmpty else {
            throw CloudRequestAuthorizationError.missingCredential
        }
        guard settings.hasCurrentTestAttestation(forAPIKey: key) else {
            throw CloudRequestAuthorizationError.connectionTestRequired
        }

        cloudActivity = .active(requestID: requestID)
        return AuthorizedCloudRequest(
            requestID: requestID,
            configuration: configuration,
            apiKey: key
        )
    }

    func finishCloudRequest(requestID: String) async {
        guard case .active(let activeRequestID) = cloudActivity,
              activeRequestID == requestID else { return }
        cloudActivity = .idle
    }

    // MARK: - Connection Test

    /// Cancellable Test connection action. Uses the injected tester (no
    /// real network in tests).
    func testConnection(using tester: any ProviderConnectionTester) async -> ProviderConnectionTestResult {
        guard settings.cloudEnabled, settings.consentGranted, hasCredential else {
            return .notConfigured
        }
        switch cloudActivity {
        case .connecting, .active:
            return .busy
        case .idle, .failed:
            break
        }
        let key = (try? credentialStore.readAPIKey()) ?? nil
        cacheCredentialState(key)
        guard let key, !key.isEmpty else { return .notConfigured }
        cloudActivity = .connecting
        let testedSettings = settings
        let testedConfiguration = settings.configuration
        let testedKey = key
        var result = await tester.test(settings: testedSettings, apiKey: testedKey)
        if case .success = result {
            let currentKey = (try? credentialStore.readAPIKey()) ?? nil
            cacheCredentialState(currentKey)
            guard settings.configuration.hasSameProviderIdentity(as: testedConfiguration),
                  currentKey == testedKey,
                  settings.mayStartExternalRequest(hasCredential: currentKey?.isEmpty == false) else {
                result = .providerError("Settings or the API key changed during the test. Test again.")
                cloudActivity = .failed(kind: "configurationChanged")
                return result
            }
            settings.lastSuccessfulTest = ProviderTestAttestation(
                configuration: testedConfiguration,
                testedAt: Date(),
                credentialFingerprint: ProviderTestAttestation.fingerprint(for: testedKey)
            )
            persistSettings()
        }
        cloudActivity = result == .cancelled || !result.isFailure
            ? .idle
            : .failed(kind: "\(result)")
        return result
    }

    // MARK: - Privacy Copy

    /// The exact privacy explanation the settings UI must display.
    nonisolated static let privacyExplanation = """
        When cloud intelligence is enabled and you consent, OpenBridge may \
        send the text of your question and selected transcript passages to \
        the configured provider. Meeting audio is never uploaded. You can \
        disable cloud or delete the API key at any time; recording, \
        transcription, history, retrieval, and export keep working fully \
        offline. Your provider's own terms, data handling, and charges may
        apply to every request.
        """

    private func normalizedEndpoint(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func persistSettings() {
        defaults.set(canLoadSavedCredential, forKey: Self.credentialConfiguredKey)
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}

extension ProviderSettingsController: CloudRequestAuthorizing {}
