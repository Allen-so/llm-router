# llm-router

Reproducible LLM routing + generation workbench (Docker, LiteLLM).  
One local OpenAI-compatible endpoint, plus a QA-gated generator workflow.

---

## Status

- ✅ `make qa` PASS (demo-safe mode, no secrets committed)
- ✅ OpenAI-compatible base URL: `http://127.0.0.1:4000/v1`
- ✅ Router auth via `Authorization: Bearer $LITELLM_MASTER_KEY`

---

## What you get

### Router (LiteLLM)
- One endpoint for multiple providers (DeepSeek / OpenAI / others)
- Model aliases: `default-chat`, `long-chat`, `best-effort-chat`, `premium-chat` (as configured)
- Local auth gate: master key required

### Workbench (Reproducible generation)
- **plan → scaffold → verify** workflow (deterministic, artifact-logged)
- Web E2E smoke gate (Next.js build verification)
- One command QA: `make qa`

---

## Architecture

```mermaid
flowchart LR
  U["Client / Scripts"] -->|OpenAI-compatible| R["LiteLLM Router<br/>127.0.0.1:4000/v1"]

  R --> DS["DeepSeek"]
  R --> OA["OpenAI"]
  R --> OT["Other providers"]

  subgraph W["Workbench"]
    QA["make qa"]
    GEN["plan -> scaffold -> verify"]
    WEB["web_smoke -> next build"]
    ART["artifacts/runs + logs"]
  end


Quickstart
Prerequisites

Docker + Docker Compose

Node + npm (for web_smoke)

Python 3

1) Create .env (DO NOT COMMIT)
cat > .env <<'EOF'
LITELLM_MASTER_KEY=CHANGE_ME_LONG_RANDOM
DEEPSEEK_API_KEY=CHANGE_ME
# OPENAI_API_KEY=CHANGE_ME
EOF
2) Run QA (demo-safe)
make qa
3) Run QA (full, requires real keys)
QA_NET=1 make qa
Useful commands
Start router
docker compose up -d
Check router is up
curl -s -o /dev/null -w "models=%{http_code}\n" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/v1/models
E2E websmoke
RUN_QA=1 KEEP_SERVER=0 bash scripts/e2e_websmoke_test.sh
Repo layout

infra/litellm/config.yaml — LiteLLM router config (models, providers, routing rules)

docker-compose.yml — local router runtime

scripts/ — QA + smoke + helper scripts

apps/router-demo/ — minimal demo client + replay tooling

apps/generated/ — generated outputs (kept small by retention script)

artifacts/runs/ — run logs + replay payloads

logs/ — QA logs (content ignored, keep .gitkeep)

Security notes

.env is ignored by git. Never commit secrets.

.env.example must contain placeholders only.

If GitHub shows Secret scanning alerts, treat those secrets as compromised:
rotate/revoke them, then resolve the alert in the Security tab.

Roadmap

 Add GitHub Actions CI for make qa (QA_NET=0)

 Add provider-specific health checks

 Add richer web UI for browsing artifacts/runs

 Add stricter schema validation + better error reporting
