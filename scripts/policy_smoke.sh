#!/usr/bin/env bash
set -euo pipefail

check_json () {
  local s="$1"
  python3 - "$s" <<'PY'
import json, sys
s = sys.argv[1]
d = json.loads(s)  # will raise if invalid
print(json.dumps(d, ensure_ascii=False))
PY
}

echo "[policy_smoke] 1) plan_web must be json_only"
j="$(python3 scripts/policy_decide.py --task plan_web --text 'Build a Next.js site')"
j="$(check_json "$j")"
python3 - "$j" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
assert d["json_only"] is True
assert d["max_attempts"] >= 3
print("[ok] plan_web json_only")
PY

echo "[policy_smoke] 2) long text should route to long-chat"
txt="$(python3 - <<'PY'
print("x"*1300)
PY
)"
j="$(python3 scripts/policy_decide.py --task other --text "$txt")"
j="$(check_json "$j")"
python3 - "$j" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
assert d["model"] == "long-chat"
print("[ok] long text routes to long-chat")
PY

echo "[policy_smoke] PASS"
