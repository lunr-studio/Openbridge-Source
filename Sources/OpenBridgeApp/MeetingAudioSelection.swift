import Foundation

enum MeetingAudioSelection: String, CaseIterable, Identifiable {
    case microphone, microphoneAndMac, macAudio
    var id: String { rawValue }
    var includesMicrophone: Bool { self != .macAudio }
    var includesMacAudio: Bool { self != .microphone }
    var title: String {
        switch self {
        case .microphone: "Microphone only"
        case .microphoneAndMac: "Microphone + Mac audio"
        case .macAudio: "Mac audio only"
        }
    }
    var notice: String {
        includesMacAudio
            ? "Mac audio includes Google Meet, Zoom, Teams, notifications and other playback. No screen or video is saved."
            : "Records the selected microphone. Other participants playing through headphones are not captured."
    }
    var captureMode: MeetingCaptureMode { includesMacAudio ? .online : .inPerson }
}

enum MeetingAudioHealth: String, Equatable {
    case awaitingAudio, receiving, silent, interrupted
    static func assess(lastSampleAt: Date?, level: Double, failed: Bool, now: Date = Date()) -> Self {
        if failed { return .interrupted }
        guard let lastSampleAt, now.timeIntervalSince(lastSampleAt) < 5 else { return .awaitingAudio }
        return level >= MeetingChunkPolicyConfiguration.live.silenceLevelThreshold ? .receiving : .silent
    }
    var title: String {
        switch self {
        case .awaitingAudio: "No recent audio received — play meeting audio to check"
        case .receiving: "Audio received"
        case .silent: "Quiet · audio samples received"
        case .interrupted: "Capture interrupted"
        }
    }
}
