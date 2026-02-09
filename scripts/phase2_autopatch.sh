#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"

req() { [[ -f "$1" ]] || { echo "ERROR: missing $1"; exit 1; }; }

req docker-compose.yml
req infra/litellm/config.yaml

mkdir -p backups scripts
cp -a docker-compose.yml "backups/docker-compose.yml.${TS}.bak"
cp -a infra/litellm/config.yaml "backups/config.yaml.${TS}.bak"
[[ -f scripts/test_models.sh ]] && cp -a scripts/test_models.sh "backups/test_models.sh.${TS}.bak" || true
[[ -f scripts/test_router.sh ]] && cp -a scripts/test_router.sh "backups/test_router.sh.${TS}.bak" || true

echo "OK: backups -> backups/*.${TS}.bak"

# -------------------------
# A) scripts/wait_ready.sh
# -------------------------
cat > scripts/wait_ready.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
READY_URL="${BASE%/}/health/readiness"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
SLEEP_SECS="${SLEEP_SECS:-1}"

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
  body="$(curl -sS --max-time 2 "$READY_URL" || true)"
  if echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"connected"'; then
    echo "READY: $READY_URL"
    exit 0
  fi
  echo "WAIT: not ready yet ($i/$MAX_ATTEMPTS)"
  sleep "$SLEEP_SECS"
done

echo "ERROR: Router not ready after $MAX_ATTEMPTS attempts."
echo "Hint: docker compose logs -n 80 litellm"
exit 1
EOF

# -------------------------
# B) scripts/test_models.sh
# -------------------------
cat > scripts/test_models.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
V1="${BASE%/}/v1"
CHAT_URL="${V1}/chat/completions"

# auto load .env
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${LITELLM_MASTER_KEY:?Missing LITELLM_MASTER_KEY in .env}"

AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY}"
JSON_HEADER="Content-Type: application/json"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

temp_for() {
  local m="$1"
  if [[ "$m" == kimi-* || "$m" == "long-chat" ]]; then
    echo "1"
  else
    echo "0.2"
  fi
}

"${here}/wait_ready.sh"

if [[ "${1:-}" == "" ]]; then
  echo "Usage: $0 <model1> [model2 ...]"
  exit 2
fi

echo "Base: ${V1}"
echo "Testing: $*"
echo

failed=0
for model in "$@"; do
  temp="$(temp_for "$model")"

  payload="$(cat <<JSON
{
  "model": "$model",
  "temperature": $temp,
  "messages": [{"role":"user","content":"ROUTER_OK"}]
}
JSON
)"
  resp="$(curl -sS -w '\n%{http_code}' -X POST "$CHAT_URL" \
    -H "$JSON_HEADER" -H "$AUTH_HEADER" \
    --data "$payload" || true)"

  code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  echo "==> $model (temperature=$temp)"
  if [[ "$code" != "200" ]]; then
    echo "FAIL http=$code"
    echo "$body"
    echo
    failed=1
    continue
  fi

  if ! echo "$body" | grep -q "ROUTER_OK"; then
    echo "FAIL (no ROUTER_OK in response)"
    echo "$body"
    echo
    failed=1
    continue
  fi

  echo "PASS"
  echo
done

exit "$failed"
EOF

# -------------------------
# C) scripts/test_router.sh
# -------------------------
cat > scripts/test_router.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:4000}"
V1="${BASE%/}/v1"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${LITELLM_MASTER_KEY:?Missing LITELLM_MASTER_KEY in .env}"
AUTH_HEADER="Authorization: Bearer ${LITELLM_MASTER_KEY}"

echo "[0/3] readiness"
./scripts/wait_ready.sh

echo "[1/3] models"
curl -sS "${V1}/models" -H "$AUTH_HEADER" | head -c 900 && echo
echo

echo "[2/3] default-chat smoke"
./scripts/test_models.sh default-chat
EOF

chmod +x scripts/wait_ready.sh scripts/test_models.sh scripts/test_router.sh

# -------------------------
# D) Patch .env.example (append only)
# -------------------------
touch .env.example
grep -q '^LITELLM_MASTER_KEY=' .env.example || cat >> .env.example <<'EOF'

# Router auth
LITELLM_MASTER_KEY=local-dev-master-key

# Providers
DEEPSEEK_API_KEY=YOUR_DEEPSEEK_KEY
MOONSHOT_API_KEY=YOUR_MOONSHOT_KEY

# Opus via Anthropic gateway (elbnt.ai)
ANTHROPIC_API_BASE=https://www.elbnt.ai
ANTHROPIC_API_KEY=YOUR_ANTHROPIC_GATEWAY_KEY

# Optional (if gateway needs it)
# LITELLM_ANTHROPIC_DISABLE_URL_SUFFIX=true
EOF

# -------------------------
# E) Patch docker-compose.yml (bind localhost + JSON logs)
#     - ports: 127.0.0.1:4000:4000
#     - env: JSON_LOGS=True, LITELLM_LOG=ERROR
# -------------------------
python3 - <<'PY'
import re, pathlib

p = pathlib.Path("docker-compose.yml")
lines = p.read_text(encoding="utf-8").splitlines(True)

# find service block "  litellm:"
start = None
for i, line in enumerate(lines):
    if re.match(r"^  litellm:\s*$", line):
        start = i
        break
if start is None:
    raise SystemExit("ERROR: cannot find service 'litellm:' in docker-compose.yml")

end = len(lines)
for j in range(start+1, len(lines)):
    if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j]):  # next service
        end = j
        break

block = lines[start:end]

# ---- ports patch
# Replace 4000:4000 variants with 127.0.0.1:4000:4000
new_block = []
ports_found = False
mapped_4000 = False
for line in block:
    if re.match(r"^\s{4}ports:\s*$", line):
        ports_found = True
        new_block.append(line)
        continue
    if ports_found and re.match(r"^\s{6}-\s*['\"]?(\d+:\d+|0\.0\.0\.0:\d+:\d+|127\.0\.0\.1:\d+:\d+)['\"]?\s*$", line):
        # normalize only if it's 4000 mapping
        s = line.strip().lstrip("-").strip().strip("'\"")
        if s.endswith("4000:4000"):
            new_block.append("      - \"127.0.0.1:4000:4000\"\n")
            mapped_4000 = True
        else:
            new_block.append(line)
        continue
    # stop ports section when indent goes back
    if ports_found and re.match(r"^\s{4}\S", line) and not re.match(r"^\s{4}ports:\s*$", line):
        ports_found = False
    new_block.append(line)

block = new_block

# If no ports section or no 4000 mapping, add it
text = "".join(block)
if "ports:" not in text:
    # insert after env_file if exists, else after image
    insert_at = None
    for i, line in enumerate(block):
        if re.match(r"^\s{4}env_file:\s*$", line) or re.match(r"^\s{4}env_file:\s*\[", line):
            insert_at = i + 1
            break
    if insert_at is None:
        for i, line in enumerate(block):
            if re.match(r"^\s{4}image:\s+", line):
                insert_at = i + 1
                break
    if insert_at is None:
        insert_at = 1
    add = ["    ports:\n", "      - \"127.0.0.1:4000:4000\"\n"]
    block = block[:insert_at] + add + block[insert_at:]
else:
    # ensure mapping exists
    if not re.search(r"127\.0\.0\.1:4000:4000", "".join(block)) and re.search(r"4000:4000", "".join(block)):
        # if it had 4000:4000 but didn't get normalized, do a final replace
        block = [re.sub(r'^\s{6}-\s*["\']?4000:4000["\']?\s*$', '      - "127.0.0.1:4000:4000"', l.rstrip("\n")).rstrip("\n") + "\n" for l in block]

# ---- environment patch
text = "".join(block)
need_json = "JSON_LOGS" not in text
need_loglvl = "LITELLM_LOG" not in text

if need_json or need_loglvl:
    # find existing environment block
    env_idx = None
    for i, line in enumerate(block):
        if re.match(r"^\s{4}environment:\s*$", line):
            env_idx = i
            break

    if env_idx is None:
        # insert environment near env_file/ports
        insert_at = None
        for i, line in enumerate(block):
            if re.match(r"^\s{4}env_file:", line):
                insert_at = i + 1
                break
        if insert_at is None:
            for i, line in enumerate(block):
                if re.match(r"^\s{4}ports:\s*$", line):
                    insert_at = i + 1
                    break
        if insert_at is None:
            insert_at = 1
        add = ["    environment:\n"]
        if need_json: add.append("      - JSON_LOGS=True\n")
        if need_loglvl: add.append("      - LITELLM_LOG=ERROR\n")
        block = block[:insert_at] + add + block[insert_at:]
    else:
        # detect list or mapping by peeking next significant line
        k = env_idx + 1
        while k < len(block) and block[k].strip() == "":
            k += 1
        is_list = (k < len(block) and re.match(r"^\s{6}-\s*", block[k]) is not None)
        is_map  = (k < len(block) and re.match(r"^\s{6}[A-Za-z0-9_]+\s*:", block[k]) is not None)

        ins = []
        if is_map and not is_list:
            if need_json: ins.append("      JSON_LOGS: \"True\"\n")
            if need_loglvl: ins.append("      LITELLM_LOG: \"ERROR\"\n")
        else:
            if need_json: ins.append("      - JSON_LOGS=True\n")
            if need_loglvl: ins.append("      - LITELLM_LOG=ERROR\n")

        block = block[:env_idx+1] + ins + block[env_idx+1:]

# write back
new_lines = lines[:start] + block + lines[end:]
p.write_text("".join(new_lines), encoding="utf-8")
print("OK: patched docker-compose.yml (localhost bind + json logs)")
PY

# -------------------------
# F) Patch infra/litellm/config.yaml
#     - ensure premium-chat uses anthropic gateway env vars
#     - add best-effort-chat model
#     - router_settings: ONLY best-effort upgrades to premium
#     - litellm_settings: context_window_fallbacks default->long and best-effort->long->premium
# -------------------------
python3 - <<'PY'
import re, pathlib

p = pathlib.Path("infra/litellm/config.yaml")
txt = p.read_text(encoding="utf-8")

# 1) Ensure premium-chat is anthropic gateway (idempotent)
pat = r"(?ms)^(\s*-\s*model_name:\s*premium-chat\s*\n\s*litellm_params:\s*\n)(?:\s{6}.*\n)*"
if re.search(pat, txt):
    block = (
        "  - model_name: premium-chat\n"
        "    litellm_params:\n"
        "      model: anthropic/claude-3-opus-20240229\n"
        "      api_base: os.environ/ANTHROPIC_API_BASE\n"
        "      api_key: os.environ/ANTHROPIC_API_KEY\n"
    )
    txt = re.sub(pat, block, txt, count=1)

# 2) Add best-effort-chat model if missing (insert before router_settings or at end)
if "model_name: best-effort-chat" not in txt:
    add = (
        "\n  - model_name: best-effort-chat\n"
        "    litellm_params:\n"
        "      model: deepseek/deepseek-chat\n"
        "      api_key: os.environ/DEEPSEEK_API_KEY\n"
    )
    m = re.search(r"(?m)^router_settings:\s*$", txt)
    if m:
        txt = txt[:m.start()] + add + "\n" + txt[m.start():]
    else:
        txt = txt.rstrip() + add + "\n"

# helper: replace a top-level block safely (router_settings)
def replace_top_block(text: str, key: str, new_block: str) -> str:
    lines = text.splitlines(True)
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}:\s*$", line):
            start = i
            break
    if start is None:
        # append at end
        if not text.endswith("\n"):
            text += "\n"
        return text + new_block + "\n"

    end = len(lines)
    for j in range(start+1, len(lines)):
        # next top-level key (no leading spaces) like "litellm_settings:"
        if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*$", lines[j]):
            end = j
            break
    return "".join(lines[:start]) + new_block + "\n" + "".join(lines[end:])

router_block = (
"router_settings:\n"
"  fallbacks:\n"
"    - best-effort-chat:\n"
"        - long-chat\n"
"        - premium-chat\n"
"  num_retries: 2\n"
)

txt = replace_top_block(txt, "router_settings", router_block)

# 3) Ensure litellm_settings.context_window_fallbacks contains our mappings
# If litellm_settings doesn't exist, append it.
if not re.search(r"(?m)^litellm_settings:\s*$", txt):
    txt = txt.rstrip() + "\n\n" + (
        "litellm_settings:\n"
        "  context_window_fallbacks:\n"
        "    - default-chat:\n"
        "        - long-chat\n"
        "    - best-effort-chat:\n"
        "        - long-chat\n"
        "        - premium-chat\n"
    ) + "\n"
else:
    # Find litellm_settings block range
    lines = txt.splitlines(True)
    ls_i = None
    for i,l in enumerate(lines):
        if re.match(r"^litellm_settings:\s*$", l):
            ls_i = i
            break
    # end at next top-level key or EOF
    ls_j = len(lines)
    for j in range(ls_i+1, len(lines)):
        if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*$", lines[j]):
            ls_j = j
            break
    ls_block = "".join(lines[ls_i:ls_j])

    if "context_window_fallbacks:" not in ls_block:
        # insert at end of litellm_settings block
        if not ls_block.endswith("\n"):
            ls_block += "\n"
        ls_block += (
            "  context_window_fallbacks:\n"
            "    - default-chat:\n"
            "        - long-chat\n"
            "    - best-effort-chat:\n"
            "        - long-chat\n"
            "        - premium-chat\n"
        )
    else:
        # ensure mappings exist (append if missing)
        if "default-chat:" not in ls_block:
            ls_block += (
                "\n    - default-chat:\n"
                "        - long-chat\n"
            )
        if "best-effort-chat:" not in ls_block:
            ls_block += (
                "\n    - best-effort-chat:\n"
                "        - long-chat\n"
                "        - premium-chat\n"
            )

    txt = "".join(lines[:ls_i]) + ls_block + "".join(lines[ls_j:])

p.write_text(txt, encoding="utf-8")
print("OK: patched infra/litellm/config.yaml (premium + best-effort + router/context fallbacks)")
PY

# -------------------------
# G) Restart + verify
# -------------------------
echo "OK: restarting docker compose..."
docker compose down
docker compose up -d

echo "OK: ps"
docker compose ps

echo "OK: router test"
./scripts/test_router.sh

echo "OK: model tests"
./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

echo "DONE ✅ Phase 2 autopatch complete."
echo "Backups saved in: backups/"
