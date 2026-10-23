import Foundation
import Testing
@testable import OpenBridgeApp

@Suite(.serialized) struct MeetingCleanupSettingsTests {

    // MARK: - Toggle defaults

    @Test func toggleDefaultsToOff() throws {
        // Use a unique key so we don't collide with real defaults
        let key = MeetingCleanupSettings.toggleKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(MeetingCleanupSettings.isCleanupEnabled == false)
    }

    @Test func togglePersistsWhenSet() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }

        MeetingCleanupSettings.setCleanupEnabled(true)
        #expect(MeetingCleanupSettings.isCleanupEnabled == true)

        MeetingCleanupSettings.setCleanupEnabled(false)
        #expect(MeetingCleanupSettings.isCleanupEnabled == false)
    }

    // MARK: - canStartCleanup guards

    @Test func cleanupNeverStartsWhenToggleIsOff() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(false)

        let manifest = MeetingManifest(
            meetingID: "test",
            title: "Test",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: "test", sequence: 0,
                text: "valid", isFinal: true
            )]
        )

        #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == false)
    }

    @Test func cleanupNeverStartsDuringRecording() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        for state in [MeetingSessionState.recording, .setup, .transcribingLive, .finalizing] {
            let manifest = MeetingManifest(
                meetingID: "test-\(state.rawValue)",
                title: "Test",
                state: state,
                segments: [MeetingTranscriptSegment(
                    id: "seg-0", meetingID: "test-\(state.rawValue)", sequence: 0,
                    text: "valid", isFinal: true
                )]
            )
            #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == false,
                    "Cleanup must not start in state \(state.rawValue)")
        }
    }

    @Test func cleanupStartsOnlyForCompletedMeetings() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        let incompleteStates: [MeetingSessionState] = [
            .setup,
            .recording,
            .stopped,
            .interrupted,
            .exported,
            .captured,
            .transcribingLive,
            .finalizing,
            .failed,
            .recoveryNeeded,
        ]

        for state in incompleteStates {
            let manifest = MeetingManifest(
                meetingID: "test-\(state.rawValue)",
                title: "Test",
                state: state,
                segments: [MeetingTranscriptSegment(
                    id: "seg-0", meetingID: "test-\(state.rawValue)", sequence: 0,
                    text: "valid", isFinal: true
                )]
            )

            #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == false,
                    "Cleanup must require a completed meeting, not \(state.rawValue)")
        }
    }

    @Test func cleanupStartsWhenToggleOnCompletedAndHasFinalSegment() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        let manifest = MeetingManifest(
            meetingID: "test",
            title: "Test",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: "test", sequence: 0,
                text: "valid transcript", isFinal: true
            )]
        )

        #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == true)
    }

    @Test func cleanupDoesNotStartWithoutFinalSegment() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        let manifest = MeetingManifest(
            meetingID: "test",
            title: "Test",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: "test", sequence: 0,
                text: "partial", isFinal: false
            )]
        )

        #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == false)
    }

    @Test func cleanupDoesNotStartWithEmptySegments() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        let manifest = MeetingManifest(
            meetingID: "test",
            title: "Test",
            state: .completed,
            segments: []
        )

        #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == false)
    }

    @Test func cleanupDoesNotStartWhenLocalIntelligenceIsDisabled() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        let manifest = MeetingManifest(
            meetingID: "test",
            title: "Test",
            state: .completed,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: "test", sequence: 0,
                text: "valid transcript", isFinal: true
            )],
            privacySettings: MeetingPrivacySettings(allowsLocalIntelligence: false)
        )

        #expect(MeetingCleanupSettings.canStartCleanup(for: manifest) == false)
    }

    // MARK: - Production post-Stop plan (the lunr-studio/Openbridge-Beta#321 gate)

    @Test func postStopCleanupPlanRequiresToggleOn() throws {
        // lunr-studio/Openbridge-Beta#321 (AC1/AC6): the remembered toggle is the master gate. With the
        // toggle Off (the default), cleanup never runs regardless of the
        // selected mode or a completed meeting.
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let manifest = MeetingManifest(
            meetingID: "plan",
            title: "Plan",
            state: .completed,
            aiMode: .localOnly,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: "plan", sequence: 0,
                text: "valid", isFinal: true
            )]
        )

        MeetingCleanupSettings.setCleanupEnabled(false)
        #expect(MeetingPostStopCleanupPlan.shouldRun(mode: .careful, manifest: manifest) == false)
        #expect(MeetingPostStopCleanupPlan.shouldRun(mode: .fast, manifest: manifest) == false)

        MeetingCleanupSettings.setCleanupEnabled(true)
        #expect(MeetingPostStopCleanupPlan.shouldRun(mode: .careful, manifest: manifest) == true)
    }

    @Test func postStopCleanupPlanStillGatesOnModeAndEligibility() throws {
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        MeetingCleanupSettings.setCleanupEnabled(true)

        let manifest = MeetingManifest(
            meetingID: "plan2",
            title: "Plan2",
            state: .completed,
            aiMode: .localOnly,
            segments: [MeetingTranscriptSegment(
                id: "seg-0", meetingID: "plan2", sequence: 0,
                text: "valid", isFinal: true
            )]
        )
        // Mode Off still blocks even with the toggle On.
        #expect(MeetingPostStopCleanupPlan.shouldRun(mode: .off, manifest: manifest) == false)
        // Transcription-only AI mode (per-meeting consent) still blocks.
        var consentBlocked = manifest
        consentBlocked.aiMode = .transcriptionOnly
        #expect(MeetingPostStopCleanupPlan.shouldRun(mode: .careful, manifest: consentBlocked) == false)
    }

    @Test func modeChangeSynchronizesMasterToggle() throws {
        // lunr-studio/Openbridge-Beta#321 wave-4 (3886250999): the cleanup-mode
        // picker and the master toggle are ONE intent - changing the mode
        // updates the persisted toggle so the start-panel control never shows
        // On while the plan gate rejects every meeting.
        let key = MeetingCleanupSettings.toggleKey
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // A local mode enables the toggle; .off withdraws intent.
        MeetingCleanupSettings.syncFromCleanupMode(.careful)
        #expect(MeetingCleanupSettings.isCleanupEnabled == true)
        MeetingCleanupSettings.syncFromCleanupMode(.fast)
        #expect(MeetingCleanupSettings.isCleanupEnabled == true)
        MeetingCleanupSettings.syncFromCleanupMode(.off)
        #expect(MeetingCleanupSettings.isCleanupEnabled == false)
    }

    // MARK: - Review states

    @Test func allReviewStatesHaveUniqueDisplayNames() throws {
        let names = MeetingCleanupReviewState.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func allReviewStatesHaveNonEmptyStatusText() throws {
        for state in MeetingCleanupReviewState.allCases {
            #expect(!state.statusText.isEmpty,
                    "State \(state.rawValue) has empty status text")
        }
    }

    @Test func completedStatesShowRevisionSwitch() throws {
        #expect(MeetingCleanupReviewState.completedCleanedDefault.showsRevisionSwitch)
        #expect(MeetingCleanupReviewState.completedOriginalView.showsRevisionSwitch)
    }

    @Test func failedStatesAllowRetry() throws {
        #expect(MeetingCleanupReviewState.failed.allowsRetry)
        #expect(MeetingCleanupReviewState.retryAvailable.allowsRetry)
    }

    @Test func queuedAndRunningShowProgress() throws {
        #expect(MeetingCleanupReviewState.queued.showsProgress)
        #expect(MeetingCleanupReviewState.running.showsProgress)
    }
}
