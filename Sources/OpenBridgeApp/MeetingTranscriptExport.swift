import Foundation

// MARK: - Export format

enum MeetingTranscriptExportFormat: String, Sendable {
    case txt
    case markdown

    var fileExtension: String { rawValue }
}

// MARK: - Export source

/// Which transcript to export.
///
/// `.cleaned` uses the active cleanup revision when one is valid and current;
/// callers that receive `.cleaned` should check the returned document to see
/// whether the fallback to `.original` occurred.
enum MeetingTranscriptExportSource: String, Sendable, Equatable {
    case cleaned
    case original
}

// MARK: - Export document

/// A prepared transcript export ready to be written to disk.
///
/// The `effectiveSource` field records whether a `.cleaned` request resolved
/// to a valid revision or fell back to the canonical original. This lets the
/// caller and tests distinguish the two without re-reading the file.
struct MeetingTranscriptDocument: Equatable {
    let text: String
    let format: MeetingTranscriptExportFormat
    let effectiveSource: MeetingTranscriptExportSource
    let revisionID: String?

    var filename: String {
        // Predictable filename: "Transcript.txt" or "Transcript.md"
        switch format {
        case .txt: return "Transcript.txt"
        case .markdown: return "Transcript.md"
        }
    }
}

// MARK: - Exporter

/// Builds deterministic TXT and Markdown transcript documents from a meeting
/// manifest and an optional active cleanup revision.
///
/// The canonical original transcript (`manifest.segments`) is never modified.
/// When exporting the cleaned revision, cleaned text replaces segment text
/// in document order; every other field (timestamps, labels) comes from the
/// original segment so the reader can still navigate the source.
enum MeetingTranscriptExporter {

    // MARK: Public API

    /// Produce an export document for the given manifest.
    ///
    /// Pass a non-nil `revision` only when it is the **active, valid** revision
    /// returned by `MeetingSessionStore.activeCleanupRevision`. The caller is
    /// responsible for that validity check; the exporter itself performs no
    /// I/O.
    static func makeDocument(
        manifest: MeetingManifest,
        format: MeetingTranscriptExportFormat,
        requestedSource: MeetingTranscriptExportSource,
        activeRevision: MeetingCleanupRevision?
    ) -> MeetingTranscriptDocument {
        // Determine effective source.
        let effectiveSource: MeetingTranscriptExportSource
        let revisionForExport: MeetingCleanupRevision?

        switch requestedSource {
        case .original:
            effectiveSource = .original
            revisionForExport = nil
        case .cleaned:
            if let activeRevision {
                effectiveSource = .cleaned
                revisionForExport = activeRevision
            } else {
                // Fall back to original — no valid/active revision exists.
                effectiveSource = .original
                revisionForExport = nil
            }
        }

        let text: String
        switch format {
        case .txt:
            text = makePlainText(manifest: manifest, source: effectiveSource, revision: revisionForExport)
        case .markdown:
            text = makeMarkdown(manifest: manifest, source: effectiveSource, revision: revisionForExport)
        }

        return MeetingTranscriptDocument(
            text: text,
            format: format,
            effectiveSource: effectiveSource,
            revisionID: revisionForExport?.id
        )
    }

    // MARK: - Plain text

    private static func makePlainText(
        manifest: MeetingManifest,
        source: MeetingTranscriptExportSource,
        revision: MeetingCleanupRevision?
    ) -> String {
        var lines: [String] = []
        lines.append("OpenBridge Meeting Transcript")
        lines.append(String(repeating: "=", count: 30))
        lines.append("")
        lines.append("Title: \(manifest.title)")
        lines.append("Date: \(iso(manifest.startedAt))")
        if let endedAt = manifest.endedAt {
            lines.append("Ended: \(iso(endedAt))")
        }
        lines.append("Source: \(sourceLabel(source, revision: revision))")
        if let revision {
            lines.append("Revision ID: \(revision.id)")
            lines.append("Model: \(revision.modelRepository)")
            if let modelRevision = revision.modelRevision {
                lines.append("Model Revision: \(modelRevision)")
            }
            lines.append("Contract Version: \(revision.contractVersion)")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        // Transcript lines
        for entry in transcriptLines(manifest: manifest, source: source, revision: revision) {
            lines.append(entry)
        }

        // Optional metadata sections
        if let summary = manifest.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("Summary:")
            lines.append(summary)
        }
        if let actions = manifest.actionItemsText?.trimmingCharacters(in: .whitespacesAndNewlines), !actions.isEmpty {
            lines.append("")
            lines.append("Action Items:")
            lines.append(actions)
        }
        if let notes = manifest.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(notes)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Markdown

    private static func makeMarkdown(
        manifest: MeetingManifest,
        source: MeetingTranscriptExportSource,
        revision: MeetingCleanupRevision?
    ) -> String {
        var lines: [String] = []
        lines.append("# \(manifest.title)")
        lines.append("")
        lines.append("- **Date:** \(iso(manifest.startedAt))")
        if let endedAt = manifest.endedAt {
            lines.append("- **Ended:** \(iso(endedAt))")
        }
        lines.append("- **Source:** \(sourceLabel(source, revision: revision))")
        if let revision {
            lines.append("- **Revision ID:** \(revision.id)")
            lines.append("- **Model:** \(revision.modelRepository)")
            if let modelRevision = revision.modelRevision {
                lines.append("- **Model Revision:** \(modelRevision)")
            }
            lines.append("- **Contract Version:** \(revision.contractVersion)")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        // Transcript blocks
        for entry in transcriptBlocks(manifest: manifest, source: source, revision: revision) {
            lines.append(entry)
        }

        // Optional metadata sections
        if let summary = manifest.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }
        if let actions = manifest.actionItemsText?.trimmingCharacters(in: .whitespacesAndNewlines), !actions.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            lines.append(actions)
            lines.append("")
        }
        if let notes = manifest.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Shared helpers

    /// One string per transcript line: `[HH:MM:SS] Label: text`
    private static func transcriptLines(
        manifest: MeetingManifest,
        source: MeetingTranscriptExportSource,
        revision: MeetingCleanupRevision?
    ) -> [String] {
        let rows = buildTranscriptRows(manifest: manifest, source: source, revision: revision)
        return rows.map { row in
            "[\(formatOffset(row.startOffset))] \(row.label): \(row.text)"
        }
    }

    /// One string per Markdown paragraph block.
    private static func transcriptBlocks(
        manifest: MeetingManifest,
        source: MeetingTranscriptExportSource,
        revision: MeetingCleanupRevision?
    ) -> [String] {
        let rows = buildTranscriptRows(manifest: manifest, source: source, revision: revision)
        return rows.map { row in
            "**[\(formatOffset(row.startOffset))] \(row.label)**\n\n\(row.text)\n"
        }
    }

    /// Unified row model that handles both typed segments and legacy spans.
    private struct TranscriptRow {
        let startOffset: TimeInterval?
        let label: String
        let text: String
    }

    private static func buildTranscriptRows(
        manifest: MeetingManifest,
        source: MeetingTranscriptExportSource,
        revision: MeetingCleanupRevision?
    ) -> [TranscriptRow] {
        // Prefer typed segments; fall back to legacy v1 spans.
        let sortedSegments = manifest.segments.sorted {
            MeetingTranscriptFingerprint.canonicalOrder($0, $1)
        }

        if !sortedSegments.isEmpty {
            // Build a lookup for cleaned text when exporting a revision.
            var cleanedByID: [String: String] = [:]
            if source == .cleaned, let revision {
                for cleaned in revision.cleanedSegments {
                    cleanedByID[cleaned.sourceSegmentID] = cleaned.cleanedText
                }
            }
            return sortedSegments.map { segment in
                TranscriptRow(
                    startOffset: segment.startOffset,
                    label: segment.sourceLabel,
                    text: cleanedByID[segment.id] ?? segment.text
                )
            }
        }

        // Legacy v1 fallback — spans are plain strings with no offsets/labels.
        return manifest.transcriptSpans.map { span in
            TranscriptRow(startOffset: nil, label: "Room", text: span)
        }
    }

    private static func formatOffset(_ offset: TimeInterval?) -> String {
        guard let offset else { return "--:--:--" }
        let total = max(0, Int(offset))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private static func sourceLabel(
        _ source: MeetingTranscriptExportSource,
        revision: MeetingCleanupRevision?
    ) -> String {
        switch source {
        case .original:
            return "Original canonical transcript"
        case .cleaned:
            return "Cleaned revision"
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}