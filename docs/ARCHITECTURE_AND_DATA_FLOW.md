# Architecture and Data Flow

This file describes existing Swift/Python implementation. The canonical proposed
Cloud path is [root ARCHITECTURE.md](../ARCHITECTURE.md); its shared storage,
completion receipts and remote MCP are not implemented by the foundation PR.

OpenBridge has two source components: a native Swift macOS app and a Python engine.

```text
microphone or media
        |
        v
Swift app ---- JSON over stdin/stdout ---- Python engine
   |                                        |
macOS UI, permissions,              MLX speech models,
hotkeys, paste, local stores        correction, FFmpeg/yt-dlp
        |                                        |
        +--------------- local result -----------+
```

## Swift app

`Sources/OpenBridgeApp/` owns:

- menu-bar and settings interfaces
- microphone capture and activity state
- macOS permission guidance
- global shortcuts and paste coordination
- local history, snippets, preferences, and custom dictionary
- durable meeting manifests and derived transcript cleanup revisions
- starting and monitoring the Python child process

`AppState.swift` is the main coordinator. `EngineService.swift` owns the process boundary. `Models.swift` and `openbridge_engine/config.py` must agree on public model identifiers.

## Python engine

`openbridge_engine/` owns:

- MLX Whisper and Parakeet transcription
- Gemma-based optional cleanup and command transforms
- audio/media normalization
- model readiness and download checks
- machine-readable command responses

`engine_cli.py` is the Swift-facing entry point. Standard output is a JSON protocol, so diagnostic logs belong on standard error.

## Main flows

### Dictation

1. Swift records temporary audio.
2. Swift launches the engine with the chosen model and audio path.
3. The engine transcribes locally and optionally applies local correction.
4. Swift pastes or exposes the result and updates local history according to the user’s setting.
5. Temporary audio is deleted.

### Command mode

1. Swift reads selected text using Accessibility or a guarded clipboard fallback.
2. The engine transcribes the spoken instruction.
3. A local model transforms the selected text.
4. Swift replaces the selection or provides a safe manual fallback.

### Media transcription

1. The user chooses a local file or URL.
2. FFmpeg normalizes local media; yt-dlp may fetch user-requested URL media.
3. The engine transcribes chunks locally.
4. The result is returned to the app.

### Post-meeting transcript cleanup

1. Swift finalizes the meeting and preserves its canonical typed segments.
2. A separate durable cleanup job snapshots the meeting's explicitly selected
   local Gemma or authorized cloud provider, and starts only after completion.
3. Local Gemma receives final segments over standard input and runs batches of
   eight in an OS-level network-denial sandbox. Explicit cloud cleanup uses the
   selected BYOK provider boundary; failure never switches provider/model.
4. Swift durably appends ID-aligned result chunks to a derived revision.
5. Only a complete one-to-one result becomes active; failures leave the
   completed meeting and original transcript unchanged.

## Storage and network boundaries

User preferences and app data are stored under the user’s Library directories. Model weights are downloaded to local upstream caches and are not in this repository.

Capture/transcription remain local. Existing opt-in BYOK cleanup/research and
user-authorized web research add separately consented network paths alongside
model downloads and user-requested media. They do not authorize the proposed
hosted shared-library upload. See [privacy boundaries](PRIVACY_STORAGE_NETWORKING.md).

## Extension rules

- Add model identifiers in the Python configuration and Swift selection model together.
- Preserve the JSON process contract and keep stdout machine-readable.
- Add or update tests for storage schema, compatibility, and deterministic transforms.
- Update licence/provenance records whenever a dependency or model changes.

## Source build

Use `make test` to compile and test the source and `make app-run` to run it. This architecture has no public packaging, signing, distribution, website, or deployment component.
