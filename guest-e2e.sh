#!/bin/sh
# Executed in the disposable OpenWrt guest from QEMU fw_cfg, never over serial.
set -eu
fw=/sys/firmware/qemu_fw_cfg/by_name/opt/netbird
read_cfg() { cat "$fw/$1/raw"; }
setup_key=$(read_cfg setup-key)
url=$(read_cfg management-url)
peer_ip=$(read_cfg peer-ip)
port=$(read_cfg payload-port)
p2p_nonce=$(read_cfg p2p-nonce)
relay_nonce=$(read_cfg relay-nonce)
ip addr flush dev br-lan
ip addr add 192.0.2.10/24 dev br-lan
ip link set br-lan up
ip route replace default via 192.0.2.1
# The test guest has exactly one physical NIC. Never configure a second WAN NIC.
/etc/init.d/netbird start
netbird up --setup-key "$setup_key" --management-url "$url"
unset setup_key
await_connection() {
  kind=$1
  n=0
  while [ "$n" -lt 45 ]; do
    status=$(netbird status -d 2>/dev/null || true)
    if printf '%s\n' "$status" | grep -Fq 'Management: Connected' &&
       printf '%s\n' "$status" | grep -Fq 'Signal: Connected' &&
       printf '%s\n' "$status" | grep -Fq "Connection type: $kind"; then
      printf 'Connection type: %s\n' "$kind"
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  printf 'FAIL: %s connection not established\n%s\n' "$kind" "$status" >&2
  return 1
}
fetch_nonce() {
  path=$1 expected=$2
  actual=$(wget -qO- "http://$peer_ip:$port/$path")
  test "$actual" = "$expected"
}
await_connection P2P
fetch_nonce p2p-nonce "$p2p_nonce"
echo P2P-OVERLAY-PASS
/etc/init.d/netbird stop
NB_FORCE_RELAY=true /usr/bin/netbird service run >/tmp/netbird-relay.log 2>&1 &
await_connection Relayed
fetch_nonce relay-nonce "$relay_nonce"
echo RELAY-OVERLAY-PASS
