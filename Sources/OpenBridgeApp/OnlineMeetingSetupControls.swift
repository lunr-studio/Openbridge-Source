import SwiftUI
import OpenBridgeUI
import AppKit
import CoreGraphics

struct OnlineMeetingSetupControls: View {
    @Binding var selection: MeetingAudioSelection
    @Binding var hasPermission: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Record audio from", selection: $selection) {
                ForEach(MeetingAudioSelection.allCases) { choice in
                    Text(choice.title).tag(choice).disabled(choice.includesMacAudio && !supportsMacAudio)
                }
            }.pickerStyle(.menu)
            Text(selection.notice).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgeTheme.mutedInk)
            if !supportsMacAudio {
                Text("Mac audio capture requires macOS 15 or later. Microphone recording remains available.")
                    .font(OpenBridgeTypography.metadata)
            } else if selection.includesMacAudio {
                if hasPermission {
                    Label("Permission granted · check the Mac audio meter after Start", systemImage: "checkmark.shield")
                        .font(OpenBridgeTypography.metadata)
                } else {
                    Text("Allow Screen & System Audio Recording to capture other participants. You may need to restart Openbridge after granting access.")
                        .font(OpenBridgeTypography.metadata)
                    HStack {
                        Button("Request access") { hasPermission = CGRequestScreenCaptureAccess() }
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Check again") { hasPermission = CGPreflightScreenCaptureAccess() }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Button("Choose microphone only instead") { selection = .microphone }.controlSize(.small)
                }
            }
        }
        .onChange(of: selection) { _, _ in hasPermission = CGPreflightScreenCaptureAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = CGPreflightScreenCaptureAccess()
        }
    }
    private var supportsMacAudio: Bool {
        if #available(macOS 15, *) { true } else { false }
    }
}
