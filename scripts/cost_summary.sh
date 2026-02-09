#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m py_compile "$ROOT/scripts/cost_summary.py" >/dev/null
python3 "$ROOT/scripts/cost_summary.py" "$@"
