# OpenWrt NetBird QEMU E2E

Standalone, disposable OpenWrt package test on [Avrea](https://docs.avrea.com/runners/). Requires no separate repository checkout or permanent runner network changes.

## Run

In this repository, open **Actions → NetBird E2E**, select **Run workflow**, and enter the **OpenWrt packages PR number** (for example, `30896` for master or `30895` for `openwrt-25.12`). No SHA, image URL, or checksum is needed. The workflow reads the PR head SHA from GitHub, accepts `master` or an `openwrt-X.Y` stable branch (such as a future `openwrt-26.1`), and checks that the PR changes the NetBird package Makefile. It fetches that exact PR ref and fails if the head changes before the build.

For a `master` PR, the build uses matching x86/64 and armsr/armv8 **OpenWrt master snapshot** SDKs and ImageBuilders. For a stable PR, it discovers the newest completed `X.Y.Z` release in that PR's `openwrt-X.Y` line with SDK and ImageBuilder archives for **both** guest targets; it does not silently switch to another line or an RC. The selected release is fixed for the entire workflow run. Snapshot builds move; the report records each architecture's actual firmware version and full commit, exact SDK/ImageBuilder archive names, download URLs and SHA-256 hashes, PR commit, package/image hashes, runtime guest and Docker peer NetBird versions, and every E2E and cleanup assertion. Find the combined Markdown report under the workflow's **Summary** and **NetBird-E2E-report** artifact; each architecture job also has its own summary. Build jobs show only a short outcome; on failure their complete output is downloadable as `build-log-<architecture>` for two days.

The workflow needs no prebuilt image, APK URL, or long-lived credentials:

1. On x86_64 Avrea build runners, cross-compile the NetBird package from the resolved PR head using the matching checksum-verified release or snapshot x86/64 and armsr/armv8 SDKs.
2. Re-sign only temporary copies of the built APKs into signed local APK v3 repositories; build x86_64 and arm64 OpenWrt images with matching ImageBuilders.
3. Upload architecture-specific images and SHA-256 manifests as workflow artifacts. Download and verify the manifest on each target-architecture Avrea runner.
4. Boot the upstream combined NetBird server fixture, create an ephemeral owner/PAT and a two-use setup key, and enroll a known-good Docker peer.
5. Boot the OpenWrt guest with **only one TAP NIC**, enroll it, require P2P plus a fresh overlay nonce, restart with `NB_FORCE_RELAY=true`, and require `Relayed` plus a second, distinct nonce.
6. Read back cleanup: no named namespace, host TAP/bridge/gateway, fixture container, peer, payload server, firewall rule, temporary image, or fixture credential directory.

The control-plane fixture is generated from the pinned upstream NetBird `v0.81.4` script; this harness currently requires a `0.81.4-r1` NetBird package, so a future PR upgrading NetBird itself needs a separate compatibility-fixture update. It uses HTTP on an ephemeral CI runner and synthetic credentials only; do not expose it on a non-disposable host. The guest receives its disposable key through a temporary **read-only 9p share**, never as a serial-console command or QEMU argument. The runner's IP forwarding and tagged iptables rules are restored/removed in the harness exit trap.

## Local checks

```sh
python3 test_harness.py
bash -n build-image.sh run-e2e.sh harness.sh verify-cleanup.sh fixtures/upstream/*.sh
shellcheck build-image.sh run-e2e.sh harness.sh verify-cleanup.sh guest-e2e.sh fixtures/upstream/*.sh
```

`build-image.sh x86_64|arm64 OUTPUT_DIR` requires an x86_64 Linux host and the official OpenWrt release downloads. `run-e2e.sh x86_64|arm64 IMAGE` requires a disposable root-capable host with Docker, TUN and the architecture's QEMU binary. The x86 guest uses KVM; the ARM guest currently uses TCG on Avrea because its nested ARM KVM run reproducibly stalled in the guest kernel's RCU path. Use the GitHub workflow for the complete integration gate.
