import SwiftUI
import Testing
@testable import OpenBridgeApp

private final class PassiveViewCredentialSpy: ProviderCredentialStore, @unchecked Sendable {
    var reads = 0
    func readAPIKey() throws -> String? { reads += 1; return "synthetic-key-not-for-display" }
    func writeAPIKey(_ key: String?) throws { Issue.record("Rendering must not write credentials") }
}

@Suite(.serialized) @MainActor struct ProviderSettingsViewTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "provider-view-\(UUID().uuidString)")!
    }

    @Test(arguments: [false, true])
    func passiveCloudSetupRendersWithoutKeychain(savedProfile: Bool) async throws {
        let defaults = freshDefaults()
        if savedProfile {
            defaults.set(try JSONEncoder().encode(ProviderSettings()), forKey: "research.provider.settings.v1")
        }
        let store = PassiveViewCredentialSpy()
        let controller = ProviderSettingsController(credentialStore: store, defaults: defaults)
        let drafts = ProviderSettingsDrafts()
        drafts.synchronize(with: controller.settings)
        let view = ProviderSettingsView(drafts: drafts).environmentObject(controller)
            .padding(24).frame(width: 720).background(Color.white).preferredColorScheme(.light)
        // NSHostingView renders AppKit-backed secure fields and pickers. SwiftUI's
        // ImageRenderer alone replaces those controls with unsupported placeholders.
        let host = NSHostingView(rootView: view)
        host.setFrameSize(.init(width: 720, height: 1_180))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderOut(nil)
        defer { window.contentView = nil }
        try await settleNativeLayout(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 2_000)
        #expect(store.reads == 0)
        #expect(!controller.hasCredential)
        #expect(controller.canLoadSavedCredential == savedProfile)
        if let path = ProcessInfo.processInfo.environment["OPENBRIDGE_CLOUD_SETUP_SCREENSHOTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(savedProfile ? "saved-cloud-profile.png" : "first-run-cloud-setup.png"))
        }
    }

    @Test func settingsViewRenders() throws {
        let controller = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(), defaults: freshDefaults()
        )
        let view = ProviderSettingsView()
            .environmentObject(controller)
        let renderer = ImageRenderer(content: view.frame(width: 720, height: 860))
        #expect(renderer.nsImage != nil)
    }

    @Test func settingsViewRendersAtNarrowWidth() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-example-1234"),
            defaults: freshDefaults()
        )
        let view = ProviderSettingsView()
            .environmentObject(controller)
        let renderer = ImageRenderer(content: view.frame(width: 420, height: 1_100))
        #expect(renderer.nsImage != nil)
    }

    @Test func controllerMaskedPreviewNilWithoutKey() {
        let controller = ProviderSettingsController(
            credentialStore: InMemoryProviderCredentialStore(), defaults: freshDefaults()
        )
        #expect(controller.maskedCredentialPreview == nil)
    }

    @Test func controllerMaskedPreviewShowsLastFour() throws {
        let controller = ProviderSettingsController(
            settings: ProviderSettings(),
            credentialStore: InMemoryProviderCredentialStore(initialKey: "sk-live-key-42"),
            defaults: freshDefaults()
        )
        #expect(controller.maskedCredentialPreview == nil)
        try controller.loadSavedCredential()
        #expect(controller.maskedCredentialPreview == "••••y-42")
        #expect(controller.hasCredential)
    }
}
