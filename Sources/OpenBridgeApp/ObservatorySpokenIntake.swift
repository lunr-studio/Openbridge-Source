import Foundation
import OpenBridgeUI

/// #299/#309: live spoken intake — feeds final transcript segments to
/// the wake-phrase detector and routes detected invocations to the
/// shared Observatory coordinator after an explicit wake phrase.
@MainActor
final class ObservatorySpokenIntake {
    static let shared = ObservatorySpokenIntake()

    private(set) var detector: SpokenWakePhraseDetector
    private var expiryTask: Task<Void, Never>?
    private var generation = UUID()
    private let coordinator: () -> ObservatoryCoordinator?
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void

    init(detector: SpokenWakePhraseDetector = SpokenWakePhraseDetector(),
         coordinator: @escaping () -> ObservatoryCoordinator? = { AppState.sharedObservatoryForRail },
         isEnabled: @escaping () -> Bool = {
             ResearchObservatoryFeatureFlag.isEnabled && AppState.shared?.isResearchIndexing != true
         }, now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
         }) {
        self.detector = detector
        self.coordinator = coordinator
        self.isEnabled = isEnabled
        self.now = now
        self.sleep = sleep
    }

    /// Synchronous replacement prevents a delayed reset racing the next
    /// meeting. In-flight work on the old actor is discarded by generation.
    func reset() {
        generation = UUID()
        expiryTask?.cancel()
        expiryTask = nil
        detector = SpokenWakePhraseDetector()
    }

    func ingest(_ segment: MeetingTranscriptSegment) async {
        guard isEnabled() else { return }
        let token = generation
        let detector = detector
        let update = await detector.processUpdate(segment, now: now())
        // Wave-16 (3838384613): the detector suspension is exactly where a
        // Stop-boundary cancel can land; a cancelled tap must not submit.
        guard !Task.isCancelled, token == generation, isEnabled() else { return }
        coordinator()?.receiveSpokenUpdate(update)
        expiryTask?.cancel()
        guard let pending = update.pending else { expiryTask = nil; return }
        expiryTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(0, pending.deadline.timeIntervalSince(self.now()))
            do { try await self.sleep(delay) }
            catch { return }
            guard !Task.isCancelled, self.generation == token, self.isEnabled() else { return }
            guard let expired = await detector.expirePending(requestID: pending.invocation.requestID, now: self.now()) else { return }
            guard !Task.isCancelled, self.generation == token, self.isEnabled() else { return }
            self.coordinator()?.receiveSpokenUpdate(expired)
        }
    }
}
