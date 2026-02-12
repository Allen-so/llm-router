#!/usr/bin/env bash
set -euo pipefail

die() { echo "[verify_web][err] $*" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Resolve run_dir (prefer RUN_DIR env to avoid LATEST confusion)
run_dir="${RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  [[ -f "$ROOT/artifacts/runs/LATEST" ]] || die "missing artifacts/runs/LATEST (or set RUN_DIR=...)"
  run_dir="$(cat "$ROOT/artifacts/runs/LATEST" | tr -d '\r\n')"
fi
[[ -d "$run_dir" ]] || die "run_dir not found: $run_dir"

echo "[verify_web] run_dir=$run_dir"
echo "[verify_web] ts=$(date -Iseconds)"
node -v
npm -v

# Locate plan file (optional)
plan_file=""
if [[ -f "$run_dir/plan.web.json" ]]; then
  plan_file="$run_dir/plan.web.json"
elif [[ -f "$run_dir/plan.json" ]]; then
  plan_file="$run_dir/plan.json"
  echo "[info] plan.web.json missing, fallback to plan.json"
else
  echo "[warn] no plan.web.json / plan.json in run dir (will proceed without plan_hash)"
fi

# Extract plan_hash if possible (but do NOT hard-fail if missing)
plan_hash=""
if [[ -n "$plan_file" ]]; then
  plan_hash="$(python3 - <<'PY' "$plan_file"
import json, sys, re

p = sys.argv[1]
try:
    j = json.load(open(p, "r", encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)

def dig(obj, path):
    cur = obj
    for k in path:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur

cands = [
    j.get("plan_hash"),
    j.get("planHash"),
    dig(j, ["plan_hash"]),
    dig(j, ["plan", "plan_hash"]),
    dig(j, ["plan", "hash"]),
    dig(j, ["meta", "plan_hash"]),
]

for v in cands:
    if isinstance(v, str) and v.strip():
        print(v.strip())
        raise SystemExit(0)

# last resort: find any hex-ish hash in json values
s = json.dumps(j)
m = re.search(r'([0-9a-f]{12,64})', s)
print(m.group(1) if m else "")
PY
)"
fi

if [[ -z "$plan_hash" ]]; then
  echo "[warn] plan_hash missing in $(basename "${plan_file:-<none>}") (will resolve gen_dir without it)"
fi

# Resolve gen_dir:
# 1) GEN_DIR env
# 2) apps/generated/*/.generated_from_run matches run_dir
# 3) apps/generated/*__{plan_hash} if plan_hash exists
# 4) apps/generated/websmoke__* newest
# 5) newest in apps/generated
gen_dir="${GEN_DIR:-}"

if [[ -z "$gen_dir" ]]; then
  # 2) match by .generated_from_run
  match="$(grep -Rsl --fixed-strings "$run_dir" "$ROOT/apps/generated"/*/.generated_from_run 2>/dev/null | head -n 1 || true)"
  if [[ -n "$match" ]]; then
    gen_dir="$(dirname "$match")"
    echo "[info] gen_dir matched by .generated_from_run: ${gen_dir#$ROOT/}"
  fi
fi

if [[ -z "$gen_dir" && -n "$plan_hash" ]]; then
  hit="$(ls -1d "$ROOT/apps/generated/"*__"$plan_hash" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$hit" ]]; then
    gen_dir="$hit"
    echo "[info] gen_dir matched by plan_hash: ${gen_dir#$ROOT/}"
  fi
fi

if [[ -z "$gen_dir" ]]; then
  hit="$(ls -1dt "$ROOT/apps/generated/websmoke__"* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$hit" ]]; then
    gen_dir="$hit"
    echo "[info] gen_dir fallback to websmoke__: ${gen_dir#$ROOT/}"
  fi
fi

if [[ -z "$gen_dir" ]]; then
  hit2="$(ls -1dt "$ROOT/apps/generated/"* 2>/dev/null | head -n 1 || true)"
  [[ -n "$hit2" ]] || die "no apps/generated/* found"
  gen_dir="$hit2"
  echo "[warn] gen_dir fallback to newest: ${gen_dir#$ROOT/}"
fi

# Normalize to absolute
if [[ "$gen_dir" != /* ]]; then gen_dir="$ROOT/$gen_dir"; fi
[[ -d "$gen_dir" ]] || die "gen_dir not found: $gen_dir"

echo "[verify_web] gen_dir=${gen_dir#$ROOT/}"

# Guard: must be a Next.js project with scripts.build
pkg="$gen_dir/package.json"
[[ -f "$pkg" ]] || die "not a web project (missing package.json): ${gen_dir#$ROOT/}"

has_build="$(python3 - <<'PY' "$pkg"
import json, sys
j = json.load(open(sys.argv[1], "r", encoding="utf-8"))
scripts = j.get("scripts", {}) if isinstance(j, dict) else {}
print("yes" if isinstance(scripts, dict) and "build" in scripts else "no")
PY
)"
if [[ "$has_build" != "yes" ]]; then
  echo "[verify_web][err] package.json has no scripts.build (wrong gen_dir?): ${gen_dir#$ROOT/}" >&2
  echo "[verify_web][info] available scripts:" >&2
  python3 - <<'PY' "$pkg" >&2
import json, sys
j = json.load(open(sys.argv[1], "r", encoding="utf-8"))
print(json.dumps(j.get("scripts", {}), indent=2))
PY
  exit 2
fi

log="$run_dir/verify.log"
summary="$run_dir/verify_summary.json"

(
  cd "$gen_dir"
  if [[ -f package-lock.json ]]; then
    echo "[run] npm ci"
    npm ci
  else
    echo "[run] npm install"
    npm install
  fi
  echo "[run] npm run build"
  npm run build
) | tee "$log"

# If plan_hash still empty, try derive from folder name suffix: name__hash
if [[ -z "$plan_hash" ]]; then
  base="$(basename "$gen_dir")"
  if [[ "$base" =~ __([0-9a-f]{12,64})$ ]]; then
    plan_hash="${BASH_REMATCH[1]}"
    echo "[info] derived plan_hash from gen_dir: $plan_hash"
  fi
fi

python3 - <<'PY' "$summary" "$plan_hash" "${gen_dir#$ROOT/}"
import json, sys, time
out = {
  "ok": True,
  "ts": time.time(),
  "plan_hash": sys.argv[2],
  "gen_dir": sys.argv[3],
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(out, indent=2) + "\n")
PY

echo "[ok] web build passed"
