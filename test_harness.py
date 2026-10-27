#!/usr/bin/env python3
"""Contract tests for the disposable OpenWrt QEMU NetBird harness."""
from pathlib import Path

HARNESS = Path(__file__).resolve().with_name("harness.sh")


def test_harness_has_separate_image_build_and_tap_only_run_modes():
    text = HARNESS.read_text()
    assert 'case "$mode" in' in text
    assert 'build-image)' in text
    assert 'run)' in text


def test_image_build_indexes_pr_package_before_imagebuilder_runs():
    text = HARNESS.read_text()
    build = text.split('build-image)', 1)[1].split(';;', 1)[0]
    assert 'mkndx' in build
    assert '--output' in build
    assert 'local-repository' in build
    assert 'netbird-*.apk' in build


def test_image_build_trusts_the_explicit_sdk_public_key():
    text = HARNESS.read_text()
    build = text.split('build-image)', 1)[1].split(';;', 1)[0]
    assert 'SDK_PUBLIC_KEY' in build
    assert 'keys/' in build


def test_image_build_resigns_only_the_local_copy_with_sdk_key():
    text = HARNESS.read_text()
    build = text.split('build-image)', 1)[1].split(';;', 1)[0]
    assert 'SDK_PRIVATE_KEY' in build
    assert 'adbsign --allow-untrusted --reset-signatures' in build
    assert 'mkndx' in build
    assert '--sign-key' in build


def test_runtime_mode_has_no_user_nat_netdev():
    text = HARNESS.read_text()
    runtime = text.split('run)', 1)[1].split(';;', 1)[0]
    assert '-netdev user' not in runtime
    assert 'ifname="$tap"' in runtime


def test_runtime_mode_normalizes_serial_crlf_before_assertions():
    text = HARNESS.read_text()
    assert "tr -d '\\r'" in text


if __name__ == '__main__':
    test_harness_has_separate_image_build_and_tap_only_run_modes()
    test_image_build_indexes_pr_package_before_imagebuilder_runs()
    test_image_build_trusts_the_explicit_sdk_public_key()
    test_image_build_resigns_only_the_local_copy_with_sdk_key()
    test_runtime_mode_has_no_user_nat_netdev()
    test_runtime_mode_normalizes_serial_crlf_before_assertions()
    print('PASS: QEMU NetBird harness contract')
