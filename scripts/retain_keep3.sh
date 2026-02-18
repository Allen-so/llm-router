#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

KEEP="${KEEP:-3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[retain] keep=$KEEP root=$ROOT"

# 1) keep newest generated only
mapfile -t GENS < <(ls -1dt apps/generated/*__* 2>/dev/null || true)
KEPT_GENS=("${GENS[@]:0:$KEEP}")
for d in "${GENS[@]:$KEEP}"; do rm -rf "$d"; done
echo "[retain] generated: total=${#GENS[@]} kept=${#KEPT_GENS[@]}"

# 2) strict keep runs to max KEEP
mapfile -t RUNS < <(ls -1dt artifacts/runs/run_* 2>/dev/null || true)

latest=""
if [[ -f artifacts/runs/LATEST ]]; then
  latest="$(cat artifacts/runs/LATEST 2>/dev/null || true)"
fi

# build ordered unique keep list: latest -> referenced -> newest
declare -A seen=()
keep_list=()

add_keep() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  local rp
  rp="$(readlink -f "$p" 2>/dev/null || true)"
  [[ -n "$rp" ]] || return 0
  [[ -d "$rp" ]] || return 0
  if [[ -z "${seen["$rp"]+x}" ]]; then
    seen["$rp"]=1
    keep_list+=("$rp")
  fi
}

add_keep "$latest"

# referenced by kept generated dirs
for gd in "${KEPT_GENS[@]}"; do
  ref="$gd/.generated_from_run"
  if [[ -f "$ref" ]]; then
    add_keep "$(cat "$ref" 2>/dev/null || true)"
  fi
done

# newest runs
for rd in "${RUNS[@]}"; do
  add_keep "$rd"
done

# enforce strict KEEP
keep_list=("${keep_list[@]:0:$KEEP}")

declare -A keep_set=()
for x in "${keep_list[@]}"; do keep_set["$x"]=1; done

del=0
for rd in "${RUNS[@]}"; do
  rp="$(readlink -f "$rd" 2>/dev/null || true)"
  if [[ -z "${keep_set["$rp"]+x}" ]]; then
    rm -rf "$rd"
    del=$((del+1))
  fi
done

# rewrite markers if they point to pruned runs
for gd in "${KEPT_GENS[@]}"; do
  ref="$gd/.generated_from_run"
  if [[ -f "$ref" ]]; then
    rp="$(readlink -f "$(cat "$ref" 2>/dev/null || true)" 2>/dev/null || true)"
    if [[ -n "$rp" && -z "${keep_set["$rp"]+x}" ]]; then
      echo "PRUNED original_run=$rp" > "$ref"
    fi
  fi
done

echo "[retain] runs: total=${#RUNS[@]} deleted=$del kept=${#keep_list[@]}"

# 3) prune artifacts/tmp
rm -rf artifacts/tmp/* 2>/dev/null || true

# 4) prune logs
mapfile -t QA_LOGS < <(ls -1dt logs/qa_*.log 2>/dev/null || true)
for f in "${QA_LOGS[@]:$KEEP}"; do rm -f "$f"; done

mapfile -t SAFE_LOGS < <(ls -1dt logs/ask_safe_* 2>/dev/null || true)
for f in "${SAFE_LOGS[@]:$KEEP}"; do rm -f "$f"; done
echo "[retain] logs pruned (qa + ask_safe kept=$KEEP)"

# 5) prune backups/script_bak
mapfile -t BAKS < <(ls -1dt backups/script_bak/* 2>/dev/null || true)
if (( ${#BAKS[@]} > KEEP )); then
  mkdir -p backups/_archive
  ts="$(date +%Y%m%d_%H%M%S)"
  archive="backups/_archive/script_bak_extra_${ts}.tar.gz"
  ( cd backups/script_bak && tar -czf "$ROOT/$archive" $(for x in "${BAKS[@]:$KEEP}"; do basename "$x"; done) )
  rm -f "${BAKS[@]:$KEEP}"
  echo "[retain] backups/script_bak archived extras => $archive"
else
  echo "[retain] backups/script_bak kept=${#BAKS[@]}"
fi

echo "[retain] done"
