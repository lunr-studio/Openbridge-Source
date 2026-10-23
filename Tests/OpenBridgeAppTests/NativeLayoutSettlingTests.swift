import AppKit
import Foundation
import Testing

/// Shared by the native component render tests. This is not app runtime code.
@MainActor
func settleNativeLayout(_ view: NSView, ticks: Int = 5) async throws {
    view.layoutSubtreeIfNeeded()
    for _ in 0..<ticks {
        // Spinning RunLoop here processes AppKit events but retains the Swift
        // MainActor executor. Async transcription/research tests then cannot
        // advance until an entire render gallery finishes. Suspending releases
        // the executor while preserving the same layout settling intervals.
        try await Task.sleep(for: .milliseconds(20))
        view.layoutSubtreeIfNeeded()
    }
}

@Suite(.serialized) @MainActor struct NativeLayoutSettlingTests {
    @Test func layoutSettlingLetsQueuedMainActorWorkRun() async throws {
        var progressed = false
        let work = Task { @MainActor in progressed = true }
        defer { work.cancel() }
        try await settleNativeLayout(NSView(), ticks: 5)
        #expect(progressed, "Rendering must yield the MainActor to transcription and research test tasks")
        await work.value
    }

    @Test func cancelledLayoutSettlingStopsPromptly() async {
        let work = Task { @MainActor in
            try await settleNativeLayout(NSView(), ticks: 50)
        }
        work.cancel()
        do {
            try await work.value
            Issue.record("Cancelled layout settling must throw")
        } catch is CancellationError {
            // Expected: a cancelled test must not continue rendering a gallery.
        } catch {
            Issue.record("Unexpected layout settling error: \(error)")
        }
    }
}
