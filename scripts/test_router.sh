#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# load env
set -a
source "$ROOT/.env"
set +a

MASTER_KEY="${LITELLM_MASTER_KEY:?missing LITELLM_MASTER_KEY}"

# Base URL (safe default + strip CR/LF)
BASE_URL="$(printf '%s' "${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}" | tr -d '\r\n' | sed 's/[[:space:]]\+$//')"
AUTH="Authorization: Bearer ${MASTER_KEY}"

# readiness URL (strip /v1 if present)
ORIGIN="$BASE_URL"
if [[ "$ORIGIN" == */v1 ]]; then
  ORIGIN="${ORIGIN%/v1}"
fi
ORIGIN="${ORIGIN%/}"
READY_URL="${ORIGIN}/health/readiness"

MODEL_SMOKE="${1:-default-chat}"

echo "[0/3] readiness"
max=30
for i in $(seq 1 "$max"); do
  # Quiet probe: suppress curl errors (prevents reset spam)
  code="$(curl -s -o /dev/null -w "%{http_code}" "$READY_URL" -H "$AUTH" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "READY: $READY_URL"
    break
  fi
  echo "WAIT: not ready yet ($i/$max)"
  sleep 1
  if [[ "$i" == "$max" ]]; then
    echo "ERROR: router not ready after ${max}s" >&2
    exit 1
  fi
done

echo "[1/3] models"
curl -sS "${BASE_URL}/models" -H "$AUTH"
echo
echo

echo "[2/3] smoke ${MODEL_SMOKE}"
echo "READY: $READY_URL"
echo "Base: ${BASE_URL}"
echo "Testing: ${MODEL_SMOKE}"
echo

# Minimal chat completion payload (no nested heredoc, avoids paste traps)
payload="$(MODEL="$MODEL_SMOKE" python3 -c 'import os,json
model=os.environ["MODEL"]
print(json.dumps({
  "model": model,
  "messages": [{"role":"user","content":"Say PASS"}],
  "temperature": 0.2
}))'
)"

set +e
resp="$(curl -sS --max-time 60 \
  "${BASE_URL}/chat/completions" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$payload")"
rc=$?
set -e

if [[ "$rc" != "0" ]]; then
  echo "FAIL (curl rc=$rc)" >&2
  echo "$resp" >&2
  exit 1
fi

python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d.get("choices"), "missing choices"
print("\n==> PASS")' <<<"$resp"
