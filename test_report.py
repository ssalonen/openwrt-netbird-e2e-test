#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name('report.py')
spec = importlib.util.spec_from_file_location('report', MODULE)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.selection = {'pr_number': 30896, 'pr_url': 'https://github.com/openwrt/packages/pull/30896',
                          'base_branch': 'master', 'head_sha': 'a' * 40, 'release': 'snapshot'}
        self.provenance = {'arch': 'x86_64', 'pr_commit': 'a' * 40,
                           'firmware_version': 'r37901-2777161847', 'firmware_commit': 'b' * 40,
                           'sdk': {'filename': 'openwrt-sdk.tar.zst', 'sha256': 'c' * 64,
                                   'url': 'https://downloads.openwrt.org/sdk.tar.zst'},
                           'imagebuilder': {'filename': 'openwrt-imagebuilder.tar.zst', 'sha256': 'd' * 64,
                                            'url': 'https://downloads.openwrt.org/ib.tar.zst'},
                           'guest_image': {'sha256': 'e' * 64}, 'netbird_apk_sha256': 'f' * 64,
                           'netbird_package_version': '0.81.4'}
        self.result = {'p2p_connection': True, 'p2p_payload': True,
                       'relay_connection': True, 'relay_payload': True,
                       'guest_version': '0.81.4', 'reference_version': '0.81.4'}

    def test_readable_report_includes_source_tools_and_all_gates(self):
        text, verdict = report.render_arch(self.selection, self.provenance, self.result,
                                           'x86_64', 'success', 'success')
        self.assertTrue(verdict)
        for detail in ('PR #30896', 'master', 'a' * 40, 'r37901-2777161847', 'b' * 40,
                       'openwrt-sdk.tar.zst', 'c' * 64, 'openwrt-imagebuilder.tar.zst',
                       'd' * 64, 'e' * 64, 'f' * 64, 'P2P connection: PASS',
                       'P2P overlay payload: PASS', 'Relayed connection: PASS',
                       'Relayed overlay payload: PASS', 'Cleanup: PASS'):
            self.assertIn(detail, text)

    def test_runtime_peer_versions_are_visible(self):
        text, passed = report.render_arch(self.selection, self.provenance, self.result,
                                          'x86_64', 'success', 'success')
        self.assertTrue(passed)
        self.assertIn('**OpenWrt guest NetBird:** `0.81.4`', text)
        self.assertIn('**Docker reference NetBird:** `0.81.4`', text)

    def test_missing_or_malformed_peer_version_fails_closed(self):
        self.result['guest_version'] = ''
        _, passed = report.render_arch(self.selection, self.provenance, self.result,
                                       'x86_64', 'success', 'success')
        self.assertFalse(passed)
        self.result['guest_version'] = '0.81.4\nSETUP_KEY=secret'
        _, passed = report.render_arch(self.selection, self.provenance, self.result,
                                       'x86_64', 'success', 'success')
        self.assertFalse(passed)

    def test_guest_runtime_version_must_match_pr_package(self):
        self.result['guest_version'] = '0.82.0'
        text, passed = report.render_arch(self.selection, self.provenance, self.result,
                                          'x86_64', 'success', 'success')
        self.assertFalse(passed)
        self.assertIn('NetBird APK version', text)

    def test_cannot_report_pass_when_runtime_or_cleanup_failed(self):
        text, verdict = report.render_arch(self.selection, self.provenance, self.result,
                                           'x86_64', 'success', 'failure')
        self.assertFalse(verdict)
        self.assertIn('Cleanup: FAIL', text)
        text, verdict = report.render_arch(self.selection, self.provenance, {},
                                           'x86_64', 'failure', 'success')
        self.assertFalse(verdict)
        self.assertIn('P2P connection: FAIL', text)

    def test_rejects_provenance_from_different_pr_commit(self):
        self.provenance['pr_commit'] = '1' * 40
        with self.assertRaisesRegex(ValueError, 'PR commit mismatch'):
            report.render_arch(self.selection, self.provenance, self.result,
                               'x86_64', 'success', 'success')


    def test_combined_report_requires_both_architectures_and_same_commit(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            destination = source / 'combined.md'
            for arch in ('x86_64', 'arm64'):
                (source / f'test-report-{arch}.md').write_text(f'## {arch}\nOverall: PASS\n')
                (source / f'test-report-{arch}.json').write_text(
                    '{"arch":"' + arch + '","passed":true,"pr_commit":"' + 'a' * 40 + '"}')
            report.aggregate((source, destination))
            self.assertIn('Both architectures: PASS', destination.read_text())
            (source / 'test-report-arm64.json').unlink()
            with self.assertRaises(SystemExit):
                report.aggregate((source, destination))
            self.assertIn('Both architectures: FAIL', destination.read_text())


    def test_failed_build_is_explained_in_combined_report(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            destination = source / 'combined.md'
            (source / 'build-result-x86_64.json').write_text(
                '{"arch":"x86_64","status":"failure","detail":"libubus20261028 (no such package)",'
                '"pr_number":30896,"pr_commit":"' + 'a' * 40 + '","base_branch":"master",'
                '"firmware_version":"r37901-2777161847","sdk":{"filename":"sdk.tar.zst",'
                '"sha256":"' + 'b' * 64 + '","url":"https://example.invalid/sdk"},'
                '"imagebuilder":{"filename":"ib.tar.zst","sha256":"' + 'c' * 64 + '",'
                '"url":"https://example.invalid/ib"},"guest_image":null}')
            with self.assertRaises(SystemExit):
                report.aggregate((source, destination))
            text = destination.read_text()
            for detail in ('libubus20261028 (no such package)', 'PR #30896', 'a' * 40,
                           'sdk.tar.zst', 'b' * 64, 'ib.tar.zst', 'c' * 64, 'image: not built'):
                self.assertIn(detail, text)


if __name__ == '__main__':
    unittest.main()
