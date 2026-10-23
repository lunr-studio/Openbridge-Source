import Foundation
import Darwin

/// Only the separate local review package opts in. Normal application bundles
/// keep their existing credentials and automatic model preparation behavior.
enum OpenBridgeLaunchContext {
    /// Launch Services supplies the review environment before Foundation starts.
    /// A direct executable launch must fail before any normal user store opens.
    static func validateBeforeOpeningStores() {
        guard isIsolatedReview else { return }
        guard let root = Bundle.main.object(forInfoDictionaryKey: "OpenBridgeReviewDataRoot") as? String else { exit(78) }
        let expected = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let actual = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard actual == expected,
              support?.path.hasPrefix(expected.path + "/") == true else {
            fputs("OpenBridge Design: review data isolation was not supplied. Open the .app through Finder.\n", stderr)
            exit(78)
        }
    }

    static var isIsolatedReview: Bool {
        Bundle.main.object(forInfoDictionaryKey: "OpenBridgeIsolatedDesignReview") as? Bool == true
    }

    static var credentialService: String { credentialService(isolatedReview: isIsolatedReview) }

    static func credentialService(isolatedReview: Bool) -> String {
        isolatedReview ? "dev.openbridge.product-review.providerCredentials" : "dev.openbridge.providerCredentials"
    }
}
