import Testing
import Foundation
@testable import OpenBridgeApp

@MainActor struct AudioSelectionRegressionTests {
    @Test func defaultInputIsClearlyNamedAsMicrophone() {
        let device = AudioRecorderService().availableInputDevices().first
        #expect(device?.displayName == "Default microphone")
    }

    @Test func captureChoicesNeverTreatAnInputDeviceAsMacAudio() {
        #expect(MeetingAudioSelection.microphone.includesMicrophone)
        #expect(!MeetingAudioSelection.microphone.includesMacAudio)
        #expect(MeetingAudioSelection.microphoneAndMac.includesMicrophone)
        #expect(MeetingAudioSelection.microphoneAndMac.includesMacAudio)
        #expect(!MeetingAudioSelection.macAudio.includesMicrophone)
        #expect(MeetingAudioSelection.macAudio.includesMacAudio)
    }

    @Test func permissionOrStartupDoesNotProveAudioAndSilenceIsNotFailure() {
        let now = Date()
        #expect(MeetingAudioHealth.assess(lastSampleAt: nil, level: 1, failed: false, now: now) == .awaitingAudio)
        #expect(MeetingAudioHealth.assess(lastSampleAt: now, level: 0, failed: false, now: now) == .silent)
        #expect(MeetingAudioHealth.assess(lastSampleAt: now, level: 1, failed: false, now: now) == .receiving)
        #expect(MeetingAudioHealth.assess(lastSampleAt: now.addingTimeInterval(-6), level: 1, failed: false, now: now) == .awaitingAudio)
        #expect(MeetingAudioHealth.assess(lastSampleAt: now, level: 1, failed: true, now: now) == .interrupted)
    }

    @Test func macOnlyDoesNotStartOrPersistAMicrophoneTrack() async throws {
        guard #available(macOS 15, *) else { return }
        let store = MeetingSessionStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            meetingDeletionObserver: { _ in })
        defer { try? store.deleteAll() }
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "fixture")
        let system = MeetingSourceMetadata(sourceID: "mac", label: "System audio", kind: .systemAudio, deviceID: "fixture")
        var manifest = MeetingManifest(title: "Synthetic Mac-only test", state: .recording, sources: [system])
        manifest.captureMode = .online
        try store.create(manifest)
        var micStarted = true
        let recorder = OnlineMeetingRecorder(store: store, microphoneSource: mic, systemSource: system,
            includesMicrophone: false, hasSystemAudioPermission: { true }, makeDriver: { mic, system, _ in
                SyntheticMacOnlyDriver(mic: mic, system: system, inspect: { micStarted = mic.isRecording })
            })
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil)
        #expect(!micStarted)
        _ = try await recorder.stopRecording()
        let saved = try store.load(meetingID: manifest.meetingID)
        #expect(saved.audioArtifacts.count == 1)
        #expect(saved.audioArtifacts.allSatisfy { $0.sourceKind == .systemAudio })
        #expect(recorder.researchCaptureProgress.count == 1)
    }
}

@available(macOS 15, *)
@MainActor private final class SyntheticMacOnlyDriver: OnlineMeetingStreamDriver {
    let mic: MeetingRecorder
    let system: MeetingRecorder
    let inspect: () -> Void
    var failure: String? { nil }
    init(mic: MeetingRecorder, system: MeetingRecorder, inspect: @escaping () -> Void) {
        self.mic = mic; self.system = system; self.inspect = inspect
    }
    func startCapture() async throws {
        inspect()
        await system.ingestTestPCM(Data(repeating: 32, count: 32_000), sampleRate: 16_000, presentationTime: 100)
    }
    func stopCapture() async throws {}
    func drain() async {}
}
