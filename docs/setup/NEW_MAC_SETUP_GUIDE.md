# Clean-Mac Contributor Exercise

This exercise proves that a new contributor can clone, compile, test, run, and change OpenBridge without signing credentials.

## Before you begin

Use a clean Apple Silicon Mac account with:

- macOS 14 or newer
- Xcode 16
- Homebrew, or equivalent installations of Python 3.14 and FFmpeg
- no OpenBridge signing certificate, notarization credentials, or private repository files

Install the open tools if needed:

```bash
brew install python@3.14 ffmpeg
```

Confirm them:

```bash
uname -m
swift --version
python3.14 --version
ffmpeg -version
```

`uname -m` should print `arm64`.

## Clone and prepare

```bash
git clone https://github.com/lunr-studio/OpenBridge-Source.git
cd OpenBridge-Source
python3.14 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-lock.txt
```

## Compile and test

```bash
make test
```

Record the exact commit:

```bash
git rev-parse HEAD
```

The exercise passes when Python checks, Swift compilation, and all source tests succeed.

## Run

```bash
make app-run
```

Confirm the app opens, the menu-bar item appears, Help loads, and the app displays understandable guidance for any required macOS permissions. A first model selection may download weights from its upstream provider.

## Make one contributor-style change

1. Create a branch: `git switch -c docs/clean-mac-proof`
2. Correct a small documentation sentence.
3. Run `make test` again.
4. Inspect `git diff --check`.
5. Restore the sentence or keep the branch as evidence for the source-readiness issue.

This small change is important: cloning proves read access, while editing and retesting proves that the contributor workflow is understandable and repeatable.

## Evidence

Record:

- Mac model, macOS version, Swift version, and Python version
- source commit
- dependency-install result
- `make test` result
- app-launch result
- the small change and retest result
- any undocumented step or failure

Do not include credentials, private paths, real transcripts, or sensitive user data.
