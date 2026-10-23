#!/usr/bin/env python3
"""Authenticate one offline model snapshot against the release lock.

The release cache is an input, not an authority.  This verifier accepts only
the exact directory topology, file sizes, and SHA-256 values recorded in the
owner-controlled packager lock and emits a path-independent receipt on stdout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class SnapshotError(RuntimeError):
    """Raised when a snapshot cannot be authenticated."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SnapshotError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    require(actual == expected, f"{label} keys differ: expected {sorted(expected)}, got {sorted(actual)}")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError(f"model snapshot lock contains duplicate key: {key}")
        result[key] = value
    return result


def load_lock(path: Path) -> tuple[dict[str, Any], str]:
    require(path.is_file() and not path.is_symlink(), "model snapshot lock must be a regular file")
    try:
        lock_bytes = path.read_bytes()
        value = json.loads(lock_bytes, object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SnapshotError(f"could not read model snapshot lock: {exc}") from exc
    lock = require_mapping(value, "model snapshot lock")
    require_exact_keys(lock, {"schema_version", "hash_algorithm", "models"}, "model snapshot lock")
    require(type(lock.get("schema_version")) is int and lock["schema_version"] == 1,
            "model snapshot lock schema_version must be the integer 1")
    require(lock.get("hash_algorithm") == "sha256",
            "model snapshot lock hash_algorithm must be sha256")
    models = require_mapping(lock.get("models"), "model snapshot lock models")
    require(set(models) == {"parakeet", "gemma"},
            "model snapshot lock must contain exactly parakeet and gemma")
    return lock, hashlib.sha256(lock_bytes).hexdigest()


def validate_relative_path(value: Any, label: str) -> str:
    require(isinstance(value, str) and bool(value), f"{label} must be a non-empty string")
    require("\\" not in value and all(char.isprintable() for char in value),
            f"{label} must be a printable POSIX relative path")
    path = PurePosixPath(value)
    require(value not in {".", ".."} and bool(path.parts)
            and not path.is_absolute()
            and all(part not in {"", ".", ".."} for part in path.parts),
            f"{label} must remain beneath the snapshot root")
    require(path.as_posix() == value, f"{label} must use canonical POSIX spelling")
    return value


def validate_model_lock(lock: dict[str, Any], model_key: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    models = require_mapping(lock.get("models"), "model snapshot lock models")
    require(model_key in models, f"unknown locked model: {model_key}")
    model = require_mapping(models[model_key], f"model snapshot lock models.{model_key}")
    require_exact_keys(
        model,
        {"repository", "revision", "file_count", "total_bytes", "files"},
        f"model snapshot lock models.{model_key}",
    )
    require(isinstance(model.get("repository"), str) and bool(model["repository"]),
            f"locked {model_key} repository must be recorded")
    require(isinstance(model.get("revision"), str) and SHA_RE.fullmatch(model["revision"]) is not None,
            f"locked {model_key} revision must be a lowercase 40-character SHA")
    files_value = model.get("files")
    require(isinstance(files_value, list) and bool(files_value),
            f"locked {model_key} files must be a non-empty array")

    files: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_casefolded: set[str] = set()
    for index, value in enumerate(files_value):
        entry = require_mapping(value, f"locked {model_key} files[{index}]")
        require_exact_keys(entry, {"path", "size_bytes", "sha256"},
                           f"locked {model_key} files[{index}]")
        relative = validate_relative_path(entry.get("path"), f"locked {model_key} files[{index}].path")
        require(relative not in seen, f"locked {model_key} file path is duplicated: {relative}")
        require(relative.casefold() not in seen_casefolded,
                f"locked {model_key} file paths collide on a case-insensitive filesystem: {relative}")
        seen.add(relative)
        seen_casefolded.add(relative.casefold())
        size = entry.get("size_bytes")
        digest = entry.get("sha256")
        require(type(size) is int and size >= 0,
                f"locked {model_key} file {relative} has an invalid size")
        require(isinstance(digest, str) and SHA256_RE.fullmatch(digest) is not None,
                f"locked {model_key} file {relative} has an invalid SHA-256")
        files.append({"path": relative, "size_bytes": size, "sha256": digest})

    paths = [entry["path"] for entry in files]
    require(paths == sorted(paths), f"locked {model_key} files must be sorted by path")
    require(model.get("file_count") == len(files), f"locked {model_key} file_count is incorrect")
    require(model.get("total_bytes") == sum(entry["size_bytes"] for entry in files),
            f"locked {model_key} total_bytes is incorrect")
    return model, files


def inventory_tree(root: Path, *, require_materialized: bool) -> tuple[set[str], set[str]]:
    require(root.is_dir() and not root.is_symlink(), "model snapshot root must be a non-symlink directory")
    files: set[str] = set()
    directories: set[str] = set()
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as exc:
            raise SnapshotError(f"could not enumerate model snapshot: {exc}") from exc
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if entry.is_symlink():
                require(not require_materialized,
                        f"materialized model snapshot contains a symlink: {relative}")
                try:
                    is_file = entry.is_file(follow_symlinks=True)
                    is_directory = entry.is_dir(follow_symlinks=True)
                except OSError as exc:
                    raise SnapshotError(f"could not resolve model snapshot symlink {relative}: {exc}") from exc
                require(is_file and not is_directory,
                        f"model snapshot symlink is not a regular file: {relative}")
                files.add(relative)
            elif entry.is_dir(follow_symlinks=False):
                directories.add(relative)
                pending.append(path)
            elif entry.is_file(follow_symlinks=False):
                files.add(relative)
            else:
                raise SnapshotError(f"model snapshot contains an unsupported filesystem entry: {relative}")
    return files, directories


def sha256_file(path: Path, expected_size: int) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            before = os.fstat(handle.fileno())
            require(before.st_size == expected_size,
                    f"model snapshot file has the wrong size: {path.name}")
            while True:
                chunk = handle.read(8 * 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            after = os.fstat(handle.fileno())
    except OSError as exc:
        raise SnapshotError(f"could not hash model snapshot file {path.name}: {exc}") from exc
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
            f"model snapshot file changed while it was hashed: {path.name}")
    return digest.hexdigest()


def require_huggingface_source_layout(snapshot_root: Path, model: dict[str, Any]) -> Path:
    expected_cache_name = "models--" + model["repository"].replace("/", "--")
    require(snapshot_root.name == model["revision"]
            and snapshot_root.parent.name == "snapshots"
            and snapshot_root.parent.parent.name == expected_cache_name,
            "source snapshot path does not match the locked repository and revision")
    blobs = snapshot_root.parent.parent / "blobs"
    require(blobs.is_dir() and not blobs.is_symlink(),
            "source Hugging Face repository has no regular blobs directory")
    return blobs.resolve(strict=True)


def require_beneath(path: Path, root: Path, label: str) -> None:
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise SnapshotError(f"{label} escapes the approved Hugging Face blobs directory") from exc


def materialize_snapshot(
    manifest_path: Path,
    model_key: str,
    snapshot_root: Path,
    destination: Path,
) -> dict[str, Any]:
    """Copy only authenticated lock entries, then authenticate the exact copy."""
    source_receipt = authenticate_snapshot(manifest_path, model_key, snapshot_root)
    lock, _manifest_sha256 = load_lock(manifest_path)
    model, files = validate_model_lock(lock, model_key)
    blobs_root = require_huggingface_source_layout(snapshot_root, model)
    require(not destination.exists() and not destination.is_symlink(),
            "materialized snapshot destination must not already exist")
    try:
        destination.mkdir(mode=0o700, parents=False)
        for entry in files:
            relative = entry["path"]
            source = snapshot_root / Path(relative)
            if source.is_symlink():
                try:
                    opened_source = source.resolve(strict=True)
                except OSError as exc:
                    raise SnapshotError(f"could not resolve source model symlink {relative}: {exc}") from exc
                require_beneath(opened_source, blobs_root, f"source model symlink {relative}")
                require(opened_source.is_file() and not opened_source.is_symlink(),
                        f"source model symlink does not resolve to a regular blob: {relative}")
            else:
                require(source.is_file(), f"source model entry is not a regular file: {relative}")
                opened_source = source

            target = destination / Path(relative)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            digest = hashlib.sha256()
            copied_size = 0
            with opened_source.open("rb") as source_handle, target.open("xb") as target_handle:
                before = os.fstat(source_handle.fileno())
                while True:
                    chunk = source_handle.read(8 * 1024 * 1024)
                    if not chunk:
                        break
                    target_handle.write(chunk)
                    digest.update(chunk)
                    copied_size += len(chunk)
                target_handle.flush()
                os.fsync(target_handle.fileno())
                after = os.fstat(source_handle.fileno())
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                    == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                    f"source model file changed while copied: {relative}")
            require(copied_size == entry["size_bytes"] and digest.hexdigest() == entry["sha256"],
                    f"source model file changed after authentication: {relative}")
            target.chmod(0o400)
    except OSError as exc:
        raise SnapshotError(f"could not materialize model snapshot: {exc}") from exc

    for directory in sorted(
        (path for path in destination.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    ):
        directory.chmod(0o500)
    destination.chmod(0o500)
    copied_receipt = authenticate_snapshot(
        manifest_path, model_key, destination, require_materialized=True
    )
    require(copied_receipt == source_receipt,
            "materialized model snapshot differs from the authenticated source")
    return copied_receipt


def authenticate_snapshot(
    manifest_path: Path,
    model_key: str,
    snapshot_root: Path,
    *,
    require_materialized: bool = False,
) -> dict[str, Any]:
    lock, manifest_sha256 = load_lock(manifest_path)
    model, files = validate_model_lock(lock, model_key)
    actual_files, actual_directories = inventory_tree(
        snapshot_root, require_materialized=require_materialized
    )
    expected_files = {entry["path"] for entry in files}
    expected_directories = {
        parent.as_posix()
        for entry in files
        for parent in PurePosixPath(entry["path"]).parents
        if parent.as_posix() != "."
    }
    require(actual_files == expected_files,
            f"{model_key} snapshot file set differs from the owner-controlled lock")
    require(actual_directories == expected_directories,
            f"{model_key} snapshot directory set differs from the owner-controlled lock")

    authenticated_files: list[dict[str, Any]] = []
    for entry in files:
        relative = entry["path"]
        actual_digest = sha256_file(snapshot_root / Path(relative), entry["size_bytes"])
        require(actual_digest == entry["sha256"],
                f"{model_key} snapshot SHA-256 mismatch: {relative}")
        authenticated_files.append(entry)

    canonical_tree = json.dumps(
        authenticated_files,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "schema_version": 1,
        "model_key": model_key,
        "repository": model["repository"],
        "revision": model["revision"],
        "file_count": model["file_count"],
        "total_bytes": model["total_bytes"],
        "snapshot_tree_sha256": hashlib.sha256(canonical_tree).hexdigest(),
        "manifest_sha256": manifest_sha256,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--model", required=True, choices=("parakeet", "gemma"))
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--require-materialized", action="store_true")
    parser.add_argument("--materialize-to", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        require(not (args.require_materialized and args.materialize_to is not None),
                "--require-materialized and --materialize-to are mutually exclusive")
        manifest_path = Path(os.path.abspath(args.manifest))
        snapshot_path = Path(os.path.abspath(args.snapshot))
        if args.materialize_to is None:
            receipt = authenticate_snapshot(
                manifest_path,
                args.model,
                snapshot_path,
                require_materialized=args.require_materialized,
            )
        else:
            receipt = materialize_snapshot(
                manifest_path,
                args.model,
                snapshot_path,
                Path(os.path.abspath(args.materialize_to)),
            )
    except (SnapshotError, OSError) as exc:
        print(f"verify-model-snapshot: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
