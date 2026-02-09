#!/usr/bin/env bash
set -euo pipefail

mkdir -p scripts

# 1) Makefile (use python to ensure tabs are correct)
python3 - <<'PY'
from pathlib import Path

makefile = r'''SHELL := /usr/bin/env bash

BASE ?= http://127.0.0.1:4000
V1   := $(BASE)/v1

.PHONY: help up down restart status logs ps test router models env doctor url

help:
	@echo ""
	@echo "ai-platform (local LiteLLM router)"
	@echo ""
	@echo "Targets:"
	@echo "  make up        - start router (docker compose up -d)"
	@echo "  make down      - stop router"
	@echo "  make restart   - restart router"
	@echo "  make status    - show container status"
	@echo "  make logs      - tail logs"
	@echo "  make test      - run full smoke tests (router + all models)"
	@echo "  make router    - router smoke only"
	@echo "  make models    - list models"
	@echo "  make env       - show required env keys (masked)"
	@echo "  make doctor    - basic sanity checks"
	@echo "  make url       - show base URL"
	@echo ""

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose down
	docker compose up -d

ps:
	docker compose ps

status: ps

logs:
	docker compose logs -n 200 -f litellm

router:
	./scripts/test_router.sh

test:
	./scripts/test_router.sh
	./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

models:
	./scripts/list_models.sh

env:
	./scripts/show_env.sh

doctor:
	./scripts/doctor.sh

url:
	@echo "$(V1)"
'''
Path("Makefile").write_text(makefile, encoding="utf-8")
print("OK: Makefile written")
PY

# 2) helper scripts (no external deps)
cat > scripts/show_env.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "MISSING: .env (copy from .env.example)"; exit 1; }

set -a; source .env; set +a

mask() {
  local v="${1:-}"
  if [[ -z "$v" ]]; then echo "MISSING"; return; fi
  echo "SET"
}

echo "LITELLM_MASTER_KEY=$(mask "${LITELLM_MASTER_KEY:-}")"
echo "DEEPSEEK_API_KEY=$(mask "${DEEPSEEK_API_KEY:-}")"
echo "MOONSHOT_API_KEY=$(mask "${MOONSHOT_API_KEY:-}")"
echo "ANTHROPIC_API_BASE=${ANTHROPIC_API_BASE:-MISSING}"
echo "ANTHROPIC_API_KEY=$(mask "${ANTHROPIC_API_KEY:-}")"
EOF

cat > scripts/list_models.sh <<'EOF'
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
EOF

cat > scripts/doctor.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1/4] docker"
command -v docker >/dev/null && docker --version || { echo "ERROR: docker not found"; exit 1; }

echo "[2/4] docker compose"
docker compose version >/dev/null || { echo "ERROR: docker compose not available"; exit 1; }

echo "[3/4] files"
[[ -f docker-compose.yml ]] || { echo "ERROR: missing docker-compose.yml"; exit 1; }
[[ -f infra/litellm/config.yaml ]] || { echo "ERROR: missing infra/litellm/config.yaml"; exit 1; }
[[ -f .env ]] || echo "WARN: .env missing (copy from .env.example)"

echo "[4/4] compose config"
docker compose config >/dev/null || { echo "ERROR: docker compose config invalid"; exit 1; }

echo "OK: doctor passed"
EOF

chmod +x scripts/show_env.sh scripts/list_models.sh scripts/doctor.sh

echo "OK: setup complete."
echo "Try: make help"
