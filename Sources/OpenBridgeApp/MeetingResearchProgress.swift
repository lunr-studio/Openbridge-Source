import Foundation

/// Read-only receipts from capture and transcription, never a new recording policy.
struct ResearchAudioWindow: Equatable, Sendable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
}

struct ResearchCaptureSourceProgress: Equatable, Sendable {
    let sourceID: String
    let capturedThrough: TimeInterval
    /// All audio before here is sealed, or was a silence-only window.
    let settledThrough: TimeInterval
    let nextBoundary: TimeInterval?
    let windows: [ResearchAudioWindow]
    var failed = false
}

struct ResearchTranscriptionProgress: Equatable, Sendable {
    var completed: Set<String> = []
    var failed: Set<String> = []
}

struct MeetingResearchProgress: Equatable, Sendable {
    let meetingID: String
    let sources: [ResearchCaptureSourceProgress]
    let transcription: ResearchTranscriptionProgress
    var isRecording = true

    var capturedThrough: TimeInterval { sources.map(\.capturedThrough).max() ?? 0 }

    enum Readiness: Equatable {
        case waiting(seconds: Int?)
        case transcribing
        case ready(through: TimeInterval, windowIDs: Set<String>)
        case failed
    }

    func readiness(through target: TimeInterval) -> Readiness {
        guard !sources.isEmpty else { return .waiting(seconds: nil) }
        var required = Set<String>()
        var coverages: [TimeInterval] = []
        var needsCapture = false
        var countdowns: [TimeInterval] = []
        for source in sources {
            if source.failed { return .failed }
            let ordered = source.windows.sorted { $0.end < $1.end }
            // Include the first window covering Send, not later overlapping windows.
            let closing = ordered.first { $0.start <= target && $0.end + 0.001 >= target }
            let windows = ordered.filter { $0.end <= (closing?.end ?? target) + 0.001 }
            required.formUnion(windows.map(\.id))
            if source.capturedThrough + 0.001 < target || source.settledThrough + 0.001 < target {
                needsCapture = true
                if let boundary = source.nextBoundary {
                    countdowns.append(max(0, boundary - source.capturedThrough))
                }
            }
            coverages.append(closing?.end ?? min(target, source.settledThrough))
        }
        if !required.isDisjoint(with: transcription.failed) { return .failed }
        if needsCapture {
            return isRecording ? .waiting(seconds: countdowns.max().map { Int(ceil($0)) }) : .failed
        }
        guard required.isSubset(of: transcription.completed) else { return .transcribing }
        return .ready(through: coverages.min() ?? target, windowIDs: required)
    }
}
