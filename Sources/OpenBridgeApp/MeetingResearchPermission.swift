import Foundation

/// Purpose-specific consent. Deliberately separate from recording/cleanup
/// snapshots so capture saves cannot restore an old research grant.
struct MeetingResearchPermission: Codable, Equatable, Sendable {
    var version = 1
    let allowed: Bool
    let provider: MeetingCloudProviderSnapshot?
    let changedAt: Date
}

enum MeetingResearchPermissionPolicy {
    static func authorizedConfiguration(ids: [String], store: MeetingSessionStore,
                                        configuration: ProviderConfiguration) -> ProviderConfiguration? {
        guard !ids.isEmpty else { return nil }
        for id in Set(ids) {
            guard let meeting = try? store.load(meetingID: id), let snapshot = provider(for: meeting, store: store),
                  configuration.hasSameProviderIdentity(as: snapshot.configuration) else { return nil }
        }
        return configuration
    }
    static func eligible(_ meeting: MeetingManifest, now: Date = Date()) -> Bool {
        guard meeting.retentionPolicy != .neverStoreTranscript,
              meeting.privacySettings.retainsTranscript else { return false }
        if let days = meeting.retentionPolicy.retentionDays,
           (meeting.endedAt ?? meeting.startedAt).addingTimeInterval(Double(days) * 86_400) <= now { return false }
        return true
    }

    static func provider(for meeting: MeetingManifest, store: MeetingSessionStore) -> MeetingCloudProviderSnapshot? {
        guard eligible(meeting) else { return nil }
        let url = store.meetingDirectory(for: meeting.meetingID).appendingPathComponent("research-permission.json")
        if FileManager.default.fileExists(atPath: url.path) {
            // A corrupt/unknown permission must not fall back to legacy consent.
            guard let data = try? Data(contentsOf: url),
                  let permission = try? JSONDecoder().decode(MeetingResearchPermission.self, from: data),
                  permission.version == 1, permission.allowed else { return nil }
            return permission.provider
        }
        guard meeting.aiMode.maySendTranscriptToCloud, meeting.privacySettings.allowsCloudIntelligence else { return nil }
        return meeting.intelligenceConfiguration?.cloudProvider
    }
}

extension MeetingSessionStore {
    /// Atomic sidecar replacement under the same per-meeting transaction lock.
    /// Never creates a directory or resurrects a deleted meeting.
    func setResearchPermission(meetingID: String, provider: MeetingCloudProviderSnapshot?) throws {
        try withManifestTransaction(meetingID: meetingID) {
            let meeting = try load(meetingID: meetingID)
            guard provider == nil || MeetingResearchPermissionPolicy.eligible(meeting) else {
                throw CloudRequestAuthorizationError.meetingConsentRequired
            }
            let permission = MeetingResearchPermission(allowed: provider != nil, provider: provider, changedAt: Date())
            let url = meetingDirectory(for: meetingID).appendingPathComponent("research-permission.json")
            try JSONEncoder().encode(permission).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NotificationCenter.default.post(name: Self.manifestDidChangeNotification, object: nil,
                userInfo: [Self.changedMeetingIDUserInfoKey: meetingID])
        }
    }
}

enum MeetingAIChoices {
    static func permissionMode(research: Bool, cleanup: MeetingAIMode) -> MeetingAIMode {
        research || cleanup == .cloudOptIn ? .cloudOptIn : cleanup
    }
}
