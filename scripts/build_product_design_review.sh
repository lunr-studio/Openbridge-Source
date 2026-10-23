#!/bin/bash
# Build a local native design review app. Never installs, notarizes, or publishes.
set -euo pipefail
checkout="$(cd "$(dirname "$0")/.." && pwd)"
runtime_source="${1:-/Applications/OpenBridge.app}"
review_root="$checkout/.local-evidence/product-refresh"
review_app="$review_root/OpenBridge Design.app"
test -d "$runtime_source/Contents/Resources/python-runtime"
test -d "$runtime_source/Contents/Frameworks/Python.framework"
test -x "$runtime_source/Contents/MacOS/openbridge-python"
mkdir -p "$review_root"
(cd "$checkout" && swift build -c release -j 4)
release_dir="$(cd "$checkout" && swift build -c release --show-bin-path)"
mkdir -p "$review_app/Contents/MacOS" "$review_app/Contents/Resources"
ditto "$checkout/Resources/OpenBridgeIcon.icns" "$review_app/Contents/Resources/OpenBridgeIcon.icns"
ditto "$release_dir/OpenBridgeApp" "$review_app/Contents/MacOS/OpenBridgeApp"
for resource_bundle in "$release_dir"/*.bundle; do
    test -d "$resource_bundle" || continue
    ditto "$resource_bundle" "$review_app/Contents/Resources/$(basename "$resource_bundle")"
done
# Reuse installed interpreter libraries only; Python application source is current.
if [[ ! -d "$review_app/Contents/Resources/python-runtime" ]]; then
    cp -cR "$runtime_source/Contents/Resources/python-runtime" "$review_app/Contents/Resources/python-runtime"
fi
if [[ ! -d "$review_app/Contents/Frameworks" ]]; then
    cp -cR "$runtime_source/Contents/Frameworks" "$review_app/Contents/Frameworks"
fi
for helper in openbridge-python ffmpeg; do
    ditto "$runtime_source/Contents/MacOS/$helper" "$review_app/Contents/MacOS/$helper"
done
mkdir -p "$review_app/Contents/Resources/python"
ditto "$checkout/openbridge_engine" "$review_app/Contents/Resources/python/openbridge_engine"
ditto "$checkout/engine_cli.py" "$review_app/Contents/Resources/python/engine_cli.py"
for file in vocab_corrections.json; do
    if [[ -f "$checkout/$file" ]]; then ditto "$checkout/$file" "$review_app/Contents/Resources/python/$file"; fi
done
python3 - "$review_app" "$checkout" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys
app, root = map(Path, sys.argv[1:])
review_data = Path.home()/'Library/Caches/dev.openbridge.product-review/isolated-home'
review_data.mkdir(parents=True, exist_ok=True)
source = subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip()
plist = dict(CFBundleName='OpenBridge Design', CFBundleDisplayName='OpenBridge Design',
    CFBundleIdentifier='dev.openbridge.product-review', CFBundleExecutable='OpenBridgeApp',
    CFBundlePackageType='APPL', CFBundleIconFile='OpenBridgeIcon', CFBundleVersion='1', CFBundleShortVersionString='local-design',
    NSHighResolutionCapable=True, LSMinimumSystemVersion='14.0', OpenBridgeIsolatedDesignReview=True,
    NSMicrophoneUsageDescription='Voice typing and meetings use your microphone when you choose to record.',
    OpenBridgeSourceCommit=source, OpenBridgeBuildPurpose='Local unaccepted native design review',
    OpenBridgeReviewDataRoot=str(review_data),
    LSEnvironment=dict(CFFIXED_USER_HOME=str(review_data),
        OPENBRIDGE_MODEL_DIR=str(review_data/'models'),
        OPENBRIDGE_LLM_CACHE_DIR=str(review_data/'llm-cache'),
        HF_HOME=str(review_data/'huggingface'), HF_HUB_DISABLE_TELEMETRY='1',
        OPENBRIDGE_ENGINE_SCRIPT=str(app/'Contents/Resources/python/engine_cli.py'),
        OPENBRIDGE_ENGINE_PYTHON='', PYTHONPATH='', PYTHONHOME=''))
with (app/'Contents/Info.plist').open('wb') as file: plistlib.dump(plist, file)
files = ['Sources','openbridge_engine','Package.swift','engine_cli.py']
inputs = {}
for relative in files:
    path = root/relative
    for file in sorted(path.rglob('*')) if path.is_dir() else [path]:
        if file.is_file() and '__pycache__' not in file.parts:
            inputs[str(file.relative_to(root))] = hashlib.sha256(file.read_bytes()).hexdigest()
(app.parent/'review-build-inputs.json').write_text(json.dumps({'source':source, 'inputs':inputs}, indent=2)+'\n')
PY
codesign --force --sign - "$review_app"
codesign --verify --deep --strict "$review_app"
touch "$review_app"
# Refresh only this local app's metadata, including its launch environment.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$review_app"
printf 'Local native review app: %s\n' "$review_app"
printf 'Uses isolated review data. No install, notarization, or distribution performed.\n'
