import SwiftUI

/// Questions, answers and progress share one stable list. A state transition
/// changes a card; it never replaces the history with an empty-state spinner.
struct MeetingQuestionRail: View {
    @ObservedObject var viewModel: ResearchRailViewModel
    private var questions: [MeetingQuestionCard] { viewModel.snapshot.meetingQuestions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "binoculars").foregroundStyle(OpenBridgePalette.mutedInk)
                Text("Meeting Intelligence").font(OpenBridgeTypography.heading(size: 18))
                Spacer(minLength: 0)
                Button {
                    viewModel.intelligenceExpanded.toggle()
                    if !viewModel.intelligenceExpanded { viewModel.focusMode = .split }
                } label: {
                    Image(systemName: viewModel.intelligenceExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(viewModel.intelligenceExpanded ? "Return to split view" : "Expand Meeting Intelligence")
                .accessibilityLabel(viewModel.intelligenceExpanded ? "Return to split view" : "Expand Meeting Intelligence")
            }.padding(16)
            if let title = viewModel.snapshot.meetingTitle {
                Text(title).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                    .lineLimit(2).padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            if let notice = viewModel.snapshot.conversationNotice {
                Text(notice).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.warningInk).padding(16)
            }
            if let access = viewModel.snapshot.researchAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Search", selection: Binding(get: { viewModel.snapshot.researchScope },
                        set: { viewModel.onResearchScope?($0) })) {
                        ForEach(MeetingResearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).font(OpenBridgeTypography.control)
                    if !access.detail.isEmpty {
                        Text(access.detail).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                    }
                    if !access.provider.isEmpty { Text(access.provider).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk).lineLimit(2) }
                    Button(access.canAsk ? "Manage approved meetings (\(access.approvedHistoryCount))"
                        : access.canEnable ? "Enable cloud research" : "Review research settings") {
                        viewModel.onManageResearch?()
                    }.controlSize(.small)
                }.padding(16)
                Divider()
            }
            // Measure complete answer cards so revealing the latest question does
            // not leave estimated heights above it. Lazy height corrections
            // otherwise move the viewport as older long answers appear. Use
            // one-shot scroll commands instead of a persistent item anchor.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if questions.isEmpty && (viewModel.snapshot.researchAccess?.canAsk ?? true) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(viewModel.snapshot.researchScope == .history ? "Ask about your meetings" : "Ask about this meeting").font(OpenBridgeTypography.heading(size: 18))
                                Text(viewModel.snapshot.meetingTitle == nil
                                    ? "Start a meeting or open a saved meeting and choose Ask."
                                    : "Type a question below. We find relevant passages within your selected search scope before asking your configured cloud model.")
                                  .font(OpenBridgeTypography.body).foregroundStyle(OpenBridgePalette.mutedInk)
                            }.padding(.vertical, 20)
                        }
                        ForEach(questions) { question in card(question).id(question.id) }
                    }.padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .onAppear {
                    if let id = viewModel.conversationScrollID { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: viewModel.conversationScrollID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent speech may still be recording. Send waits for the section containing your question time to be transcribed.")
                    .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                TextField("Ask about this meeting…", text: $viewModel.composerText, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain)
                    .font(OpenBridgeTypography.control)
                    .padding(10)
                    .background(OpenBridgePalette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(OpenBridgePalette.controlBorder))
                    .accessibilityLabel("Meeting question")
                    .onSubmit { viewModel.submitQuestion() }
                HStack {
                    if viewModel.onSubmitWebQuestion != nil {
                        Button("Research the web…", systemImage: "globe") { viewModel.previewWebQuestion() }
                            .disabled(!viewModel.isComposerEnabled || viewModel.composerText.isEmpty || viewModel.composerText.count > 2_000)
                    }
                    if viewModel.composerText.count > 2_000 {
                        Text("Keep questions under 2,000 characters.")
                            .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                    }
                    Spacer(minLength: 4)
                    Button("Send", systemImage: "arrow.up") { viewModel.submitQuestion() }
                        .disabled(!viewModel.isComposerEnabled || viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.composerText.count > 2_000)
                        .buttonStyle(.borderedProminent).controlSize(.regular).tint(OpenBridgePalette.ink)
                }

            }.padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(OpenBridgePalette.surface)
        .foregroundStyle(OpenBridgePalette.ink)
        .tint(OpenBridgePalette.blue)
        .font(OpenBridgeTypography.control)
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain).accessibilityLabel("Meeting Intelligence")
        .sheet(isPresented: Binding(get: { viewModel.webPreview != nil }, set: { if !$0 { viewModel.cancelWebPreview() } })) {
            webQueryPreview
        }
    }

    /// A bounded sheet keeps the full outgoing query and privacy copy readable
    /// even when the research rail is narrow. Actions stay outside the scroll area.
    private var webQueryPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review your Brave query").font(OpenBridgeTypography.heading(size: 20))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only the final query below goes to Brave. Remove private details. Your question, permitted meeting excerpts and retrieved sources go to your configured cloud AI. Provider charges and data policies apply.")
                        .font(OpenBridgeTypography.body)
                    Text("Question: " + (viewModel.webPreview?.question ?? ""))
                        .font(OpenBridgeTypography.metadata)
                    Text("Search query").font(OpenBridgeTypography.control)
                    TextField("Search query", text: $viewModel.webQueryDraft, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityLabel("Approved Brave search query")
                    Text("Limit to websites (optional)").font(OpenBridgeTypography.control)
                    TextField("docs.example.com, example.org", text: $viewModel.webSourceDomainsDraft)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Limit web sources to websites")
                    Text(viewModel.approvedWebDomains == nil
                         ? "Enter up to five domains separated by commas, without https:// or paths."
                         : "Blank searches any website. Otherwise only these domains and their subdomains are used. Choose sources you trust.")
                        .font(OpenBridgeTypography.metadata)
                    Text("Final query: " + viewModel.effectiveWebQuery)
                        .font(OpenBridgeTypography.body).textSelection(.enabled)
                    Text("\(viewModel.effectiveWebQuery.count)/600 characters · up to 75 words")
                        .font(OpenBridgeTypography.metadata)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { viewModel.cancelWebPreview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Search and answer") { viewModel.approveWebQuestion() }
                    .disabled(!viewModel.canApproveWebQuery).buttonStyle(.borderedProminent).tint(OpenBridgePalette.ink)
            }
        }.padding(24).frame(width: 560, height: 520)
            .font(OpenBridgeTypography.control).foregroundStyle(OpenBridgePalette.ink)
            .background(OpenBridgePalette.surface).preferredColorScheme(.light)
    }

    private func card(_ card: MeetingQuestionCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(card.question).font(OpenBridgeTypography.body(size: 16, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { viewModel.actions.dismiss(card.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(OpenBridgePalette.mutedInk).help("Dismiss question")
                    .accessibilityLabel("Dismiss question")
            }
            Text(card.scope.title).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            HStack(spacing: 6) {
                if card.phase.isPending { ProgressView().controlSize(.mini) }
                Text(card.phase.title).font(OpenBridgeTypography.body(size: 13, weight: .semibold))
            }.foregroundStyle(OpenBridgePalette.mutedInk)
            if card.phase == .waiting, let seconds = card.countdown {
                Text("Next section in about \(seconds)s").font(OpenBridgeTypography.mono(size: 13))
            }
            if card.phase == .waiting {
                Text("Waiting for recent audio. Transcription follows the next section boundary.").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            } else if card.phase == .transcribing {
                Text("Preparing the transcript through the time you pressed Send.").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            } else if card.phase == .queued {
                Text("Transcript ready. Waiting for the preceding question.").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
            }
            if let answer = card.answer, !answer.isEmpty {
                Text(card.scope == .history ? "From your meetings" : "From this meeting").font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                Text(answer).font(OpenBridgeTypography.body).lineSpacing(7).textSelection(.enabled)
            }
            if !card.webClaims.isEmpty {
                Divider()
                Label("Web research", systemImage: "globe").font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                ForEach(Array(card.webClaims.enumerated()), id: \.offset) { _, claim in
                    Text(claim.isSourceQuotation ? "Source quotation" : "Saved AI summary · Passage support not checked")
                        .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                    Text(claim.text).font(OpenBridgeTypography.body).lineSpacing(7).textSelection(.enabled)
                    ForEach(Array(claim.sources.enumerated()), id: \.offset) { _, source in
                        VStack(alignment: .leading, spacing: 4) {
                            Link(source.title, destination: source.url).font(OpenBridgeTypography.metadata)
                                .accessibilityLabel("Open web source: " + source.title)
                            Text(source.pageDate.map { "Page date: \($0) · Reported by search provider" }
                                 ?? "Page date unavailable")
                                .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                            DisclosureGroup("Source excerpt") {
                                Text(source.passage).font(OpenBridgeTypography.body).textSelection(.enabled)
                                Text("Retrieved " + source.retrievedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                            }.font(OpenBridgeTypography.metadata)
                        }
                    }
                }
            }
            if let query = card.webQuery {
                Text("Brave query: " + query).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                Text(card.webSourceDomains.isEmpty ? "Sources: Any website" : "Sources: " + card.webSourceDomains.joined(separator: ", "))
                    .font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                if card.phase == .failed || card.phase == .cancelled {
                    Text("Review a new web query below to try again.").font(OpenBridgeTypography.metadata)
                }
            }
            if let coverage = card.webCoverage { Text(coverage).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk) }
            if let explanation = card.explanation, !explanation.isEmpty {
                Divider()
                Label("General knowledge", systemImage: "sparkles").font(OpenBridgeTypography.body(size: 13, weight: .semibold))
                Text("Not meeting evidence · Not live web research").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                Text(explanation).font(OpenBridgeTypography.body).lineSpacing(7).textSelection(.enabled)
            }
            if let detail = card.detail { Text(detail).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk).textSelection(.enabled) }
            if let coverage = card.coverage { Text(coverage).font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk) }
            if !card.evidence.isEmpty {
                DisclosureGroup("Meeting sources (\(card.evidence.count))") {
                    ForEach(card.evidence) { evidence in
                        VStack(alignment: .leading, spacing: 4) {
                            // Inline source detail leaves the live recorder and Stop visible.
                            Text(evidence.sourceTitle ?? "Source passage").font(OpenBridgeTypography.body(size: 13, weight: .medium))
                            Text(evidence.passage).font(OpenBridgeTypography.body).lineSpacing(6).foregroundStyle(OpenBridgePalette.mutedInk).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }
                }.font(OpenBridgeTypography.metadata)
            }
            if card.phase.isPending {
                Button("Cancel question") { viewModel.actions.cancelQuestion(card.id) }.controlSize(.small)
            } else if (card.phase == .failed || card.phase == .cancelled) && card.mayRetry {
                Button("Retry") { viewModel.actions.retryQuestion(card.id) }.controlSize(.small)
            } else if card.phase == .answered {
                HStack {
                    Button("Copy") { viewModel.actions.copyCard(card.copyText) }
                    Button("Follow up") { viewModel.followUp(card.id) }
                }.controlSize(.small)
            }
            if card.mayUseAvailable {
                Button("Answer using available transcript") { viewModel.actions.answerUsingAvailable(card.id) }
                    .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(OpenBridgePalette.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OpenBridgePalette.border))
    }
}
