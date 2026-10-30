#!/bin/sh
# Executed from a read-only disposable 9p share, never typed over serial.
set -eu
fw=/mnt/e2e
read_cfg() { cat "$fw/$1"; }
setup_key=$(cat /mnt/e2e/setup-key)
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
  n=0
  while [ "$n" -lt 30 ]; do
    actual=$(timeout 8 wget -T 5 -qO- "http://$peer_ip:$port/$path" 2>/tmp/e2e-wget-error || true)
    if [ "$actual" = "$expected" ]; then return 0; fi
    n=$((n + 1))
    if [ $((n % 5)) -eq 0 ]; then echo "waiting for $path overlay data (attempt $n)"; fi
    sleep 2
  done
  echo "FAIL: overlay $path payload did not match" >&2
  cat /tmp/e2e-wget-error >&2
  netbird status -d >&2 || true
  if [ "$path" = relay-nonce ]; then cat /tmp/netbird-relay.log >&2 || true; fi
  return 1
}
fetch_nonce p2p-nonce "$p2p_nonce"
await_connection P2P
echo P2P-OVERLAY-PASS
echo RELAY-STOP-BEGIN
timeout 20 netbird down
/etc/init.d/netbird stop
rm -f /var/run/netbird.sock
echo RELAY-STOP-DONE
NB_STATE_DIR=/root/.config/netbird NB_DISABLE_SSH_CONFIG=1 \
  NB_DNS_STATE_FILE=/var/lib/netbird/state.json NB_FORCE_RELAY=true \
  /usr/bin/netbird service run >/tmp/netbird-relay.log 2>&1 &
echo RELAY-SERVICE-LAUNCHED
n=0
while [ "$n" -lt 20 ]; do
  if timeout 3 netbird status --check live >/dev/null 2>&1; then break; fi
  n=$((n + 1))
  sleep 1
done
if ! timeout 3 netbird status --check live >/dev/null 2>&1; then
  echo 'FAIL: forced-relay daemon did not start' >&2
  tail -40 /tmp/netbird-relay.log >&2
  exit 1
fi
netbird up --management-url "$url"
fetch_nonce relay-nonce "$relay_nonce"
await_connection Relayed
version_status=$(netbird status)
guest_version=$(printf '%s\n' "$version_status" | sed -nE 's/^[[:space:]]*Daemon version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' | sed -n '1p')
if [ -z "$guest_version" ]; then
  echo 'FAIL: guest NetBird daemon version unavailable' >&2
  exit 1
fi
printf 'E2E-GUEST-VERSION: %s\n' "$guest_version"
echo RELAY-OVERLAY-PASS
