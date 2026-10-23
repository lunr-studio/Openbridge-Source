import SwiftUI
import OpenBridgeUI

/// The Settings hierarchy owns drafts above its conditional tab content. It can
/// unmount Cloud AI without losing text or leaving a test request running.
@MainActor
final class ProviderSettingsDrafts: ObservableObject {
    @Published var presetDraft: ProviderPreset = .openRouter
    @Published var endpointDraft = ""
    @Published var modelDraft = ""
    @Published var timeoutDraft = Int(ProviderSettings.defaultTimeout)
    @Published var keyDraft = ""
    @Published var showingKeyEntry = false
    @Published var statusMessage: String?
    @Published var isTesting = false
    @Published private(set) var didLoadDrafts = false
    var connectionTask: Task<Void, Never>?
    private var synchronizedSettings: ProviderSettings?

    func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        if isTesting { statusMessage = "Connection test cancelled." }
        isTesting = false
    }

    func synchronize(with settings: ProviderSettings, force: Bool = false) {
        // Consent, key state, and connection attestations may publish settings
        // without changing the editable configuration. Keep in-progress edits.
        let configurationChanged = synchronizedSettings.map {
            $0.preset != settings.preset || $0.baseURL != settings.baseURL
                || $0.model != settings.model || $0.timeout != settings.timeout
        } ?? true
        synchronizedSettings = settings
        guard force || configurationChanged else { return }
        presetDraft = settings.preset
        endpointDraft = settings.baseURL.absoluteString
        modelDraft = settings.model
        timeoutDraft = Int(settings.timeout.rounded())
        didLoadDrafts = true
    }
}

/// Standalone callers receive a local owner; the main Settings hierarchy injects
/// one stable owner for all of its Cloud AI tab appearances.
struct ProviderSettingsView: View {
    @StateObject private var ownedDrafts = ProviderSettingsDrafts()
    let drafts: ProviderSettingsDrafts?
    var braveResearch: BraveResearchSettings? = nil

    init(drafts: ProviderSettingsDrafts? = nil, braveResearch: BraveResearchSettings? = nil) {
        self.drafts = drafts; self.braveResearch = braveResearch
    }

    var body: some View {
        ProviderSettingsEditor(braveResearch: braveResearch, drafts: drafts ?? ownedDrafts)
    }
}

private struct ProviderSettingsEditor: View {
    @EnvironmentObject private var controller: ProviderSettingsController
    @AppStorage(ResearchObservatoryFeatureFlag.key) private var researchRailEnabled = false
    var braveResearch: BraveResearchSettings? = nil
    @ObservedObject var drafts: ProviderSettingsDrafts

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MainInfoCard("Cloud intelligence", systemImage: "brain") {
            Text("Cloud AI is optional. Choose a provider and model, enter your own API key, then authorize and test the connection. Recording and local transcription work without cloud setup.")
                .font(OpenBridgeTypography.body(size: 15))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $drafts.presetDraft) {
                ForEach(ProviderPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: drafts.presetDraft) { _, preset in
                guard drafts.didLoadDrafts, preset != controller.settings.preset else { return }
                applyPreset(preset)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("HTTPS endpoint")
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                TextField("https://provider.example/v1", text: $drafts.endpointDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Cloud provider HTTPS endpoint")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBridgeTheme.ink)
                TextField("Provider model name", text: $drafts.modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Cloud provider model")
            }

            VStack(alignment: .leading, spacing: 4) {
                Stepper(value: $drafts.timeoutDraft, in: 1...120) {
                    HStack {
                        Text("Request timeout")
                        Spacer()
                        Text("\(drafts.timeoutDraft) seconds")
                            .foregroundStyle(OpenBridgeTheme.mutedInk)
                    }
                }

                Text("120 seconds is recommended for transcript cleanup. Shorter limits may fail when a provider is busy.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Save provider settings") {
                saveConfiguration()
            }
            .buttonStyle(.borderedProminent)
            .tint(OpenBridgeTheme.brandTeal)

            Divider()

            credentialControls

            Divider()

            Toggle("Authorize cloud intelligence", isOn: cloudBinding)
                .font(OpenBridgeTypography.body(size: 15, weight: .semibold))

            HStack(spacing: 10) {
                Button(drafts.isTesting ? "Testing…" : "Test Connection") {
                    testConnection()
                }
                .disabled(drafts.isTesting || !controller.settings.mayStartExternalRequest(hasCredential: controller.hasCredential))

                if drafts.isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 0)

                Text(activityLabel)
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(activityColor)
            }

            Text("Test Connection cleans eight fixed synthetic segments—the largest production batch—and may incur a small provider charge. It never sends your meeting text or audio.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if let statusMessage = drafts.statusMessage {
                Text(statusMessage)
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Cloud settings status: \(statusMessage)")
            }

            Text(ProviderSettingsController.privacyExplanation)
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let braveResearch { BraveResearchSettingsView(settings: braveResearch) }

            MainInfoCard("Meeting Intelligence (Beta)", systemImage: "sidebar.right") {
                Toggle("Enable Meeting Intelligence (Beta)", isOn: researchRailBinding)
                    .font(OpenBridgeTypography.body(size: 15, weight: .semibold))

                Text("Type a question in Meeting Intelligence. Relevant excerpts are selected on this Mac, then your tested cloud provider answers. Choose This meeting or expand the search to approved saved meetings. Research permission can be changed during recording, independently of transcript cleanup.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Speaking ‘OpenBridge’ does not submit a question. There are no proactive cloud requests. Web searches require a separate query approval. Recording and transcription remain local.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Only meetings with explicit research permission are eligible. Approving existing saved meetings does not approve future recordings.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Meeting Intelligence Beta settings")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cloud intelligence and Meeting Intelligence settings")
        .onAppear {
            drafts.synchronize(with: controller.settings)
        }
        .onReceive(controller.$settings) { settings in
            guard drafts.didLoadDrafts else { return }
            drafts.synchronize(with: settings)
        }
        .onDisappear {
            drafts.cancelConnectionTest()
        }
    }

    private var researchRailBinding: Binding<Bool> {
        Binding(
            get: { researchRailEnabled },
            set: { enabled in
                researchRailEnabled = enabled
                // AppState is present in the real app. Standalone render
                // tests intentionally have no app lifecycle owner, so the
                // persisted toggle remains safe to render there as well.
                AppState.shared?.setResearchRailEnabled(enabled)
            }
        )
    }

    @ViewBuilder
    private var credentialControls: some View {
        if controller.hasCredential {
            MainFactRow(
                label: "API key",
                value: controller.maskedCredentialPreview ?? "Stored in Keychain"
            )

            HStack(spacing: 10) {
                Button(drafts.showingKeyEntry ? "Cancel" : "Replace") {
                    drafts.keyDraft = ""
                    drafts.showingKeyEntry.toggle()
                }

                Button("Remove", role: .destructive) {
                    removeCredential()
                }
            }
        } else {
            if controller.canLoadSavedCredential {
                Text("Your cloud settings are saved. Load your saved key for this session, or enter a replacement below. macOS may ask for Keychain access when you use or change a saved credential, not simply when Openbridge opens.")
                    .font(OpenBridgeTypography.body(size: 13))
                    .foregroundStyle(OpenBridgeTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Load saved key") {
                        do {
                            try controller.loadSavedCredential()
                            drafts.statusMessage = controller.hasCurrentTestAttestation
                                ? "Saved key loaded. Your previous connection test is still valid; no new test or cloud request is needed."
                                : controller.hasCredential
                                    ? "Saved key loaded. No cloud request was sent."
                                    : "No saved key was found on this Mac. Enter your own provider API key."
                        } catch {
                            drafts.statusMessage = error.localizedDescription
                        }
                    }
                    .accessibilityHint("May ask for Keychain access. Does not send a cloud request.")
                    Button("Remove saved key", role: .destructive) { removeCredential() }
                }
            } else {
                Text("Enter your own provider API key. No key is included with Openbridge.")
                .font(OpenBridgeTypography.body(size: 13))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            }
            keyEntry
        }

        if controller.hasCredential, drafts.showingKeyEntry {
            keyEntry
        }
    }

    private var keyEntry: some View {
        HStack(spacing: 10) {
            SecureField("API key", text: $drafts.keyDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Cloud provider API key")

            Button(controller.hasCredential ? "Save replacement" : "Save key") {
                saveCredential()
            }
            .disabled(drafts.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var cloudBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.cloudEnabled && controller.settings.consentGranted },
            set: { authorized in
                do {
                    if authorized {
                        try controller.grantConsent()
                        drafts.statusMessage = "Cloud intelligence authorized for explicit actions."
                    } else {
                        try controller.revokeConsent()
                        drafts.statusMessage = "Cloud intelligence is off. Local features still work."
                    }
                } catch {
                    drafts.statusMessage = error.localizedDescription
                }
            }
        )
    }

    private var activityLabel: String {
        switch controller.cloudActivity {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .active: return "Cloud active"
        case .failed: return "Needs attention"
        }
    }

    private var activityColor: Color {
        switch controller.cloudActivity {
        case .idle: return OpenBridgeTheme.mutedInk
        case .connecting, .active: return OpenBridgeTheme.brandTeal
        case .failed: return OpenBridgeTheme.brandCoral
        }
    }

    private func applyPreset(_ preset: ProviderPreset) {
        let hadCredential = controller.hasCredential || controller.canLoadSavedCredential
        do {
            try controller.selectPreset(preset)
            drafts.synchronize(with: controller.settings, force: true)
            drafts.statusMessage = hadCredential
                ? "Provider changed. The previous API key was removed for safety."
                : "\(preset.displayName) selected."
        } catch {
            drafts.synchronize(with: controller.settings, force: true)
            drafts.statusMessage = error.localizedDescription
        }
    }

    private func saveConfiguration() {
        guard let endpoint = URL(string: drafts.endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            drafts.statusMessage = ProviderSettingsError.invalidEndpoint.localizedDescription
            return
        }

        let hadCredential = controller.hasCredential || controller.canLoadSavedCredential
        var updated = controller.settings
        updated.preset = drafts.presetDraft
        updated.providerLabel = drafts.presetDraft.displayName
        updated.baseURL = endpoint
        updated.model = drafts.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.timeout = TimeInterval(drafts.timeoutDraft)

        do {
            try controller.update(updated)
            drafts.synchronize(with: controller.settings, force: true)
            drafts.statusMessage = hadCredential && !controller.canLoadSavedCredential
                ? "Endpoint changed. The previous API key was removed for safety."
                : "Provider settings saved."
        } catch {
            drafts.statusMessage = error.localizedDescription
        }
    }

    private func saveCredential() {
        do {
            try controller.saveAPIKey(drafts.keyDraft)
            drafts.keyDraft = ""
            drafts.showingKeyEntry = false
            drafts.statusMessage = "API key saved securely in Keychain."
        } catch {
            drafts.statusMessage = error.localizedDescription
        }
    }

    private func removeCredential() {
        do {
            try controller.deleteCredential()
            drafts.keyDraft = ""
            drafts.showingKeyEntry = false
            drafts.statusMessage = "API key removed."
        } catch {
            drafts.statusMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        drafts.cancelConnectionTest()
        drafts.isTesting = true
        drafts.statusMessage = nil
        drafts.connectionTask = Task {
            let result = await controller.testConnection(using: OpenAICompatibleConnectionTester())
            guard !Task.isCancelled else { return }
            drafts.isTesting = false
            drafts.statusMessage = result.userDescription
        }
    }
}
