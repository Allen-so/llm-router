# llm-router

Reproducible LLM routing + generation workbench built on **Docker + LiteLLM**.  
Expose a local **OpenAI-compatible API** and ship **QA-gated workflows** (`plan -> scaffold -> verify`) + deterministic `web_smoke`.

---

## Highlights

- **OpenAI-compatible endpoint**: `http://127.0.0.1:4000/v1`
- **Single auth gate**: `Authorization: Bearer $LITELLM_MASTER_KEY`
- **Provider routing behind one API**: DeepSeek / OpenAI / others
- **Reproducible runs**: `artifacts/runs/` + `logs/` (kept small by retention scripts)
- **One command QA**: `make qa` (demo-safe by default)

---

## Architecture

### Mermaid (rendered by GitHub)
```mermaid
flowchart LR
  U[Client / Scripts] -->|OpenAI-compatible| R[LiteLLM Router\n127.0.0.1:4000/v1]

  R --> DS[DeepSeek]
  R --> OA[OpenAI]
  R --> OT[Other providers]

  subgraph W[Workbench]
    QA[make qa]
    GEN[plan -> scaffold -> verify]
    WEB[web_smoke -> next build]
    ART[artifacts/runs + logs]
  end
ASCII fallback (always works)
Client / Scripts
  |
  |  OpenAI-compatible API
  v
LiteLLM Router (http://127.0.0.1:4000/v1)
  |--> DeepSeek
  |--> OpenAI
  `--> Other providers

Workbench
  - make qa
  - plan -> scaffold -> verify
  - web_smoke -> next build
  - artifacts/runs + logs
Quickstart
Prerequisites

Docker + Docker Compose

Python 3

Node + npm (only for web_smoke)

1) Create .env (DO NOT COMMIT)
cd ~/ai-platform || exit 1

cat > .env <<'EOF'
# Router auth (your own gate key)
LITELLM_MASTER_KEY=CHANGE_ME_LONG_RANDOM

# Provider keys (fill what you use)
DEEPSEEK_API_KEY=CHANGE_ME
# OPENAI_API_KEY=CHANGE_ME
EOF

Sanity check (should say .env is ignored):

git status --porcelain | grep -E '(^A|^M).env$' && echo "DONT COMMIT .env" || echo "OK .env not staged"
git check-ignore -v .env || true
2) Run QA (demo-safe, no real keys required)
make qa
3) Run QA (full, requires real keys + network)
QA_NET=1 make qa
Useful commands
Start router
docker compose up -d
Check router is up (requires auth)
set -a; source .env; set +a

curl -s -o /dev/null -w "models=%{http_code}\n" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/v1/models
E2E websmoke
RUN_QA=1 KEEP_SERVER=0 bash scripts/e2e_websmoke_test.sh
Repo layout

infra/litellm/config.yaml — LiteLLM router config (models, providers, routing rules)

docker-compose.yml — local router runtime

scripts/ — QA + smoke + helper scripts

apps/router-demo/ — demo client + replay tooling

apps/generated/ — generated outputs (kept small by retention)

artifacts/runs/ — run logs + replay payloads

logs/ — QA logs (repo keeps .gitkeep only)

Security notes

.env is ignored by git. Never commit secrets.

.env.example must contain placeholders only.

If GitHub Secret scanning alerts exist, treat those keys as compromised:

revoke/rotate keys on provider

ensure repo has no secrets committed

resolve alerts in GitHub Security tab

Roadmap

Add GitHub Actions CI for make qa (default QA_NET=0)

Add provider-specific health checks

Improve artifacts/runs browsing UI

Better schema validation + error reporting
