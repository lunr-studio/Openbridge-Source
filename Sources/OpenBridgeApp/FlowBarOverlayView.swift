import OpenBridgeUI
import SwiftUI

/// Value-only presentation shared by the real floating panel and visual
/// fixtures. Constructing it has no recording, provider or persistence effects.
struct FlowBarPresentation {
    let phase: FlowBarPhase
    let title: String
    let detail: String
    var privacyLabel = "On your Mac"
    var privacyIconName = "lock"
    var recordingStartedAt: Date? = nil
    var processingStartedAt: Date? = nil
    var allowsCancellation = false
    var hasRecoveryText = false
    var recoveryTone: DictationRecoveryTone = .attention

    static func successTitle(for message: String, context: FlowBarContext) -> String {
        if message.hasPrefix("Text copied.") { return "Text copied" }
        if message.hasPrefix("Replacement requested.") { return "Replacement requested" }
        return context == .commandMode ? "Text action complete" : "Pasted into place"
    }
}

/// The production adapter reads the existing operation and wires its actions.
/// Rendering the surface never starts a microphone or model.
struct FlowBarOverlayView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        FlowBarSurface(
            presentation: FlowBarPresentation(
                phase: appState.flowBarPhase,
                title: title,
                detail: detail,
                privacyLabel: privacyLabel,
                privacyIconName: appState.flowBarContext == .commandMode ? "wand.and.stars" : "lock",
                recordingStartedAt: appState.recordingStartedAt,
                processingStartedAt: appState.flowBarProcessingStartedAt,
                allowsCancellation: appState.flowBarAllowsCancellation,
                hasRecoveryText: appState.flowBarRecoveryText != nil,
                recoveryTone: appState.flowBarRecoveryTone
            ),
            inputLevel: { appState.flowBarInputLevel },
            processingDetail: { appState.flowBarProcessingDetail(elapsedSeconds: $0) },
            onStop: { Task { await appState.stopActiveRecording() } },
            onCancel: { appState.cancelDictation() },
            onDismiss: { appState.dismissFlowBar() },
            onCopyRecovery: { appState.copyFlowBarRecoveryText() }
        )
    }

    private var title: String {
        switch appState.flowBarPhase {
        case .hidden: AppIdentity.displayName
        case .listening: appState.flowBarContext == .commandMode ? "Listening to your instruction" : "Listening"
        case .processing: appState.flowBarProcessingTitle
        case .success(let message): FlowBarPresentation.successTitle(for: message, context: appState.flowBarContext)
        case .cancelled: "Cancelled"
        case .error: appState.flowBarRecoveryText == nil ? "Needs attention" : appState.flowBarRecoveryTone.title
        }
    }

    private var detail: String {
        switch appState.flowBarPhase {
        case .hidden: appState.statusMessage
        case .listening: appState.flowBarContext == .dictation ? "Your next thought, in your own words." : appState.flowBarListeningDetail
        case .processing: appState.flowBarProcessingDetail(elapsedSeconds: 0)
        case .success(let message), .error(let message): message
        case .cancelled: appState.flowBarContext == .commandMode
            ? "Text action discarded. Nothing was pasted."
            : "Recording discarded. Nothing was pasted."
        }
    }

    private var privacyLabel: String {
        let label = switch appState.flowBarContext {
        case .commandMode: "Text action"
        case .handsFree: "On your Mac · Hands-free"
        case .dictation: "On your Mac"
        }
        // Local test packages opt in explicitly. The production release keeps
        // its usual footer; screenshots of a test identify the exact build.
        if Bundle.main.object(forInfoDictionaryKey: "OpenBridgeLocalTest") as? Bool == true {
            return "\(label) · Test build \(AppIdentity.build)"
        }
        return label
    }

}

/// The actual native flow appearance, independent of AppState construction.
struct FlowBarSurface: View {
    let presentation: FlowBarPresentation
    var inputLevel: () -> Double = { 0 }
    var processingDetail: ((Int) -> String)? = nil
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onCopyRecovery: () -> Void = {}
    // Optional override is for inert visual fixtures; production uses macOS.
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            phaseVisual
                .frame(width: 70, height: 58)
                .background(OpenBridgeTheme.canvas, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(presentation.title)
                        .font(OpenBridgeTypography.heading(size: 18))
                        .foregroundStyle(OpenBridgeTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if presentation.phase == .listening {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(elapsedTimeLabel(asOf: timeline.date))
                                .font(OpenBridgeTypography.mono(size: 13, weight: .medium))
                                .foregroundStyle(OpenBridgeTheme.mutedInk)
                                .accessibilityLabel("Recording duration")
                                .accessibilityValue(elapsedTimeLabel(asOf: timeline.date))
                        }
                    }
                }
                detailView
                Label(presentation.privacyLabel, systemImage: presentation.privacyIconName)
                    .font(OpenBridgeTypography.body(size: 12, weight: .medium))
                    .foregroundStyle(OpenBridgeTheme.localInk)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            controls
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 19)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(OpenBridgeTheme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(OpenBridgeTheme.brandGold).frame(height: 2)

        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(OpenBridgeTheme.border, lineWidth: 1) }
        .overlay(alignment: .top) {
            Capsule().fill(OpenBridgeTheme.controlBorder)
                .frame(width: 28, height: 3)
                .frame(width: 88, height: 18)
                .overlay { FlowBarDragRegion() }
                .help("Drag to move. OpenBridge remembers this position.")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: phaseKey)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private var phaseVisual: some View {
        switch presentation.phase {
        case .listening:
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                ListeningWaveform(level: inputLevel(), reduceMotion: reduceMotion)
            }
        case .processing:
            ProcessingGlyph(reduceMotion: reduceMotion)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .medium)).foregroundStyle(OpenBridgeTheme.localInk)
                .accessibilityHidden(true)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 26, weight: .medium)).foregroundStyle(OpenBridgeTheme.mutedInk)
                .accessibilityHidden(true)
        case .error:
            Image(systemName: presentation.recoveryTone.iconName)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(presentation.recoveryTone == .unconfirmed ? OpenBridgeTheme.mutedInk : OpenBridgeTheme.errorInk)
                .accessibilityHidden(true)
        case .hidden:
            OpenBridgeBrandMark(size: 32)
        }
    }

    @ViewBuilder private var detailView: some View {
        if presentation.phase == .processing {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                detailText(processingDetail?(processingElapsedSeconds(asOf: timeline.date)) ?? presentation.detail)
            }
        } else {
            detailText(presentation.detail)
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(OpenBridgeTypography.metadata)
            .lineSpacing(3)
            .foregroundStyle(OpenBridgeTheme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var controls: some View {
        switch presentation.phase {
        case .listening:
            VStack(spacing: 6) {
                Button("Stop", action: onStop)
                    .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                    .help("Stop recording and transcribe")
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .help("Cancel recording without pasting")
            }
        case .processing:
            if presentation.allowsCancellation {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(OpenBridgeMiniButtonStyle())
                    .help("Cancel without pasting")
            }
        case .success, .cancelled:
            dismissButton
        case .error:
            VStack(spacing: 6) {
                if presentation.hasRecoveryText {
                    Button("Copy text", action: onCopyRecovery)
                        .buttonStyle(OpenBridgeMiniButtonStyle(prominent: true))
                        .help("Copy the text retained from this operation")
                }
                dismissButton
            }
        case .hidden:
            EmptyView()
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark").frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(OpenBridgeTheme.mutedInk)
        .help("Dismiss")
        .accessibilityLabel("Dismiss voice typing status")
    }

    private func elapsedTimeLabel(asOf date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(presentation.recordingStartedAt ?? date)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func processingElapsedSeconds(asOf date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(presentation.processingStartedAt ?? date)))
    }

    private var phaseKey: String {
        switch presentation.phase {
        case .hidden: "hidden"
        case .listening: "listening"
        case .processing: "processing"
        case .success: "success"
        case .cancelled: "cancelled"
        case .error: "error"
        }
    }

}

private struct FlowBarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> FlowBarDragHandle {
        let view = FlowBarDragHandle()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel("Move voice typing widget")
        return view
    }

    func updateNSView(_ nsView: FlowBarDragHandle, context: Context) {}
}
private struct ListeningWaveform: View {
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<9, id: \.self) { index in
                let envelope = 1 - abs(Double(index - 4)) / 6
                let height = reduceMotion ? 14 : 5 + min(1, max(0, level)) * 32 * envelope
                RoundedRectangle(cornerRadius: 2)
                    .fill(index == 4 ? OpenBridgeTheme.brandGold : OpenBridgeTheme.ink)
                    .frame(width: 4, height: height)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone input")
        .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) percent")
    }
}

private struct ProcessingGlyph: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Image(systemName: "waveform.path").font(.system(size: 24)).foregroundStyle(OpenBridgeTheme.ink)
                .accessibilityHidden(true)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                ZStack {
                    Circle().stroke(OpenBridgeTheme.border, lineWidth: 2).frame(width: 30, height: 30)
                    Circle().trim(from: 0.05, to: 0.36)
                        .stroke(OpenBridgeTheme.brandBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate * 140))
                    Circle().fill(OpenBridgeTheme.brandGold).frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
