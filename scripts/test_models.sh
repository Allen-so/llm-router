#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
V1="${BASE%/}/v1"
CHAT_URL="${V1}/chat/completions"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${LITELLM_MASTER_KEY:?Missing LITELLM_MASTER_KEY in .env}"

AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY}"
JSON_HEADER="Content-Type: application/json"

temp_for() {
  local m="$1"
  if [[ "$m" == kimi-* || "$m" == "long-chat" ]]; then
    echo "1"
  else
    echo "0.2"
  fi
}

./scripts/wait_ready.sh

if [[ "${1:-}" == "" ]]; then
  echo "Usage: $0 <model1> [model2 ...]"
  exit 2
fi

echo "Base: ${V1}"
echo "Testing: $*"
echo

failed=0
for model in "$@"; do
  temp="$(temp_for "$model")"
  payload="$(cat <<JSON
{
  "model":"$model",
  "temperature": $temp,
  "messages":[{"role":"user","content":"ROUTER_OK"}]
}
JSON
)"
  resp="$(curl -sS -w '\n%{http_code}' -X POST "$CHAT_URL" \
    -H "$JSON_HEADER" -H "$AUTH_HEADER" \
    --data "$payload" || true)"
  code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  echo "==> $model (temperature=$temp)"
  if [[ "$code" != "200" ]]; then
    echo "FAIL http=$code"
    echo "$body"
    echo
    failed=1
    continue
  fi
  if ! echo "$body" | grep -q "ROUTER_OK"; then
    echo "FAIL (no ROUTER_OK in response)"
    echo "$body"
    echo
    failed=1
    continue
  fi
  echo "PASS"
  echo
done

exit "$failed"
