import Combine
import Foundation
import OpenBridgeUI

/// App-owned question lifetime, deliberately separate from audio lifetime.
/// Only Send enters this controller. Neither transcript callbacks nor model
/// output can create another request. Histories are local and meeting-scoped.
@MainActor
final class MeetingResearchController: ObservableObject {
    typealias Answer = @Sendable (CurrentMeetingQuestionRequest) async throws -> CurrentMeetingQuestionResponse
    @Published private(set) var snapshot = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil, meetingQuestions: [])
    private let store: MeetingSessionStore
    private let answer: Answer
    private let now: () -> Date
    private var meeting: MeetingManifest?
    private var progress: MeetingResearchProgress?
    private var histories: [String: [Entry]] = [:]
    private var loadedHistories = Set<String>()
    private var loadingHistories = Set<String>()
    private var historyLoadTokens: [String: UUID] = [:]
    private var unreadableHistories = Set<String>()
    private var lastSaved: [String: MeetingConversationDocument] = [:]
    private var saving: Task<Void, Never>?
    private var saveMessages: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var activeID: String?
    private var timer: Task<Void, Never>?
    private var enabled = true
    private var generation = UUID()
    private var followUpID: String?
    private var storeObservation: AnyCancellable?
    private var providerObservation: AnyCancellable?
    private var accessTask: Task<Void, Never>?
    private let configuredProvider: (@MainActor () -> ProviderConfiguration?)?
    private var approvedHistoryIDs: [String] = []
    private(set) var scope: MeetingResearchScope = .thisMeeting
    private var access = MeetingResearchAccess(canAsk: false, canEnable: false, detail: "Start or open a meeting.")
    var selectedMeetingID: String? { meeting?.meetingID }

    private struct Entry {
        let id: String
        let text: String
        let submittedAt: Date
        let cutoff: TimeInterval
        let priorQuestion: String?
        let priorSources: [String]
        var priorMeetingIDs: [String] = []
        var scope: MeetingResearchScope = .thisMeeting
        var historyIDs: [String] = []
        var permissionBlocked = false
        var allowPartial = false
        var phase: MeetingQuestionPhase = .waiting
        var detail: String?
        var countdown: Int?
        var request: CurrentMeetingQuestionRequest?
        var response: CurrentMeetingQuestionResponse?
        var useAvailable = false
        var snapshotLoading = false
        var approvedWebQuery: String? = nil
        var approvedWebDomains: [String]? = nil
    }

    init(store: MeetingSessionStore = MeetingSessionStore(), now: @escaping () -> Date = Date.init,
         configuredProvider: (@MainActor () -> ProviderConfiguration?)? = nil,
         answer: @escaping Answer) {
        self.store = store; self.now = now; self.answer = answer
        self.configuredProvider = configuredProvider
        storeObservation = NotificationCenter.default.publisher(for: MeetingSessionStore.manifestDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                let id = notification.userInfo?[MeetingSessionStore.changedMeetingIDUserInfoKey] as? String
                self?.validateRetainedMeetings(changedID: id)
                self?.refreshAccess()
            }
    }

    static func production(providerSettings: ProviderSettingsController?, braveResearch: BraveResearchSettings? = nil) -> MeetingResearchController {
        let store = MeetingSessionStore()
        let provider = providerSettings.map { ConfiguredResearchProvider(providerSettings: $0) }
        let controller = MeetingResearchController(store: store, configuredProvider: {
            guard let settings = providerSettings, settings.hasCurrentTestAttestation,
                  settings.settings.mayStartExternalRequest(hasCredential: settings.hasCredential) else { return nil }
            return settings.settings.configuration
        }) { request in
            // Re-read consent at dispatch, including deletion/retention. Never
            // upgrade an existing meeting from current global settings alone.
            let active = await MainActor.run { providerSettings?.settings.configuration }
            let authorized = await Task.detached(priority: .userInitiated) {
                guard let active else { return Optional<ProviderConfiguration>.none }
                let ids = Set(request.referencedMeetingIDs + [request.context.meetingID].compactMap { $0 })
                return MeetingResearchPermissionPolicy.authorizedConfiguration(ids: Array(ids), store: store, configuration: active)
            }.value
            guard let provider, let authorized, let expected = request.context.expectedCloudConfiguration,
                  authorized.hasSameProviderIdentity(as: expected) else {
                throw CloudRequestAuthorizationError.meetingConsentRequired
            }
            var enriched = request
            var coverage: String? = nil
            if let query = request.approvedWebQuery {
                guard let braveResearch else { throw WebResearchError.missingCredential }
                let result = try await braveResearch.research(.init(requestID: request.context.requestID,
                    questionText: query, webAuthority: true, allowedDomains: request.approvedWebDomains ?? []))
                guard !result.items.isEmpty else { throw WebResearchError.unavailable("No usable sources were found. Review your query and try again.") }
                enriched.webEvidence = result.items
                if case .partial(_, let dropped) = result { coverage = "Brave · \(result.items.count) sources · \(dropped) omitted · Selected excerpts" }
            }
            var response = try await provider.answerCurrentMeeting(enriched)
            if let coverage { response.webCoverage = coverage }
            return response
        }
        controller.providerObservation = providerSettings?.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in controller?.refreshAccess() }
        return controller
    }

    func selectMeeting(_ manifest: MeetingManifest) {
        if meeting?.meetingID != manifest.meetingID {
            cancelPending()
            generation = UUID()
            progress = nil
            followUpID = nil
            scope = .thisMeeting
        }
        meeting = manifest
        loadConversation(manifest)
        refreshAccess()
        publish()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { cancelPending() }
        refreshAccess()
        publish(force: true)
    }

    func followUp(_ id: String) {
        followUpID = id
        if let previous = entries.first(where: { $0.id == id }) { scope = previous.scope; publish() }
    }

    func setScope(_ value: MeetingResearchScope) { scope = value; publish() }

    /// No credentials or transcript bodies are exposed to the permission sheet.
    struct PermissionRow: Identifiable, Sendable {
        let id: String
        let title: String
        let date: Date
        let allowed: Bool
        let isCurrent: Bool
    }

    func permissionRows() async -> [PermissionRow] {
        let store = store, currentID = meeting?.meetingID
        let configuration = configuredProvider?()
        let useLegacyConfiguration = configuredProvider == nil
        return await Task.detached(priority: .utility) {
            var configuration = configuration
            if useLegacyConfiguration, let currentID, let current = try? store.load(meetingID: currentID) {
                configuration = MeetingResearchPermissionPolicy.provider(for: current, store: store)?.configuration
            }
            return ((try? store.listMeetings()) ?? []).filter {
                MeetingResearchPermissionPolicy.eligible($0) && ($0.meetingID == currentID || $0.state != .recording)
            }.map { value in
                let consent = MeetingResearchPermissionPolicy.provider(for: value, store: store)
                let allowed = consent.map { configuration?.hasSameProviderIdentity(as: $0.configuration) == true } ?? false
                return PermissionRow(id: value.meetingID, title: value.title, date: value.startedAt,
                    allowed: allowed, isCurrent: value.meetingID == currentID)
            }
        }.value
    }

    func applyResearchPermission(ids: [String], allowed: Bool, expectedProvider: ProviderConfiguration? = nil) async -> [String] {
        var provider: MeetingCloudProviderSnapshot? = nil
        if allowed {
            var configuration: ProviderConfiguration? = nil
            if let resolver = configuredProvider { configuration = resolver() }
            else if let meeting {
                configuration = MeetingResearchPermissionPolicy.provider(for: meeting, store: store)?.configuration
            }
            guard let configuration else { return ids }
            if let expectedProvider {
                guard configuration.hasSameProviderIdentity(as: expectedProvider) else { return ids }
            }
            provider = MeetingCloudProviderSnapshot(preset: configuration.preset, endpoint: configuration.baseURL,
                                                    model: configuration.model, timeout: configuration.timeout)
        }
        let store = store
        let frozenProvider = provider
        let failures = await Task.detached(priority: .utility) {
            var failed: [String] = []
            for id in ids {
                do { try store.setResearchPermission(meetingID: id, provider: frozenProvider) }
                catch { failed.append(id) }
            }
            return failed
        }.value
        refreshAccess()
        return failures
    }

    func refreshAccess() {
        accessTask?.cancel()
        guard let current = meeting else {
            access = .init(canAsk: false, canEnable: false, detail: "Start or open a meeting.")
            approvedHistoryIDs = []; publish(); return
        }
        let store = store, selectedID = current.meetingID
        let configured = configuredProvider?()
        let useLegacyConfiguration = configuredProvider == nil
        accessTask = Task { [weak self] in
            let values = await Task.detached(priority: .utility) {
                let current = try? store.load(meetingID: selectedID)
                let all = (try? store.listMeetings()) ?? []
                var configuration = configured
                if useLegacyConfiguration, let current {
                    configuration = MeetingResearchPermissionPolicy.provider(for: current, store: store)?.configuration
                }
                var permittedIDs = Set<String>()
                for value in all {
                    if let grant = MeetingResearchPermissionPolicy.provider(for: value, store: store),
                       configuration?.hasSameProviderIdentity(as: grant.configuration) == true {
                        permittedIDs.insert(value.meetingID)
                    }
                }
                let historyIDs = all.filter {
                    $0.meetingID != selectedID && $0.state != .recording && permittedIDs.contains($0.meetingID)
                }.map(\.meetingID)
                return (current, configuration, permittedIDs, historyIDs)
            }.value
            guard !Task.isCancelled, let self, self.meeting?.meetingID == selectedID else { return }
            guard let current = values.0 else { self.purgeMeeting(selectedID); return }
            self.meeting = current
            let eligible = MeetingResearchPermissionPolicy.eligible(current)
            let configuration = values.1
            let providerReady = configuration != nil
            let authorized = values.2.contains(selectedID)
            self.approvedHistoryIDs = values.3
            self.access = .init(canAsk: self.enabled && eligible && authorized, canEnable: eligible && providerReady,
                detail: !eligible ? "Research is unavailable because this transcript is not retained or has expired."
                    : !providerReady ? "Configure your cloud provider and pass Test Connection in Settings."
                    : authorized ? ""
                    : "Cloud research is off for this meeting. Enable it here without stopping recording.",
                provider: configuration.map { "\($0.preset.rawValue) · \($0.model)" } ?? "Cloud provider not ready",
                approvedHistoryCount: self.approvedHistoryIDs.count)
            for entry in self.entries {
                let sourceIDs = entry.request?.sourceMeetingIDs ?? []
                let validSources = sourceIDs.allSatisfy { values.2.contains($0) }
                if entry.phase.isPending && (!authorized || !validSources) {
                    if self.activeID == entry.id { self.task?.cancel() }
                    self.change(entry.id) { $0.phase = .failed; $0.permissionBlocked = true
                        $0.detail = "Research permission or provider changed. Review access before retrying." }
                } else if entry.permissionBlocked && authorized && validSources {
                    self.change(entry.id) { $0.permissionBlocked = false; $0.detail = "Cloud research is ready. Retry this question when you are ready." }
                }
            }
            self.publish()
        }
    }

    private func validateRetainedMeetings(changedID: String?) {
        var knownIDs = Set(histories.keys)
        if let id = meeting?.meetingID { knownIDs.insert(id) }
        for history in histories.values {
            for entry in history { knownIDs.formUnion(entry.request?.sourceMeetingIDs ?? []) }
        }
        let ids = changedID.map { knownIDs.contains($0) ? [$0] : [] } ?? Array(knownIDs)
        let store = store
        Task { [weak self] in
            let invalid = await Task.detached(priority: .utility) {
                ids.filter { id in
                    guard let value = try? store.load(meetingID: id) else { return true }
                    return !MeetingResearchPermissionPolicy.eligible(value)
                }
            }.value
            for id in invalid { self?.purgeMeeting(id) }
        }
    }

    func submit(_ text: String, id: String = UUID().uuidString, approvedWebQuery: String? = nil, approvedWebDomains: [String]? = nil) {
        if let approvedWebQuery, !BraveLLMContextProvider.validQuery(approvedWebQuery) { return }
        if let domains = approvedWebDomains {
            guard approvedWebQuery != nil, domains.count <= 5, domains.allSatisfy(WebSearchSourcePolicy.validDomain) else { return }
        }
        guard enabled, let meeting else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { return }
        guard !entries.contains(where: { $0.id == id }) else { return }
        let allowedIDs = Set([meeting.meetingID] + (scope == .history ? approvedHistoryIDs : []))
        let previous = followUpID.flatMap { id in entries.first { $0.id == id } }
            ?? entries.last(where: { $0.response != nil && $0.scope == scope
                && Set($0.request?.sourceMeetingIDs ?? []).isSubset(of: allowedIDs) })
        let cutoff = progress?.capturedThrough ?? (meeting.segments.compactMap(\.endOffset).max() ?? 0)
        var entry = Entry(id: id, text: text, submittedAt: now(), cutoff: cutoff,
            priorQuestion: previous?.text,
            priorSources: previous?.response?.claims.flatMap { claim in claim.citations.map { citation in
                if scope == .history, let meetingID = citation.meetingID {
                    return MeetingHistoryContextRetriever.sourceKey(meetingID: meetingID, segmentID: citation.segmentID)
                }
                return citation.segmentID
            } } ?? [])
        entry.scope = scope
        entry.approvedWebQuery = approvedWebQuery
        entry.approvedWebDomains = approvedWebDomains
        entry.priorMeetingIDs = previous?.request?.sourceMeetingIDs ?? []
        entry.historyIDs = scope == .history ? approvedHistoryIDs : []
        if MeetingResearchPermissionPolicy.provider(for: meeting, store: store) == nil {
            entry.phase = .failed
            entry.permissionBlocked = true
            entry.detail = "Cloud research is off. Enable cloud research in the rail; cleanup can remain off."
        } else if meeting.retentionPolicy == .neverStoreTranscript {
            entry.phase = .failed
            entry.detail = "Research is unavailable with Never store transcript. This recording's privacy choice is unchanged."
        }
        histories[meeting.meetingID, default: []].append(entry)
        followUpID = nil
        tick()
        startTimerIfNeeded()
    }

    func updateProgress(_ value: MeetingResearchProgress) {
        guard meeting?.meetingID == value.meetingID else { return }
        progress = value
        tick()
    }

    func recordingEnded(_ manifest: MeetingManifest, finalProgress: MeetingResearchProgress) {
        guard meeting?.meetingID == manifest.meetingID else { return }
        meeting = manifest
        progress = finalProgress
        tick()
    }

    func cancel(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].phase.isPending else { return }
        change(id) { $0.phase = .cancelled; $0.detail = "Question cancelled. Recording is unaffected." }
        if activeID == id { task?.cancel() }
        // Do not release the serial slot until transport cancellation unwinds.
        tick()
    }

    func retry(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }), !entry.phase.isPending,
              !entry.permissionBlocked, access.canAsk else { return }
        guard entry.approvedWebQuery == nil else { return } // A new web call needs a fresh preview.
        scope = entry.scope
        submit(entry.text)
    }

    func useAvailable(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }), entry.response == nil,
              !entry.permissionBlocked, access.canAsk,
              entry.phase != .failed || entry.allowPartial,
              [.waiting, .transcribing, .failed].contains(entry.phase) else { return }
        change(id) { $0.useAvailable = true; $0.phase = .waiting; $0.detail = nil }
        tick()
        startTimerIfNeeded()
    }

    func dismiss(_ id: String) {
        cancel(id)
        guard let meetingID = meeting?.meetingID else { return }
        histories[meetingID]?.removeAll { $0.id == id }
        publish()
    }

    func purgeMeeting(_ id: String) {
        if meeting?.meetingID == id {
            cancelPending(); meeting = nil; progress = nil; generation = UUID()
        }
        histories[id] = nil
        historyLoadTokens[id] = nil
        loadedHistories.remove(id); loadingHistories.remove(id); unreadableHistories.remove(id)
        lastSaved[id] = nil; saveMessages[id] = nil
        for key in Array(histories.keys) {
            if histories[key]?.contains(where: { $0.request?.sourceMeetingIDs.contains(id) == true || $0.priorMeetingIDs.contains(id) }) == true {
                task?.cancel()
                histories[key]?.removeAll { $0.request?.sourceMeetingIDs.contains(id) == true || $0.priorMeetingIDs.contains(id) }
                persistConversation(key)
            }
        }
        publish()
    }

    /// Also callable with an injected clock; no sleeping tests required.
    func tick() {
        guard enabled, let meeting else { publish(); return }
        for entry in entries where [.waiting, .transcribing].contains(entry.phase) {
            if !entry.useAvailable && now().timeIntervalSince(entry.submittedAt) >= 120 {
                change(entry.id) { $0.phase = .failed; $0.allowPartial = true; $0.detail = "The recent transcript is taking too long. Retry or answer using the transcript available now." }
                continue
            }
            guard !entry.snapshotLoading else { continue }
            if entry.useAvailable {
                loadSnapshot(for: entry, readyThrough: nil, windowIDs: nil)
            } else if let progress {
                switch progress.readiness(through: entry.cutoff) {
                case .waiting(let seconds):
                    change(entry.id) { $0.phase = .waiting; $0.countdown = seconds }
                case .transcribing:
                    change(entry.id) { $0.phase = .transcribing; $0.countdown = nil }
                case .failed:
                    change(entry.id) { $0.phase = .failed; $0.allowPartial = true; $0.detail = "Recent audio could not be processed. Recover the transcript or answer using available text." }
                case .ready(let through, let ids): loadSnapshot(for: entry, readyThrough: through, windowIDs: ids)
                }
            } else if meeting.state == .completed {
                loadSnapshot(for: entry, readyThrough: nil, windowIDs: nil)
            }
        }
        startNext()
        publish()
    }

    private var entries: [Entry] { meeting.flatMap { histories[$0.meetingID] } ?? [] }

    private func change(_ id: String, _ mutation: (inout Entry) -> Void) {
        guard let meetingID = meeting?.meetingID, let i = histories[meetingID]?.firstIndex(where: { $0.id == id }) else { return }
        mutation(&histories[meetingID]![i])
        persistConversation(meetingID)
    }

    private func loadSnapshot(for entry: Entry, readyThrough: TimeInterval?, windowIDs: Set<String>?) {
        guard let meeting else { return }
        change(entry.id) { $0.snapshotLoading = true; $0.countdown = nil; $0.phase = .transcribing }
        let token = generation, store = store
        Task { [weak self] in
            do {
                let manifest = try await Task.detached(priority: .userInitiated) { try store.load(meetingID: meeting.meetingID) }.value
                guard let self, self.generation == token,
                      self.entries.first(where: { $0.id == entry.id })?.phase.isPending == true else { return }
                guard let provider = MeetingResearchPermissionPolicy.provider(for: manifest, store: store),
                      manifest.retentionPolicy != .neverStoreTranscript else {
                    throw CloudRequestAuthorizationError.meetingConsentRequired
                }
                let segments = manifest.segments.filter { segment in
                    guard let ids = windowIDs else { return true }
                    return ids.contains(segment.artifactID ?? "room:\(segment.sequence)")
                }
                let selection = await Task.detached(priority: .userInitiated) {
                    var current = manifest; current.segments = segments
                    if entry.scope == .history {
                        let history = entry.historyIDs.compactMap { try? store.load(meetingID: $0) }.filter { value in
                            guard let consent = MeetingResearchPermissionPolicy.provider(for: value, store: store) else { return false }
                            return consent.configuration.hasSameProviderIdentity(as: provider.configuration)
                        }
                        return MeetingHistoryContextRetriever.select(current: current, history: history,
                            question: entry.text, previousQuestion: entry.priorQuestion, previousSourceIDs: entry.priorSources)
                    }
                    var selection = CurrentMeetingContextRetriever.select(meetingID: manifest.meetingID, segments: segments,
                        question: entry.text, previousQuestion: entry.priorQuestion, previousSourceIDs: entry.priorSources)
                    selection = .init(passages: selection.passages.map { passage in
                        var result = passage; result.meetingID = manifest.meetingID; result.meetingTitle = manifest.title
                        result.meetingDate = manifest.startedAt; return result
                    }, isPartial: selection.isPartial)
                    return selection
                }.value
                guard self.generation == token,
                      self.entries.first(where: { $0.id == entry.id })?.phase.isPending == true else { return }
                guard !selection.passages.isEmpty else {
                    self.change(entry.id) { $0.snapshotLoading = false; $0.phase = .failed; $0.detail = "There is no transcribed discussion to answer from yet. Retry after speech has been transcribed." }
                    self.publish(); return
                }
                var request = CurrentMeetingQuestionRequest(context: .init(requestID: entry.id,
                    meetingID: manifest.meetingID, workspaceID: manifest.workspaceID, mode: .cloudExperiment,
                    expectedCloudConfiguration: provider.configuration), question: entry.text,
                    previousQuestion: entry.priorQuestion, passages: selection.passages,
                    contextIsPartial: selection.isPartial || entry.useAvailable,
                    coveredThrough: readyThrough ?? (segments.compactMap(\.endOffset).max() ?? 0))
                request.scope = entry.scope
                request.approvedWebQuery = entry.approvedWebQuery
                request.approvedWebDomains = entry.approvedWebDomains
                request.sourceMeetingIDs = Array(Set(selection.passages.compactMap(\.meetingID) + entry.priorMeetingIDs)).sorted()
                self.change(entry.id) { $0.request = request; $0.phase = .queued; $0.snapshotLoading = false }
                self.tick()
            } catch {
                guard let self, self.generation == token,
                      self.entries.first(where: { $0.id == entry.id })?.phase.isPending == true else { return }
                self.change(entry.id) {
                    $0.snapshotLoading = false; $0.phase = .failed
                    $0.permissionBlocked = error is CloudRequestAuthorizationError
                    $0.detail = $0.permissionBlocked ? "Research permission changed. Review cloud research settings before retrying."
                        : "The saved transcript could not be read. Reopen the meeting and retry. Recording is unaffected."
                }
                self.publish()
            }
        }
    }

    private func startNext() {
        guard let meetingID = meeting?.meetingID, loadedHistories.contains(meetingID),
              task == nil, let entry = entries.first(where: { $0.phase.isPending }),
              entry.phase == .queued, var request = entry.request else { return }
        let currentlyApproved = Set(approvedHistoryIDs)
        let allowedIDs = Set([meetingID] + (entry.scope == .history ? entry.historyIDs.filter(currentlyApproved.contains) : []))
        let preceding = entries.prefix { $0.id != entry.id }.compactMap { value -> MeetingConversationContext? in
            guard let response = value.response else { return nil }
            let text = (response.claims.map(\.text) + (response.webClaims ?? []).map { "Previously retrieved web evidence: " + $0.text } + [response.explanation, response.limitation].compactMap { $0 }).joined(separator: "\n\n")
            return .init(question: value.text, answer: text, sourceMeetingIDs: value.request?.sourceMeetingIDs ?? [meetingID])
        }
        request.conversation = MeetingConversationContextPolicy.select(preceding, allowedIDs: allowedIDs)
        request.sourceMeetingIDs = Array(Set(request.sourceMeetingIDs + request.conversation.flatMap(\.sourceMeetingIDs))).sorted()
        change(entry.id) { $0.request = request }
        let dispatchedRequest = request
        activeID = entry.id
        change(entry.id) { $0.phase = .answering }
        let token = generation, answer = answer
        task = Task { [weak self] in
            defer {
                if let self {
                    self.task = nil; self.activeID = nil
                    self.tick()
                }
            }
            do {
                try Task.checkCancellation()
                let response = try await answer(dispatchedRequest)
                try Task.checkCancellation()
                guard let self, self.generation == token,
                      self.entries.first(where: { $0.id == entry.id })?.phase == .answering else { return }
                guard response.requestID == entry.id else { throw ResearchProviderError.invalidJSON("request identity mismatch") }
                self.change(entry.id) { $0.response = response; $0.phase = .answered; $0.detail = response.limitation }
            } catch {
                guard let self, self.generation == token,
                      self.entries.first(where: { $0.id == entry.id })?.phase == .answering else { return }
                self.change(entry.id) {
                    $0.phase = .failed
                    $0.detail = (error as? WebResearchServiceError)?.errorDescription ?? (error as? WebResearchError)?.errorDescription
                        ?? Self.providerFailureDescription(error)
                        ?? "The cloud request failed or timed out. Check cloud settings and connection. Submitting again may incur a charge."
                }
            }
        }
    }

    /// Only app-owned categories reach the conversation. Never persist arbitrary
    /// provider details, which can contain echoed prompts or credentials.
    static func providerFailureDescription(_ error: Error) -> String? {
        guard let error = error as? ResearchProviderError else { return nil }
        switch error {
        case .timeout: return "The cloud AI timed out. Try again when the provider is available."
        case .cancelled, .staleRequest: return "The cloud AI request was cancelled."
        case .rateLimited: return "The cloud AI is rate-limiting requests. Wait before submitting again."
        case .modeBlocked: return "Cloud research access changed. Review your provider and meeting permissions."
        case .unsupportedOperation: return "The cloud AI is not ready for research. Load your saved key and check Test Connection in Settings."
        case .invalidJSON(let reason):
            let reasons: [String: String] = [
                "current-meeting answer schema mismatch": "response format",
                "chat-completions response schema mismatch": "response envelope",
                "unsupported meeting citation": "meeting citations",
                "missing web claims": "missing web answer",
                "too many web claims": "answer length",
                "unsupported web citation": "web citations"
            ]
            return "The cloud AI's answer could not be verified (\(reasons[reason] ?? "response validation")). Try a shorter question. No unverified answer was saved."
        case .providerError(let reason):
            let reasons: [String: String] = [
                "The configured API key was rejected.": "The cloud AI rejected the saved key. Check it in Settings.",
                "Provider credit or billing is unavailable.": "The cloud AI account has no available credit. Check the provider's billing settings.",
                "No network connection is available.": "The cloud AI could not be reached. Check your internet connection.",
                "The provider response exceeded the safety limit.": "The cloud AI response was too large. Try a shorter question.",
                "Another cloud request is already running.": "Another cloud AI request is running. Wait for it to finish."
            ]
            if let message = reasons[reason] { return message }
            let prefix = "The provider returned HTTP "
            if reason.hasPrefix(prefix), reason.hasSuffix("."),
               let code = Int(reason.dropFirst(prefix.count).dropLast()), (400...599).contains(code) {
                return "The cloud AI returned HTTP \(code). Check your provider settings before trying again."
            }
            return "The cloud AI request failed. Check your provider settings before trying again."
        }
    }

    private func cancelPending() {
        for entry in entries where entry.phase.isPending { change(entry.id) { $0.phase = .cancelled; $0.detail = "Question cancelled when leaving this meeting." } }
        task?.cancel()
        timer?.cancel(); timer = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
                if !self.entries.contains(where: { $0.phase.isPending }) { self.timer = nil; return }
            }
        }
    }

    private func publish(force: Bool = false) {
        if let id = meeting?.meetingID { persistConversation(id) }
        let cards: [MeetingQuestionCard] = entries.map { self.presentation(for: $0) }
        var next = ResearchRailSnapshot(state: entries.contains(where: { $0.phase.isPending }) ? .searching : .quiet,
            cards: [], activeQuestion: nil, meetingQuestions: cards, meetingTitle: meeting?.title)
        next.meetingContextID = meeting?.meetingID
        next.researchAccess = access
        next.researchScope = scope
        next.conversationNotice = meeting.flatMap { saveMessages[$0.meetingID] }
        if force || snapshot != next { snapshot = next }
    }

    func flushConversationSaves() async { await saving?.value }

    private func archived(_ id: String) -> MeetingConversationDocument {
        .init(meetingID: id, questions: (histories[id] ?? []).map {
            .init(id: $0.id, question: $0.text, submittedAt: $0.submittedAt, cutoff: $0.cutoff,
                phase: $0.phase.rawValue, scope: $0.scope.rawValue, detail: $0.detail,
                passages: $0.request?.passages ?? [], sourceMeetingIDs: $0.request?.sourceMeetingIDs ?? [],
                coveredThrough: $0.request?.coveredThrough ?? 0, partial: $0.request?.contextIsPartial ?? true,
                response: $0.response, approvedWebQuery: $0.approvedWebQuery, approvedWebDomains: $0.approvedWebDomains)
        })
    }

    private func persistConversation(_ id: String) {
        guard loadedHistories.contains(id), !unreadableHistories.contains(id), histories[id] != nil else { return }
        let document = archived(id)
        guard document != lastSaved[id] else { return }
        lastSaved[id] = document
        let previous = saving, storage = MeetingConversationStore(store: store)
        saving = Task { [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority: .utility) { try storage.save(document) }.value
                self?.saveMessages[id] = nil
            } catch {
                self?.saveMessages[id] = "Conversation could not be saved. Keep this window open and copy any answers you need."
            }
            // No recursive retry loop; next explicit conversation change retries.
            if self?.meeting?.meetingID == id {
                var next = self!.snapshot
                next.conversationNotice = self?.saveMessages[id]
                self?.snapshot = next
            }
        }
    }

    private func loadConversation(_ manifest: MeetingManifest) {
        let id = manifest.meetingID
        guard !loadedHistories.contains(id), loadingHistories.insert(id).inserted else { return }
        let token = UUID()
        historyLoadTokens[id] = token
        let storage = MeetingConversationStore(store: store), previous = saving
        Task { [weak self] in
            await previous?.value
            do {
                let saved = try await Task.detached(priority: .utility) { try storage.load(id) }.value
                guard let self, self.historyLoadTokens[id] == token else { return }
                let current = self.histories[id] ?? []
                let currentIDs = Set(current.map(\.id))
                let restored = saved.questions.filter { !currentIDs.contains($0.id) }.map { value -> Entry in
                    var entry = Entry(id: value.id, text: value.question, submittedAt: value.submittedAt,
                        cutoff: value.cutoff, priorQuestion: nil, priorSources: [])
                    entry.scope = MeetingResearchScope(rawValue: value.scope) ?? .thisMeeting
                    entry.phase = MeetingQuestionPhase(rawValue: value.phase) ?? .cancelled
                    entry.detail = value.detail
                    if entry.phase.isPending {
                        entry.phase = .cancelled
                        entry.detail = "Interrupted when the app closed. Retry when ready; this may incur another provider charge."
                    }
                    entry.response = value.response
                    entry.approvedWebQuery = value.approvedWebQuery
                    entry.approvedWebDomains = value.approvedWebDomains
                    var request = CurrentMeetingQuestionRequest(context: .init(requestID: value.id, meetingID: id,
                        workspaceID: manifest.workspaceID, mode: .cloudExperiment,
                        expectedCloudConfiguration: MeetingResearchPermissionPolicy.provider(for: manifest, store: self.store)?.configuration),
                        question: value.question, previousQuestion: nil, passages: value.passages,
                        contextIsPartial: value.partial, coveredThrough: value.coveredThrough)
                    request.approvedWebQuery = value.approvedWebQuery
                    request.approvedWebDomains = value.approvedWebDomains
                    request.scope = entry.scope; request.sourceMeetingIDs = value.sourceMeetingIDs
                    entry.request = request
                    return entry
                }
                self.histories[id] = restored + current
            } catch {
                guard self?.historyLoadTokens[id] == token else { return }
                self?.unreadableHistories.insert(id)
                self?.saveMessages[id] = "Saved conversation is unavailable. Existing files are unchanged; new answers in this window are not saved."
            }
            guard let self, self.historyLoadTokens[id] == token else { return }
            self.loadingHistories.remove(id)
            self.loadedHistories.insert(id)
            if self.meeting?.meetingID == id { self.tick() }
        }
    }

    private func presentation(for entry: Entry) -> MeetingQuestionCard {
            let citations: [CurrentMeetingCitation] = entry.response?.claims.flatMap(\.citations) ?? []
            let evidence: [ResearchEvidence] = citations.enumerated().compactMap { i, citation -> ResearchEvidence? in
                guard let passage = entry.request?.passages.first(where: {
                    $0.segmentID == citation.segmentID && (citation.meetingID == nil || $0.meetingID == citation.meetingID)
                }),
                      let meetingID = meeting?.meetingID else { return nil }
                let stamp = Self.timestamp(passage.start ?? 0)
                let sourceID = passage.meetingID ?? meetingID
                let prior = sourceID != meetingID
                let title = prior ? "\(passage.meetingTitle ?? "Saved meeting") · \(passage.meetingDate?.formatted(date: .abbreviated, time: .omitted) ?? "") · \(stamp)" : "\(passage.sourceLabel) · \(stamp)"
                return .init(id: "\(entry.id):\(i)", type: prior ? .priorMeeting : .currentMeeting, passage: citation.quote,
                    sourceLocator: prior ? .priorMeeting(meetingID: sourceID, segmentID: citation.segmentID)
                        : .currentPassage(segmentID: citation.segmentID, meetingID: sourceID), sourceTitle: title)
            }
            let answerText = entry.response?.claims.map(\.text).joined(separator: "\n\n")
            let coverage = entry.request.map { "Transcript through \(Self.timestamp($0.coveredThrough))" + ($0.contextIsPartial ? " · Selected excerpts" : "") }
            let webClaims = (entry.response?.webClaims ?? []).map { claim in
                MeetingWebClaim(text: claim.text, isSourceQuotation: claim.isSourceQuotation == true, sources: claim.sources.filter { WebResearchResponseValidator.isSafeSourceURL($0.url) }.map {
                    MeetingWebSource(title: $0.title, url: $0.url, passage: $0.passage,
                        retrievedAt: $0.retrievedAt, pageDate: $0.pageDate)
                })
            }
            return MeetingQuestionCard(id: entry.id, question: entry.text, phase: entry.phase, detail: entry.detail,
                countdown: entry.countdown, answer: answerText,
                explanation: entry.response?.explanation, evidence: evidence,
                coverage: coverage,
                mayUseAvailable: access.canAsk && !entry.permissionBlocked && entry.response == nil
                    && ([.waiting, .transcribing].contains(entry.phase) || (entry.phase == .failed && entry.allowPartial)),
                scope: entry.scope, mayRetry: entry.approvedWebQuery == nil && !entry.permissionBlocked && access.canAsk,
                webQuery: entry.approvedWebQuery, webSourceDomains: entry.approvedWebDomains ?? [], webClaims: webClaims, webCoverage: entry.response?.webCoverage)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
}
