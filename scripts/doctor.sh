#!/usr/bin/env bash
set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; NC=$'\033[0m'

ok()  { echo "${GRN}[ok]${NC} $*"; }
warn(){ echo "${YEL}[warn]${NC} $*"; }
bad() { echo "${RED}[fail]${NC} $*"; }

ROOT="/home/suxiaocong/ai-platform"
cd "$ROOT" 2>/dev/null || { bad "Not in $ROOT"; exit 2; }

need_files=(
  "docker-compose.yml"
  "scripts/ask.sh"
  "scripts/wait_ready.sh"
  "scripts/lib_http_retry.sh"
  "logs"
)

for f in "${need_files[@]}"; do
  [[ -e "$f" ]] && ok "exists: $f" || { bad "missing: $f"; exit 2; }
done

command -v docker >/dev/null 2>&1 && ok "docker installed" || { bad "docker not found"; exit 2; }
docker compose version >/dev/null 2>&1 && ok "docker compose plugin OK" || { bad "docker compose not available"; exit 2; }

# .env checks (do NOT print secrets)
if [[ -f ".env" ]]; then
  ok ".env present"
  grep -q '^LITELLM_MASTER_KEY=' .env && ok "LITELLM_MASTER_KEY set in .env" || warn "LITELLM_MASTER_KEY not found in .env (ask/demo may 401/403)"
else
  warn ".env missing (ask/demo may fail unless env vars are set elsewhere)"
fi

echo
echo "[doctor] docker compose ps:"
docker compose ps || true

# Port check
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ':4000'; then
    ok "port 4000 is listening"
  else
    warn "port 4000 not listening (maybe container not up yet)"
  fi
else
  warn "ss not available; skip port check"
fi

# HTTP check (401/403/200 all mean alive)
API_BASE="${API_BASE:-http://127.0.0.1:4000}"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$API_BASE/v1/models" || true)"
[[ -z "$code" ]] && code=000
echo "[doctor] GET /v1/models => HTTP=$code"
case "$code" in
  200|401|403) ok "router alive (HTTP=$code)";;
  000) warn "router not reachable (HTTP=000)";;
  *)  warn "unexpected HTTP=$code";;
esac

echo
echo "[doctor] tip:"
echo "  make upready && make ask MODE=auto TEXT='Reply with exactly ROUTER_OK'"
