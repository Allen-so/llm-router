#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE_DEFAULT="${LOG_DIR}/ask_history.log"
PROFILES_DIR="${ROOT_DIR}/infra/profiles"

debug() { [[ "${ROUTER_DEBUG:-0}" == "1" ]] && echo "[debug] $*" >&2 || true; }

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/ask.sh [--meta] [--profile <name|path>] [--json] [--pretty] [--out <file>] <mode|auto> <text...>
  echo "text" | ./scripts/ask.sh [--meta] [--profile <name|path>] [--json] [--pretty] [--out <file>] <mode|auto> -

Modes:
  auto | daily | default | coding | long | hard | best-effort | premium

Profiles:
  --profile dev     -> infra/profiles/dev.txt
  --profile debug   -> infra/profiles/debug.txt
  --profile <path>  -> use an explicit file path
  --no-profile      -> disable profile for this call

JSON:
  --json            -> force a single JSON object output (no markdown / no code fences)
  --pretty          -> pretty-print JSON (only with --json)
  --out <file>      -> also save JSON to a file (only with --json)

Notes:
  - Default output: assistant content only (stdout).
  - --meta prints: mode/model/rc/tokens/ms/escalated/profile/format (stderr).
Env:
  LITELLM_BASE_URL    default: http://127.0.0.1:4000/v1
  LITELLM_MASTER_KEY  required (auto-load from .env if missing)
  ASK_PROFILE         optional default profile name
  ROUTER_DEBUG=1      debug to stderr
EOF
}

strip_crlf() { tr -d '\r'; }
ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_ms() { date +%s%3N; }

# ---------- args ----------
META=0
PROFILE_NAME="${ASK_PROFILE:-}"
PROFILE_PATH=""
JSON_MODE=0
JSON_PRETTY=0
JSON_OUT=""

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --meta)
      META=1; shift;;
    --profile)
      [[ $# -ge 2 ]] || { echo "ERROR: --profile requires a value" >&2; exit 2; }
      PROFILE_NAME="$2"; shift 2;;
    --no-profile)
      PROFILE_NAME=""
      PROFILE_PATH=""
      shift;;
    --json)
      JSON_MODE=1; shift;;
    --pretty)
      JSON_PRETTY=1; shift;;
    --out)
      [[ $# -ge 2 ]] || { echo "ERROR: --out requires a file path" >&2; exit 2; }
      JSON_OUT="$2"; shift 2;;
    --help|-h)
      usage; exit 0;;
    *)
      ARGS+=("$1"); shift;;
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

if [[ "${JSON_MODE}" -eq 0 && ( "${JSON_PRETTY}" -eq 1 || -n "${JSON_OUT}" ) ]]; then
  echo "ERROR: --pretty/--out requires --json" >&2
  exit 2
fi

# ---------- resolve profile path ----------
if [[ -n "${PROFILE_NAME}" ]]; then
  if [[ "${PROFILE_NAME}" == *"/"* || "${PROFILE_NAME}" == *.txt || "${PROFILE_NAME}" == *.md ]]; then
    PROFILE_PATH="${PROFILE_NAME}"
  else
    if [[ -f "${PROFILES_DIR}/${PROFILE_NAME}.txt" ]]; then
      PROFILE_PATH="${PROFILES_DIR}/${PROFILE_NAME}.txt"
    elif [[ -f "${PROFILES_DIR}/${PROFILE_NAME}.md" ]]; then
      PROFILE_PATH="${PROFILES_DIR}/${PROFILE_NAME}.md"
    else
      echo "ERROR: profile not found: ${PROFILE_NAME}" >&2
      echo "Available profiles:" >&2
      ls -1 "${PROFILES_DIR}" 2>/dev/null || true
      exit 2
    fi
  fi

  if [[ ! -f "${PROFILE_PATH}" ]]; then
    echo "ERROR: profile file not found: ${PROFILE_PATH}" >&2
    exit 2
  fi
fi

# ---------- env/auth ----------
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

FORMAT_TAG="text"
[[ "${JSON_MODE}" -eq 1 ]] && FORMAT_TAG="json"

debug "mode=${MODE} model=${MODEL} allow_escalation=${ALLOW_ESCALATION} temp=${TEMP} profile=${PROFILE_PATH:-none} format=${FORMAT_TAG}"
debug "api_url=${API_URL}"

json_directive() {
  cat <<'TXT'
Return ONLY a single JSON object and nothing else.
- No markdown, no code fences, no surrounding text.
- Must be valid JSON (double quotes, no trailing commas).
- Use this schema (keys required unless marked optional):

{
  "decision": "string",
  "steps": ["string"],
  "commands": ["string"],
  "patches": [
    {
      "path": "string",
      "content": "string"
    }
  ],
  "verify": ["string"],
  "risks": ["string"],
  "notes": ["string"]  // optional
}

Rules:
- If you have no commands or patches, return empty arrays.
- Keep strings concise; do not embed markdown fences.
TXT
}

build_payload() {
  MODEL="$1" TEXT="$TEXT" TEMP="$TEMP" PROFILE_PATH="$PROFILE_PATH" JSON_MODE="$JSON_MODE" python3 - <<'PY'
import json, os, pathlib

model = os.environ["MODEL"]
text  = os.environ.get("TEXT","")
temp  = float(os.environ.get("TEMP","0.2"))
pp    = os.environ.get("PROFILE_PATH","").strip()
json_mode = os.environ.get("JSON_MODE","0") == "1"

messages = []
if pp:
  sys_txt = pathlib.Path(pp).read_text(encoding="utf-8", errors="replace")
  messages.append({"role":"system","content": sys_txt})

if json_mode:
  # second system message: hard constraint for machine-consumable output
  directive = """Return ONLY a single JSON object and nothing else.
No markdown, no code fences, no surrounding text. Must be valid JSON.

Schema:
{
  "decision": "string",
  "steps": ["string"],
  "commands": ["string"],
  "patches": [{"path":"string","content":"string"}],
  "verify": ["string"],
  "risks": ["string"],
  "notes": ["string"]
}

If no commands/patches, use empty arrays. Keep strings concise."""
  messages.append({"role":"system","content": directive})

messages.append({"role":"user","content": text})

print(json.dumps({
  "model": model,
  "temperature": temp,
  "messages": messages
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

# ---------- file-based extractor ----------
extract_from_file() {
  local file="$1"
  local kind="$2"   # content | tokens
  python3 - "$file" "$kind" <<'PY'
import json, sys
path = sys.argv[1]
kind = sys.argv[2]

try:
  raw = open(path, "r", encoding="utf-8", errors="replace").read().strip()
except Exception:
  raw = ""

if not raw:
  sys.exit(0)

try:
  obj = json.loads(raw)
except Exception:
  if kind == "content":
    sys.stdout.write(raw)
  sys.exit(0)

def get_content(o):
  choices = o.get("choices")
  if isinstance(choices, list) and choices and isinstance(choices[0], dict):
    ch = choices[0]
    msg = ch.get("message")
    if isinstance(msg, dict):
      c = msg.get("content", "")
      if isinstance(c, str):
        return c
      if isinstance(c, list):
        parts = []
        for p in c:
          if isinstance(p, dict) and isinstance(p.get("text"), str):
            parts.append(p["text"])
          elif isinstance(p, str):
            parts.append(p)
        return "".join(parts)
    t = ch.get("text")
    if isinstance(t, str) and t:
      return t
    delta = ch.get("delta")
    if isinstance(delta, dict) and isinstance(delta.get("content"), str):
      return delta["content"]

  ot = o.get("output_text")
  if isinstance(ot, str) and ot:
    return ot

  err = o.get("error")
  if isinstance(err, dict) and isinstance(err.get("message"), str):
    return err["message"]

  return ""

def get_tokens(o):
  u = o.get("usage")
  if isinstance(u, dict):
    tt = u.get("total_tokens")
    if isinstance(tt, int):
      return str(tt)
    it = u.get("input_tokens")
    ot = u.get("output_tokens")
    if isinstance(it, int) and isinstance(ot, int):
      return str(it + ot)
  return ""

if kind == "content":
  sys.stdout.write(get_content(obj) or "")
else:
  sys.stdout.write(get_tokens(obj) or "")
PY
}

# ---------- json sanitizer/validator ----------
sanitize_json() {
  local input="$1"
  python3 - "$input" <<'PY'
import json, sys

s = sys.argv[1]

def try_load(x):
  try:
    return json.loads(x)
  except Exception:
    return None

obj = try_load(s)

if obj is None:
  # attempt to extract first {...last} block
  a = s.find("{")
  b = s.rfind("}")
  if a != -1 and b != -1 and b > a:
    candidate = s[a:b+1]
    obj = try_load(candidate)

if obj is None or not isinstance(obj, dict):
  sys.exit(2)

# any missing keys? enforce baseline keys exist (notes optional)
required = ["decision","steps","commands","patches","verify","risks"]
for k in required:
  if k not in obj:
    sys.exit(3)

# normalize types to avoid weird model outputs
def ensure_list_str(v):
  if isinstance(v, list):
    return [str(x) for x in v]
  return []

obj["steps"] = ensure_list_str(obj.get("steps"))
obj["commands"] = ensure_list_str(obj.get("commands"))
obj["verify"] = ensure_list_str(obj.get("verify"))
obj["risks"] = ensure_list_str(obj.get("risks"))

patches = obj.get("patches")
if not isinstance(patches, list):
  patches = []
norm = []
for p in patches:
  if isinstance(p, dict):
    path = p.get("path","")
    content = p.get("content","")
    if isinstance(path, str) and isinstance(content, str) and path.strip():
      norm.append({"path": path.strip(), "content": content})
obj["patches"] = norm

print(json.dumps(obj, ensure_ascii=False))
PY
}

pretty_json() {
  local input="$1"
  python3 - "$input" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
print(json.dumps(obj, ensure_ascii=False, indent=2))
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

TMP="$(mktemp)"
printf "%s" "${RESP}" > "${TMP}"
CONTENT="$(extract_from_file "${TMP}" content || true)"
TOKENS="$(extract_from_file "${TMP}" tokens || true)"
rm -f "${TMP}"

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

    TMP="$(mktemp)"
    printf "%s" "${RESP}" > "${TMP}"
    CONTENT="$(extract_from_file "${TMP}" content || true)"
    TOKENS="$(extract_from_file "${TMP}" tokens || true)"
    rm -f "${TMP}"
  fi
fi

STATUS="ok"
if [[ "${RC}" -ne 200 || -z "${CONTENT}" ]]; then
  STATUS="empty"
fi

# ---------- json mode post-process ----------
JSON_VALID=1
if [[ "${JSON_MODE}" -eq 1 && -n "${CONTENT}" && "${RC}" -eq 200 ]]; then
  if ! CLEAN_JSON="$(sanitize_json "${CONTENT}")"; then
    JSON_VALID=0
  else
    if [[ "${JSON_PRETTY}" -eq 1 ]]; then
      CLEAN_JSON="$(pretty_json "${CLEAN_JSON}")"
    fi
    CONTENT="${CLEAN_JSON}"
  fi
fi

if [[ "${JSON_MODE}" -eq 1 && "${JSON_VALID}" -eq 0 ]]; then
  STATUS="json_invalid"
  echo "ERROR: model did not return valid JSON (or schema mismatch)." >&2
  if [[ "${ROUTER_DEBUG:-0}" == "1" || "${META}" -eq 1 ]]; then
    echo "[debug] raw content (first 800 chars):" >&2
    printf "%s" "${CONTENT}" | head -c 800 >&2
    echo >&2
  fi
fi

# ---------- logging ----------
LOG_FILE="${ASK_LOG_FILE:-${LOG_FILE_DEFAULT}}"
LOG_FILE="$(printf "%s" "${LOG_FILE}" | strip_crlf)"
PROFILE_TAG="${PROFILE_NAME:-}"

printf "%s mode=%s model=%s status=%s rc=%s tokens=%s ms=%s escalated=%s profile=%s format=%s\n" \
  "$(ts_utc)" "${MODE}" "${MODEL_USED}" "${STATUS}" "${RC}" "${TOKENS:-}" "${MS}" "${ESCALATED}" "${PROFILE_TAG}" "${FORMAT_TAG}" >> "${LOG_FILE}"

# ---------- output ----------
if [[ -n "${CONTENT}" && "${STATUS}" != "empty" && "${STATUS}" != "json_invalid" ]]; then
  printf "%s\n" "${CONTENT}"
  if [[ "${JSON_MODE}" -eq 1 && -n "${JSON_OUT}" ]]; then
    mkdir -p "$(dirname "${JSON_OUT}")" 2>/dev/null || true
    printf "%s\n" "${CONTENT}" > "${JSON_OUT}"
  fi
else
  if [[ "${STATUS}" == "json_invalid" ]]; then
    exit 11
  fi
  printf "ERROR: empty response (rc=%s)\n" "${RC}" >&2
fi

if [[ "${META}" -eq 1 ]]; then
  printf "meta: mode=%s model=%s rc=%s tokens=%s ms=%s escalated=%s profile=%s format=%s\n" \
    "${MODE}" "${MODEL_USED}" "${RC}" "${TOKENS:-}" "${MS}" "${ESCALATED}" "${PROFILE_TAG}" "${FORMAT_TAG}" >&2
fi

[[ "${STATUS}" == "ok" ]] || exit 10
