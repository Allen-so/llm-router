#!/usr/bin/env bash
set -euo pipefail

# Prevent being sourced (sourcing + exit could kill the current shell)
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: Do not source this script. Use: ./scripts/smoke_3keys.sh"
  return 2
fi

cd "$(dirname "$0")/.."

# load .env if present
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

HOST="http://127.0.0.1:4000"
BASE="$HOST/v1"
KEY="${LITELLM_MASTER_KEY:-local-dev-master-key}"

pick_temp () {
  local m="$1"
  case "$m" in
    kimi-*|long-chat) echo "1" ;;
    *) echo "0" ;;
  esac
}

echo "[0/3] router health..."
curl -fsS "$HOST/health" -H "Authorization: Bearer $KEY" >/dev/null && echo "OK" || {
  echo "FAIL: cannot reach $HOST/health"
  exit 1
}
echo

echo "[1/3] list models..."
models_json="$(curl -fsS "$BASE/models" -H "Authorization: Bearer $KEY")"
echo "$models_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("MODELS:", [x.get("id") for x in d.get("data",[])])'
echo

echo "[2/3] chat smoke..."
for m in deepseek-chat kimi-chat long-chat default-chat; do
  if echo "$models_json" | grep -q "\"id\":\"$m\""; then
    temp="$(pick_temp "$m")"
    echo "==> $m (temperature=$temp)"
    resp="$(curl -s -w "\n%{http_code}" "$BASE/chat/completions" \
      -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"'"$m"'","messages":[{"role":"user","content":"Reply with exactly: ROUTER_OK"}],"temperature":'"$temp"'}')"
    body="$(echo "$resp" | sed '$d')"
    http="$(echo "$resp" | tail -n 1)"

    if [[ "$http" == "200" ]] && echo "$body" | grep -q "ROUTER_OK"; then
      echo "PASS $m"
    else
      echo "FAIL $m http=$http"
      echo "$body"
      exit 1
    fi
    echo
  fi
done

echo "[3/3] done."
