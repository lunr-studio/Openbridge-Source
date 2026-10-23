import Testing
import Foundation
@testable import OpenBridgeApp

@Suite(.serialized) struct OnlineMeetingCaptureTests {
    @Test func legacyManifestKeepsCleanupAndPrivacy() throws {
        var m = MeetingManifest(title: "Legacy", aiMode: .localOnly, manualNotes: "keep these notes")
        m.schemaVersion = 3
        let encoder = JSONEncoder()
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(m)) as? [String: Any])
        for key in ["captureMode", "captureStatus", "audioArtifacts", "activeSourceJournals", "transcribedArtifactIDs"] { object.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(MeetingManifest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(migrated.captureMode == .inPerson)
        #expect(migrated.schemaVersion == 4)
        #expect(migrated.aiMode == .localOnly)
        #expect(migrated.manualNotes == "keep these notes")
        #expect(migrated.audioArtifacts.isEmpty)
    }

    @MainActor @Test func sourceWritersShareClockAndPreserveBothTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "test")
        let system = MeetingSourceMetadata(sourceID: "system", label: "System audio", kind: .systemAudio, deviceID: "test")
        var m = MeetingManifest(title: "Synthetic dual capture", state: .recording, sources: [mic, system])
        m.captureMode = .online
        try store.create(m)
        let a = MeetingRecorder(store: store, capturesMicrophone: false, source: mic)
        let b = MeetingRecorder(store: store, capturesMicrophone: false, source: system)
        try await a.startRecording(meetingID: m.meetingID, deviceID: nil, segmentDurationSeconds: 30, commonClockOrigin: 100)
        try await b.startRecording(meetingID: m.meetingID, deviceID: nil, segmentDurationSeconds: 30, commonClockOrigin: 100)
        await a.ingestTestPCM(Data(repeating: 32, count: 32_000), sampleRate: 16_000, presentationTime: 101)
        await b.ingestTestPCM(Data(repeating: 64, count: 32_000), sampleRate: 16_000, presentationTime: 102)
        let active = try store.load(meetingID: m.meetingID)
        #expect(active.activeSourceJournals.count == 2)
        _ = try await a.stopRecording()
        _ = try await b.stopRecording()
        let saved = try store.load(meetingID: m.meetingID)
        #expect(saved.audioArtifacts.count == 2)
        #expect(saved.audioSegments.count == 2)
        #expect(saved.activeSourceJournals.isEmpty)
        #expect(a.audioArtifacts.first?.startOffset == 1)
        #expect(b.audioArtifacts.first?.startOffset == 2)
        #expect(a.audioArtifacts.first?.relativePath == "microphone/segment_0000.wav")
        #expect(b.audioArtifacts.first?.relativePath == "system-audio/segment_0000.wav")
        for item in saved.audioArtifacts {
            #expect(try MeetingWAVFile.durationSeconds(at: store.audioDirectory(for: m.meetingID).appendingPathComponent(item.relativePath)) == 1)
        }
        let files = try await a.stopRecording()
        #expect(files.count == 1)
        #expect(try store.load(meetingID: m.meetingID).audioArtifacts.count == 2)
    }
}


extension OnlineMeetingCaptureTests {
    @MainActor @Test func permissionDenialNeverStartsCaptureOrImplicitFallback() async throws {
        guard #available(macOS 15.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "test")
        let sys = MeetingSourceMetadata(sourceID: "sys", label: "System audio", kind: .systemAudio, deviceID: "test")
        let recorder = OnlineMeetingRecorder(store: store, microphoneSource: mic, systemSource: sys,
            hasSystemAudioPermission: { false })
        do {
            try await recorder.startRecording(meetingID: "synthetic-denied", deviceID: nil)
            Issue.record("Permission denial must fail explicitly")
        } catch {
            #expect(error.localizedDescription.contains("permission"))
        }
        #expect(!recorder.isRecording)
        #expect(recorder.audioArtifacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        _ = try await recorder.stopRecording()
        _ = try await recorder.stopRecording()
    }
}


@available(macOS 15.0, *)
@MainActor private final class PartialOnlineDriver: OnlineMeetingStreamDriver {
    let mic: MeetingRecorder
    let system: MeetingRecorder
    let failStart: Bool
    let failStop: Bool
    var stops = 0
    var drains = 0
    var failure: String? { nil }
    init(mic: MeetingRecorder, system: MeetingRecorder, failStart: Bool, failStop: Bool) {
        self.mic = mic; self.system = system; self.failStart = failStart; self.failStop = failStop
    }
    func startCapture() async throws {
        await mic.ingestTestPCM(Data(repeating: 32, count: 32_000), sampleRate: 16_000, presentationTime: 100)
        if failStart { throw MeetingRecorderError.onlineCaptureFailed("Synthetic partial startup") }
        await system.ingestTestPCM(Data(repeating: 64, count: 32_000), sampleRate: 16_000, presentationTime: 100)
    }
    func stopCapture() async throws {
        stops += 1
        if failStop { throw MeetingRecorderError.onlineCaptureFailed("Synthetic Stop failure") }
    }
    func drain() async {
        drains += 1
        if !failStart {
            await mic.ingestTestPCM(Data(repeating: 32, count: 32_000), sampleRate: 16_000, presentationTime: 101)
            await system.ingestTestPCM(Data(repeating: 64, count: 32_000), sampleRate: 16_000, presentationTime: 101)
        }
    }
}

extension OnlineMeetingCaptureTests {
    @MainActor @Test func driverFactoryRetainsMainActorAcrossSuspension() async throws {
        guard #available(macOS 15.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "fixture")
        let sys = MeetingSourceMetadata(sourceID: "sys", label: "System audio", kind: .systemAudio, deviceID: "fixture")
        var manifest = MeetingManifest(title: "Actor-isolated factory fixture", state: .recording, sources: [mic, sys])
        manifest.captureMode = .online
        try store.create(manifest)
        var calls = 0
        var driver: PartialOnlineDriver?
        let recorder = OnlineMeetingRecorder(store: store, microphoneSource: mic, systemSource: sys,
            hasSystemAudioPermission: { true }, makeDriver: { microphone, system, deviceID in
                MainActor.assertIsolated()
                calls += 1
                #expect(deviceID == "fixture-input")
                await Task.yield()
                MainActor.assertIsolated()
                let value = PartialOnlineDriver(mic: microphone, system: system, failStart: false, failStop: false)
                driver = value
                return value
            })
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: "fixture-input")
        #expect(recorder.isRecording)
        #expect(calls == 1)
        _ = try await recorder.stopRecording()
        #expect(driver?.stops == 1 && driver?.drains == 1)
        #expect(!recorder.isRecording)
        let saved = try store.load(meetingID: manifest.meetingID)
        #expect(saved.audioArtifacts.count == 2)
        #expect(saved.activeSourceJournals.isEmpty)
    }

    @MainActor @Test func partialStartupStopsDriverAndPreservesReceivedMicrophoneAudio() async throws {
        guard #available(macOS 15.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "fixture")
        let sys = MeetingSourceMetadata(sourceID: "sys", label: "System audio", kind: .systemAudio, deviceID: "fixture")
        var manifest = MeetingManifest(title: "Partial startup fixture", state: .recording, sources: [mic, sys])
        manifest.captureMode = .online
        try store.create(manifest)
        var driver: PartialOnlineDriver?
        let recorder = OnlineMeetingRecorder(store: store, microphoneSource: mic, systemSource: sys,
            hasSystemAudioPermission: { true }, makeDriver: { microphone, system, _ in
                let value = PartialOnlineDriver(mic: microphone, system: system, failStart: true, failStop: false)
                driver = value; return value
            })
        do { try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil); Issue.record("Startup should fail") }
        catch { #expect(error.localizedDescription.contains("partial startup")) }
        #expect(!recorder.isRecording)
        #expect(driver?.stops == 1 && driver?.drains == 1)
        let saved = try store.load(meetingID: manifest.meetingID)
        #expect(saved.audioArtifacts.count == 1)
        #expect(saved.audioArtifacts.first?.sourceKind == .microphone)
        #expect(saved.activeSourceJournals.isEmpty)
    }

    @MainActor @Test func failedDuplicateStopStillDrainsAndSealsBothTracks() async throws {
        guard #available(macOS 15.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "fixture")
        let sys = MeetingSourceMetadata(sourceID: "sys", label: "System audio", kind: .systemAudio, deviceID: "fixture")
        var manifest = MeetingManifest(title: "Stop failure fixture", state: .recording, sources: [mic, sys])
        manifest.captureMode = .online
        try store.create(manifest)
        var driver: PartialOnlineDriver?
        let recorder = OnlineMeetingRecorder(store: store, microphoneSource: mic, systemSource: sys,
            hasSystemAudioPermission: { true }, makeDriver: { microphone, system, _ in
                let value = PartialOnlineDriver(mic: microphone, system: system, failStart: false, failStop: true)
                driver = value; return value
            })
        try await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil)
        async let a = try? recorder.stopRecording()
        async let b = try? recorder.stopRecording()
        _ = await (a, b)
        #expect(driver?.stops == 1 && driver?.drains == 1)
        #expect(!recorder.isRecording)
        let saved = try store.load(meetingID: manifest.meetingID)
        #expect(saved.state == .failed)
        #expect(saved.audioArtifacts.count == 2)
        #expect(saved.activeSourceJournals.isEmpty)
        for artifact in saved.audioArtifacts {
            #expect(try MeetingWAVFile.durationSeconds(at: store.audioDirectory(for: manifest.meetingID).appendingPathComponent(artifact.relativePath)) == 2)
        }
    }
}

@available(macOS 15.0, *)
@MainActor private final class SuspendedOnlineDriver: OnlineMeetingStreamDriver {
    var failure: String? { nil }
    var continuation: CheckedContinuation<Void, Never>?
    var running = false
    var stops = 0
    func startCapture() async throws {
        await withCheckedContinuation { continuation = $0 }
        running = true
    }
    func stopCapture() async throws { stops += 1; running = false }
    func drain() async {}
}

extension OnlineMeetingCaptureTests {
    @MainActor @Test func cancelledPendingStartupCannotLeaveLateCaptureRunning() async throws {
        guard #available(macOS 15.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let mic = MeetingSourceMetadata(sourceID: "mic", label: "Me", deviceID: "fixture")
        let sys = MeetingSourceMetadata(sourceID: "sys", label: "System audio", kind: .systemAudio, deviceID: "fixture")
        var manifest = MeetingManifest(title: "Cancelled startup fixture", state: .recording, sources: [mic, sys])
        manifest.captureMode = .online
        try store.create(manifest)
        let driver = SuspendedOnlineDriver()
        let recorder = OnlineMeetingRecorder(store: store, microphoneSource: mic, systemSource: sys,
            hasSystemAudioPermission: { true }, makeDriver: { _, _, _ in driver })
        let start = Task { try? await recorder.startRecording(meetingID: manifest.meetingID, deviceID: nil) }
        let deadline = Date().addingTimeInterval(60)
        while driver.continuation == nil, Date() < deadline { await Task.yield() }
        try #require(driver.continuation != nil)
        await recorder.cancelRecording()
        driver.continuation?.resume()
        _ = await start.value
        #expect(!recorder.isRecording)
        #expect(!driver.running)
    }
}
