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


    def test_failure_preserves_pr_and_toolchain_provenance(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'version.buildinfo').write_text('r37901-2777161847\n')
            (root / 'sdk.metadata').write_text('openwrt-sdk-x86-64.Linux-x86_64.tar.zst ' + 'a' * 64 + '\n')
            (root / 'imagebuilder.metadata').write_text('openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst ' + 'b' * 64 + '\n')
            data = result.record('x86_64', 'failure', 'libubus20261028 (no such package)', root,
                                 30896, 'c' * 40, 'master', 'snapshot')
            self.assertEqual(data['pr_commit'], 'c' * 40)
            self.assertEqual(data['sdk']['sha256'], 'a' * 64)
            self.assertEqual(data['imagebuilder']['filename'], 'openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst')
            self.assertEqual(data['firmware_version'], 'r37901-2777161847')
            self.assertIsNone(data['guest_image'])


if __name__ == '__main__':
    unittest.main()
