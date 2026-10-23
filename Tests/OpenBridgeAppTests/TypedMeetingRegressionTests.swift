import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) @MainActor struct TypedMeetingRegressionTests {
    @Test func localCleanupCanCoexistWithCloudQuestions() throws {
        let snapshot = try MeetingIntelligenceConfigurationResolver.snapshot(cleanupEnabled: true,
            aiMode: .cloudOptIn, providerSettings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            hasCredential: true, providerWasTested: true, cleanupProvider: .localGemma)
        #expect(snapshot.cleanupEnabled && snapshot.cleanupProvider == .localGemma)
        #expect(snapshot.cloudProvider != nil)
    }
    @Test func cloudCleanupCannotBypassMeetingConsent() {
        #expect(throws: CloudRequestAuthorizationError.meetingConsentRequired) {
            try MeetingIntelligenceConfigurationResolver.snapshot(cleanupEnabled: true, aiMode: .localOnly,
                providerSettings: ProviderSettings(cloudEnabled: true, consentGranted: true),
                hasCredential: true, providerWasTested: true, cleanupProvider: .cloud)
        }
    }
    @Test func cloudPermissionDoesNotRequireAutomaticCleanup() throws {
        let settings = ProviderSettings(cloudEnabled: true, consentGranted: true)
        let snapshot = try MeetingIntelligenceConfigurationResolver.snapshot(
            cleanupEnabled: false, aiMode: .cloudOptIn, providerSettings: settings,
            hasCredential: true, providerWasTested: true)
        #expect(!snapshot.cleanupEnabled)
        #expect(snapshot.cloudProvider != nil)
    }

    @Test func cleanupOffStillRequiresTestedCloudPermission() throws {
        let settings = ProviderSettings(cloudEnabled: true, consentGranted: true)
        #expect(throws: CloudRequestAuthorizationError.connectionTestRequired) {
            _ = try MeetingIntelligenceConfigurationResolver.snapshot(
                cleanupEnabled: false, aiMode: .cloudOptIn, providerSettings: settings,
                hasCredential: true, providerWasTested: false)
        }
    }
}
