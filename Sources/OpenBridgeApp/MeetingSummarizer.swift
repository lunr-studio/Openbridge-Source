import Foundation

/// Generates meeting summaries and action items from transcript spans
/// using the existing `EngineService.transformSelectedText()` command-mode API.
///
/// After a meeting stops, the summary service:
/// 1. Concatenates all transcript spans into one text block
/// 2. Calls the local LLM (Ollama) with a "summarize" instruction
/// 3. Calls it again with an "extract action items" instruction
/// 4. Saves results to the meeting manifest
@MainActor
final class MeetingSummarizer: ObservableObject {
    @Published var isGenerating = false
    @Published var summaryText: String?
    @Published var actionItemsText: String?
    @Published var error: String?

    private let engine = EngineService()

    func generateSummary(
        for meetingID: String,
        transcriptSpans: [String],
        store: MeetingSessionStore
    ) async {
        guard !transcriptSpans.isEmpty else {
            error = "No transcript available to summarize."
            return
        }

        isGenerating = true
        error = nil

        let fullTranscript = transcriptSpans.joined(separator: "\n\n")

        do {
            // Generate summary
            let summaryResponse = try await engine.transformSelectedText(
                selectedText: fullTranscript,
                instruction: "Summarize this meeting transcript in 3-5 key points. Be concise and actionable.",
                appContext: "Meeting summary"
            )
            summaryText = summaryResponse.transformedText

            // Generate action items
            let actionResponse = try await engine.transformSelectedText(
                selectedText: fullTranscript,
                instruction: "Extract action items from this meeting transcript as a bulleted list. Each item should start with a dash.",
                appContext: "Meeting action items"
            )
            actionItemsText = actionResponse.transformedText

            // Save to manifest
            if var manifest = try? store.load(meetingID: meetingID) {
                manifest.summaryText = summaryText
                manifest.actionItemsText = actionItemsText
                try? store.saveManifest(manifest)
            }
        } catch {
            self.error = "Summary generation failed: \(error.localizedDescription)"
        }

        isGenerating = false
    }
}