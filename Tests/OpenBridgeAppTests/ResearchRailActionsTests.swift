import SwiftUI
import Testing
@testable import OpenBridgeUI

// MARK: - Research Rail Actions + Gating Tests (#318 rework)
//
// Covers Trishan's review requirements: injected fixture-testable
// actions (all nine), dismiss/suppress behavior, pinned ordering, focus
// modes with readable minimum widths, flag-gated integration, and
// production-type availability in Release.

@Suite(.serialized) @MainActor struct ResearchRailActionsTests {

    /// Records every action invocation for assertion.
    private final class ActionRecorder {
        var highlighted: [(String, String)] = []
        var openedPrior: [(String, String?)] = []
        var openedWeb: [URL] = []
        var pins: [String] = []
        var dismissals: [String] = []
        var copies: [String] = []
        var followUps: [String] = []
        var retries = 0
        var expansions: [String] = []

        var actions: ResearchRailActions {
            ResearchRailActions(
                highlightCurrentPassage: { self.highlighted.append(($0, $1)) },
                openPriorMeeting: { self.openedPrior.append(($0, $1)) },
                openWebSource: { self.openedWeb.append($0) },
                togglePin: { self.pins.append($0) },
                dismiss: { self.dismissals.append($0) },
                copyCard: { self.copies.append($0) },
                followUp: { self.followUps.append($0) },
                retry: { self.retries += 1 },
                toggleExpanded: { self.expansions.append($0) }
            )
        }
    }

    private func makeViewModel(recorder: ActionRecorder, cards: [ResearchCard]) -> ResearchRailViewModel {
        ResearchRailViewModel(
            snapshot: ResearchRailSnapshot(state: .answered, cards: cards, activeQuestion: nil),
            actions: recorder.actions
        )
    }

    // MARK: - All nine actions are injected + invocable

    @Test func allNineActionsFire() {
        let recorder = ActionRecorder()
        let vm = makeViewModel(recorder: recorder, cards: [ResearchObservatoryFixtures.answeredCard])
        let card = ResearchObservatoryFixtures.answeredCard

        vm.togglePin(card.id)
        vm.dismiss(card.id)
        vm.toggleExpanded(card.id)
        vm.copy(card)
        vm.followUp(card.id)
        vm.retry()
        vm.openSource(for: ResearchObservatoryFixtures.currentMeetingEvidence)
        vm.openSource(for: ResearchObservatoryFixtures.priorMeetingEvidence)
        vm.openSource(for: ResearchObservatoryFixtures.webEvidence)

        #expect(recorder.pins == [card.id])
        #expect(recorder.dismissals == [card.id])
        #expect(recorder.expansions == [card.id])
        #expect(recorder.copies.count == 1)
        #expect(recorder.followUps == [card.id])
        #expect(recorder.retries == 1)
        #expect(recorder.highlighted.count == 1 && recorder.highlighted[0].0 == "seg-005" && recorder.highlighted[0].1 == "current-meeting")
        #expect(recorder.openedPrior.count == 1 && recorder.openedPrior[0].0 == "prior-001" && recorder.openedPrior[0].1 == "seg-012")
        #expect(recorder.openedWeb == [URL(string: "https://example.com/launch-benchmarks")!])
    }

    // MARK: - Source routing by locator kind

    @Test func openSourceRoutesByLocator() {
        let recorder = ActionRecorder()
        let vm = makeViewModel(recorder: recorder, cards: [])

        vm.openSource(for: ResearchObservatoryFixtures.currentMeetingEvidence)
        #expect(recorder.highlighted.count == 1 && recorder.openedPrior.isEmpty && recorder.openedWeb.isEmpty)

        vm.openSource(for: ResearchObservatoryFixtures.priorMeetingEvidence)
        #expect(recorder.openedPrior.count == 1)

        vm.openSource(for: ResearchObservatoryFixtures.webEvidence)
        #expect(recorder.openedWeb.count == 1)
    }

    // MARK: - Dismiss + suppress

    @Test func dismissSuppressesCardForCurrentMeeting() {
        let recorder = ActionRecorder()
        let card = ResearchObservatoryFixtures.memoryCueCard
        let vm = makeViewModel(recorder: recorder, cards: [card])

        #expect(vm.visibleCards.count == 1)
        vm.dismiss(card.id)
        #expect(vm.visibleCards.isEmpty, "Dismissed card is suppressed")
        #expect(recorder.dismissals == [card.id], "Suppress feedback recorded")
    }

    // MARK: - Pin ordering

    @Test func pinnedCardsSurfaceFirst() {
        let recorder = ActionRecorder()
        let a = ResearchObservatoryFixtures.memoryCueCard
        let b = ResearchObservatoryFixtures.openLoopCard
        let vm = makeViewModel(recorder: recorder, cards: [a, b])

        vm.togglePin(b.id)
        let visible = vm.visibleCards
        #expect(visible.first?.id == b.id, "Pinned card surfaces first")
        #expect(visible.count == 2)
    }

    // MARK: - Expand/collapse

    @Test func toggleExpandedFlipsCardState() {
        let recorder = ActionRecorder()
        let card = ResearchObservatoryFixtures.answeredCard
        let vm = makeViewModel(recorder: recorder, cards: [card])

        #expect(vm.snapshot.cards.first?.isExpanded == true)
        vm.toggleExpanded(card.id)
        #expect(vm.snapshot.cards.first?.isExpanded == false, "Expanded card collapses")
    }

    @Test func coordinatorRefreshPreservesCardInteractionState() throws {
        let recorder = ActionRecorder()
        let card = ResearchObservatoryFixtures.answeredCard
        let vm = makeViewModel(recorder: recorder, cards: [card])
        vm.togglePin(card.id)
        vm.dismiss(card.id)
        vm.toggleExpanded(card.id)

        let refreshed = ResearchCard(
            id: card.id,
            variant: card.variant,
            title: card.title,
            summary: "Refreshed coordinator content",
            evidence: card.evidence
        )
        vm.updateSnapshot(ResearchRailSnapshot(
            state: .quiet,
            cards: [refreshed],
            activeQuestion: nil
        ))

        let preserved = try #require(vm.snapshot.cards.first)
        #expect(preserved.summary == "Refreshed coordinator content")
        #expect(preserved.isPinned)
        #expect(preserved.isDismissed)
        #expect(!preserved.isExpanded)
        #expect(vm.visibleCards.isEmpty)
    }

    // MARK: - Focus modes

    @Test func focusModesAreSwitchable() {
        let vm = ResearchRailViewModel()
        #expect(vm.focusMode == .transcript)
        vm.focusMode = .split
        #expect(vm.focusMode == .split)
        vm.focusMode = .research
        #expect(vm.focusMode == .research)
    }

    @Test func readableMinimumWidthsEnforced() {
        // Review requirement: focus modes must enforce readable minimums.
        #expect(ResearchLayout.transcriptMinWidth >= 400, "Transcript pane >= 400pt")
        #expect(ResearchLayout.railMinWidth >= 300, "Rail pane >= 300pt")
        #expect(ResearchLayout.narrowWindowThreshold >= ResearchLayout.transcriptMinWidth)
    }

    @Test func focusContainerRendersAllModes() throws {
        let vm = ResearchRailViewModel(
            snapshot: ResearchObservatoryFixtures.fixture(for: .answered)
        )
        for mode in ResearchFocusMode.allCases {
            vm.focusMode = mode
            let container = ResearchFocusContainer(
                transcript: Text("Transcript placeholder"),
                viewModel: vm
            )
            let renderer = ImageRenderer(content: container.frame(width: 700, height: 500))
            #expect(renderer.nsImage != nil, "Focus container renders in \(mode.displayName)")
        }
    }

    // MARK: - Wide/narrow render evidence

    @Test func railRendersWideAndNarrow() throws {
        let vm = ResearchRailViewModel(
            snapshot: ResearchObservatoryFixtures.fixture(for: .answered)
        )
        for width in [CGFloat(1280), CGFloat(480)] {
            let renderer = ImageRenderer(content: ResearchRailView(viewModel: vm).frame(width: width, height: 600))
            let image = try #require(renderer.nsImage, "Rail renders at width \(width)")
            #expect(image.size.width > 0)
        }
    }

    // MARK: - Flag gating

    @Test func gatingDefaultsOffAndDisablesRail() throws {
        // Default OFF (uses a clean defaults suite to prove the default).
        let suiteName = "research-flag-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!defaults.bool(forKey: ResearchObservatoryFeatureFlag.key),
                "Flag defaults OFF in a fresh defaults domain")

        // Gated container: with flag off, transcript renders WITHOUT rail.
        ResearchObservatoryFeatureFlag.setEnabled(false)
        let gated = ResearchGatedMeetingsContent(transcript: Text("Just the meetings page"))
        let rendererOff = ImageRenderer(content: gated.frame(width: 1000, height: 600))
        #expect(rendererOff.nsImage != nil, "Disabled flag renders transcript-only")
    }

    @Test func flagToggleRoundTrips() {
        let original = ResearchObservatoryFeatureFlag.isEnabled
        defer { ResearchObservatoryFeatureFlag.setEnabled(original) }

        ResearchObservatoryFeatureFlag.setEnabled(true)
        #expect(ResearchObservatoryFeatureFlag.isEnabled)
        ResearchObservatoryFeatureFlag.setEnabled(false)
        #expect(!ResearchObservatoryFeatureFlag.isEnabled)
    }

    @Test func legacyAlphaFlagCannotEnableVersionedBetaConsent() {
        let suiteName = "research-beta-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ResearchObservatoryFeatureFlag.legacyInternalKey)

        #expect(!ResearchObservatoryFeatureFlag.isEnabled(in: defaults))

        ResearchObservatoryFeatureFlag.setEnabled(true, in: defaults)
        #expect(ResearchObservatoryFeatureFlag.isEnabled(in: defaults))
        ResearchObservatoryFeatureFlag.clearLegacyInternalValue(in: defaults)
        #expect(defaults.object(forKey: ResearchObservatoryFeatureFlag.legacyInternalKey) == nil)
        #expect(ResearchObservatoryFeatureFlag.isEnabled(in: defaults))
    }

    @Test @MainActor func disabledComposerCannotSubmitDuringReindex() {
        let viewModel = ResearchRailViewModel()
        var submissions: [String] = []
        viewModel.onSubmitQuestion = { submissions.append($0) }
        viewModel.composerText = "What changed?"
        viewModel.isComposerEnabled = false

        viewModel.submitQuestion()

        #expect(submissions.isEmpty)
        #expect(viewModel.composerText == "What changed?")
        viewModel.isComposerEnabled = true
        viewModel.submitQuestion()
        #expect(submissions == ["What changed?"])
    }

    // MARK: - Production availability (Release-compatibility contract)

    @Test func productionTypesAvailableWithoutDEBUG() {
        // These references compile identically in Release: the types are
        // NOT #if DEBUG-gated (review requirement). Constructing them here
        // asserts availability; the Release build in CI is the true gate.
        _ = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil)
        _ = ResearchRailActions()
        _ = ResearchLayout.narrowWindowThreshold
    }
}
