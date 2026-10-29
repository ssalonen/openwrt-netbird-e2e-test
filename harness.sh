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
    : "${NB_CA_CERT:?set NB_CA_CERT to the fixture CA certificate path}"
    : "${PEER_CONTAINER:?set PEER_CONTAINER to the enrolled Docker reference peer container}"
    : "${PEER_OVERLAY_IP:?set PEER_OVERLAY_IP to the reference peer NetBird overlay IP}"
    : "${GUEST_ARCH:=x86_64}"
    : "${PEER_PAYLOAD_PORT:=18080}"
    test -s "$IMAGE"
    test -s "$NB_CA_CERT"
    [[ "$NB_MANAGEMENT_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "NB_MANAGEMENT_URL must be a simple http(s) URL" >&2; exit 2; }
    [[ "$PEER_OVERLAY_IP" =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "PEER_OVERLAY_IP must be a NetBird overlay IPv4 address" >&2; exit 2; }
    [[ "$PEER_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "PEER_CONTAINER has invalid characters" >&2; exit 2; }
    [[ "$PEER_PAYLOAD_PORT" =~ ^[0-9]{2,5}$ ]] || { echo "PEER_PAYLOAD_PORT must be numeric" >&2; exit 2; }
    [[ "${EUID}" -eq 0 ]] || { echo "run mode must execute as root" >&2; exit 1; }
    for command in ip docker gzip nc openssl iptables sysctl; do need "$command"; done
    case "$GUEST_ARCH" in
      x86_64) qemu='qemu-system-x86_64'; qemu_args=(-enable-kvm) ;;
      arm64) qemu='qemu-system-aarch64'; qemu_args=(-machine 'virt,accel=kvm' -cpu host -bios /usr/share/AAVMF/AAVMF_CODE.fd) ;;
      *) echo 'GUEST_ARCH must be x86_64 or arm64' >&2; exit 2 ;;
    esac
    need "$qemu"
    [[ -c /dev/net/tun ]] || { echo "/dev/net/tun unavailable" >&2; exit 1; }
    ! ip netns list | awk '{print $1}' | grep -Fxq "$ns" || { echo "namespace exists: $ns" >&2; exit 1; }
    docker inspect -f '{{.State.Running}}' "$PEER_CONTAINER" | grep -Fx true >/dev/null

    overlay_nonce="$(openssl rand -hex 24)"
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
    mkdir -p "$state"
    gzip -dc "$IMAGE" > "$state/disk.img"
    printf '%s\n' "$overlay_nonce" > "$state/overlay-nonce"
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

    # Intentionally only one guest NIC: the namespace TAP interface.
    # The setup key and CA travel through QEMU fw_cfg; neither is echoed on serial.
    ip netns exec "$ns" "$qemu" "${qemu_args[@]}" -display none -m 1024 \
        -drive file="$state/disk.img",format=raw,if=virtio \
        -netdev tap,id=n0,ifname="$tap",script=no,downscript=no \
        -device virtio-net-pci,netdev=n0 \
        -fw_cfg name=opt/netbird/setup-key,string="$NB_SETUP_KEY" \
        -fw_cfg name=opt/netbird/ca-cert,file="$NB_CA_CERT" \
        -chardev socket,id=s0,path="$state/serial.sock",server=on,wait=off \
        -serial chardev:s0 -pidfile "$state/qemu.pid" -daemonize
    for _ in $(seq 1 30); do test -S "$state/serial.sock" && break; sleep 1; done
    test -S "$state/serial.sock"
    {
        sleep 20
        printf '\n'
        sleep 2
        # shellcheck disable=SC2016 # Deliberately emitted for expansion by the guest shell.
        printf 'set -e; ip addr flush dev br-lan; ip addr add 192.0.2.10/24 dev br-lan; ip link set br-lan up; ip route replace default via 192.0.2.1; mkdir -p /etc/ssl/certs; cat /sys/firmware/qemu_fw_cfg/by_name/opt/netbird/ca-cert/raw > /etc/ssl/certs/netbird-e2e-ca.pem; setup_key=$(cat /sys/firmware/qemu_fw_cfg/by_name/opt/netbird/setup-key/raw); /etc/init.d/netbird start; netbird up --setup-key "$setup_key" --management-url "%s"; unset setup_key; for i in $(seq 1 30); do netbird status -d | grep -F "Connection type: P2P" && break; sleep 2; done; netbird status -d | grep -F "Connection type: P2P"; wget -qO- "http://%s:%s/overlay-nonce" | grep -Fx "%s"; echo P2P-OVERLAY-PASS; /etc/init.d/netbird stop; NB_FORCE_RELAY=true /usr/bin/netbird service run >/tmp/netbird-relay.log 2>&1 & for i in $(seq 1 30); do netbird status -d | grep -F "Connection type: Relayed" && break; sleep 2; done; netbird status -d | grep -F "Connection type: Relayed"; wget -qO- "http://%s:%s/overlay-nonce" | grep -Fx "%s"; echo RELAY-OVERLAY-PASS\n' "$NB_MANAGEMENT_URL" "$PEER_OVERLAY_IP" "$PEER_PAYLOAD_PORT" "$overlay_nonce" "$PEER_OVERLAY_IP" "$PEER_PAYLOAD_PORT" "$overlay_nonce"
        sleep 180
    } | timeout 240 nc -U "$state/serial.sock" > "$state/console.log" 2>&1 || true
    tr -d '\r' < "$state/console.log" > "$state/console.normalized"
    if ! grep -Fxq 'RELAY-OVERLAY-PASS' "$state/console.normalized"; then
        sed -n '/set -e; ip addr flush/,$p' "$state/console.normalized" | tail -100 >&2
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
