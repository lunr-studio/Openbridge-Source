import Foundation
import SwiftUI

/// Manages the remembered "Clean transcript locally after Stop" toggle (lunr-studio/Openbridge-Beta#321).
///
/// The toggle defaults to Off and its state survives relaunch via `@AppStorage`.
/// Cleanup is NEVER allowed during recording — this is enforced by
/// `canStartCleanup(for:)` regardless of the toggle state.
///
/// Per the lunr-studio/Openbridge-Beta#321 design gate: this is the storage/logic layer only.
/// Production SwiftUI views require Trishan's explicit design approval.
struct MeetingCleanupSettings {
    static let toggleKey = "meeting.cleanupEnabled"

    /// Returns the persisted toggle value (defaults to false).
    static var isCleanupEnabled: Bool {
        UserDefaults.standard.bool(forKey: toggleKey)
    }

    /// Sets the toggle value and persists it.
    static func setCleanupEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: toggleKey)
    }

    /// lunr-studio/Openbridge-Beta#321 wave-4 (3886250999): the master toggle and
    /// the cleanup mode are ONE intent - a mode of .off means intent withdrawn.
    static func syncFromCleanupMode(_ mode: TranscriptionCleanupMode) {
        setCleanupEnabled(mode != .off)
    }

    /// Determines whether cleanup may start for a meeting.
    ///
    /// Rules:
    /// 1. The toggle must be On.
    /// 2. The meeting must have completed successfully.
    /// 3. Local intelligence must be allowed for this meeting.
    /// 4. The meeting must have a valid canonical transcript (at least one
    ///    final typed segment).
    static func canStartCleanup(for manifest: MeetingManifest) -> Bool {
        guard isCleanupEnabled else { return false }
        guard manifest.state == .completed else { return false }
        guard manifest.privacySettings.allowsLocalIntelligence else { return false }

        // Must have at least one final segment
        return manifest.segments.contains { $0.isFinal }
    }
}

// MARK: - Fixture-only review surface (lunr-studio/Openbridge-Beta#321 design gate)
//
// These views are for Trishan's synthetic-state design review ONLY.
// They use fixture data, not real meetings or live cleanup jobs.
// Production SwiftUI implementation requires Trishan's explicit approval
// recorded on issue lunr-studio/Openbridge-Beta#321.
//
// To view these fixtures:
//   1. Open the project in Xcode
//   2. Open MeetingCleanupReviewSurface.swift
//   3. Use the Canvas (Cmd+Option+Enter) to see all preview states
//   4. Or build and run the fixture preview app (see instructions)

#if DEBUG

/// All possible cleanup UI states that the fixture surface must cover.
enum MeetingCleanupReviewState: String, CaseIterable, Identifiable {
    case toggleOff
    case toggleOnPreStop
    case originalShownImmediately
    case queued
    case running
    case cancelled
    case missingModel
    case failed
    case retryAvailable
    case stale
    case completedCleanedDefault
    case completedOriginalView

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggleOff: return "Toggle Off (default)"
        case .toggleOnPreStop: return "Toggle On, pre-Stop"
        case .originalShownImmediately: return "Original shown immediately after Stop"
        case .queued: return "Cleanup queued"
        case .running: return "Cleanup running"
        case .cancelled: return "Cleanup cancelled"
        case .missingModel: return "Missing model"
        case .failed: return "Cleanup failed"
        case .retryAvailable: return "Retry available"
        case .stale: return "Stale (source changed)"
        case .completedCleanedDefault: return "Completed — Cleaned default"
        case .completedOriginalView: return "Completed — Original view"
        }
    }

    var statusText: String {
        switch self {
        case .toggleOff: return "Clean transcript locally is off."
        case .toggleOnPreStop: return "Clean transcript locally is on. Cleanup starts after recording stops."
        case .originalShownImmediately: return "Transcript is ready. Cleanup will start shortly."
        case .queued: return "Cleaning transcript…"
        case .running: return "Cleaning transcript…"
        case .cancelled: return "Cleanup cancelled. Original transcript is available."
        case .missingModel: return "Cleanup model is not available. Original transcript is ready."
        case .failed: return "Cleanup failed. Original transcript is available."
        case .retryAvailable: return "Cleanup failed. Tap retry or use the original transcript."
        case .stale: return "The transcript changed since cleanup. Original is shown."
        case .completedCleanedDefault: return "Cleaned transcript is ready."
        case .completedOriginalView: return "Showing original transcript."
        }
    }

    var showsProgress: Bool {
        switch self {
        case .queued, .running: return true
        default: return false
        }
    }

    var allowsRetry: Bool {
        switch self {
        case .failed, .retryAvailable: return true
        default: return false
        }
    }

    var showsRevisionSwitch: Bool {
        switch self {
        case .completedCleanedDefault, .completedOriginalView: return true
        default: return false
        }
    }
}

/// Fixture transcript data for the review surface.
enum MeetingCleanupFixtures {
    static let originalSegment = MeetingTranscriptSegment(
        id: "fix-1",
        meetingID: "fixture-meeting",
        sequence: 0,
        startOffset: 0,
        endOffset: 30,
        sourceLabel: "Room",
        text: "so um yeah I think we should probably move the meeting to next week because everyone is pretty busy right now",
        isFinal: true
    )

    static let cleanedText = "I think we should move the meeting to next week because everyone is busy."

    static let originalText = originalSegment.text
}

#endif
// MARK: - Post-Stop execution plan (wave-7, PR #67 3836503097)

/// Pure decision helper for the post-Stop cleanup wiring: SHOULD the
/// selected cleanup run for this completed meeting? Encapsulates AGENTS.md
/// L39-42 - Gemma owns post-meeting cleanup after Stop; the transcriber
/// itself is Parakeet-only. `MainWindowView.runPostStopCleanup` consults
/// this before constructing the coordinator.
enum MeetingPostStopCleanupPlan {
    /// Cleanup may start only when a Gemma mode is selected, the lunr-studio/Openbridge-Beta#321
    /// toggle is on, the meeting completed, local intelligence is allowed,
    /// and a final typed segment exists (reuse of the eligibility rules in
    /// `MeetingCleanupSettings.canStartCleanup`).
    static func shouldRun(
        mode: TranscriptionCleanupMode,
        manifest: MeetingManifest
    ) -> Bool {
        guard manifest.state == .completed else { return false }
        if let intelligence = manifest.intelligenceConfiguration {
            guard intelligence.cleanupEnabled else { return false }
            switch intelligence.cleanupProvider {
            case .localGemma:
                guard manifest.privacySettings.allowsLocalIntelligence else { return false }
            case .cloud:
                guard manifest.aiMode.maySendTranscriptToCloud,
                      manifest.privacySettings.allowsCloudIntelligence,
                      intelligence.cloudProvider != nil else { return false }
            }
        } else {
            // Legacy meetings retain their pre-build-19 local behavior but do
            // not gain the new cloud alternative or intelligence actions.
            guard MeetingCleanupSettings.isCleanupEnabled else { return false }
            guard mode != .off else { return false }
            guard manifest.aiMode != .transcriptionOnly else { return false }
            guard manifest.privacySettings.allowsLocalIntelligence else { return false }
        }
        return manifest.segments.contains { $0.isFinal }
    }

    /// Wave-8 (3837539273): truth-in-behavior. The coordinator implements
    /// ONE post-Stop cleanup contract - the offline full-transcript pass -
    /// for either Fast or Careful selection; it does NOT (yet) differentiate
    /// cost/behavior by mode. Exposing exactly that keeps the wiring honest;
    /// mode-differentiated cleanup behavior is lunr-studio/Openbridge-Beta#321's flagship scope and
    /// must not be claimed here.
    static var implementsModeDifferentiatedBehavior: Bool { false }
}
