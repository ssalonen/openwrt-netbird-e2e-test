#!/usr/bin/env python3
import unittest
from pathlib import Path

BUILD = Path(__file__).with_name('build-image.sh')


class SnapshotDependencyTests(unittest.TestCase):
    def test_snapshot_builds_exact_firmware_ubus_abi_into_local_repository(self):
        build = BUILD.read_text()
        self.assertIn('package/libs/libubox/Makefile', build)
        self.assertIn('package/libs/libubox/compile', build)
        self.assertIn('package/system/ubus/Makefile', build)
        self.assertIn('package/system/ubus/compile', build)
        self.assertIn('firmware_commit', build)
        self.assertIn('libubus*.apk', build)
        self.assertIn('local-repository', build)
        self.assertIn('mkndx', build)


if __name__ == '__main__':
    unittest.main()
