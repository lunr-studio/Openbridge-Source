import Testing
import SwiftUI
@testable import OpenBridgeApp
@testable import OpenBridgeUI

@Suite struct MeetingStartGateTests {
    private func gate(
        title: String = "Planning",
        isMeetingRecording: Bool = false,
        isMeetingStopping: Bool = false,
        isMeetingStarting: Bool = false,
        isDictationStarting: Bool = false,
        isRecoveryRetryRunning: Bool = false,
        readyForDictation: Bool = true,
        setupMessage: String = "Finish setup."
    ) -> MeetingStartGate {
        MeetingStartGate(
            title: title,
            isMeetingRecording: isMeetingRecording,
            isMeetingStopping: isMeetingStopping,
            isMeetingStarting: isMeetingStarting,
            isDictationStarting: isDictationStarting,
            isRecoveryRetryRunning: isRecoveryRetryRunning,
            readyForDictation: readyForDictation,
            setupMessage: setupMessage
        )
    }

    @Test func emptyAndWhitespaceNamesExplainTheRequirement() {
        for title in ["", "   ", "\n\t"] {
            let result = gate(title: title)
            #expect(!result.canStart)
            #expect(result.helperText == "Give this meeting a name to enable Start meeting.")
        }
    }

    @Test func readyNamedMeetingCanStart() {
        let result = gate()
        #expect(result.canStart)
        #expect(result.helperText == "Ready to record.")
    }

    @Test func optionalCloudSetupDoesNotDisableTheStartRecoveryAction() {
        let result = MeetingStartGate(
            title: "Planning", isMeetingRecording: false, isMeetingStopping: false,
            isMeetingStarting: false, isDictationStarting: false,
            isRecoveryRetryRunning: false, readyForDictation: true,
            setupMessage: "Ready", cleanupBlocker: "Cloud setup needs attention."
        )
        #expect(result.canStart)
        #expect(result.blockerText == nil)
        #expect(result.helperText == "Cloud setup needs attention.")
    }

    @Test func namedMeetingShowsTheActualSetupBlocker() {
        let result = gate(readyForDictation: false, setupMessage: "Allow microphone access first.")
        #expect(!result.canStart)
        #expect(result.helperText == "Allow microphone access first.")
    }

    @Test func captureAndRecoveryTransitionsStayBlocked() {
        #expect(gate(isMeetingRecording: true).helperText == "A meeting is already recording.")
        #expect(gate(isMeetingStopping: true).helperText == "Wait for the current meeting to finish saving.")
        #expect(gate(isMeetingStarting: true).helperText == "Wait for the meeting to finish starting.")
        #expect(gate(isDictationStarting: true).helperText == "Wait for dictation to finish starting.")
        #expect(gate(isRecoveryRetryRunning: true).helperText == "Finish the recovery retry before starting a meeting.")
    }

    @Test func sourceCloudCleanupAndPermissionMatrixRoutesWithoutChangingChoices() {
        for audio in MeetingAudioSelection.allCases {
            for research in [false, true] {
                for cleanup in [MeetingAIMode.transcriptionOnly, .localOnly, .cloudOptIn] {
                    for providerReady in [false, true] {
                        for permission in [false, true] {
                            for supported in [false, true] {
                                let cloudMissing = (research || cleanup == .cloudOptIn) && !providerReady
                                let result = MeetingStartRecovery.resolve(audio: audio,
                                    supportsMacAudio: supported, hasMacAudioPermission: permission,
                                    cloudBlocker: cloudMissing ? "Synthetic cloud setup" : nil)
                                if audio.includesMacAudio && !supported {
                                    #expect(result == .unsupportedMacAudio)
                                } else if audio.includesMacAudio && !permission {
                                    #expect(result == .macAudioAccess)
                                } else if cloudMissing {
                                    #expect(result == .cloudSetup("Synthetic cloud setup"))
                                } else {
                                    #expect(result == nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func permissionRegrantRevocationAndCloudChangesAreReevaluated() {
        func resolve(_ permission: Bool, _ cloud: String?) -> MeetingStartRecovery? {
            .resolve(audio: .macAudio, supportsMacAudio: true,
                hasMacAudioPermission: permission, cloudBlocker: cloud)
        }
        #expect(resolve(false, "Cloud") == .macAudioAccess)
        #expect(resolve(true, "Cloud") == .cloudSetup("Cloud"))
        #expect(resolve(true, nil) == nil)
        #expect(resolve(false, nil) == .macAudioAccess)
        #expect(resolve(true, "Changed provider") == .cloudSetup("Changed provider"))
    }

    @Test func explicitLocalChoicePreservesLocalCleanupAndCannotGrantCloud() throws {
        for cleanup in [MeetingAIMode.transcriptionOnly, .localOnly, .cloudOptIn] {
            let local = MeetingStartRecovery.localCleanupChoice(cleanup)
            #expect(local == (cleanup == .cloudOptIn ? .transcriptionOnly : cleanup))
            let mode = MeetingAIChoices.permissionMode(research: false, cleanup: local)
            let config = try MeetingIntelligenceConfigurationResolver.snapshot(
                cleanupEnabled: local != .transcriptionOnly, aiMode: mode,
                providerSettings: .init(cloudEnabled: false, consentGranted: false),
                hasCredential: false, providerWasTested: false,
                cleanupProvider: .localGemma)
            #expect(!mode.maySendTranscriptToCloud)
            #expect(config.cloudProvider == nil)
            #expect(config.cleanupEnabled == (cleanup == .localOnly))
            // Local choice cannot remove a separate Mac-audio permission requirement.
            #expect(MeetingStartRecovery.resolve(audio: .macAudio, supportsMacAudio: true,
                hasMacAudioPermission: false, cloudBlocker: nil) == .macAudioAccess)
        }
    }

    @Test func runtimeSnapshotStillRejectsCloudRevokedAfterConfirmation() {
        #expect(throws: (any Error).self) {
            try MeetingIntelligenceConfigurationResolver.snapshot(cleanupEnabled: false,
                aiMode: .cloudOptIn, providerSettings: .init(cloudEnabled: false),
                hasCredential: true, providerWasTested: true)
        }
        #expect(throws: (any Error).self) {
            try MeetingIntelligenceConfigurationResolver.snapshot(cleanupEnabled: true,
                aiMode: .cloudOptIn, providerSettings: .init(cloudEnabled: true, consentGranted: true),
                hasCredential: false, providerWasTested: true, cleanupProvider: .cloud)
        }
    }

    @Test func recoveryChoicesSeparatePermissionFromCloudAndNeverOfferImplicitFallback() {
        #expect(MeetingStartRecovery.cloudSetup("Setup").actions == [.useLocalRecording, .configureCloud])
        #expect(MeetingStartRecovery.macAudioAccess.actions == [
            .requestMacAudioAccess, .openMacAudioSettings, .checkMacAudioAccess, .chooseMicrophone])
        #expect(MeetingStartRecovery.unsupportedMacAudio.actions == [.chooseMicrophone])
        #expect(MeetingStartRecovery.cloudSetup("Setup").message.contains("global cloud settings"))
    }

    /// Production composition guards, not a substitute for installed-app interaction.
    @Test func productionStartAndSettingsRecoveryPreserveTheWorkspaceAndRuntimeGuards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeApp/MainWindowView.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "onStart: requestMeetingStart").count == 3)
        #expect(source.contains("OnlineMeetingSetupControls(selection: $audioSelection, hasPermission: $hasMacAudioPermission)"))
        #expect(source.contains(".sheet(item: $startRecovery, onDismiss: finishStartRecovery)"))
        #expect(source.contains(".sheet(isPresented: $showingStartCloudSettings)"))
        #expect(source.contains("ProviderSettingsView(drafts: startCloudDrafts)"))
        let start = try #require(source.range(of: "private func finishStartRecovery()"))
        let end = try #require(source.range(of: "var body: some View", range: start.upperBound..<source.endIndex))
        let handler = String(source[start.lowerBound..<end.lowerBound])
        #expect(handler.contains("showingStartCloudSettings = true"))
        #expect(!handler.contains("onNavigate("))
        #expect(!handler.contains("loadSavedCredential"))
        #expect(!handler.contains("startMeeting("))
        #expect(handler.components(separatedBy: "audioSelection = .microphone").count == 2)
        #expect(source.contains("if audioSelection.includesMacAudio && !CGPreflightScreenCaptureAccess()"))
        #expect(source.contains("intelligenceConfiguration: try MeetingIntelligenceConfigurationResolver.snapshot("))
    }
}

/// Offscreen native UI only. No real capture, permission prompts or provider.
@Suite(.serialized) @MainActor struct MeetingStartRecoveryRenderTests {
    @Test func recoveryChoicesAndStartExplanationRenderAtNarrowAndWideWidths() async throws {
        let variants: [MeetingStartRecovery] = [.cloudSetup("Load your saved key in Cloud AI settings, or use local recording."),
            .macAudioAccess, .unsupportedMacAudio]
        for recovery in variants {
            for width in [CGFloat(680), 1020] {
                let size = CGSize(width: width, height: 760)
                let host = NSHostingView(rootView: VStack(spacing: 24) {
                    MeetingHomeSetupHeading(canStart: true, isStarting: false,
                        helperText: recovery.summary, onStart: {})
                    MeetingStartRecoveryView(recovery: recovery, onChoose: { _ in })
                    Text("Synthetic native preview · No recording or cloud request")
                        .font(OpenBridgeTypography.metadata)
                }.padding(24).frame(width: size.width, height: size.height)
                    .background(OpenBridgeTheme.canvas).preferredColorScheme(.light))
                host.setFrameSize(size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderOut(nil)
                defer { window.contentView = nil }
                try await settleNativeLayout(host)
                #expect(host.bounds.size == size)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 2_000)
                if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_START_RECOVERY_RENDER_DIR"] {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try png.write(to: output.appendingPathComponent("start-recovery-\(recovery.id)-\(Int(width)).png"))
                }
            }
        }
    }
}
