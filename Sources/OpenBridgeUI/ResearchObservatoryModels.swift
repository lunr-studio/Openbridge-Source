import Foundation
import SwiftUI

// MARK: - Research Observatory Domain Models (#318)
//
// Provider-neutral domain contracts for the Meeting Research Observatory.
// No SwiftUI view may import a provider-specific implementation.
// Live orchestration belongs to #299; this shell is fixture-only (#318).

// MARK: - Rail State

/// The top-level state of the Research Observatory rail.
///
/// The rail is quiet by default. It surfaces at most one proactive memory
/// cue, transitions to searching when a question is active, and resolves to
/// answered, noSource, timeout, or failure.
public enum ResearchRailState: String, Equatable, Sendable, CaseIterable, Identifiable {
    case quiet
    case memoryCue
    case searching
    case answered
    case noSource
    case timeout
    case failure

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .memoryCue: return "Memory cue"
        case .searching: return "Searching"
        case .answered: return "Answered"
        case .noSource: return "No source"
        case .timeout: return "Timeout"
        case .failure: return "Failure"
        }
    }

    var statusText: String {
        switch self {
        case .quiet: return "Meeting Intelligence is quiet."
        case .memoryCue: return "A prior meeting may be relevant."
        case .searching: return "Searching for evidence…"
        case .answered: return "Evidence found."
        case .noSource: return "No relevant source found."
        case .timeout: return "The search timed out."
        case .failure: return "Something went wrong. Try again."
        }
    }
}

// MARK: - Question Origin

/// How a research question entered the system.
public enum ResearchQuestionOrigin: String, Equatable, Sendable, CaseIterable {
    case typed
    case spoken
}

// MARK: - Evidence Scope

/// Which sources the user authorized for a research question.
public struct ResearchEvidenceScope: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let currentMeeting  = ResearchEvidenceScope(rawValue: 1 << 0)
    static let priorMeetings   = ResearchEvidenceScope(rawValue: 1 << 1)
    static let web             = ResearchEvidenceScope(rawValue: 1 << 2)
    static let modelSynthesis  = ResearchEvidenceScope(rawValue: 1 << 3)

    public static let all: ResearchEvidenceScope = [.currentMeeting, .priorMeetings, .web, .modelSynthesis]
    public static let localOnly: ResearchEvidenceScope = [.currentMeeting, .priorMeetings]

    var labels: [String] {
        var result: [String] = []
        if contains(.currentMeeting)  { result.append("This meeting") }
        if contains(.priorMeetings)   { result.append("Prior meetings") }
        if contains(.web)             { result.append("Web") }
        if contains(.modelSynthesis)  { result.append("Model") }
        return result
    }
}

// MARK: - Research Question

/// A research question posed by the user.
public struct ResearchQuestion: Equatable, Identifiable, Sendable {
    public let id: String
    let text: String
    let origin: ResearchQuestionOrigin
    let scopes: ResearchEvidenceScope
    let allowsCloudWeb: Bool

    public init(
        id: String = UUID().uuidString,
        text: String,
        origin: ResearchQuestionOrigin = .typed,
        scopes: ResearchEvidenceScope = .localOnly,
        allowsCloudWeb: Bool = false
    ) {
        self.id = id
        self.text = text
        self.origin = origin
        self.scopes = scopes
        self.allowsCloudWeb = allowsCloudWeb
    }
}

// MARK: - Evidence Source Type

/// The kind of source backing a piece of evidence.
public enum ResearchEvidenceType: String, Equatable, Sendable, CaseIterable, Identifiable {
    case currentMeeting
    case priorMeeting
    case web
    case modelSynthesis

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentMeeting: return "This meeting"
        case .priorMeeting: return "Prior meeting"
        case .web: return "Web"
        case .modelSynthesis: return "Model synthesis"
        }
    }

    var iconName: String {
        switch self {
        case .currentMeeting: return "mic.fill"
        case .priorMeeting: return "clock.arrow.circlepath"
        case .web: return "globe"
        case .modelSynthesis: return "cpu"
        }
    }

    var bandColor: Color {
        switch self {
        case .currentMeeting: return OpenBridgePalette.blue
        case .priorMeeting: return OpenBridgePalette.cloudInk
        case .web: return OpenBridgePalette.localInk
        case .modelSynthesis: return OpenBridgePalette.warningInk
        }
    }
}

// MARK: - Source Locator

/// A stable, openable reference to where evidence was found.
public enum ResearchSourceLocator: Equatable, Sendable {
    case currentPassage(segmentID: String, meetingID: String)
    case priorMeeting(meetingID: String, segmentID: String?)
    case web(url: URL, title: String)
}

// MARK: - Evidence

/// A single piece of evidence surfaced in the research rail.
public struct ResearchEvidence: Equatable, Identifiable, Sendable {
    public let id: String
    let type: ResearchEvidenceType
    let passage: String
    let sourceLocator: ResearchSourceLocator
    let confidence: Double // 0.0–1.0
    /// lunr-studio/Openbridge-Beta#299 (Build 24): exact retrieval/store-owned
    /// identity for the evidence card (e.g. "Kickoff Sync · Sep 4, 2026 · 04:14").
    /// Nil falls back to the generic type display name. Never model-generated.
    let sourceTitle: String?

    public init(
        id: String = UUID().uuidString,
        type: ResearchEvidenceType,
        passage: String,
        sourceLocator: ResearchSourceLocator,
        confidence: Double = 0.8,
        sourceTitle: String? = nil
    ) {
        self.id = id
        self.type = type
        self.passage = passage
        self.sourceLocator = sourceLocator
        self.sourceTitle = sourceTitle
        self.confidence = confidence
    }
}

// MARK: - Card Variant

/// The kind of research card to render.
public enum ResearchCardVariant: String, Equatable, Sendable, CaseIterable, Identifiable {
    case priorDiscussion
    case priorDecision
    case actionCandidate
    case openLoop
    case changedDecision

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .priorDiscussion: return "Prior discussion"
        case .priorDecision: return "Prior decision"
        case .actionCandidate: return "Action candidate"
        case .openLoop: return "Open loop"
        case .changedDecision: return "Changed decision"
        }
    }

    var iconName: String {
        switch self {
        case .priorDiscussion: return "bubble.left.and.bubble.right"
        case .priorDecision: return "checkmark.seal"
        case .actionCandidate: return "checkmark.square"
        case .openLoop: return "arrow.triangle.2.circlepath"
        case .changedDecision: return "arrow.left.arrow.right"
        }
    }
}

// MARK: - Research Card

/// A card displayed in the research rail, backed by evidence.
public struct ResearchCard: Equatable, Identifiable, Sendable {
    public let id: String
    let variant: ResearchCardVariant
    let title: String
    let summary: String
    let evidence: [ResearchEvidence]
    var isPinned: Bool = false
    var isDismissed: Bool = false
    var isExpanded: Bool = true

    public init(
        id: String = UUID().uuidString,
        variant: ResearchCardVariant,
        title: String,
        summary: String,
        evidence: [ResearchEvidence],
        isPinned: Bool = false,
        isDismissed: Bool = false,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.variant = variant
        self.title = title
        self.summary = summary
        self.evidence = evidence
        self.isPinned = isPinned
        self.isDismissed = isDismissed
        self.isExpanded = isExpanded
    }
}

// MARK: - Focus Mode (narrow windows)

/// Layout mode for narrow windows.
public enum ResearchFocusMode: String, Equatable, Sendable, CaseIterable, Identifiable {
    case transcript
    case split
    case research

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcript: return "Transcript"
        case .split: return "Split"
        case .research: return "Intelligence"
        }
    }
}

// MARK: - Feature Flag

/// Controls whether the Research Observatory rail is visible.
/// Defaults to Off — this is an explicit-action-only Beta feature.
public enum ResearchObservatoryFeatureFlag {
    /// Versioned production consent. The former unversioned key belonged to
    /// an internal Alpha/Debug switch and must never opt a user into Beta.
    public static let key = "research.observatory.beta.v1.enabled"
    public static let legacyInternalKey = "research.observatory.enabled"

    public static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    public static func setEnabled(
        _ enabled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: key)
    }

    public static func clearLegacyInternalValue(
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: legacyInternalKey)
    }
}
