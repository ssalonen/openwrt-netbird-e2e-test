#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name('build-result.py')
spec = importlib.util.spec_from_file_location('build_result', MODULE)
result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(result)


class BuildResultTests(unittest.TestCase):
    def test_missing_upstream_snapshot_package_is_specific(self):
        log = 'ERROR: unable to select packages:\n  libubus20261028 (no such package):\n    required by: procd-ujail\n'
        self.assertEqual(result.summarize(log), 'libubus20261028 (no such package)')

    def test_unknown_failure_does_not_fabricate_cause(self):
        self.assertEqual(result.summarize('build terminated'), 'build failed; see build job log')


if __name__ == '__main__':
    unittest.main()
