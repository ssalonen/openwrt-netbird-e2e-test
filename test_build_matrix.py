#!/usr/bin/env python3
import unittest
from pathlib import Path

BUILD = Path(__file__).with_name('build-image.sh')
WORKFLOW = Path(__file__).parent / '.github/workflows/e2e.yml'


class BuildMatrixTests(unittest.TestCase):
    def test_pr_head_is_explicitly_fetched_and_checked(self):
        build = BUILD.read_text()
        self.assertIn('refs/pull/$pr_number/head', build)
        self.assertIn('FETCH_HEAD', build)
        self.assertIn('PR head changed', build)

    def test_release_and_snapshot_choose_distinct_downloads(self):
        build = BUILD.read_text()
        self.assertIn('OPENWRT_RELEASE', build)
        self.assertIn('snapshots/targets/', build)
        self.assertIn('releases/$release/targets/', build)
        self.assertIn('version.buildinfo', build)

    def test_workflow_asks_for_pr_number_not_sha(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('pr_number:', workflow)
        self.assertIn('resolve-pr.py', workflow)
        self.assertNotIn('packages_ref:', workflow)


    def test_all_jobs_use_avrea_runners(self):
        workflow = WORKFLOW.read_text()
        self.assertNotIn('runs-on: ubuntu-latest', workflow)
        self.assertIn('Resolve and validate NetBird PR', workflow)
        self.assertIn('Human-readable E2E report', workflow)


    def test_untrusted_pr_build_receives_no_github_token(self):
        workflow = WORKFLOW.read_text()
        build = workflow.split('  build-image:', 1)[1].split('  e2e:', 1)[0]
        self.assertNotIn('GITHUB_TOKEN:', build)
        self.assertIn('persist-credentials: false', build)


    def test_build_accepts_discovered_stable_version_not_one_fixed_patch(self):
        build = BUILD.read_text()
        self.assertNotIn('"$release" == 25.12.1', build)
        self.assertIn('OPENWRT_RELEASE', build)
        self.assertIn('snapshot', build)


    def test_build_logs_are_quiet_and_raw_log_is_downloadable_on_failure(self):
        workflow = WORKFLOW.read_text()
        build = workflow.split('  build-image:', 1)[1].split('  e2e:', 1)[0]
        self.assertIn('> "$RUNNER_TEMP/build.log" 2>&1', build)
        self.assertIn('name: build-log-${{ matrix.arch }}', build)
        self.assertIn('if: failure()', build)
        self.assertNotIn('| tee "$RUNNER_TEMP/build.log"', build)


if __name__ == '__main__':
    unittest.main()
