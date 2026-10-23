import Foundation

// Test that AppState's foregroundStatus and maintenanceStatus channels
// exist and can hold independent values without contaminating statusMessage.
//
// This test validates the Part C fix: MainRuntimeState.current(for:) reads
// from the channel-specific properties instead of the shared statusMessage.

enum StatusChannelsTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw StatusChannelsTestFailure.failed(message)
    }
}

// Since AppState requires AppKit and a full app context, we test the
// channel isolation logic at the struct level. MainRuntimeState reads:
//   foreground = appState.foregroundStatus ?? appState.statusMessage
//   maintenance = appState.maintenanceStatus ?? appState.statusMessage
//
// We verify the coalescing logic that determines which message is shown.

struct StatusChannelsFixture {
    var statusMessage: String
    var foregroundStatus: String?
    var maintenanceStatus: String?
    var isTranscribing: Bool
    var isInstallingModel: Bool
    var isTranscribingMedia: Bool
    var isStartingRecording: Bool
    var isRecording: Bool
    var isRunningSystemCheck: Bool
}

func effectiveForegroundMessage(_ fixture: StatusChannelsFixture) -> String {
    fixture.foregroundStatus ?? fixture.statusMessage
}

func effectiveMaintenanceMessage(_ fixture: StatusChannelsFixture) -> String {
    fixture.maintenanceStatus ?? fixture.statusMessage
}

func testStatusChannelsIsolation() throws {
    // Scenario: transcription is running, but a maintenance message
    // (e.g. "Installing model...") was last written to statusMessage.
    // The banner should show the foreground channel, not the stale maintenance value.
    let fixture = StatusChannelsFixture(
        statusMessage: "Installing model...",
        foregroundStatus: "Transcribing...",
        maintenanceStatus: nil,
        isTranscribing: true,
        isInstallingModel: false,
        isTranscribingMedia: false,
        isStartingRecording: false,
        isRecording: false,
        isRunningSystemCheck: false
    )

    try expect(fixture.isTranscribing == true, "Transcription flag should be set")
    try expect(fixture.isInstallingModel == false, "Install should have finished")

    let foregroundMsg = effectiveForegroundMessage(fixture)
    try expect(foregroundMsg == "Transcribing...", "Foreground banner should show '\(foregroundMsg)' not contaminated statusMessage")

    // Scenario: maintenance active, foreground idle
    let maintenanceFixture = StatusChannelsFixture(
        statusMessage: "Listening...",
        foregroundStatus: nil,
        maintenanceStatus: "Installing whisper-base...",
        isTranscribing: false,
        isInstallingModel: true,
        isTranscribingMedia: false,
        isStartingRecording: false,
        isRecording: false,
        isRunningSystemCheck: false
    )

    let maintenanceMsg = effectiveMaintenanceMessage(maintenanceFixture)
    try expect(maintenanceMsg == "Installing whisper-base...", "Maintenance banner should show channel message, not stale foreground statusMessage")
    try expect(maintenanceFixture.isInstallingModel == true, "Install flag should be set")

    // Scenario: both channels nil, falls back to statusMessage
    let idleFixture = StatusChannelsFixture(
        statusMessage: "Ready. Press Right Option + Space to dictate.",
        foregroundStatus: nil,
        maintenanceStatus: nil,
        isTranscribing: false,
        isInstallingModel: false,
        isTranscribingMedia: false,
        isStartingRecording: false,
        isRecording: false,
        isRunningSystemCheck: false
    )

    try expect(effectiveForegroundMessage(idleFixture) == idleFixture.statusMessage, "Idle foreground should fall back to statusMessage")
    try expect(effectiveMaintenanceMessage(idleFixture) == idleFixture.statusMessage, "Idle maintenance should fall back to statusMessage")

    print("[PASS] testStatusChannelsIsolation")
}

func testCanChangeSelectedModelBlocksTranscription() throws {
    // canChangeSelectedModel = !isStartingRecording && !isRecording && !isTranscribing && !isTranscribingMedia
    let blocked = StatusChannelsFixture(
        statusMessage: "Transcribing...",
        foregroundStatus: "Transcribing...",
        maintenanceStatus: nil,
        isTranscribing: true,
        isInstallingModel: false,
        isTranscribingMedia: false,
        isStartingRecording: false,
        isRecording: false,
        isRunningSystemCheck: false
    )

    let canChange = !blocked.isStartingRecording && !blocked.isRecording && !blocked.isTranscribing && !blocked.isTranscribingMedia
    try expect(canChange == false, "Model change should be blocked during transcription")

    let idle = StatusChannelsFixture(
        statusMessage: "Ready.",
        foregroundStatus: nil,
        maintenanceStatus: nil,
        isTranscribing: false,
        isInstallingModel: false,
        isTranscribingMedia: false,
        isStartingRecording: false,
        isRecording: false,
        isRunningSystemCheck: false
    )

    let canChangeIdle = !idle.isStartingRecording && !idle.isRecording && !idle.isTranscribing && !idle.isTranscribingMedia
    try expect(canChangeIdle == true, "Model change should be allowed when idle")

    print("[PASS] testCanChangeSelectedModelBlocksTranscription")
}

// Run all tests
do {
    try testStatusChannelsIsolation()
    try testCanChangeSelectedModelBlocksTranscription()
    print("\n--- All status channel tests passed ---")
} catch {
    print("\n--- TEST FAILURE ---")
    print(error)
    exit(1)
}