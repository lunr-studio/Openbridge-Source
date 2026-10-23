import Testing
@testable import OpenBridgeApp

@MainActor
@Suite struct VoiceTypingDraftTests {
    @Test func recreatedTabPagesKeepIndependentUnsavedDrafts() {
        let owner = MainVoiceTypingDrafts()
        let snippets = MainSnippetsPage(drafts: owner)
        snippets.drafts.snippetTriggerPhrase = "my sign off"
        snippets.drafts.snippetExpansionText = "Warmly,\nAlex"
        snippets.drafts.snippetSearchText = "sign"

        // Conditional tab content is reconstructed; its edit/search data lives
        // with the common owner, without mounting any microphone preference UI.
        let dictionary = MainDictionaryPage(drafts: owner)
        dictionary.drafts.dictionaryHeardAs = "open bridge"
        dictionary.drafts.dictionaryReplaceWith = "OpenBridge"
        dictionary.drafts.dictionarySearchText = "bridge"
        let history = MainHistoryPage(drafts: owner)
        history.drafts.historySearchText = "follow up"

        let reopenedSnippets = MainSnippetsPage(drafts: owner)
        let reopenedDictionary = MainDictionaryPage(drafts: owner)
        #expect(reopenedSnippets.drafts.snippetTriggerPhrase == "my sign off")
        #expect(reopenedSnippets.drafts.snippetExpansionText == "Warmly,\nAlex")
        #expect(reopenedSnippets.drafts.snippetSearchText == "sign")
        #expect(reopenedDictionary.drafts.dictionaryHeardAs == "open bridge")
        #expect(reopenedDictionary.drafts.dictionaryReplaceWith == "OpenBridge")
        #expect(reopenedDictionary.drafts.dictionarySearchText == "bridge")
        #expect(MainHistoryPage(drafts: owner).drafts.historySearchText == "follow up")
    }
}
