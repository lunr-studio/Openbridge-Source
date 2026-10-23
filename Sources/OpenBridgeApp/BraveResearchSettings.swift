import Combine
import Foundation
import SwiftUI
import OpenBridgeUI

/// Credentials are loaded only by a deliberate settings action. Saving a key
/// does not authorize any query; each search still needs its own approval.
@MainActor
final class BraveResearchSettings: ObservableObject, WebResearchGate {
    @Published private(set) var hasCredential = false
    @Published private(set) var message = "Save or load your Brave key for this session."
    private let store: any ProviderCredentialStore
    private let transport: BraveLLMContextProvider.Transport
    private var key: String?
    private var generation = UUID()

    init(store: any ProviderCredentialStore = KeychainProviderCredentialStore(
        service: OpenBridgeLaunchContext.credentialService, account: "braveSearchAPIKey"),
         transport: @escaping BraveLLMContextProvider.Transport = BraveLLMContextProvider.send) {
        self.store = store; self.transport = transport
    }

    func save(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 1_024, !value.contains(where: \.isWhitespace) else {
            message = "Enter a valid Brave API key."; return
        }
        do {
            try store.writeAPIKey(value)
            key = value; hasCredential = true; generation = UUID()
            message = "Brave key saved in Keychain. No search has been sent."
        } catch { message = "The Brave key could not be saved in Keychain." }
    }
    func load() {
        generation = UUID(); key = nil; hasCredential = false
        do {
            key = try store.readAPIKey()
            hasCredential = key?.isEmpty == false
            message = hasCredential ? "Brave key loaded for this session. No search has been sent." : "No Brave key is saved."
        } catch { message = "The Brave key could not be loaded from Keychain." }
    }
    func remove() {
        generation = UUID(); key = nil; hasCredential = false
        do { try store.writeAPIKey(nil); message = "Brave key removed. Web research is off." }
        catch { message = "Web research is off for this session. Keychain deletion failed; try Remove again." }
    }

    func settings() async -> ProviderSettings {
        var settings = ProviderSettings()
        settings.cloudEnabled = true
        return settings
    }
    func hasCredential() async -> Bool { hasCredential }
    func networkReachable() async -> Bool { true } // The transport reports real connectivity failures.

    func research(_ question: AuthorizedWebQuestion) async throws -> WebResearchServiceResult {
        let token = generation
        let provider = BraveLLMContextProvider(credential: { [weak self] in
            try await MainActor.run {
                guard let self, self.generation == token, let key = self.key else { throw WebResearchError.missingCredential }
                return key
            }
        }, transport: transport)
        let result = try await WebResearchService(webProvider: provider, gate: self).research(question)
        try Task.checkCancellation()
        guard token == generation, hasCredential else { throw WebResearchError.missingCredential }
        return result
    }
}

struct BraveResearchSettingsView: View {
    @ObservedObject var settings: BraveResearchSettings
    @State private var keyDraft = ""
    var body: some View {
        MainInfoCard("Web research with Brave", systemImage: "globe") {
            Text("Add your own Brave Search API key with LLM Context access. Review and approve each query in Meeting Intelligence. Only that query goes to Brave; retrieved excerpts go to your configured cloud AI for a cited answer.")
                .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
            SecureField("Brave Search API key", text: $keyDraft).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Brave key") { settings.save(keyDraft); keyDraft = "" }.disabled(keyDraft.isEmpty)
                Button("Load saved Brave key") { settings.load() }
                Button("Remove Brave key", role: .destructive) { settings.remove(); keyDraft = "" }
            }
            Text(settings.message).font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
            Text("Brave has its own usage charges and data policy. A normal API key does not establish zero data retention. Avoid private information in search queries.")
                .font(OpenBridgeTypography.body(size: 13)).foregroundStyle(OpenBridgeTheme.mutedInk)
        }
        .onDisappear { keyDraft = "" }
    }
}
