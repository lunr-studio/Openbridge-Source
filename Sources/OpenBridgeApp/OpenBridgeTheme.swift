import AppKit
import SwiftUI
import OpenBridgeUI

enum OpenBridgeTheme {
    static let ink = OpenBridgePalette.ink
    static let mutedInk = OpenBridgePalette.mutedInk
    static let canvas = OpenBridgePalette.canvas
    static let card = OpenBridgePalette.surface
    static let cardSoft = OpenBridgePalette.canvas
    static let border = OpenBridgePalette.border
    static let controlBorder = OpenBridgePalette.controlBorder
    static let selected = OpenBridgePalette.selected
    static let brandBlue = OpenBridgePalette.blue
    static let brandGold = OpenBridgePalette.gold
    static let brandTeal = OpenBridgePalette.localInk
    static let brandGreen = OpenBridgePalette.localInk
    static let brandCoral = OpenBridgePalette.errorInk
    static let localInk = OpenBridgePalette.localInk
    static let localSurface = OpenBridgePalette.localSurface
    static let cloudInk = OpenBridgePalette.cloudInk
    static let cloudSurface = OpenBridgePalette.cloudSurface
    static let warningInk = OpenBridgePalette.warningInk
    static let warningSurface = OpenBridgePalette.warningSurface
    static let errorInk = OpenBridgePalette.errorInk
    static let errorSurface = OpenBridgePalette.errorSurface
    static let coolSurface = OpenBridgePalette.guided
    static let windowGutter: CGFloat = 24
    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 6
    static let motionDuration = 0.18

    static func accent(for phase: FlowBarPhase, context: FlowBarContext) -> Color {
        switch phase {
        case .hidden:
            return .secondary
        case .listening:
            return context == .commandMode ? brandTeal : brandBlue
        case .processing:
            return context == .commandMode ? brandTeal : brandGold
        case .success:
            return brandGreen
        case .cancelled:
            return .secondary
        case .error:
            return brandCoral
        }
    }

    static func stageTint(isActive: Bool, isComplete: Bool, accent: Color) -> Color {
        if isActive {
            return accent
        }
        if isComplete {
            return brandTeal
        }
        return .secondary.opacity(0.34)
    }
}

struct OpenBridgeBrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        // Preserve the homepage SVG's 128-point artwork and original colors.
        // Drawing only its foreground removes the old PNG's white icon tile.
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 128, y: canvasSize.height / 128)
            let ink = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)
            let gold = Color(red: 250 / 255, green: 204 / 255, blue: 21 / 255)
            let outline = StrokeStyle(lineWidth: 5, lineCap: .round)
            context.stroke(Path(ellipseIn: CGRect(x: 16, y: 16, width: 96, height: 96)),
                           with: .color(ink), style: outline)
            var stem = Path()
            stem.move(to: CGPoint(x: 64, y: 93))
            stem.addLine(to: CGPoint(x: 64, y: 116))
            context.stroke(stem, with: .color(ink), style: outline)
            let microphone = Path(roundedRect: CGRect(x: 45, y: 29, width: 38, height: 66),
                                  cornerRadius: 19)
            context.fill(microphone, with: .color(gold))
            context.stroke(microphone, with: .color(ink), style: outline)
            for x in [56.0, 72.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 54.5, width: 5, height: 5)),
                             with: .color(ink.opacity(0.18)))
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 55, y: 74))
            smile.addCurve(to: CGPoint(x: 73, y: 74),
                           control1: CGPoint(x: 55, y: 86), control2: CGPoint(x: 73, y: 86))
            context.stroke(smile, with: .color(ink.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PremiumSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(OpenBridgeTypography.heading(size: 18))
                    .foregroundStyle(OpenBridgeTheme.ink)

                if let subtitle {
                    Text(subtitle)
                        .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgeTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenBridgeTheme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OpenBridgeTheme.border.opacity(0.75), lineWidth: 1)
        }
    }
}

struct OpenBridgeStatusPill: View {
    let text: String
    var tint: Color = OpenBridgeTheme.brandTeal

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(OpenBridgeTypography.body(size: 12, weight: .medium))
                .foregroundStyle(OpenBridgeTheme.mutedInk)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        }
    }
}

struct OpenBridgePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OpenBridgeTypography.control)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OpenBridgeTheme.ink)
            }
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: OpenBridgeTheme.motionDuration), value: configuration.isPressed)
    }
}

struct OpenBridgeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OpenBridgeTypography.control)
            .foregroundStyle(OpenBridgeTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OpenBridgeTheme.card.opacity(configuration.isPressed ? 0.72 : 0.96))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(OpenBridgeTheme.border.opacity(0.9), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: OpenBridgeTheme.motionDuration), value: configuration.isPressed)
    }
}

struct OpenBridgePresetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
            .foregroundStyle(OpenBridgeTheme.mutedInk)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? OpenBridgeTheme.coolSurface.opacity(0.8) : OpenBridgeTheme.card.opacity(0.82))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(OpenBridgeTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: OpenBridgeTheme.motionDuration), value: configuration.isPressed)
    }
}

struct OpenBridgeMiniButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OpenBridgeTypography.body(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : OpenBridgeTheme.mutedInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? OpenBridgeTheme.ink : OpenBridgeTheme.card.opacity(configuration.isPressed ? 0.7 : 0.92))
            }
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OpenBridgeTheme.border.opacity(0.85), lineWidth: 1)
                }
            }
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: OpenBridgeTheme.motionDuration), value: configuration.isPressed)
    }
}
