#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
V1="${BASE%/}/v1"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${LITELLM_MASTER_KEY:?Missing LITELLM_MASTER_KEY in .env}"
AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY}"

echo "[0/3] readiness"
./scripts/wait_ready.sh

echo "[1/3] models"
curl -sS "${V1}/models" -H "$AUTH_HEADER" | head -c 900 && echo
echo

echo "[2/3] smoke default-chat"
./scripts/test_models.sh default-chat
