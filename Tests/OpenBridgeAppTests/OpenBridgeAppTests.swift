import Testing
import Foundation

@Suite struct OpenBridgeAppTestSuite {
    @Test func swiftPMTestTargetCompiles() {
        #expect(1 == 1)
    }
}