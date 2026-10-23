import Testing
@testable import OpenBridgeApp

struct OpenBridgeLaunchContextTests {
    @Test func reviewDoesNotShareProductionCredentials() {
        #expect(OpenBridgeLaunchContext.credentialService(isolatedReview: false) == "dev.openbridge.providerCredentials")
        #expect(OpenBridgeLaunchContext.credentialService(isolatedReview: true) != OpenBridgeLaunchContext.credentialService(isolatedReview: false))
        #expect(!OpenBridgeLaunchContext.isIsolatedReview)
    }
}
