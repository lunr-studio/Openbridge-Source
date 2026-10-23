import AVFoundation
import ApplicationServices
import AppKit
import Foundation

@MainActor
enum PermissionService {
    static func currentStates() -> [PermissionState] {
        [
            PermissionState(kind: .microphone, value: microphoneState()),
            PermissionState(kind: .accessibility, value: accessibilityState()),
            PermissionState(kind: .inputMonitoring, value: inputMonitoringState()),
        ]
    }

    static func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    static func prepareForOpeningSettings(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
            await request(kind)
        case .accessibility, .inputMonitoring:
            await request(kind)
        }
    }

    static func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static func microphoneState() -> PermissionStateValue {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .needsAttention
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static func accessibilityState() -> PermissionStateValue {
        AXIsProcessTrusted() ? .granted : .needsAttention
    }

    private static func inputMonitoringState() -> PermissionStateValue {
        CGPreflightListenEventAccess() ? .granted : .needsAttention
    }
}
