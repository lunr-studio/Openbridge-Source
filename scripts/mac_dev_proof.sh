#!/bin/sh

# Produce an auditable macOS source-development proof for one exact commit.
#
# This intentionally has two modes:
#   developer_manual - Franklin runs it in an interactive macOS login and
#                      explicitly confirms the visible launch smoke.
#   ci_automated     - the dedicated self-hosted runner proves only automated
#                      build/test and process-survival behavior. It must never
#                      claim that a person saw the UI.

set -u

APPROVED_RUNNER_LABEL="franklin-mac-mini"
APPROVED_DEVELOPER_ACCOUNT="franklin"
APPROVED_CI_ACCOUNT="openbridge-ci"
DEFAULT_APPROVAL_FILE="/Library/Application Support/OpenBridge/mac-mini-runner-label"
APPROVED_RUNTIME_ROOT="/Library/Application Support/OpenBridge/mac-proof-runtime"
APPROVED_PYTHON_BASE="/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14"
TRUSTED_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PARAKEET_MODEL_ID="parakeet-tdt-0.6b-v3-mlx-bf16"
PARAKEET_MODEL_REPOSITORY="sonic-speech/parakeet-tdt-0.6b-v3"
PARAKEET_MODEL_REVISION="55c316ecc6eca874d3aff6c5c711d37305159271"
PARAKEET_RUNTIME="parakeet_mlx"
GEMMA_MODEL_ID="mlx-community/gemma-3-4b-it-qat-4bit"
GEMMA_MODEL_REVISION="3d9ef289111449933c22761961f16a5df237ce2a"
GEMMA_RUNTIME="mlx"
NETWORK_SANDBOX_PROFILE="(version 1)(allow default)(deny network*)"
EXPECTED_WORKFLOW_REF="lunr-studio/Openbridge-Dev/.github/workflows/mac-mini-proof.yml@refs/heads/main"

PROOF_MODE="${OPENBRIDGE_PROOF_MODE:-}"
EXPECTED_SHA="${OPENBRIDGE_EXPECTED_SHA:-}"
RUNNER_LABELS="${OPENBRIDGE_RUNNER_LABELS:-}"
MANUAL_RESULT_INPUT="${OPENBRIDGE_MANUAL_RESULT:-}"
MANUAL_CONFIRMATION_INPUT="${OPENBRIDGE_MANUAL_CONFIRMATION:-}"
MANUAL_SCENARIO_INPUT="${OPENBRIDGE_MANUAL_SCENARIO_ID:-}"
TEST_MODE_INPUT="${OPENBRIDGE_PROOF_TESTING:-0}"
LAUNCH_SECONDS="${OPENBRIDGE_LAUNCH_SMOKE_SECONDS:-8}"
TARGET_REPOSITORY_INPUT="${OPENBRIDGE_TARGET_REPOSITORY:-}"
GITHUB_EVENT_NAME_INPUT="${OPENBRIDGE_GITHUB_EVENT_NAME:-}"
GITHUB_WORKFLOW_REF_INPUT="${OPENBRIDGE_GITHUB_WORKFLOW_REF:-}"
GITHUB_WORKFLOW_SHA_INPUT="${OPENBRIDGE_GITHUB_WORKFLOW_SHA:-}"
GITHUB_CONTROL_SHA_INPUT="${OPENBRIDGE_GITHUB_CONTROL_SHA:-}"
GITHUB_RUN_ID_INPUT="${OPENBRIDGE_GITHUB_RUN_ID:-}"
GITHUB_RUN_ATTEMPT_INPUT="${OPENBRIDGE_GITHUB_RUN_ATTEMPT:-}"
GITHUB_JOB_INPUT="${OPENBRIDGE_GITHUB_JOB:-}"
GITHUB_CHECK_RUN_ID_INPUT="${OPENBRIDGE_GITHUB_CHECK_RUN_ID:-}"
GITHUB_TARGET_AUTHORIZATION_INPUT="${OPENBRIDGE_GITHUB_TARGET_AUTHORIZATION:-}"
GITHUB_PULL_REQUEST_NUMBER_INPUT="${OPENBRIDGE_GITHUB_PULL_REQUEST_NUMBER:-}"
GITHUB_APPROVED_BY_INPUT="${OPENBRIDGE_GITHUB_APPROVED_BY:-}"

case "$TEST_MODE_INPUT" in
  0|1) ;;
  *)
    printf 'mac-dev-proof: OPENBRIDGE_PROOF_TESTING must be 0 or 1.\n' >&2
    exit 2
    ;;
esac
if [ "$TEST_MODE_INPUT" = "1" ] && [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
  printf 'mac-dev-proof: test-only host overrides are forbidden in GitHub Actions.\n' >&2
  exit 2
fi

if [ "$TEST_MODE_INPUT" = "0" ]; then
  # A proof is an integrity boundary. Do not let shell startup state redirect
  # Git, Make, Xcode, Swift, or Python to caller-selected code.
  PATH="$TRUSTED_SYSTEM_PATH"
  export PATH
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
  unset GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
  unset GIT_OPTIONAL_LOCKS GIT_LITERAL_PATHSPECS
  unset MAKEFLAGS MFLAGS MAKEOVERRIDES MAKEFILES GNUMAKEFLAGS
  unset PYTHON APP_ENGINE_PYTHON PYTHONHOME PYTHONPATH PYTHONSTARTUP
  unset PYTHONINSPECT PYTHONBREAKPOINT PYTHONWARNINGS PYTHONSAFEPATH
  unset DEVELOPER_DIR SDKROOT SWIFT_EXEC TOOLCHAINS
  unset CODESIGN_ALLOCATE OTHER_CODE_SIGN_FLAGS
  unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
  unset TMPDIR CDPATH ENV BASH_ENV ZDOTDIR
  PYTHONNOUSERSITE=1
  PYTHONDONTWRITEBYTECODE=1
  export PYTHONNOUSERSITE PYTHONDONTWRITEBYTECODE

  GIT_BIN="/usr/bin/git"
  MAKE_BIN="/usr/bin/make"
  SWIFT_BIN="/usr/bin/swift"
  CODESIGN_BIN="/usr/bin/codesign"
  OPEN_BIN="/usr/bin/open"
  ID_BIN="/usr/bin/id"
  UNAME_BIN="/usr/bin/uname"
  SW_VERS_BIN="/usr/bin/sw_vers"
  XCODEBUILD_BIN="/usr/bin/xcodebuild"
  SANDBOX_EXEC_BIN="/usr/bin/sandbox-exec"
  RECEIPT_PYTHON_BIN="/usr/bin/python3"
  DIRNAME_BIN="/usr/bin/dirname"
  STAT_BIN="/usr/bin/stat"
  ENV_BIN="/usr/bin/env"
  DATE_BIN="/bin/date"
  MKTEMP_BIN="/usr/bin/mktemp"
else
  resolve_test_tool() {
    command -v "$1" 2>/dev/null || {
      printf 'mac-dev-proof: test fixture tool is unavailable: %s\n' "$1" >&2
      exit 2
    }
  }

  GIT_BIN=$(resolve_test_tool git)
  MAKE_BIN=$(resolve_test_tool make)
  SWIFT_BIN=$(resolve_test_tool swift)
  CODESIGN_BIN=$(resolve_test_tool codesign)
  OPEN_BIN=$(resolve_test_tool open)
  ID_BIN=$(resolve_test_tool id)
  UNAME_BIN=$(resolve_test_tool uname)
  SW_VERS_BIN=$(resolve_test_tool sw_vers)
  XCODEBUILD_BIN=$(resolve_test_tool xcodebuild)
  SANDBOX_EXEC_BIN=$(resolve_test_tool sandbox-exec)
  RECEIPT_PYTHON_BIN=$(resolve_test_tool python3)
  DIRNAME_BIN=$(resolve_test_tool dirname)
  STAT_BIN=$(resolve_test_tool stat)
  ENV_BIN=$(resolve_test_tool env)
  DATE_BIN=$(resolve_test_tool date)
  MKTEMP_BIN=$(resolve_test_tool mktemp)
fi

SCRIPT_DIR=$(CDPATH= cd -- "$("$DIRNAME_BIN" -- "$0")" && pwd)
CONTROL_REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
if [ -n "$TARGET_REPOSITORY_INPUT" ]; then
  REPOSITORY_ROOT=$(CDPATH= cd -- "$TARGET_REPOSITORY_INPUT" 2>/dev/null && pwd) || {
    printf 'mac-dev-proof: OPENBRIDGE_TARGET_REPOSITORY is unavailable.\n' >&2
    exit 2
  }
else
  REPOSITORY_ROOT="$CONTROL_REPOSITORY_ROOT"
fi

generated_at_utc=""
account="unknown"
commit_sha=""
clean_worktree="false"
macos_version="not_collected"
architecture="not_collected"
xcode_version="not_collected"
xcode_build_version="not_collected"
swift_version="not_collected"
python_tests="not_run"
python_test_count=""
swift_debug_build="not_run"
swift_release_build="not_run"
swift_tests="not_run"
swift_test_count=""
parakeet_source_runtime="not_run"
parakeet_load_result="not_run"
parakeet_inference_result="not_run"
gemma_source_runtime="not_run"
gemma_inference_result="not_run"
local_model_network_isolation="not_run"
development_app_bundle="not_run"
automated_launch_survival="not_run"
manual_launch_status="not_run"
manual_tester=""
manual_confirmation=""
manual_scenario_id=""
overall_result="fail"
failure_reason="preflight_incomplete"
receipt_path=""
attestation_path=""
receipt_ready=0
temporary_root=""
app_pid=""
bundle_identifier=""
launched_with_launch_services=0
account_home=""
model_python=""
proof_cache_root=""
github_event_name=""
github_workflow_ref=""
github_workflow_sha=""
github_control_sha=""
github_run_id=""
github_run_attempt=""
github_job=""
github_check_run_id=""
github_target_authorization=""
github_pull_request_number=""
github_approved_by=""

say() {
  printf '%s\n' "$*"
}

fail() {
  failure_reason="$1"
  printf 'mac-dev-proof: %s\n' "$2" >&2
  exit 1
}

# Test mode intentionally calls fixture commands with the unittest's
# environment. A real proof starts build subprocesses from a small allowlist so
# variables such as MAKEFLAGS, PYTHONPATH, SDKROOT, compiler flags, or shell
# startup state cannot silently change what gets tested.
run_make() {
  if [ "$TEST_MODE_INPUT" = "1" ]; then
    "$MAKE_BIN" "$@"
  else
    "$ENV_BIN" -i \
      PATH="$TRUSTED_SYSTEM_PATH" \
      HOME="$account_home" \
      USER="$account" \
      LOGNAME="$account" \
      LANG=C \
      LC_ALL=C \
      PYTHON="$model_python" \
      APP_ENGINE_PYTHON="$model_python" \
      "$MAKE_BIN" "$@"
  fi
}

run_swift() {
  if [ "$TEST_MODE_INPUT" = "1" ]; then
    "$SWIFT_BIN" "$@"
  else
    "$ENV_BIN" -i \
      PATH="$TRUSTED_SYSTEM_PATH" \
      HOME="$account_home" \
      USER="$account" \
      LOGNAME="$account" \
      LANG=C \
      LC_ALL=C \
      "$SWIFT_BIN" "$@"
  fi
}

run_codesign() {
  if [ "$TEST_MODE_INPUT" = "1" ]; then
    "$CODESIGN_BIN" "$@"
  else
    "$ENV_BIN" -i \
      PATH="$TRUSTED_SYSTEM_PATH" \
      HOME="$account_home" \
      USER="$account" \
      LOGNAME="$account" \
      LANG=C \
      LC_ALL=C \
      "$CODESIGN_BIN" "$@"
  fi
}

proof_git() {
  if [ "$TEST_MODE_INPUT" = "1" ]; then
    "$GIT_BIN" "$@"
  else
    "$ENV_BIN" -i \
      PATH="$TRUSTED_SYSTEM_PATH" \
      HOME="$account_home" \
      USER="$account" \
      LOGNAME="$account" \
      LANG=C \
      LC_ALL=C \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_SYSTEM=/dev/null \
      GIT_ATTR_NOSYSTEM=1 \
      "$GIT_BIN" \
      -c core.fsmonitor=false \
      -c core.hooksPath=/dev/null \
      "$@"
  fi
}

cleanup() {
  if [ "$launched_with_launch_services" -eq 1 ] && [ -n "$bundle_identifier" ] && [ -x /usr/bin/osascript ]; then
    /usr/bin/osascript -e "tell application id \"$bundle_identifier\" to quit" >/dev/null 2>&1 || true
  fi

  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi

  if [ -n "$temporary_root" ] && [ -d "$temporary_root" ]; then
    chmod -R u+w "$temporary_root" 2>/dev/null || true
    rm -rf "$temporary_root"
  fi
}

write_receipt() {
  [ "$receipt_ready" -eq 1 ] || return 0

  RECEIPT_GENERATED_AT_UTC="$generated_at_utc" \
  RECEIPT_ACCOUNT="$account" \
  RECEIPT_APPROVED_RUNNER_LABEL="$APPROVED_RUNNER_LABEL" \
  RECEIPT_COMMIT_SHA="$commit_sha" \
  RECEIPT_CLEAN_WORKTREE="$clean_worktree" \
  RECEIPT_MACOS_VERSION="$macos_version" \
  RECEIPT_ARCHITECTURE="$architecture" \
  RECEIPT_XCODE_VERSION="$xcode_version" \
  RECEIPT_XCODE_BUILD_VERSION="$xcode_build_version" \
  RECEIPT_SWIFT_VERSION="$swift_version" \
  RECEIPT_PYTHON_TESTS="$python_tests" \
  RECEIPT_PYTHON_TEST_COUNT="$python_test_count" \
  RECEIPT_SWIFT_DEBUG_BUILD="$swift_debug_build" \
  RECEIPT_SWIFT_RELEASE_BUILD="$swift_release_build" \
  RECEIPT_SWIFT_TESTS="$swift_tests" \
  RECEIPT_SWIFT_TEST_COUNT="$swift_test_count" \
  RECEIPT_PARAKEET_SOURCE_RUNTIME="$parakeet_source_runtime" \
  RECEIPT_PARAKEET_LOAD_RESULT="$parakeet_load_result" \
  RECEIPT_PARAKEET_INFERENCE_RESULT="$parakeet_inference_result" \
  RECEIPT_GEMMA_SOURCE_RUNTIME="$gemma_source_runtime" \
  RECEIPT_GEMMA_INFERENCE_RESULT="$gemma_inference_result" \
  RECEIPT_LOCAL_MODEL_NETWORK_ISOLATION="$local_model_network_isolation" \
  RECEIPT_PARAKEET_MODEL_ID="$PARAKEET_MODEL_ID" \
  RECEIPT_PARAKEET_MODEL_REVISION="$PARAKEET_MODEL_REVISION" \
  RECEIPT_PARAKEET_RUNTIME="$PARAKEET_RUNTIME" \
  RECEIPT_GEMMA_MODEL_ID="$GEMMA_MODEL_ID" \
  RECEIPT_GEMMA_MODEL_REVISION="$GEMMA_MODEL_REVISION" \
  RECEIPT_GEMMA_RUNTIME="$GEMMA_RUNTIME" \
  RECEIPT_DEVELOPMENT_APP_BUNDLE="$development_app_bundle" \
  RECEIPT_AUTOMATED_LAUNCH_SURVIVAL="$automated_launch_survival" \
  RECEIPT_MANUAL_LAUNCH_STATUS="$manual_launch_status" \
  RECEIPT_MANUAL_TESTER="$manual_tester" \
  RECEIPT_MANUAL_CONFIRMATION="$manual_confirmation" \
  RECEIPT_MANUAL_SCENARIO_ID="$manual_scenario_id" \
  RECEIPT_GITHUB_EVENT_NAME="$github_event_name" \
  RECEIPT_GITHUB_WORKFLOW_REF="$github_workflow_ref" \
  RECEIPT_GITHUB_WORKFLOW_SHA="$github_workflow_sha" \
  RECEIPT_GITHUB_CONTROL_SHA="$github_control_sha" \
  RECEIPT_GITHUB_RUN_ID="$github_run_id" \
  RECEIPT_GITHUB_RUN_ATTEMPT="$github_run_attempt" \
  RECEIPT_GITHUB_JOB="$github_job" \
  RECEIPT_GITHUB_CHECK_RUN_ID="$github_check_run_id" \
  RECEIPT_GITHUB_TARGET_AUTHORIZATION="$github_target_authorization" \
  RECEIPT_GITHUB_PULL_REQUEST_NUMBER="$github_pull_request_number" \
  RECEIPT_GITHUB_APPROVED_BY="$github_approved_by" \
  RECEIPT_PROOF_TYPE="$PROOF_MODE" \
  RECEIPT_TEST_MODE="$TEST_MODE_INPUT" \
  RECEIPT_LAUNCH_SECONDS="$LAUNCH_SECONDS" \
  RECEIPT_OVERALL_RESULT="$overall_result" \
  RECEIPT_FAILURE_REASON="$failure_reason" \
  "$RECEIPT_PYTHON_BIN" - "$receipt_path" <<'PY'
import json
import os
import pathlib
import sys


def required(name: str) -> str:
    value = os.environ[name]
    if any(ord(character) < 32 for character in value):
        raise SystemExit(f"unsafe control character in receipt field: {name}")
    return value


def nullable(name: str):
    value = required(name)
    return value if value else None


def nullable_int(name: str):
    value = required(name)
    return int(value) if value else None


receipt = {
    "schema_version": 1,
    "proof_type": required("RECEIPT_PROOF_TYPE"),
    "test_mode": required("RECEIPT_TEST_MODE") == "1",
    "generated_at_utc": required("RECEIPT_GENERATED_AT_UTC"),
    "account": required("RECEIPT_ACCOUNT"),
    "approved_runner_label": required("RECEIPT_APPROVED_RUNNER_LABEL"),
    "commit_sha": required("RECEIPT_COMMIT_SHA"),
    "clean_worktree": required("RECEIPT_CLEAN_WORKTREE") == "true",
    "macos_version": required("RECEIPT_MACOS_VERSION"),
    "architecture": required("RECEIPT_ARCHITECTURE"),
    "xcode_version": required("RECEIPT_XCODE_VERSION"),
    "xcode_build_version": required("RECEIPT_XCODE_BUILD_VERSION"),
    "swift_version": required("RECEIPT_SWIFT_VERSION"),
    "app_bundle_kind": "source_only_ad_hoc",
    "automated_launch_seconds": int(required("RECEIPT_LAUNCH_SECONDS")),
    "test_counts": {
        "python_tests": nullable_int("RECEIPT_PYTHON_TEST_COUNT"),
        "swift_tests": nullable_int("RECEIPT_SWIFT_TEST_COUNT"),
    },
    "source_runtime_models": {
        "scope": "source_runtime",
        "network_isolation_result": required("RECEIPT_LOCAL_MODEL_NETWORK_ISOLATION"),
        "parakeet": {
            "model_id": required("RECEIPT_PARAKEET_MODEL_ID"),
            "revision": required("RECEIPT_PARAKEET_MODEL_REVISION"),
            "runtime": required("RECEIPT_PARAKEET_RUNTIME"),
            "load_result": required("RECEIPT_PARAKEET_LOAD_RESULT"),
            "inference_result": required("RECEIPT_PARAKEET_INFERENCE_RESULT"),
        },
        "gemma": {
            "model_id": required("RECEIPT_GEMMA_MODEL_ID"),
            "revision": required("RECEIPT_GEMMA_MODEL_REVISION"),
            "runtime": required("RECEIPT_GEMMA_RUNTIME"),
            "inference_result": required("RECEIPT_GEMMA_INFERENCE_RESULT"),
        },
    },
    "checks": {
        "python_tests": required("RECEIPT_PYTHON_TESTS"),
        "swift_debug_build": required("RECEIPT_SWIFT_DEBUG_BUILD"),
        "swift_release_build": required("RECEIPT_SWIFT_RELEASE_BUILD"),
        "swift_tests": required("RECEIPT_SWIFT_TESTS"),
        "parakeet_source_runtime": required("RECEIPT_PARAKEET_SOURCE_RUNTIME"),
        "gemma_source_runtime": required("RECEIPT_GEMMA_SOURCE_RUNTIME"),
        "local_model_network_isolation": required("RECEIPT_LOCAL_MODEL_NETWORK_ISOLATION"),
        "development_app_bundle": required("RECEIPT_DEVELOPMENT_APP_BUNDLE"),
        "automated_launch_survival": required("RECEIPT_AUTOMATED_LAUNCH_SURVIVAL"),
        "manual_launch_smoke": required("RECEIPT_MANUAL_LAUNCH_STATUS"),
    },
    "manual_launch_smoke": {
        "result": required("RECEIPT_MANUAL_LAUNCH_STATUS"),
        "tester": nullable("RECEIPT_MANUAL_TESTER"),
        "confirmation": nullable("RECEIPT_MANUAL_CONFIRMATION"),
        "scenario_id": nullable("RECEIPT_MANUAL_SCENARIO_ID"),
        "required_observations": [
            "menu_bar_item_visible",
            "primary_ui_opened",
            "application_responsive",
            "primary_user_journey_passed",
        ],
    },
    "github_provenance": {
        "event_name": nullable("RECEIPT_GITHUB_EVENT_NAME"),
        "workflow_ref": nullable("RECEIPT_GITHUB_WORKFLOW_REF"),
        "workflow_sha": nullable("RECEIPT_GITHUB_WORKFLOW_SHA"),
        "control_commit_sha": nullable("RECEIPT_GITHUB_CONTROL_SHA"),
        "run_id": nullable_int("RECEIPT_GITHUB_RUN_ID"),
        "run_attempt": nullable_int("RECEIPT_GITHUB_RUN_ATTEMPT"),
        "job": nullable("RECEIPT_GITHUB_JOB"),
        "check_run_id": nullable_int("RECEIPT_GITHUB_CHECK_RUN_ID"),
        "target_authorization": nullable("RECEIPT_GITHUB_TARGET_AUTHORIZATION"),
        "pull_request_number": nullable_int("RECEIPT_GITHUB_PULL_REQUEST_NUMBER"),
        "approved_by": nullable("RECEIPT_GITHUB_APPROVED_BY"),
    },
    "overall_result": required("RECEIPT_OVERALL_RESULT"),
    "failure_reason": nullable("RECEIPT_FAILURE_REASON"),
}

destination = pathlib.Path(sys.argv[1])
destination.parent.mkdir(parents=True, exist_ok=True)
temporary = destination.with_suffix(destination.suffix + ".tmp")
temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(destination)
PY
}

write_manual_attestation() {
  [ "$PROOF_MODE" = "developer_manual" ] || return 0

  "$RECEIPT_PYTHON_BIN" - "$receipt_path" "$attestation_path" "$commit_sha" "$TEST_MODE_INPUT" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys


receipt_path = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
expected_sha = sys.argv[3]
expected_test_mode = sys.argv[4] == "1"
receipt_bytes = receipt_path.read_bytes()
receipt = json.loads(receipt_bytes)
expected_checks = {
    "python_tests",
    "swift_debug_build",
    "swift_release_build",
    "swift_tests",
    "parakeet_source_runtime",
    "gemma_source_runtime",
    "local_model_network_isolation",
    "development_app_bundle",
    "automated_launch_survival",
    "manual_launch_smoke",
}
expected_provenance = {
    "event_name",
    "workflow_ref",
    "workflow_sha",
    "control_commit_sha",
    "run_id",
    "run_attempt",
    "job",
    "check_run_id",
    "target_authorization",
    "pull_request_number",
    "approved_by",
}
checks = receipt.get("checks", {})
provenance = receipt.get("github_provenance", {})
manual = receipt.get("manual_launch_smoke", {})
if (
    receipt.get("proof_type") != "developer_manual"
    or receipt.get("test_mode") is not expected_test_mode
    or receipt.get("account") != "franklin"
    or receipt.get("commit_sha") != expected_sha
    or receipt.get("clean_worktree") is not True
    or receipt.get("overall_result") != "pass"
    or receipt.get("failure_reason") is not None
    or set(checks) != expected_checks
    or any(value != "pass" for value in checks.values())
    or manual.get("tester") != "franklin"
    or manual.get("confirmation") != "observed:" + expected_sha
    or set(provenance) != expected_provenance
    or any(value is not None for value in provenance.values())
):
    raise SystemExit("manual receipt is not eligible for attestation")

payload = {
    "schema_version": 1,
    "attestation_type": "franklin_mac_dev_proof",
    "target_sha": expected_sha,
    "receipt_sha256": hashlib.sha256(receipt_bytes).hexdigest(),
    "scenario_id": manual["scenario_id"],
    "receipt_base64": base64.b64encode(receipt_bytes).decode("ascii"),
}
body = (
    "<!-- openbridge-franklin-mac-dev-proof-v1 -->\n"
    "```json\n" + json.dumps(payload, indent=2, sort_keys=True) + "\n```\n"
)
temporary = destination.with_suffix(destination.suffix + ".tmp")
temporary.write_text(body, encoding="utf-8")
temporary.replace(destination)
PY
}

finish() {
  exit_code=$?
  trap - EXIT HUP INT TERM

  cleanup

  if [ "$exit_code" -eq 0 ]; then
    overall_result="pass"
    failure_reason=""
  fi

  if ! write_receipt; then
    printf 'mac-dev-proof: could not write the sanitized receipt.\n' >&2
    exit_code=1
  elif [ "$receipt_ready" -eq 1 ]; then
    say "Sanitized receipt: ${receipt_path#$REPOSITORY_ROOT/}"
    if [ "$exit_code" -eq 0 ] && [ "$PROOF_MODE" = "developer_manual" ]; then
      if write_manual_attestation; then
        say "Ready-to-post Franklin attestation: ${attestation_path#$REPOSITORY_ROOT/}"
      else
        overall_result="fail"
        failure_reason="manual_attestation_write_failed"
        write_receipt || true
        printf 'mac-dev-proof: could not write the digest-bound Franklin attestation.\n' >&2
        exit_code=1
      fi
    fi
  fi

  exit "$exit_code"
}

trap finish EXIT
trap 'failure_reason="interrupted"; exit 130' HUP INT TERM

case "$PROOF_MODE" in
  developer_manual|ci_automated) ;;
  *)
    printf 'mac-dev-proof: set OPENBRIDGE_PROOF_MODE to developer_manual or ci_automated.\n' >&2
    exit 2
    ;;
esac

if [ "$PROOF_MODE" = "developer_manual" ] && [ -n "$TARGET_REPOSITORY_INPUT" ]; then
  printf 'mac-dev-proof: OPENBRIDGE_TARGET_REPOSITORY is reserved for the controlled CI proof.\n' >&2
  exit 2
fi
if [ "$PROOF_MODE" = "ci_automated" ] && [ -z "$TARGET_REPOSITORY_INPUT" ]; then
  printf 'mac-dev-proof: controlled CI proof requires OPENBRIDGE_TARGET_REPOSITORY.\n' >&2
  exit 2
fi

case "$EXPECTED_SHA" in
  *[!0-9a-f]*|'')
    printf 'mac-dev-proof: OPENBRIDGE_EXPECTED_SHA must be an exact lowercase 40-character commit SHA.\n' >&2
    exit 2
    ;;
esac
if [ "${#EXPECTED_SHA}" -ne 40 ]; then
  printf 'mac-dev-proof: OPENBRIDGE_EXPECTED_SHA must be an exact lowercase 40-character commit SHA.\n' >&2
  exit 2
fi

case "$LAUNCH_SECONDS" in
  *[!0-9]*|'')
    printf 'mac-dev-proof: OPENBRIDGE_LAUNCH_SMOKE_SECONDS must be a whole number.\n' >&2
    exit 2
    ;;
esac
if [ "$LAUNCH_SECONDS" -gt 300 ]; then
  printf 'mac-dev-proof: OPENBRIDGE_LAUNCH_SMOKE_SECONDS must not exceed 300 seconds.\n' >&2
  exit 2
fi
if [ "$TEST_MODE_INPUT" = "0" ] && [ "$LAUNCH_SECONDS" -lt 5 ]; then
  printf 'mac-dev-proof: a real proof requires at least five seconds of launch survival.\n' >&2
  exit 2
fi

cd "$REPOSITORY_ROOT" || exit 2

for trusted_tool in \
  "$GIT_BIN" "$MAKE_BIN" "$SWIFT_BIN" "$CODESIGN_BIN" "$OPEN_BIN" \
  "$ID_BIN" "$UNAME_BIN" "$SW_VERS_BIN" "$XCODEBUILD_BIN" \
  "$SANDBOX_EXEC_BIN" "$RECEIPT_PYTHON_BIN" "$DIRNAME_BIN" "$STAT_BIN" \
  "$ENV_BIN" "$DATE_BIN" "$MKTEMP_BIN"
do
  [ -x "$trusted_tool" ] || fail "trusted_tool_missing" "a required fixed-path proof tool is unavailable."
done

account=$("$ID_BIN" -un 2>/dev/null) || fail "account_unavailable" "could not determine the macOS account."
if [ "$TEST_MODE_INPUT" = "1" ]; then
  account_home="${OPENBRIDGE_PROOF_TEST_ACCOUNT_HOME:-}"
  [ -d "$account_home" ] || fail "account_home_unavailable" "the test account-home fixture is unavailable."
else
  account_home="/Users/$account"
  [ -d "$account_home" ] || fail "account_home_unavailable" "the approved account home directory is unavailable."
  account_home_owner=$("$STAT_BIN" -f '%Su' "$account_home" 2>/dev/null) || fail "account_home_unavailable" "the approved account home could not be verified."
  [ "$account_home_owner" = "$account" ] || fail "account_home_owner_mismatch" "the approved account must own its home directory."
fi

commit_sha=$(proof_git rev-parse HEAD 2>/dev/null) || fail "git_revision_unavailable" "could not read the current Git commit."
if [ "$commit_sha" != "$EXPECTED_SHA" ]; then
  fail "commit_sha_mismatch" "HEAD does not match OPENBRIDGE_EXPECTED_SHA."
fi

case "$PROOF_MODE" in
  developer_manual)
    receipt_path="$REPOSITORY_ROOT/.build/mac-dev-proof/mac-dev-proof-$commit_sha.json"
    attestation_path="$REPOSITORY_ROOT/.build/mac-dev-proof/franklin-attestation-$commit_sha.md"
    ;;
  ci_automated)
    receipt_path="$REPOSITORY_ROOT/.build/mac-mini-proof/mac-mini-proof-$commit_sha.json"
    ;;
esac
receipt_ready=1
generated_at_utc=$("$DATE_BIN" -u '+%Y-%m-%dT%H:%M:%SZ') || fail "utc_clock_unavailable" "could not read the UTC clock."

git_status=$(proof_git status --porcelain --untracked-files=normal 2>/dev/null) || fail "git_status_unavailable" "could not verify the working-tree state."
if [ -n "$git_status" ]; then
  fail "worktree_not_clean" "the worktree must be clean before proof begins."
fi
clean_worktree="true"

case "$PROOF_MODE" in
  developer_manual)
    if [ "$account" != "$APPROVED_DEVELOPER_ACCOUNT" ]; then
      fail "unapproved_developer_account" "developer proof must run as the franklin account."
    fi
    case "$MANUAL_SCENARIO_INPUT" in
      ''|*[!a-z0-9._-]*)
        fail "manual_scenario_invalid" "set OPENBRIDGE_MANUAL_SCENARIO_ID to a lowercase journey identifier using only a-z, 0-9, dot, underscore, or hyphen."
        ;;
    esac
    if [ "${#MANUAL_SCENARIO_INPUT}" -gt 64 ]; then
      fail "manual_scenario_invalid" "OPENBRIDGE_MANUAL_SCENARIO_ID must be at most 64 characters."
    fi
    manual_scenario_id="$MANUAL_SCENARIO_INPUT"
    ;;
  ci_automated)
    if [ "$account" != "$APPROVED_CI_ACCOUNT" ]; then
      fail "unapproved_ci_account" "CI proof must run as the openbridge-ci account."
    fi
    if [ -n "$MANUAL_RESULT_INPUT" ] || [ -n "$MANUAL_CONFIRMATION_INPUT" ] || [ -n "$MANUAL_SCENARIO_INPUT" ]; then
      fail "manual_claim_forbidden_in_ci" "CI proof cannot accept or report manual launch evidence."
    fi
    manual_launch_status="not_applicable"

    if [ "$GITHUB_EVENT_NAME_INPUT" != "workflow_dispatch" ]; then
      fail "github_provenance_invalid" "CI proof requires the protected workflow_dispatch event."
    fi
    if [ "$GITHUB_WORKFLOW_REF_INPUT" != "$EXPECTED_WORKFLOW_REF" ]; then
      fail "github_provenance_invalid" "CI proof requires the protected main workflow reference."
    fi
    case "$GITHUB_WORKFLOW_SHA_INPUT" in
      *[!0-9a-f]*|'') fail "github_provenance_invalid" "CI proof requires an exact lowercase workflow SHA." ;;
    esac
    case "$GITHUB_CONTROL_SHA_INPUT" in
      *[!0-9a-f]*|'') fail "github_provenance_invalid" "CI proof requires an exact lowercase control SHA." ;;
    esac
    if [ "${#GITHUB_WORKFLOW_SHA_INPUT}" -ne 40 ] || [ "${#GITHUB_CONTROL_SHA_INPUT}" -ne 40 ] || [ "$GITHUB_WORKFLOW_SHA_INPUT" != "$GITHUB_CONTROL_SHA_INPUT" ]; then
      fail "github_provenance_invalid" "workflow and control SHAs must be the same exact protected-main commit."
    fi
    case "$GITHUB_RUN_ID_INPUT" in
      ''|*[!0-9]*|0|0*) fail "github_provenance_invalid" "CI proof requires a positive GitHub run ID." ;;
    esac
    case "$GITHUB_RUN_ATTEMPT_INPUT" in
      ''|*[!0-9]*|0|0*) fail "github_provenance_invalid" "CI proof requires a positive GitHub run attempt." ;;
    esac
    if [ "$GITHUB_JOB_INPUT" != "mac-mini-proof" ]; then
      fail "github_provenance_invalid" "CI proof requires the mac-mini-proof GitHub job identity."
    fi
    case "$GITHUB_CHECK_RUN_ID_INPUT" in
      ''|*[!0-9]*|0|0*) fail "github_provenance_invalid" "CI proof requires a positive target check-run ID." ;;
    esac
    case "$GITHUB_TARGET_AUTHORIZATION_INPUT" in
      protected_main)
        if [ -n "$GITHUB_PULL_REQUEST_NUMBER_INPUT" ] || [ -n "$GITHUB_APPROVED_BY_INPUT" ]; then
          fail "github_provenance_invalid" "protected-main authorization cannot claim pull-request approval metadata."
        fi
        ;;
      approved_pull_request)
        case "$GITHUB_PULL_REQUEST_NUMBER_INPUT" in
          ''|*[!0-9]*|0|0*) fail "github_provenance_invalid" "approved-PR authorization requires a positive pull-request number." ;;
        esac
        case "$GITHUB_APPROVED_BY_INPUT" in
          trishan-lunr|alex-lunr) ;;
          *) fail "github_provenance_invalid" "approved-PR authorization requires the configured Alex or Trishan reviewer." ;;
        esac
        ;;
      *) fail "github_provenance_invalid" "CI proof requires hosted target authorization." ;;
    esac

    github_event_name="$GITHUB_EVENT_NAME_INPUT"
    github_workflow_ref="$GITHUB_WORKFLOW_REF_INPUT"
    github_workflow_sha="$GITHUB_WORKFLOW_SHA_INPUT"
    github_control_sha="$GITHUB_CONTROL_SHA_INPUT"
    github_run_id="$GITHUB_RUN_ID_INPUT"
    github_run_attempt="$GITHUB_RUN_ATTEMPT_INPUT"
    github_job="$GITHUB_JOB_INPUT"
    github_check_run_id="$GITHUB_CHECK_RUN_ID_INPUT"
    github_target_authorization="$GITHUB_TARGET_AUTHORIZATION_INPUT"
    github_pull_request_number="$GITHUB_PULL_REQUEST_NUMBER_INPUT"
    github_approved_by="$GITHUB_APPROVED_BY_INPUT"

    control_head=$(proof_git -C "$CONTROL_REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null) || fail "control_checkout_unavailable" "could not verify the protected proof-control checkout."
    [ "$control_head" = "$github_control_sha" ] || fail "control_checkout_mismatch" "the proof harness checkout does not match the recorded protected control SHA."
    control_status=$(proof_git -C "$CONTROL_REPOSITORY_ROOT" status --porcelain --untracked-files=normal 2>/dev/null) || fail "control_checkout_unavailable" "could not verify the protected proof-control state."
    [ -z "$control_status" ] || fail "control_checkout_dirty" "the protected proof-control checkout must be clean."
    ;;
esac

operating_system=$("$UNAME_BIN" -s 2>/dev/null) || fail "operating_system_unavailable" "could not identify the operating system."
if [ "$operating_system" != "Darwin" ]; then
  fail "unsupported_operating_system" "this proof may run only on macOS."
fi

architecture=$("$UNAME_BIN" -m 2>/dev/null) || fail "architecture_unavailable" "could not identify the Mac architecture."
if [ "$architecture" != "arm64" ]; then
  fail "unsupported_architecture" "this proof requires an Apple-silicon arm64 Mac."
fi

approval_file="$DEFAULT_APPROVAL_FILE"
if [ -n "${OPENBRIDGE_HOST_APPROVAL_FILE:-}" ]; then
  if [ "$TEST_MODE_INPUT" != "1" ]; then
    fail "host_approval_override_forbidden" "the host approval marker cannot be overridden outside the script tests."
  fi
  approval_file="$OPENBRIDGE_HOST_APPROVAL_FILE"
fi

if [ ! -r "$approval_file" ]; then
  fail "approved_host_marker_missing" "the root-owned Mac mini approval marker is missing."
fi
approval_value=$(cat "$approval_file" 2>/dev/null) || fail "approved_host_marker_unreadable" "the Mac mini approval marker could not be read."
if [ "$approval_value" != "$APPROVED_RUNNER_LABEL" ]; then
  fail "approved_host_marker_mismatch" "the Mac mini approval marker has the wrong label."
fi

if [ "$TEST_MODE_INPUT" = "0" ]; then
  marker_owner=$("$STAT_BIN" -f '%Su' "$approval_file" 2>/dev/null) || fail "approved_host_marker_stat_failed" "the Mac mini approval marker metadata could not be read."
  marker_mode=$("$STAT_BIN" -f '%Lp' "$approval_file" 2>/dev/null) || fail "approved_host_marker_stat_failed" "the Mac mini approval marker metadata could not be read."
  if [ "$marker_owner" != "root" ] || [ "$marker_mode" != "444" ]; then
    fail "approved_host_marker_insecure" "the Mac mini approval marker must be root-owned with mode 0444."
  fi
fi

if [ "$PROOF_MODE" = "ci_automated" ]; then
  compact_labels=$(printf '%s' "$RUNNER_LABELS" | tr -d '[:space:]')
  for required_label in self-hosted macOS ARM64 "$APPROVED_RUNNER_LABEL"; do
    case ",$compact_labels," in
      *",$required_label,"*) ;;
      *) fail "required_runner_label_missing" "the self-hosted runner label set is incomplete." ;;
    esac
  done
fi

macos_version=$("$SW_VERS_BIN" -productVersion 2>/dev/null) || fail "macos_version_unavailable" "could not read the macOS version."
macos_major=${macos_version%%.*}
case "$macos_major" in
  *[!0-9]*|'') fail "macos_version_invalid" "the macOS version could not be validated." ;;
esac
if [ "$macos_major" -lt 14 ]; then
  fail "macos_version_too_old" "OpenBridge requires macOS 14 or newer."
fi

xcode_output=$("$XCODEBUILD_BIN" -version 2>/dev/null) || fail "xcode_version_unavailable" "could not read the Xcode version."
xcode_version=$(printf '%s\n' "$xcode_output" | awk 'NR == 1 { sub(/^Xcode /, ""); print; exit }')
xcode_build_version=$(printf '%s\n' "$xcode_output" | awk 'NR == 2 { sub(/^Build version /, ""); print; exit }')
xcode_major=${xcode_version%%.*}
case "$xcode_major" in
  *[!0-9]*|'') fail "xcode_version_invalid" "the Xcode version could not be validated." ;;
esac
if [ "$xcode_major" -lt 16 ]; then
  fail "xcode_version_too_old" "OpenBridge requires Xcode 16 or newer."
fi

swift_version=$(run_swift --version 2>/dev/null | awk 'NR == 1 { print; exit }')
swift_major=$(printf '%s\n' "$swift_version" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p')
case "$swift_major" in
  *[!0-9]*|'') fail "swift_version_invalid" "the Swift version could not be validated." ;;
esac
if [ "$swift_major" -lt 6 ]; then
  fail "swift_version_too_old" "OpenBridge requires Swift 6 or newer."
fi

if [ "$TEST_MODE_INPUT" = "1" ]; then
  proof_temp_parent="${TMPDIR:-/tmp}"
else
  proof_temp_parent="/tmp"
fi
temporary_root=$("$MKTEMP_BIN" -d "$proof_temp_parent/openbridge-mac-proof.XXXXXX") || fail "temporary_directory_failed" "could not create an isolated proof directory."

run_logged() {
  proof_log=$1
  shift

  "$@" >"$proof_log" 2>&1
  proof_status=$?
  cat "$proof_log"
  return "$proof_status"
}

extract_test_count() {
  count_kind=$1
  count_log=$2
  "$RECEIPT_PYTHON_BIN" - "$count_kind" "$count_log" <<'PY'
import pathlib
import re
import sys

kind = sys.argv[1]
text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)

if kind == "python":
    counts = [int(value) for value in re.findall(r"^Ran\s+(\d+)\s+tests?\s+in\b", text, re.MULTILINE)]
    count = sum(counts)
else:
    swift_testing = [
        int(value)
        for value in re.findall(
            r"Test run with\s+(\d+)\s+tests?(?:\s+in\s+\d+\s+suites?)?\s+passed\b",
            text,
        )
    ]
    if swift_testing:
        count = swift_testing[-1]
    else:
        xctest = [int(value) for value in re.findall(r"Executed\s+(\d+)\s+tests?,\s+with\s+0\s+failures", text)]
        count = max(xctest, default=0)

if count <= 0:
    raise SystemExit(1)
print(count)
PY
}

verify_model_cache_layout() {
  "$RECEIPT_PYTHON_BIN" - \
    "$proof_cache_root" \
    "$PARAKEET_MODEL_ID" \
    "$PARAKEET_MODEL_REPOSITORY" \
    "$PARAKEET_MODEL_REVISION" \
    "$GEMMA_MODEL_ID" \
    "$GEMMA_MODEL_REVISION" <<'PY'
import pathlib
import sys


root = pathlib.Path(sys.argv[1])
parakeet_id = sys.argv[2]
parakeet_repository = sys.argv[3]
parakeet_revision = sys.argv[4]
gemma_id = sys.argv[5]
gemma_revision = sys.argv[6]
hub = root / "huggingface" / "hub"


def cache_name(repository: str) -> str:
    return "models--" + repository.replace("/", "--")


parakeet_snapshot = hub / cache_name(parakeet_repository) / "snapshots" / parakeet_revision
parakeet_link = root / "speech-models" / parakeet_id
if not parakeet_snapshot.is_dir() or not parakeet_link.is_symlink():
    raise SystemExit(1)
try:
    if parakeet_link.resolve(strict=True) != parakeet_snapshot.resolve(strict=True):
        raise SystemExit(1)
except OSError:
    raise SystemExit(1)

gemma_snapshots = hub / cache_name(gemma_id) / "snapshots"
gemma_snapshot = gemma_snapshots / gemma_revision
if not gemma_snapshot.is_dir():
    raise SystemExit(1)
available_gemma_revisions = {
    path.name for path in gemma_snapshots.iterdir() if path.is_dir()
}
if available_gemma_revisions != {gemma_revision}:
    # Production's resolver selects the newest local snapshot. A proof cache
    # containing another revision would therefore be ambiguous.
    raise SystemExit(1)
PY
}

run_offline_engine() {
  proof_stdout=$1
  proof_stderr=$2
  shift 2

  if [ "$TEST_MODE_INPUT" = "1" ]; then
    "$ENV_BIN" -i \
      PATH="$PATH" \
      HOME="$account_home" \
      USER="$account" \
      LOGNAME="$account" \
      TMPDIR="$temporary_root/model-tmp" \
      PYTHONNOUSERSITE=1 \
      PYTHONDONTWRITEBYTECODE=1 \
      HF_HOME="$proof_cache_root/huggingface" \
      HF_HUB_OFFLINE=1 \
      HF_HUB_DISABLE_TELEMETRY=1 \
      HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
      TRANSFORMERS_OFFLINE=1 \
      OPENBRIDGE_MODEL_DIR="$proof_cache_root/speech-models" \
      OPENBRIDGE_LLM_CACHE_DIR="$proof_cache_root/huggingface" \
      OPENBRIDGE_NETWORK_SANDBOX=macos-deny-network \
      FAKE_SANDBOX_LOG="${FAKE_SANDBOX_LOG:-}" \
      FAKE_FAIL_MODEL="${FAKE_FAIL_MODEL:-}" \
      "$SANDBOX_EXEC_BIN" -p "$NETWORK_SANDBOX_PROFILE" \
      "$model_python" "$engine_script" "$@" \
      >"$proof_stdout" 2>"$proof_stderr"
  else
    "$ENV_BIN" -i \
      PATH="$TRUSTED_SYSTEM_PATH" \
      HOME="$account_home" \
      USER="$account" \
      LOGNAME="$account" \
      LANG=C \
      LC_ALL=C \
      TMPDIR="$temporary_root/model-tmp" \
      PYTHONNOUSERSITE=1 \
      PYTHONDONTWRITEBYTECODE=1 \
      HF_HOME="$proof_cache_root/huggingface" \
      HF_HUB_OFFLINE=1 \
      HF_HUB_DISABLE_TELEMETRY=1 \
      HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
      TRANSFORMERS_OFFLINE=1 \
      OPENBRIDGE_MODEL_DIR="$proof_cache_root/speech-models" \
      OPENBRIDGE_LLM_CACHE_DIR="$proof_cache_root/huggingface" \
      OPENBRIDGE_NETWORK_SANDBOX=macos-deny-network \
      "$SANDBOX_EXEC_BIN" -p "$NETWORK_SANDBOX_PROFILE" \
      "$model_python" "$engine_script" "$@" \
      >"$proof_stdout" 2>"$proof_stderr"
  fi
}

validate_model_output() {
  validation_kind=$1
  validation_path=$2
  "$RECEIPT_PYTHON_BIN" - \
    "$validation_kind" \
    "$validation_path" \
    "$PARAKEET_MODEL_ID" \
    "$PARAKEET_RUNTIME" \
    "$GEMMA_MODEL_ID" \
    "$GEMMA_MODEL_REVISION" <<'PY'
import json
import pathlib
import sys


kind, output_path, parakeet_id, parakeet_runtime, gemma_id, gemma_revision = sys.argv[1:]
try:
    payload = json.loads(pathlib.Path(output_path).read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(payload, dict) or payload.get("ok") is not True or payload.get("schemaVersion") != 1:
    raise SystemExit(1)

if kind == "parakeet":
    readiness = payload.get("readiness")
    if not isinstance(readiness, dict):
        raise SystemExit(1)
    model = readiness.get("speechModel")
    if not isinstance(model, dict):
        raise SystemExit(1)
    expected = {
        "identifier": parakeet_id,
        "runtime": parakeet_runtime,
        "runtimeSupported": True,
        "installed": True,
        "loadChecked": True,
        "loadOK": True,
        "inferenceChecked": True,
        "inferenceOK": True,
    }
    if any(model.get(key) != value for key, value in expected.items()):
        raise SystemExit(1)
elif kind == "gemma":
    cleanup = payload.get("cleanup")
    if not isinstance(cleanup, dict):
        raise SystemExit(1)
    segments = cleanup.get("segments")
    if (
        cleanup.get("contractVersion") != 1
        or cleanup.get("modelRepository") != gemma_id
        or cleanup.get("modelRevision") != gemma_revision
        or cleanup.get("chunkSize") != 8
        or not isinstance(segments, list)
        or len(segments) != 1
        or not isinstance(segments[0], dict)
        or segments[0].get("sourceSegmentID") != "proof-segment-1"
        or not isinstance(segments[0].get("cleanedText"), str)
        or not segments[0]["cleanedText"].strip()
    ):
        raise SystemExit(1)
else:
    raise SystemExit(1)
PY
}

verify_proof_runtime() {
  runtime_root=$1
  runtime_marker="$runtime_root/requirements-lock.sha256"
  runtime_lock="$REPOSITORY_ROOT/requirements-lock.txt"
  [ -f "$runtime_lock" ] || return 1
  [ -x "$runtime_root/venv/bin/python" ] || return 1

  "$ENV_BIN" -i \
    PATH="$TRUSTED_SYSTEM_PATH" \
    HOME="$account_home" \
    USER="$account" \
    LOGNAME="$account" \
    PYTHONNOUSERSITE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$RECEIPT_PYTHON_BIN" - \
    "$runtime_root" "$runtime_marker" "$runtime_lock" "$APPROVED_PYTHON_BASE" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys


runtime_root = pathlib.Path(sys.argv[1])
marker = pathlib.Path(sys.argv[2])
lock = pathlib.Path(sys.argv[3])
approved_python_base = pathlib.Path(sys.argv[4])
try:
    entries = [runtime_root, marker, *runtime_root.rglob("*")]
    for entry in entries:
        metadata = entry.lstat()
        if metadata.st_uid != 0:
            raise SystemExit(1)
        if not stat.S_ISLNK(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) & 0o022:
            raise SystemExit(1)
    if stat.S_IMODE(marker.stat().st_mode) != 0o444:
        raise SystemExit(1)
    resolved_python = (runtime_root / "venv" / "bin" / "python").resolve(strict=True)
    if resolved_python != approved_python_base.resolve(strict=True):
        raise SystemExit(1)
    base_metadata = resolved_python.stat()
    if base_metadata.st_uid != 0 or stat.S_IMODE(base_metadata.st_mode) & 0o022:
        raise SystemExit(1)
    expected = hashlib.sha256(lock.read_bytes()).hexdigest()
    recorded = marker.read_text(encoding="ascii").strip()
except (OSError, UnicodeError):
    raise SystemExit(1)
if recorded != expected:
    raise SystemExit(1)
PY
  runtime_metadata_status=$?
  [ "$runtime_metadata_status" -eq 0 ] || return "$runtime_metadata_status"

  "$ENV_BIN" -i \
    PATH="$TRUSTED_SYSTEM_PATH" \
    HOME="$account_home" \
    USER="$account" \
    LOGNAME="$account" \
    PYTHONNOUSERSITE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$runtime_root/venv/bin/python" - "$runtime_lock" <<'PY'
import importlib.metadata
import pathlib
import re
import sys


if sys.version_info[:2] != (3, 14):
    raise SystemExit(1)
lock_lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
expected = {}
for line in lock_lines:
    match = re.match(r"^([A-Za-z0-9_.-]+)==([^ \\\\]+)", line)
    if match:
        name = re.sub(r"[-_.]+", "-", match.group(1)).lower()
        expected[name] = match.group(2)
installed = {
    re.sub(r"[-_.]+", "-", distribution.metadata["Name"]).lower(): distribution.version
    for distribution in importlib.metadata.distributions()
    if distribution.metadata.get("Name")
}
permitted_bootstrap = {"pip"}
unexpected = set(installed) - set(expected) - permitted_bootstrap
if (
    not expected
    or unexpected
    or any(installed.get(name) != version for name, version in expected.items())
):
    raise SystemExit(1)
PY
}

engine_script="$REPOSITORY_ROOT/engine_cli.py"
[ -f "$engine_script" ] || fail "engine_script_missing" "engine_cli.py is missing from the exact source checkout."
if [ "$TEST_MODE_INPUT" = "1" ]; then
  model_python="$RECEIPT_PYTHON_BIN"
else
  if ! verify_proof_runtime "$APPROVED_RUNTIME_ROOT" >/dev/null 2>&1; then
    fail "approved_source_runtime_invalid" "the root-owned Python 3.14 proof runtime does not match the exact hashed dependency lock."
  fi
  model_python="$APPROVED_RUNTIME_ROOT/venv/bin/python"
fi

proof_cache_root="$account_home/Library/Caches/OpenBridge/mac-proof"
mkdir -p "$temporary_root/model-tmp" || fail "model_temporary_directory_failed" "could not create the isolated model temporary directory."
if ! verify_model_cache_layout >/dev/null 2>&1; then
  fail "pinned_model_cache_invalid" "the dedicated proof cache does not contain only the approved pinned Parakeet and Gemma snapshots."
fi

# A revision-shaped directory or symlink is not byte authentication. Before
# executing production code, copy only the complete locked file inventory into
# the private proof tree; each file is hashed during and after the copy.
if [ "$TEST_MODE_INPUT" != "1" ]; then
  verified_cache="$temporary_root/verified-model-cache"
  if ! "$RECEIPT_PYTHON_BIN" - "$REPOSITORY_ROOT" "$proof_cache_root" "$verified_cache" <<'PY'
import pathlib
import sys
sys.path.insert(0, sys.argv[1])
from openbridge_engine.model_snapshot_verifier import load_lock, materialize_snapshot
source, target = map(pathlib.Path, sys.argv[2:])
lock_path = pathlib.Path(sys.argv[1]) / "openbridge_engine/model_snapshots.lock.json"
lock, _ = load_lock(lock_path)
for key, spec in lock["models"].items():
    relative = pathlib.Path("huggingface/hub") / ("models--" + spec["repository"].replace("/", "--")) / "snapshots" / spec["revision"]
    destination = (target / "speech-models" / "parakeet-tdt-0.6b-v3-mlx-bf16"
                   if key == "parakeet" else target / relative)
    materialize_snapshot(lock_path, key, source / relative, destination)
PY
  then
    fail "model_snapshot_integrity_failed" "model bytes differ from the exact source snapshot lock; no inference was attempted."
  fi
  proof_cache_root="$verified_cache"
fi

say "[1/8] Python syntax and unit tests"
python_syntax_log="$temporary_root/python-syntax.log"
if ! run_logged "$python_syntax_log" run_make python-syntax; then
  python_tests="fail"
  fail "python_syntax_failed" "Python syntax check failed."
fi
python_log="$temporary_root/python-tests.log"
if run_logged "$python_log" run_make python-test; then
  python_tests="pass"
else
  python_tests="fail"
  fail "python_tests_failed" "Python tests failed."
fi
python_test_count=$(extract_test_count python "$python_log") || fail "python_test_count_unavailable" "Python tests passed but their nonzero test count could not be verified."

say "[2/8] Swift Debug build"
if run_make app-build; then
  swift_debug_build="pass"
else
  swift_debug_build="fail"
  fail "swift_debug_build_failed" "the Swift Debug build failed."
fi

say "[3/8] Swift optimized Release build"
if run_make app-build-release; then
  swift_release_build="pass"
else
  swift_release_build="fail"
  fail "swift_release_build_failed" "the Swift optimized Release build failed."
fi

say "[4/8] Swift source tests"
swift_log="$temporary_root/swift-tests.log"
if run_logged "$swift_log" run_make swift-test; then
  swift_tests="pass"
else
  swift_tests="fail"
  fail "swift_tests_failed" "Swift tests failed."
fi
swift_test_count=$(extract_test_count swift "$swift_log") || fail "swift_test_count_unavailable" "Swift tests passed but their nonzero test count could not be verified."

say "[5/8] Offline Parakeet source-runtime load and tiny inference"
parakeet_output="$temporary_root/parakeet-result.json"
parakeet_error="$temporary_root/parakeet-error.log"
if run_offline_engine "$parakeet_output" "$parakeet_error" \
  readiness \
  --model "$PARAKEET_MODEL_ID" \
  --cleanup-mode off \
  --load-check \
  --inference-check \
  && validate_model_output parakeet "$parakeet_output"; then
  parakeet_source_runtime="pass"
  parakeet_load_result="pass"
  parakeet_inference_result="pass"
else
  parakeet_source_runtime="fail"
  parakeet_load_result="fail"
  parakeet_inference_result="fail"
  fail "parakeet_source_runtime_failed" "the pinned Parakeet model did not load and complete its tiny offline inference through the production engine path."
fi

say "[6/8] Offline Gemma source-runtime cleanup inference"
gemma_input="$temporary_root/gemma-request.json"
gemma_output="$temporary_root/gemma-result.json"
gemma_error="$temporary_root/gemma-error.log"
printf '%s\n' '{"contractVersion":1,"modelRepository":"mlx-community/gemma-3-4b-it-qat-4bit","chunkSize":8,"segments":[{"id":"proof-segment-1","meetingID":"proof-meeting","sequence":0,"startOffset":0.0,"endOffset":1.0,"sourceLabel":"synthetic-proof","text":"synthetic non-sensitive text needing obvious cleanup","isFinal":true}]}' >"$gemma_input" \
  || fail "gemma_synthetic_input_failed" "could not create the synthetic Gemma proof input."
if run_offline_engine "$gemma_output" "$gemma_error" meeting-cleanup <"$gemma_input" \
  && validate_model_output gemma "$gemma_output"; then
  gemma_source_runtime="pass"
  gemma_inference_result="pass"
  local_model_network_isolation="pass"
else
  gemma_source_runtime="fail"
  gemma_inference_result="fail"
  fail "gemma_source_runtime_failed" "the pinned Gemma model did not complete synthetic cleanup inference through the offline production engine path."
fi

say "[7/8] Source-only optimized development app bundle"
release_bin_path=$(run_swift build -c release --show-bin-path 2>/dev/null | tail -n 1) || fail "swift_bin_path_unavailable" "could not locate the Swift Release products."
case "$release_bin_path" in
  "$REPOSITORY_ROOT"/.build/*) ;;
  *) fail "swift_bin_path_unsafe" "Swift reported a build-products path outside this checkout." ;;
esac
if [ ! -x "$release_bin_path/OpenBridgeApp" ]; then
  fail "development_executable_missing" "the Release OpenBridgeApp executable is missing."
fi

development_app="$temporary_root/OpenBridgeMacProof.app"
mkdir -p "$development_app/Contents/MacOS" "$development_app/Contents/Resources" || fail "development_bundle_failed" "could not create the development app bundle."
cp "$release_bin_path/OpenBridgeApp" "$development_app/Contents/MacOS/OpenBridgeMacProof" || fail "development_bundle_failed" "could not copy the optimized development executable."

for resource_bundle in "$release_bin_path"/*.bundle; do
  if [ -d "$resource_bundle" ]; then
    cp -R "$resource_bundle" "$development_app/Contents/Resources/" || fail "development_bundle_failed" "could not copy Swift package resources."
    # SwiftPM's generated executable accessor looks beside Bundle.main while a
    # conventional app expects resources in Contents/Resources. Include both
    # locations so the smoke does not succeed only because the build tree still
    # happens to contain the compile-time fallback path.
    cp -R "$resource_bundle" "$development_app/" || fail "development_bundle_failed" "could not copy Swift package resource compatibility bundle."
  fi
done

bundle_identifier="dev.openbridge.macproof.$commit_sha"
cat >"$development_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>OpenBridgeMacProof</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_identifier</string>
  <key>CFBundleName</key>
  <string>OpenBridge Mac Proof</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Development launch proof only; no microphone test is performed.</string>
</dict>
</plist>
PLIST

if run_codesign --force --sign - "$development_app" >/dev/null 2>&1 \
  && run_codesign --verify --deep --strict "$development_app" >/dev/null 2>&1; then
  development_app_bundle="pass"
else
  development_app_bundle="fail"
  fail "development_bundle_signing_failed" "the source-only development app could not be ad-hoc signed."
fi

say "[8/8] Automated launch-survival smoke"
isolated_home="$temporary_root/profile"
mkdir -p "$isolated_home" || fail "isolated_profile_failed" "could not create an isolated launch profile."
engine_python="$model_python"
engine_script="$REPOSITORY_ROOT/engine_cli.py"
if [ ! -f "$engine_script" ]; then
  fail "engine_script_missing" "engine_cli.py is missing from the exact source checkout."
fi
if [ "$TEST_MODE_INPUT" = "1" ]; then
  "$ENV_BIN" -i \
    PATH="$PATH" \
    HOME="$isolated_home" \
    USER="$account" \
    LOGNAME="$account" \
    TMPDIR="$temporary_root" \
    CFFIXED_USER_HOME="$isolated_home" \
    OPENBRIDGE_ENGINE_PYTHON="$engine_python" \
    OPENBRIDGE_ENGINE_SCRIPT="$engine_script" \
    OPENBRIDGE_MODEL_DIR="$proof_cache_root/speech-models" \
    OPENBRIDGE_LLM_CACHE_DIR="$proof_cache_root/huggingface" \
    HF_HOME="$proof_cache_root/huggingface" \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    FAKE_LAUNCH_ENV_LOG="${FAKE_LAUNCH_ENV_LOG:-}" \
    "$development_app/Contents/MacOS/OpenBridgeMacProof" >"$temporary_root/app.stdout" 2>"$temporary_root/app.stderr" &
  app_pid=$!
else
  launched_with_launch_services=1
  "$ENV_BIN" -i \
    PATH="$TRUSTED_SYSTEM_PATH" \
    HOME="$account_home" \
    USER="$account" \
    LOGNAME="$account" \
    "$OPEN_BIN" -n -W \
      --env "PATH=$TRUSTED_SYSTEM_PATH" \
      --env "HOME=$isolated_home" \
      --env "TMPDIR=$temporary_root" \
      --env "CFFIXED_USER_HOME=$isolated_home" \
      --env "OPENBRIDGE_ENGINE_PYTHON=$engine_python" \
      --env "OPENBRIDGE_ENGINE_SCRIPT=$engine_script" \
      --env "OPENBRIDGE_MODEL_DIR=$proof_cache_root/speech-models" \
      --env "OPENBRIDGE_LLM_CACHE_DIR=$proof_cache_root/huggingface" \
      --env "HF_HOME=$proof_cache_root/huggingface" \
      --env "HF_HUB_OFFLINE=1" \
      --env "TRANSFORMERS_OFFLINE=1" \
      --stdout "$temporary_root/app.stdout" \
      --stderr "$temporary_root/app.stderr" \
      "$development_app" &
  app_pid=$!
fi
sleep "$LAUNCH_SECONDS"
if kill -0 "$app_pid" 2>/dev/null; then
  automated_launch_survival="pass"
else
  automated_launch_survival="fail"
  fail "automated_launch_survival_failed" "the bundled development process exited during the launch-smoke interval."
fi

if [ "$PROOF_MODE" = "developer_manual" ]; then
  say "Manual launch smoke required for exact commit $commit_sha."
  say "Scenario: $manual_scenario_id"
  say "Pass means all four are true: the menu-bar item is visible, the primary UI opens, the app responds, and the named primary user journey succeeds."

  manual_result="$MANUAL_RESULT_INPUT"
  if [ -z "$manual_result" ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      fail "manual_result_required" "manual result was omitted and no interactive terminal is available."
    fi
    printf 'Enter manual result (pass or fail): ' >/dev/tty
    IFS= read -r manual_result </dev/tty || fail "manual_result_required" "manual result was not recorded."
  fi

  case "$manual_result" in
    pass)
      expected_confirmation="observed:$commit_sha"
      provided_confirmation="$MANUAL_CONFIRMATION_INPUT"
      if [ -z "$provided_confirmation" ]; then
        if [ ! -t 0 ] || [ ! -t 1 ]; then
          fail "manual_confirmation_required" "manual confirmation was omitted and no interactive terminal is available."
        fi
        printf 'Type %s to bind the observation to this commit: ' "$expected_confirmation" >/dev/tty
        IFS= read -r provided_confirmation </dev/tty || fail "manual_confirmation_required" "manual confirmation was not recorded."
      fi
      if [ "$provided_confirmation" != "$expected_confirmation" ]; then
        fail "manual_confirmation_mismatch" "manual confirmation did not name the exact commit."
      fi
      manual_launch_status="pass"
      manual_tester="$account"
      manual_confirmation="$provided_confirmation"
      ;;
    fail)
      manual_launch_status="fail"
      manual_tester="$account"
      fail "manual_launch_smoke_failed" "the visible launch smoke was reported as failed."
      ;;
    *)
      fail "manual_result_invalid" "manual result must be exactly pass or fail."
      ;;
  esac
fi

final_target_head=$(proof_git rev-parse HEAD 2>/dev/null) || fail "git_revision_unavailable" "could not reverify the final target commit."
if [ "$final_target_head" != "$commit_sha" ]; then
  clean_worktree="false"
  fail "target_commit_changed_during_proof" "the target HEAD changed while the proof was running."
fi

git_status=$(proof_git status --porcelain --untracked-files=normal 2>/dev/null) || fail "git_status_unavailable" "could not verify the final working-tree state."
if [ -n "$git_status" ]; then
  clean_worktree="false"
  fail "worktree_changed_during_proof" "the proof changed repository-tracked state."
fi
clean_worktree="true"

if [ "$PROOF_MODE" = "ci_automated" ]; then
  final_control_head=$(proof_git -C "$CONTROL_REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null) || fail "control_checkout_unavailable" "could not reverify the protected proof-control checkout."
  [ "$final_control_head" = "$github_control_sha" ] || fail "control_checkout_mismatch" "the proof-control commit changed while candidate code ran."
  final_control_status=$(proof_git -C "$CONTROL_REPOSITORY_ROOT" status --porcelain --untracked-files=normal 2>/dev/null) || fail "control_checkout_unavailable" "could not reverify the protected proof-control state."
  [ -z "$final_control_status" ] || fail "control_checkout_dirty" "candidate execution changed the protected proof-control checkout."
fi

say "Mac proof passed for $commit_sha."
exit 0
