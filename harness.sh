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

state_root=${STATE_ROOT:-/var/tmp/openwrt-netbird-qemu}
state="$state_root/$run_id"
ns="nbqemu-$run_id"
tap="tap0"
bridge="br0"
gateway="gw-$run_id"
payload="nbpayload-$run_id"

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
    { printf 'file://%s/packages.adb\n' "$local_repo"; cat "$IMAGEBUILDER/repositories.upstream"; } > "$IMAGEBUILDER/repositories"
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
    : "${NB_SETUP_KEY:?set NB_SETUP_KEY to a disposable NetBird setup key}"
    : "${NB_MANAGEMENT_URL:?set NB_MANAGEMENT_URL to the fixture management URL}"
    : "${PEER_CONTAINER:?set PEER_CONTAINER to the enrolled Docker reference peer container}"
    : "${PEER_OVERLAY_IP:?set PEER_OVERLAY_IP to the reference peer NetBird overlay IP}"
    : "${GUEST_ARCH:=x86_64}"
    : "${PEER_PAYLOAD_PORT:=18080}"
    test -s "$IMAGE"
    [[ "$NB_MANAGEMENT_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "NB_MANAGEMENT_URL must be a simple http(s) URL" >&2; exit 2; }
    [[ "$PEER_OVERLAY_IP" =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "PEER_OVERLAY_IP must be a NetBird overlay IPv4 address" >&2; exit 2; }
    [[ "$PEER_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "PEER_CONTAINER has invalid characters" >&2; exit 2; }
    [[ "$PEER_PAYLOAD_PORT" =~ ^[0-9]{2,5}$ ]] || { echo "PEER_PAYLOAD_PORT must be numeric" >&2; exit 2; }
    [[ "${EUID}" -eq 0 ]] || { echo "run mode must execute as root" >&2; exit 1; }
    for command in ip docker gzip openssl iptables sysctl; do need "$command"; done
    case "$GUEST_ARCH" in
      x86_64) qemu='qemu-system-x86_64'; qemu_args=(-enable-kvm); smp=2 ;;
      arm64) qemu='qemu-system-aarch64'; qemu_args=(-machine 'virt,accel=tcg' -cpu cortex-a53 -bios /usr/share/AAVMF/AAVMF_CODE.fd); smp=1 ;;
      *) echo 'GUEST_ARCH must be x86_64 or arm64' >&2; exit 2 ;;
    esac
    need "$qemu"
    [[ -c /dev/net/tun ]] || { echo "/dev/net/tun unavailable" >&2; exit 1; }
    ! ip netns list | awk '{print $1}' | grep -Fxq "$ns" || { echo "namespace exists: $ns" >&2; exit 1; }
    docker inspect -f '{{.State.Running}}' "$PEER_CONTAINER" | grep -Fx true >/dev/null

    p2p_nonce="$(openssl rand -hex 24)"
    relay_nonce="$(openssl rand -hex 24)"
    [[ "$p2p_nonce" != "$relay_nonce" ]]
    forwarding_before="$(sysctl -n net.ipv4.ip_forward)"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    nat_comment="openwrt-netbird-e2e-$run_id"
    cleanup() {
        set +e
        test -f "$state/qemu.pid" && kill "$(cat "$state/qemu.pid")" 2>/dev/null || true
        docker rm -f "$payload" >/dev/null 2>&1 || true
        iptables -D FORWARD -o "$gateway" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
        iptables -D FORWARD -i "$gateway" -j ACCEPT >/dev/null 2>&1 || true
        iptables -t nat -D POSTROUTING -s 192.0.2.0/24 -m comment --comment "$nat_comment" -j MASQUERADE >/dev/null 2>&1 || true
        ip link del "$gateway" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.ip_forward=$forwarding_before" >/dev/null 2>&1 || true
        ip netns del "$ns" >/dev/null 2>&1 || true
        rm -rf "$state"
    }
    trap cleanup EXIT
    umask 077
    mkdir -p "$state"
    gzip -dc "$IMAGE" > "$state/disk.img"
    mkdir -m 700 "$state/config"
    cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/guest-e2e.sh" "$state/config/guest-e2e.sh"
    printf '%s\n' "$NB_SETUP_KEY" > "$state/config/setup-key"
    printf '%s\n' "$NB_MANAGEMENT_URL" > "$state/config/management-url"
    printf '%s\n' "$PEER_OVERLAY_IP" > "$state/config/peer-ip"
    printf '%s\n' "$PEER_PAYLOAD_PORT" > "$state/config/payload-port"
    printf '%s\n' "$p2p_nonce" > "$state/config/p2p-nonce"
    printf '%s\n' "$relay_nonce" > "$state/config/relay-nonce"
    printf '%s\n' "$p2p_nonce" > "$state/p2p-nonce"
    printf '%s\n' "$relay_nonce" > "$state/relay-nonce"
    docker run -d --rm --name "$payload" --network "container:$PEER_CONTAINER" \
        --mount "type=bind,src=$state,dst=/payload,readonly" python:3.12-alpine \
        python3 -m http.server "$PEER_PAYLOAD_PORT" --bind 0.0.0.0 --directory /payload >/dev/null

    ip netns add "$ns"
    ip -n "$ns" link set lo up
    ip -n "$ns" link add "$bridge" type bridge
    ip -n "$ns" link set "$bridge" up
    ip -n "$ns" tuntap add dev "$tap" mode tap
    ip -n "$ns" link set "$tap" master "$bridge"
    ip -n "$ns" link set "$tap" up
    # Temporary host/namespace gateway for the fixture control plane only.
    ip link add "$gateway" type veth peer name gw0
    ip addr add 192.0.2.1/24 dev "$gateway"
    ip link set "$gateway" up
    ip link set gw0 netns "$ns"
    ip -n "$ns" link set gw0 master "$bridge"
    ip -n "$ns" link set gw0 up
    iptables -t nat -A POSTROUTING -s 192.0.2.0/24 -m comment --comment "$nat_comment" -j MASQUERADE
    iptables -A FORWARD -i "$gateway" -j ACCEPT
    iptables -A FORWARD -o "$gateway" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Only one guest NIC: the namespace TAP interface. Secrets are on a
    # temporary read-only 9p share, not on the serial console or QEMU argv.
    ip netns exec "$ns" "$qemu" "${qemu_args[@]}" -display none -m 1024 -smp "$smp" \
        -device virtio-rng-pci \
        -drive file="$state/disk.img",format=raw,if=virtio \
        -fsdev local,id=e2e,path="$state/config",security_model=none,readonly=on \
        -device virtio-9p-pci,fsdev=e2e,mount_tag=netbirdcfg \
        -netdev tap,id=n0,ifname="$tap",script=no,downscript=no \
        -device virtio-net-pci,netdev=n0 \
        -chardev socket,id=s0,path="$state/serial.sock",server=on,wait=off \
        -serial chardev:s0 -pidfile "$state/qemu.pid" -daemonize
    for _ in $(seq 1 30); do test -S "$state/serial.sock" && break; sleep 1; done
    test -S "$state/serial.sock"
    serial_rc=0
    python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/serial-console.py" \
        "$state/serial.sock" "$state/console.log" || serial_rc=$?
    tr -d '\r' < "$state/console.log" > "$state/console.normalized"
    if (( serial_rc != 0 )) || ! grep -Fxq 'RELAY-OVERLAY-PASS' "$state/console.normalized"; then
        tail -100 "$state/console.normalized" >&2
        exit 1
    fi
    grep -F 'Connection type: P2P' "$state/console.normalized"
    grep -F 'Connection type: Relayed' "$state/console.normalized"
    grep -Fx 'P2P-OVERLAY-PASS' "$state/console.normalized"
    grep -Fx 'RELAY-OVERLAY-PASS' "$state/console.normalized"
    echo 'PASS: NetBird enrollment, P2P overlay nonce, and forced-relay overlay nonce'
    ;;
*)
    echo "usage: harness.sh build-image|run" >&2
    exit 2
    ;;
esac
