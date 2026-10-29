#!/usr/bin/env python3
"""Human-readable, fail-closed CI evidence for both OpenWrt guest architectures."""
import json
import os
import sys
from pathlib import Path

GATES = [('p2p_connection', 'P2P connection'), ('p2p_payload', 'P2P overlay payload'),
         ('relay_connection', 'Relayed connection'), ('relay_payload', 'Relayed overlay payload')]


def render_arch(selection, provenance, result, arch, runtime, cleanup):
    if provenance and provenance['pr_commit'] != selection['head_sha']:
        raise ValueError('PR commit mismatch between selection and build provenance')
    if provenance and provenance['arch'] != arch:
        raise ValueError('architecture mismatch in build provenance')
    passed = bool(provenance and runtime == 'success' and cleanup == 'success' and
                  all(result.get(key) is True for key, _ in GATES))
    lines = [f'## {arch} — NetBird package E2E',
             f"- **PR:** [PR #{selection['pr_number']}]({selection['pr_url']})",
             f"- **Target branch:** `{selection['base_branch']}`",
             f"- **PR commit:** `{selection['head_sha']}`",
             f"- **OpenWrt line:** `{selection['release']}`"]
    if provenance:
        lines.extend([f"- **Guest firmware:** `{provenance['firmware_version']}`",
                      f"- **OpenWrt firmware commit:** `{provenance['firmware_commit']}`"])
        for key, label in [('sdk', 'SDK'), ('imagebuilder', 'ImageBuilder')]:
            tool = provenance[key]
            lines.extend([f"- **{label}:** [{tool['filename']}]({tool['url']})",
                          f"- **{label} SHA-256:** `{tool['sha256']}`"])
        lines.extend([f"- **NetBird APK SHA-256:** `{provenance['netbird_apk_sha256']}`",
                      f"- **Baked guest image SHA-256:** `{provenance['guest_image']['sha256']}`"])
    else:
        lines.append('- **Build provenance:** unavailable (build/download failed)')
    lines.extend(['', '### Assertions'])
    for key, label in GATES:
        lines.append(f'- {label}: {"PASS" if runtime == "success" and result.get(key) is True else "FAIL"}')
    lines.extend([f'- Cleanup: {"PASS" if cleanup == "success" else "FAIL"}',
                  f'- **Overall: {"PASS" if passed else "FAIL"}**', ''])
    return '\n'.join(lines), passed


def read_optional(path):
    return json.loads(Path(path).read_text()) if Path(path).is_file() else {}


def arch_report(args):
    selection_path, provenance_path, result_path, destination, arch, runtime, cleanup = args
    selection = read_optional(selection_path)
    if not selection:
        selection = {'pr_number': 'unknown', 'pr_url': '#', 'base_branch': 'unknown',
                     'head_sha': 'unknown', 'release': 'unknown'}
    provenance = read_optional(provenance_path)
    result = read_optional(result_path)
    try:
        text, passed = render_arch(selection, provenance, result, arch, runtime, cleanup)
    except (KeyError, ValueError) as error:
        text, passed = f'## {arch} — NetBird package E2E\n\n**Overall: FAIL** — {error}\n', False
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)
    destination.with_suffix('.json').write_text(json.dumps({'arch': arch, 'pr_commit': selection['head_sha'],
                                                            'passed': passed}, indent=2) + '\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(text)
    print(text)


def aggregate(args):
    source, destination = map(Path, args)
    sections = ['# NetBird OpenWrt E2E report', '']
    verdicts = []
    for arch in ('x86_64', 'arm64'):
        report = source / f'test-report-{arch}.md'
        verdict = source / f'test-report-{arch}.json'
        if report.is_file() and verdict.is_file():
            sections.append(report.read_text())
            verdicts.append(json.loads(verdict.read_text()))
        else:
            sections.append(f'## {arch}\n\n**Overall: FAIL** — report missing\n')
    passed = (len(verdicts) == 2 and all(v['passed'] for v in verdicts) and
              len({v['pr_commit'] for v in verdicts}) == 1 and
              {v['arch'] for v in verdicts} == {'x86_64', 'arm64'})
    sections.append(f'**Both architectures: {"PASS" if passed else "FAIL"}**\n')
    text = '\n'.join(sections)
    destination.write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(text)
    print(text)
    if not passed:
        sys.exit(1)


if __name__ == '__main__':
    if len(sys.argv) == 9 and sys.argv[1] == 'arch':
        arch_report(sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == 'aggregate':
        aggregate(sys.argv[2:])
    else:
        sys.exit('usage: report.py arch selection provenance result destination arch runtime cleanup | aggregate dir destination')
