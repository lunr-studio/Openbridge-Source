PYTHON ?= python3
VENV_PYTHON := .venv/bin/python
APP_ENGINE_PYTHON ?= $(if $(wildcard $(VENV_PYTHON)),$(VENV_PYTHON),$(PYTHON))

.PHONY: help setup app-build app-build-release app-run python-syntax python-test swift-test swift-check mac-dev-proof mac-dev-proof-test test

help:
	@echo "OpenBridge source-development commands"
	@echo "  make setup       Create .venv and install Python dependencies"
	@echo "  make app-build   Compile the Swift app source"
	@echo "  make app-build-release Compile the optimized Swift app source"
	@echo "  make app-run     Run the app from source"
	@echo "  make python-test Run Python engine tests"
	@echo "  make swift-test  Run source-level Swift tests"
	@echo "  make swift-check Compile the app and run source-level Swift checks"
	@echo "  make mac-dev-proof Run Franklin's approved-Mac source proof for exact HEAD"
	@echo "  make mac-dev-proof-test Test the proof gate without claiming real Mac proof"
	@echo "  make test        Run the complete source test suite"

setup:
	$(PYTHON) -m venv .venv
	$(VENV_PYTHON) -m pip install --upgrade pip
	$(VENV_PYTHON) -m pip install -r requirements.txt

app-build:
	swift build

app-build-release:
	swift build -c release

# Extra launch arguments: make app-run ARGS="-observatoryTestMode"
ARGS ?=
app-run:
	OPENBRIDGE_ENGINE_PYTHON="$(APP_ENGINE_PYTHON)" swift run OpenBridgeApp $(ARGS)

python-syntax:
	"$(APP_ENGINE_PYTHON)" -m py_compile openbridge_engine/*.py dictate.py engine_cli.py transcribe_video.py

python-test:
	"$(APP_ENGINE_PYTHON)" scripts/run_engine_tests.py
	"$(APP_ENGINE_PYTHON)" -m unittest discover -s scripts/tests -p "test_*.py" -v

swift-test:
	swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks

# Source-level Swift checks. Both debug and release configurations compile so
# production-only conditional-compilation failures cannot pass the test gate.
# Real assertions live in the SwiftPM test target
# (`swift test`); the historical `swift Sources/... scripts/test_*.swift`
# invocations only printed output and could exit 0 without enforcing
# assertions, which produced false-positive passes. They were removed so
# `make test` genuinely reports pass/fail and visible test counts.
swift-check:
	$(MAKE) app-build
	$(MAKE) app-build-release
	$(MAKE) swift-test

mac-dev-proof:
	OPENBRIDGE_PROOF_MODE=developer_manual \
	OPENBRIDGE_EXPECTED_SHA="$${OPENBRIDGE_EXPECTED_SHA:-$$(git rev-parse HEAD)}" \
	./scripts/mac_dev_proof.sh

mac-dev-proof-test:
	"$(APP_ENGINE_PYTHON)" -m unittest discover -s scripts/tests -p "test_*.py" -v

test: python-syntax python-test swift-check
