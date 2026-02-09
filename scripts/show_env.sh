#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "MISSING: .env (copy from .env.example)"; exit 1; }

set -a; source .env; set +a

mask() {
  local v="${1:-}"
  if [[ -z "$v" ]]; then echo "MISSING"; return; fi
  echo "SET"
}

echo "LITELLM_MASTER_KEY=$(mask "${LITELLM_MASTER_KEY:-}")"
echo "DEEPSEEK_API_KEY=$(mask "${DEEPSEEK_API_KEY:-}")"
echo "MOONSHOT_API_KEY=$(mask "${MOONSHOT_API_KEY:-}")"
echo "ANTHROPIC_API_BASE=${ANTHROPIC_API_BASE:-MISSING}"
echo "ANTHROPIC_API_KEY=$(mask "${ANTHROPIC_API_KEY:-}")"
