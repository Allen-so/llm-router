#!/usr/bin/env bash
# __ASK_P2C_RETRY_FALLBACK_V1__
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="${ROUTER_RULES_PATH:-$ROOT/infra/router_rules.json}"

MODE="${1:-}"; shift || true
PROMPT="${*:-}"
if [[ -z "$MODE" || -z "$PROMPT" ]]; then
  echo "Usage: $0 <auto|daily|coding|long|hard|premium|best-effort> \"prompt...\""
  exit 2
fi

# logging
mkdir -p "$ROOT/logs"
DEBUG="${ROUTER_DEBUG:-0}"
DEBUG_LOG="$ROOT/logs/ask_last_run.log"
HIST_LOG="$ROOT/logs/ask_history.log"

if [[ "$DEBUG" == "1" ]]; then
  : > "$DEBUG_LOG"
  exec >>"$DEBUG_LOG" 2>&1
  echo "[ask] debug=1 log=$DEBUG_LOG"
fi

# load env (secrets)
set -a
source "$ROOT/.env"
set +a

# keep debug flag even if .env contains ROUTER_DEBUG
ROUTER_DEBUG="$DEBUG"

# Base URL: env override + safe fallback + strip CR/LF/spaces
BASE_URL="$(printf '%s' "${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}" | tr -d '\r\n' | sed 's/[[:space:]]\+$//')"
if [[ "$BASE_URL" != http*://* ]]; then
  BASE_URL="http://127.0.0.1:4000/v1"
fi

AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY:?missing LITELLM_MASTER_KEY}"

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }

echo "[ask] base_url=$BASE_URL"
echo "[ask] mode_in=$MODE"

# route.py: route.py <rules_path> <mode> <msg>
route_json="$(python3 "$ROOT/scripts/route.py" "$RULES" "$MODE" "$PROMPT")"
route_mode="$(printf '%s' "$route_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("mode","unknown"))')"
route_model="$(printf '%s' "$route_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("model","unknown"))')"
route_prefix="$(printf '%s' "$route_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("prefix",""))')"

echo "[ask] route_mode=$route_mode route_model=$route_model"

# temperature rule
TEMP="${ROUTER_TEMPERATURE:-0.2}"
if [[ "$route_model" == "kimi-chat" || "$route_model" == "long-chat" ]]; then
  TEMP="1"
fi

# -------- helpers --------
build_payload() {
  local model="$1"
  local temp="$2"
  MODEL="$model" PROMPT="$PROMPT" PREFIX="$route_prefix" TEMP="$temp" python3 -c '
import os, json
model=os.environ["MODEL"]
prompt=os.environ["PROMPT"]
prefix=os.environ.get("PREFIX","")
temp=float(os.environ.get("TEMP","0.2"))
msgs=[]
if prefix.strip():
  msgs.append({"role":"system","content":prefix})
msgs.append({"role":"user","content":prompt})
print(json.dumps({"model":model,"messages":msgs,"temperature":temp}, ensure_ascii=False))
'
}

parse_content() {
  python3 -c 'import json,sys
raw=sys.stdin.read().strip()
try: d=json.loads(raw) if raw else {}
except: d={}
c=d.get("choices") or []
m=(c[0].get("message") if c else {}) or {}
print((m.get("content") or "").strip())
'
}

parse_tokens() {
  python3 -c 'import json,sys
raw=sys.stdin.read().strip()
try: d=json.loads(raw) if raw else {}
except: d={}
u=d.get("usage") or {}
print(u.get("total_tokens","-"))
'
}

# call one attempt; returns via globals: RC RESP CONTENT TOKENS ATT_MS
RC=0; RESP=""; CONTENT=""; TOKENS="-"; ATT_MS=0
call_once() {
  local model="$1"
  local temp="$2"
  local payload
  payload="$(build_payload "$model" "$temp")"
  local t0 t1 rc resp
  t0="$(now_ms)"

  set +e
  resp="$(curl -sS --max-time 120 --retry 0 \
    "$BASE_URL/chat/completions" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  rc=$?
  set -e

  t1="$(now_ms)"
  ATT_MS="$((t1 - t0))"
  RC="$rc"
  RESP="$resp"
  CONTENT="$(printf '%s' "$RESP" | parse_content 2>/dev/null || true)"
  TOKENS="$(printf '%s' "$RESP" | parse_tokens 2>/dev/null || echo "-")"
}

# retry wrapper (network/empty output)
request_with_retry() {
  local model="$1"
  local temp="$2"
  local max_try="${3:-2}"     # default 2 retries (total attempts=max_try)
  local backoff=1

  for attempt in $(seq 1 "$max_try"); do
    echo "[ask] try=$attempt/$max_try model=$model temp=$temp"
    call_once "$model" "$temp"

    if [[ "$RC" == "0" && -n "$CONTENT" ]]; then
      return 0
    fi

    # last try -> stop
    if [[ "$attempt" == "$max_try" ]]; then
      return 1
    fi

    echo "[ask] retrying in ${backoff}s (rc=$RC empty=$([[ -z "$CONTENT" ]] && echo 1 || echo 0))"
    sleep "$backoff"
    backoff="$((backoff * 2))"   # 1s -> 2s
  done
  return 1
}

# -------- strategy (P2-C) --------
# Keep ask_history.log format unchanged:
# ts mode=... model=... status=... rc=... tokens=... ms=...

start_ms="$(now_ms)"

final_model="$route_model"
final_status="empty"

# candidate sequence:
# 1) primary model
# 2) if coding fails => best-effort (then it may escalate)
# 3) if long/kimi fails => default-chat then best-effort
candidates=("$route_model")

if [[ "$route_mode" == "coding" ]]; then
  if [[ "$route_model" != "best-effort-chat" && "$route_model" != "premium-chat" ]]; then
    candidates+=("best-effort-chat")
  fi
elif [[ "$route_model" == "kimi-chat" || "$route_model" == "long-chat" ]]; then
  candidates+=("default-chat" "best-effort-chat")
fi

# dedupe while preserving order
uniq=()
seen=""
for m in "${candidates[@]}"; do
  if [[ " $seen " != *" $m "* ]]; then
    uniq+=("$m")
    seen+=" $m"
  fi
done
candidates=("${uniq[@]}")

# run candidates
for m in "${candidates[@]}"; do
  temp="$TEMP"
  if [[ "$m" == "kimi-chat" || "$m" == "long-chat" ]]; then
    temp="1"
  fi

  # best-effort escalation chain (best-effort -> premium)
  if [[ "$m" == "best-effort-chat" ]]; then
    chain=("best-effort-chat" "premium-chat")
  else
    chain=("$m")
  fi

  for cm in "${chain[@]}"; do
    ct="$temp"
    if [[ "$cm" == "kimi-chat" || "$cm" == "long-chat" ]]; then
      ct="1"
    fi

    if request_with_retry "$cm" "$ct" 2; then
      final_model="$cm"
      final_status="ok"
      break 2
    else
      # keep last rc/content/tokens for logging
      final_model="$cm"
      final_status="empty"
    fi
  done
done

end_ms="$(now_ms)"
total_ms="$((end_ms - start_ms))"

# final log + stdout
echo "$(ts_utc) mode=$route_mode model=$final_model status=$final_status rc=$RC tokens=$TOKENS ms=$total_ms" >> "$HIST_LOG"
echo "[ask] done rc=$RC status=$final_status tokens=$TOKENS ms=$total_ms"
echo "[ask] history -> $HIST_LOG"

# Always print content to stdout (so you see output even in debug)
printf '%s\n' "$CONTENT"

exit "$RC"
