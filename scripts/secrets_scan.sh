#!/usr/bin/env bash
set -euo pipefail

STRICT="${STRICT:-0}"   # STRICT=1 -> fail
SHOW="${SHOW:-20}"      # show first N hits

fail() { echo "FAIL: $*" >&2; exit 2; }
warn() { echo "WARN: $*" >&2; }

cd "$(dirname "$0")/.."  # repo root

# 1) .env must never be tracked
if git ls-files | grep -E '(^|/)\.env$' >/dev/null 2>&1; then
  fail ".env is tracked by git. Remove it from index: git rm --cached .env"
fi

# 2) scan tracked files for key-like patterns (sk-*)
HITS="$(git grep -nE 'sk-[A-Za-z0-9]{16,}' -- . || true)"

if [[ -n "${HITS}" ]]; then
  echo "== potential secrets found (first ${SHOW}) =="
  echo "${HITS}" | head -n "${SHOW}"
  echo "== end =="

  if [[ "${STRICT}" == "1" ]]; then
    fail "Secret-like tokens detected in tracked files. Refuse to continue."
  else
    warn "Secret-like tokens detected in tracked files. (not failing because STRICT=0)"
  fi
else
  echo "OK: no sk-* tokens found in tracked files"
fi

exit 0
