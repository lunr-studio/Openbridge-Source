"""Generate fixtures or run the CLEAN-00 local Gemma benchmark."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from openbridge_engine.meeting_cleanup_benchmark import (
    DEFAULT_CHUNK_SIZE,
    EXACT_MODEL_ID,
    benchmark_suite,
    generate_synthetic_fixture,
    inspect_local_snapshot,
    load_cleanup_fixture,
    write_fixture,
    write_report,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)

    generate = subcommands.add_parser("generate-fixtures")
    generate.add_argument(
        "--output-dir", type=Path, default=REPO_ROOT / "Tests" / "fixtures"
    )

    preflight = subcommands.add_parser("preflight")
    preflight.add_argument("--output", type=Path)

    run = subcommands.add_parser("run")
    run.add_argument(
        "--fixture",
        action="append",
        type=Path,
        default=[],
        help="Fixture path; repeat for both 15m and 60m fixtures.",
    )
    run.add_argument("--runs", type=int, default=3)
    run.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    run.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "output" / "clean-00" / "benchmark-results.json",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command == "generate-fixtures":
        for minutes in (15, 60):
            target = args.output_dir / f"meeting_cleanup_{minutes}m.json"
            write_fixture(generate_synthetic_fixture(minutes), target)
            print(f"Wrote {target}")
        return 0

    snapshot = inspect_local_snapshot(EXACT_MODEL_ID)
    if args.command == "preflight":
        payload = snapshot.to_dict()
        if args.output:
            write_report(payload, args.output)
        print("Complete" if snapshot.complete else "Incomplete")
        print(f"Repository: {snapshot.repository}")
        print(f"Revision: {snapshot.revision or 'not resolved'}")
        print(f"Snapshot: {snapshot.snapshotPath or 'not found'}")
        if snapshot.missingFiles:
            print("Missing: " + ", ".join(snapshot.missingFiles))
        return 0 if snapshot.complete else 2

    fixtures = tuple(
        load_cleanup_fixture(path)
        for path in (
            args.fixture
            or [
                REPO_ROOT / "Tests" / "fixtures" / "meeting_cleanup_15m.json",
                REPO_ROOT / "Tests" / "fixtures" / "meeting_cleanup_60m.json",
            ]
        )
    )
    report = benchmark_suite(
        fixtures,
        runs_per_fixture=args.runs,
        chunk_size=args.chunk_size,
        snapshot=snapshot,
        progress=lambda message: print(message, flush=True),
    )
    write_report(report, args.output)
    print(f"Decision: {report['decision']}")
    print(f"Evidence: {args.output}")
    for reason in report.get("decisionReasons", []):
        print(f"- {reason}")
    return 0 if report["decision"] == "Build" else 2


if __name__ == "__main__":
    raise SystemExit(main())
