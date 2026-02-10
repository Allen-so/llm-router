#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()   { echo "OK  : $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 2; }

section() { echo; echo "== $* =="; }

# Load .env if present (do NOT print values)
load_env() {
  local envf="${ROOT_DIR}/.env"
  if [[ -f "${envf}" ]]; then
    # export variables from .env
    set -a
    # shellcheck disable=SC1090
    source "${envf}"
    set +a
    ok ".env loaded (values masked)"
  else
    warn ".env not found (ok if you export env vars manually)"
  fi
}

mask_present() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    ok "${name}=***MASKED***"
  else
    warn "${name} missing"
  fi
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
  ok "found: $c"
}

section "context"
echo "time(utc): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "pwd: ${ROOT_DIR}"
echo "kernel: $(uname -a)"
if grep -qi microsoft /proc/version 2>/dev/null; then ok "running in WSL"; else warn "not WSL? (unexpected)"; fi

section "repo"
if [[ -d "${ROOT_DIR}/.git" ]]; then
  ok "git repo detected"
  echo "head: $(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
else
  warn "not a git repo (no .git)"
fi

# Ensure .env is not tracked
if git -C "${ROOT_DIR}" ls-files 2>/dev/null | grep -E '(^|/)\.env$' >/dev/null 2>&1; then
  warn ".env is tracked by git (should not happen)"
else
  ok ".env not tracked by git"
fi

section "tooling"
require_cmd bash
require_cmd curl
require_cmd python3
require_cmd git

require_cmd docker
# docker compose (plugin) OR docker-compose (legacy)
if docker compose version >/dev/null 2>&1; then
  ok "docker compose available"
else
  command -v docker-compose >/dev/null 2>&1 || fail "missing docker compose (docker compose / docker-compose)"
  ok "docker-compose available"
fi

section "env"
load_env

# Defaults (safe) if not set
: "${LITELLM_BASE_URL:=http://127.0.0.1:4000/v1}"

mask_present LITELLM_MASTER_KEY
ok "LITELLM_BASE_URL=${LITELLM_BASE_URL}"

# Optional provider keys (you may not use all every day)
mask_present DEEPSEEK_API_KEY
mask_present MOONSHOT_API_KEY
mask_present ANTHROPIC_API_KEY
if [[ -n "${ANTHROPIC_API_BASE:-}" ]]; then ok "ANTHROPIC_API_BASE=${ANTHROPIC_API_BASE}"; else warn "ANTHROPIC_API_BASE missing (ok if not using gateway)"; fi

section "docker status"
# Show compose ps if possible
if [[ -f "${ROOT_DIR}/docker-compose.yml" || -f "${ROOT_DIR}/docker-compose.yaml" ]]; then
  docker compose -f "${ROOT_DIR}/docker-compose.yml" ps 2>/dev/null || docker compose ps || true
else
  warn "docker-compose.yml not found in repo root"
fi

section "router readiness"
# /health/readiness usually no auth; try no-auth then auth fallback
READY_URL="http://127.0.0.1:4000/health/readiness"

if curl -fsS "${READY_URL}" >/dev/null 2>&1; then
  ok "readiness: ${READY_URL}"
else
  # try with auth
  if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
    if curl -fsS "${READY_URL}" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" >/dev/null 2>&1; then
      ok "readiness (auth): ${READY_URL}"
    else
      warn "readiness check failed (router may be down): ${READY_URL}"
    fi
  else
    warn "readiness check failed and no LITELLM_MASTER_KEY to retry with auth"
  fi
fi

section "models list"
MODELS_URL="${LITELLM_BASE_URL%/}/models"
if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  warn "skip models: missing LITELLM_MASTER_KEY"
else
  if curl -fsS "${MODELS_URL}" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" | head -c 200 >/dev/null 2>&1; then
    ok "models endpoint reachable: ${MODELS_URL}"
  else
    warn "models endpoint failed: ${MODELS_URL}"
  fi
fi

section "quick smoke (optional)"
# Only run if scripts exist
if [[ -x "${ROOT_DIR}/scripts/test_router.sh" ]]; then
  ok "running: scripts/test_router.sh"
  "${ROOT_DIR}/scripts/test_router.sh" || warn "test_router.sh failed"
else
  warn "scripts/test_router.sh not executable or missing"
fi

section "summary"
echo "doctor: completed (warnings above are actionable; no secrets printed)"
