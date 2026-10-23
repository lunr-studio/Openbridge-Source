import SwiftUI
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

@Suite(.serialized) @MainActor struct MeetingIntelligenceLayoutTests {
    @Test func liveBridgePreservesStorageWarningAndOnlyNewQuestionsMoveReadingPosition() {
        let vm = ResearchRailViewModel(snapshot: snapshot)
        vm.conversationScrollID = "one"
        var tick = snapshot
        tick.conversationNotice = "Conversation could not be saved."
        vm.updateSnapshot(tick)
        #expect(vm.snapshot.conversationNotice == tick.conversationNotice)
        #expect(vm.conversationScrollID == "one")
        let submitted = ResearchRailSnapshot(state: .searching, cards: [], activeQuestion: nil,
            meetingQuestions: (tick.meetingQuestions ?? []) + [.init(id: "three", question: "A new question", phase: .queued)])
        vm.updateSnapshot(submitted)
        #expect(vm.conversationScrollID == "three")
        vm.intelligenceExpanded = true; vm.intelligenceWidth = 600
        vm.composerText = "A draft"
        vm.updateSnapshot(submitted)
        #expect(vm.intelligenceExpanded && vm.intelligenceWidth == 600)
        #expect(vm.composerText == "A draft")
    }

    @Test func splitWidthsClampAndExpandedUsesEntireContentArea() {
        let size = CGSize(width: 1_200, height: 700)
        for preferred in [CGFloat(100), 420, 2_000] {
            let layout = MeetingIntelligenceLayout(size: size, preferredRailWidth: preferred, expanded: false, focus: .transcript)
            #expect(layout.transcript.width >= 420)
            #expect(layout.rail.width >= 300)
            #expect(layout.rail.maxX == size.width)
            #expect(layout.canResize)
        }
        let full = MeetingIntelligenceLayout(size: size, preferredRailWidth: 420, expanded: true, focus: .transcript)
        #expect(full.rail.size == size)
        #expect(full.transcript.isEmpty)
        #expect(!full.canResize)
        for mode in ResearchFocusMode.allCases {
            let narrow = MeetingIntelligenceLayout(size: .init(width: 500, height: 700), preferredRailWidth: 420, expanded: false, focus: mode)
            #expect(narrow.rail.width <= 500 && narrow.transcript.width <= 500)
            #expect(!narrow.canResize)
        }
    }

    /// Real AppKit/SwiftUI renders with synthetic content. Not provider, audio,
    /// installed-app or headphone evidence.
    @Test func resizedAndExpandedConversationKeepsDraftAndRendersReadableAnswers() async throws {
        let vm = ResearchRailViewModel(snapshot: snapshot)
        vm.composerText = "How would that affect our rollout?"
        let host = NSHostingView(rootView: fixture(vm))
        host.setFrameSize(.init(width: 1_440, height: 960))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderOut(nil)
        defer { window.contentView = nil }
        for (name, width, expanded) in [("split", 1_440, false), ("resized", 1_440, false), ("expanded", 1_440, true), ("narrow", 720, true)] {
            vm.intelligenceExpanded = expanded
            if name == "resized" { vm.intelligenceWidth = 620 }
            window.setContentSize(.init(width: width, height: 960))
            try await settleNativeLayout(host)
            #expect(vm.composerText == "How would that affect our rollout?")
            #expect(vm.snapshot.meetingQuestions?.count == 2)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 2_000)
            if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_HOME_RENDER_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appendingPathComponent("meeting-intelligence-\(name).png"))
            }
        }
    }

    @Test func longSavedAnswersAllowContinuousUpwardReading() async throws {
        let paragraphs = (0..<45).map { "Passage \($0). A long source quotation retains its context and citation while the reader moves through previous answers." }.joined(separator: "\n\n")
        let state = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil,
            meetingQuestions: [
                .init(id: "old", question: "First saved question", phase: .answered, answer: paragraphs),
                .init(id: "middle", question: "Second saved question", phase: .answered, answer: String(paragraphs.prefix(900))),
                .init(id: "last", question: "Latest saved question", phase: .failed, coverage: "No sources were found.")])
        let vm = ResearchRailViewModel(snapshot: state)
        vm.conversationScrollID = "last"
        let host = NSHostingView(rootView: MeetingQuestionRail(viewModel: vm))
        host.setFrameSize(.init(width: 420, height: 760))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderOut(nil)
        defer { window.contentView = nil }
        try await settleNativeLayout(host, ticks: 10)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return [scroll] }
            var found: [NSScrollView] = []
            for child in view.subviews { found += scrollViews(child) }
            return found
        }
        let scroll = try #require(scrollViews(host).first { ($0.documentView?.frame.height ?? 0) > 1_000 })
        let clip = scroll.contentView
        let document = try #require(scroll.documentView)
        #expect(document.isFlipped)
        clip.scroll(to: .init(x: 0, y: max(0, document.frame.height - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
        try await settleNativeLayout(host)
        var previous = clip.bounds.minY
        #expect(previous > 500)
        for _ in 0..<80 {
            let target = max(0, previous - 180)
            clip.scroll(to: .init(x: 0, y: target))
            scroll.reflectScrolledClipView(clip)
            // Production publishes existing-card updates while users read.
            vm.updateSnapshot(state)
            try await settleNativeLayout(host, ticks: 2)
            let actual = clip.bounds.minY
            #expect(actual <= target + 2, "Upward reading jumped from \(previous) past target \(target) to \(actual)")
            if actual > target + 2 { break }
            previous = actual
            if actual <= 2 { break }
        }
        #expect(clip.bounds.minY <= 2)
        #expect(vm.snapshot.meetingQuestions?.count == 3)
        vm.composerText = "Unsent draft"
        let appended = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil,
            meetingQuestions: (state.meetingQuestions ?? []) + [.init(id: "new", question: "A newly submitted question", phase: .queued)])
        vm.updateSnapshot(appended)
        try await settleNativeLayout(host, ticks: 10)
        // scrollTo reveals the final card, above the stack's 16-point padding.
        #expect(abs(clip.bounds.maxY - document.frame.maxY) <= 17)
        #expect(vm.composerText == "Unsent draft")
    }

    private var snapshot: ResearchRailSnapshot {
        .init(state: .quiet, cards: [], activeQuestion: nil, meetingQuestions: [
            .init(id: "one", question: "What did we decide about the Cedar rollout?", phase: .answered,
                answer: "The team agreed to a small pilot on Friday, with a review before wider rollout.",
                explanation: "A pilot limits the consequences of an unexpected problem while giving the team real feedback. It works best when you agree on success criteria before launch.\n\nFor this kind of rollout, consider three questions: Can people complete the main task? Are errors easy to recover from? Does the support team understand the new workflow?\n\nStart with a representative group, record problems consistently, and keep a clear rollback path. A successful pilot is not just one without complaints: it should demonstrate the specific outcomes the team chose to measure.",
                evidence: [.init(id: "citation", type: .currentMeeting, passage: "Let's pilot Cedar on Friday, then review before expanding.", sourceLocator: .currentPassage(segmentID: "s1", meetingID: "synthetic"), sourceTitle: "Room · 00:00:12")], coverage: "Transcript through 00:01:30"),
            .init(id: "two", question: "What would useful success criteria look like?", phase: .waiting, countdown: 12)
        ], meetingTitle: "Cedar planning · Synthetic UI fixture")
    }

    private func fixture(_ vm: ResearchRailViewModel) -> some View {
        VStack(spacing: 0) {
            MeetingHomeRecordingHeader(title: "Cedar planning — synthetic fixture", elapsed: "00:01:42", isStopping: false,
                microphone: "Default microphone", microphoneLevel: 0.35, systemLevel: 0.5,
                configurationSummary: "Microphone + Mac audio · Cloud intelligence on · Cleanup off", onStop: {},
                systemStatus: "Receiving audio", microphoneStatus: "Receiving audio")
            ResearchFocusContainer(transcript:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Live transcript").font(OpenBridgeTypography.heading(size: 22))
                        Text("Let's pilot Cedar on Friday, then review before expanding. We should agree on what success looks like before inviting the first group.\n\nWe can record completion rates and make a note of any point where people need help. The wider rollout can wait until we have reviewed the pilot.")
                            .font(OpenBridgeTypography.body).lineSpacing(7).textSelection(.enabled)
                        Text("Synthetic native render • No microphone or cloud request").font(OpenBridgeTypography.metadata).foregroundStyle(OpenBridgePalette.mutedInk)
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }.background(OpenBridgePalette.canvas), viewModel: vm)
        }.background(OpenBridgePalette.surface).foregroundStyle(OpenBridgePalette.ink).preferredColorScheme(.light)
    }
}
