import SwiftUI
import Testing
@testable import OpenBridgeApp
@testable import OpenBridgeUI

/// Synthetic component renders. No AppState, microphone or provider is created.
@Suite(.serialized) @MainActor struct MeetingHomeRenderTests {
    @Test func researchFocusAndDraftSurviveParentRecordingTicks() async throws {
        let suite = "meeting-home-focus-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ResearchObservatoryFeatureFlag.key)
        let probe = FocusLifetimeProbe()
        let host = NSHostingView(rootView: FocusLifetimeFixture(probe: probe).defaultAppStorage(defaults).frame(width: 730, height: 500))
        host.setFrameSize(CGSize(width: 730, height: 500))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderOut(nil)
        try await settleNativeLayout(host)
        let initial = try #require(probe.latest)
        initial.focusMode = .research
        initial.composerText = "A draft must survive recording ticks"
        for tick in 1...4 { probe.tick = tick; try await settleNativeLayout(host) }
        #expect(probe.creations == 1)
        #expect(probe.latest === initial)
        #expect(probe.latest?.focusMode == .research)
        #expect(probe.latest?.composerText == "A draft must survive recording ticks")
        window.contentView = nil
    }

    @Test func approvedHomeComponentsRenderAcrossWindowSizes() async throws {
        for width in [980, 1180, 1480] {
            for state in ["ready", "blocked", "expanded", "cloud-cleanup", "cloud-research", "recording", "waiting", "answered"] {
                let size = CGSize(width: width, height: width == 980 ? 680 : (width == 1180 ? 760 : 900))
                let host = NSHostingView(rootView: fixture(state, size: size))
                host.setFrameSize(size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderOut(nil)
                try await settleNativeLayout(host)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 2_000)
                if let directory = ProcessInfo.processInfo.environment["OPENBRIDGE_HOME_RENDER_DIR"] {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try png.write(to: root.appendingPathComponent("native-fixture-\(state)-\(width).png"))
                }
                window.contentView = nil
            }
        }
    }

    private func fixture(_ state: String, size: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Openbridge").font(.headline)
                Label("Home", systemImage: "house")
                Label("Meetings", systemImage: "person.3")
                Spacer()
                Text("Synthetic native fixture\nNot a live recording").font(.caption)
            }
            .padding(24).frame(width: 204).frame(maxHeight: .infinity)
            .background(OpenBridgeTheme.card)
            if ["recording", "waiting", "answered"].contains(state) {
                VStack(spacing: 0) {
                    MeetingHomeRecordingHeader(title: "Design review", elapsed: "00:01:12", isStopping: false,
                        microphone: "Mac microphone", microphoneLevel: 0.4, systemLevel: 0.2,
                        configurationSummary: "Online · Cloud allowed · Keep until deleted · No cleanup", onStop: {})
                    HStack(alignment: .top, spacing: 0) {
                        Text("Live transcript\n\nThe project codename is Cedar. We agreed to review the design on Friday.")
                            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        if state != "recording" {
                            ResearchRailView(viewModel: .init(snapshot: .init(state: .quiet, cards: [], activeQuestion: nil,
                                meetingQuestions: [.init(id: "fixture", question: "What did we agree?",
                                    phase: state == "waiting" ? .waiting : .answered,
                                    countdown: state == "waiting" ? 18 : nil,
                                    answer: state == "answered" ? "Review the design on Friday." : nil)], meetingTitle: "Design review — fixture")))
                                .frame(width: 300)
                        }
                    }.frame(maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MeetingHomeSetupHeading(canStart: state != "blocked", isStarting: false, helperText: "Synthetic fixture", onStart: {})
                        MeetingHomeColumns {
                            MeetingHomeForm(title: .constant(state == "blocked" ? "" : "Design review"), cloudAllowed: .constant(state == "cloud-research"),
                                optionsExpanded: .constant(state == "expanded"),
                                helperText: state == "blocked" ? "Allow microphone access in System Check." : "Ready to record.",
                                canStart: state != "blocked", isStarting: false, providerLabel: "OpenRouter",
                                optionsSummary: "Default workspace · Keep until deleted",
                                cleanup: .constant(state == "cloud-cleanup" ? .cloudOptIn : .transcriptionOnly), showsStartButton: false, onStart: {}) {
                                    Picker("Meeting type", selection: .constant(0)) { Text("In-person").tag(0); Text("Online").tag(1) }.pickerStyle(.segmented)
                                    Picker("Microphone", selection: .constant(0)) { Text("System default").tag(0) }
                                } options: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Workspace: Default")
                                        Text("Retention: Keep until deleted")
                                        Text("After recording: No cleanup")
                                    }
                                }
                            MeetingHomeSetupSummary(microphone: "System default", model: "Parakeet TDT v3 MLX BF16", modelStatus: "Installed · Ready",
                                readiness: state == "blocked" ? "Microphone needs attention." : "Ready to record.", onSystemCheck: {}, onModels: {}, onSettings: {})
                        }
                        HStack { Button("Dictate") {}; Button("Transcribe a file") {}; Button("YouTube") {} }
                        MeetingHomePanel(title: "Recent meetings") {
                            ForEach(["Design review", "Weekly planning", "Research notes"], id: \.self) { Text($0) }
                        }
                    }.padding(24)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(OpenBridgeTheme.canvas).foregroundStyle(OpenBridgeTheme.ink).preferredColorScheme(.light)
    }
}

@MainActor private final class FocusLifetimeProbe: ObservableObject {
    @Published var tick = 0
    var creations = 0
    var latest: ResearchRailViewModel?
    func make() -> ResearchRailViewModel {
        creations += 1
        let vm = ResearchRailViewModel()
        latest = vm
        return vm
    }
}

@MainActor private struct FocusLifetimeFixture: View {
    @ObservedObject var probe: FocusLifetimeProbe
    var body: some View {
        ResearchGatedMeetingsContent(transcript: Text("Recording tick \(probe.tick)"), makeViewModel: { probe.make() })
    }
}
