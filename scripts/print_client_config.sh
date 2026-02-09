#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -f ".env" ]]; then
  set -a; source .env; set +a
fi

echo "Base URL : http://127.0.0.1:4000/v1"
echo "Auth     : Authorization: Bearer \$LITELLM_MASTER_KEY"
echo "Models   : default-chat | long-chat | premium-chat | best-effort-chat"
