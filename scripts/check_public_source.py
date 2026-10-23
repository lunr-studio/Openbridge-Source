#!/usr/bin/env python3
"""Reject excluded filenames in tracked application source (not a secrets audit)."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess


def tracked_paths(repository: Path, history: bool = False) -> set[str]:
    def git(*arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(repository), *arguments], text=True
        )
    paths = set(git("ls-files", "-z").split("\0")) - {""}
    if history:
        for tree in set(git("log", "--all", "--format=%T").splitlines()):
            paths.update(git("ls-tree", "-r", "--name-only", "-z", tree).split("\0"))
    return paths - {""}


def excluded_paths(paths: set[str]) -> list[str]:
    website_roots = {"src", "public", "deploy"}
    website_files = {"server.mjs", "package.json", "package-lock.json", "Dockerfile", "index.html", "vite.config.js", "cloud-run.env.yaml"}
    generated = {".build", ".swiftpm", ".venv", "node_modules", "dist", "output", ".local-evidence"}
    forbidden_suffixes = (".dmg", ".p12", ".p8", ".pem", ".key", ".safetensors", ".gguf", ".ckpt")
    rejected = []
    for path in paths:
        parts = path.split("/")
        if (parts[0] in website_roots or path in website_files
                or any(part in generated or part.lower().endswith(".app") for part in parts)
                or parts[-1] == ".env"
                or path.lower().endswith(forbidden_suffixes)):
            rejected.append(path)
    return sorted(rejected)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--history", action="store_true", help="Check all locally available Git history as well as the index")
    args = parser.parse_args()
    paths = tracked_paths(args.repo, args.history)
    excluded = excluded_paths(paths)
    if excluded:
        print("Excluded public-source paths:")
        for path in excluded:
            print(path)
        return 1
    print(f"Public-source path check passed ({len(paths)} paths; content/credentials not audited).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
