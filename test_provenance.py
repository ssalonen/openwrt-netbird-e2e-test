#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name('provenance.py')
spec = importlib.util.spec_from_file_location('provenance', MODULE)
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class ProvenanceTests(unittest.TestCase):
    def test_records_exact_verified_tools_and_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'version.buildinfo').write_text('r37901-2777161847\n')
            (root / 'netbird-version').write_text('0.82.0\n')
            (root / 'sdk.metadata').write_text('openwrt-sdk-x86-64.Linux-x86_64.tar.zst ' + 'a' * 64 + '\n')
            (root / 'imagebuilder.metadata').write_text('openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst ' + 'b' * 64 + '\n')
            (root / 'netbird.apk.sha256').write_text('c' * 64 + '  /private/sdk/netbird.apk\n')
            (root / 'guest.img.gz').write_bytes(b'image bytes')
            result = provenance.record(root, root, 'https://downloads.openwrt.org/snapshots/targets/x86/64',
                                       'snapshot', 'x86_64', 'a' * 40, 30896,
                                       lambda short: '2777161847' + 'd' * 30)
            self.assertEqual(result['firmware_commit'], '2777161847' + 'd' * 30)
            self.assertEqual(result['sdk']['sha256'], 'a' * 64)
            self.assertEqual(result['imagebuilder']['sha256'], 'b' * 64)
            self.assertEqual(result['guest_image']['sha256'], provenance.digest(root / 'guest.img.gz'))
            self.assertEqual(result['pr_commit'], 'a' * 40)
            self.assertEqual(result['netbird_package_version'], '0.82.0')

    def test_rejects_mismatched_firmware_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'version.buildinfo').write_text('r37901-2777161847\n')
            for kind in ('sdk', 'imagebuilder'):
                (root / f'{kind}.metadata').write_text('a.tar.zst ' + 'a' * 64 + '\n')
            (root / 'netbird.apk.sha256').write_text('c' * 64 + '  apk\n')
            (root / 'guest.img.gz').write_bytes(b'image bytes')
            with self.assertRaisesRegex(ValueError, 'firmware commit'):
                provenance.record(root, root, 'https://downloads.openwrt.org/snapshots/targets/x86/64',
                                  'snapshot', 'x86_64', 'a' * 40, 30896, lambda short: 'b' * 40)


if __name__ == '__main__':
    unittest.main()
