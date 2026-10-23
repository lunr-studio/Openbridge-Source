import Foundation

enum AppIdentity {
    static let displayName = "Openbridge"
    static let fallbackBundleIdentifier = "studio.lunr.openbridge"
    static let fallbackVersion = "1.2.9"
    static let fallbackBuild = "10"
    static let minimumMacOS = "14.0"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackVersion
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? fallbackBuild
    }

    static var versionLabel: String {
        "\(version) (\(build))"
    }
}

enum AppInstallLocationKind {
    case applications
    case diskImage
    case downloads
    case other
}

struct AppInstallLocationStatus {
    let kind: AppInstallLocationKind
    let bundleURL: URL

    var needsInstallReminder: Bool {
        kind == .diskImage || kind == .downloads
    }

    var reminderTitle: String {
        "Move Openbridge to Applications first"
    }

    var reminderSubtitle: String {
        switch kind {
        case .diskImage:
            return "This copy is running from the downloaded disk image. Drag Openbridge to Applications. Then open it from there before granting permissions."
        case .downloads:
            return "This copy is running from Downloads. Move Openbridge to Applications. Then open it from there before setup."
        case .applications, .other:
            return ""
        }
    }
}

enum AppInstallLocation {
    static var current: AppInstallLocationStatus {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let path = bundleURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
        let homeApplications = home.appendingPathComponent("Applications", isDirectory: true).standardizedFileURL
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL

        let kind: AppInstallLocationKind
        if isInside(bundleURL, directory: systemApplications) || isInside(bundleURL, directory: homeApplications) {
            kind = .applications
        } else if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            kind = .diskImage
        } else if isInside(bundleURL, directory: downloads) {
            kind = .downloads
        } else {
            kind = .other
        }

        return AppInstallLocationStatus(kind: kind, bundleURL: bundleURL)
    }

    private static func isInside(_ child: URL, directory: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return childPath == directoryPath || childPath.hasPrefix(directoryPath + "/")
    }
}
