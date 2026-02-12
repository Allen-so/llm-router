#!/usr/bin/env bash
set -euo pipefail

STEP="${1:-}"
shift || true

if [[ -z "${STEP}" ]]; then
  echo "[run_step_log] missing STEP" >&2
  exit 2
fi

if [[ "${1:-}" != "--" ]]; then
  echo "[run_step_log] usage: ./scripts/run_step_log.sh <step> -- <command...>" >&2
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
  if [[ -z "${rd}" ]]; then echo ""; return 0; fi
  if [[ -f "${rd}/plan.web.json" ]]; then echo "plan_web"; return 0; fi
  if [[ -f "${rd}/plan.json" ]]; then echo "plan"; return 0; fi
  echo ""
}

KIND="${KIND:-}"

t0_ms="$(date +%s%3N)"
run_dir_before="$(read_latest)"
if [[ -z "${KIND}" ]]; then KIND="$(infer_kind "${run_dir_before}")"; fi

python3 "${REPO_DIR}/scripts/event_append.py" \
  --run-dir "${run_dir_before}" \
  --kind "${KIND}" \
  --step "${STEP}" \
  --phase start \
  --ts-ms "${t0_ms}" >/dev/null 2>&1 || true

# run command, tee output to step log
set +e
tlog="/tmp/step_${STEP}_$$.log"
"$@" > >(tee "${tlog}") 2> >(tee -a "${tlog}" >&2)
rc=$?
set -e

t1_ms="$(date +%s%3N)"
dur_ms=$((t1_ms - t0_ms))
run_dir_after="$(read_latest)"
if [[ -z "${KIND}" ]]; then KIND="$(infer_kind "${run_dir_after}")"; fi

# choose where to store log
target_dir="${run_dir_after}"
if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
  target_dir="${run_dir_before}"
fi
if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
  target_dir="${REPO_DIR}/logs"
fi
mkdir -p "${target_dir}"
step_log="${target_dir}/step_${STEP}.log"
cp -f "${tlog}" "${step_log}" 2>/dev/null || true
rm -f "${tlog}" 2>/dev/null || true

status="ok"
err_class=""
msg=""
if [[ "${rc}" -ne 0 ]]; then
  status="fail"
  read -r err_class msg < <(python3 "${REPO_DIR}/scripts/error_classify.py" --step "${STEP}" --rc "${rc}" --log-file "${step_log}" --plain || true)
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
