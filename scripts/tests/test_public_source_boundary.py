"""Application-source publication boundary, derived from OSS-02/OSS-05."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check_public_source.py"
spec = importlib.util.spec_from_file_location("public_source_boundary", SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PublicSourceBoundaryTests(unittest.TestCase):
    def test_current_and_old_built_outputs_are_excluded(self):
        paths = {"OpenBridge.dmg", "archive/Beta-1.DMG", "dist/OpenBridge.app/Contents/MacOS/OpenBridge", ".build/debug/OpenBridgeApp"}
        self.assertEqual(policy.excluded_paths(paths), sorted(paths))

    def test_website_and_private_configuration_are_excluded(self):
        paths = {"src/App.jsx", "public/tester-config.json", "server.mjs", "package.json", "package-lock.json", "Dockerfile", "deploy/cloud-run.env.yaml", "cloud-run.env.yaml", ".env", "credentials/signing.p12", "key.p8", "secret.pem", "keychain/private.key"}
        self.assertEqual(policy.excluded_paths(paths), sorted(paths))

    def test_application_resources_and_nested_evaluation_inputs_remain_allowed(self):
        paths = {"Sources/OpenBridgeApp/Resources/icon.png", "Sources/OpenBridgeUI/Resources/Fonts/font.woff2", "evals/cloud/package.json", "evals/cloud/package-lock.json", "evals/cloud/fixtures/synthetic.wav", "Resources/OpenBridge.entitlements", "docs/setup/env.example.md", "requirements-lock.txt", "openbridge_engine/model_snapshots.lock.json"}
        self.assertEqual(policy.excluded_paths(paths), [])

    def test_generated_runtime_and_model_weights_are_excluded(self):
        paths = {".venv/bin/python", "models/model.safetensors", "weights/model.gguf", "node_modules/example/index.js", "output/log.txt", ".local-evidence/report.json"}
        self.assertEqual(policy.excluded_paths(paths), sorted(paths))

    def test_deleted_dmg_is_still_found_in_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
            git("init", "-q")
            (root / "old.dmg").write_bytes(b"synthetic test bytes, not a real DMG")
            git("add", "old.dmg")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
            git("rm", "old.dmg")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "remove")
            self.assertEqual(policy.excluded_paths(policy.tracked_paths(root)), [])
            self.assertEqual(policy.excluded_paths(policy.tracked_paths(root, True)), ["old.dmg"])

    def test_cli_returns_failure_for_tracked_app_bundle(self):
        import sys
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True)
            app = root / "OpenBridge.app" / "Contents" / "Info.plist"
            app.parent.mkdir(parents=True)
            app.write_text("synthetic")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True, capture_output=True)
            result = subprocess.run([sys.executable, str(SCRIPT), "--repo", str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("OpenBridge.app/Contents/Info.plist", result.stdout)


if __name__ == "__main__":
    unittest.main()
