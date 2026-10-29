#!/usr/bin/env bash
# Read back every named disposable host resource after the E2E job.
set -euo pipefail
arch=${1:?usage: verify-cleanup.sh x86_64|arm64}
run_id="e2e${GITHUB_RUN_ID: -6}"
work="${RUNNER_TEMP:-/tmp}/nbfixture-${GITHUB_RUN_ID:-local}-${arch}"
ns="nbqemu-$run_id"
peer="nbref-$run_id"
failed=0
leak() { echo "LEAK: $1" >&2; failed=1; }
[[ ! -e "$work" ]] || leak fixture
[[ ! -e "${RUNNER_TEMP:-/tmp}/$run_id" ]] || leak run_state
if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then leak namespace; fi
if ip link show "gw-$run_id" >/dev/null 2>&1; then leak host_gateway; fi
if ip link show br0 >/dev/null 2>&1; then leak host_bridge; fi
if ip link show tap0 >/dev/null 2>&1; then leak host_tap; fi
if docker ps -a --format '{{.Names}}' | grep -Fxq "$peer"; then leak reference_peer; fi
if docker ps -a --format '{{.Names}}' | grep -Fxq "nbpayload-$run_id"; then leak payload_server; fi
if docker ps -aq --filter "label=com.docker.compose.project=nbfixture-${GITHUB_RUN_ID:-local}-${arch}" | grep -q .; then leak fixture_containers; fi
if iptables-save | grep -Fq "openwrt-netbird-e2e-$run_id"; then leak firewall; fi
if [[ $failed -ne 0 ]]; then exit 1; fi
printf 'PASS: no per-run namespace, TAP, gateway, Docker peer, fixture, firewall rules, disk, or setup key\n'
