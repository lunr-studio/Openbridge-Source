import Foundation

struct MeetingArtifactTranscript: Sendable {
    let artifact: MeetingAudioArtifact
    let source: MeetingSourceMetadata
    let payload: TranscriptPayload
}

enum MeetingTranscriptMerger {
    static func merge(
        meetingID: String,
        captureMode: MeetingCaptureMode,
        transcripts: [MeetingArtifactTranscript]
    ) -> [MeetingTranscriptSegment] {
        let draftSegments = transcripts.flatMap { transcript in
            makeDrafts(for: transcript, captureMode: captureMode)
        }
        let ordered = draftSegments.sorted(by: draftOrder)

        return ordered.enumerated().map { sequence, draft in
            var segment = MeetingTranscriptSegment(
                id: draft.id,
                meetingID: meetingID,
                sequence: sequence,
                startOffset: draft.startOffset,
                endOffset: draft.endOffset,
                sourceLabel: draft.sourceLabel,
                text: draft.text,
                isFinal: true
            )
            segment.sourceID = draft.sourceID
            segment.sourceSequence = draft.sourceSequence
            segment.artifactID = draft.artifactID
            return segment
        }
    }

    private static func makeDrafts(
        for transcript: MeetingArtifactTranscript,
        captureMode: MeetingCaptureMode
    ) -> [Draft] {
        let artifact = transcript.artifact
        let sourceLabel = label(for: transcript.source, captureMode: captureMode)
        let detailedSpans = transcript.payload.spans.enumerated().compactMap { index, span -> Draft? in
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let startOffset = absoluteOffset(
                relativeOffset: span.startOffset,
                artifactStart: artifact.startOffset,
                artifactEnd: artifact.endOffset,
                fallback: artifact.startOffset
            )
            let endOffset = max(
                startOffset,
                absoluteOffset(
                    relativeOffset: span.endOffset,
                    artifactStart: artifact.startOffset,
                    artifactEnd: artifact.endOffset,
                    fallback: artifact.endOffset
                )
            )
            return Draft(
                id: "\(artifact.id)-span-\(String(format: "%04d", index))",
                sourceID: artifact.sourceID, sourceSequence: artifact.sequence, artifactID: artifact.id,
                sourceKind: artifact.sourceKind,
                startOffset: startOffset,
                endOffset: endOffset,
                sourceLabel: sourceLabel,
                text: text
            )
        }

        if !detailedSpans.isEmpty {
            return detailedSpans
        }

        let fallbackText = transcript.payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackText.isEmpty else { return [] }
        return [Draft(
            id: "\(artifact.id)-fallback",
            sourceID: artifact.sourceID, sourceSequence: artifact.sequence, artifactID: artifact.id,
            sourceKind: artifact.sourceKind,
            startOffset: artifact.startOffset,
            endOffset: max(artifact.startOffset, artifact.endOffset),
            sourceLabel: sourceLabel,
            text: fallbackText
        )]
    }

    private static func absoluteOffset(
        relativeOffset: TimeInterval?,
        artifactStart: TimeInterval,
        artifactEnd: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard let relativeOffset, relativeOffset.isFinite else { return fallback }
        return min(max(artifactStart + max(0, relativeOffset), artifactStart), artifactEnd)
    }

    private static func label(
        for source: MeetingSourceMetadata,
        captureMode: MeetingCaptureMode
    ) -> String {
        guard captureMode == .online else { return "Room" }
        switch source.kind {
        case .microphone: return "Me"
        case .systemAudio: return "System audio"
        }
    }

    private static func draftOrder(_ lhs: Draft, _ rhs: Draft) -> Bool {
        if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
        if sourceRank(lhs.sourceKind) != sourceRank(rhs.sourceKind) {
            return sourceRank(lhs.sourceKind) < sourceRank(rhs.sourceKind)
        }
        return lhs.id < rhs.id
    }

    private static func sourceRank(_ kind: MeetingSourceKind) -> Int {
        switch kind {
        case .microphone: return 0
        case .systemAudio: return 1
        }
    }

    private struct Draft {
        let id: String
        let sourceID: String
        let sourceSequence: Int
        let artifactID: String
        let sourceKind: MeetingSourceKind
        let startOffset: TimeInterval
        let endOffset: TimeInterval
        let sourceLabel: String
        let text: String
    }
}
