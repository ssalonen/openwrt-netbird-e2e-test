#!/usr/bin/env bash
# Bootstrap a disposable upstream embedded-IdP instance and emit a two-use key.
set -euo pipefail
umask 077

netbird_url=${NETBIRD_URL:?set NETBIRD_URL, e.g. http://127.0.0.1}
state=${1:?usage: bootstrap.sh STATE_DIR}
mkdir -p "$state"

for _ in $(seq 1 60); do
  curl -fsS "$netbird_url/api/instance" >"$state/instance.json" && break
  sleep 1
done
python3 - "$state/instance.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['setup_required'] is True
PY
password="$(openssl rand -base64 36 | tr -d '\n')"
python3 - "$password" >"$state/setup-request.json" <<'PY'
import json,sys
print(json.dumps({'email':'ci@example.invalid','name':'CI bootstrap','password':sys.argv[1],'create_pat':True,'pat_expire_in':1}))
PY
curl -fsS -X POST "$netbird_url/api/setup" -H 'Content-Type: application/json' --data @"$state/setup-request.json" >"$state/setup.json"
python3 - "$state/setup.json" "$state/pat" <<'PY'
import json,pathlib,sys
pat=json.load(open(sys.argv[1])).get('personal_access_token','')
assert pat.startswith('nbp_')
pathlib.Path(sys.argv[2]).write_text(pat)
PY
curl -fsS -X POST "$netbird_url/api/setup-keys" -H "Authorization: Token $(<"$state/pat")" -H 'Content-Type: application/json' --data '{"name":"ci-e2e","type":"reusable","expires_in":86400,"auto_groups":[],"usage_limit":2,"ephemeral":true,"allow_extra_dns_labels":false}' >"$state/setup-key.json"
python3 - "$state/setup-key.json" "$state/setup-key" <<'PY'
import json,pathlib,sys
data=json.load(open(sys.argv[1])); assert data['type']=='reusable' and data['usage_limit']==2 and data['key']
pathlib.Path(sys.argv[2]).write_text(data['key'])
PY
