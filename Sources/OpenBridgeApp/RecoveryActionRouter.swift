import Foundation

// MARK: - #219 Recovery Action Router
//
// The production boundary for recovery actions. Every action is routed
// through `evaluateRecovery` + the guarded store paths — the unconditional
// `finalizeMeeting` shortcut is never used for recovery.
//
// Contract (fault-injection proven, MeetingRecoveryFaultInjectionTests):
// - finalize: completes ONLY when a transcript exists; a transcriptless
//   meeting is refused (audio stays recoverable for retry).
// - providerFailure: isolated — recorded as an event, NEVER as a meeting
//   failure; capture/transcription/cleanup states are untouched.

enum RecoveryAction: Equatable {
    case finalize
    case providerFailure(String)
}

enum RecoveryOutcome: Equatable {
    case completed
    case refusedNoTranscript
    case retrySucceeded(persistedCount: Int)
    case retryFailed(String)
    case isolatedProviderFailure
}

enum RecoveryActionRouter {
    static func route(
        action: RecoveryAction,
        meetingID: String,
        store: MeetingSessionStore
    ) throws -> RecoveryOutcome {
        switch action {
        case .finalize:
            if try store.load(meetingID: meetingID).captureMode == .online {
                return try store.completeOnlineRecovery(meetingID: meetingID) ? .completed : .refusedNoTranscript
            }
            // Wave-9 (3876794393): a neverStoreTranscript meeting stores no
            // text by design, so the transcript-validity verdict is not the
            // right criterion - if every preserved audio chunk has been
            // retried successfully, finalize can complete it.
            if let manifest = try? store.load(meetingID: meetingID),
               manifest.retentionPolicy == .neverStoreTranscript,
               neverStoreFullyRetried(meetingID: meetingID, store: store) {
                // Wave-11 (3876962658): the store's transcript-presence guard
                // would throw for this intentionally-empty manifest - bypass it
                // via the marker-verified path (markers cover every audio file).
                try store.completeRecoveredMeeting(
                    meetingID: meetingID, allowsEmptyTranscript: true
                )
                return .completed
            }
            // Verdict first: is there a VALID transcript to complete?
            let assessment = try store.evaluateRecovery(meetingID: meetingID)
            guard hasValidTranscript(assessment, store: store, meetingID: meetingID) else {
                // Audio-only, empty, or invalid-transcript meeting: NEVER
                // Completed. The audio stays on disk for retry.
                return .refusedNoTranscript
            }
            try store.completeRecoveredMeeting(meetingID: meetingID)
            return .completed

        case .providerFailure(let reason):
            // #219: a provider failure is an ISOLATED condition. Record it
            // as a traceable event but never touch the meeting's state —
            // capture/transcription/cleanup must never read as failed
            // because a provider was unreachable.
            try store.recordRecoveryEvent(
                meetingID: meetingID, kind: "PROVIDER_FAILURE", detail: reason
            )
            return .isolatedProviderFailure
        }
    }

    /// #219: the retry path ADVERTISED after a finalize refusal — transcribe
    /// ONLY the missing segments from the preserved audio, via the caller's
    /// transcriber (production engine configuration). Async by design: it
    /// drives the ordered, persist-only runner per index.
    ///
    /// Review-wave hardening (waves 2–3):
    /// - Audio indices are PARSED FROM FILENAMES (`segment_NNNN.wav`) — the
    ///   directory is never assumed contiguous (a lost `segment_0000.wav`
    ///   with `segment_0001.wav` present retries index 1, not 0..<count).
    /// - Coverage counts only CANONICALLY VALID persisted segments — a
    ///   foreign/non-final/whitespace entry never masks its WAV.
    /// - Each missing index runs as its OWN single-index pass — noncontiguous
    ///   holes never re-transcribe interior persisted indices (idempotent).
    /// - Success is verified against the DURABLE transcript after the run —
    ///   a range completion with no valid persisted transcript reports
    ///   failure, never a false "you can finalize".
    static func retryTranscription(
        meetingID: String,
        store: MeetingSessionStore,
        transcriber: MeetingTranscriber
    ) async -> RecoveryOutcome {
        if (try? store.load(meetingID: meetingID).captureMode) == .online {
            switch await transcriber.retryOnlineArtifacts(meetingID: meetingID) {
            case .completed(let count): return .retrySucceeded(persistedCount: count)
            case .failed(_, let message): return .retryFailed(message)
            }
        }
        // Parse preserved audio indices from disk (source of truth after a
        // crash; never assume contiguity).
        let audioDir = store.audioDirectory(for: meetingID)
        let diskFiles: [String]
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
            diskFiles = contents
                .filter { $0.hasPrefix("segment_") && $0.hasSuffix(".wav") }
                .sorted()
        } else {
            diskFiles = []
        }
        let diskIndices = diskFiles.compactMap { name -> Int? in
            let stem = name.dropFirst("segment_".count).dropLast(".wav".count)
            return Int(stem)
        }.sorted()
        guard !diskIndices.isEmpty else {
            return .retryFailed("No preserved audio to transcribe.")
        }

        // Coverage = indices of CANONICALLY VALID persisted segments only.
        let manifest = (try? store.load(meetingID: meetingID))
            ?? MeetingManifest(meetingID: meetingID, title: "")
        let validIndices = Set(
            manifest.segments
                .filter { Self.segmentIsValid($0, meetingID: meetingID) }
                .map(\.sequence)
        )
        // A missing index = on disk, not validly persisted.
        let missing = diskIndices.filter { !validIndices.contains($0) }

        var transcribed = 0
        var firstFailure: String?
        if missing.isEmpty {
            // Wave-6 (3849215436): the all-covered path still MUST run
            // reconciliation + whole-manifest validation — a foreign or
            // duplicate entry at a covered index would otherwise report a
            // false success forever (finalize keeps refusing while retry
            // keeps succeeding).
            transcribed = validIndices.count
        } else {
            // Each missing index runs as its own pass: interior persisted
            // indices are never re-transcribed (no duplicate sequences), and
            // a gap cannot be skipped.
            for index in missing {
                let result = await transcriber.transcribeSegmentRange(
                    meetingID: meetingID, fromIndex: index, toIndex: index + 1
                )
                switch result {
                case .completed:
                    transcribed += 1
                case .failed(_, let message):
                    if firstFailure == nil { firstFailure = message }
                }
            }
        }

        // Reconcile the manifest BEFORE verification: replace canonically
        // invalid entries at the relevant sequences (all disk indices on the
        // already-covered path — the corrupt-duplicate case), and write the
        // discovered on-disk audio filenames back so replay can see them.
        // Wave-6 (3849160827): a failed reconcile write is NOT swallowed —
        // claiming success without the audio-filename write-back would be a
        // false success (replay still sees no audio).
        let sequencesToReconcile = missing.isEmpty ? diskIndices : missing
        do {
            try store.reconcileRecoveredMeeting(
                meetingID: meetingID,
                retriedSequences: sequencesToReconcile,
                segmentIsValid: { Self.segmentIsValid($0, meetingID: meetingID) },
                discoveredAudioFilenames: diskFiles
            )
        } catch {
            return .retryFailed(
                firstFailure ?? "Recovery could not save the manifest — audio preserved."
            )
        }

        // Wave-7 (3876716832): a neverStoreTranscript meeting NEVER writes
        // text durably, so durable-coverage verification is not the right
        // success criterion - every chunk transcribed without engine failure
        // is success (the policy stores no text by design).
        let neverStore = (manifest.retentionPolicy == .neverStoreTranscript)

        // Verify the DURABLE manifest passes the SAME whole-manifest canonical
        // validation finalization uses — invalid persisted entries at retried
        // indices are REPLACED before this check (below), and the surviving
        // set must be entirely valid with unique IDs/sequences. A silent-WAV
        // hole or a leftover invalid entry reports failure, never a false
        // "you can finalize".
        let reloaded = (try? store.load(meetingID: meetingID))
            ?? manifest
        let nowValidIndices = Set(
            reloaded.segments
                .filter { Self.segmentIsValid($0, meetingID: meetingID) }
                .map(\.sequence)
        )
        let uncovered = diskIndices.filter { !nowValidIndices.contains($0) }
        if !uncovered.isEmpty, !neverStore {
            return .retryFailed(
                firstFailure
                    ?? "Retry produced no usable transcript for segment\(uncovered.count == 1 ? "" : "s") "
                        + "\(uncovered.map { String($0) }.joined(separator: ", ")) — audio preserved."
            )
        }
        // Whole-manifest canonical validation (the finalize predicate): one
        // invalid or duplicate entry anywhere still refuses success.
        // Wave-8 (3876762097): for neverStoreTranscript the manifest is
        // intentionally EMPTY (no text stored by design) - the whole-manifest
        // guard must also be skipped, otherwise retry always returns
        // .retryFailed and the meeting can never finalize.
        if !neverStore {
            guard Self.manifestPassesFinalizeValidation(
                reloaded, store: store, meetingID: meetingID
            ) else {
                return .retryFailed(
                    "Retry left invalid transcript entries — audio preserved; the corrupt entries need manual review."
                )
            }
        }
        if neverStore {
            // Wave-10 (3876862718): never-store success must be PROVEN by the
            // durable per-index retry markers the finalize route requires. A
            // whitespace engine result follows the empty-text persistence path
            // (no marker) and a marker save error is swallowed, yet both would
            // otherwise reach .retrySucceeded while Finalize immediately
            // refuses the intentionally-empty manifest.
            let reloadedMarkers = (try? store.load(meetingID: meetingID)) ?? manifest
            let markedIndices = Set(reloadedMarkers.events.compactMap { event -> Int? in
                guard event.hasPrefix("NEVER_STORE_RETRY_OK:") else { return nil }
                return Int(event.dropFirst("NEVER_STORE_RETRY_OK:".count))
            })
            let everyIndexMarked = diskIndices.allSatisfy { markedIndices.contains($0) }
            guard everyIndexMarked else {
                return .retryFailed(
                    firstFailure
                        ?? "Retry left preserved audio without a durable never-store marker — audio preserved."
                )
            }
        }
        if let firstFailure {
            return .retryFailed(firstFailure)
        }
        return .retrySucceeded(persistedCount: transcribed)
    }

    /// Whole-manifest validation identical to the finalize path: every typed
    /// segment valid + unique IDs/sequences (or no typed segments with a
    /// non-whitespace legacy span).
    static func manifestPassesFinalizeValidation(
        _ manifest: MeetingManifest,
        store: MeetingSessionStore,
        meetingID: String
    ) -> Bool {
        if !manifest.segments.isEmpty {
            let allValid = manifest.segments.allSatisfy {
                segmentIsValid($0, meetingID: meetingID)
            }
            let ids = Set(manifest.segments.map(\.id))
            let sequences = Set(manifest.segments.map(\.sequence))
            return allValid
                && ids.count == manifest.segments.count
                && sequences.count == manifest.segments.count
        }
        return manifest.transcriptSpans.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Canonical per-segment validity (shared by coverage and completion
    /// checks): owned by this meeting, final, non-empty after trimming.
    static func segmentIsValid(
        _ segment: MeetingTranscriptSegment,
        meetingID: String
    ) -> Bool {
        segment.meetingID == meetingID && segment.isFinal
            && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Production entry point for provider-failure isolation from services
    /// that have no meeting context (ObservatoryCoordinator, answer
    /// services). No-ops when no meeting is active — the failure is
    /// rail-local and must not touch any meeting.
    @MainActor
    static func recordProviderFailure(_ detail: String) {
        guard let appState = AppState.shared,
              let meetingID = appState.activeMeetingID else { return }
        let store = MeetingSessionStore()
        _ = try? store.recordRecoveryEvent(
            meetingID: meetingID, kind: "PROVIDER_FAILURE", detail: detail
        )
    }

    /// #219 (P1): `hasPartialTranscript` alone is too lenient — a manifest
    /// holding only whitespace spans, empty/foreign/non-final segments must
    /// NOT be completable. Applies the store's canonical validity rules:
    /// EVERY typed segment must be final, owned by this meeting, non-empty
    /// after trimming, and IDs + sequences must be UNIQUE. A single valid
    /// segment cannot smuggle a corrupt manifest through; one invalid
    /// segment anywhere refuses completion (whitespace spans: ALL must be
    /// non-whitespace).
    /// Wave-9 (3876794393): a neverStoreTranscript meeting is fully
    /// recoverable when every preserved audio chunk has been retried
    /// successfully. The retry path records per-index success in the
    /// manifest's recovery events (no transcript text is stored).
    private static func neverStoreFullyRetried(
        meetingID: String,
        store: MeetingSessionStore
    ) -> Bool {
        let audioDir = store.audioDirectory(for: meetingID)
        let diskFiles: [String]
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
            diskFiles = contents.filter { $0.hasPrefix("segment_") && $0.hasSuffix(".wav") }
        } else {
            diskFiles = []
        }
        guard !diskFiles.isEmpty else { return false }
        let diskIndices = Set(diskFiles.compactMap { name -> Int? in
            let stem = name.dropFirst("segment_".count).dropLast(".wav".count)
            return Int(stem)
        })
        // A retry success event is recorded per chunk when the policy is
        // never-store; require one for every disk index.
        guard let manifest = try? store.load(meetingID: meetingID) else { return false }
        let retried = Set(manifest.events.compactMap { event -> Int? in
            guard event.contains("NEVER_STORE_RETRY_OK") else { return nil }
            let parts = event.split(separator: ":")
            guard parts.count >= 2, let idx = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return idx
        })
        return diskIndices.allSatisfy { retried.contains($0) }
    }

    private static func hasValidTranscript(
        _ assessment: MeetingRecoveryAssessment,
        store: MeetingSessionStore,
        meetingID: String
    ) -> Bool {
        if let segments = try? store.fetchSegments(meetingID: meetingID),
           !segments.isEmpty {
            // Every typed segment must be individually valid.
            let allValid = segments.allSatisfy {
                $0.meetingID == meetingID && $0.isFinal
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // IDs and sequences must be unique (canonical validator rule).
            let ids = Set(segments.map(\.id))
            let sequences = Set(segments.map(\.sequence))
            let unique = ids.count == segments.count && sequences.count == segments.count
            if allValid && unique { return true }
            // Fall through to legacy-span check only when no valid typed set
            // exists — a corrupt typed set cannot be completed via spans.
            return false
        }
        // Legacy spans: any non-whitespace span qualifies.
        if let manifest = try? store.load(meetingID: meetingID) {
            return manifest.transcriptSpans.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return false
    }
}
