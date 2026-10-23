# Development Guide

This guide covers the public source-development path. It does not require or describe Apple distribution credentials.

## Toolchain

| Tool | Supported baseline | Check |
| --- | --- | --- |
| macOS | 14 or newer on Apple Silicon | `sw_vers` and `uname -m` |
| Swift | 6.0 / Xcode 16 | `swift --version` |
| Python | 3.14 | `python3.14 --version` |
| FFmpeg | available on `PATH` | `ffmpeg -version` |

The Swift app is macOS-specific. Python syntax and unit tests also run on Ubuntu in CI.

## First setup

The system Python is not the project toolchain. Install Python 3.14 and FFmpeg via Homebrew first:

```bash
brew install python@3.14 ffmpeg
```

Then clone and set up:

```bash
git clone https://github.com/lunr-studio/Openbridge-Source.git
cd Openbridge-Source
python3.14 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-lock.txt
make test
```

A virtual environment isolates this repository’s Python packages from the rest of your computer. Activate it again with `source .venv/bin/activate` whenever you return to the project.

## Compile and run

```bash
make app-build
make app-run
```

`make app-run` passes `.venv/bin/python` to the Swift process when that file exists. This matters because the app launches the Python engine as a child process; using a different Python can make the app compile correctly but fail at runtime.

On first use, macOS may request microphone, Accessibility, and Input Monitoring permissions. Model providers may also be contacted to download the model selected in the app.

## Test

```bash
make test
```

The command runs:

1. Python syntax checks
2. Python unit tests
3. `swift build`
4. an optimized Release build
5. the SwiftPM XCTest and Swift Testing suites, plus script tests

A successful command exits with code zero and reports passing test counts. Optional real-provider probes can remain explicitly skipped; they are not proof of real service behavior. Native tests need a normal macOS session: a restrictive sandbox can block process-memory measurement or GPU access. Record that setup limitation rather than weakening the tests.

Before opening a pull request, also launch the app and exercise the behaviour you changed.

## Dependency inputs

- `requirements.txt` names the direct Python packages.
- `requirements-lock.txt` records the hash-locked environment used by the documented setup. Pip checks each downloaded package against its recorded hashes.
- `make setup` is a convenience command for direct dependencies; use the explicit locked install above when reproducing source-release evidence.
- `Package.swift` declares the native app target and currently has no external Swift packages.
- ML model identifiers and their terms are recorded in `docs/governance/ASSET_AND_MODEL_PROVENANCE.md`.

Changing any dependency or model identifier should include an updated licence/provenance review.

## Common problems

### `swift` or the macOS SDK is missing

Install Xcode 16, accept its licence, select it with `xcode-select`, and rerun `swift --version`.

### Python imports fail

Activate `.venv`, confirm `which python` points inside the repository, then rerun the dependency install.

### FFmpeg is not found

Install FFmpeg with your package manager or set `OPENBRIDGE_FFMPEG_PATH` to an executable you obtained under its applicable licence.

### The app starts but the engine is unavailable

Run `make app-run` from an activated virtual environment. Do not launch `swift run` with a Python interpreter that lacks the packages in `requirements.txt`.

## Repository boundary

The repository accepts source-development tooling only. Official application packaging, signing, notarization, upload, distribution, website, and deployment operations are intentionally maintained elsewhere.

## Source publication check

```bash
python scripts/check_public_source.py
python scripts/check_public_source.py --history
```

The first command checks tracked filenames. The second also checks every tree in
locally available Git history; fetch the required branch/tag/PR refs before a
publication audit. Both must exit zero. This is a filename guard, not a secret,
licensing, private-data or GitHub Actions-artifact audit. Website code and all
current/old built DMGs remain excluded. Files generated for local builds stay
ignored; never add them to Git.
