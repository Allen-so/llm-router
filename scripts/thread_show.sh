#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

THREAD="${1:-}"
N="${2:-30}"

if [[ -z "$THREAD" ]]; then
  echo "Usage: $0 <thread_name> [n=30]" >&2
  exit 2
fi

SAFE="$(printf '%s' "$THREAD" | tr -cs 'A-Za-z0-9._-' '_' )"
FILE="$ROOT/logs/threads/${SAFE}.jsonl"

python3 - <<'PY' "$FILE" "$N"
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
n = int(sys.argv[2])

if not path.exists():
    print(f"(no thread file) {path}")
    raise SystemExit(0)

lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
items=[]
for ln in lines:
    ln=ln.strip()
    if not ln: 
        continue
    try:
        items.append(json.loads(ln))
    except Exception:
        continue

tail = items[-n:] if n>0 else items
for it in tail:
    role = it.get("role","?")
    ts = it.get("ts","")
    model = it.get("model","")
    prefix = "U>" if role=="user" else ("A>" if role=="assistant" else "S>")
    meta = f"{ts}" + (f" [{model}]" if model else "")
    content = (it.get("content") or "").rstrip()
    print(f"{prefix} {meta}\n{content}\n")
PY
