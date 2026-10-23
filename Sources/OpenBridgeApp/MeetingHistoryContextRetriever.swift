import Foundation

/// Operates only on an already-authorized frozen corpus, off the UI thread.
/// No cloud search/classification, indexing mutation or full-corpus upload.
enum MeetingHistoryContextRetriever {
    static func sourceKey(meetingID: String, segmentID: String) -> String { meetingID + "\u{1f}" + segmentID }
    static func select(current: MeetingManifest, history: [MeetingManifest], question: String,
                       previousQuestion: String?, previousSourceIDs: [String]) -> CurrentMeetingContextRetriever.Selection {
        let terms = Set(WorkspaceRetrievalIndex.contentTerms(question + " " + (previousQuestion ?? "")))
        let all = ([current] + history).flatMap { meeting in
            meeting.segments.filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.text.hasPrefix("AlignedResult(") && $0.meetingID == meeting.meetingID }.map { segment in
                CurrentMeetingPassage(segmentID: segment.id, text: segment.text, sourceLabel: segment.sourceLabel,
                    start: segment.startOffset, meetingID: meeting.meetingID, meetingTitle: meeting.title,
                    meetingDate: meeting.startedAt)
            }
        }
        let tokenSets = all.map { Set(WorkspaceRetrievalIndex.contentTerms($0.text)) }
        let frequencies = tokenSets.reduce(into: [String: Int]()) { counts, tokens in
            for token in tokens { counts[token, default: 0] += 1 }
        }
        let scores = tokenSets.map { tokens in terms.intersection(tokens).reduce(0.0) {
            $0 + log(1 + Double(all.count + 1) / Double(frequencies[$1, default: 0] + 1))
        } }
        var indices = all.indices.filter { all[$0].meetingID == current.meetingID }
            .sorted { (all[$0].start ?? 0) > (all[$1].start ?? 0) }.prefix(2).map { $0 }
        let prior = Set(previousSourceIDs)
        for i in all.indices where indices.count < 4 && !indices.contains(i)
            && prior.contains(sourceKey(meetingID: all[i].meetingID ?? "", segmentID: all[i].segmentID)) {
            indices.append(i)
        }
        let ranked = all.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        for i in ranked where indices.count < 6 && !indices.contains(i) && scores[i] > 0 { indices.append(i) }
        var remaining = 12_000
        let passages = indices.enumerated().map { offset, i in
            var passage = all[i]
            let text = String(passage.text.prefix(remaining / max(1, indices.count - offset)))
            remaining -= text.count
            passage = .init(segmentID: passage.segmentID, text: text, sourceLabel: passage.sourceLabel,
                start: passage.start, meetingID: passage.meetingID, meetingTitle: passage.meetingTitle, meetingDate: passage.meetingDate)
            return passage
        }
        return .init(passages: passages, isPartial: true)
    }
}
