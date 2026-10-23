import SwiftUI

// MARK: - Fixture Review Surface for #321 Design Gate
//
// This file contains fixture-only SwiftUI views for Trishan's design review.
// All data is synthetic. These views are NOT wired to production code.
// Production implementation requires Trishan's explicit approval on
// lunr-studio/Openbridge-Beta#321.

#if DEBUG

/// A single fixture card showing one cleanup UI state.
/// This mirrors the visual style described in DESIGN.md:
/// - Calm, premium utility
/// - White and cool-blue surfaces, navy text
/// - Short sentence-case labels
struct FixtureCleanupCard: View {
    let state: MeetingCleanupReviewState
    let toggleEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: state label
            HStack {
                Text(state.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }

            // Toggle (only in toggle states)
            if state == .toggleOff || state == .toggleOnPreStop {
                Toggle("Clean transcript locally", isOn: .constant(toggleEnabled))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Status message
            Text(state.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Progress indicator
            if state.showsProgress {
                ProgressView()
                    .scaleEffect(0.8)
            }

            // Transcript preview (shows original or cleaned text)
            transcriptPreview

            // Error/retry actions
            if state.allowsRetry {
                HStack(spacing: 12) {
                    Button("Retry cleanup") {}
                        .buttonStyle(.bordered)
                    Button("Use original") {}
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            // Original/Cleaned switch (completed states)
            if state.showsRevisionSwitch {
                Picker("Revision", selection: .constant(state == .completedCleanedDefault ? "Cleaned" : "Original")) {
                    Text("Cleaned").tag("Cleaned")
                    Text("Original").tag("Original")
                }
                .pickerStyle(.segmented)
                .font(.subheadline)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    @ViewBuilder
    private var transcriptPreview: some View {
        let text: String = {
            switch state {
            case .completedCleanedDefault:
                return MeetingCleanupFixtures.cleanedText
            case .completedOriginalView, .stale:
                return MeetingCleanupFixtures.originalText
            default:
                return MeetingCleanupFixtures.originalText
            }
        }()

        if state == .toggleOff || state == .toggleOnPreStop {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("[00:00:00] Room")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(Color.blue.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The full review gallery — shows all 12 states in a scrollable list.
/// Trishan reviews this in Xcode Canvas or via the preview app.
struct FixtureCleanupReviewGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Cleanup Toggle & Review — Design Review (#321)")
                    .font(.title2.bold())
                    .padding(.bottom, 8)

                Text("All states below use synthetic fixture data. Review the status text, toggle, progress, retry actions, and revision switch for each state.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                ForEach(MeetingCleanupReviewState.allCases) { state in
                    FixtureCleanupCard(
                        state: state,
                        toggleEnabled: state != .toggleOff
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Xcode Canvas Previews (PreviewProvider for SwiftPM compatibility)

struct FixtureCleanupPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            FixtureCleanupReviewGallery()
                .previewDisplayName("Full Gallery")

            FixtureCleanupCard(state: .toggleOff, toggleEnabled: false)
                .padding()
                .previewDisplayName("Toggle Off")

            FixtureCleanupCard(state: .toggleOnPreStop, toggleEnabled: true)
                .padding()
                .previewDisplayName("Toggle On, Pre-Stop")

            FixtureCleanupCard(state: .originalShownImmediately, toggleEnabled: true)
                .padding()
                .previewDisplayName("Original Shown Immediately")

            FixtureCleanupCard(state: .queued, toggleEnabled: true)
                .padding()
                .previewDisplayName("Queued")

            FixtureCleanupCard(state: .running, toggleEnabled: true)
                .padding()
                .previewDisplayName("Running")

            FixtureCleanupCard(state: .cancelled, toggleEnabled: true)
                .padding()
                .previewDisplayName("Cancelled")

            FixtureCleanupCard(state: .missingModel, toggleEnabled: true)
                .padding()
                .previewDisplayName("Missing Model")

            FixtureCleanupCard(state: .failed, toggleEnabled: true)
                .padding()
                .previewDisplayName("Failed")

            FixtureCleanupCard(state: .retryAvailable, toggleEnabled: true)
                .padding()
                .previewDisplayName("Retry Available")

            FixtureCleanupCard(state: .stale, toggleEnabled: true)
                .padding()
                .previewDisplayName("Stale")

            FixtureCleanupCard(state: .completedCleanedDefault, toggleEnabled: true)
                .padding()
                .previewDisplayName("Completed — Cleaned")

            FixtureCleanupCard(state: .completedOriginalView, toggleEnabled: true)
                .padding()
                .previewDisplayName("Completed — Original")
        }
    }
}

#endif
