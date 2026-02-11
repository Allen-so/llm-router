#!/usr/bin/env bash
set -u

ROOT="/home/suxiaocong/ai-platform"
cd "$ROOT" || exit 2

ts="$(date +%Y%m%d_%H%M%S)"
mkdir -p logs
log="logs/qa_${ts}.log"
exec > >(tee "$log") 2>&1
echo "[qa] log=$log"

fail=0
step() { echo; echo "== $* =="; }
ok()   { echo "[ok] $*"; }
bad()  { echo "[fail] $*"; fail=$((fail+1)); }

must_exist() {
  [[ -e "$1" ]] && ok "exists: $1" || bad "missing: $1"
}

run() {
  echo "+ $*"
  bash -lc "$*" || { bad "command failed: $*"; return 1; }
  return 0
}

step "repo sanity"
must_exist apps/router-demo/schemas/plan.schema.json
must_exist docker-compose.yml
must_exist scripts/ask.sh
must_exist scripts/wait_ready.sh
must_exist scripts/lib_http_retry.sh
must_exist scripts/secrets_scan.sh
must_exist apps/router-demo/run.py
must_exist apps/router-demo/replay.py
must_exist apps/router-demo/plan.py
must_exist apps/router-demo/scaffold.py
must_exist logs

step "syntax check (bash)"
rm -f /tmp/qa_bash_files.txt
find scripts -maxdepth 1 -type f -name '*.sh' -print > /tmp/qa_bash_files.txt
while IFS= read -r f; do
  if bash -n "$f"; then ok "bash -n $f"; else bad "bash -n $f"; fi
done < /tmp/qa_bash_files.txt

step "schema json"
run "python3 -m json.tool apps/router-demo/schemas/plan.schema.json >/dev/null"

step "syntax check (python)"
python3 -m py_compile apps/router-demo/run.py apps/router-demo/replay.py apps/router-demo/plan.py apps/router-demo/scaffold.py && ok 'python py_compile router-demo' || bad 'python py_compile router-demo'

step "secrets scan"
run './scripts/secrets_scan.sh' || true

step "up + ready"
run 'docker compose up -d' || true
run './scripts/wait_ready.sh' || true
run 'docker compose ps' || true
run "curl -sS -o /dev/null -w 'HTTP=%{http_code}\\n' http://127.0.0.1:4000/v1/models || true" || true

step "ask (positive path)"
out="$(./scripts/ask.sh --meta auto 'Say ROUTER_OK' 2>/dev/null || true)"
echo "$out"
if echo "$out" | grep -q 'ROUTER_OK'; then ok 'ask returned ROUTER_OK'; else bad 'ask did not return ROUTER_OK'; fi
tail -n 1 logs/ask_history.log 2>/dev/null || true

step "demo + replay_latest"
run "make demo MODE=auto TEXT='Reply with exactly ROUTER_OK and nothing else.'" || true
out2="$(make replay_latest 2>/dev/null || true)"
echo "$out2"
if echo "$out2" | grep -q 'ROUTER_OK'; then ok 'replay_latest returned ROUTER_OK'; else bad 'replay_latest did not return ROUTER_OK'; fi

step "plan + scaffold"
run "make plan MODEL=default-chat TEXT='Build a minimal python CLI tool named qarenamer. It prints parsed args and supports --help.'" || true
run 'python3 apps/router-demo/scaffold.py --force' || true
if [[ -d apps/generated/qarenamer ]]; then ok 'generated app exists: apps/generated/qarenamer'; else bad 'generated app missing'; fi
if [[ -f apps/generated/qarenamer/RUN_INSTRUCTIONS.txt ]]; then ok 'RUN_INSTRUCTIONS.txt exists'; else bad 'RUN_INSTRUCTIONS.txt missing'; fi

step "down + ask (negative path should be diagnosable)"
run 'docker compose down' || true
meta="$(./scripts/ask.sh --meta auto 'Say ROUTER_OK' 2>/dev/null | tail -n 1 || true)"
echo "$meta"
if echo "$meta" | grep -q 'rc=000'; then ok 'down path shows rc=000 (expected)'; else bad 'down path did not show rc=000'; fi
tail -n 1 logs/ask_history.log 2>/dev/null || true

echo
if [[ $fail -eq 0 ]]; then
  echo 'QA RESULT: PASS'
  exit 0
else
  echo "QA RESULT: FAIL ($fail failures)"
  exit 1
fi
