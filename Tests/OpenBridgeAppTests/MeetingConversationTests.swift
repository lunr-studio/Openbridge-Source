import Foundation
import Testing
@testable import OpenBridgeApp

@Suite struct MeetingConversationTests {
    private func fixture() throws -> (MeetingSessionStore, MeetingConversationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-tests-\(UUID().uuidString)")
        let store = MeetingSessionStore(rootDirectory: root, meetingDeletionObserver: { _ in })
        try store.create(MeetingManifest(meetingID: "current", title: "Synthetic current", state: .completed))
        try store.create(MeetingManifest(meetingID: "past", title: "Synthetic past", state: .completed))
        return (store, .init(store: store))
    }
    private func question(_ id: String = "one", sources: [String] = ["current"], phase: String = "answered") -> SavedMeetingQuestion {
        .init(id: id, question: "What did Cedar decide?", submittedAt: Date(timeIntervalSince1970: 1_000),
            cutoff: 30, phase: phase, scope: "thisMeeting", detail: nil,
            passages: [.init(segmentID: "s1", text: "Cedar launches on Friday.", sourceLabel: "Room", start: 0, meetingID: sources.first)],
            sourceMeetingIDs: sources, coveredThrough: 30, partial: false,
            response: phase == "answered" ? .init(requestID: id, claims: [], explanation: "A synthetic explanation.", limitation: nil) : nil)
    }

    @Test func versionedSidecarRoundTripsWithoutChangingManifestOrPermission() throws {
        let (store, conversation) = try fixture(); defer { try? store.deleteAll() }
        let manifest = try Data(contentsOf: store.manifestURL(for: "current"))
        let document = MeetingConversationDocument(meetingID: "current", questions: [question()])
        try conversation.save(document)
        #expect(try conversation.load("current") == document)
        #expect(try Data(contentsOf: store.manifestURL(for: "current")) == manifest)
        let attributes = try FileManager.default.attributesOfItem(atPath: conversation.url("current").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(for: "current").appendingPathComponent("research-permission.json").path))
    }

    @Test func deletingSourcePurgesDependentTurnsAndLateSaveCannotRestoreThem() throws {
        let (store, conversation) = try fixture(); defer { try? store.deleteAll() }
        let stale = MeetingConversationDocument(meetingID: "current", questions: [question(), question("dependent", sources: ["current", "past"])])
        try conversation.save(stale)
        try store.delete(meetingID: "past")
        #expect(try conversation.load("current").questions.map(\.id) == ["one"])
        // A save queued before deletion is revalidated under the same lock.
        try conversation.save(stale)
        #expect(try conversation.load("current").questions.map(\.id) == ["one"])
        let raw = try JSONDecoder().decode(MeetingConversationDocument.self, from: Data(contentsOf: conversation.url("current")))
        #expect(raw.questions.map(\.id) == ["one"])
        try store.delete(meetingID: "current")
        #expect(throws: MeetingConversationError.self) { try conversation.save(stale) }
        #expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(for: "current").path))
    }

    @Test func unrelatedCorruptConversationDoesNotPreventOtherReferencePurges() throws {
        let (store, conversation) = try fixture(); defer { try? store.deleteAll() }
        try store.create(MeetingManifest(meetingID: "corrupt", title: "Corrupt fixture", state: .completed))
        try Data("{truncated".utf8).write(to: conversation.url("corrupt"))
        try conversation.save(.init(meetingID: "current", questions: [question(sources: ["past"])]))
        #expect(throws: (any Error).self) { try store.delete(meetingID: "past") }
        #expect(try conversation.load("current").questions.isEmpty)
        #expect(try String(contentsOf: conversation.url("corrupt"), encoding: .utf8) == "{truncated")
    }

    @Test func neverStoreAndExpiredMeetingsRejectConversationStorage() throws {
        let (store, conversation) = try fixture(); defer { try? store.deleteAll() }
        for policy in [MeetingRetentionPolicy.neverStoreTranscript, .autoDeleteAfter7Days] {
            var manifest = try store.load(meetingID: "current")
            manifest.retentionPolicy = policy
            manifest.startedAt = Date().addingTimeInterval(-9 * 86_400)
            try store.saveManifest(manifest)
            #expect(throws: MeetingConversationError.self) { try conversation.save(.init(meetingID: "current", questions: [question()])) }
            #expect(throws: MeetingConversationError.self) { try conversation.load("current") }
        }
        #expect(!FileManager.default.fileExists(atPath: conversation.url("current").path))
    }

    @Test func unknownSchemaAndDuplicateIdentityFailClosed() throws {
        let (store, conversation) = try fixture(); defer { try? store.deleteAll() }
        var document = MeetingConversationDocument(meetingID: "current", questions: [question()])
        document.version = 99
        try JSONEncoder().encode(document).write(to: conversation.url("current"))
        #expect(throws: MeetingConversationError.self) { try conversation.load("current") }
        document.version = 1; document.questions.append(question())
        try JSONEncoder().encode(document).write(to: conversation.url("current"))
        #expect(throws: MeetingConversationError.self) { try conversation.load("current") }
    }

    @Test func contextIsRecentBoundedAndScopedWithoutTruncatingIndividualTurns() {
        let turns = (0..<12).map { MeetingConversationContext(question: "Q\($0)", answer: "A\($0)", sourceMeetingIDs: ["current"]) }
        let revoked = MeetingConversationContext(question: "Private question", answer: "Private answer", sourceMeetingIDs: ["past"])
        let tooLong = MeetingConversationContext(question: "Large", answer: String(repeating: "x", count: 24_001), sourceMeetingIDs: ["current"])
        let result = MeetingConversationContextPolicy.select(turns + [revoked, tooLong], allowedIDs: ["current"])
        #expect(result == Array(turns.suffix(8)))
        let long = (0..<8).map { MeetingConversationContext(question: "Q\($0)", answer: String(repeating: "x", count: 4_000), sourceMeetingIDs: ["current"]) }
        #expect(MeetingConversationContextPolicy.select(long, allowedIDs: ["current"]).count == 5)
        #expect(MeetingConversationContextPolicy.select([revoked], allowedIDs: ["current", "past"]) == [revoked])
    }
}
