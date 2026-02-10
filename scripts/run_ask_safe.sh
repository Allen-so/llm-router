#!/usr/bin/env bash
set -euo pipefail
LOG="logs/ask_safe_$(date +%Y%m%d_%H%M%S).log"
# 用 bash -x 跟踪执行，任何错误都写进日志
bash -x ./scripts/ask.sh "$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
echo "[run_ask_safe] rc=$rc log=$LOG" >&2
exit "$rc"
