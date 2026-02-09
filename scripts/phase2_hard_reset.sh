#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p backups scripts infra/litellm

# ---- backup current state
for f in docker-compose.yml infra/litellm/config.yaml scripts/test_models.sh scripts/test_router.sh scripts/wait_ready.sh; do
  if [[ -f "$f" ]]; then
    cp -a "$f" "backups/$(basename "$f").${TS}.bak"
  fi
done
echo "OK: backups written to backups/*.${TS}.bak"

# ---- write docker-compose.yml (STRICT: env_file as STRING)
cat > docker-compose.yml <<'EOF'
services:
  litellm:
    image: docker.litellm.ai/berriai/litellm:main-latest
    env_file: .env
    ports:
      - "127.0.0.1:4000:4000"
    volumes:
      - ./infra/litellm/config.yaml:/app/config.yaml:ro
    environment:
      - JSON_LOGS=True
      - LITELLM_LOG=ERROR
    command: --config /app/config.yaml --detailed_debug
    restart: unless-stopped
EOF
echo "OK: wrote docker-compose.yml"

# ---- write infra/litellm/config.yaml (clean + productized Phase2)
cat > infra/litellm/config.yaml <<'EOF'
model_list:
  # DeepSeek (daily)
  - model_name: deepseek-chat
    litellm_params:
      model: deepseek/deepseek-chat
      api_key: os.environ/DEEPSEEK_API_KEY

  # Kimi / Moonshot (long context; temperature constraint handled in test script)
  - model_name: kimi-chat
    litellm_params:
      model: moonshot/kimi-k2.5
      api_key: os.environ/MOONSHOT_API_KEY

  # Logical aliases (clients should use)
  - model_name: default-chat
    litellm_params:
      model: deepseek/deepseek-chat
      api_key: os.environ/DEEPSEEK_API_KEY

  - model_name: long-chat
    litellm_params:
      model: moonshot/kimi-k2.5
      api_key: os.environ/MOONSHOT_API_KEY

  # Premium (Opus via Anthropic gateway elbnt.ai)
  - model_name: premium-chat
    litellm_params:
      model: anthropic/claude-3-opus-20240229
      api_base: os.environ/ANTHROPIC_API_BASE
      api_key: os.environ/ANTHROPIC_API_KEY

  # Best-effort (ONLY this one is allowed to escalate)
  - model_name: best-effort-chat
    litellm_params:
      model: deepseek/deepseek-chat
      api_key: os.environ/DEEPSEEK_API_KEY

router_settings:
  # Only allow escalation on best-effort-chat
  fallbacks:
    - best-effort-chat:
        - long-chat
        - premium-chat
  num_retries: 2

litellm_settings:
  # Context too long -> move to long context model
  context_window_fallbacks:
    - default-chat:
        - long-chat
    - best-effort-chat:
        - long-chat
        - premium-chat
EOF
echo "OK: wrote infra/litellm/config.yaml"

# ---- write scripts/wait_ready.sh (with crash detection)
cat > scripts/wait_ready.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
READY_URL="${BASE%/}/health/readiness"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-90}"
SLEEP_SECS="${SLEEP_SECS:-1}"

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
  # if container not running -> fail fast and print logs
  if ! docker ps --format '{{.Names}}' | grep -qx 'litellm'; then
    echo "ERROR: container 'litellm' is not running."
    echo "---- docker compose ps ----"
    docker compose ps || true
    echo "---- docker compose logs (tail 200) ----"
    docker compose logs -n 200 litellm || true
    exit 1
  fi

  body="$(curl -sS --max-time 2 "$READY_URL" || true)"
  if echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"connected"'; then
    echo "READY: $READY_URL"
    exit 0
  fi

  echo "WAIT: not ready yet ($i/$MAX_ATTEMPTS)"
  sleep "$SLEEP_SECS"
done

echo "ERROR: Router not ready after $MAX_ATTEMPTS attempts."
echo "---- docker compose ps ----"
docker compose ps || true
echo "---- docker compose logs (tail 200) ----"
docker compose logs -n 200 litellm || true
exit 1
EOF

# ---- write scripts/test_models.sh
cat > scripts/test_models.sh <<'EOF'
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
EOF

# ---- write scripts/test_router.sh
cat > scripts/test_router.sh <<'EOF'
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
EOF

chmod +x scripts/wait_ready.sh scripts/test_models.sh scripts/test_router.sh
echo "OK: wrote scripts/* and chmod +x"

# ---- validate compose
echo "OK: docker compose config validate..."
docker compose config >/dev/null

# ---- restart
echo "OK: restarting compose..."
docker compose down
docker compose up -d

echo "OK: compose ps"
docker compose ps

echo "OK: router test"
./scripts/test_router.sh

echo "OK: model tests"
./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

echo "DONE ✅ Phase2 hard reset + all tests PASS"
