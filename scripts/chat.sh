#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
V1="${BASE%/}/v1"
CHAT_URL="${V1}/chat/completions"

DEBUG="${DEBUG:-0}"

# load .env
if [[ -f ".env" ]]; then
  set -a
  source .env
  set +a
fi

: "${LITELLM_MASTER_KEY:?Missing LITELLM_MASTER_KEY in .env}"

MODEL="${MODEL:-${1:-}}"
if [[ -z "${MODEL}" ]]; then
  echo "Usage: $0 <model> <message...>"
  echo "Example: $0 default-chat \"hello\""
  exit 2
fi
shift || true

MSG="${MSG:-${*:-}}"
if [[ -z "${MSG}" ]]; then
  echo "Usage: $0 <model> <message...>"
  exit 2
fi

temp_for() {
  local m="$1"
  if [[ "$m" == kimi-* || "$m" == "long-chat" ]]; then
    echo "1"
  else
    echo "0.2"
  fi
}
TEMP="$(temp_for "$MODEL")"

payload="$(MODEL="$MODEL" TEMP="$TEMP" MSG="$MSG" python3 - <<'EOF_PY'
import os, json
print(json.dumps({
  "model": os.environ["MODEL"],
  "temperature": float(os.environ["TEMP"]),
  "stream": False,
  "messages": [{"role":"user","content": os.environ["MSG"]}]
}))
EOF_PY
)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

code="$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$CHAT_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  --data "$payload" || true)"
code="${code:-000}"

# Always show http code in debug
if [[ "$DEBUG" == "1" ]]; then
  echo "HTTP=$code" >&2
fi

if [[ ! -s "$tmp" ]]; then
  echo "FAIL: empty response body (http=$code)" >&2
  exit 1
fi

if [[ "$code" != "200" ]]; then
  echo "FAIL http=$code" >&2
  cat "$tmp" >&2
  exit 1
fi

# Print assistant content. If unexpected structure, print whole JSON in debug.
python3 - <<'EOF_PY' <"$tmp"
import json,sys
d=json.load(sys.stdin)
choices=d.get("choices") or []
msg=((choices[0] or {}).get("message") or {}).get("content") if choices else None
if msg is None:
    print(json.dumps(d, ensure_ascii=False))
else:
    # always print content, even if it's non-string
    if isinstance(msg, str):
        print(msg)
    else:
        print(json.dumps(msg, ensure_ascii=False))
EOF_PY

# Optional: full raw JSON for troubleshooting
if [[ "$DEBUG" == "1" ]]; then
  echo "---- RAW JSON ----" >&2
  python3 -m json.tool "$tmp" >&2 || cat "$tmp" >&2
fi
