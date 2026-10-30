#!/usr/bin/env python3
"""Resolve one OpenWrt NetBird package PR to an exact, allowed head revision."""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

API = 'https://api.github.com/repos/openwrt/packages'
RELEASES = 'https://downloads.openwrt.org/releases/'


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.hrefs.extend(value for key, value in attrs if key == 'href')


def links(html):
    parser = Links()
    parser.feed(html)
    return parser.hrefs


def download_index(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'netbird-openwrt-e2e/1'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode('utf-8')


def discover_latest(series, fetch_index=download_index):
    if not re.fullmatch(r'[0-9]{2,3}\.[0-9]{1,2}', series):
        raise ValueError('unsupported stable release series')
    pattern = re.compile(rf'^{re.escape(series)}\.([0-9]+)/$')
    patches = sorted({int(match.group(1)) for href in links(fetch_index(RELEASES))
                      if (match := pattern.fullmatch(href))}, reverse=True)
    for patch in patches:
        release = f'{series}.{patch}'
        complete = True
        for target, slug in (('x86/64', 'x86-64'), ('armsr/armv8', 'armsr-armv8')):
            try:
                filenames = links(fetch_index(f'{RELEASES}{release}/targets/{target}/'))
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
                complete = False
                break
            sdk = re.compile(rf'^openwrt-sdk-{re.escape(release)}-{slug}_[A-Za-z0-9_.-]+\.Linux-x86_64\.tar\.zst$')
            ib = f'openwrt-imagebuilder-{release}-{slug}.Linux-x86_64.tar.zst'
            if not any(sdk.fullmatch(name) for name in filenames) or ib not in filenames:
                complete = False
                break
        if complete:
            return release
    raise ValueError(f'no complete stable release SDK/ImageBuilder pair for {series}')


def select(pr, filenames, resolve_release=discover_latest):
    if pr['base']['repo']['full_name'] != 'openwrt/packages':
        raise ValueError('PR must target openwrt/packages')
    branch = pr['base']['ref']
    stable = re.fullmatch(r'openwrt-([0-9]{2,3}\.[0-9]{1,2})', branch)
    if branch != 'master' and stable is None:
        raise ValueError(f'unsupported PR base: {branch}')
    if 'net/netbird/Makefile' not in filenames:
        raise ValueError('PR does not change the NetBird Makefile')
    sha = pr['head']['sha']
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('invalid PR head SHA')
    number = pr['number']
    if not isinstance(number, int) or number <= 0:
        raise ValueError('invalid PR number')
    release = 'snapshot' if branch == 'master' else resolve_release(stable.group(1))
    if branch != 'master' and not re.fullmatch(rf'{re.escape(stable.group(1))}\.[0-9]+', release):
        raise ValueError('discovered release does not match PR base')
    return {'pr_number': number, 'pr_url': pr['html_url'],
            'base_branch': branch, 'head_sha': sha,
            'source_ref': f'refs/pull/{number}/head',
            'release': release}


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
