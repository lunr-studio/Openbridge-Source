import AppKit
import SwiftUI
import OpenBridgeUI

@main
struct OpenBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var providerSettings: ProviderSettingsController

    init() {
        OpenBridgeLaunchContext.validateBeforeOpeningStores()
        let providerSettings = ProviderSettingsController(
            credentialStore: KeychainProviderCredentialStore(service: OpenBridgeLaunchContext.credentialService)
        )
        _providerSettings = StateObject(wrappedValue: providerSettings)
        _appState = StateObject(wrappedValue: AppState(providerSettings: providerSettings))
    }

    var body: some Scene {
        Window("Openbridge", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(providerSettings)
                .frame(
                    minWidth: MainWindowLayout.windowMinimumSize.width,
                    minHeight: MainWindowLayout.windowMinimumSize.height
                )
        }
        .defaultSize(
            width: MainWindowLayout.windowPreferredSize.width,
            height: MainWindowLayout.windowPreferredSize.height
        )
        .windowResizability(.contentMinSize)
        .commands {
            OpenBridgeSettingsCommand()
            LocalDictationInsertionCommands()
        }

        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
                .environmentObject(providerSettings)
        } label: {
            OpenBridgeMenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Openbridge Setup", id: "onboarding") {
            OnboardingView()
                .environmentObject(appState)
                .environmentObject(providerSettings)
                .frame(
                    minWidth: OnboardingLayout.windowMinimumSize.width,
                    minHeight: OnboardingLayout.windowMinimumSize.height
                )
        }
        .defaultSize(
            width: OnboardingLayout.windowPreferredSize.width,
            height: OnboardingLayout.windowPreferredSize.height
        )


    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenBridgeHelpController.shared.stop()
    }
}

private struct OpenBridgeMenuBarLabel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenInitialOnboarding = false

    var body: some View {
        HStack(spacing: 5) {
            Image("OpenBridgeMenuBarTemplate")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(AppIdentity.displayName)
        }
        .task {
            guard !didOpenInitialOnboarding else { return }
            didOpenInitialOnboarding = true
            guard appState.shouldShowOnboardingOnLaunch else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
        }
    }
}

private struct OpenBridgeSettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                OpenBridgeNavigation.shared.request(.settings)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
