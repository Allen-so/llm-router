#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# load .env into current shell (so LITELLM_MASTER_KEY is available)
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

BASE="http://127.0.0.1:4000"
KEY="${LITELLM_MASTER_KEY:-local-dev-master-key}"

echo "[0/3] health (auth)..."
ok="no"
for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w "%{http_code}" \
    "$BASE/health" -H "Authorization: Bearer $KEY" || true)"
  if [[ "$code" == "200" ]]; then
    ok="yes"; break
  fi
  sleep 1
done

if [[ "$ok" != "yes" ]]; then
  echo "FAIL: /health not 200 after 30s (last http=$code)"
  echo "---- docker compose ps ----"
  docker compose ps || true
  echo "---- docker logs (tail 120) ----"
  docker logs litellm --tail 120 || true
  exit 1
fi
echo "OK"

echo "[1/3] models..."
curl -fsS "$BASE/v1/models" \
  -H "Authorization: Bearer $KEY" > /tmp/models.json

grep -q "deepseek-chat" /tmp/models.json || { echo "FAIL: deepseek-chat not found"; cat /tmp/models.json; exit 1; }
echo "OK"

echo "[2/3] chat..."
payload='{"model":"deepseek-chat","messages":[{"role":"user","content":"Reply with exactly: ROUTER_OK"}],"temperature":0}'
resp="$(curl -fsS "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d "$payload")"

echo "$resp" | grep -q "ROUTER_OK" || { echo "FAIL: ROUTER_OK not found"; echo "$resp"; exit 1; }
echo "PASS: ROUTER_OK"
