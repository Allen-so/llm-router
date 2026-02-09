#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
V1="${BASE%/}/v1"
CHAT_URL="${V1}/chat/completions"

if [[ -f ".env" ]]; then
  set -a
  source .env
  set +a
fi

: "${LITELLM_MASTER_KEY:?Missing LITELLM_MASTER_KEY in .env}"

MODEL="${1:-default-chat}"
shift || true
MSG="${*:-hello}"

TEMP="0.2"
if [[ "$MODEL" == kimi-* || "$MODEL" == "long-chat" ]]; then
  TEMP="1"
fi

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

code="$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$CHAT_URL"   -H "Content-Type: application/json"   -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"   --data "$payload" || true)"
code="${code:-000}"

echo "HTTP=$code"
echo "---- RAW BODY (first 1200 chars) ----"
head -c 1200 "$tmp" || true
echo
echo "---- JSON TOOL (best effort) ----"
python3 -m json.tool "$tmp" 2>/dev/null || cat "$tmp"
