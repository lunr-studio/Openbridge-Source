import SwiftUI

/// Pure layout policy: the transcript stays readable in split view, while
/// full-width intelligence leaves the recording header and Stop outside it.
struct MeetingIntelligenceLayout {
    let transcript: CGRect
    let rail: CGRect
    let canResize: Bool

    static func clampedWidth(_ value: CGFloat, available: CGFloat) -> CGFloat {
        min(max(ResearchLayout.railMinWidth, value), max(0, available - ResearchLayout.transcriptMinWidth - 8))
    }

    init(size: CGSize, preferredRailWidth: CGFloat, expanded: Bool, focus: ResearchFocusMode) {
        let bounds = CGRect(origin: .zero, size: size)
        let narrow = size.width < ResearchLayout.narrowWindowThreshold
        canResize = !narrow && !expanded
        if expanded || (narrow && focus == .research) {
            transcript = .zero; rail = bounds
        } else if narrow && focus == .transcript {
            transcript = bounds; rail = .zero
        } else if narrow {
            let top = size.height * 0.4
            transcript = CGRect(x: 0, y: 0, width: size.width, height: top)
            rail = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
        } else {
            let width = Self.clampedWidth(preferredRailWidth, available: size.width)
            transcript = CGRect(x: 0, y: 0, width: size.width - width - 8, height: size.height)
            rail = CGRect(x: size.width - width, y: 0, width: width, height: size.height)
        }
    }
}
