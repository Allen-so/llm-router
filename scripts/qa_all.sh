#!/usr/bin/env bash
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/load_node.sh" || true
cd "$ROOT" || exit 1

mkdir -p logs

TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${QA_LOG:-logs/qa_${TS}.log}"

# tee all output to log
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[qa] start: $(date)"
echo "[qa] root:  $ROOT"
if command -v git >/dev/null 2>&1; then
  echo "[qa] git:   $(git rev-parse --short HEAD 2>/dev/null || echo NA)"
fi
echo "[qa] log:   $LOG_FILE"
echo

FAILS=()
SKIPS=()

hint() {
  case "$1" in
    repo_sanity)
      echo "  hint: missing key files. make sure you are in repo root and pulled latest changes."
      ;;
    bash_syntax)
      echo "  hint: a shell script has syntax errors. run: bash -n scripts/<file>.sh"
      ;;
    python_syntax)
      echo "  hint: a python file fails compile. run: python3 -m py_compile <file.py>"
      ;;
    secrets_scan)
      echo "  hint: secrets detected. remove leaked keys, rotate them, and re-run."
      ;;
    docker_upready)
      echo "  hint: Docker not available in WSL. enable Docker Desktop WSL integration, then run: docker version"
      ;;
    models_endpoint)
      echo "  hint: router not listening on 127.0.0.1:4000 or port is blocked. check: docker compose ps"
      ;;
    strict_check)
      echo "  hint: master key missing or model alias wrong. verify .env LITELLM_MASTER_KEY and litellm config."
      ;;
    demo_replay)
      echo "  hint: router-demo cannot replay. verify artifacts/runs/LATEST exists and .env is readable."
      ;;
    plan_scaffold)
      echo "  hint: model output not valid json or schema mismatch. check apps/router-demo/plan.py logs in artifacts."
      ;;
    down_negative)
      echo "  hint: docker compose down did not stop the router, or another service occupies port 4000."
      ;;
    *)
      echo "  hint: check the log above for the failing command."
      ;;
  esac
}

run_step() {
  local name="$1"; shift
  echo "==> [step] $name"
  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "[fail] step=$name rc=$rc"
    hint "$name"
    FAILS+=("$name")
    echo
    return $rc
  fi
  echo "[ok] step=$name"
  echo
  return 0
}

skip_step() {
  local name="$1"; shift
  echo "==> [skip] $name"
  echo "  reason: $*"
  SKIPS+=("$name")
  echo
}

# 1 repo sanity
run_step repo_sanity bash -lc '
  test -f docker-compose.yml
  test -f Makefile
  test -d scripts
  test -f scripts/wait_ready.sh
  test -f scripts/qa_all.sh
  test -d apps/router-demo
  test -f apps/router-demo/plan.py
  test -f apps/router-demo/scaffold.py
' || true

# 2 bash syntax
run_step bash_syntax bash -lc '
  shopt -s nullglob
  files=(scripts/*.sh)
  test ${#files[@]} -gt 0
  for f in "${files[@]}"; do bash -n "$f"; done
' || true

# 3 python syntax
run_step python_syntax bash -lc '
  python3 - <<PY
import sys, pathlib, py_compile
root = pathlib.Path("apps/router-demo")
files = list(root.rglob("*.py"))
if not files:
  print("no python files under apps/router-demo")
  sys.exit(1)
for f in files:
  py_compile.compile(str(f), doraise=True)
print(f"compiled {len(files)} files")
PY
' || true

# 4 secrets scan
run_step secrets_scan bash -lc './scripts/secrets_scan.sh' || true

# 5 up + ready
DOCKER_OK=1
run_step docker_upready bash -lc '
  docker compose up -d
  ./scripts/wait_ready.sh
  docker compose ps
' || DOCKER_OK=0

# 6 models endpoint
if [ $DOCKER_OK -eq 1 ]; then
  run_step models_endpoint bash -lc '
    code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4000/v1/models || true)"
    echo "[info] /v1/models http_code=$code"
    test "$code" = "401" -o "$code" = "200"
  ' || true
else
  skip_step models_endpoint "docker not ready"
fi

# 7 strict ask gate
if [ $DOCKER_OK -eq 1 ]; then
  run_step strict_check bash -lc 'make check' || true
else
  skip_step strict_check "docker not ready"
fi

# 8 demo + replay
if [ $DOCKER_OK -eq 1 ]; then
  run_step demo_replay bash -lc '
    make demo MODE=auto TEXT="Reply with exactly ROUTER_OK and nothing else."
    make replay_latest
  ' || true
else
  skip_step demo_replay "docker not ready"
fi

# 9 plan + scaffold
if [ $DOCKER_OK -eq 1 ]; then
  if run_step plan_scaffold bash -lc '
    make plan MODEL=default-chat TEXT="Build a minimal python CLI tool named plancheck. It supports --help and prints parsed args."
    make scaffold
  '; then
    run_step generated_smoke bash -lc 'make verify_generated'
  fi
else
  skip_step plan_scaffold "docker not ready"
  skip_step generated_smoke "docker not ready"
fi

# 9c web scaffold smoke (deterministic)
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  run_step web_smoke bash -lc 'make web_smoke'
else
  skip_step web_smoke "node/npm not installed"
fi

# 10 down + negative check
run_step down_negative bash -lc '
  docker compose down
  code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4000/v1/models || true)"
  echo "[info] /v1/models after down http_code=$code"
  test "$code" = "000"
' || true

echo "===================="
echo "[qa] summary"
echo "[qa] log: $LOG_FILE"
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "[qa] result: PASS"
else
  echo "[qa] result: FAIL"
  echo "[qa] failed steps:"
  for s in "${FAILS[@]}"; do echo "  - $s"; done
fi
if [ ${#SKIPS[@]} -gt 0 ]; then
  echo "[qa] skipped steps:"
  for s in "${SKIPS[@]}"; do echo "  - $s"; done
fi
echo "===================="

[ ${#FAILS[@]} -eq 0 ]
