import Foundation

enum FeedbackSupport {
    static let emailAddress = "team@lunr.studio"
    static let subject = "Openbridge beta feedback"

    static let privacyBoundary = """
    Openbridge does not send telemetry in the background. No transcript, audio, screenshots, diagnostics, snippets, media files, or dictation history are attached unless you explicitly add them.
    """

    static func emailBody() -> String {
        let compatibility = MacCompatibility.current
        let installLocation = AppInstallLocation.current

        return """
        Openbridge beta feedback

        Privacy note:
        \(privacyBoundary)

        What I was trying to do:

        What happened:

        What I expected:

        Can I reproduce it?

        App version:
        \(AppIdentity.displayName) \(AppIdentity.versionLabel)

        Mac:
        \(compatibility.macOSVersionLabel), \(compatibility.chipKind.label)

        Install location:
        \(installLocation.kind.diagnosticLabel)

        Optional System Check:
        If you choose to include setup details, run Settings > Support and diagnostics > System Check, press Copy, and paste the summary below. The System Check summary excludes audio, transcript text, selected text, snippets, media contents, saved dictation history contents, credentials, and private keys.

        """
    }

    static func mailtoURL() -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: emailBody()),
        ]
        return components.url
    }
}
