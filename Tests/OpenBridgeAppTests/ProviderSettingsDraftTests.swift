import Foundation
import Testing
@testable import OpenBridgeApp

@MainActor
@Suite struct ProviderSettingsDraftTests {
    @Test func reopeningCloudAITabKeepsUnsavedConfigurationAndKey() throws {
        let saved = ProviderSettings()
        let owner = ProviderSettingsDrafts()
        let firstEditor = ProviderSettingsView(drafts: owner)
        let firstDrafts = try #require(firstEditor.drafts)
        firstDrafts.synchronize(with: saved)
        firstDrafts.endpointDraft = "https://fictional.example/v1"
        firstDrafts.modelDraft = "fictional-model"
        firstDrafts.timeoutDraft = 45
        firstDrafts.keyDraft = "fictional-key-not-sent"
        firstDrafts.showingKeyEntry = true

        // The local tab switch recreates its editor. onAppear and the initial
        // controller publisher each deliver the same saved configuration again.
        let reopenedEditor = ProviderSettingsView(drafts: owner)
        let reopenedDrafts = try #require(reopenedEditor.drafts)
        reopenedDrafts.synchronize(with: saved)
        reopenedDrafts.synchronize(with: saved)
        #expect(reopenedDrafts === firstDrafts)
        #expect(reopenedDrafts.endpointDraft == "https://fictional.example/v1")
        #expect(reopenedDrafts.modelDraft == "fictional-model")
        #expect(reopenedDrafts.timeoutDraft == 45)
        #expect(reopenedDrafts.keyDraft == "fictional-key-not-sent")
        #expect(reopenedDrafts.showingKeyEntry)
    }

    @Test func consentOnlyPublicationDoesNotEraseConfigurationDrafts() {
        var saved = ProviderSettings()
        let owner = ProviderSettingsDrafts()
        owner.synchronize(with: saved)
        owner.modelDraft = "unsaved-model"
        owner.endpointDraft = "https://fictional.example/v1"
        saved.cloudEnabled = true
        saved.consentGranted = true
        owner.synchronize(with: saved)
        #expect(owner.modelDraft == "unsaved-model")
        #expect(owner.endpointDraft == "https://fictional.example/v1")
    }

    @Test func persistedConfigurationChangeStillRefreshesTheEditor() {
        var saved = ProviderSettings()
        let owner = ProviderSettingsDrafts()
        owner.synchronize(with: saved)
        owner.modelDraft = "unsaved-model"
        saved.model = "newly-saved-model"
        saved.timeout = 60
        owner.synchronize(with: saved)
        #expect(owner.modelDraft == "newly-saved-model")
        #expect(owner.timeoutDraft == 60)
    }

    @Test func explicitResetRestoresSavedValuesWithoutSavingADraft() {
        let saved = ProviderSettings()
        let owner = ProviderSettingsDrafts()
        owner.synchronize(with: saved)
        owner.endpointDraft = "invalid endpoint"
        owner.modelDraft = "unsaved-model"
        owner.synchronize(with: saved, force: true)
        #expect(owner.endpointDraft == saved.baseURL.absoluteString)
        #expect(owner.modelDraft == saved.model)
    }

    @Test func leavingTheTabClearsTestingStateWhileRetainingEdits() throws {
        let owner = ProviderSettingsDrafts()
        owner.synchronize(with: ProviderSettings())
        owner.modelDraft = "unsaved-model"
        owner.isTesting = true
        owner.cancelConnectionTest()
        let reopened = try #require(ProviderSettingsView(drafts: owner).drafts)
        #expect(!reopened.isTesting)
        #expect(reopened.connectionTask == nil)
        #expect(reopened.statusMessage == "Connection test cancelled.")
        #expect(reopened.modelDraft == "unsaved-model")
    }
}
