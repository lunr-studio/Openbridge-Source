"""Contract tests for the macOS development proof.

The real proof is deliberately restricted to an approved Apple-silicon Mac.
These tests exercise its decision logic in a disposable Git repository with
fake platform/build commands. Test-mode receipts remain marked ``test_mode``
and therefore cannot be accepted as real proof.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SCRIPT_SOURCE = Path(__file__).resolve().parents[1] / "mac_dev_proof.sh"
MAKEFILE_SOURCE = Path(__file__).resolve().parents[2] / "Makefile"
WORKFLOW_SOURCE = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "mac-mini-proof.yml"
)
CI_WORKFLOW_SOURCE = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "ci.yml"
)
CODEOWNERS_SOURCE = Path(__file__).resolve().parents[2] / ".github" / "CODEOWNERS"
RUNNER_DOC_SOURCE = (
    Path(__file__).resolve().parents[2] / "docs" / "setup" / "MAC_MINI_PROOF_RUNNER.md"
)


def _extract_github_scripts(workflow_source: str) -> dict[str, str]:
    """Extract github-script literal blocks without requiring a YAML package."""

    lines = workflow_source.splitlines()
    scripts: dict[str, str] = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.lstrip(" ")
        if not stripped.startswith("- name: "):
            index += 1
            continue

        step_indent = len(line) - len(stripped)
        step_name = stripped.removeprefix("- name: ").strip().strip("'\"")
        step_end = index + 1
        while step_end < len(lines):
            candidate = lines[step_end]
            if candidate.strip() and len(candidate) - len(candidate.lstrip(" ")) <= step_indent:
                break
            step_end += 1

        step_lines = lines[index:step_end]
        if any(
            candidate.lstrip(" ").startswith("uses: actions/github-script@")
            for candidate in step_lines
        ):
            script_markers = [
                offset
                for offset, candidate in enumerate(step_lines)
                if candidate.lstrip(" ").startswith("script: |")
            ]
            if len(script_markers) != 1:
                raise ValueError(
                    f"github-script step {step_name!r} must contain one literal script block"
                )
            marker = script_markers[0]
            marker_line = step_lines[marker]
            marker_indent = len(marker_line) - len(marker_line.lstrip(" "))
            body_lines = []
            for candidate in step_lines[marker + 1 :]:
                if candidate.strip() and len(candidate) - len(candidate.lstrip(" ")) <= marker_indent:
                    break
                body_lines.append(candidate)
            content_indents = [
                len(candidate) - len(candidate.lstrip(" "))
                for candidate in body_lines
                if candidate.strip()
            ]
            if not content_indents or min(content_indents) <= marker_indent:
                raise ValueError(f"github-script step {step_name!r} has an empty script")
            content_indent = min(content_indents)
            script = "\n".join(
                candidate[content_indent:] if candidate.strip() else ""
                for candidate in body_lines
            )
            if step_name in scripts:
                raise ValueError(f"duplicate github-script step name {step_name!r}")
            scripts[step_name] = script

        index = step_end

    return scripts


class MacDevProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.repository = self.root / "repository"
        self.fake_bin = self.root / "fake-bin"
        self.repository.mkdir()
        self.fake_bin.mkdir()

        script_directory = self.repository / "scripts"
        script_directory.mkdir()
        self.script = script_directory / "mac_dev_proof.sh"
        shutil.copy2(SCRIPT_SOURCE, self.script)
        self.script.chmod(0o755)
        (self.repository / ".gitignore").write_text(".build/\n", encoding="utf-8")
        (self.repository / "engine_cli.py").write_text("# engine fixture\n", encoding="utf-8")

        self._write_fake_commands()
        self._write_fake_build_products()

        self._git("init", "-q")
        self._git("config", "user.name", "Mac Proof Test")
        self._git("config", "user.email", "mac-proof@example.invalid")
        self._git("add", ".gitignore", "engine_cli.py", "scripts/mac_dev_proof.sh")
        self._git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        self.commit_sha = self._git("rev-parse", "HEAD").stdout.strip()

        self.marker = self.root / "approved-host-marker"
        self.marker.write_text("franklin-mac-mini\n", encoding="utf-8")
        self.make_log = self.root / "make.log"
        self.launch_environment_log = self.root / "launch-environment.log"
        self.sandbox_log = self.root / "sandbox.log"
        self.account_home = self.root / "account-home"
        self.account_home.mkdir()
        proof_cache = self.account_home / "Library" / "Caches" / "OpenBridge" / "mac-proof"
        hub = proof_cache / "huggingface" / "hub"
        parakeet_snapshot = (
            hub
            / "models--sonic-speech--parakeet-tdt-0.6b-v3"
            / "snapshots"
            / "55c316ecc6eca874d3aff6c5c711d37305159271"
        )
        gemma_snapshot = (
            hub
            / "models--mlx-community--gemma-3-4b-it-qat-4bit"
            / "snapshots"
            / "3d9ef289111449933c22761961f16a5df237ce2a"
        )
        parakeet_snapshot.mkdir(parents=True)
        gemma_snapshot.mkdir(parents=True)
        speech_models = proof_cache / "speech-models"
        speech_models.mkdir(parents=True)
        (speech_models / "parakeet-tdt-0.6b-v3-mlx-bf16").symlink_to(
            parakeet_snapshot,
            target_is_directory=True,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            check=True,
            text=True,
            capture_output=True,
        )

    def _write_command(self, name: str, body: str) -> None:
        path = self.fake_bin / name
        path.write_text("#!/bin/sh\nset -u\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_commands(self) -> None:
        self._write_command(
            "id",
            """if [ "${1:-}" = "-un" ]; then
  printf '%s\\n' "${FAKE_ACCOUNT:-openbridge-ci}"
  exit 0
fi
exit 2
""",
        )
        self._write_command(
            "uname",
            """case "${1:-}" in
  -s) printf '%s\\n' "${FAKE_OPERATING_SYSTEM:-Darwin}" ;;
  -m) printf '%s\\n' "${FAKE_ARCHITECTURE:-arm64}" ;;
  *) exit 2 ;;
esac
""",
        )
        self._write_command(
            "sw_vers",
            """if [ "${1:-}" = "-productVersion" ]; then
  printf '%s\\n' "${FAKE_MACOS_VERSION:-14.6.1}"
  exit 0
fi
exit 2
""",
        )
        self._write_command(
            "xcodebuild",
            """if [ "${1:-}" = "-version" ]; then
  printf 'Xcode %s\\n' "${FAKE_XCODE_VERSION:-16.4}"
  printf 'Build version %s\\n' "${FAKE_XCODE_BUILD_VERSION:-16F6}"
  exit 0
fi
exit 2
""",
        )
        self._write_command(
            "swift",
            """if [ "${1:-}" = "--version" ]; then
  printf 'Apple Swift version %s (swiftlang-test)\\n' "${FAKE_SWIFT_VERSION:-6.1.2}"
  exit 0
fi
if [ "$*" = "build -c release --show-bin-path" ]; then
  printf '%s\\n' "$FAKE_REPOSITORY_ROOT/.build/fake/release"
  exit 0
fi
exit 2
""",
        )
        self._write_command(
            "make",
            """printf '%s\\n' "$*" >>"$FAKE_MAKE_LOG"
if [ "${FAKE_FAIL_MAKE_TARGET:-}" = "${1:-}" ]; then
  exit 1
fi
if [ -n "${FAKE_SWITCH_HEAD:-}" ] && [ "${1:-}" = "app-build-release" ]; then
  /usr/bin/git -C "$FAKE_REPOSITORY_ROOT" checkout -q "$FAKE_SWITCH_HEAD"
fi
case "${1:-}" in
  python-test)
    if [ "${FAKE_OMIT_TEST_COUNTS:-}" != "python" ]; then
      printf 'Ran 7 tests in 0.001s\\n\\nOK\\n'
    fi
    ;;
  swift-test)
    if [ "${FAKE_OMIT_TEST_COUNTS:-}" != "swift" ]; then
      printf '◇ Test run with 9 tests in 4 suites passed after 0.001 seconds.\\n'
    fi
    ;;
esac
exit 0
""",
        )
        self._write_command("codesign", "exit 0\n")
        self._write_command("open", "exit 2\n")
        self._write_command(
            "sandbox-exec",
            """{
  printf 'args=%s\\n' "$*"
  printf 'model_dir=%s\\n' "${OPENBRIDGE_MODEL_DIR:-}"
  printf 'llm_cache=%s\\n' "${OPENBRIDGE_LLM_CACHE_DIR:-}"
  printf 'hf_offline=%s\\n' "${HF_HUB_OFFLINE:-}"
  printf 'transformers_offline=%s\\n' "${TRANSFORMERS_OFFLINE:-}"
  printf 'network_sandbox=%s\\n' "${OPENBRIDGE_NETWORK_SANDBOX:-}"
  printf 'pythonpath=%s\\n' "${PYTHONPATH:-}"
  printf 'app_engine_python=%s\\n' "${APP_ENGINE_PYTHON:-}"
  printf 'openai_api_key=%s\\n' "${OPENAI_API_KEY:-}"
} >>"$FAKE_SANDBOX_LOG"
case " $* " in
  *" readiness "*)
    [ "${FAKE_FAIL_MODEL:-}" != "parakeet" ] || exit 1
    printf '%s\\n' '{"ok":true,"schemaVersion":1,"readiness":{"speechModel":{"identifier":"parakeet-tdt-0.6b-v3-mlx-bf16","runtime":"parakeet_mlx","runtimeSupported":true,"installed":true,"loadChecked":true,"loadOK":true,"inferenceChecked":true,"inferenceOK":true}}}'
    ;;
  *" meeting-cleanup "*)
    /bin/cat >/dev/null
    [ "${FAKE_FAIL_MODEL:-}" != "gemma" ] || exit 1
    printf '%s\\n' '{"ok":true,"schemaVersion":1,"cleanup":{"contractVersion":1,"modelRepository":"mlx-community/gemma-3-4b-it-qat-4bit","modelRevision":"3d9ef289111449933c22761961f16a5df237ce2a","chunkSize":8,"segments":[{"sourceSegmentID":"proof-segment-1","cleanedText":"Synthetic local proof input."}]}}'
    ;;
  *) exit 2 ;;
esac
""",
        )

    def _write_fake_build_products(self) -> None:
        release_directory = self.repository / ".build" / "fake" / "release"
        release_directory.mkdir(parents=True)
        executable = release_directory / "OpenBridgeApp"
        executable.write_text(
            """#!/bin/sh
proof_macos=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
proof_app=$(CDPATH= cd -- "$proof_macos/../.." && pwd)
test -d "$proof_app/Contents/Resources/OpenBridge_OpenBridgeApp.bundle" || exit 20
test -d "$proof_app/OpenBridge_OpenBridgeApp.bundle" || exit 21
{
  printf 'CFFIXED_USER_HOME=%s\\n' "${CFFIXED_USER_HOME:-}"
  printf 'OPENBRIDGE_ENGINE_PYTHON=%s\\n' "${OPENBRIDGE_ENGINE_PYTHON:-}"
  printf 'OPENBRIDGE_ENGINE_SCRIPT=%s\\n' "${OPENBRIDGE_ENGINE_SCRIPT:-}"
} >"$FAKE_LAUNCH_ENV_LOG"
exec /bin/sleep 60
""",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        (release_directory / "OpenBridge_OpenBridgeApp.bundle").mkdir()

    def _receipt_path(self, mode: str) -> Path:
        directory = "mac-mini-proof" if mode == "ci_automated" else "mac-dev-proof"
        return self.repository / ".build" / directory / f"{directory}-{self.commit_sha}.json"

    def _attestation_path(self) -> Path:
        return (
            self.repository
            / ".build"
            / "mac-dev-proof"
            / f"franklin-attestation-{self.commit_sha}.md"
        )

    def _run(
        self,
        mode: str = "ci_automated",
        **environment_overrides: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict]:
        environment = os.environ.copy()
        for inherited_name in (
            "OPENBRIDGE_PROOF_MODE",
            "OPENBRIDGE_EXPECTED_SHA",
            "OPENBRIDGE_PROOF_TESTING",
            "OPENBRIDGE_HOST_APPROVAL_FILE",
            "OPENBRIDGE_LAUNCH_SMOKE_SECONDS",
            "OPENBRIDGE_RUNNER_LABELS",
            "OPENBRIDGE_TARGET_REPOSITORY",
            "OPENBRIDGE_GITHUB_EVENT_NAME",
            "OPENBRIDGE_GITHUB_WORKFLOW_REF",
            "OPENBRIDGE_GITHUB_WORKFLOW_SHA",
            "OPENBRIDGE_GITHUB_CONTROL_SHA",
            "OPENBRIDGE_GITHUB_RUN_ID",
            "OPENBRIDGE_GITHUB_RUN_ATTEMPT",
            "OPENBRIDGE_GITHUB_JOB",
            "OPENBRIDGE_GITHUB_CHECK_RUN_ID",
            "OPENBRIDGE_GITHUB_TARGET_AUTHORIZATION",
            "OPENBRIDGE_GITHUB_PULL_REQUEST_NUMBER",
            "OPENBRIDGE_GITHUB_APPROVED_BY",
            "OPENBRIDGE_MANUAL_SCENARIO_ID",
            "OPENBRIDGE_MANUAL_RESULT",
            "OPENBRIDGE_MANUAL_CONFIRMATION",
            "FAKE_ACCOUNT",
            "FAKE_OPERATING_SYSTEM",
            "FAKE_ARCHITECTURE",
            "FAKE_MACOS_VERSION",
            "FAKE_XCODE_VERSION",
            "FAKE_XCODE_BUILD_VERSION",
            "FAKE_SWIFT_VERSION",
            "FAKE_FAIL_MAKE_TARGET",
            "FAKE_OMIT_TEST_COUNTS",
            "FAKE_FAIL_MODEL",
            "FAKE_SWITCH_HEAD",
        ):
            environment.pop(inherited_name, None)
        environment.update(
            {
                "PATH": f"{self.fake_bin}{os.pathsep}{environment['PATH']}",
                "FAKE_REPOSITORY_ROOT": str(self.repository),
                "FAKE_MAKE_LOG": str(self.make_log),
                "FAKE_LAUNCH_ENV_LOG": str(self.launch_environment_log),
                "FAKE_SANDBOX_LOG": str(self.sandbox_log),
                "FAKE_ACCOUNT": "openbridge-ci" if mode == "ci_automated" else "franklin",
                # The child is an intentionally fake proof fixture even when
                # this unittest itself runs inside GitHub Actions.
                "GITHUB_ACTIONS": "false",
                "OPENBRIDGE_PROOF_MODE": mode,
                "OPENBRIDGE_EXPECTED_SHA": self.commit_sha,
                "OPENBRIDGE_PROOF_TESTING": "1",
                "OPENBRIDGE_HOST_APPROVAL_FILE": str(self.marker),
                "OPENBRIDGE_PROOF_TEST_ACCOUNT_HOME": str(self.account_home),
                "OPENBRIDGE_LAUNCH_SMOKE_SECONDS": "0",
                "OPENBRIDGE_RUNNER_LABELS": "self-hosted,macOS,ARM64,franklin-mac-mini",
            }
        )
        if mode == "ci_automated":
            environment.update(
                {
                    "OPENBRIDGE_TARGET_REPOSITORY": str(self.repository),
                    "OPENBRIDGE_GITHUB_EVENT_NAME": "workflow_dispatch",
                    "OPENBRIDGE_GITHUB_WORKFLOW_REF": (
                        "lunr-studio/Openbridge-Dev/.github/workflows/"
                        "mac-mini-proof.yml@refs/heads/main"
                    ),
                    "OPENBRIDGE_GITHUB_WORKFLOW_SHA": self.commit_sha,
                    "OPENBRIDGE_GITHUB_CONTROL_SHA": self.commit_sha,
                    "OPENBRIDGE_GITHUB_RUN_ID": "12345",
                    "OPENBRIDGE_GITHUB_RUN_ATTEMPT": "1",
                    "OPENBRIDGE_GITHUB_JOB": "mac-mini-proof",
                    "OPENBRIDGE_GITHUB_CHECK_RUN_ID": "54321",
                    "OPENBRIDGE_GITHUB_TARGET_AUTHORIZATION": "approved_pull_request",
                    "OPENBRIDGE_GITHUB_PULL_REQUEST_NUMBER": "77",
                    "OPENBRIDGE_GITHUB_APPROVED_BY": "trishan-lunr",
                }
            )
        environment.update(environment_overrides)
        result = subprocess.run(
            ["/bin/sh", str(self.script)],
            cwd=self.repository,
            env=environment,
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=15,
        )
        receipt_path = self._receipt_path(mode)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8")) if receipt_path.exists() else {}
        return result, receipt

    def test_ci_receipt_has_exact_success_contract(self) -> None:
        result, receipt = self._run(OPENBRIDGE_LAUNCH_SMOKE_SECONDS="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            set(receipt),
            {
                "schema_version",
                "proof_type",
                "test_mode",
                "generated_at_utc",
                "account",
                "approved_runner_label",
                "commit_sha",
                "clean_worktree",
                "macos_version",
                "architecture",
                "xcode_version",
                "xcode_build_version",
                "swift_version",
                "app_bundle_kind",
                "automated_launch_seconds",
                "test_counts",
                "source_runtime_models",
                "checks",
                "manual_launch_smoke",
                "github_provenance",
                "overall_result",
                "failure_reason",
            },
        )
        self.assertEqual(receipt["schema_version"], 1)
        self.assertEqual(receipt["proof_type"], "ci_automated")
        self.assertIs(receipt["test_mode"], True)
        self.assertEqual(receipt["account"], "openbridge-ci")
        self.assertEqual(receipt["approved_runner_label"], "franklin-mac-mini")
        self.assertEqual(receipt["commit_sha"], self.commit_sha)
        self.assertIs(receipt["clean_worktree"], True)
        self.assertRegex(receipt["generated_at_utc"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual(receipt["macos_version"], "14.6.1")
        self.assertEqual(receipt["architecture"], "arm64")
        self.assertEqual(receipt["xcode_version"], "16.4")
        self.assertEqual(receipt["xcode_build_version"], "16F6")
        self.assertIn("Swift version 6.1.2", receipt["swift_version"])
        self.assertEqual(receipt["test_counts"], {"python_tests": 7, "swift_tests": 9})
        self.assertEqual(
            receipt["github_provenance"],
            {
                "event_name": "workflow_dispatch",
                "workflow_ref": (
                    "lunr-studio/Openbridge-Dev/.github/workflows/"
                    "mac-mini-proof.yml@refs/heads/main"
                ),
                "workflow_sha": self.commit_sha,
                "control_commit_sha": self.commit_sha,
                "run_id": 12345,
                "run_attempt": 1,
                "job": "mac-mini-proof",
                "check_run_id": 54321,
                "target_authorization": "approved_pull_request",
                "pull_request_number": 77,
                "approved_by": "trishan-lunr",
            },
        )
        self.assertEqual(
            receipt["source_runtime_models"],
            {
                "scope": "source_runtime",
                "network_isolation_result": "pass",
                "parakeet": {
                    "model_id": "parakeet-tdt-0.6b-v3-mlx-bf16",
                    "revision": "55c316ecc6eca874d3aff6c5c711d37305159271",
                    "runtime": "parakeet_mlx",
                    "load_result": "pass",
                    "inference_result": "pass",
                },
                "gemma": {
                    "model_id": "mlx-community/gemma-3-4b-it-qat-4bit",
                    "revision": "3d9ef289111449933c22761961f16a5df237ce2a",
                    "runtime": "mlx",
                    "inference_result": "pass",
                },
            },
        )
        expected_checks = {
            "python_tests": "pass",
            "swift_debug_build": "pass",
            "swift_release_build": "pass",
            "swift_tests": "pass",
            "parakeet_source_runtime": "pass",
            "gemma_source_runtime": "pass",
            "local_model_network_isolation": "pass",
            "development_app_bundle": "pass",
            "automated_launch_survival": "pass",
            "manual_launch_smoke": "not_applicable",
        }
        self.assertEqual(receipt["checks"], expected_checks)
        self.assertEqual(
            receipt["manual_launch_smoke"],
            {
                "result": "not_applicable",
                "tester": None,
                "confirmation": None,
                "scenario_id": None,
                "required_observations": [
                    "menu_bar_item_visible",
                    "primary_ui_opened",
                    "application_responsive",
                    "primary_user_journey_passed",
                ],
            },
        )
        self.assertEqual(receipt["overall_result"], "pass")
        self.assertIsNone(receipt["failure_reason"])
        launch_environment = dict(
            line.split("=", 1)
            for line in self.launch_environment_log.read_text(encoding="utf-8").splitlines()
        )
        self.assertRegex(launch_environment["CFFIXED_USER_HOME"], r"openbridge-mac-proof\.")
        self.assertTrue(launch_environment["OPENBRIDGE_ENGINE_PYTHON"].endswith("python3"))
        self.assertEqual(
            launch_environment["OPENBRIDGE_ENGINE_SCRIPT"],
            str(self.repository / "engine_cli.py"),
        )
        self.assertEqual(
            self.make_log.read_text(encoding="utf-8").splitlines(),
            [
                "python-syntax",
                "python-test",
                "app-build",
                "app-build-release",
                "swift-test",
            ],
        )
        sandbox_log = self.sandbox_log.read_text(encoding="utf-8")
        self.assertEqual(sandbox_log.count("args="), 2)
        self.assertIn("(deny network*)", sandbox_log)
        self.assertIn("readiness --model parakeet-tdt-0.6b-v3-mlx-bf16", sandbox_log)
        self.assertIn("meeting-cleanup", sandbox_log)
        self.assertIn(f"model_dir={self.account_home}/Library/Caches/OpenBridge/mac-proof/speech-models", sandbox_log)
        self.assertIn(f"llm_cache={self.account_home}/Library/Caches/OpenBridge/mac-proof/huggingface", sandbox_log)
        self.assertEqual(sandbox_log.count("hf_offline=1"), 2)
        self.assertEqual(sandbox_log.count("transformers_offline=1"), 2)
        self.assertEqual(sandbox_log.count("network_sandbox=macos-deny-network"), 2)
        self.assertEqual(sandbox_log.count("pythonpath="), 2)
        self.assertEqual(sandbox_log.count("app_engine_python="), 2)
        self.assertEqual(sandbox_log.count("openai_api_key="), 2)

    def test_developer_pass_requires_scenario_and_sha_bound_confirmation(self) -> None:
        result, receipt = self._run(
            "developer_manual",
            OPENBRIDGE_MANUAL_SCENARIO_ID="issue-321-primary-dictation",
            OPENBRIDGE_MANUAL_RESULT="pass",
            OPENBRIDGE_MANUAL_CONFIRMATION=f"observed:{self.commit_sha}",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt["proof_type"], "developer_manual")
        self.assertEqual(
            receipt["github_provenance"],
            {
                "event_name": None,
                "workflow_ref": None,
                "workflow_sha": None,
                "control_commit_sha": None,
                "run_id": None,
                "run_attempt": None,
                "job": None,
                "check_run_id": None,
                "target_authorization": None,
                "pull_request_number": None,
                "approved_by": None,
            },
        )
        self.assertEqual(receipt["checks"]["manual_launch_smoke"], "pass")
        self.assertEqual(
            receipt["manual_launch_smoke"],
            {
                "result": "pass",
                "tester": "franklin",
                "confirmation": f"observed:{self.commit_sha}",
                "scenario_id": "issue-321-primary-dictation",
                "required_observations": [
                    "menu_bar_item_visible",
                    "primary_ui_opened",
                    "application_responsive",
                    "primary_user_journey_passed",
                ],
            },
        )
        self.assertEqual(receipt["overall_result"], "pass")
        attestation = self._attestation_path().read_text(encoding="utf-8")
        self.assertTrue(
            attestation.startswith("<!-- openbridge-franklin-mac-dev-proof-v1 -->\n")
        )
        match = re.search(r"```json\n(.*)\n```\n$", attestation, re.DOTALL)
        self.assertIsNotNone(match)
        payload = json.loads(match.group(1))
        self.assertEqual(
            set(payload),
            {
                "schema_version",
                "attestation_type",
                "target_sha",
                "receipt_sha256",
                "scenario_id",
                "receipt_base64",
            },
        )
        receipt_bytes = self._receipt_path("developer_manual").read_bytes()
        self.assertEqual(base64.b64decode(payload["receipt_base64"]), receipt_bytes)
        self.assertEqual(payload["receipt_sha256"], hashlib.sha256(receipt_bytes).hexdigest())
        self.assertEqual(payload["target_sha"], self.commit_sha)
        self.assertEqual(payload["scenario_id"], "issue-321-primary-dictation")

    def test_developer_omission_cannot_become_a_pass(self) -> None:
        result, receipt = self._run(
            "developer_manual",
            OPENBRIDGE_MANUAL_SCENARIO_ID="primary-dictation",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "manual_result_required")
        self.assertEqual(receipt["overall_result"], "fail")
        self.assertEqual(receipt["checks"]["manual_launch_smoke"], "not_run")

    def test_developer_confirmation_must_name_exact_sha(self) -> None:
        result, receipt = self._run(
            "developer_manual",
            OPENBRIDGE_MANUAL_SCENARIO_ID="primary-dictation",
            OPENBRIDGE_MANUAL_RESULT="pass",
            OPENBRIDGE_MANUAL_CONFIRMATION="observed:" + ("0" * 40),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "manual_confirmation_mismatch")
        self.assertEqual(receipt["overall_result"], "fail")

    def test_ci_rejects_any_manual_claim(self) -> None:
        result, receipt = self._run(OPENBRIDGE_MANUAL_RESULT="pass")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "manual_claim_forbidden_in_ci")
        self.assertFalse(self.make_log.exists())

    def test_ci_rejects_unbound_or_mismatched_control_provenance(self) -> None:
        result, receipt = self._run(OPENBRIDGE_GITHUB_WORKFLOW_SHA="f" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "github_provenance_invalid")
        self.assertFalse(self.make_log.exists())

    def test_ci_protected_main_authorization_cannot_claim_a_reviewer(self) -> None:
        result, receipt = self._run(
            OPENBRIDGE_GITHUB_TARGET_AUTHORIZATION="protected_main",
            OPENBRIDGE_GITHUB_APPROVED_BY="trishan-lunr",
            OPENBRIDGE_GITHUB_PULL_REQUEST_NUMBER="",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "github_provenance_invalid")
        self.assertFalse(self.make_log.exists())

    def test_off_mac_host_fails_before_builds(self) -> None:
        result, receipt = self._run(FAKE_OPERATING_SYSTEM="Linux")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "unsupported_operating_system")
        self.assertEqual(receipt["overall_result"], "fail")
        self.assertFalse(self.make_log.exists())

    def test_dirty_worktree_fails_before_builds(self) -> None:
        (self.repository / "untracked.txt").write_text("dirty\n", encoding="utf-8")

        result, receipt = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "worktree_not_clean")
        self.assertIs(receipt["clean_worktree"], False)
        self.assertFalse(self.make_log.exists())

    def test_clean_head_change_during_proof_is_rejected(self) -> None:
        (self.repository / "alternate.txt").write_text("alternate\n", encoding="utf-8")
        self._git("add", "alternate.txt")
        self._git("-c", "commit.gpgsign=false", "commit", "-qm", "alternate")
        alternate_sha = self._git("rev-parse", "HEAD").stdout.strip()
        self._git("checkout", "-q", self.commit_sha)

        result, receipt = self._run(FAKE_SWITCH_HEAD=alternate_sha)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "target_commit_changed_during_proof")
        self.assertIs(receipt["clean_worktree"], False)

    def test_successful_command_without_test_count_is_rejected(self) -> None:
        result, receipt = self._run(FAKE_OMIT_TEST_COUNTS="swift")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "swift_test_count_unavailable")
        self.assertEqual(receipt["checks"]["swift_tests"], "pass")
        self.assertEqual(receipt["overall_result"], "fail")

    def test_python_syntax_failure_stops_before_unit_tests(self) -> None:
        result, receipt = self._run(FAKE_FAIL_MAKE_TARGET="python-syntax")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "python_syntax_failed")
        self.assertEqual(receipt["checks"]["python_tests"], "fail")
        self.assertEqual(receipt["overall_result"], "fail")
        self.assertEqual(
            self.make_log.read_text(encoding="utf-8").splitlines(),
            ["python-syntax"],
        )
        self.assertFalse(self.launch_environment_log.exists())

    def test_real_model_failure_cannot_be_reported_as_a_pass(self) -> None:
        result, receipt = self._run(FAKE_FAIL_MODEL="parakeet")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "parakeet_source_runtime_failed")
        self.assertEqual(receipt["checks"]["parakeet_source_runtime"], "fail")
        self.assertEqual(receipt["checks"]["gemma_source_runtime"], "not_run")
        self.assertEqual(receipt["overall_result"], "fail")
        self.assertFalse(self.launch_environment_log.exists())

    def test_model_subprocess_does_not_inherit_injection_or_cloud_variables(self) -> None:
        result, _ = self._run(
            PYTHONPATH="/tmp/injected-python",
            APP_ENGINE_PYTHON="/tmp/injected-engine",
            OPENAI_API_KEY="must-not-reach-model",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        sandbox_log = self.sandbox_log.read_text(encoding="utf-8")
        self.assertNotIn("injected-python", sandbox_log)
        self.assertNotIn("injected-engine", sandbox_log)
        self.assertNotIn("must-not-reach-model", sandbox_log)

    def test_unapproved_gemma_cache_revision_fails_closed(self) -> None:
        extra_revision = (
            self.account_home
            / "Library"
            / "Caches"
            / "OpenBridge"
            / "mac-proof"
            / "huggingface"
            / "hub"
            / "models--mlx-community--gemma-3-4b-it-qat-4bit"
            / "snapshots"
            / ("f" * 40)
        )
        extra_revision.mkdir()

        result, receipt = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "pinned_model_cache_invalid")
        self.assertFalse(self.sandbox_log.exists())

    def test_expected_sha_must_be_exact(self) -> None:
        result, receipt = self._run(OPENBRIDGE_EXPECTED_SHA="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HEAD does not match", result.stderr)
        self.assertEqual(receipt, {})

    def test_real_proof_cannot_reduce_survival_interval_to_zero(self) -> None:
        result, receipt = self._run(OPENBRIDGE_PROOF_TESTING="0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires at least five seconds", result.stderr)
        self.assertEqual(receipt, {})

    def test_developer_scenario_id_is_sanitized(self) -> None:
        result, receipt = self._run(
            "developer_manual",
            OPENBRIDGE_MANUAL_SCENARIO_ID="Primary journey with spaces",
            OPENBRIDGE_MANUAL_RESULT="pass",
            OPENBRIDGE_MANUAL_CONFIRMATION=f"observed:{self.commit_sha}",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["failure_reason"], "manual_scenario_invalid")
        self.assertIsNone(receipt["manual_launch_smoke"]["scenario_id"])

    def test_real_mode_uses_fixed_tools_and_clears_injection_variables(self) -> None:
        source = SCRIPT_SOURCE.read_text(encoding="utf-8")
        real_mode = source.split('if [ "$TEST_MODE_INPUT" = "0" ]; then', 1)[1].split(
            "else", 1
        )[0]

        self.assertIn('PATH="$TRUSTED_SYSTEM_PATH"', real_mode)
        for assignment in (
            'GIT_BIN="/usr/bin/git"',
            'MAKE_BIN="/usr/bin/make"',
            'SWIFT_BIN="/usr/bin/swift"',
            'CODESIGN_BIN="/usr/bin/codesign"',
            'OPEN_BIN="/usr/bin/open"',
            'ID_BIN="/usr/bin/id"',
            'UNAME_BIN="/usr/bin/uname"',
            'SW_VERS_BIN="/usr/bin/sw_vers"',
            'XCODEBUILD_BIN="/usr/bin/xcodebuild"',
            'SANDBOX_EXEC_BIN="/usr/bin/sandbox-exec"',
            'RECEIPT_PYTHON_BIN="/usr/bin/python3"',
        ):
            self.assertIn(assignment, real_mode)
        for variable in (
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "MAKEFLAGS",
            "MFLAGS",
            "PYTHON",
            "APP_ENGINE_PYTHON",
            "PYTHONPATH",
            "DEVELOPER_DIR",
            "SDKROOT",
            "SWIFT_EXEC",
        ):
            self.assertRegex(real_mode, rf"unset[^\n]*\b{variable}\b")

        self.assertIn('proof_git() {', source)
        self.assertIn('run_make() {', source)
        self.assertIn('run_swift() {', source)
        self.assertGreaterEqual(source.count('"$ENV_BIN" -i'), 5)
        self.assertNotIn("resolve_test_tool", real_mode)
        self.assertIn(
            'APPROVED_RUNTIME_ROOT="/Library/Application Support/OpenBridge/mac-proof-runtime"',
            source,
        )
        self.assertIn(
            'APPROVED_PYTHON_BASE="/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14"',
            source,
        )
        self.assertIn('APP_ENGINE_PYTHON="$model_python"', source)
        self.assertIn('PYTHON="$model_python"', source)
        self.assertIn('runtime_lock="$REPOSITORY_ROOT/requirements-lock.txt"', source)
        self.assertIn('sys.version_info[:2] != (3, 14)', source)
        self.assertGreaterEqual(source.count('proof_git -C "$CONTROL_REPOSITORY_ROOT"'), 4)

    def test_approved_python_path_is_quoted_and_runtime_rejects_extra_packages(self) -> None:
        makefile = MAKEFILE_SOURCE.read_text(encoding="utf-8")
        self.assertEqual(makefile.count('"$(APP_ENGINE_PYTHON)" -m'), 3)
        self.assertIn('"$(APP_ENGINE_PYTHON)" scripts/run_engine_tests.py', makefile)
        self.assertNotIn("\t$(APP_ENGINE_PYTHON) -m", makefile)

        approved_path = (
            "/Library/Application Support/OpenBridge/"
            "mac-proof-runtime/venv/bin/python"
        )
        dry_run = subprocess.run(
            [
                "make",
                "-n",
                "python-test",
                f"APP_ENGINE_PYTHON={approved_path}",
            ],
            cwd=MAKEFILE_SOURCE.parent,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
        # GNU Make adds Entering/Leaving-directory lines when this test is
        # itself launched by Make; select only the recipes under test.
        commands = [
            line
            for line in dry_run.stdout.splitlines()
            if line.startswith(f'"{approved_path}" ')
        ]
        self.assertEqual(len(commands), 2, dry_run.stdout)
        self.assertTrue(all(command.startswith(f'"{approved_path}" ') for command in commands))
        self.assertIn("scripts/run_engine_tests.py", commands[0])

        source = SCRIPT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('permitted_bootstrap = {"pip"}', source)
        self.assertIn(
            "unexpected = set(installed) - set(expected) - permitted_bootstrap",
            source,
        )

        runner_doc = RUNNER_DOC_SOURCE.read_text(encoding="utf-8")
        self.assertIn('-m venv --clear "$runtime_root/venv"', runner_doc)

    def test_source_ci_checks_out_and_records_exact_event_source_sha(self) -> None:
        workflow = CI_WORKFLOW_SOURCE.read_text(encoding="utf-8")
        source_expression = (
            "${{ github.event_name == 'pull_request' && "
            "github.event.pull_request.head.sha || github.sha }}"
        )
        python_job = workflow[
            workflow.index("\n  python:") : workflow.index("\n  swift:")
        ]
        swift_job = workflow[workflow.index("\n  swift:") :]

        for job in (python_job, swift_job):
            with self.subTest(job=job.splitlines()[1].strip()):
                self.assertIn(f"ref: {source_expression}", job)
                self.assertIn(f"OPENBRIDGE_CI_SOURCE_SHA: {source_expression}", job)
                self.assertIn("persist-credentials: false", job)
                self.assertIn("- name: Verify and record exact source SHA", job)
                self.assertIn('actual_sha="$(git rev-parse HEAD)"', job)
                self.assertIn(
                    '[[ "$actual_sha" != "$OPENBRIDGE_CI_SOURCE_SHA" ]]', job
                )
                self.assertIn("Exact Source CI SHA:", job)

    def test_release_source_proof_is_main_only_and_binds_candidate_without_write_authority(self) -> None:
        workflow = (CI_WORKFLOW_SOURCE.parent / "release-source-proof.yml").read_text()
        self.assertIn("run-name: Release source proof ${{ inputs.source_sha }}", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("checks: write", workflow)
        self.assertNotIn("continue-on-error", workflow)
        for job in workflow.split("runs-on:")[1:]:
            self.assertIn("ref: ${{ inputs.source_sha }}", job)
            self.assertIn("persist-credentials: false", job)
            self.assertIn('actual_sha="$(git rev-parse HEAD)"', job)
            self.assertIn('[[ "$actual_sha" != "$OPENBRIDGE_CI_SOURCE_SHA" ]]', job)
        self.assertEqual(workflow.count("if: github.ref == 'refs/heads/main'"), 2)

    def test_workflow_uses_protected_control_checkout_and_exact_candidate(self) -> None:
        workflow = WORKFLOW_SOURCE.read_text(encoding="utf-8")

        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("target_sha:", workflow)
        self.assertIn('GITHUB_REF" != "refs/heads/main"', workflow)
        self.assertIn('CONTROL_SHA" != "$WORKFLOW_SHA', workflow)
        self.assertIn("path: proof-control", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("path: source", workflow)
        self.assertIn("ref: ${{ steps.source.outputs.sha }}", workflow)
        self.assertIn("run: ./proof-control/scripts/mac_dev_proof.sh", workflow)
        self.assertIn("OPENBRIDGE_TARGET_REPOSITORY: ${{ github.workspace }}/source", workflow)
        self.assertIn("OPENBRIDGE_GITHUB_WORKFLOW_SHA: ${{ github.workflow_sha }}", workflow)
        self.assertIn("OPENBRIDGE_GITHUB_CONTROL_SHA: ${{ github.sha }}", workflow)
        self.assertIn("listPullRequestsAssociatedWithCommit", workflow)
        self.assertIn("mainBranch.protected !== true", workflow)
        self.assertIn(
            "mainBranch.commit.sha !== process.env.CONTROL_SHA", workflow
        )
        self.assertIn(
            "mainBranch.commit.sha !== process.env.WORKFLOW_SHA", workflow
        )
        self.assertIn("review.commit_id === target", workflow)
        self.assertIn("['trishan-lunr', 'alex-lunr']", workflow)
        self.assertIn("checks: write", workflow)
        self.assertIn("OPENBRIDGE_GITHUB_CHECK_RUN_ID:", workflow)
        self.assertIn("name: 'mac-mini-proof'", workflow)
        self.assertIn("listJobsForWorkflowRunAttempt", workflow)
        self.assertIn("${runUrl}/job/${proofJobId}", workflow)
        self.assertIn("include-hidden-files: true", workflow)
        self.assertIn(
            "path: source/.build/mac-mini-proof/mac-mini-proof-${{ steps.source.outputs.sha }}.json",
            workflow,
        )
        self.assertNotIn("make setup", workflow)
        self.assertIn(
            "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2",
            workflow,
        )
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2",
            workflow,
        )
        self.assertIn(
            "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b # v7.1.0",
            workflow,
        )

    def test_workflow_revalidates_control_after_queue_and_before_success(self) -> None:
        workflow = WORKFLOW_SOURCE.read_text(encoding="utf-8")
        queued_check = workflow.index(
            "- name: Revalidate live protected control after Mac queue"
        )
        control_checkout = workflow.index("- name: Check out protected proof control")
        candidate_checkout = workflow.index("- name: Check out exact candidate source")
        self.assertLess(queued_check, control_checkout)
        self.assertLess(queued_check, candidate_checkout)

        mac_job = workflow[
            workflow.index("\n  mac-mini-proof:") : workflow.index(
                "\n  finalize-target-check:"
            )
        ]
        self.assertIn("permissions:\n      contents: read", mac_job)
        self.assertIn("pull-requests: read", mac_job)
        self.assertNotRegex(mac_job, r"(?m)^\s+[a-z-]+:\s+write\s*$")

        queued_block = workflow[queued_check:control_checkout]
        self.assertIn(
            "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b",
            queued_block,
        )
        self.assertIn("mainBranch.protected !== true", queued_block)
        self.assertIn(
            "mainBranch.commit.sha !== process.env.CONTROL_SHA", queued_block
        )
        self.assertIn(
            "mainBranch.commit.sha !== process.env.WORKFLOW_SHA", queued_block
        )

        finalizer = workflow[workflow.index("finalize-target-check:") :]
        self.assertIn("permissions:\n      actions: read\n      contents: read", finalizer)
        self.assertIn("pull-requests: read", finalizer)
        self.assertIn("mainBranch.protected !== true", finalizer)
        self.assertIn(
            "mainBranch.commit.sha !== process.env.CONTROL_SHA", finalizer
        )
        self.assertIn(
            "mainBranch.commit.sha !== process.env.WORKFLOW_SHA", finalizer
        )
        self.assertIn(
            "proofSucceeded && authorizationFresh && jobBindingFailure === ''",
            finalizer,
        )
        self.assertIn("finalizerFailures.push(authorizationFailure)", finalizer)
        self.assertIn("core.setFailed(finalizerFailure)", finalizer)

    def test_workflow_revalidates_live_pr_and_latest_review_state(self) -> None:
        workflow = WORKFLOW_SOURCE.read_text(encoding="utf-8")
        queued_start = workflow.index(
            "- name: Revalidate live protected control after Mac queue"
        )
        queued_end = workflow.index("- name: Resolve exact candidate identity")
        queued_block = workflow[queued_start:queued_end]
        finalizer = workflow[workflow.index("finalize-target-check:") :]

        for live_check in (queued_block, finalizer):
            self.assertIn("github.rest.pulls.get", live_check)
            self.assertIn("pull.state !== 'open'", live_check)
            self.assertIn("pull.base.ref !== 'main'", live_check)
            self.assertIn("pull.head.sha !== target", live_check)
            self.assertIn("github.rest.pulls.listReviews", live_check)
            self.assertIn(
                "if (login && authorizedReviewers.has(login))", live_check
            )
            self.assertIn(
                "review.state === 'APPROVED' && review.commit_id === target",
                live_check,
            )
            self.assertIn("!currentApprovers.includes(approvedBy)", live_check)

        self.assertNotIn(
            "authorizedReviewers.has(login) && review.commit_id === target",
            workflow,
        )
        self.assertGreaterEqual(workflow.count("DISMISSED"), 1)
        self.assertLess(
            finalizer.index("github.rest.pulls.get"),
            finalizer.index("github.rest.checks.update"),
        )

    def test_workflow_embedded_github_scripts_have_valid_javascript(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest(
                "system Node.js is optional on Mac proof hosts; normal CI validates workflow JavaScript"
            )
        scripts = _extract_github_scripts(
            WORKFLOW_SOURCE.read_text(encoding="utf-8")
        )

        self.assertGreaterEqual(len(scripts), 4)
        for step_name, script in scripts.items():
            # github-script executes the body as an AsyncFunction, so wrap it
            # before parsing to allow the same top-level await/return syntax.
            wrapped = f"(async function () {{\n{script}\n}});\n"
            result = subprocess.run(
                [node, "--check"],
                input=wrapped,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, f"{step_name}: {result.stderr}")

    def test_finalizer_completes_failure_when_job_binding_is_unavailable(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest(
                "system Node.js is optional on Mac proof hosts; normal CI exercises workflow JavaScript"
            )
        scripts = _extract_github_scripts(
            WORKFLOW_SOURCE.read_text(encoding="utf-8")
        )
        script = scripts["Publish exact-target conclusion"]
        wrapper = (
            """
(async function () {
  const updates = [];
  const failures = [];
  const github = {
    paginate: async () => {
      if (process.env.BINDING_MODE === 'api_error') {
        throw new Error('job lookup unavailable');
      }
      if (process.env.BINDING_MODE === 'multiple') {
        return [
          {name: 'mac-mini-proof', id: 101},
          {name: 'mac-mini-proof', id: 102},
        ];
      }
      return [];
    },
    rest: {
      actions: {listJobsForWorkflowRunAttempt: () => {}},
      checks: {update: async (input) => updates.push(input)},
      repos: {
        getBranch: async () => ({
          data: {protected: true, commit: {sha: process.env.CONTROL_SHA}},
        }),
      },
    },
  };
  const core = {setFailed: (message) => failures.push(message)};
  const context = {
    repo: {owner: 'lunr-studio', repo: 'Openbridge-Dev'},
    runId: 456,
    serverUrl: 'https://github.com',
  };
"""
            + script
            + """
  process.stdout.write(JSON.stringify({updates, failures}));
})().catch((error) => {
  process.stderr.write(String(error));
  process.exitCode = 1;
});
"""
        )

        for mode in ("zero", "multiple", "api_error"):
            with self.subTest(mode=mode):
                environment = os.environ.copy()
                environment.update(
                    {
                        "BINDING_MODE": mode,
                        "CHECK_RUN_ID": "123",
                        "PROOF_RESULT": "success",
                        "GITHUB_RUN_ATTEMPT": "1",
                        "CONTROL_SHA": "a" * 40,
                        "WORKFLOW_SHA": "a" * 40,
                        "TARGET_SHA": "a" * 40,
                        "TARGET_AUTHORIZATION": "protected_main",
                        "PULL_REQUEST_NUMBER": "",
                        "APPROVED_BY": "",
                    }
                )
                result = subprocess.run(
                    [node],
                    input=wrapper,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                outcome = json.loads(result.stdout)
                self.assertEqual(len(outcome["updates"]), 1)
                update = outcome["updates"][0]
                self.assertEqual(update["status"], "completed")
                self.assertEqual(update["conclusion"], "failure")
                self.assertIn("proof evidence was rejected", update["output"]["summary"])
                self.assertEqual(
                    update["details_url"],
                    "https://github.com/lunr-studio/Openbridge-Dev/actions/runs/456",
                )
                self.assertTrue(outcome["failures"])

    def test_proof_trust_root_paths_have_codeowners_and_activation_controls(self) -> None:
        codeowners = CODEOWNERS_SOURCE.read_text(encoding="utf-8")
        for protected_path in (
            "/.github/CODEOWNERS",
            "/.github/workflows/mac-mini-proof.yml",
            "/scripts/mac_dev_proof.sh",
            "/scripts/tests/test_mac_dev_proof.py",
            "/requirements-lock.txt",
            "/docs/setup/MAC_MINI_PROOF_RUNNER.md",
        ):
            self.assertIn(protected_path, codeowners)

        runner_doc = RUNNER_DOC_SOURCE.read_text(encoding="utf-8")
        self.assertIn("require review from Code Owners", runner_doc)
        self.assertIn("no bypass", runner_doc)
        self.assertIn("selected workflow", runner_doc)
        self.assertIn(
            "lunr-studio/Openbridge-Dev/.github/workflows/"
            "mac-mini-proof.yml@refs/heads/main",
            runner_doc,
        )
        self.assertIn("openbridge-franklin-mac-dev-proof-v1", runner_doc)

        ci_workflow = CI_WORKFLOW_SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            ci_workflow.count(
                "actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4"
            ),
            2,
        )
        self.assertIn(
            "actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5",
            ci_workflow,
        )


if __name__ == "__main__":
    unittest.main()
