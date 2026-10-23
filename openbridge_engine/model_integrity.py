"""Pinned production models. Never select model bytes by modification time.

The lock is shipped inside the signed app, copied byte-for-byte from the private
owner-controlled release lock. Installation never removes a legacy model tree.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import tempfile
import uuid

from .model_snapshot_verifier import (
    SnapshotError, authenticate_snapshot, load_lock, materialize_snapshot,
    validate_model_lock, require_huggingface_source_layout,
)

LOCK_PATH = Path(__file__).with_name("model_snapshots.lock.json")
ALIASES = {"parakeet-tdt-0.6b-v3-mlx-bf16": "parakeet"}


class ModelIntegrityError(RuntimeError):
    pass


def model_key(identifier: str) -> str | None:
    lock, _ = load_lock(LOCK_PATH)
    if identifier in ALIASES:
        return ALIASES[identifier]
    return next((key for key, value in lock["models"].items()
                 if value["repository"] == identifier), None)


def model_spec(key: str) -> dict:
    lock, _ = load_lock(LOCK_PATH)
    return validate_model_lock(lock, key)[0]


def authenticate(key: str, path: Path, *, materialized: bool = True) -> Path:
    try:
        # Reject symlinked ancestors as well as files. A normal HF snapshot may
        # contain blob symlinks, but only the installer may materialize those.
        if any(parent.is_symlink() for parent in (path, *path.parents)):
            raise SnapshotError("model path contains a symlink")
        spec = model_spec(key)
        if path.parent.name == "snapshots" and path.name != spec["revision"]:
            raise SnapshotError("model snapshot has the wrong revision")
        authenticate_snapshot(LOCK_PATH, key, path, require_materialized=materialized)
        return path
    except (SnapshotError, OSError) as exc:
        raise ModelIntegrityError(
            f"The {key} model could not be verified. Reinstall this model in Models & Performance. "
            f"Existing files were preserved. Details: {exc}"
        ) from exc


def installed_path(key: str, model_root: Path) -> Path:
    return model_root / "verified-snapshots" / key / model_spec(key)["revision"]


def resolve(key: str, model_root: Path, *, legacy: list[Path] = (), verify: bool = True) -> Path:
    preferred = installed_path(key, model_root)
    for path in (preferred, *legacy):
        if path.exists() or path.is_symlink():
            return authenticate(key, path) if verify else path
    raise ModelIntegrityError(f"The verified {key} model is not installed. Install it in Models & Performance.")


@contextmanager
def installation_lock(directory: Path):
    if any(parent.is_symlink() for parent in (directory, *directory.parents)):
        raise ModelIntegrityError("Model installation path contains a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    fd = os.open(directory / ".install.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def install(key: str, model_root: Path, *, force: bool = False, downloader=None,
            local_sources: tuple[Path, ...] = (), download_allowed: bool = True) -> Path:
    spec = model_spec(key)
    destination = installed_path(key, model_root)
    with installation_lock(destination.parent):
        if destination.exists() or destination.is_symlink():
            try:
                return authenticate(key, destination)
            except ModelIntegrityError:
                if not force:
                    raise
        source = next((path for path in local_sources if path.exists() or path.is_symlink()), None)
        if source is None and (not download_allowed or os.environ.get("HF_HUB_OFFLINE", "").lower() in {"1", "true", "yes"}):
            raise ModelIntegrityError("The verified model is missing and offline mode forbids downloading it.")
        if source is None and downloader is None:
            from huggingface_hub import snapshot_download
            downloader = snapshot_download
        with tempfile.TemporaryDirectory(prefix=".model-install-", dir=destination.parent) as temporary:
            stage = Path(temporary)
            downloaded = source is None
            if downloaded:
                source = Path(downloader(repo_id=spec["repository"], revision=spec["revision"],
                                         cache_dir=str(stage / "hub")))
            try:
                if downloaded:
                    source.relative_to(stage / "hub")
                require_huggingface_source_layout(source, spec)
                materialize_snapshot(LOCK_PATH, key, source, stage / "verified")
                # Detect source substitution between authentication and promotion.
                authenticate(key, stage / "verified")
                # The proof materializer seals directories read-only. macOS
                # requires owner-write on the directory itself to rename it.
                (stage / "verified").chmod(0o700)
                quarantine = None
                if destination.exists() or destination.is_symlink():
                    quarantine = destination.with_name(f"{destination.name}.unverified-{uuid.uuid4().hex}")
                    if not destination.is_symlink():
                        destination.chmod(0o700)
                    os.rename(destination, quarantine)
                try:
                    os.rename(stage / "verified", destination)
                    authenticate(key, destination)
                except BaseException:
                    # Never discard either the old or new model on failure.
                    if destination.exists():
                        os.rename(destination, destination.with_name(f"{destination.name}.failed-{uuid.uuid4().hex}"))
                    if quarantine is not None:
                        os.rename(quarantine, destination)
                    raise
            except (SnapshotError, OSError, ValueError) as exc:
                raise ModelIntegrityError(f"Model installation could not be verified; prior files preserved: {exc}") from exc
    return destination


def cached_sources(key: str, hub_roots: tuple[Path, ...]) -> tuple[Path, ...]:
    spec = model_spec(key)
    return tuple(root / ("models--" + spec["repository"].replace("/", "--")) /
                 "snapshots" / spec["revision"] for root in hub_roots)
