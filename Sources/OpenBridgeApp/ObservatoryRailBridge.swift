import AppKit
import Combine
import OpenBridgeUI
import SwiftUI

/// A deterministic request from an evidence band to the Meetings page. The
/// app opens the saved meeting and surfaces the exact transcript segment;
/// provider output never controls this navigation identity.
struct ResearchSourceNavigationRequest: Sendable {
    static let notification = Notification.Name("openbridge.research.openSource")

    let meetingID: String
    let segmentID: String

    func post() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }
}

/// Thread-safe per-meeting manifest cache for evidence titles (round-3,
/// lunr-studio/Openbridge-Beta#299 P2): one manifest decode per distinct
/// meeting instead of one per evidence row, usable from any actor.
final class EvidenceTitleCache: @unchecked Sendable {
    private let lock = NSLock()
    private let store: MeetingSessionStore
    private var manifests: [String: MeetingManifest] = [:]
    private var loadCounts: [String: Int] = [:]

    private var observer: NSObjectProtocol?

    init(store: MeetingSessionStore = MeetingSessionStore()) {
        self.store = store
        // Round-4 (P2 stale cache): live appends and renames mutate the
        // manifest after it was cached; evict on the store's change
        // notification so evidence titles never go stale.
        observer = NotificationCenter.default.addObserver(
            forName: MeetingSessionStore.manifestDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let meetingID = notification.userInfo?[MeetingSessionStore.changedMeetingIDUserInfoKey]
                      as? String
            else { return }
            self.evict(meetingID: meetingID)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func evict(meetingID: String) {
        lock.lock()
        defer { lock.unlock() }
        manifests.removeValue(forKey: meetingID)
    }

    func manifest(meetingID: String) -> MeetingManifest? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = manifests[meetingID] { return cached }
        guard let loaded = try? store.load(meetingID: meetingID) else { return nil }
        manifests[meetingID] = loaded
        loadCounts[meetingID, default: 0] += 1
        return loaded
    }

    /// Test seam: manifest decode count per meeting ID.
    func decodeCounts() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return loadCounts
    }
}

/// Bridges the app-scoped Release coordinator into the provider-neutral rail
/// shell. The bridge owns UI actions only; question execution remains in the
/// coordinator and all cloud traffic remains behind the central gate.
@MainActor
final class ObservatoryRailBridge: ObservableObject {
    static let shared = ObservatoryRailBridge()

    private var cancellables = Set<AnyCancellable>()
    private var coordinator: ObservatoryCoordinator?
    private weak var viewModel: ResearchRailViewModel?

    func makeViewModel(coordinator supplied: ObservatoryCoordinator? = nil) -> ResearchRailViewModel {
        cancellables.removeAll()
        if supplied == nil, let controller = AppState.sharedMeetingResearch {
            return makeTypedViewModel(controller)
        }
        let coordinator = supplied ?? AppState.sharedObservatoryForRail
            ?? ObservatoryCoordinator.makeForLiveIntegration()
        self.coordinator = coordinator

        let vm = ResearchRailViewModel(
            snapshot: ResearchRailSnapshot(
                state: coordinator.railState,
                cards: [],
                activeQuestion: nil
            ),
            actions: ResearchRailActions(
                highlightCurrentPassage: { segmentID, meetingID in
                    ResearchSourceNavigationRequest(
                        meetingID: meetingID,
                        segmentID: segmentID
                    ).post()
                },
                openPriorMeeting: { meetingID, segmentID in
                    ResearchSourceNavigationRequest(
                        meetingID: meetingID,
                        segmentID: segmentID ?? ""
                    ).post()
                },
                openWebSource: { url in
                    NSWorkspace.shared.open(url)
                },
                dismiss: { [weak self] cardID in
                    self?.dismissCard(cardID)
                },
                copyCard: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                followUp: { [weak self] _ in
                    self?.viewModel?.composerText = "Follow up: "
                    self?.viewModel?.focusMode = .research
                },
                retry: { [weak coordinator] in
                    guard ResearchObservatoryFeatureFlag.isEnabled,
                          AppState.shared?.isResearchIndexing != true else { return }
                    coordinator?.retryLastQuestion()
                }
            )
        )
        viewModel = vm
        vm.onSubmitQuestion = { [weak coordinator] text in
            guard ResearchObservatoryFeatureFlag.isEnabled,
                  AppState.shared?.isResearchIndexing != true else { return }
            coordinator?.submitTyped(text)
        }

        if let appState = AppState.shared {
            vm.isComposerEnabled = ResearchObservatoryFeatureFlag.isEnabled
                && !appState.isResearchIndexing
            appState.$isResearchIndexing
                .receive(on: DispatchQueue.main)
                .sink { [weak vm] isIndexing in
                    vm?.isComposerEnabled = ResearchObservatoryFeatureFlag.isEnabled
                        && !isIndexing
                }
                .store(in: &cancellables)
        } else {
            vm.isComposerEnabled = false
        }

        Publishers.CombineLatest4(coordinator.$railState, coordinator.$completedAnswers, coordinator.$activeQuestion, coordinator.$spokenStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak vm] state, answers, question, spokenStatus in
                guard let vm else { return }
                // Round-3 (P2): card construction resolves evidence titles
                // from per-meeting cached manifests; it runs off the main
                // actor so manifest decoding never blocks the UI. A serial
                // guard drops stale out-of-order snapshots.
                let serial = Self.nextSnapshotSerial()
                Task { @MainActor in
                    let cards = await Task.detached(priority: .userInitiated) {
                        answers.reversed().flatMap { Self.cards(for: $0) }
                    }.value
                    guard serial == Self.currentSnapshotSerial() else { return }
                    vm.updateSnapshot(ResearchRailSnapshot(
                        state: state,
                        cards: cards,
                        activeQuestion: question.map {
                            ResearchQuestion(id: $0.id, text: $0.text,
                                origin: Self.questionOrigin($0.origin))
                        },
                        spokenStatus: spokenStatus
                    ))
                }
            }
            .store(in: &cancellables)
        return vm
    }

    /// Opens the rail composer for a deliberate question about a new meeting.
    /// The meeting's immutable privacy snapshot controls whether cloud may be
    /// selected; older/local meetings always remain local-only.
    func beginAsk(from meeting: MeetingManifest) {
        AppState.sharedMeetingResearch?.selectMeeting(meeting)
        let target = coordinator ?? AppState.sharedObservatoryForRail
        coordinator = target
        target?.setMeetingContext(
            meetingID: meeting.meetingID,
            workspaceID: meeting.workspaceID ?? Workspace.defaultWorkspace.id,
            allowsCloud: meeting.aiMode.maySendTranscriptToCloud
                && meeting.privacySettings.allowsCloudIntelligence
                && meeting.intelligenceConfiguration?.cloudProvider != nil
        )
        viewModel?.focusMode = .research
        viewModel?.composerText = ""
    }

    private func makeTypedViewModel(_ controller: MeetingResearchController) -> ResearchRailViewModel {
        let vm = ResearchRailViewModel(snapshot: controller.snapshot, actions: ResearchRailActions(
            highlightCurrentPassage: { segmentID, meetingID in
                ResearchSourceNavigationRequest(meetingID: meetingID, segmentID: segmentID).post()
            },
            dismiss: { [weak controller] in controller?.dismiss($0) },
            copyCard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            followUp: { [weak controller, weak self] id in
                controller?.followUp(id)
                self?.viewModel?.composerText = "Explain that in more detail."
                self?.viewModel?.focusMode = .research
            },
            cancelQuestion: { [weak controller] in controller?.cancel($0) },
            retryQuestion: { [weak controller] in controller?.retry($0) },
            answerUsingAvailable: { [weak controller] in controller?.useAvailable($0) }
        ))
        viewModel = vm
        vm.onSubmitQuestion = { [weak controller] text in
            guard ResearchObservatoryFeatureFlag.isEnabled else { return }
            controller?.submit(text)
        }
        vm.onSubmitWebQuestion = { [weak controller] question, query, domains, meetingID in
            guard ResearchObservatoryFeatureFlag.isEnabled, controller?.selectedMeetingID == meetingID else { return }
            controller?.submit(question, approvedWebQuery: query, approvedWebDomains: domains)
        }
        controller.$snapshot.receive(on: DispatchQueue.main).sink { [weak vm] snapshot in
            vm?.updateSnapshot(snapshot)
            vm?.isComposerEnabled = ResearchObservatoryFeatureFlag.isEnabled && snapshot.researchAccess?.canAsk == true
        }.store(in: &cancellables)
        vm.isComposerEnabled = controller.snapshot.researchAccess?.canAsk == true
        vm.onResearchScope = { [weak controller] in controller?.setScope($0) }
        vm.onManageResearch = { NotificationCenter.default.post(name: .manageMeetingResearch, object: nil) }
        return vm
    }

    private nonisolated(unsafe) static var snapshotSerial: UInt64 = 0
    private nonisolated static let snapshotSerialLock = NSLock()

    private nonisolated static func nextSnapshotSerial() -> UInt64 {
        snapshotSerialLock.lock()
        snapshotSerial &+= 1
        defer { snapshotSerialLock.unlock() }
        return snapshotSerial
    }

    private nonisolated static func currentSnapshotSerial() -> UInt64 {
        snapshotSerialLock.lock()
        defer { snapshotSerialLock.unlock() }
        return snapshotSerial
    }

    private func dismissCard(_ cardID: String) {
        coordinator?.dismissAnswer(cardID)
    }

    private static func questionOrigin(_ origin: ObservatoryQuestionOrigin) -> ResearchQuestionOrigin {
        if case .spoken = origin { return .spoken }
        return .typed
    }

    /// lunr-studio/Openbridge-Beta#299 (Build 24): exact meeting identity +
    /// timestamp for evidence cards, resolved from the meeting store at
    /// render time. The label is store-owned (title/date/segment offset);
    /// it is never model-generated. Nil when the manifest cannot be loaded,
    /// in which case the UI falls back to the generic source-type label.
    nonisolated static let titleCache = EvidenceTitleCache()

    nonisolated static func sourceTitle(
        meetingID: String,
        segmentID: String?,
        store: MeetingSessionStore = MeetingSessionStore(),
        cache: EvidenceTitleCache? = nil
    ) -> String? {
        let manifest = cache?.manifest(meetingID: meetingID)
            ?? (try? store.load(meetingID: meetingID))
        guard let manifest else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        var title = "\(manifest.title) · \(formatter.string(from: manifest.startedAt))"
        if let segmentID,
           let segment = manifest.segments.first(where: { $0.id == segmentID }),
           let offset = segment.startOffset {
            // Fix-cycle P2 (lunr-studio/Openbridge-Beta#299): identical
            // conversion to the transcript display
            // (MeetingReplayView.formattedOffset): truncate, hh:mm:ss — the
            // chip timestamp can never disagree with its source.
            let total = Int(offset)
            title += " · \(String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60))"
        }
        return title
    }

    nonisolated static func cards(for answer: ObservatoryAnswer) -> [ResearchCard] {
        let evidence = answer.evidence.map { item -> ResearchEvidence in
            switch item.source {
            case .modelSynthesis:
                return ResearchEvidence(
                    id: item.id,
                    type: .modelSynthesis,
                    passage: item.passage,
                    sourceLocator: .priorMeeting(meetingID: "", segmentID: nil),
                    confidence: item.confidence
                )
            case .web(let url):
                return ResearchEvidence(
                    id: item.id,
                    type: .web,
                    passage: item.passage,
                    sourceLocator: .web(
                        url: URL(string: url) ?? URL(string: "https://openbridge.invalid")!,
                        title: "Web source"
                    ),
                    confidence: item.confidence
                )
            case .currentMeeting(let meetingID, let segmentID):
                return ResearchEvidence(
                    id: item.id,
                    type: .currentMeeting,
                    passage: item.passage,
                    sourceLocator: .currentPassage(
                        segmentID: segmentID,
                        meetingID: meetingID
                    ),
                    confidence: item.confidence,
                    sourceTitle: Self.sourceTitle(meetingID: meetingID, segmentID: segmentID, cache: Self.titleCache)
                )
            case .priorMeeting(let meetingID, let segmentID):
                return ResearchEvidence(
                    id: item.id,
                    type: .priorMeeting,
                    passage: item.passage,
                    sourceLocator: .priorMeeting(
                        meetingID: meetingID,
                        segmentID: segmentID
                    ),
                    confidence: item.confidence,
                    sourceTitle: Self.sourceTitle(meetingID: meetingID, segmentID: segmentID, cache: Self.titleCache)
                )
            }
        }

        let isSynthesis = answer.evidence.allSatisfy { $0.source == .modelSynthesis }
        let hasCurrent = answer.evidence.contains {
            if case .currentMeeting = $0.source { return true }
            return false
        }
        return [ResearchCard(
            id: "answer-\(answer.questionID)",
            variant: .priorDiscussion,
            title: answer.questionText.isEmpty
                ? (isSynthesis ? "Model knowledge" : (hasCurrent ? "Meeting evidence" : "Prior meetings"))
                : answer.questionText,
            summary: answer.answerText,
            evidence: evidence,
            isPinned: false,
            isDismissed: false,
            isExpanded: true
        )]
    }
}
