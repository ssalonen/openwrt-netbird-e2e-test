#!/usr/bin/env python3
"""Summarize a build failure without publishing arbitrary build output as an artifact."""
import json
import os
import re
import sys
from pathlib import Path


def summarize(log):
    missing = re.search(r'\b([a-zA-Z0-9+_.-]+ \(no such package\))', log)
    if missing:
        return missing.group(1)
    if 'ubox_include_dir-NOTFOUND' in log:
        return 'snapshot SDK lacks libubox headers required by ubus'
    if 'None of the required \'json-c\' found' in log:
        return 'snapshot SDK lacks json-c headers required by libubox'
    return 'build failed; see build job log'


def record(arch, outcome, detail, work, pr_number, pr_commit, base_branch, release):
    work = Path(work)
    target = {'x86_64': 'x86/64', 'arm64': 'armsr/armv8'}[arch]
    base = ('https://downloads.openwrt.org/snapshots/targets/' if release == 'snapshot'
            else f'https://downloads.openwrt.org/releases/{release}/targets/') + target
    def tool(kind):
        file = work / f'{kind}.metadata'
        if not file.is_file():
            return None
        filename, sha = file.read_text().strip().split()
        return {'filename': filename, 'sha256': sha, 'url': f'{base}/{filename}'}
    version = work / 'version.buildinfo'
    return {'arch': arch, 'status': outcome, 'detail': detail, 'pr_number': pr_number,
            'pr_commit': pr_commit, 'base_branch': base_branch, 'release': release,
            'firmware_version': version.read_text().strip() if version.is_file() else None,
            'sdk': tool('sdk'), 'imagebuilder': tool('imagebuilder'), 'guest_image': None}


if __name__ == '__main__':
    arch, outcome, logfile, destination = sys.argv[1:]
    log = Path(logfile).read_text(errors='replace') if Path(logfile).is_file() else ''
    result = record(arch, outcome, 'build passed' if outcome == 'success' else summarize(log),
                    Path(sys.argv[3]).parent / f'openwrt-build-{arch}',
                    int(os.environ['PR_NUMBER']), os.environ['PR_COMMIT'],
                    os.environ['BASE_BRANCH'], os.environ['OPENWRT_RELEASE'])
    Path(destination).write_text(json.dumps(result, indent=2) + '\n')
    print(f"{arch} build: {result['status']} — {result['detail']}")
