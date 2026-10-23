import Foundation
import Testing
@testable import OpenBridgeUI

@Suite(.serialized) struct ResearchObservatoryTests {

    // MARK: - Feature flag

    @Test func featureFlagDefaultsToOff() throws {
        let key = ResearchObservatoryFeatureFlag.key
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(ResearchObservatoryFeatureFlag.isEnabled == false)
    }

    @Test func featureFlagPersists() throws {
        let key = ResearchObservatoryFeatureFlag.key
        defer { UserDefaults.standard.removeObject(forKey: key) }

        ResearchObservatoryFeatureFlag.setEnabled(true)
        #expect(ResearchObservatoryFeatureFlag.isEnabled == true)

        ResearchObservatoryFeatureFlag.setEnabled(false)
        #expect(ResearchObservatoryFeatureFlag.isEnabled == false)
    }

    // MARK: - Rail states

    @Test func allRailStatesHaveUniqueDisplayNames() throws {
        let names = ResearchRailState.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func allRailStatesHaveNonEmptyStatusText() throws {
        for state in ResearchRailState.allCases {
            #expect(!state.statusText.isEmpty, "State \(state.rawValue) has empty status text")
        }
    }

    @Test func quietIsDefaultState() throws {
        // The quiet state should be the first case
        #expect(ResearchRailState.allCases.first == .quiet)
    }

    // MARK: - Evidence scopes

    @Test func localOnlyExcludesWebAndModel() throws {
        let local = ResearchEvidenceScope.localOnly
        #expect(local.contains(.currentMeeting))
        #expect(local.contains(.priorMeetings))
        #expect(!local.contains(.web))
        #expect(!local.contains(.modelSynthesis))
    }

    @Test func allScopesIncludesEverything() throws {
        let all = ResearchEvidenceScope.all
        #expect(all.contains(.currentMeeting))
        #expect(all.contains(.priorMeetings))
        #expect(all.contains(.web))
        #expect(all.contains(.modelSynthesis))
    }

    @Test func scopeLabelsAreCorrect() throws {
        let labels = ResearchEvidenceScope.all.labels
        #expect(labels.count == 4)
        #expect(labels.contains("This meeting"))
        #expect(labels.contains("Prior meetings"))
        #expect(labels.contains("Web"))
        #expect(labels.contains("Model"))
    }

    // MARK: - Evidence types

    @Test func allEvidenceTypesHaveUniqueDisplayNames() throws {
        let names = ResearchEvidenceType.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func allEvidenceTypesHaveIcons() throws {
        for type in ResearchEvidenceType.allCases {
            #expect(!type.iconName.isEmpty, "Type \(type.rawValue) has empty icon")
        }
    }

    // MARK: - Card variants

    @Test func allCardVariantsHaveUniqueDisplayNames() throws {
        let names = ResearchCardVariant.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func allCardVariantsHaveIcons() throws {
        for variant in ResearchCardVariant.allCases {
            #expect(!variant.iconName.isEmpty, "Variant \(variant.rawValue) has empty icon")
        }
    }

    // MARK: - Fixtures

    @Test func allStatesHaveFixtures() throws {
        for state in ResearchRailState.allCases {
            let snapshot = ResearchObservatoryFixtures.fixture(for: state)
            #expect(snapshot.state == state)
        }
    }

    @Test func answeredFixtureHasCardsWithEvidence() throws {
        let snapshot = ResearchObservatoryFixtures.fixture(for: .answered)
        #expect(!snapshot.cards.isEmpty)
        let card = snapshot.cards[0]
        #expect(!card.evidence.isEmpty)
    }

    @Test func quietFixtureHasNoCards() throws {
        let snapshot = ResearchObservatoryFixtures.fixture(for: .quiet)
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.activeQuestion == nil)
    }

    @Test func searchingFixtureHasQuestionButNoCards() throws {
        let snapshot = ResearchObservatoryFixtures.fixture(for: .searching)
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.activeQuestion != nil)
    }

    @Test func allCardVariantsCoveredInFixtures() throws {
        let variants = Set(ResearchObservatoryFixtures.allCardVariants.map(\.variant))
        #expect(variants.count == ResearchCardVariant.allCases.count)
    }

    // MARK: - Research question

    @Test func questionDefaultsToLocalOnlyAndTyped() throws {
        let q = ResearchQuestion(text: "test")
        #expect(q.origin == .typed)
        #expect(q.scopes == .localOnly)
        #expect(q.allowsCloudWeb == false)
    }

    // MARK: - Focus modes

    @Test func focusModesAreComplete() throws {
        #expect(ResearchFocusMode.allCases.count == 3)
        #expect(ResearchFocusMode.allCases.contains(.transcript))
        #expect(ResearchFocusMode.allCases.contains(.split))
        #expect(ResearchFocusMode.allCases.contains(.research))
    }
}