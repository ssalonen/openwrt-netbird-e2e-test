#!/usr/bin/env python3
"""Resolve one OpenWrt NetBird package PR to an exact, allowed head revision."""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

API = 'https://api.github.com/repos/openwrt/packages'


def select(pr, filenames):
    if pr['base']['repo']['full_name'] != 'openwrt/packages':
        raise ValueError('PR must target openwrt/packages')
    branch = pr['base']['ref']
    if branch not in ('master', 'openwrt-25.12'):
        raise ValueError(f'unsupported PR base: {branch}')
    if 'net/netbird/Makefile' not in filenames:
        raise ValueError('PR does not change the NetBird Makefile')
    sha = pr['head']['sha']
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('invalid PR head SHA')
    number = pr['number']
    if not isinstance(number, int) or number <= 0:
        raise ValueError('invalid PR number')
    return {'pr_number': number, 'pr_url': pr['html_url'],
            'base_branch': branch, 'head_sha': sha,
            'source_ref': f'refs/pull/{number}/head',
            'release': 'snapshot' if branch == 'master' else '25.12.1'}


def fetch(path):
    token = os.environ['GITHUB_TOKEN']
    request = urllib.request.Request(API + path, headers={
        'Accept': 'application/vnd.github+json',
        'Authorization': f'Bearer {token}',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    if len(sys.argv) != 3 or not re.fullmatch(r'[1-9][0-9]{0,7}', sys.argv[1]):
        raise ValueError('usage: resolve-pr.py PR_NUMBER OUTPUT_JSON')
    number = int(sys.argv[1])
    pr = fetch(f'/pulls/{number}')
    if pr['number'] != number:
        raise ValueError('PR number mismatch')
    filenames = []
    for page in range(1, 12):
        files = fetch(f'/pulls/{number}/files?per_page=100&page={page}')
        filenames.extend(item['filename'] for item in files)
        if len(files) < 100:
            break
    else:
        raise ValueError('PR has too many changed files to inspect')
    if len(filenames) != pr['changed_files']:
        raise ValueError('PR file list incomplete')
    result = select(pr, filenames)
    Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + '\n')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in result.items():
                print(f'{key}={value}', file=output)
    print(f"Resolved #{number}: {result['base_branch']} at {result['head_sha']}")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
