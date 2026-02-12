#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LATEST_FILE="${REPO_DIR}/artifacts/runs/LATEST"

target="${1:-}"
if [[ -z "${target}" ]]; then
  if [[ -f "${LATEST_FILE}" ]]; then
    target="$(cat "${LATEST_FILE}" | tr -d '\r\n')"
  fi
fi

if [[ -z "${target}" || ! -d "${target}" ]]; then
  echo "[web_replay] invalid run_dir: ${target}" >&2
  exit 2
fi

if [[ ! -f "${target}/plan.web.json" ]]; then
  echo "[web_replay] ${target} missing plan.web.json (not a plan_web run?)" >&2
  exit 2
fi

old_latest=""
if [[ -f "${LATEST_FILE}" ]]; then
  old_latest="$(cat "${LATEST_FILE}" | tr -d '\r\n')"
fi

restore_latest() {
  if [[ -n "${old_latest}" ]]; then
    echo "${old_latest}" > "${LATEST_FILE}"
  fi
}
trap restore_latest EXIT

echo "${target}" > "${LATEST_FILE}"

export KIND="plan_web"

echo "[web_replay] run_dir=${target}"

./scripts/run_step.sh web_replay_start -- bash -lc 'true'

./scripts/run_step.sh scaffold_web -- python3 apps/router-demo/scaffold_web.py
./scripts/run_step.sh apply_plan_web -- python3 apps/router-demo/apply_plan_web.py
./scripts/run_step.sh verify_generated_web -- ./scripts/verify_generated_web.sh
./scripts/run_step.sh meta_latest -- python3 scripts/write_run_meta.py --append-events

./scripts/run_step.sh web_replay_end -- bash -lc 'true'

echo "[web_replay] OK"
