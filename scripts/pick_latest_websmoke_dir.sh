#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(ls -1dt "$ROOT/apps/generated/websmoke__"* 2>/dev/null | head -n 1 || true)"
[[ -n "$dir" ]] || { echo "[pick] no apps/generated/websmoke__* found" >&2; exit 2; }
echo "$dir"
