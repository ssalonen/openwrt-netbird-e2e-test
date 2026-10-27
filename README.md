# OpenWrt NetBird QEMU E2E test

A disposable integration harness for an OpenWrt NetBird package build.

## Scope

- Bake a hash-verified, PR-built `netbird` APK and `wget` into an OpenWrt x86_64 image.
- Boot one OpenWrt QEMU guest using **only** a namespace-local TAP NIC.
- Connect the guest to a Docker reference peer through a disposable network namespace.
- Remove per-run QEMU, Docker, TAP, bridge, veth, and namespace resources on exit.

No OpenWrt package source, NetBird server fixture, credentials, build artifacts, or prior spike history is included here.

## Prerequisites

Run `build-image` on a matching x86_64 host with an OpenWrt 25.12.1 ImageBuilder and the SDK used for the package build. `run` requires root, KVM, Docker, `/dev/net/tun`, and `ip netns`.

The package source APK must be hash-verified before it is handed to the harness. The harness copies it into a local temporary repository, re-signs only that copy using the SDK build key, and generates a signed APK v3 repository index. It removes its temporary ImageBuilder repository override and public key when the build command exits.

## Build a guest image

```sh
IMAGEBUILDER=/path/to/openwrt-imagebuilder-25.12.1-x86-64.Linux-x86_64 \
NETBIRD_APK=/path/to/netbird-0.81.4-r1.apk \
SDK_PUBLIC_KEY=/path/to/sdk/public-key.pem \
SDK_PRIVATE_KEY=/path/to/sdk/private-key.pem \
OUTPUT_IMAGE=$PWD/openwrt-netbird-wget-ext4.img.gz \
./harness.sh build-image
```

## TAP-only NetBird enrollment, P2P, and relay gate

`run` requires an already-running NetBird server fixture and an enrolled Docker reference peer on the same controlled topology. It creates a fresh nonce, serves it from that peer, then requires the OpenWrt guest to fetch it over the overlay first as P2P and then with relay forcing enabled.

```sh
sudo IMAGE=$PWD/openwrt-netbird-wget-ext4.img.gz \
  NB_SETUP_KEY="$(cat /secure/runtime/setup-key)" \
  NB_MANAGEMENT_URL=https://netbird.netbird.test \
  NB_CA_CERT=/secure/runtime/ca-bundle.pem \
  PEER_CONTAINER=netbird-reference-peer \
  PEER_OVERLAY_IP=100.77.120.41 \
  ./harness.sh run
```

The setup key and CA are provided through QEMU `fw_cfg`, not the serial command stream. The guest has only the namespace-local TAP NIC; there is no user-mode NAT NIC, WAN route, or provisioning interface in this phase.

The peer container must have `python3` and must already be connected to the same test NetBird control plane. The current harness starts a temporary HTTP server inside that container and removes it during cleanup.

## Local contract test

```sh
python3 test_harness.py
bash -n harness.sh
```

## Status

The topology and cleanup primitive have been proven separately. This repository currently contains the isolated image-build and TAP-only harness scaffold; NetBird enrollment plus P2P and forced-relay overlay assertions are the next implementation slice.
