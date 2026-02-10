#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

strip_crlf() { tr -d '\r'; }
die() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }

# ---- load env (best-effort) ----
if [[ -z "${LITELLM_MASTER_KEY:-}" || -z "${LITELLM_BASE_URL:-}" ]]; then
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ROOT_DIR}/.env"
    set +a
  fi
fi

BASE_URL="${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}"
BASE_URL="$(printf "%s" "${BASE_URL}" | strip_crlf)"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"
MASTER_KEY="$(printf "%s" "${MASTER_KEY}" | strip_crlf)"

[[ -n "${MASTER_KEY}" ]] || die "LITELLM_MASTER_KEY missing (set env or .env)."

HEALTH_URL="${BASE_URL%/}/../health/readiness"
MODELS_URL="${BASE_URL%/}/models"
CHAT_URL="${BASE_URL%/}/chat/completions"

# cost control: premium off by default
INCLUDE_PREMIUM="${INCLUDE_PREMIUM:-0}"  # set INCLUDE_PREMIUM=1 to include premium-chat in live regress

AUTH_HEADER="Authorization: Bearer ${MASTER_KEY}"

# ---- helpers ----
parse_content_from_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
raw = open(path, "r", encoding="utf-8", errors="replace").read().strip()
if not raw:
  sys.exit(0)
try:
  obj = json.loads(raw)
except Exception:
  print(raw, end="")
  sys.exit(0)
try:
  c = obj["choices"][0]["message"]["content"]
  if isinstance(c, str):
    print(c, end="")
    sys.exit(0)
except Exception:
  pass
# fallbacks
try:
  t = obj["choices"][0].get("text")
  if isinstance(t, str):
    print(t, end="")
    sys.exit(0)
except Exception:
  pass
err = obj.get("error")
if isinstance(err, dict) and isinstance(err.get("message"), str):
  print(err["message"], end="")
PY
}

parse_ids_from_models_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
obj = json.loads(open(path, "r", encoding="utf-8", errors="replace").read())
ids = []
for it in obj.get("data", []):
  if isinstance(it, dict) and isinstance(it.get("id"), str):
    ids.append(it["id"])
print("\n".join(ids))
PY
}

curl_json() {
  # outputs: body to stdout, http_code to stderr marker
  local url="$1"
  local data="${2:-}"
  local tmp
  tmp="$(mktemp)"
  if [[ -n "${data}" ]]; then
    # POST
    local out
    out="$(curl -sS -o "${tmp}" -w "%{http_code}" \
      -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
      -d "${data}" "${url}" || true)"
    echo "${out}"
  else
    # GET
    local out
    out="$(curl -sS -o "${tmp}" -w "%{http_code}" \
      -H "${AUTH_HEADER}" "${url}" || true)"
    echo "${out}"
  fi
  cat "${tmp}"
  rm -f "${tmp}"
}

# Because we need both body and code reliably:
http_get_to_file() {
  local url="$1" file="$2"
  local code
  code="$(curl -sS -o "${file}" -w "%{http_code}" -H "${AUTH_HEADER}" "${url}" || true)"
  printf "%s" "${code}"
}

http_post_to_file() {
  local url="$1" data="$2" file="$3"
  local code
  code="$(curl -sS -o "${file}" -w "%{http_code}" \
    -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
    -d "${data}" "${url}" || true)"
  printf "%s" "${code}"
}

require_model_present() {
  local model="$1" models_file="$2"
  if ! grep -qx "${model}" "${models_file}"; then
    die "model not exposed by /v1/models: '${model}'"
  fi
}

call_model_expect_ok() {
  local model="$1" temp="$2" name="$3"
  local prompt='Reply exactly with: ROUTER_OK'
  local payload
  payload="$(python3 - <<PY
import json
print(json.dumps({
  "model": "${model}",
  "temperature": float("${temp}"),
  "messages": [{"role":"user","content":"${prompt}"}]
}))
PY
)"
  local resp_file code t0 t1 content
  resp_file="$(mktemp)"
  t0="$(date +%s%3N)"
  code="$(http_post_to_file "${CHAT_URL}" "${payload}" "${resp_file}")"
  t1="$(date +%s%3N)"
  local ms=$((t1-t0))

  if [[ "${code}" != "200" ]]; then
    echo "[${name}] HTTP ${code} (${ms}ms)" >&2
    echo "[${name}] body (first 400 chars):" >&2
    head -c 400 "${resp_file}" >&2; echo >&2
    rm -f "${resp_file}"
    die "${name} failed (http ${code})"
  fi

  content="$(parse_content_from_file "${resp_file}" | strip_crlf | tr -d '\n' | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
  rm -f "${resp_file}"

  if [[ "${content}" != "ROUTER_OK" ]]; then
    echo "[${name}] content mismatch (${ms}ms): '${content}'" >&2
    die "${name} failed (content mismatch)"
  fi

  echo "PASS: ${name} (${ms}ms) model=${model}"
}

# ---- 0) readiness (no auth) ----
info "readiness"
if ! curl -sS "${HEALTH_URL}" | grep -q '"status":"healthy"'; then
  echo "readiness body:" >&2
  curl -sS "${HEALTH_URL}" >&2 || true
  die "router not healthy at ${HEALTH_URL}"
fi
echo "PASS: readiness"

# ---- 1) models ----
info "models"
models_json="$(mktemp)"
code="$(http_get_to_file "${MODELS_URL}" "${models_json}")"
if [[ "${code}" != "200" ]]; then
  echo "models HTTP ${code}" >&2
  head -c 400 "${models_json}" >&2; echo >&2
  rm -f "${models_json}"
  die "GET /v1/models failed"
fi

models_ids="$(mktemp)"
parse_ids_from_models_file "${models_json}" > "${models_ids}"
rm -f "${models_json}"

# required baseline models
require_model_present "default-chat" "${models_ids}"
require_model_present "long-chat" "${models_ids}"
require_model_present "best-effort-chat" "${models_ids}"
if [[ "${INCLUDE_PREMIUM}" == "1" ]]; then
  require_model_present "premium-chat" "${models_ids}"
fi
rm -f "${models_ids}"
echo "PASS: models list + required ids"

# ---- 2) live calls (token cost) ----
info "live calls"
call_model_expect_ok "default-chat" "0.2" "router:default-chat"
call_model_expect_ok "long-chat" "1"   "router:long-chat"
call_model_expect_ok "best-effort-chat" "0.2" "router:best-effort-chat"
if [[ "${INCLUDE_PREMIUM}" == "1" ]]; then
  call_model_expect_ok "premium-chat" "0.2" "router:premium-chat"
else
  echo "SKIP: router:premium-chat (set INCLUDE_PREMIUM=1 to include)" >&2
fi

# ---- 3) ask.sh integration (route + log + meta pipeline) ----
info "ask.sh pipeline"
out="$(./scripts/ask.sh auto "Reply exactly with: ROUTER_OK" | strip_crlf | head -n1 || true)"
[[ "${out}" == "ROUTER_OK" ]] || die "ask.sh auto failed (got '${out}')"

meta="$(./scripts/ask.sh --meta auto "Reply exactly with: ROUTER_OK" 2>&1 >/dev/null || true)"
echo "${meta}" | grep -q "meta: mode=" || die "ask.sh --meta missing meta line"
echo "PASS: ask.sh auto + --meta"

echo "== OK: live regress completed =="
