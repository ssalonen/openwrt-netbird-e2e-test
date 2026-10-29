#!/usr/bin/env bash
# Tear down only a fixture directory created by start.sh.
set -euo pipefail

work=${1:?usage: stop.sh FIXTURE_WORKDIR}
case "$work" in
  */nbfixture-*) ;;
  *) echo "refusing unexpected fixture work directory: $work" >&2; exit 2 ;;
esac

test -f "$work/owner-marker"
test "$(cat "$work/owner-marker")" = "$work"
if [[ -f "$work/docker-compose.yml" ]]; then
  if [[ -f "$work/compose.ci.yml" ]]; then
    docker compose -f "$work/docker-compose.yml" -f "$work/compose.ci.yml" down --volumes --remove-orphans
  else
    docker compose -f "$work/docker-compose.yml" down --volumes --remove-orphans
  fi
fi
rm -rf -- "$work"
