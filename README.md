# OpenBridge

OpenBridge is a local-first macOS voice typing and transcription app. This repository contains the independently releasable source code for the native Swift app and its Python engine.

## Source-only boundary

This repository publishes source, tests, resources, licences, community files, and contributor documentation. It deliberately contains:

- no compiled app or disk image, including historical DMGs
- no code-signing or notarization automation
- no official packaging or upload pipeline
- no marketing website or deployment system
- no official download configuration or private release evidence

Contributors can compile, run, and test OpenBridge without Apple signing credentials. Official builds, if offered by Lunr Studio, are produced separately and are not a prerequisite for source publication.

## Requirements

- Apple Silicon Mac running macOS 14 or newer
- Xcode 16 or the matching Swift 6 command-line toolchain
- Python 3.14
- FFmpeg available on `PATH` for media transcription

Homebrew is one convenient way to install Python and FFmpeg:

```bash
brew install python@3.14 ffmpeg
```

## Set up

```bash
git clone https://github.com/lunr-studio/OpenBridge-Source.git
cd OpenBridge-Source
python3.14 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-lock.txt
make test
```

`make test` checks Python syntax, engine and script tests, Debug/optimized Release compilation, and the Swift XCTest/Swift Testing suites. Optional provider probes are reported separately.

## Run from source

With the virtual environment activated:

```bash
make app-run
```

The first use may download model weights from their upstream providers. Those weights are not stored in this repository and remain subject to their own licences and terms.

## Repository map

- `Sources/OpenBridgeApp/` — native macOS application
- `openbridge_engine/` — Python transcription and language-model engine
- `Resources/` — app configuration and original OpenBridge assets
- `Tests/`, `tests/`, and `scripts/tests/` — source tests
- `docs/` — architecture, privacy, setup, and governance documentation
- `requirements.txt` / `requirements-lock.txt` — Python dependency inputs

Read the [development guide](docs/DEVELOPMENT_GUIDE.md) for the contributor workflow and the [architecture guide](docs/ARCHITECTURE_AND_DATA_FLOW.md) for the Swift/Python boundary.

## Contributing and security

Contributions are welcome under [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Please report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Licence

Project-authored source and documentation are licensed under the [Apache License 2.0](LICENSE). Third-party dependencies, model weights, and reserved brand assets have separate terms described in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
