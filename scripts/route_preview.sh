#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="${ROUTER_RULES_PATH:-$ROOT/infra/router_rules.json}"

EXPLAIN=0
if [[ "${1:-}" == "--explain" ]]; then
  EXPLAIN=1
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--explain] \"text...\"" >&2
  exit 2
fi

TEXT="$*"

# route.py expects: route.py <rules_path> <mode> <msg>
ROUTE_JSON="$(python3 "$ROOT/scripts/route.py" "$RULES" auto "$TEXT")"

if [[ -z "$ROUTE_JSON" ]]; then
  echo "route_preview: route.py returned empty output" >&2
  exit 1
fi

if [[ "${ROUTER_DEBUG:-0}" == "1" ]]; then
  echo "[route_preview] raw route.py output:" >&2
  echo "$ROUTE_JSON" >&2
  echo "----" >&2
fi

# pass prompt via env to avoid quoting issues
export ROUTE_TEXT="$TEXT"
printf "%s" "$ROUTE_JSON" | python3 "$ROOT/scripts/route_explain.py" "$RULES" "$EXPLAIN"
