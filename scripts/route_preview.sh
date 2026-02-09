#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="${ROUTER_RULES_PATH:-$ROOT/infra/router_rules.json}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"text...\""
  exit 2
fi

TEXT="$*"

# Keep stderr visible; capture stdout only (route.py prints JSON to stdout)
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

# IMPORTANT: use -c so stdin is free for JSON (no heredoc for code)
printf '%s' "$ROUTE_JSON" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
d = json.loads(raw) if raw else {}

mode = d.get("mode") or "unknown"
model = d.get("model") or "unknown"
esc = d.get("escalation")
if isinstance(esc, list) and esc:
    chain = "->".join(str(x) for x in esc)
else:
    chain = "-"

print(f"mode={mode} model={model} escalation={chain}")
'
