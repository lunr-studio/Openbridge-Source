import Testing
@testable import OpenBridgeApp

/// Navigation contracts for existing saved routes and the approved grouped sidebar.
struct MainWindowNavigationMappingTests {
    @Test func sidebarOffersFourWorkflowsAndTwoSupportDestinations() {
        #expect(MainWindowSection.primary == [.home, .meetings, .dictation, .transcribe])
        #expect(MainWindowSection.support == [.settings, .help])
        let visible = MainWindowSection.primary + MainWindowSection.support
        #expect(Set(visible).count == visible.count)
        #expect(visible.map(\.title) == ["Home", "Meetings", "Voice typing", "Transcribe", "Settings", "Help"])
    }

    @Test func everySavedRouteHasAVisibleParentAndStableIdentity() {
        let visible = Set(MainWindowSection.primary + MainWindowSection.support)
        for section in MainWindowSection.allCases {
            #expect(visible.contains(section.group), "\(section.rawValue) must retain a visible parent")
            #expect(section.group.group == section.group)
            #expect(MainWindowSection(rawValue: section.rawValue) == section)
        }
        for section in visible {
            #expect(section.group == section)
        }
    }

    @Test func legacyVoiceRoutesSelectTheirOriginalContentWithinVoiceTyping() {
        let routes: [(String, MainWindowSection, MainVoiceTypingTab)] = [
            ("dictation", .dictation, .preferences),
            ("history", .history, .history),
            ("transforms", .transforms, .textActions),
            ("snippets", .snippets, .snippets),
            ("dictionary", .dictionary, .dictionary),
        ]
        for (savedRoute, section, tab) in routes {
            #expect(MainWindowSection(rawValue: savedRoute) == section)
            #expect(section.group == .dictation)
            #expect(section.voiceTab == tab)
            #expect(tab.section == section)
            #expect(section.systemImage == MainWindowSection.dictation.systemImage)
        }
        #expect(MainWindowSection.transforms.title == "Text actions")
        #expect(MainVoiceTypingTab.textActions.title == "Text actions")
    }

    @Test func legacyModelAndSystemCheckRoutesEnterTheirSettingsTab() {
        let routes: [(String, MainWindowSection, MainSettingsSection)] = [
            ("settings", .settings, .general),
            ("models", .models, .models),
            ("systemCheck", .systemCheck, .systemCheck),
        ]
        for (savedRoute, section, tab) in routes {
            #expect(MainWindowSection(rawValue: savedRoute) == section)
            #expect(section.group == .settings)
            #expect(section.settingsTab == tab)
            #expect(section.systemImage == MainWindowSection.settings.systemImage)
        }
        #expect(MainSettingsSection.allCases.map(\.title) == [
            "General", "Models & performance", "Cloud AI", "Privacy & data", "System Check"
        ])
    }

    @Test func youTubeAndFilesShareTranscribeWithoutJoiningDictationHistory() {
        #expect(MainWindowSection.transcribe.group == .transcribe)
        #expect(MainWindowSection.transcribeYouTube.group == .transcribe)
        #expect(MainWindowSection.transcribeYouTube.title == "Transcribe")
        #expect(MainWindowSection.transcribeYouTube.systemImage == MainWindowSection.transcribe.systemImage)
        #expect(MainWindowSection.history.group == .dictation)
        #expect(MainTranscribeTab.allCases == [.files, .youtube])
    }
}
