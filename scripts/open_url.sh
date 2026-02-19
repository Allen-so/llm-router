#!/usr/bin/env bash
set -euo pipefail
url="${1:-}"
[[ -n "$url" ]] || { echo "usage: open_url.sh <url>" >&2; exit 2; }

if command -v wslview >/dev/null 2>&1; then
  wslview "$url" >/dev/null 2>&1 || true
  exit 0
fi

echo "[open] $url"
echo "[tip] install wslview (package: wslu) to auto-open from WSL"
