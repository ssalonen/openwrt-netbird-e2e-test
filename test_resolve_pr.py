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
    def test_stable_pr_selects_stable_release(self):
        result = resolver.select(pr('openwrt-25.12'), ['net/netbird/Makefile'])
        self.assertEqual(result['release'], '25.12.1')
        self.assertEqual(result['head_sha'], 'a' * 40)
        self.assertEqual(result['source_ref'], 'refs/pull/30895/head')

    def test_master_pr_selects_snapshot(self):
        result = resolver.select(pr('master', number=30896), ['net/netbird/Makefile'])
        self.assertEqual(result['release'], 'snapshot')

    def test_rejects_wrong_target(self):
        with self.assertRaisesRegex(ValueError, 'unsupported PR base'):
            resolver.select(pr('openwrt-24.10'), ['net/netbird/Makefile'])

    def test_rejects_unrelated_pr(self):
        with self.assertRaisesRegex(ValueError, 'NetBird Makefile'):
            resolver.select(pr('master'), ['net/other/Makefile'])

    def test_rejects_invalid_sha_and_repo(self):
        with self.assertRaises(ValueError):
            resolver.select(pr('master', sha='short'), ['net/netbird/Makefile'])
        wrong = pr('master')
        wrong['base']['repo']['full_name'] = 'someone/else'
        with self.assertRaises(ValueError):
            resolver.select(wrong, ['net/netbird/Makefile'])


if __name__ == '__main__':
    unittest.main()
