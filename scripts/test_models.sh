#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# load .env if present
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

BASE="http://127.0.0.1:4000/v1"
KEY="${LITELLM_MASTER_KEY:-local-dev-master-key}"

models_json="$(curl -fsS "$BASE/models" -H "Authorization: Bearer $KEY")"

tmp="/tmp/litellm_models.json"
printf '%s' "$models_json" > "$tmp"

if [[ "$#" -gt 0 ]]; then
  MODELS=("$@")
else
  mapfile -t MODELS < <(python3 -c '
import json
data=json.load(open("'"$tmp"'","r",encoding="utf-8"))
for item in data.get("data", []):
    mid=item.get("id")
    if mid:
        print(mid)
')
fi

if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "FAIL: no models to test"
  echo "$models_json"
  exit 1
fi

echo "Base: $BASE"
echo "Testing: ${MODELS[*]}"
echo

for m in "${MODELS[@]}"; do
  echo "==> $m"
  payload='{"model":"'"$m"'","messages":[{"role":"user","content":"Reply with exactly: ROUTER_OK"}],"temperature":0}'
  resp="$(curl -s -w "\n%{http_code}" "$BASE/chat/completions" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  body="$(echo "$resp" | sed '$d')"
  http="$(echo "$resp" | tail -n 1)"

  if [[ "$http" != "200" ]]; then
    echo "FAIL http=$http"
    echo "$body"
    echo
    continue
  fi

  if echo "$body" | grep -q "ROUTER_OK"; then
    echo "PASS"
  else
    echo "FAIL (missing ROUTER_OK)"
    echo "$body"
  fi
  echo
done
