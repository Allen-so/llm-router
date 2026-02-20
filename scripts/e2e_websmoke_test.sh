#!/usr/bin/env bash
set -Eeuo pipefail

RUN_QA="${RUN_QA:-0}"           # RUN_QA=1 -> 先跑 make qa（更慢但更全）
KEEP_SERVER="${KEEP_SERVER:-1}" # KEEP_SERVER=0 -> 测完自动 kill Next

say(){ echo -e "$*"; }
die(){ echo "[fail] $*" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "not in a git repo"
cd "$ROOT" || die "cd root failed"

PIDFILE=""
PORT=""
PID=""

cleanup(){
  if [[ "${KEEP_SERVER}" == "0" && -n "${PID:-}" ]]; then
    if kill -0 "$PID" >/dev/null 2>&1; then
      say
      say "== [cleanup] killing Next (pid=$PID) =="
      kill "$PID" >/dev/null 2>&1 || true
      sleep 0.4 || true
      kill -9 "$PID" >/dev/null 2>&1 || true
    fi
    [[ -n "${PIDFILE:-}" ]] && rm -f "$PIDFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# fetch url -> out, also write headers to hdr, return http code in stdout
fetch_to_file(){
  local url="$1" out="$2" hdr="$3"
  : >"$hdr"
  local code="000"
  code="$(curl -sS -L --retry 5 --retry-connrefused --retry-delay 0 \
    -D "$hdr" -o "$out" -w '%{http_code}' "$url" || echo "000")"
  echo "$code"
}

# hard-validate that file is JSON-ish
assert_json_file(){
  local url="$1" body="$2" hdr="$3" code="$4"

  if [[ "$code" != "200" ]]; then
    say "[fail] GET $url http=$code"
    sed -n '1,25p' "$hdr" >&2 || true
    head -c 200 "$body" >&2 || true
    return 1
  fi

  local ctype
  ctype="$(grep -i '^content-type:' "$hdr" | tail -n1 | tr -d '\r' || true)"
  say "[info] content-type: ${ctype:-unknown}"

  if [[ "${ctype,,}" != *json* ]]; then
    say "[fail] non-json content-type for $url"
    say "[debug] first 200 bytes:"
    head -c 200 "$body" | sed 's/[^[:print:]\t]/?/g' >&2 || true
    return 1
  fi

  local first
  first="$(python3 - <<'PY' "$body"
import sys, pathlib
p = pathlib.Path(sys.argv[1])
b = p.read_bytes()
# find first non-whitespace
i = 0
while i < len(b) and b[i] in b" \r\n\t":
    i += 1
print(chr(b[i]) if i < len(b) else "")
PY
)"
  if [[ "$first" != "{" && "$first" != "[" ]]; then
    say "[fail] body not JSON for $url (first_non_ws='$first')"
    say "[debug] first 200 bytes:"
    head -c 200 "$body" | sed 's/[^[:print:]\t]/?/g' >&2 || true
    return 1
  fi
}

say "== [0/9] repo =="
say "[info] root=$ROOT"
git rev-parse --short HEAD 2>/dev/null | sed 's/^/[info] git=/' || true

say
say "== [1/9] syntax checks =="
for f in scripts/*.sh; do
  bash -n "$f"
done
python3 -m py_compile $(git ls-files '*.py') >/dev/null
say "[ok] bash + python syntax OK"

say
if [[ "$RUN_QA" == "1" ]]; then
  say "== [2/9] make qa =="
  make qa
  say "[ok] qa PASS"
else
  say "== [2/9] skip make qa (RUN_QA=0) =="
fi

say
say "== [3/9] run full pipeline (web_smoke_open) =="
make web_smoke_open

say
say "== [4/9] detect latest Next port/pid =="
PIDFILE="$(ls -1t /tmp/websmoke_*.pid 2>/dev/null | head -n1 || true)"
[[ -n "$PIDFILE" ]] || die "no /tmp/websmoke_*.pid found"
PORT="$(basename "$PIDFILE")"
PORT="${PORT#websmoke_}"
PORT="${PORT%.pid}"
PID="$(cat "$PIDFILE" 2>/dev/null || true)"
[[ -n "$PID" ]] || die "pidfile empty: $PIDFILE"
say "[ok] pidfile=$PIDFILE"
say "[ok] port=$PORT pid=$PID"
BASE="http://localhost:$PORT"
say "[info] base=$BASE"

say
say "== [5/9] wait server ready (/runs) =="
for i in {1..30}; do
  code="$(curl -sS -L -o /dev/null -w '%{http_code}' "$BASE/runs" || echo 000)"
  if [[ "$code" == "200" ]]; then
    say "[ok] /runs reachable http=200 (try=$i)"
    break
  fi
  sleep 0.25
  [[ "$i" == "30" ]] && die "/runs not reachable (last_http=$code)"
done

say
say "== [6/9] fetch index.json and pick RID =="
IDX_BODY="$(mktemp)"
IDX_HDR="$(mktemp)"
IDX_URL="$BASE/runs_data/index.json"
IDX_CODE="$(fetch_to_file "$IDX_URL" "$IDX_BODY" "$IDX_HDR")"
assert_json_file "$IDX_URL" "$IDX_BODY" "$IDX_HDR" "$IDX_CODE" || die "index.json invalid"

RID="$(python3 - <<'PY' "$IDX_BODY"
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))

items = None
if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    for k in ("items", "runs", "data"):
        v = data.get(k)
        if isinstance(v, list):
            items = v
            break

if not items:
    raise SystemExit("no items in index.json")

def pick_id(it):
    if not isinstance(it, dict):
        return None
    for k in ("rid", "run_id", "id", "name"):
        if k in it and isinstance(it[k], str) and it[k]:
            return it[k]
    return None

rid = None
for it in items:
    rid = pick_id(it)
    if rid:
        break

if not rid:
    raise SystemExit("no rid-like field found in index items")

print(rid)
PY
)" || die "failed to parse RID from index.json"
say "[ok] RID=$RID"

say
say "== [7/9] validate /runs_data and /runs pages =="
# detail json
DET_BODY="$(mktemp)"
DET_HDR="$(mktemp)"
DET_URL="$BASE/runs_data/$RID.json"
DET_CODE="$(fetch_to_file "$DET_URL" "$DET_BODY" "$DET_HDR")"
assert_json_file "$DET_URL" "$DET_BODY" "$DET_HDR" "$DET_CODE" || die "detail json invalid"

# runs list + run detail pages should be html
code_runs="$(curl -sS -L -o /dev/null -w '%{http_code}' "$BASE/runs" || echo 000)"
[[ "$code_runs" == "200" ]] || die "/runs not 200 (http=$code_runs)"
code_run="$(curl -sS -L -o /dev/null -w '%{http_code}' "$BASE/runs/$RID" || echo 000)"
[[ "$code_run" == "200" ]] || die "/runs/$RID not 200 (http=$code_run)"

say "[ok] http: /runs=200 /runs/$RID=200 /runs_data/index.json=200 /runs_data/$RID.json=200"

say
say "== [8/9] key/status checks (index/meta/verify) =="
python3 - <<'PY' "$DET_BODY"
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text(encoding="utf-8"))

def get_status(obj, path):
    cur = obj
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur

need_keys = ("index", "meta", "verify")
for k in need_keys:
    if k not in d:
        raise SystemExit(f"missing key: {k}")

idx_status = get_status(d, ("index", "status"))
meta_status = get_status(d, ("meta", "status"))
ver_status = get_status(d, ("verify", "status"))

print(f"has index/meta/verify: True")
print(f"index.status: {idx_status}")
print(f"meta.status:  {meta_status}")
print(f"verify.status:{ver_status}")

# 你要“全面测试”，这里我直接把 meta 也要求 ok（不然就是你之前的 unknown 问题）
if idx_status != "ok":
    raise SystemExit(f"index.status not ok: {idx_status}")
if meta_status != "ok":
    raise SystemExit(f"meta.status not ok: {meta_status}")
if ver_status not in (None, "ok"):
    raise SystemExit(f"verify.status not ok: {ver_status}")
PY

say "[ok] key/status checks PASS"

say
say "== [9/9] done =="
say "[open] $BASE/runs"
say "[open] $BASE/runs/$RID"
say "[open] $BASE/runs_data/index.json"
say "[open] $BASE/runs_data/$RID.json"
say "[ok] e2e_websmoke_test PASS"
