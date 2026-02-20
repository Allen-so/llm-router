# llm-router

<p align="left">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-black">
  <img alt="docker" src="https://img.shields.io/badge/docker-compose-black">
  <img alt="litellm" src="https://img.shields.io/badge/LiteLLM-router-black">
  <img alt="python" src="https://img.shields.io/badge/Python-3.x-black">
  <img alt="node" src="https://img.shields.io/badge/Node-20%2B-black">
</p>

Reproducible LLM routing + generation workbench built on Docker + LiteLLM.  
Expose a local OpenAI-compatible API and ship QA-gated workflows (plan → scaffold → verify) + deterministic web_smoke.

---

## Architecture

> IMPORTANT: The mermaid block must start at column 1, and the closing ``` must be on its own line.

```mermaid
flowchart LR
  Client["Client / Scripts"]
  Router["LiteLLM Router — 127.0.0.1:4000/v1"]

  DS["DeepSeek"]
  OA["OpenAI"]
  OT["Other providers"]

  Client --> Router
  Router --> DS
  Router --> OA
  Router --> OT

  subgraph Workbench
    QA["make qa"]
    GEN["plan -> scaffold -> verify"]
    WEB["web_smoke -> next build"]
    ART["artifacts/runs + logs"]
  end

  Router --> QA
  Router --> GEN
  Router --> WEB
  Router --> ART
What you get

OpenAI-compatible endpoint: http://127.0.0.1:4000/v1

Single auth gate: Authorization: Bearer $LITELLM_MASTER_KEY

Provider routing behind one API: DeepSeek / OpenAI / others

Workbench flows

QA: make qa

Generator: plan → scaffold → verify

Web smoke: deterministic Next.js scaffold + next build

Artifacts and logs

artifacts/runs/ stores run payloads and replay outputs

logs/ stores QA logs (repo keeps .gitkeep only)

Quickstart
Prerequisites

Docker + Docker Compose

Python 3

Node + npm (only for web_smoke)

Create .env (DO NOT COMMIT)
cd ~/ai-platform || exit 1

cat > .env <<'EOF'
LITELLM_MASTER_KEY=CHANGE_ME_LONG_RANDOM
DEEPSEEK_API_KEY=CHANGE_ME
# OPENAI_API_KEY=CHANGE_ME
EOF

git check-ignore -v .env
Run QA (demo-safe)
make qa
Run QA (full mode, requires real keys)
QA_NET=1 make qa
Useful commands
Start router
docker compose up -d
Stop router
docker compose down
Check router without auth (expect 401)
curl -s -o /dev/null -w "models_no_auth=%{http_code}\n" \
  http://127.0.0.1:4000/v1/models
Check router with auth (expect 200)
set -a; source .env; set +a

curl -s -o /dev/null -w "models_with_auth=%{http_code}\n" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/v1/models
E2E websmoke
RUN_QA=1 KEEP_SERVER=0 bash scripts/e2e_websmoke_test.sh
Repo layout

infra/litellm/config.yaml — LiteLLM router config

docker-compose.yml — local router runtime

scripts/ — QA + smoke + helper scripts

apps/router-demo/ — demo client + replay tooling

apps/generated/ — generated outputs (kept small by retention)

artifacts/runs/ — run logs + replay payloads

logs/ — QA logs (.gitkeep tracked)

Security notes

.env is ignored by git. Never commit secrets.

.env.example must contain placeholders only.

If GitHub Secret scanning alerts exist, treat those keys as compromised:

revoke/rotate keys on provider

ensure repo has no secrets committed

resolve alerts in GitHub Security tab

Roadmap

Add GitHub Actions CI for make qa (QA_NET=0)

Add provider-specific health checks

Improve artifacts/runs browsing UI

Better schema validation + error reporting
