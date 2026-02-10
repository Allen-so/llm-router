#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
READY_URL="${BASE%/}/health/readiness"
MODELS_URL="${BASE%/}/health/readiness"

# load .env for LITELLM_MASTER_KEY
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

AUTH=()
if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${LITELLM_MASTER_KEY}")
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
SLEEP_SECS="${SLEEP_SECS:-1}"

check_200() {
  local url="$1"
  local code
  code="$(curl -fs -o /dev/null -w '%{http_code}' --max-time 2 "$url" "${AUTH[@]}" || echo 000)" 2>/dev/null
  [[ "$code" == "200" ]]
}

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
  # Prefer readiness; if it returns 200 -> ready
  if check_200 "$READY_URL"; then
    echo "READY: $READY_URL"
    exit 0
  fi

  # Fallback: /health/readiness is the real “serving traffic” proof
  if check_200 "$MODELS_URL"; then
    echo "READY: $MODELS_URL"
    exit 0
  fi

  echo "WAIT: not ready yet ($i/$MAX_ATTEMPTS)"
  sleep "$SLEEP_SECS"
done

echo "ERROR: Router not ready after $MAX_ATTEMPTS attempts."
echo "Hint: docker compose logs -n 200 litellm"
exit 1
