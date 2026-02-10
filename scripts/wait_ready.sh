#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}"
BASE="${BASE%/}"
URL="${BASE}/models"

TIMEOUT_SECS="${WAIT_READY_TIMEOUT_SECS:-60}"
INTERVAL_SECS="${WAIT_READY_INTERVAL_SECS:-1}"

deadline=$(( $(date +%s) + TIMEOUT_SECS ))

echo "[wait_ready] url=$URL timeout=${TIMEOUT_SECS}s"

while :; do
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "[wait_ready] timeout after ${TIMEOUT_SECS}s" >&2
    echo "[wait_ready] docker compose ps:" >&2
    docker compose ps >&2 || true
    echo "[wait_ready] last logs (litellm):" >&2
    docker compose logs --tail 120 litellm >&2 || true
    exit 1
  fi

  http="$(curl -sS -o /dev/null --connect-timeout 2 --max-time 3 -w '%{http_code}' "$URL" 2>/dev/null || echo 000)"
  http="${http:0:3}"
  [[ -z "$http" ]] && http=000

  # 200=OK, 401/403=需要鉴权但服务已响应 => 也算 ready
  case "$http" in
    200|401|403)
      echo "[wait_ready] ready (HTTP=$http)"
      exit 0
      ;;
    *)
      echo "[wait_ready] not ready yet (HTTP=$http) ..."
      sleep "$INTERVAL_SECS"
      ;;
  esac
done
