#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name('resolve-pr.py')
spec = importlib.util.spec_from_file_location('resolve_pr', MODULE)
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


def pr(base, sha='a' * 40, number=30895):
    return {'number': number, 'html_url': f'https://github.com/openwrt/packages/pull/{number}',
            'base': {'ref': base, 'repo': {'full_name': 'openwrt/packages'}},
            'head': {'sha': sha}, 'changed_files': 1}


class ResolvePRTests(unittest.TestCase):
    def test_stable_pr_selects_latest_matching_release(self):
        result = resolver.select(pr('openwrt-25.12'), ['net/netbird/Makefile'],
                                 lambda series: '25.12.6')
        self.assertEqual(result['release'], '25.12.6')
        self.assertEqual(result['head_sha'], 'a' * 40)
        self.assertEqual(result['source_ref'], 'refs/pull/30895/head')

    def test_future_stable_branch_selects_its_own_series(self):
        result = resolver.select(pr('openwrt-26.1'), ['net/netbird/Makefile'],
                                 lambda series: '26.1.3' if series == '26.1' else 'wrong')
        self.assertEqual(result['release'], '26.1.3')

    def test_master_pr_selects_snapshot(self):
        result = resolver.select(pr('master', number=30896), ['net/netbird/Makefile'])
        self.assertEqual(result['release'], 'snapshot')

    def test_rejects_wrong_target(self):
        with self.assertRaisesRegex(ValueError, 'unsupported PR base'):
            resolver.select(pr('openwrt-24.10-rc'), ['net/netbird/Makefile'])

    def test_rejects_unrelated_pr(self):
        with self.assertRaisesRegex(ValueError, 'NetBird Makefile'):
            resolver.select(pr('master'), ['net/other/Makefile'])

    def test_uses_highest_complete_patch_for_both_targets(self):
        root = 'https://downloads.openwrt.org/releases/'
        indexes = {
            root: '<a href="25.12.6/">new</a><a href="25.12.5/">old</a><a href="25.12.7-rc1/">rc</a><a href="26.1.1/">other</a>',
        }
        for patch in ('25.12.5', '25.12.6'):
            for path, name in [('x86/64', 'x86-64'), ('armsr/armv8', 'armsr-armv8')]:
                sdk = f'openwrt-sdk-{patch}-{name}_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
                ib = f'openwrt-imagebuilder-{patch}-{name}.Linux-x86_64.tar.zst'
                indexes[f'{root}{patch}/targets/{path}/'] = f'<a href="{sdk}">SDK</a>' + (
                    f'<a href="{ib}">IB</a>' if patch == '25.12.5' or path == 'x86/64' else '')
        self.assertEqual(resolver.discover_latest('25.12', indexes.__getitem__), '25.12.5')
        indexes[f'{root}25.12.6/targets/armsr/armv8/'] += (
            '<a href="openwrt-imagebuilder-25.12.6-armsr-armv8.Linux-x86_64.tar.zst">IB</a>')
        self.assertEqual(resolver.discover_latest('25.12', indexes.__getitem__), '25.12.6')

    def test_no_complete_release_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'no complete stable release'):
            resolver.discover_latest('26.1', lambda url: '<a href="26.1.0-rc1/">rc</a>')

    def test_rejects_invalid_sha_and_repo(self):
        with self.assertRaises(ValueError):
            resolver.select(pr('master', sha='short'), ['net/netbird/Makefile'])
        wrong = pr('master')
        wrong['base']['repo']['full_name'] = 'someone/else'
        with self.assertRaises(ValueError):
            resolver.select(wrong, ['net/netbird/Makefile'])


if __name__ == '__main__':
    unittest.main()
