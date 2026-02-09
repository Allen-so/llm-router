#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== up =="
docker compose up -d

echo
echo "== ready =="
./scripts/wait_ready.sh

echo
echo "== test router =="
./scripts/test_router.sh

echo
echo "== route preview sample =="
./scripts/route_preview.sh "Traceback: KeyError in pandas"

echo
echo "== cost summary (last 24h) =="
./scripts/cost_summary.sh --since-hours 24

echo
echo "== cost guard (last 1h) =="
./scripts/cost_guard.sh --since-hours 1

echo
echo "== route stats (last 24h) =="
./scripts/route_stats.sh --since-hours 24

echo
echo "== OK: all checks passed =="

echo
echo "== route regress ==" 

echo
echo "== rules validate ==" 
./scripts/rules_validate.py infra/router_rules.json
./scripts/route_regress.sh
echo "== OK: check completed =="
