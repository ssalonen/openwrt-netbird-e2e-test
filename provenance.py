#!/usr/bin/env python3
"""Attest the exact OpenWrt tool archives and guest image used by one build."""
import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def record(work, output, base, release, arch, pr_commit, pr_number, resolve_commit):
    work, output = Path(work), Path(output)
    version = (work / 'version.buildinfo').read_text().strip()
    match = re.fullmatch(r'r[0-9]+-([a-f0-9]{7,40})', version)
    if not match:
        raise ValueError('unrecognized firmware version.buildinfo')
    commit = resolve_commit(match.group(1))
    if not re.fullmatch(r'[a-f0-9]{40}', commit) or not commit.startswith(match.group(1)):
        raise ValueError('firmware commit does not match version.buildinfo')

    def tool(kind):
        name, sha = (work / f'{kind}.metadata').read_text().strip().split()
        if '/' in name or not re.fullmatch(r'[a-f0-9]{64}', sha):
            raise ValueError('invalid tool archive metadata')
        return {'filename': name, 'url': f'{base}/{name}', 'sha256': sha}

    apk_hash = (output / 'netbird.apk.sha256').read_text().split()[0]
    if not re.fullmatch(r'[a-f0-9]{64}', apk_hash):
        raise ValueError('invalid package checksum')
    result = {'arch': arch, 'pr_number': pr_number, 'pr_commit': pr_commit,
              'openwrt_release': release, 'firmware_version': version,
              'firmware_commit': commit, 'target_url': base,
              'sdk': tool('sdk'), 'imagebuilder': tool('imagebuilder'),
              'netbird_apk_sha256': apk_hash,
              'guest_image': {'filename': 'guest.img.gz', 'sha256': digest(output / 'guest.img.gz')}}
    if (output / 'libubus.apk.sha256').is_file():
        libubus_hash = (output / 'libubus.apk.sha256').read_text().split()[0]
        if not re.fullmatch(r'[a-f0-9]{64}', libubus_hash):
            raise ValueError('invalid libubus checksum')
        result['libubus_apk_sha256'] = libubus_hash
    return result


def resolve_commit(short):
    headers = {'Accept': 'application/vnd.github+json'}
    if os.environ.get('GITHUB_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GITHUB_TOKEN']
    url = f'https://api.github.com/repos/openwrt/openwrt/commits/{short}'
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)['sha']


if __name__ == '__main__':
    try:
        result = record(os.environ['BUILD_WORK'], os.environ['BUILD_OUTPUT'], os.environ['TARGET_URL'],
                        os.environ['OPENWRT_RELEASE'], os.environ['GUEST_ARCH'],
                        os.environ['PACKAGES_REF'], int(os.environ['PR_NUMBER']), resolve_commit)
        destination = Path(os.environ['BUILD_OUTPUT']) / 'provenance.json'
        destination.write_text(json.dumps(result, indent=2) + '\n')
        print(f"Built {result['arch']}: {result['firmware_version']} ({result['firmware_commit']}); "
              f"PR #{result['pr_number']} at {result['pr_commit']}")
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
