#!/usr/bin/env bash
# Disposable TAP-only OpenWrt QEMU harness.
# build-image produces an image with test packages baked in; run never adds WAN.
set -euo pipefail

mode=${1:?usage: harness.sh build-image|run}
run_id=${RUN_ID:-qnb-$(date +%s)}
[[ "$run_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,9}$ ]] || {
    echo "RUN_ID must be 1-10 alphanumeric/hyphen characters" >&2
    exit 2
}

root="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
state_root=${STATE_ROOT:-/var/tmp/openwrt-netbird-qemu}
state="$state_root/$run_id"
ns="nbqemu-$run_id"
tap="tap0"
bridge="br0"
peer="nbqemu-peer-$run_id"

need() {
    command -v "$1" >/dev/null || { echo "missing command: $1" >&2; exit 1; }
}

case "$mode" in
build-image)
    : "${IMAGEBUILDER:?set IMAGEBUILDER to an OpenWrt ImageBuilder directory}"
    : "${NETBIRD_APK:?set NETBIRD_APK to the PR-built netbird APK}"
    : "${OUTPUT_IMAGE:?set OUTPUT_IMAGE to the resulting ext4 image path}"
    test -d "$IMAGEBUILDER"
    test -s "$NETBIRD_APK"
    : "${SDK_PUBLIC_KEY:?set SDK_PUBLIC_KEY to the SDK public signing key}"
    : "${SDK_PRIVATE_KEY:?set SDK_PRIVATE_KEY to the SDK private signing key}"
    test -r "$SDK_PUBLIC_KEY"
    test -r "$SDK_PRIVATE_KEY"
    local_repo="$IMAGEBUILDER/local-repository"
    key_name="$(basename "$SDK_PUBLIC_KEY")"
    test ! -e "$IMAGEBUILDER/keys/$key_name"
    cp "$SDK_PUBLIC_KEY" "$IMAGEBUILDER/keys/$key_name"
    apk_tool=${APK_TOOL:-"$IMAGEBUILDER/staging_dir/host/bin/apk"}
    test -x "$apk_tool"
    rm -rf "$local_repo"
    mkdir -p "$local_repo"
    cp "$NETBIRD_APK" "$local_repo/"
    "$apk_tool" adbsign --allow-untrusted --reset-signatures --sign-key "$SDK_PRIVATE_KEY" "$local_repo"/netbird-*.apk
    "$apk_tool" --keys-dir "$IMAGEBUILDER/keys" mkndx --sign-key "$SDK_PRIVATE_KEY" --output "$local_repo/packages.adb" "$local_repo"/netbird-*.apk
    cp "$IMAGEBUILDER/repositories" "$IMAGEBUILDER/repositories.upstream"
    { printf 'file://%s/packages.adb\\n' "$local_repo"; cat "$IMAGEBUILDER/repositories.upstream"; } > "$IMAGEBUILDER/repositories"
    restore_build_config() {
        test -f "$IMAGEBUILDER/repositories.upstream" && mv -f "$IMAGEBUILDER/repositories.upstream" "$IMAGEBUILDER/repositories" || true
        rm -f "$IMAGEBUILDER/keys/$key_name"
    }
    trap restore_build_config EXIT
    make -C "$IMAGEBUILDER" image PACKAGES="netbird wget"
    image="$(find "$IMAGEBUILDER/bin/targets" -type f -name '*ext4-combined.img.gz' -print -quit)"
    test -n "$image"
    cp "$image" "$OUTPUT_IMAGE"
    sha256sum "$OUTPUT_IMAGE"
    ;;
run)
    : "${IMAGE:?set IMAGE to the baked OpenWrt ext4-combined image}"
    : "${PEER_IMAGE:=alpine:3.21}"
    test -s "$IMAGE"
    [[ "${EUID}" -eq 0 ]] || { echo "run mode must execute as root" >&2; exit 1; }
    for command in ip docker qemu-system-x86_64 gzip nc; do need "$command"; done
    [[ -c /dev/net/tun ]] || { echo "/dev/net/tun unavailable" >&2; exit 1; }
    ! ip netns list | awk '{print $1}' | grep -Fxq "$ns" || { echo "namespace exists: $ns" >&2; exit 1; }

    cleanup() {
        set +e
        test -f "$state/qemu.pid" && kill "$(cat "$state/qemu.pid")" 2>/dev/null || true
        docker rm -f "$peer" >/dev/null 2>&1 || true
        ip netns del "$ns" >/dev/null 2>&1 || true
        rm -rf "$state"
    }
    trap cleanup EXIT
    mkdir -p "$state"
    gzip -dc "$IMAGE" > "$state/disk.img"

    ip netns add "$ns"
    ip -n "$ns" link set lo up
    ip -n "$ns" link add "$bridge" type bridge
    ip -n "$ns" link set "$bridge" up
    ip -n "$ns" tuntap add dev "$tap" mode tap
    ip -n "$ns" link set "$tap" master "$bridge"
    ip -n "$ns" link set "$tap" up

    docker run -d --rm --name "$peer" --network none --cap-add NET_ADMIN "$PEER_IMAGE" sleep 300 >/dev/null
    peer_pid="$(docker inspect -f '{{.State.Pid}}' "$peer")"
    ip link add "veth-$run_id" type veth peer name peer0
    ip link set "veth-$run_id" netns "$ns"
    ip -n "$ns" link set "veth-$run_id" master "$bridge"
    ip -n "$ns" link set "veth-$run_id" up
    ip link set peer0 netns "$peer_pid"
    nsenter -t "$peer_pid" -n ip link set lo up
    nsenter -t "$peer_pid" -n ip link set peer0 name eth0
    nsenter -t "$peer_pid" -n ip addr add 192.0.2.2/24 dev eth0
    nsenter -t "$peer_pid" -n ip link set eth0 up

    # Intentionally only one guest NIC: the namespace TAP interface.
    ip netns exec "$ns" qemu-system-x86_64 -enable-kvm -display none -m 256 \
        -drive file="$state/disk.img",format=raw,if=virtio \
        -netdev tap,id=n0,ifname="$tap",script=no,downscript=no \
        -device virtio-net-pci,netdev=n0 \
        -chardev socket,id=s0,path="$state/serial.sock",server=on,wait=off \
        -serial chardev:s0 -pidfile "$state/qemu.pid" -daemonize
    for _ in $(seq 1 30); do test -S "$state/serial.sock" && break; sleep 1; done
    test -S "$state/serial.sock"
    {
        sleep 20
        printf '\n'
        sleep 2
        printf 'ip addr flush dev br-lan; ip addr add 192.0.2.10/24 dev br-lan; ip link set br-lan up; ping -c 1 -W 3 192.0.2.2; echo TAP-ONLY-DONE\n'
        sleep 5
    } | timeout 32 nc -U "$state/serial.sock" > "$state/console.log" 2>&1 || true
    tr -d '\r' < "$state/console.log" > "$state/console.normalized"
    grep -F '1 packets received' "$state/console.normalized"
    grep -Fx 'TAP-ONLY-DONE' "$state/console.normalized"
    echo 'PASS: TAP-only QEMU OpenWrt smoke'
    ;;
*)
    echo "usage: harness.sh build-image|run" >&2
    exit 2
    ;;
esac
