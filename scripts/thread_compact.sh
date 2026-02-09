#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# load .env for LITELLM_MASTER_KEY/LITELLM_BASE_URL
set -a
source "$ROOT/.env"
set +a

THREAD="${1:-}"
shift || true
if [[ -z "$THREAD" ]]; then
  echo "Usage: $0 <thread_name> [--max-chars N] [--keep-last N] [--model MODEL]" >&2
  exit 2
fi

python3 "$ROOT/scripts/thread_compact.py" "$THREAD" "$@"
