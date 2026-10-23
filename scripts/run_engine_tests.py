"""Run both Git test trees once, including on case-sensitive Linux CI."""
from pathlib import Path
import sys
import unittest


def test_roots(root: Path, names=("tests", "Tests")) -> list[Path]:
    result = []
    seen = set()
    for name in names:
        path = root / name
        if path.is_dir():
            identity = (path.stat().st_dev, path.stat().st_ino)
            if identity not in seen:
                seen.add(identity)
                result.append(path)
    return result


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root))
    suite = unittest.TestSuite()
    for directory in test_roots(root):
        suite.addTests(unittest.TestLoader().discover(str(directory), pattern="test_*.py",
                                                      top_level_dir=str(directory)))
    if suite.countTestCases() == 0:
        raise RuntimeError("No engine tests discovered")
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
