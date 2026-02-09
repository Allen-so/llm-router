#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE_DEFAULT="${LOG_DIR}/ask_history.log"

debug() { [[ "${ROUTER_DEBUG:-0}" == "1" ]] && echo "[debug] $*" >&2 || true; }

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/ask.sh [--meta] <mode|auto> <text...>
  echo "text" | ./scripts/ask.sh [--meta] <mode|auto> -

Modes:
  auto | daily | default | coding | long | hard | best-effort | premium
Notes:
  - Default output: assistant content only (stdout).
  - --meta prints a concise meta line (stderr).
Env:
  LITELLM_BASE_URL    default: http://127.0.0.1:4000/v1
  LITELLM_MASTER_KEY  required (auto-load from .env if missing)
  ROUTER_DEBUG=1      debug logs to stderr
EOF
}

strip_crlf() { tr -d '\r'; }
ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_ms() { date +%s%3N; }

# ---------- parse args ----------
META=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --meta) META=1 ;;
    --help|-h) usage; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done

if [[ "${#ARGS[@]}" -lt 2 ]]; then
  usage
  exit 2
fi

MODE_IN="${ARGS[0]}"
TEXT_IN="${ARGS[@]:1}"

if [[ "${TEXT_IN}" == "-" ]]; then
  TEXT="$(cat)"
else
  TEXT="${TEXT_IN}"
fi

# ---------- env & auth ----------
mkdir -p "${LOG_DIR}"

LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}"
LITELLM_BASE_URL="$(printf "%s" "${LITELLM_BASE_URL}" | strip_crlf)"
API_URL="${LITELLM_BASE_URL%/}/chat/completions"

if [[ -z "${LITELLM_MASTER_KEY:-}" && -f "${ROOT_DIR}/.env" ]]; then
  LITELLM_MASTER_KEY="$(grep -E '^LITELLM_MASTER_KEY=' "${ROOT_DIR}/.env" | head -n1 | cut -d= -f2- | strip_crlf || true)"
fi
if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "ERROR: LITELLM_MASTER_KEY is not set (.env or export)." >&2
  exit 3
fi
AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY}"

# ---------- routing ----------
ESCALATION_CHAIN="${ESCALATION_CHAIN:-best-effort-chat->premium-chat}"

map_mode_to_model() {
  case "$1" in
    auto) echo "" ;;
    daily|default|default-chat|coding) echo "default-chat" ;;
    long|long-chat) echo "long-chat" ;;
    hard) echo "best-effort-chat" ;;
    best-effort|best-effort-chat) echo "best-effort-chat" ;;
    premium|premium-chat) echo "premium-chat" ;;
    deepseek-chat|kimi-chat) echo "$1" ;;
    *) echo "$1" ;;
  esac
}

MODE="${MODE_IN}"
MODEL=""

if [[ "${MODE_IN}" == "auto" ]]; then
  ROUTE_OUT="$(python3 "${ROOT_DIR}/scripts/route.py" "${TEXT}" 2>/dev/null || true)"
  debug "route.py => ${ROUTE_OUT}"

  MODE="$(printf "%s" "${ROUTE_OUT}" | sed -n 's/.*mode=\([^ ]*\).*/\1/p')"
  MODEL="$(printf "%s" "${ROUTE_OUT}" | sed -n 's/.*model=\([^ ]*\).*/\1/p')"
  ESCALATION_CHAIN="$(printf "%s" "${ROUTE_OUT}" | sed -n 's/.*escalation=\([^ ]*\).*/\1/p')"

  MODE="${MODE:-daily}"
  MODEL="${MODEL:-default-chat}"
  ESCALATION_CHAIN="${ESCALATION_CHAIN:-best-effort-chat->premium-chat}"
else
  MODEL="$(map_mode_to_model "${MODE_IN}")"
fi

MODE="${MODE:-${MODE_IN}}"
MODEL="${MODEL:-default-chat}"
ESCALATION_CHAIN="${ESCALATION_CHAIN:-best-effort-chat->premium-chat}"

ALLOW_ESCALATION=0
case "${MODE}" in
  hard|best-effort|best-effort-chat) ALLOW_ESCALATION=1 ;;
esac

TEMP="${TEMP:-0.2}"
if [[ "${MODEL}" == "kimi-chat" || "${MODEL}" == "long-chat" ]]; then
  TEMP="1"
fi

debug "mode=${MODE} model=${MODEL} allow_escalation=${ALLOW_ESCALATION} temp=${TEMP}"
debug "api_url=${API_URL}"

build_payload() {
  MODEL="$1" TEXT="$TEXT" TEMP="$TEMP" python3 - <<'PY'
import json, os
model = os.environ["MODEL"]
text  = os.environ.get("TEXT","")
temp  = float(os.environ.get("TEMP","0.2"))
print(json.dumps({
  "model": model,
  "temperature": temp,
  "messages": [{"role":"user","content": text}]
}))
PY
}

post_chat() {
  local model="$1"
  local payload
  payload="$(build_payload "${model}")"
  curl -sS \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    -w "\n__HTTP_CODE:%{http_code}\n" \
    "${API_URL}"
}

# ---------- parse response (single JSON out) ----------
# stdin: response json (string)
# stdout: {"content":"...","tokens":"13"}  tokens may be ""
parse_content_tokens_json() {
  python3 - <<'PY'
import json, sys
raw = sys.stdin.read().strip()
out = {"content":"", "tokens":""}
if not raw:
  print(json.dumps(out, ensure_ascii=False)); sys.exit(0)

try:
  obj = json.loads(raw)
except Exception:
  out["content"] = raw
  print(json.dumps(out, ensure_ascii=False)); sys.exit(0)

content = ""

# chat.completions
choices = obj.get("choices")
if isinstance(choices, list) and choices and isinstance(choices[0], dict):
  ch = choices[0]
  msg = ch.get("message")
  if isinstance(msg, dict):
    c = msg.get("content", "")
    if isinstance(c, str):
      content = c
    elif isinstance(c, list):
      parts = []
      for p in c:
        if isinstance(p, dict) and isinstance(p.get("text"), str):
          parts.append(p["text"])
        elif isinstance(p, str):
          parts.append(p)
      content = "".join(parts)
  if not content and isinstance(ch.get("text"), str):
    content = ch["text"]
  if not content:
    delta = ch.get("delta")
    if isinstance(delta, dict) and isinstance(delta.get("content"), str):
      content = delta["content"]

# fallback schemas
if not content and isinstance(obj.get("output_text"), str):
  content = obj["output_text"]

# sometimes error is still wrapped
if not content:
  err = obj.get("error")
  if isinstance(err, dict) and isinstance(err.get("message"), str):
    content = err["message"]

tok = ""
u = obj.get("usage")
if isinstance(u, dict):
  tt = u.get("total_tokens")
  if isinstance(tt, int):
    tok = str(tt)
  else:
    it = u.get("input_tokens")
    ot = u.get("output_tokens")
    if isinstance(it, int) and isinstance(ot, int):
      tok = str(it + ot)

out["content"] = content or ""
out["tokens"] = tok or ""
print(json.dumps(out, ensure_ascii=False))
PY
}

get_json_field() {
  local key="$1"
  python3 - <<PY
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(str(d.get("${key}", "")))
PY
}

# ---------- call primary ----------
ESCALATED=0
MODEL_USED="${MODEL}"

START_MS="$(now_ms)"
OUT="$(post_chat "${MODEL}" || true)"
END_MS="$(now_ms)"
MS=$((END_MS-START_MS))

RC="$(printf "%s" "${OUT}" | sed -n 's/^__HTTP_CODE:\([0-9][0-9][0-9]\)$/\1/p' | tail -n1)"
RESP="$(printf "%s" "${OUT}" | sed '/^__HTTP_CODE:[0-9][0-9][0-9]$/d')"
[[ -z "${RC}" ]] && RC=0

PARSED_JSON="$(printf "%s" "${RESP}" | parse_content_tokens_json)"
CONTENT="$(printf "%s" "${PARSED_JSON}" | get_json_field content)"
TOKENS="$(printf "%s" "${PARSED_JSON}" | get_json_field tokens)"

fail_or_empty() {
  [[ "${RC}" -ne 200 ]] && return 0
  [[ -z "${CONTENT}" ]] && return 0
  return 1
}

# ---------- optional escalation ----------
if fail_or_empty && [[ "${ALLOW_ESCALATION}" -eq 1 ]]; then
  IFS='->' read -r -a chain <<<"${ESCALATION_CHAIN}"
  next=""
  for i in "${!chain[@]}"; do
    if [[ "${chain[$i]}" == "${MODEL}" ]]; then
      [[ $((i+1)) -lt "${#chain[@]}" ]] && next="${chain[$((i+1))]}"
      break
    fi
  done

  if [[ -n "${next}" ]]; then
    debug "escalate: ${MODEL} -> ${next} (rc=${RC})"
    ESCALATED=1
    MODEL_USED="${next}"

    START_MS="$(now_ms)"
    OUT="$(post_chat "${next}" || true)"
    END_MS="$(now_ms)"
    MS=$((END_MS-START_MS))

    RC="$(printf "%s" "${OUT}" | sed -n 's/^__HTTP_CODE:\([0-9][0-9][0-9]\)$/\1/p' | tail -n1)"
    RESP="$(printf "%s" "${OUT}" | sed '/^__HTTP_CODE:[0-9][0-9][0-9]$/d')"
    [[ -z "${RC}" ]] && RC=0

    PARSED_JSON="$(printf "%s" "${RESP}" | parse_content_tokens_json)"
    CONTENT="$(printf "%s" "${PARSED_JSON}" | get_json_field content)"
    TOKENS="$(printf "%s" "${PARSED_JSON}" | get_json_field tokens)"
  fi
fi

STATUS="ok"
if [[ "${RC}" -ne 200 || -z "${CONTENT}" ]]; then
  STATUS="empty"
fi

if [[ "${STATUS}" != "ok" && "${RC}" -eq 200 && ( "${META}" -eq 1 || "${ROUTER_DEBUG:-0}" == "1" ) ]]; then
  echo "[debug] rc=200 but content empty. raw response (first 800 chars):" >&2
  printf "%s" "${RESP}" | head -c 800 >&2
  echo >&2
fi

# ---------- logging ----------
LOG_FILE="${ASK_LOG_FILE:-${LOG_FILE_DEFAULT}}"
LOG_FILE="$(printf "%s" "${LOG_FILE}" | strip_crlf)"

printf "%s mode=%s model=%s status=%s rc=%s tokens=%s ms=%s escalated=%s\n" \
  "$(ts_utc)" "${MODE}" "${MODEL_USED}" "${STATUS}" "${RC}" "${TOKENS:-}" "${MS}" "${ESCALATED}" >> "${LOG_FILE}"

# ---------- output ----------
if [[ -n "${CONTENT}" ]]; then
  printf "%s\n" "${CONTENT}"
else
  printf "ERROR: empty response (rc=%s)\n" "${RC}" >&2
fi

if [[ "${META}" -eq 1 ]]; then
  printf "meta: mode=%s model=%s rc=%s tokens=%s ms=%s escalated=%s\n" \
    "${MODE}" "${MODEL_USED}" "${RC}" "${TOKENS:-}" "${MS}" "${ESCALATED}" >&2
fi

[[ "${STATUS}" == "ok" ]] || exit 10
