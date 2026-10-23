import SwiftUI

// MARK: - Research Observatory SwiftUI Shell (#318)
//
// Provider-neutral shell behind an opt-in Beta flag. Data comes from
// ResearchObservatoryFixtures (DEBUG) or an injected production snapshot;
// all interactions are injected via ResearchRailActions.
// Production types are NOT wrapped in #if DEBUG (review requirement):
// only the fixture data and Canvas previews are DEBUG-gated.

// MARK: - Layout constants

/// Readable minimum widths for focus modes (review requirement).
enum ResearchLayout {
    /// Minimum readable transcript pane width.
    static let transcriptMinWidth: CGFloat = 420
    /// Minimum readable research rail width.
    static let railMinWidth: CGFloat = 300
    /// Below this total width the window switches to focus modes.
    static let narrowWindowThreshold: CGFloat = 760
}

// MARK: - Research Rail View

/// The right-side Research Observatory rail.
struct ResearchRailView: View {
    @ObservedObject var viewModel: ResearchRailViewModel

    private var snapshot: ResearchRailSnapshot { viewModel.snapshot }

    private var statusTitle: String {
        if snapshot.state == .searching && snapshot.activeQuestion?.origin == .spoken { return "Answering" }
        if snapshot.spokenStatus.pendingQuestion != nil { return "Waiting for question" }
        if snapshot.spokenStatus.needsRepeat { return "Repeat question" }
        return snapshot.state.displayName
    }

    var body: some View {
        if snapshot.meetingQuestions != nil {
            MeetingQuestionRail(viewModel: viewModel)
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        VStack(spacing: 0) {
            railHeader
            Divider()
            spokenProgress
            if !viewModel.visibleCards.isEmpty {
                // Activity and completed results are independent: neither a
                // quiet timer nor a new request may hide readable answers.
                if snapshot.state == .searching || snapshot.state == .failure || snapshot.state == .timeout || snapshot.state == .noSource {
                    requestStatus
                }
                cardsContent
            } else {
                switch snapshot.state {
                case .quiet, .answered, .memoryCue:
                    if snapshot.spokenStatus.pendingQuestion != nil || snapshot.spokenStatus.needsRepeat {
                        Spacer(minLength: 0)
                    } else { quietContent }
                case .searching: searchingContent
                case .noSource: noSourceContent
                case .timeout: timeoutContent
                case .failure: failureContent
                }
            }
            Spacer(minLength: 0)
            Divider()
            Text("Voice questions are checked after transcription, in roughly 30-second chunks, then answered.")
                 .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, 8)
            composerBar
        }
        .frame(minWidth: ResearchLayout.railMinWidth, idealWidth: 360, maxWidth: 420)
        .background(OpenBridgePalette.surface)
        .foregroundStyle(OpenBridgePalette.ink)
        .tint(OpenBridgePalette.blue)
        .font(OpenBridgeTypography.control)
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting Intelligence")
    }

    private var railHeader: some View {
        HStack {
            Image(systemName: "binoculars")
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .accessibilityHidden(true)
            Text("Meeting Intelligence")
                .font(OpenBridgeTypography.heading(size: 18))
            Spacer()
            Text(statusTitle)
                 .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OpenBridgePalette.guided)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var spokenProgress: some View {
        let status = snapshot.spokenStatus
        if status.pendingQuestion != nil || status.needsRepeat || !status.queuedQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let question = status.pendingQuestion {
                    Label("Heard OpenBridge — waiting for the rest", systemImage: "mic")
                       .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    Text(question).font(OpenBridgeTypography.body)
                    Text("Finish your question. We’ll check the next transcript chunk.")
                        .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                }
                if status.needsRepeat {
                    Text("I didn’t get a complete question.").font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    Text("Say ‘OpenBridge’ followed by the full question again, or type below.")
                        .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                }
                if !status.queuedQuestions.isEmpty {
                    Text("Queued: \(status.queuedQuestions.count)").font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                    ForEach(Array(status.queuedQuestions.prefix(2).enumerated()), id: \.offset) { _, question in
                        Text(question).font(OpenBridgeTypography.metadata).lineLimit(2)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .accessibilityElement(children: .combine)
            Divider()
        }
    }

    private var requestStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let question = snapshot.activeQuestion {
                Text(question.origin == .spoken ? "Heard your question" : "Your question")
                    .font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                Text(question.text).font(OpenBridgeTypography.body).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if snapshot.state == .searching { ProgressView().controlSize(.small) }
                Text(snapshot.state == .searching ? "Working on your question…" : snapshot.state.statusText)
                    .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                if snapshot.state == .failure || snapshot.state == .timeout {
                    Button("Retry") { viewModel.retry() }.controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var quietContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "moon.zzz")
                .font(.system(size: 32))
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .accessibilityHidden(true)
            Text("Quiet")
                .font(OpenBridgeTypography.control)
                .foregroundStyle(OpenBridgePalette.mutedInk)
            Text("Ask about this meeting or an earlier meeting.")
                 .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private var cardsContent: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.visibleCards) { card in
                    ResearchCardView(card: card, viewModel: viewModel)
                }
            }
            .padding(16)
        }
    }

    private var searchingContent: some View {
        VStack(spacing: 12) {
            Spacer()
            if let question = snapshot.activeQuestion {
                Text("\"\(question.text)\"")
                    .font(OpenBridgeTypography.body)
                    .foregroundStyle(OpenBridgePalette.mutedInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            ProgressView()
                .scaleEffect(0.9)
            Text(snapshot.activeQuestion?.origin == .spoken ? "Answering your question…" : "Searching for evidence…")
                 .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgePalette.mutedInk)
            Spacer()
        }
        .accessibilityLabel(snapshot.activeQuestion?.origin == .spoken ? "Answering your question" : "Searching for evidence")
    }

    private var noSourceContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .accessibilityHidden(true)
            Text(snapshot.activeQuestion?.origin == .spoken ? "Couldn’t answer your question" : "No relevant source found")
                .font(OpenBridgeTypography.control)
                .foregroundStyle(OpenBridgePalette.mutedInk)
            Text(snapshot.activeQuestion?.origin == .spoken
                 ? "Check that cloud research is enabled for this meeting and your provider is ready, or ask again."
                 : "Try rephrasing your question or expanding the search scope.")
                 .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private var timeoutContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(OpenBridgePalette.warningInk)
                .accessibilityHidden(true)
            Text("The search timed out")
                .font(OpenBridgeTypography.control)
                .foregroundStyle(OpenBridgePalette.mutedInk)
            Button("Retry") { viewModel.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Runs the search again")
            Spacer()
        }
        .padding()
    }

    private var failureContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(OpenBridgePalette.errorInk)
                .accessibilityHidden(true)
            Text("Something went wrong")
                .font(OpenBridgeTypography.control)
                .foregroundStyle(OpenBridgePalette.mutedInk)
            Text("Your meeting is unaffected.")
                 .font(OpenBridgeTypography.metadata)
                .foregroundStyle(OpenBridgePalette.mutedInk)
            Button("Retry") { viewModel.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Runs the search again")
            Spacer()
        }
        .padding()
    }

    private var composerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .accessibilityHidden(true)
            TextField(
                viewModel.isComposerEnabled ? "Ask a question…" : "Preparing meeting search…",
                text: $viewModel.composerText
            )
                .textFieldStyle(.plain)
                .font(OpenBridgeTypography.control)
                .onSubmit { viewModel.submitQuestion() }
                .disabled(!viewModel.isComposerEnabled)
            Button(action: { viewModel.submitQuestion() }) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(
                !viewModel.isComposerEnabled
                    || viewModel.composerText.trimmingCharacters(in: .whitespaces).isEmpty
            )
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Research Card View

/// A single evidence card in the rail.
struct ResearchCardView: View {
    let card: ResearchCard
    @ObservedObject var viewModel: ResearchRailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.variant.iconName)
                    .foregroundStyle(OpenBridgePalette.mutedInk)
                    .font(OpenBridgeTypography.metadata)
                    .accessibilityHidden(true)
                Text(card.researchSourceLabel)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgePalette.mutedInk)
                Spacer()
                Button {
                    viewModel.togglePin(card.id)
                } label: {
                    Image(systemName: card.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(card.isPinned ? "Unpin card" : "Pin card")
                .accessibilityLabel(card.isPinned ? "Unpin card" : "Pin card")
                Button {
                    viewModel.dismiss(card.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss and suppress for this meeting")
                .accessibilityLabel("Dismiss card")
            }

            Text(card.title)
                .font(OpenBridgeTypography.heading(size: 16))
                .foregroundStyle(OpenBridgePalette.ink)

            if card.isExpanded {
                Text(card.summary)
                    .font(OpenBridgeTypography.metadata)
                    .foregroundStyle(OpenBridgePalette.mutedInk)
                    .padding(.bottom, 2)

                ForEach(card.evidence) { evidence in
                    EvidenceBandView(evidence: evidence) {
                        viewModel.openSource(for: evidence)
                    }
                }

                HStack(spacing: 12) {
                    Button { viewModel.toggleExpanded(card.id) } label: {
                        Label("Less", systemImage: "chevron.up")
                           .font(OpenBridgeTypography.metadata)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Collapse card")
                    Spacer()
                    Button { viewModel.copy(card) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                           .font(OpenBridgeTypography.metadata)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy card text")
                    Button { viewModel.followUp(card.id) } label: {
                        Label("Follow-up", systemImage: "arrow.turn.down.right")
                           .font(OpenBridgeTypography.metadata)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Ask a follow-up question")
                }
                .foregroundStyle(OpenBridgePalette.mutedInk)
            } else {
                Button { viewModel.toggleExpanded(card.id) } label: {
                    Label("More", systemImage: "chevron.down")
                        .font(OpenBridgeTypography.metadata)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(OpenBridgePalette.mutedInk)
                .accessibilityLabel("Expand card")
            }
        }
        .padding(16)
        .background(OpenBridgePalette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(OpenBridgePalette.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.variant.displayName): \(card.title)")
    }
}

extension ResearchCard {
    /// Model-only answers must never carry a prior-meeting heading.
    var researchSourceLabel: String {
        if evidence.isEmpty { return "Research request" }
        if evidence.allSatisfy({ $0.type == .modelSynthesis }) { return "Model knowledge" }
        if evidence.allSatisfy({ $0.type == .currentMeeting }) { return "This meeting" }
        return variant.displayName
    }
}

// MARK: - Evidence Band

/// A colored evidence source band within a card. Tapping opens the exact
/// source via the injected action.
struct EvidenceBandView: View {
    let evidence: ResearchEvidence
    let openSource: () -> Void

    /// lunr-studio/Openbridge-Beta#299 (Build 24): exact meeting identity +
    /// timestamp when the store resolved one; otherwise the generic label.
    private var sourceIdentity: String {
        evidence.sourceTitle ?? evidence.type.displayName
    }

    var body: some View {
        Button(action: openSource) {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(evidence.type.bandColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: evidence.type.iconName)
                       .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(evidence.type.bandColor)
                        .accessibilityHidden(true)
                    Text(sourceIdentity)
                       .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(evidence.type.bandColor)
                    Spacer()
                    Text("\(Int(evidence.confidence * 100))%")
                       .font(OpenBridgeTypography.metadata)
                        .foregroundStyle(OpenBridgePalette.mutedInk)
                }
                Text(evidence.passage)
                    .font(OpenBridgeTypography.body(size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(OpenBridgePalette.mutedInk)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sourceIdentity) evidence, \(Int(evidence.confidence * 100)) percent confidence")
        .accessibilityHint("Opens the source")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Focus Mode Container

/// Adapts the Meetings content + research rail to wide and narrow windows.
/// Wide: transcript and rail side by side. Narrow: focus modes with
/// readable minimum widths enforced.
struct ResearchFocusContainer<TranscriptContent: View>: View {
    let transcript: TranscriptContent
    @ObservedObject var viewModel: ResearchRailViewModel
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let isNarrow = proxy.size.width < ResearchLayout.narrowWindowThreshold
            VStack(spacing: 0) {
                if isNarrow {
                    focusModePicker
                    Divider()
                }
                GeometryReader { content in
                    let layout = MeetingIntelligenceLayout(size: content.size,
                        preferredRailWidth: viewModel.intelligenceWidth,
                        expanded: viewModel.intelligenceExpanded, focus: viewModel.focusMode)
                    // Keep both panes in the same view tree. Resizing or focus
                    // changes must not destroy a draft, scroll anchor or source disclosure.
                    ZStack(alignment: .topLeading) {
                        transcript
                            .frame(width: layout.transcript.width, height: layout.transcript.height)
                            .clipped().opacity(layout.transcript.isEmpty ? 0 : 1)
                            .accessibilityHidden(layout.transcript.isEmpty)
                        ResearchRailView(viewModel: viewModel)
                            .frame(width: layout.rail.width, height: layout.rail.height)
                            .clipped().opacity(layout.rail.isEmpty ? 0 : 1)
                            .accessibilityHidden(layout.rail.isEmpty)
                            .offset(x: layout.rail.minX, y: layout.rail.minY)
                        if layout.canResize {
                            resizeHandle(availableWidth: content.size.width)
                                .frame(width: 8, height: content.size.height)
                                .offset(x: layout.transcript.maxX)
                        }
                    }
                }
            }
        }
    }

    private func resizeHandle(availableWidth: CGFloat) -> some View {
        Rectangle().fill(OpenBridgePalette.border.opacity(0.7))
            .overlay(Capsule().fill(OpenBridgePalette.mutedInk).frame(width: 3, height: 32))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStartWidth == nil {
                    dragStartWidth = MeetingIntelligenceLayout.clampedWidth(viewModel.intelligenceWidth, available: availableWidth)
                }
                viewModel.intelligenceWidth = MeetingIntelligenceLayout.clampedWidth(
                    (dragStartWidth ?? 420) - value.translation.width, available: availableWidth)
            }.onEnded { _ in dragStartWidth = nil })
            .help("Drag to resize Meeting Intelligence")
            .accessibilityLabel("Meeting Intelligence width")
            .accessibilityValue("\(Int(viewModel.intelligenceWidth)) points")
            .accessibilityAdjustableAction { direction in
                viewModel.intelligenceWidth = MeetingIntelligenceLayout.clampedWidth(
                    viewModel.intelligenceWidth + (direction == .increment ? 40 : -40), available: availableWidth)
            }
    }

    private var focusModePicker: some View {
        Picker("Focus", selection: Binding(get: { viewModel.intelligenceExpanded ? .research : viewModel.focusMode }, set: {
            viewModel.intelligenceExpanded = false; viewModel.focusMode = $0
        })) {
            ForEach(ResearchFocusMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityLabel("Focus mode")
    }
}

// MARK: - Feature-gated Meetings content

/// Renders the Meetings page with the Research Observatory rail attached
/// ONLY when the feature flag is enabled. The flag defaults OFF; when
/// disabled the Meetings page renders exactly as before.
public struct ResearchGatedMeetingsContent<TranscriptContent: View>: View {
    let transcript: TranscriptContent
    let isPresented: Bool
    let makeViewModel: () -> ResearchRailViewModel
    @AppStorage(ResearchObservatoryFeatureFlag.key) private var isResearchRailEnabled = false

    public init(
        transcript: TranscriptContent,
        isPresented: Bool = true,
        makeViewModel: @escaping () -> ResearchRailViewModel = {
            ResearchRailViewModel()
        }
    ) {
        self.transcript = transcript
        self.isPresented = isPresented
        self.makeViewModel = makeViewModel
    }

    public var body: some View {
        if isResearchRailEnabled && isPresented {
            ResearchOwnedFocusContainer(transcript: transcript, makeViewModel: makeViewModel)
        } else {
            transcript
        }
    }

}

/// SwiftUI owns this reference once for the mounted presentation. Assigning a
/// @State cache during body evaluation loses that assignment on parent updates,
/// recreating the bridge and wiping the selected focus and unsent draft.
private struct ResearchOwnedFocusContainer<TranscriptContent: View>: View {
    let transcript: TranscriptContent
    @StateObject private var viewModel: ResearchRailViewModel

    init(transcript: TranscriptContent, makeViewModel: @escaping () -> ResearchRailViewModel) {
        self.transcript = transcript
        _viewModel = StateObject(wrappedValue: makeViewModel())
    }

    var body: some View {
        ResearchFocusContainer(transcript: transcript, viewModel: viewModel)
    }
}

// MARK: - DEBUG: Fixture previews + gallery

#if DEBUG

struct ResearchRailPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            ForEach(ResearchRailState.allCases) { state in
                ResearchRailView(
                    viewModel: ResearchRailViewModel(
                        snapshot: ResearchObservatoryFixtures.fixture(for: state)
                    )
                )
                .previewDisplayName(state.displayName)
            }
        }
        .frame(height: 600)
    }
}

struct ResearchObservatoryGallery: View {
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(ResearchRailState.allCases) { state in
                    VStack {
                        Text(state.displayName)
                          .font(OpenBridgeTypography.heading(size: 18))
                        ResearchRailView(
                            viewModel: ResearchRailViewModel(
                                snapshot: ResearchObservatoryFixtures.fixture(for: state)
                            )
                        )
                        .frame(height: 500)
                        .border(Color.gray.opacity(0.2))
                    }
                }
                Divider().frame(height: 500)
                // All five card variants, one per labeled rail (tester
                // feedback: test 5) — keeps the 7e81332 fix in the rework.
                ForEach(ResearchObservatoryFixtures.allCardVariants) { card in
                    VStack {
                        Text(card.variant.displayName)
                          .font(OpenBridgeTypography.heading(size: 18))
                        ResearchRailView(
                            viewModel: ResearchRailViewModel(
                                snapshot: ResearchRailSnapshot(
                                    state: .answered, cards: [card], activeQuestion: nil
                                )
                            )
                        )
                        .frame(height: 500)
                        .border(Color.gray.opacity(0.2))
                    }
                }
            }
            .padding()
        }
        .frame(height: 600)
    }
}

struct ResearchObservatoryGalleryPreviews: PreviewProvider {
    static var previews: some View {
        ResearchObservatoryGallery()
    }
}

#endif
