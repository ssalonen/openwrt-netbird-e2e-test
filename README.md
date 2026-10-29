# OpenWrt NetBird QEMU E2E

Standalone, disposable OpenWrt package test on [Avrea](https://docs.avrea.com/runners/). No `external-checkout` checkout or permanent runner network changes.

## Run

Open [Actions → NetBird E2E](Actions - NetBird E2E) and select **Run workflow**. The default `packages_ref` is the exact master PR #30896 head, `8379ac12710eea0772da83066999ed44b82951b6`. To test another revision, supply its **full 40-character commit SHA** from `openwrt/packages`.

The workflow needs no prebuilt image, APK URL, or long-lived credentials:

1. On x86_64 Avrea build runners, cross-compile the NetBird package from that commit using official checksum-verified OpenWrt 25.12.1 x86/64 and armsr/armv8 SDKs.
2. Re-sign only temporary copies of the built APKs into signed local APK v3 repositories; build x86_64 and arm64 OpenWrt images with matching ImageBuilders.
3. Upload architecture-specific images and SHA-256 manifests as workflow artifacts. Download and verify the manifest on each target-architecture Avrea runner.
4. Boot the upstream combined NetBird server fixture, create an ephemeral owner/PAT and a two-use setup key, and enroll a known-good Docker peer.
5. Boot the OpenWrt guest with **only one TAP NIC**, enroll it, require P2P plus a fresh overlay nonce, restart with `NB_FORCE_RELAY=true`, and require `Relayed` plus a second, distinct nonce.
6. Read back cleanup: no named namespace, host TAP/bridge/gateway, fixture container, peer, payload server, firewall rule, temporary image, or fixture credential directory.

The control-plane fixture is generated from the pinned upstream NetBird `v0.81.4` script. It uses HTTP on an ephemeral CI runner and synthetic credentials only; do not expose it on a non-disposable host. The guest receives its disposable key on a temporary **read-only ext4 disk**, never as a serial-console command or QEMU argument. The runner's IP forwarding and tagged iptables rules are restored/removed in the harness exit trap.

## Local checks

```sh
python3 test_harness.py
bash -n build-image.sh run-e2e.sh harness.sh verify-cleanup.sh fixtures/upstream/*.sh
shellcheck build-image.sh run-e2e.sh harness.sh verify-cleanup.sh guest-e2e.sh fixtures/upstream/*.sh
```

`build-image.sh x86_64|arm64 OUTPUT_DIR` requires an x86_64 Linux host and the official OpenWrt release downloads. `run-e2e.sh x86_64|arm64 IMAGE` requires a disposable root-capable host with Docker, KVM, TUN and the architecture's QEMU binary. Use the GitHub workflow for the complete integration gate.
