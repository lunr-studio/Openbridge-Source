# Openbridge

**Local AI, your control.**

Speak, capture the thought, and keep working. Openbridge turns speech into useful text on your Mac: an email draft, a research note, a meeting transcript, or the documentation you have been putting off writing.

Useful AI should work for you on the computer you already own. Openbridge brings open speech and language models into everyday Mac workflows, so local dictation and transcription do not need a cloud subscription or an upload of your recordings. You choose what to capture, where the text goes, and whether to use optional cloud features.

This repository gives you the application source, its Python engine, tests, and build instructions to run it yourself, understand how it works, and help improve it. Openbridge is an evolving project; review the text it produces before using it.

[Get started](#get-started) · [Find your way around](#find-your-way-around-the-code) · [Contribute](#contribute) · [Privacy](docs/PRIVACY_STORAGE_NETWORKING.md)

## What you can do

- **Write by speaking.** Dictate into Mac text fields for emails, notes, issue descriptions, documentation, and everyday writing. Use snippets and a custom dictionary for words and phrases you use often.
- **Capture meetings.** Record and transcribe locally, revisit the original transcript, and copy or export the result. Optional cleanup creates a separate revision so the original remains available.
- **Turn media into text.** Transcribe audio and video files, or fetch supported media URLs and transcribe them locally.
- **Work with your words.** Use local language models for cleanup and selected-text transformations. Optional provider integrations add cloud cleanup and questions about meeting transcripts when explicitly configured and authorized.
- **Build on it.** Explore a native Swift app, an inspectable Python engine, and synthetic fixtures you can use to develop and test your own improvements.

Openbridge is for writers, researchers, developers, clinicians, and anyone who wants less friction between a thought and a useful piece of writing.

## Why local first?

Modern Apple Silicon Macs can run capable speech and language models directly. Openbridge makes that capability useful where you already work, while keeping capture and transcription on your Mac. Models are downloaded separately; once installed, local file transcription and dictation do not require a cloud transcription service.

You stay in control of the processing choices. Optional cloud cleanup and research send authorized text to your selected provider and may incur that provider's charges. Model downloads, requested media downloads, and those cloud actions use the network. See [privacy, storage, and networking](docs/PRIVACY_STORAGE_NETWORKING.md) for the full data flow.

## Get started

### 1. Prepare your Mac

The source targets **Apple Silicon**, **macOS 14 or newer**, **Swift 6 / Xcode 16 or newer**, and **Python 3.14**. FFmpeg handles media conversion. The complete native app runs on macOS; Python checks also run on Linux in CI.

Install Apple's command-line developer tools if needed:

```bash
xcode-select --install
```

With [Homebrew](https://brew.sh/) installed, install Python and FFmpeg:

```bash
brew install python@3.14 ffmpeg
```

Check the tools before continuing:

```bash
swift --version
python3.14 --version
ffmpeg -version
```

Swift should report version 6 or newer and Python should report 3.14. Allow disk space and time for the speech and optional language-model downloads. The [development guide](docs/DEVELOPMENT_GUIDE.md) covers toolchain setup and troubleshooting.

### 2. Clone and install dependencies

```bash
git clone https://github.com/lunr-studio/Openbridge-Source.git
cd Openbridge-Source
python3.14 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-lock.txt
```

The virtual environment (`.venv`) keeps this project's Python packages separate from the rest of your Mac. The lock file records package versions and hashes so pip can verify the downloads.

### 3. Check the build and run the app

```bash
make test
make app-run
```

`make test` runs Python checks, Debug and optimized Release builds, and the Swift test suites. Success means the command finishes with passing tests and no build errors; optional provider probes are reported separately. `make app-run` then launches the native app and supplies the virtual environment's Python to its engine. You do not need Apple distribution credentials.

### 4. Make your first transcript

1. In the app, open **Settings → Models & performance**. Install the selected speech model and check that it is ready. The default is Parakeet; Whisper is also available. The initial download needs internet access.
2. Open **Transcribe → Files → Choose file**. Select the synthetic sample at `evals/fixtures/cloud/v1/sync_today.wav` in your checkout, or a short audio file of your own.
3. Choose **Transcribe file**. When the text appears, use **Copy** or **Save As**.

That exercises the app, Python engine, and a real local speech model together. File transcription does not require microphone or keyboard-access permissions.

To try voice typing, follow the app's prompts for **Microphone**, **Accessibility**, and **Input Monitoring**, then return and choose **Check again**. Click a blank text field, press **Right Option**, speak a short phrase, and press **Right Option** again. macOS permissions belong to a particular app or process; permissions for an installed copy may not carry over to a source run. See the [Mac setup guide](docs/setup/NEW_MAC_SETUP_GUIDE.md) if access needs attention.

### When you come back

From the repository directory:

```bash
source .venv/bin/activate
make app-run
```

Reinstall dependencies when the lock file changes, and run `make test` before submitting a change.

## Find your way around the code

The app has two main parts. **Swift** handles the Mac experience: windows, recording, permissions, shortcuts, and paste. **Python** runs speech recognition, media conversion, and local text-model tasks. They communicate through a JSON command-line interface, which lets you investigate the engine separately from the UI.

| Start here | What you will find |
| --- | --- |
| [Sources/OpenBridgeApp/](Sources/OpenBridgeApp/) | Native app, capture, shortcuts, paste, meeting workflows, and local stores |
| [Sources/OpenBridgeUI/](Sources/OpenBridgeUI/) | Shared UI components, typography, and meeting/research presentation |
| [openbridge_engine/](openbridge_engine/) | Speech models, media processing, model management, and text transformations |
| [engine_cli.py](engine_cli.py) → [openbridge_engine/cli.py](openbridge_engine/cli.py) | The JSON interface used by Swift, also usable from a terminal |
| [Tests/OpenBridgeAppTests/](Tests/OpenBridgeAppTests/) | Swift behavior and regression tests |
| [Tests/](Tests/), [tests/](tests/), [scripts/tests/](scripts/tests/) | Python engine and tooling tests; both capitalizations are intentional |
| [evals/fixtures/](evals/fixtures/) | Synthetic samples and evaluation contracts |
| [Package.swift](Package.swift), [Makefile](Makefile) | Swift targets and everyday development commands |
| [requirements.txt](requirements.txt), [requirements-lock.txt](requirements-lock.txt) | Direct Python dependencies and the reproducible environment |
| [docs/](docs/README.md) | Architecture, setup, privacy, design, and reference guides |

For a first code-reading session, follow [OpenBridgeApp.swift](Sources/OpenBridgeApp/OpenBridgeApp.swift) → [AppState.swift](Sources/OpenBridgeApp/AppState.swift) → [EngineService.swift](Sources/OpenBridgeApp/EngineService.swift) → [engine_cli.py](engine_cli.py). This shows how a user action reaches the engine and returns a result. Keep standard output machine-readable JSON; diagnostic logs belong on standard error.

The displayed product name is **Openbridge**. Existing paths, Swift targets, and API identifiers such as `OpenBridgeApp` keep their exact spelling so builds and integrations continue to work.

### Useful development commands

Run these from the repository root, with `.venv` activated:

| Command | Purpose |
| --- | --- |
| `make help` | List the available development commands |
| `make app-build` | Compile the native app without launching it |
| `make app-build-release` | Compile the optimized native app |
| `make python-test` | Run engine and tooling tests |
| `make swift-test` | Run Swift source tests |
| `make test` | Run the complete source check suite |
| `python engine_cli.py --help` | Explore the engine's terminal interface |
| `python engine_cli.py doctor` | Inspect dependencies and installed models; output is JSON |
| `python scripts/check_public_source.py --history` | Check locally available Git history for excluded filenames |

For the engine alone, after installing a speech model:

```bash
python engine_cli.py transcribe-audio --audio-path evals/fixtures/cloud/v1/sync_today.wav
```

### Read next

- [Development guide](docs/DEVELOPMENT_GUIDE.md): toolchains, commands, dependencies, and common setup problems.
- [Implemented architecture and data flow](docs/ARCHITECTURE_AND_DATA_FLOW.md): how Swift, Python, storage, and processing fit together. The root Cloud design documents describe proposed work separately.
- [Privacy and networking](docs/PRIVACY_STORAGE_NETWORKING.md): what stays local and what optional actions send to providers.
- [Design system](DESIGN.md): product identity and native UI conventions.
- [Model and asset provenance](docs/governance/ASSET_AND_MODEL_PROVENANCE.md): model sources, licences, and bundled assets.
- [Documentation index](docs/README.md): the wider reference library.

## Contribute

Useful contributions include clearer onboarding, reproducible bug reports, better recognition workflows, accessibility improvements, and focused fixes. Start with [CONTRIBUTING.md](CONTRIBUTING.md), search the [issues](https://github.com/lunr-studio/Openbridge-Source/issues), and open a focused pull request with the checks you ran. Use synthetic examples rather than personal recordings or transcripts.

Please report suspected vulnerabilities privately using [SECURITY.md](SECURITY.md), and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Source and licence

This is the application-source repository: code, tests, resources, and contributor documentation. Local builds are generated on your Mac. Official installers, signing and distribution, and the marketing website are maintained separately; built apps, DMGs, model weights, and secrets do not belong in Git.

Project-authored source and documentation use the [Apache License 2.0](LICENSE). Third-party dependencies and model weights have their own terms; names, marks, and other reserved brand assets are covered in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the [asset policy](docs/governance/TRADEMARK_AND_ASSET_POLICY.md).
