#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

source "$ROOT/scripts/load_node.sh" || true

RUN="artifacts/runs/run_web_smoke_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"

cat > "$RUN/plan.web.json" <<'JSON'
{
  "project_type": "nextjs_site",
  "name": "websmoke",
  "app_title": "Web Smoke",
  "tagline": "Minimal site.",
  "pages": [
    { "route": "/", "title": "Home", "sections": ["Hero", "CTA"] },
    { "route": "/about", "title": "About", "sections": ["Bio", "Links"] }
  ]
}
JSON

echo "$(pwd)/$RUN" > artifacts/runs/LATEST

python3 apps/router-demo/scaffold_web.py
./scripts/verify_generated_web.sh
