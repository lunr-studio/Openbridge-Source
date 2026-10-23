import Foundation
import Testing
@testable import OpenBridgeApp

@MainActor @Suite struct OnlineMeetingReplayTests {
    @Test func preparesBothTracksWithOverlapAndSkipsMissingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["mic-0.wav", "mic-1.wav", "system.wav"] {
            try MeetingWAVFile.write(pcm: Data(repeating: 0, count: 32_000), sampleRate: 16_000,
                                     to: root.appendingPathComponent(name))
        }
        let player = MeetingPlayer()
        // Deliberately unsorted; the microphone chunks overlap by half a second.
        let artifacts = [artifact("mic-1.wav", start: 0.5, sequence: 1),
                         artifact("system.wav", start: 0.25, kind: .systemAudio),
                         artifact("missing.wav", start: 2),
                         artifact("mic-0.wav", start: 0)]
        try await player.loadOnline(artifacts: artifacts, audioDirectory: root)
        #expect(player.onlineDuration == 1.5)
        #expect(player.totalSegments == 4)
        #expect(player.currentSegmentIndex == 0)
        #expect(player.currentSegmentName == "Online meeting · both sources")
        #expect(!player.isPlaying)
        player.stop()
        #expect(player.progress == 0)
    }

    @Test func emptyOnlineReplayDoesNotStartPlayback() async throws {
        let player = MeetingPlayer()
        try await player.loadOnline(artifacts: [], audioDirectory: FileManager.default.temporaryDirectory)
        #expect(player.onlineDuration == 0)
        #expect(player.totalSegments == 0)
        #expect(!player.isPlaying)
    }

    private func artifact(_ name: String, start: TimeInterval, sequence: Int = 0,
                          kind: MeetingSourceKind = .microphone) -> MeetingAudioArtifact {
        MeetingAudioArtifact(sourceID: kind == .microphone ? "mic" : "system", sourceKind: kind,
            sequence: sequence, relativePath: name, startOffset: start, endOffset: start + 1,
            sampleRate: 16_000, channelCount: 1)
    }
}
