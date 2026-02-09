#!/usr/bin/env bash
# __ASK_SAFE_BASEURL_V2__
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="$ROOT/infra/router_rules.json"

# 强制固定（先把系统跑稳，再考虑开放 LITELLM_BASE_URL）
BASE_URL="$(printf '%s' "${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}" | tr -d '\r\n' | sed 's/[[:space:]]\+$//')"
if [[ "$BASE_URL" != http*://* ]]; then
  BASE_URL="http://127.0.0.1:4000/v1"
fi

MODE="${1:-}"; shift || true
PROMPT="${*:-}"
if [[ -z "$MODE" || -z "$PROMPT" ]]; then
  echo "Usage: $0 <auto|daily|coding|long|hard|premium|best-effort> \"prompt...\""
  exit 2
fi

mkdir -p "$ROOT/logs"
DEBUG_LOG="$ROOT/logs/ask_last_run.log"
HIST_LOG="$ROOT/logs/ask_history.log"

# 保存命令行传入的 debug，避免被 .env 覆盖
DEBUG="${ROUTER_DEBUG:-0}"

log() { [[ "$DEBUG" == "1" ]] && echo "$*" >> "$DEBUG_LOG"; }

if [[ "$DEBUG" == "1" ]]; then
  : > "$DEBUG_LOG"  # 必定创建文件
  log "[ask] debug=1 log=$DEBUG_LOG"
fi

# 载入 .env（只用来拿 master key 等 secrets）
set -a
source "$ROOT/.env"
set +a

# 恢复 debug
ROUTER_DEBUG="$DEBUG"

AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY:?missing LITELLM_MASTER_KEY}"

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }

log "[ask] base_url=$BASE_URL"
log "[ask] mode_in=$MODE"

# route.py: <rules_path> <mode> <msg>
route_json="$(python3 "$ROOT/scripts/route.py" "$RULES" "$MODE" "$PROMPT")"
route_mode="$(printf '%s' "$route_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("mode","unknown"))')"
route_model="$(printf '%s' "$route_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("model","unknown"))')"
route_prefix="$(printf '%s' "$route_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("prefix",""))')"

log "[ask] route_mode=$route_mode route_model=$route_model"

TEMP="${ROUTER_TEMPERATURE:-0.2}"
if [[ "$route_model" == "kimi-chat" || "$route_model" == "long-chat" ]]; then
  TEMP="1"
fi

call_api() {
  local model="$1"
  local temp="$2"

  local payload
  payload="$(MODEL="$model" PROMPT="$PROMPT" PREFIX="$route_prefix" TEMP="$temp" python3 -c '
import os, json
model=os.environ["MODEL"]
prompt=os.environ["PROMPT"]
prefix=os.environ.get("PREFIX","")
temp=float(os.environ["TEMP"])
msgs=[]
if prefix.strip():
  msgs.append({"role":"system","content":prefix})
msgs.append({"role":"user","content":prompt})
print(json.dumps({"model":model,"messages":msgs,"temperature":temp}, ensure_ascii=False))
')"

  local t0 t1 resp rc
  t0="$(now_ms)"

  # 防止 set -e 因 curl 非 0 直接秒退（你之前“窗口一闪就没”多半就是这个）
  set +e
  resp="$(curl -sS --max-time 120 --retry 2 --retry-all-errors \
    "$BASE_URL/chat/completions" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  rc=$?
  set -e

  t1="$(now_ms)"
  echo "$rc|$((t1 - t0))|$resp"
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

result="$(call_api "$route_model" "$TEMP")"
RC="${result%%|*}"
rest="${result#*|}"
MS="${rest%%|*}"
RESP="${rest#*|}"

CONTENT="$(printf '%s' "$RESP" | parse_content 2>/dev/null || true)"
TOKENS="$(printf '%s' "$RESP" | parse_tokens 2>/dev/null || echo "-")"

status="ok"
if [[ "$RC" != "0" || -z "$CONTENT" ]]; then
  status="empty"
fi

# 只对 best-effort 做升级
if [[ "$status" == "empty" && "$route_model" == "best-effort-chat" ]]; then
  log "[ask] escalate best-effort-chat -> premium-chat"
  route_model="premium-chat"

  result="$(call_api "$route_model" "0.2")"
  RC="${result%%|*}"
  rest="${result#*|}"
  MS="${rest%%|*}"
  RESP="${rest#*|}"

  CONTENT="$(printf '%s' "$RESP" | parse_content 2>/dev/null || true)"
  TOKENS="$(printf '%s' "$RESP" | parse_tokens 2>/dev/null || echo "-")"

  status="ok"
  if [[ "$RC" != "0" || -z "$CONTENT" ]]; then
    status="empty"
  fi
fi

echo "$(ts_utc) mode=$route_mode model=$route_model status=$status rc=$RC tokens=$TOKENS ms=$MS" >> "$HIST_LOG"
log "[ask] done rc=$RC status=$status tokens=$TOKENS ms=$MS"
log "[ask] history -> $HIST_LOG"

# debug=1 也照样输出内容，避免你误判“没输出=关了”
printf '%s\n' "$CONTENT"

exit "$RC"
