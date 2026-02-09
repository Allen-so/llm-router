#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="${ROUTER_RULES_PATH:-$ROOT/infra/router_rules.json}"

if [[ ! -f "$RULES" ]]; then
  echo "FAIL: rules not found: $RULES" >&2
  exit 1
fi

echo "rules: $RULES"

# Helper: run route.py and assert mode/model
assert_route () {
  local name="$1"
  local text="$2"
  local exp_mode="$3"
  local exp_model="$4"

  local out
  out="$(ROUTER_EXPLAIN=1 python3 "$ROOT/scripts/route.py" "$RULES" auto "$text")"

  python3 - <<PYCODE "$name" "$exp_mode" "$exp_model" "$out"
import json,sys
name=sys.argv[1]
exp_mode=sys.argv[2]
exp_model=sys.argv[3]
raw=sys.argv[4]

d=json.loads(raw)
mode=d.get("mode")
model=d.get("model")

if mode!=exp_mode or model!=exp_model:
    ex=d.get("explain",{})
    print(f"FAIL: {name}", file=sys.stderr)
    print(f"  expected: mode={exp_mode} model={exp_model}", file=sys.stderr)
    print(f"  got:      mode={mode} model={model}", file=sys.stderr)
    if isinstance(ex, dict):
        print(f"  reason: {ex.get('reason')}", file=sys.stderr)
        print(f"  coding_hits: {ex.get('coding_hits')}", file=sys.stderr)
        print(f"  hard_hits:   {ex.get('hard_hits')}", file=sys.stderr)
        print(f"  priority:    {ex.get('priority')}", file=sys.stderr)
        print(f"  long_min:    {ex.get('long_min')}", file=sys.stderr)
        print(f"  input_len:   {ex.get('input_len')}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: {name} -> mode={mode} model={model}")
PYCODE
}

# 1) coding should win when mixed with hard keywords (priority: long > coding > hard > daily)
assert_route "coding_priority_wins" \
  "Traceback: CVaR optimization KeyError in pandas df['age']" \
  "coding" "default-chat"

# 2) hard routing
assert_route "hard_route" \
  "Derive CVaR optimization formulation for portfolio" \
  "hard" "best-effort-chat"

# 3) long routing (>=1200 chars)
LONG_TEXT="$(python3 - <<'PY2'
print("x"*1300)
PY2
)"
assert_route "long_route" \
  "$LONG_TEXT" \
  "long" "long-chat"

echo "OK: route regress completed"
