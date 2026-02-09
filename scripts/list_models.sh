#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a
curl -sS "http://127.0.0.1:4000/v1/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
| python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
print("\n".join([x.get("id","") for x in d.get("data",[])]))
PY
