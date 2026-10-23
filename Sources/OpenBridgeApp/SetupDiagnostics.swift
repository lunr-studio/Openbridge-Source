import Foundation

struct SetupDiagnosticsSnapshot: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let privacy: SetupDiagnosticsPrivacy
    let app: SetupDiagnosticsApp
    let readiness: SetupDiagnosticsReadiness
    let permissions: [SetupDiagnosticsPermission]
    let speechModel: SetupDiagnosticsSpeechModel
    let localAI: SetupDiagnosticsLocalAI
    let microphone: SetupDiagnosticsMicrophone
    let transcription: SetupDiagnosticsTranscription
    let media: SetupDiagnosticsMedia
    let shortcuts: [SetupDiagnosticsShortcut]
    let history: SetupDiagnosticsHistory
    let activity: SetupDiagnosticsActivity
}

struct SetupDiagnosticsPrivacy: Encodable {
    let summary: String
    let includedData: [String]
    let excludedData: [String]
}

struct SetupDiagnosticsApp: Encodable {
    let displayName: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let installLocation: String
    let installLocationDetail: String
    let bundlePath: String
    let launchAtLogin: Bool
    let onboardingCompleted: Bool
}

struct SetupDiagnosticsReadiness: Encodable {
    let readyForDictation: Bool
    let readyForMediaTranscription: Bool
    let missingPermissions: [String]
    let selectedModelInstalled: Bool
    let modelReadinessSummary: String?
    let modelReadinessChecks: [SetupDiagnosticsReadinessCheck]
    let setupMessage: String
}

struct SetupDiagnosticsReadinessCheck: Encodable {
    let id: String
    let title: String
    let state: String
    let message: String
    let recovery: String?
    let blocking: Bool
}

struct SetupDiagnosticsPermission: Encodable {
    let id: String
    let title: String
    let state: String
    let needsFollowUp: Bool
    let whyItMatters: String
}

struct SetupDiagnosticsSpeechModel: Encodable {
    let performanceMode: String
    let selectedIdentifier: String
    let selectedDisplayName: String
    let selectedInstalled: Bool
    let installedCount: Int
    let availableCount: Int
    let managedStatus: String
    let isInstalling: Bool
    let isWarmingSelectedModel: Bool
}

struct SetupDiagnosticsLocalAI: Encodable {
    let cleanupMode: String
    let cleanupEnabled: Bool
    let defaultProvider: String?
    let mlxAvailable: Bool?
    let mlxDefaultModel: String?
    let mlxDefaultModelPresent: Bool?
    let ollamaAvailable: Bool?
}

struct SetupDiagnosticsMicrophone: Encodable {
    let selectedName: String
    let selectedIdentifier: String
    let availableInputCount: Int
    let meterLevel: Double
    let diagnosticsMessage: String
    let warning: String?
}

struct SetupDiagnosticsTranscription: Encodable {
    let formattingEnabled: Bool
    let vocabularyCorrectionsEnabled: Bool
    let spokenFormattingCommandsEnabled: Bool
    let pressEnterVoiceCommandEnabled: Bool
}

struct SetupDiagnosticsMedia: Encodable {
    let ready: Bool
    let setupMessage: String
    let ffmpegAvailable: Bool?
    let isTranscribing: Bool
    let lastResultAvailable: Bool
}

struct SetupDiagnosticsShortcut: Encodable {
    let action: String
    let binding: String
}

struct SetupDiagnosticsHistory: Encodable {
    let retentionMode: String
    let retentionChoiceMade: Bool
    let storedItemCount: Int
    let pasteLastAvailable: Bool
}

struct SetupDiagnosticsActivity: Encodable {
    let statusMessage: String
    let isRecording: Bool
    let isTranscribing: Bool
    let isTranscribingMedia: Bool
    let flowBarContext: String
    let flowBarPhase: String
}

extension AppInstallLocationKind {
    var diagnosticLabel: String {
        switch self {
        case .applications:
            return "Applications"
        case .diskImage:
            return "Mounted disk image"
        case .downloads:
            return "Downloads"
        case .other:
            return "Other location"
        }
    }

    var diagnosticDetail: String {
        switch self {
        case .applications:
            return "Openbridge is running from an Applications folder."
        case .diskImage:
            return "Openbridge is running from a mounted DMG. Move it to Applications before granting permissions."
        case .downloads:
            return "Openbridge is running from Downloads. Move it to Applications before setup."
        case .other:
            return "Openbridge is not running from Applications, Downloads, or a mounted DMG."
        }
    }
}

extension FlowBarContext {
    var diagnosticLabel: String {
        switch self {
        case .dictation:
            return "Dictation"
        case .handsFree:
            return "Hands-free dictation"
        case .commandMode:
            return "Command Mode"
        }
    }
}

extension FlowBarPhase {
    var diagnosticLabel: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .success:
            return "Success"
        case .cancelled:
            return "Cancelled"
        case .error:
            return "Error"
        }
    }
}
