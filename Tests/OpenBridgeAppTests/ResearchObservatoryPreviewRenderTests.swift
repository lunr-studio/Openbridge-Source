import SwiftUI
import Testing
@testable import OpenBridgeUI
@testable import OpenBridgeApp

// MARK: - Preview Render Smoke Tests (#318 / Canvas-independent)
//
// Machine-verifies what Xcode Canvas tests 4–7 check visually: that the
// preview providers build and RENDER. Uses ImageRenderer offscreen, so
// no Xcode GUI is required. This is interim coverage while testers run
// the interactive Canvas check (see Test Checklist note re: toolchain).

@Suite(.serialized) @MainActor struct ResearchObservatoryPreviewRenderTests {
    @Test func railCopyKeepsOnlyUsefulGuidanceAndConsistentHeading() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let typed = try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeUI/MeetingQuestionRail.swift"), encoding: .utf8)
        let legacy = try String(contentsOf: root.appendingPathComponent("Sources/OpenBridgeUI/ResearchObservatoryViews.swift"), encoding: .utf8)
        #expect(!typed.contains("Speaking ‘OpenBridge’ no longer sends questions."))
        #expect(!typed.contains("Cloud answer ·"))
        #expect(typed.contains("if !access.detail.isEmpty"))
        #expect(typed.contains("Keep questions under 2,000 characters."))
        #expect(typed.contains("Recent speech may still be recording."))
        for source in [typed, legacy] {
            #expect(source.contains("Text(\"Meeting Intelligence\")"))
            #expect(source.contains(".accessibilityLabel(\"Meeting Intelligence\")"))
            #expect(!source.contains("Text(\"Research\")"))
        }
    }

    /// Actual native controls with fake snapshots only; no provider or capture.
    @Test func simplifiedRailRendersReadyBlockedAndValidationStates() async throws {
        for state in ["ready", "off", "overlength", "legacy"] {
            let size = CGSize(width: 360, height: 780)
            var snapshot = ResearchRailSnapshot(state: .quiet, cards: [], activeQuestion: nil,
                meetingQuestions: state == "legacy" ? nil : [], meetingTitle: "Synthetic UI fixture")
            snapshot.researchAccess = .init(canAsk: state != "off", canEnable: true,
                detail: state == "off" ? "Cloud research is off for this meeting. Enable it here without stopping recording." : "",
                provider: "Synthetic provider · synthetic-model", approvedHistoryCount: 3)
            let vm = ResearchRailViewModel(snapshot: snapshot)
            vm.updateSnapshot(snapshot)
            if state == "overlength" { vm.composerText = String(repeating: "a", count: 2_001) }
            let view = NSHostingView(rootView: ResearchRailView(viewModel: vm).frame(width: size.width, height: size.height))
            view.setFrameSize(size)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.orderOut(nil)
            defer { window.contentView = nil }
            try await settleNativeLayout(view)
            #expect(view.bounds.size == size)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 2_000)
            if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_RAIL_RENDER_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appendingPathComponent("simplified-\(state).png"))
            }
        }
    }

    @Test func typedQuestionStatesRenderWithRetainedAnswers() async throws {
        let prior = MeetingQuestionCard(id: "prior", question: "What codename did we choose?", phase: .answered,
            answer: "The meeting chose Cedar.", explanation: "A codename is a short project label.", coverage: "Transcript through 00:00:30")
        for phase in [MeetingQuestionPhase.waiting, .transcribing, .queued, .answering, .answered, .failed, .cancelled] {
            let current = MeetingQuestionCard(id: "current", question: "Can you explain the project decision?", phase: phase,
                detail: phase == .failed ? "The cloud request failed. Check Settings, then Retry." : nil,
                countdown: phase == .waiting ? 12 : nil, mayUseAvailable: phase == .waiting)
            let vm = ResearchRailViewModel(snapshot: .init(state: .quiet, cards: [], activeQuestion: nil,
                meetingQuestions: [current, prior], meetingTitle: "Synthetic fixture — not a live recording"))
            let view = NSHostingView(rootView: ResearchRailView(viewModel: vm).frame(width: 360, height: 850))
            view.setFrameSize(NSSize(width: 360, height: 850))
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.orderOut(nil)
            try await settleNativeLayout(view)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_RAIL_RENDER_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("typed-fixture-\(phase.rawValue).png"))
            }
            #expect(vm.snapshot.meetingQuestions?.last == prior)
            window.contentView = nil
        }
    }

    @Test func retainedProductionAnswersRenderWhileQuietSearchingAndFailed() async throws {
        let answers = [
            ObservatoryAnswer(questionID: "one", answerText: "An induction loop transmits sound magnetically to compatible hearing aids.",
                evidence: [.init(id: "model-one", source: .modelSynthesis, passage: "", confidence: 0.9)],
                questionText: "What is an induction hearing loop?"),
            ObservatoryAnswer(questionID: "two", answerText: "Four.",
                evidence: [.init(id: "model-two", source: .modelSynthesis, passage: "", confidence: 0.9)],
                questionText: "What is two plus two?"),
        ]
        let cards = answers.flatMap { ObservatoryRailBridge.cards(for: $0) }
        #expect(cards.allSatisfy { $0.researchSourceLabel == "Model knowledge" })
        let vm = ResearchRailViewModel(snapshot: .init(state: .answered, cards: cards, activeQuestion: nil))
        vm.togglePin(cards[0].id)
        let scenarios: [(String, ResearchRailState, ResearchSpokenStatus)] = [
            ("quiet", .quiet, .init()),
            ("searching", .searching, .init()),
            ("failure", .failure, .init()),
            ("waiting", .quiet, .init(pendingQuestion: "can you tell me")),
            ("queued", .searching, .init(queuedQuestions: ["What is gravity?", "What is a magnet?"])),
            ("repeat", .quiet, .init(needsRepeat: true)),
        ]
        for (label, state, status) in scenarios {
            vm.updateSnapshot(.init(state: state, cards: cards, activeQuestion: .init(text: "Explain how magnets work.", origin: .spoken), spokenStatus: status))
            #expect(vm.visibleCards.count == 2)
            #expect(vm.visibleCards.first?.isPinned == true)
            #expect(vm.snapshot.spokenStatus == status)
            // ImageRenderer omits the native scroll/text-field backing
            // views. Capture the actual offscreen AppKit hosting hierarchy.
            let view = NSHostingView(rootView: ResearchRailView(viewModel: vm).frame(width: 360, height: 780))
            view.setFrameSize(NSSize(width: 360, height: 780))
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderOut(nil)
            try await settleNativeLayout(view, ticks: 10)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_RAIL_RENDER_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("retained-\(label).png"))
            }
            window.contentView = nil
        }
        vm.dismiss(cards[1].id)
        vm.updateSnapshot(.init(state: .quiet, cards: cards, activeQuestion: nil))
        #expect(vm.visibleCards.count == 1)
    }

    /// Renders each rail state fixture offscreen; a nil image means the
    /// view failed to render.
    @Test func railPreviewsRenderForEveryState() throws {
        for state in ResearchRailState.allCases {
            let view = ResearchRailView(viewModel: ResearchRailViewModel(snapshot: ResearchObservatoryFixtures.fixture(for: state)))
            let renderer = ImageRenderer(content: view.frame(width: 420, height: 600))
            let image = renderer.nsImage
            #expect(image != nil, "Rail preview must render for state \(state.displayName)")
            #expect(image!.size.width > 0 && image!.size.height > 0,
                    "Rendered rail preview must have non-zero size for \(state.displayName)")
        }
    }

    /// The gallery (full preview surface) renders offscreen.
    @Test func galleryPreviewRenders() throws {
        let renderer = ImageRenderer(content: ResearchObservatoryGallery().frame(width: 1200, height: 600))
        let image = renderer.nsImage
        #expect(image != nil, "Gallery preview must render")
        #expect(image!.size.width > 0 && image!.size.height > 0)
    }

    /// The DEBUG-gated preview providers themselves construct and their
    /// content renders — the exact views Canvas would show.
    @Test func previewProviderContentRenders() throws {
        #if DEBUG
        let railContent = ResearchRailPreviews.previews
        let railRenderer = ImageRenderer(content: railContent.frame(width: 420, height: 600))
        #expect(railRenderer.nsImage != nil, "ResearchRailPreviews content must render")

        let galleryContent = ResearchObservatoryGalleryPreviews.previews
        let galleryRenderer = ImageRenderer(content: galleryContent.frame(width: 1200, height: 600))
        #expect(galleryRenderer.nsImage != nil, "ResearchObservatoryGalleryPreviews content must render")
        #else
        // Release builds exclude previews by design; nothing to verify.
        #endif
    }
}
