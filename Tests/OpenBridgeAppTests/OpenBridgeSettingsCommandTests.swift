import Foundation
import Testing
@testable import OpenBridgeApp

/// Source integration checks complement the native Cmd-comma/menu smoke test.
/// They protect the one Settings destination without requiring a second Scene.
struct OpenBridgeSettingsCommandTests {
    @Test func commandCommaOpensSettingsInTheMainWindow() throws {
        let appSource = try source("OpenBridgeApp.swift")
        let command = try #require(appSource.range(of: "private struct OpenBridgeSettingsCommand: Commands"))
        let commandSource = String(appSource[command.lowerBound...])

        // Other commands may share this scene and the block may span lines.
        // Still require Settings to be registered inside the commands block.
        #expect(appSource.range(
            of: #"\.commands\s*\{\s*OpenBridgeSettingsCommand\(\)"#,
            options: .regularExpression
        ) != nil)
        #expect(commandSource.contains("CommandGroup(replacing: .appSettings)"))
        #expect(commandSource.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        #expect(commandSource.contains("OpenBridgeNavigation.shared.request(.settings)"))
        #expect(commandSource.contains("openWindow(id: \"main\")"))
        #expect(!appSource.contains("Settings {"))
        #expect(!appSource.contains("Window(\"Openbridge Settings\""))
    }

    @Test func menuSettingsUsesTheSameMainWindowRoute() throws {
        let views = try source("Views.swift")
        let start = try #require(views.range(of: "struct MenuContentView: View"))
        let end = try #require(views.range(of: "enum OnboardingLayout"))
        let menuSource = String(views[start.lowerBound..<end.lowerBound])

        #expect(menuSource.contains("openMainWindow(.settings)"))
        #expect(menuSource.contains("OpenBridgeNavigation.shared.request(section)"))
        #expect(menuSource.contains("openWindow(id: \"main\")"))
        #expect(!menuSource.contains("SettingsLink"))
        #expect(!menuSource.contains("openWindow(id: \"settings\")"))
    }

    @Test func externalRequestsUseTheGuardedMainWindowNavigation() throws {
        let mainWindow = try source("MainWindowView.swift")
        let start = try #require(mainWindow.range(of: ".onReceive(navigation.$requestedSection)"))
        let end = try #require(mainWindow.range(of: ".fileImporter(", range: start.upperBound..<mainWindow.endIndex))
        let requestHandler = String(mainWindow[start.lowerBound..<end.lowerBound])

        #expect(requestHandler.contains("navigate(to: section)"))
        #expect(requestHandler.contains("navigation.requestedSection = nil"))
        #expect(!requestHandler.contains("selectedSectionRawValue ="))
        #expect(mainWindow.contains("MeetingHomeNavigation.blocker("))
        #expect(mainWindow.contains("MainSettingsPage(navigate: navigate, initialSection: section.settingsTab)"))
    }

    private func source(_ filename: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/OpenBridgeApp/\(filename)"), encoding: .utf8)
    }
}
