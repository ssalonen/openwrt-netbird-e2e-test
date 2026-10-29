#!/usr/bin/env bash
# Own the disposable server, credentials, reference peer and QEMU invocation.
set -euo pipefail
arch=${1:?usage: run-e2e.sh x86_64|arm64 IMAGE}
image=${2:?guest image required}
[[ "$arch" == x86_64 || "$arch" == arm64 ]] || exit 2
[[ $(uname -m) == "${arch/arm64/aarch64}" ]] || { echo "runner architecture mismatch" >&2; exit 2; }
test -s "$image"
[[ ${EUID} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
run_id="e2e${GITHUB_RUN_ID: -6}"
fixture_arch=${arch/_/-}
work="${RUNNER_TEMP:-/tmp}/nbfixture-${GITHUB_RUN_ID:-local}-${fixture_arch}"
peer="nbref-$run_id"
cleanup() {
  set +e
  docker rm -f "$peer" >/dev/null 2>&1 || true
  if test -f "$work/owner-marker"; then fixtures/upstream/stop.sh "$work"; fi
}
trap cleanup EXIT
FIXTURE_ROOT=$(dirname "$work") FIXTURE_RUN_ID=$(basename "$work") fixtures/upstream/start.sh
# In use-ip mode the generator advertises the runner's primary IPv4 on port 80.
server_ip=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
[[ "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
NETBIRD_URL="http://$server_ip" fixtures/upstream/bootstrap.sh "$work/state"
mkdir -m 700 "$work/reference-data"
docker run -d --rm --name "$peer" --hostname "$peer" \
  --network host --privileged --device /dev/net/tun \
  --mount "type=bind,src=$work/state/setup-key,dst=/run/secrets/netbird-setup-key,readonly" \
  --mount "type=bind,src=$work/reference-data,dst=/var/lib/netbird" \
  -e NB_SETUP_KEY=file:/run/secrets/netbird-setup-key \
  -e NB_MANAGEMENT_URL="http://$server_ip" \
  netbirdio/netbird:0.81.4 >/dev/null
status=''
for _ in $(seq 1 60); do
  status=$(docker exec "$peer" netbird status 2>/dev/null || true)
  [[ "$status" == *'Management: Connected'* && "$status" == *'Signal: Connected'* ]] && break
  sleep 2
done
[[ "$status" == *'Management: Connected'* && "$status" == *'Signal: Connected'* ]] || {
  echo 'reference peer failed to enroll' >&2
  docker logs --tail 60 "$peer" >&2
  exit 1
}
peer_ip=$(printf '%s\n' "$status" | sed -nE 's/.*NetBird IP: (100\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | sed -n '1p')
[[ "$peer_ip" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'reference peer lacks overlay IP' >&2; exit 1; }
printf 'Reference peer enrolled: %s\n' "$peer_ip"
IMAGE="$image" NB_SETUP_KEY="$(<"$work/state/setup-key")" \
  NB_MANAGEMENT_URL="http://$server_ip" NB_CA_CERT=/etc/ssl/certs/ca-certificates.crt \
  PEER_CONTAINER="$peer" PEER_OVERLAY_IP="$peer_ip" \
  RUN_ID="$run_id" STATE_ROOT="${RUNNER_TEMP:-/tmp}" GUEST_ARCH="$arch" ./harness.sh run
