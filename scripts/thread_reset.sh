#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

THREAD="${1:-}"
if [[ -z "$THREAD" ]]; then
  echo "Usage: $0 <thread_name>" >&2
  exit 2
fi

SAFE="$(printf '%s' "$THREAD" | tr -cs 'A-Za-z0-9._-' '_' )"
FILE="$ROOT/logs/threads/${SAFE}.jsonl"

mkdir -p "$ROOT/logs/threads"
: > "$FILE"
echo "OK: reset $FILE"
