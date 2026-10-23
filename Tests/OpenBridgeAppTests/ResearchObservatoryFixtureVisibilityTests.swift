import SwiftUI
import Testing
@testable import OpenBridgeUI

// MARK: - Fixture Visibility Tests (#318)
//
// Added from tester feedback: automated render tests asserted "something
// rendered" but not that every card variant and every evidence band is
// actually VISIBLE in the fixture surfaces. These close that gap.

@Suite(.serialized) @MainActor struct ResearchObservatoryFixtureVisibilityTests {

    /// Every card variant must appear in the gallery's variant section.
    @Test func allCardVariantsCoverEveryVariantCase() {
        let present = Set(ResearchObservatoryFixtures.allCardVariants.map(\.variant))
        #expect(present == Set(ResearchCardVariant.allCases),
                "Every card variant must be in allCardVariants; missing: \(Set(ResearchCardVariant.allCases).subtracting(present))")
    }

    /// The Answered fixture must show ALL FOUR evidence bands — including
    /// the blue "This meeting" band the tester found missing.
    @Test func answeredCardShowsAllFourEvidenceBands() {
        let types = Set(ResearchObservatoryFixtures.answeredCard.evidence.map(\.type))
        #expect(types == Set(ResearchEvidenceType.allCases),
                "Answered fixture must include all four evidence types; missing: \(Set(ResearchEvidenceType.allCases).subtracting(types))")
    }

    /// Each variant card renders in its own rail (non-nil output).
    @Test func everyVariantCardRenders() throws {
        for card in ResearchObservatoryFixtures.allCardVariants {
            let rail = ResearchRailView(
                viewModel: ResearchRailViewModel(
                    snapshot: ResearchRailSnapshot(state: .answered, cards: [card], activeQuestion: nil)
                )
            )
            let renderer = ImageRenderer(content: rail.frame(width: 360, height: 600))
            #expect(renderer.nsImage != nil, "Variant \(card.variant.displayName) must render")
        }
    }

    /// The expanded gallery (states + all variants) renders as a whole.
    @Test func galleryRendersStatesAndVariants() throws {
        let renderer = ImageRenderer(content: ResearchObservatoryGallery().frame(width: 4200, height: 620))
        #expect(renderer.nsImage != nil, "Gallery must render states and variants")
    }
}