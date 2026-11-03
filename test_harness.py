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
    runtime = text.split('run)', 1)[1].rsplit('\n*)', 1)[0]
    assert '-netdev user' not in runtime
    assert 'ifname="$tap"' in runtime


def test_runtime_mode_normalizes_serial_crlf_before_assertions():
    text = HARNESS.read_text()
    assert "tr -d '\\r'" in text


def test_runtime_requires_explicit_enrollment_and_payload_inputs():
    text = HARNESS.read_text()
    runtime = text.split('run)', 1)[1].rsplit('\n*)', 1)[0]
    for required in ('NB_SETUP_KEY', 'NB_MANAGEMENT_URL', 'PEER_OVERLAY_IP'):
        assert required in runtime


def test_runtime_uses_ephemeral_readonly_9p_share_not_guest_fw_cfg_sysfs():
    runtime = HARNESS.read_text().split('run)', 1)[1].rsplit('\n*)', 1)[0]
    guest = HARNESS.with_name('guest-e2e.sh').read_text()
    boot = HARNESS.parent.joinpath('image-overlay/etc/rc.local').read_text()
    assert '-fsdev local' in runtime
    assert 'readonly=on' in runtime
    assert 'mount -t 9p' in boot
    assert 'qemu_fw_cfg' not in guest
    assert '/mnt/e2e/setup-key' in guest


def test_baked_guest_boots_9p_script_without_serial_input():
    build = HARNESS.with_name('build-image.sh').read_text()
    boot = HARNESS.parent.joinpath('image-overlay/etc/rc.local').read_text()
    assert 'FILES=' in build
    assert 'mount -t 9p' in boot
    assert '/mnt/e2e/guest-e2e.sh' in boot
    assert '/dev/console' in boot


def test_runtime_has_separate_p2p_and_relay_assertions():
    text = HARNESS.read_text()
    runtime = text.split('run)', 1)[1].rsplit('\n*)', 1)[0]
    guest = HARNESS.with_name('guest-e2e.sh').read_text()
    assert 'Connection type: P2P' in runtime
    assert 'Connection type: Relayed' in runtime
    assert 'NB_FORCE_RELAY=true' in guest
    assert 'netbird up --setup-key' in guest
    assert 'p2p-nonce' in guest and 'relay-nonce' in guest
    assert '/mnt/e2e/guest-e2e.sh' in HARNESS.parent.joinpath('image-overlay/etc/rc.local').read_text()


def test_runtime_emits_machine_readable_evidence_only_after_assertions():
    runtime = HARNESS.read_text().split('run)', 1)[1].rsplit('\n*)', 1)[0]
    self_check = runtime.index("grep -Fx 'RELAY-OVERLAY-PASS'")
    result = runtime.index('E2E_RESULT_DIR')
    assert self_check < result
    assert '"p2p_connection":true' in runtime
    assert '"relay_payload":true' in runtime


def test_runtime_versions_come_from_guest_and_reference_peer():
    guest = HARNESS.with_name('guest-e2e.sh').read_text()
    runtime = HARNESS.read_text()
    launcher = HARNESS.with_name('run-e2e.sh').read_text()
    assert 'E2E-GUEST-VERSION:' in guest
    assert 'Daemon version:' in guest
    assert 'REFERENCE_NETBIRD_VERSION=' in launcher
    assert 'Daemon version:' in launcher
    assert 'E2E-GUEST-VERSION:' in runtime
    assert '"guest_version"' in runtime and '"reference_version"' in runtime


def test_conffile_upgrade_bakes_base_package_in_an_enlarged_rootfs():
    build = HARNESS.with_name('build-image.sh').read_text()
    assert 'BASE_PACKAGES_REF' in build
    assert 'base_release' in build
    assert 'upgrade-netbird.apk' in build
    assert 'ROOTFS_PARTSIZE=256' in build


def test_conffile_upgrade_checks_modes_without_a_stat_applet():
    guest = HARNESS.with_name('guest-e2e.sh').read_text()
    assert 'stat -c' not in guest
    assert "ls -ld /etc/netbird/certs | awk '{print $1}'" in guest
    assert "ls -ld /etc/netbird/certs/device.key | awk '{print $1}'" in guest


def test_runtime_mounts_candidate_package_only_for_conffile_upgrade():
    runtime = HARNESS.read_text()
    launcher = HARNESS.with_name('run-e2e.sh').read_text()
    assert 'UPGRADE_APK' in runtime
    assert 'upgrade-netbird.apk' in runtime
    assert 'CONFFILE_UPGRADE_APK' in launcher


def test_guest_checks_certificate_files_survive_the_package_upgrade():
    guest = HARNESS.with_name('guest-e2e.sh').read_text()
    assert 'CONFFILE-UPGRADE-PASS' in guest
    assert '/etc/netbird/certs/device.pem' in guest
    assert 'apk add --allow-untrusted /mnt/e2e/upgrade-netbird.apk' in guest


if __name__ == '__main__':
    test_harness_has_separate_image_build_and_tap_only_run_modes()
    test_image_build_indexes_pr_package_before_imagebuilder_runs()
    test_image_build_trusts_the_explicit_sdk_public_key()
    test_image_build_resigns_only_the_local_copy_with_sdk_key()
    test_runtime_mode_has_no_user_nat_netdev()
    test_runtime_mode_normalizes_serial_crlf_before_assertions()
    test_runtime_requires_explicit_enrollment_and_payload_inputs()
    test_runtime_uses_ephemeral_readonly_9p_share_not_guest_fw_cfg_sysfs()
    test_baked_guest_boots_9p_script_without_serial_input()
    test_runtime_has_separate_p2p_and_relay_assertions()
    test_runtime_emits_machine_readable_evidence_only_after_assertions()
    test_runtime_versions_come_from_guest_and_reference_peer()
    test_conffile_upgrade_bakes_base_package_in_an_enlarged_rootfs()
    test_conffile_upgrade_checks_modes_without_a_stat_applet()
    test_runtime_mounts_candidate_package_only_for_conffile_upgrade()
    test_guest_checks_certificate_files_survive_the_package_upgrade()
    print('PASS: QEMU NetBird harness contract')
