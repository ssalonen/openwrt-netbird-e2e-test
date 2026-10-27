#!/usr/bin/env bash
# Tear down only a fixture directory created by start.sh.
set -euo pipefail

work=${1:?usage: stop.sh FIXTURE_WORKDIR}
case "$work" in
  */.fixture/nbfixture-*) ;;
  *) echo "refusing unexpected fixture work directory: $work" >&2; exit 2 ;;
esac

test -f "$work/docker-compose.yml"
docker compose -f "$work/docker-compose.yml" down --volumes --remove-orphans
rm -rf "$work"
