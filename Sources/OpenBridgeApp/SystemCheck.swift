import Foundation

enum SystemCheckState: String {
    case pass
    case warn
    case fail

    var label: String {
        switch self {
        case .pass:
            return "Pass"
        case .warn:
            return "Warn"
        case .fail:
            return "Fail"
        }
    }
}

struct SystemCheckItem: Identifiable {
    let id: String
    let title: String
    let state: SystemCheckState
    let message: String
    let recovery: String?
}

struct SystemCheckReport {
    let generatedAt: Date
    let items: [SystemCheckItem]
    let supportText: String

    var failures: [SystemCheckItem] {
        items.filter { $0.state == .fail }
    }

    var warnings: [SystemCheckItem] {
        items.filter { $0.state == .warn }
    }

    var isReady: Bool {
        failures.isEmpty
    }

    var summary: String {
        if failures.isEmpty && warnings.isEmpty {
            return "Ready. System Check found no setup problems."
        }
        if failures.isEmpty {
            return "Ready with \(warnings.count) note\(warnings.count == 1 ? "" : "s")."
        }
        return "\(failures.count) setup problem\(failures.count == 1 ? "" : "s") need attention."
    }
}

struct HelpAvailabilityStatus {
    let available: Bool
    let message: String
    let recovery: String?
}
