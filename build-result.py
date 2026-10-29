#!/usr/bin/env python3
"""Summarize a build failure without publishing arbitrary build output as an artifact."""
import json
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


if __name__ == '__main__':
    arch, outcome, logfile, destination = sys.argv[1:]
    log = Path(logfile).read_text(errors='replace') if Path(logfile).is_file() else ''
    result = {'arch': arch, 'status': outcome,
              'detail': 'build passed' if outcome == 'success' else summarize(log)}
    Path(destination).write_text(json.dumps(result, indent=2) + '\n')
    print(f"{arch} build: {result['status']} — {result['detail']}")
