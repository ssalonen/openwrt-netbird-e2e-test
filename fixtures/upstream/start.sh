#!/usr/bin/env bash
# Create a disposable minimal upstream NetBird combined-server fixture.
set -euo pipefail

fixture_root=${FIXTURE_ROOT:-"$PWD/.fixture"}
run_id=${FIXTURE_RUN_ID:-"nbfixture-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"}
work="$fixture_root/$run_id"
netbird_ref=${NETBIRD_FIXTURE_REF:-v0.81.4}

[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,50}$ ]] || {
    echo "invalid FIXTURE_RUN_ID" >&2
    exit 2
}
command -v curl >/dev/null
command -v docker >/dev/null
docker info >/dev/null

if [[ -e "$work" ]]; then
    echo "fixture work directory exists: $work" >&2
    exit 1
fi
mkdir -p "$fixture_root"
mkdir -m 700 "$work"
printf '%s\n' "$work" > "$work/owner-marker"
cd "$work"
if [[ -e docker-compose.yml || -e config.yaml ]]; then
    echo "fixture work directory is not empty: $work" >&2
    exit 1
fi

# Use the upstream generator rather than maintaining a forked server compose file.
curl -fsSLo getting-started.sh \
    "https://raw.githubusercontent.com/netbirdio/netbird/$netbird_ref/infrastructure_files/getting-started.sh"
chmod 700 getting-started.sh

# `use-ip` gives this disposable fixture no public-DNS or ACME dependency. The
# generated compose/config files remain upstream-owned, and all files stay in
# this per-run directory for explicit cleanup.
NETBIRD_NON_INTERACTIVE=true \
NETBIRD_DOMAIN=use-ip \
NETBIRD_REVERSE_PROXY_TYPE=5 \
NETBIRD_BIND_LOCALHOST_ONLY=false \
NETBIRD_SERVER_IMAGE="netbirdio/netbird-server:${NETBIRD_SERVER_VERSION:-0.81.4}" \
./getting-started.sh
cat > compose.ci.yml <<'EOF'
services:
  netbird-server:
    environment:
      NB_SETUP_PAT_ENABLED: "true"
    ports:
      - "80:80"
EOF
docker compose -f docker-compose.yml -f compose.ci.yml up -d --force-recreate netbird-server

printf 'FIXTURE_WORKDIR=%s\n' "$work"
