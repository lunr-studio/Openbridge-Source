from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from openbridge_engine import common, local_llm, model_integrity as integrity


class ModelIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.model_root = self.root / "models"
        self.payload = {"config.json": b'{}', "model.bin": b"approved weights"}
        files = [{"path": name, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                 for name, data in sorted(self.payload.items())]
        self.lock = {"schema_version": 1, "hash_algorithm": "sha256", "models": {
            key: {"repository": f"example/{key}", "revision": "a" * 40,
                  "file_count": len(files), "total_bytes": sum(len(v) for v in self.payload.values()),
                  "files": files} for key in ("parakeet", "gemma")}}
        lock_path = self.root / "lock.json"
        lock_path.write_text(json.dumps(self.lock))
        patcher = mock.patch.object(integrity, "LOCK_PATH", lock_path)
        patcher.start()
        self.addCleanup(patcher.stop)
        environment = mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": "0"})
        environment.start()
        self.addCleanup(environment.stop)
        self.downloads = []

    def download(self, **kwargs):
        self.downloads.append(kwargs)
        repo = Path(kwargs["cache_dir"]) / ("models--" + kwargs["repo_id"].replace("/", "--"))
        source = repo / "snapshots" / kwargs["revision"]
        source.mkdir(parents=True)
        (repo / "blobs").mkdir()
        for name, data in self.payload.items():
            blob = repo / "blobs" / hashlib.sha256(data).hexdigest()
            blob.write_bytes(data)
            (source / name).symlink_to(blob)
        return str(source)

    def install(self, **kwargs):
        destination = integrity.install("parakeet", self.model_root, downloader=self.download, **kwargs)
        for file in destination.iterdir():
            file.chmod(0o600)
        return destination

    def test_install_pins_revision_and_reuses_only_authenticated_copy(self):
        destination = self.install()
        self.assertEqual(self.downloads[0]["revision"], "a" * 40)
        self.assertEqual(self.downloads[0]["repo_id"], "example/parakeet")
        self.assertFalse((destination / "model.bin").is_symlink())
        self.assertEqual(integrity.resolve("parakeet", self.model_root), destination)
        self.assertEqual(self.install(), destination)
        self.assertEqual(len(self.downloads), 1)

    def test_corrupt_missing_extra_and_symlink_files_fail(self):
        mutations = {
            "same-size substitution": lambda path: (path / "model.bin").write_bytes(b"x" * len(self.payload["model.bin"])),
            "missing file": lambda path: (path / "config.json").unlink(),
            "extra file": lambda path: (path / "unapproved.py").write_text("bad"),
            "extra directory": lambda path: (path / "extra").mkdir(),
            "symlink": lambda path: ((path / "config.json").unlink(), (path / "config.json").symlink_to(self.root / "lock.json")),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                root = self.root / label
                destination = integrity.install("parakeet", root, downloader=self.download)
                for file in destination.iterdir():
                    file.chmod(0o600)
                mutate(destination)
                with self.assertRaises(integrity.ModelIntegrityError):
                    integrity.resolve("parakeet", root)

    def test_wrong_revision_and_symlinked_ancestors_fail(self):
        destination = self.install()
        wrong = self.root / "snapshots" / ("b" * 40)
        wrong.parent.mkdir()
        destination.rename(wrong)
        with self.assertRaisesRegex(integrity.ModelIntegrityError, "wrong revision"):
            integrity.authenticate("parakeet", wrong)
        link = self.root / "linked"
        link.symlink_to(wrong.parent)
        with self.assertRaisesRegex(integrity.ModelIntegrityError, "symlink"):
            integrity.authenticate("parakeet", link / wrong.name)

    def test_failed_force_download_preserves_previous_model(self):
        destination = self.install()
        (destination / "model.bin").write_bytes(b"old corrupt content")
        def corrupt_download(**kwargs):
            source = Path(self.download(**kwargs))
            (source / "config.json").write_bytes(b"bad")
            return str(source)
        with self.assertRaises(integrity.ModelIntegrityError):
            integrity.install("parakeet", self.model_root, force=True, downloader=corrupt_download)
        self.assertEqual((destination / "model.bin").read_bytes(), b"old corrupt content")

    def test_force_repair_quarantines_previous_files(self):
        destination = self.install()
        (destination / "model.bin").write_bytes(b"preserve me")
        self.install(force=True)
        quarantined = list(destination.parent.glob("*.unverified-*"))
        self.assertEqual(len(quarantined), 1)
        self.assertEqual((quarantined[0] / "model.bin").read_bytes(), b"preserve me")
        integrity.authenticate("parakeet", destination)

    def test_mutation_before_promotion_fails(self):
        real_materialize = integrity.materialize_snapshot
        def mutate_after_copy(*args):
            result = real_materialize(*args)
            (args[3] / "config.json").chmod(0o600)
            (args[3] / "config.json").write_bytes(b"!!")
            return result
        with mock.patch.object(integrity, "materialize_snapshot", side_effect=mutate_after_copy):
            with self.assertRaises(integrity.ModelIntegrityError):
                self.install()
        self.assertFalse(integrity.installed_path("parakeet", self.model_root).exists())

    def test_offline_missing_model_makes_no_download(self):
        with mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": "1"}):
            with self.assertRaisesRegex(integrity.ModelIntegrityError, "offline"):
                self.install()
        self.assertEqual(self.downloads, [])

    def test_newer_cache_directory_cannot_override_locked_revision(self):
        hub = self.root / "hub"
        snapshots = hub / "models--example--gemma" / "snapshots"
        approved = snapshots / ("a" * 40)
        approved.mkdir(parents=True)
        newer = snapshots / ("f" * 40)
        newer.mkdir()
        os.utime(newer, (9999999999, 9999999999))
        with mock.patch.object(common, "HF_CACHE_ROOT", hub):
            self.assertEqual(common.find_local_hf_snapshot("example/gemma"), approved)

    def test_parakeet_checks_integrity_before_importing_loader(self):
        common._load_parakeet_mlx_model.cache_clear()
        with mock.patch.object(integrity, "authenticate", side_effect=integrity.ModelIntegrityError("reinstall")) as check:
            with self.assertRaisesRegex(integrity.ModelIntegrityError, "reinstall"):
                common._load_parakeet_mlx_model("/synthetic/not-loaded")
        check.assert_called_once_with("parakeet", Path("/synthetic/not-loaded"))

    def test_gemma_checks_mutated_path_before_importing_loader(self):
        local_llm._load_mlx_model.cache_clear()
        with mock.patch.object(integrity, "authenticate", side_effect=integrity.ModelIntegrityError("reinstall")) as check:
            with self.assertRaisesRegex(integrity.ModelIntegrityError, "reinstall"):
                local_llm._load_mlx_model("/synthetic/not-loaded", "gemma")
        check.assert_called_once_with("gemma", Path("/synthetic/not-loaded"))

    def test_offline_adoption_authenticates_and_preserves_shared_cache(self):
        source = Path(self.download(repo_id="example/parakeet", revision="a" * 40,
                                    cache_dir=str(self.root / "legacy-hub")))
        with mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": "1"}):
            destination = integrity.install("parakeet", self.model_root,
                local_sources=(source,), downloader=mock.Mock(side_effect=AssertionError("network")))
        self.assertTrue((source / "model.bin").is_symlink())
        self.assertFalse((destination / "model.bin").is_symlink())
        integrity.authenticate("parakeet", destination)

    def test_wrong_download_revision_and_outside_source_are_rejected(self):
        def wrong_revision(**kwargs):
            return self.download(**{**kwargs, "revision": "b" * 40})
        with self.assertRaises(integrity.ModelIntegrityError):
            integrity.install("parakeet", self.model_root, downloader=wrong_revision)
        with self.assertRaises(integrity.ModelIntegrityError):
            integrity.install("parakeet", self.model_root, downloader=lambda **kw: self.root)
        self.assertFalse(integrity.installed_path("parakeet", self.model_root).exists())

    def test_status_recognizes_verified_gemma_without_loading(self):
        destination = integrity.install("gemma", self.model_root, downloader=self.download)
        with mock.patch.object(local_llm, "MODEL_ROOT", self.model_root):
            self.assertTrue(local_llm.mlx_model_cache_present("example/gemma"))
        self.assertTrue(destination.is_dir())
