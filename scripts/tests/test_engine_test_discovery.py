import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "engine_test_discovery", Path(__file__).resolve().parents[1] / "run_engine_tests.py")
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class EngineTestDiscoveryTests(unittest.TestCase):
    def test_distinct_directories_are_both_discovered(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one").mkdir()
            (root / "two").mkdir()
            self.assertEqual(discovery.test_roots(root, ("one", "two")),
                             [root / "one", root / "two"])

    def test_same_directory_is_not_run_twice(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one").mkdir()
            (root / "alias").symlink_to(root / "one", target_is_directory=True)
            self.assertEqual(discovery.test_roots(root, ("one", "alias")), [root / "one"])
