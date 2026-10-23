import Foundation
import OpenBridgeUI

struct MeetingConversationContext: Codable, Equatable, Sendable {
    let question: String
    let answer: String
    let sourceMeetingIDs: [String]
}

struct SavedMeetingQuestion: Codable, Equatable, Sendable {
    let id: String
    let question: String
    let submittedAt: Date
    let cutoff: TimeInterval
    let phase: String
    let scope: String
    let detail: String?
    let passages: [CurrentMeetingPassage]
    let sourceMeetingIDs: [String]
    let coveredThrough: TimeInterval
    let partial: Bool
    let response: CurrentMeetingQuestionResponse?
    var approvedWebQuery: String? = nil
    var approvedWebDomains: [String]? = nil
    var referencedMeetingIDs: Set<String> { Set(sourceMeetingIDs + passages.compactMap(\.meetingID)) }
}

struct MeetingConversationDocument: Codable, Equatable, Sendable {
    var version = 1
    let meetingID: String
    var questions: [SavedMeetingQuestion]
}

enum MeetingConversationError: Error {
    case unavailable, unsupportedVersion, tooLarge
}

/// Sidecars never rewrite the transcript manifest. The root-scoped lock also
/// covers source deletion, so a queued save cannot resurrect deleted evidence.
struct MeetingConversationStore: Sendable {
    let store: MeetingSessionStore
    static let maximumBytes = 8 * 1_024 * 1_024
    static func locked<T>(_ store: MeetingSessionStore, _ body: () throws -> T) rethrows -> T {
        try store.withManifestTransaction(meetingID: "conversation-storage-lock", body)
    }
    func url(_ id: String) -> URL { store.meetingDirectory(for: id).appendingPathComponent("conversation.json") }
    private func eligible(_ id: String) -> Bool {
        guard let manifest = try? store.load(meetingID: id) else { return false }
        return MeetingResearchPermissionPolicy.eligible(manifest)
    }
    func load(_ id: String) throws -> MeetingConversationDocument {
        try Self.locked(store) {
            guard eligible(id) else { throw MeetingConversationError.unavailable }
            guard FileManager.default.fileExists(atPath: url(id).path) else {
                return .init(meetingID: id, questions: [])
            }
            let document = try read(id)
            return .init(meetingID: id, questions: document.questions.filter {
                $0.referencedMeetingIDs.allSatisfy(eligible)
            })
        }
    }
    private func read(_ id: String) throws -> MeetingConversationDocument {
        let size = try url(id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumBytes else { throw MeetingConversationError.tooLarge }
        let data = try Data(contentsOf: url(id))
        let document = try JSONDecoder().decode(MeetingConversationDocument.self, from: data)
        guard document.version == 1, document.meetingID == id,
              Set(document.questions.map(\.id)).count == document.questions.count,
              document.questions.allSatisfy({ $0.response == nil || $0.response?.requestID == $0.id }) else {
            throw MeetingConversationError.unsupportedVersion
        }
        return document
    }
    private func write(_ document: MeetingConversationDocument) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumBytes else { throw MeetingConversationError.tooLarge }
        try data.write(to: url(document.meetingID), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(document.meetingID).path)
    }
    func save(_ value: MeetingConversationDocument) throws {
        try Self.locked(store) {
            guard eligible(value.meetingID) else { throw MeetingConversationError.unavailable }
            var valid = value
            valid.questions.removeAll { !$0.referencedMeetingIDs.allSatisfy(eligible) }
            // No createDirectory: absent/deleted meetings must never reappear.
            try write(valid)
        }
    }
    func purgeReferences(to sourceID: String) throws {
        try Self.locked(store) {
            var firstFailure: Error?
            for manifest in try store.listMeetings() where manifest.meetingID != sourceID {
                let file = url(manifest.meetingID)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                do {
                    var document = try read(manifest.meetingID)
                    let count = document.questions.count
                    document.questions.removeAll { $0.referencedMeetingIDs.contains(sourceID) }
                    if document.questions.count != count { try write(document) }
                } catch { if firstFailure == nil { firstFailure = error } }
            }
            if let firstFailure { throw firstFailure }
        }
    }
}

enum MeetingConversationContextPolicy {
    /// Never send unbounded history, another scope's evidence or revoked data.
    static func select(_ candidates: [MeetingConversationContext], allowedIDs: Set<String>) -> [MeetingConversationContext] {
        var remaining = 24_000
        var result: [MeetingConversationContext] = []
        for turn in candidates.reversed() where result.count < 8 {
            guard Set(turn.sourceMeetingIDs).isSubset(of: allowedIDs) else { continue }
            let count = turn.question.count + turn.answer.count
            guard count <= remaining else { continue }
            remaining -= count
            result.append(turn)
        }
        return result.reversed()
    }
}
