#!/usr/bin/env bash
set -euo pipefail

STEP="${1:-}"
shift || true

if [[ -z "${STEP}" ]]; then
  echo "[run_step] missing STEP" >&2
  exit 2
fi

if [[ "${1:-}" != "--" ]]; then
  echo "[run_step] usage: ./scripts/run_step.sh <step> -- <command...>" >&2
  exit 2
fi
shift

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LATEST_FILE="${REPO_DIR}/artifacts/runs/LATEST"

read_latest() {
  if [[ -f "${LATEST_FILE}" ]]; then
    cat "${LATEST_FILE}" | tr -d '\r\n'
  else
    echo ""
  fi
}

infer_kind() {
  local rd="${1:-}"
  if [[ -z "${rd}" ]]; then
    echo ""
    return 0
  fi
  if [[ -f "${rd}/plan.web.json" ]]; then
    echo "plan_web"
    return 0
  fi
  if [[ -f "${rd}/plan.json" ]]; then
    echo "plan"
    return 0
  fi
  if [[ -f "${rd}/verify_web.log" ]]; then
    echo "plan_web"
    return 0
  fi
  echo ""
}

KIND="${KIND:-}"

t0_ms="$(date +%s%3N)"
run_dir_before="$(read_latest)"

if [[ -z "${KIND}" ]]; then
  KIND="$(infer_kind "${run_dir_before}")"
fi

python3 "${REPO_DIR}/scripts/event_append.py" \
  --run-dir "${run_dir_before}" \
  --kind "${KIND}" \
  --step "${STEP}" \
  --phase start \
  --ts-ms "${t0_ms}" >/dev/null 2>&1 || true

set +e
"$@"
rc=$?
set -e

t1_ms="$(date +%s%3N)"
dur_ms=$((t1_ms - t0_ms))
run_dir_after="$(read_latest)"

if [[ -z "${KIND}" ]]; then
  KIND="$(infer_kind "${run_dir_after}")"
fi

status="ok"
err_class=""
msg=""
if [[ "${rc}" -ne 0 ]]; then
  status="fail"
  err_class="rc_${rc}"
  msg="step_failed"
fi

python3 "${REPO_DIR}/scripts/event_append.py" \
  --run-dir "${run_dir_after}" \
  --kind "${KIND}" \
  --step "${STEP}" \
  --phase end \
  --status "${status}" \
  --rc "${rc}" \
  --duration-ms "${dur_ms}" \
  --message "${msg}" \
  --error-class "${err_class}" >/dev/null 2>&1 || true

exit "${rc}"
