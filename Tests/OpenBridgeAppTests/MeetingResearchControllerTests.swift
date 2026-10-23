import Foundation
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

private actor QuestionTestProvider {
    var requests: [CurrentMeetingQuestionRequest] = []
    var held = false
    var fail = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(held: Bool = false, fail: Bool = false) { self.held = held; self.fail = fail }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func answer(_ request: CurrentMeetingQuestionRequest) async throws -> CurrentMeetingQuestionResponse {
        requests.append(request)
        if held { await withCheckedContinuation { continuation = $0 } }
        if fail { throw URLError(.timedOut) }
        let passage = request.passages[0]
        return .init(requestID: request.context.requestID,
            claims: [.init(text: "The meeting selected Cedar.", citations: [.init(segmentID: passage.segmentID, quote: passage.text)])],
            explanation: "A codename identifies a project.", limitation: nil)
    }
}

@Suite(.serialized) @MainActor struct MeetingResearchControllerTests {
    @Test func failedAnswersExplainTheStageWithoutExposingProviderContent() async throws {
        let cases: [(ResearchProviderError, String)] = [
            (.invalidJSON("unsupported web citation"), "web citations"),
            (.providerError("The provider returned HTTP 503."), "HTTP 503"),
            (.providerError("Provider credit or billing is unavailable."), "credit"),
            (.providerError("synthetic-private-prompt-and-key"), "cloud AI request failed"),
            (.invalidJSON("synthetic-private-prompt-and-key"), "response validation")
        ]
        for (error, expected) in cases {
            let (store, manifest) = try fixture(state: .completed)
            defer { try? store.deleteAll() }
            let controller = MeetingResearchController(store: store, answer: { _ in throw error })
            controller.selectMeeting(manifest)
            controller.submit("What codename?", id: "failed")
            await eventually { controller.snapshot.meetingQuestions?.first?.phase == .failed }
            let detail = try #require(controller.snapshot.meetingQuestions?.first?.detail)
            #expect(detail.contains(expected))
            #expect(!detail.contains("synthetic-private-prompt-and-key"))
            #expect(controller.snapshot.meetingQuestions?.first?.evidence.isEmpty == true)
        }
    }

    private func fixture(state: MeetingSessionState = .recording, cloud: Bool = true) throws -> (MeetingSessionStore, MeetingManifest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typed-research-tests-\(UUID().uuidString)")
        let store = MeetingSessionStore(rootDirectory: root, meetingDeletionObserver: { _ in })
        let configuration = try MeetingIntelligenceConfigurationResolver.snapshot(cleanupEnabled: false,
            aiMode: cloud ? .cloudOptIn : .localOnly,
            providerSettings: ProviderSettings(cloudEnabled: true, consentGranted: true),
            hasCredential: true, providerWasTested: true)
        let id = UUID().uuidString
        let segment = MeetingTranscriptSegment(id: "first", meetingID: id, sequence: 0,
            startOffset: 0, endOffset: 30, text: "The meeting selected Cedar as the project codename.")
        let manifest = MeetingManifest(meetingID: id, title: "Synthetic research", state: state,
            aiMode: cloud ? .cloudOptIn : .localOnly, segments: [segment],
            privacySettings: .init(allowsLocalIntelligence: true, allowsCloudIntelligence: cloud),
            intelligenceConfiguration: configuration)
        try store.create(manifest)
        return (store, manifest)
    }
    private func progress(_ id: String, captured: Double = 20, ready: Bool = false) -> MeetingResearchProgress {
        .init(meetingID: id, sources: [.init(sourceID: "room", capturedThrough: captured,
            settledThrough: ready ? 30 : 0, nextBoundary: ready ? 58.5 : 30,
            windows: ready ? [.init(id: "room:0", start: 0, end: 30)] : [])],
            transcription: .init(completed: ready ? ["room:0"] : []))
    }
    private func eventually(_ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition did not settle within 1.5 seconds")
    }

    @Test func waitsForFrozenCutoffThenRetainsAcrossQuietStopAndMeetingChange() async throws {
        let (store, manifest) = try fixture()
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        controller.updateProgress(progress(manifest.meetingID))
        controller.submit("What codename did we choose?", id: "question")
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .waiting)
        #expect(controller.snapshot.meetingQuestions?.first?.countdown == 10)
        #expect(await provider.requests.isEmpty)
        var later = try store.load(meetingID: manifest.meetingID)
        later.segments.append(.init(id: "future", meetingID: manifest.meetingID, sequence: 1,
            startOffset: 28.5, endOffset: 58.5, text: "Later discussion must not extend the frozen question snapshot."))
        try store.saveManifest(later)
        controller.updateProgress(progress(manifest.meetingID, captured: 46, ready: true))
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(await provider.requests.count == 1)
        #expect(await provider.requests.first?.coveredThrough == 30)
        #expect(await provider.requests.first?.passages.contains { $0.segmentID == "future" } == false)
        #expect(controller.snapshot.meetingQuestions?.first?.explanation != nil)
        #expect(controller.snapshot.meetingQuestions?.first?.evidence.first?.sourceTitle == "Room · 00:00:00")
        var stopped = manifest; stopped.state = .completed
        controller.recordingEnded(stopped, finalProgress: progress(manifest.meetingID, captured: 46, ready: true))
        controller.tick()
        #expect(controller.snapshot.state == .quiet)
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .answered)
        let other = MeetingManifest(title: "Other")
        controller.selectMeeting(other)
        #expect(controller.snapshot.meetingQuestions?.isEmpty == true)
        controller.selectMeeting(stopped)
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .answered)
    }

    @Test func fifoRepeatAndReplayIdentityHaveDistinctMeaning() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider(); await provider.configure(held: true)
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        controller.submit("What codename?", id: "one")
        controller.submit("What codename?", id: "one") // UI replay, not another charge
        controller.submit("What codename?", id: "two") // deliberate identical question
        await eventually { controller.snapshot.meetingQuestions?.last?.phase == .queued }
        #expect(controller.snapshot.meetingQuestions?.count == 2)
        await eventually { await provider.requests.count == 1 }
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .answering)
        await provider.release()
        await eventually { controller.snapshot.meetingQuestions?.allSatisfy { $0.phase == .answered } == true }
        #expect(await provider.requests.map(\.context.requestID) == ["one", "two"])
        #expect(await provider.requests.last?.conversation.first?.answer.contains("A codename identifies") == true)
        #expect(await provider.requests.first?.conversation.isEmpty == true)
    }

    @Test func answersSurviveANewControllerWithoutAnotherCloudCall() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        let first = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        first.selectMeeting(manifest)
        first.submit("What codename?", id: "saved")
        await eventually { first.snapshot.meetingQuestions?.first?.phase == .answered }
        // A disk-backed conversation should be available after a fresh controller.
        await first.flushConversationSaves()
        let reopened = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        reopened.selectMeeting(manifest)
        await eventually { reopened.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(reopened.snapshot.meetingQuestions?.first?.answer == "The meeting selected Cedar.")
        #expect(reopened.snapshot.meetingQuestions?.first?.evidence.first?.passage == manifest.segments.first?.text)
        #expect(await provider.requests.count == 1)
    }

    @Test func interruptedSavedRequestNeverAutomaticallyCallsProvider() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let saved = SavedMeetingQuestion(id: "interrupted", question: "What codename?", submittedAt: Date(),
            cutoff: 30, phase: "answering", scope: "thisMeeting", detail: nil, passages: [],
            sourceMeetingIDs: [manifest.meetingID], coveredThrough: 30, partial: false, response: nil)
        try MeetingConversationStore(store: store).save(.init(meetingID: manifest.meetingID, questions: [saved]))
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .cancelled }
        #expect(controller.snapshot.meetingQuestions?.first?.detail?.contains("Retry") == true)
        #expect(await provider.requests.isEmpty)
    }

    @Test func savedWebDatesReachSourcePresentationWithoutAnotherRequest() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let retrieved = Date(timeIntervalSince1970: 1_790_496_000)
        let sources: [WebEvidenceItem] = [
            .init(title: "Historical source", url: URL(string: "https://example.com/old")!, passage: "Old guidance.",
                  provider: "brave-llm-context", retrievedAt: retrieved, score: nil, pageDate: "2017-01-15"),
            .init(title: "Undated source", url: URL(string: "https://example.com/docs")!, passage: "Documentation.",
                  provider: "brave-llm-context", retrievedAt: retrieved, score: nil)
        ]
        let response = CurrentMeetingQuestionResponse(requestID: "saved-web", claims: [], explanation: nil,
            limitation: "Current capabilities are not established.",
            webClaims: [.init(text: "Historical guidance requires current verification.", sources: sources)])
        let saved = SavedMeetingQuestion(id: "saved-web", question: "What is supported now?", submittedAt: retrieved,
            cutoff: 30, phase: "answered", scope: "thisMeeting", detail: nil, passages: [],
            sourceMeetingIDs: [manifest.meetingID], coveredThrough: 30, partial: false, response: response,
            approvedWebQuery: "public documentation")
        try MeetingConversationStore(store: store).save(.init(meetingID: manifest.meetingID, questions: [saved]))
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        let presented = try #require(controller.snapshot.meetingQuestions?.first?.webClaims.first?.sources)
        #expect(presented.map(\.pageDate) == ["2017-01-15", nil])
        #expect(presented.map(\.retrievedAt) == [retrieved, retrieved])
        #expect(await provider.requests.isEmpty)
    }

    @Test func approvedWebPolicyReachesRequestAndSurvivesReload() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        await eventually { controller.snapshot.researchAccess?.canAsk == true }
        controller.submit("What codename?", id: "selected-web", approvedWebQuery: "codename site:example.com", approvedWebDomains: ["example.com"])
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(await provider.requests.first?.approvedWebDomains == ["example.com"])
        await controller.flushConversationSaves()
        let saved = try MeetingConversationStore(store: store).load(manifest.meetingID)
        #expect(saved.questions.first?.approvedWebDomains == ["example.com"])
        let reopened = MeetingResearchController(store: store, answer: { _ in
            Issue.record("Reopening must not request another answer")
            throw CancellationError()
        })
        reopened.selectMeeting(manifest)
        await eventually { reopened.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(reopened.snapshot.meetingQuestions?.first?.webSourceDomains == ["example.com"])
        #expect(reopened.snapshot.meetingQuestions?.first?.mayRetry == false)
    }

    @Test func corruptArchiveIsNotOverwrittenByNewAnswers() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let file = MeetingConversationStore(store: store).url(manifest.meetingID)
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: file)
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        controller.submit("What codename?", id: "new")
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        await controller.flushConversationSaves()
        #expect(controller.snapshot.conversationNotice?.contains("not saved") == true)
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func timeoutNeverSilentlyUsesIncompleteText() async throws {
        let (store, manifest) = try fixture()
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        var clock = Date()
        let controller = MeetingResearchController(store: store, now: { clock }, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        await eventually { controller.snapshot.researchAccess?.canAsk == true }
        controller.updateProgress(progress(manifest.meetingID))
        controller.submit("What codename?", id: "one")
        clock = clock.addingTimeInterval(121); controller.tick()
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .failed)
        #expect(await provider.requests.isEmpty)
        controller.useAvailable("one")
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(await provider.requests.first?.contextIsPartial == true)
    }

    @Test func cancellationKeepsSerialSlotUntilLateReplyAndCannotResurrectCard() async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider(); await provider.configure(held: true)
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        controller.submit("What codename?", id: "one")
        await eventually { await provider.requests.count == 1 }
        controller.cancel("one")
        controller.submit("Explain codename", id: "two")
        await eventually { controller.snapshot.meetingQuestions?.last?.phase == .queued }
        #expect(await provider.requests.count == 1)
        await provider.release()
        await eventually { controller.snapshot.meetingQuestions?.last?.phase == .answered }
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .cancelled)
        #expect(controller.snapshot.meetingQuestions?.first?.answer == nil)
    }

    @Test func changingMeetingsCancelsUnfinishedAndRejectsOldProgress() async throws {
        let (store, manifest) = try fixture()
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        controller.updateProgress(progress(manifest.meetingID)); controller.submit("What?", id: "one")
        controller.selectMeeting(MeetingManifest(title: "Other"))
        controller.updateProgress(progress(manifest.meetingID, captured: 30, ready: true))
        controller.selectMeeting(manifest)
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .cancelled)
        #expect(await provider.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func failureRetryAndExplicitFollowUpPreserveEvidenceNotGeneratedText(delayedAccess: Bool) async throws {
        let (store, manifest) = try fixture(state: .completed)
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider(); await provider.configure(fail: true)
        var configuration: ProviderConfiguration? = ProviderSettings().configuration
        let controller = MeetingResearchController(store: store, configuredProvider: { configuration },
            answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest)
        await eventually { controller.snapshot.researchAccess?.canAsk == true }
        try #require(controller.snapshot.researchAccess?.canAsk == true)
        controller.submit("What codename?", id: "one")
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .failed }
        try #require(controller.snapshot.meetingQuestions?.first?.phase == .failed)
        if delayedAccess {
            // Force the same ordering as CI: a failed card is visible before
            // the asynchronous access check has made Retry available.
            configuration = nil
            controller.refreshAccess()
            await eventually { controller.snapshot.researchAccess?.canAsk == false }
            try #require(controller.snapshot.meetingQuestions?.first?.mayRetry == false)
        }
        await provider.configure()
        if delayedAccess {
            configuration = ProviderSettings().configuration
            controller.refreshAccess()
        }
        // A failed answer and a completed permission check are independent.
        // Exercise the same enabled Retry action the user can actually click.
        await eventually { controller.snapshot.meetingQuestions?.first?.mayRetry == true }
        try #require(controller.snapshot.meetingQuestions?.first?.mayRetry == true)
        controller.retry("one")
        await eventually {
            controller.snapshot.meetingQuestions?.last?.id != "one"
                && controller.snapshot.meetingQuestions?.last?.phase == .answered
        }
        try #require(controller.snapshot.meetingQuestions?.count == 2)
        try #require(controller.snapshot.meetingQuestions?.last?.phase == .answered)
        let answered = try #require(controller.snapshot.meetingQuestions?.last?.id)
        controller.followUp(answered); controller.submit("Explain that", id: "followup")
        await eventually {
            controller.snapshot.meetingQuestions?.first(where: { $0.id == "followup" })?.phase == .answered
        }
        try #require(controller.snapshot.meetingQuestions?.first(where: { $0.id == "followup" })?.phase == .answered)
        let requests = await provider.requests
        #expect(requests.map(\.context.requestID) == ["one", answered, "followup"])
        let request = try #require(requests.last)
        #expect(request.previousQuestion == "What codename?")
        #expect(!request.passages.contains { $0.text.contains("A codename identifies") })
        #expect(request.conversation.last?.answer.contains("A codename identifies") == true)
        #expect(controller.snapshot.meetingQuestions?.count == 3)
    }

    @Test func privacyBlocksWithoutUpgradeAndDeletionPurgesRetainedText() async throws {
        let (store, local) = try fixture(state: .completed, cloud: false)
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(local); controller.submit("What codename?", id: "one")
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .failed)
        #expect(await provider.requests.isEmpty)
        #expect(controller.snapshot.meetingQuestions?.first?.mayUseAvailable == false)
        controller.useAvailable("one")
        #expect(controller.snapshot.meetingQuestions?.first?.phase == .failed)
        try store.delete(meetingID: local.meetingID)
        await eventually { controller.snapshot.meetingTitle == nil }
        #expect(controller.snapshot.meetingQuestions?.isEmpty == true)
    }

    @Test func stopDrainsPendingQuestionWithoutAnotherRecordingWindow() async throws {
        let (store, manifest) = try fixture()
        defer { try? store.deleteAll() }
        let provider = QuestionTestProvider()
        let controller = MeetingResearchController(store: store, answer: { try await provider.answer($0) })
        controller.selectMeeting(manifest); controller.updateProgress(progress(manifest.meetingID))
        controller.submit("What codename?", id: "one")
        var final = progress(manifest.meetingID, captured: 30, ready: true); final.isRecording = false
        var stopped = manifest; stopped.state = .completed; try store.saveManifest(stopped)
        controller.recordingEnded(stopped, finalProgress: final)
        await eventually { controller.snapshot.meetingQuestions?.first?.phase == .answered }
        #expect(await provider.requests.count == 1)
    }
}
