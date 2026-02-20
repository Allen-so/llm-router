# llm-router

<p align="left">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-black">
  <img alt="docker" src="https://img.shields.io/badge/docker-compose-black">
  <img alt="litellm" src="https://img.shields.io/badge/LiteLLM-router-black">
  <img alt="python" src="https://img.shields.io/badge/Python-3.x-black">
  <img alt="node" src="https://img.shields.io/badge/Node-20%2B-black">
</p>

Reproducible **LLM routing + generation workbench** built on **Docker + LiteLLM**.  
It exposes a **local OpenAI-compatible API** and includes a **QA-gated workflow** (plan → scaffold → verify) plus a deterministic **Next.js web_smoke** gate.

---

## Architecture

> ✅ 注意：下面 ` ```mermaid ` 到 ` ``` ` 之间 **只能放 mermaid 图代码**，不要混进任何文字，否则 GitHub 会报红。

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

  R --> QA
  R --> GEN
  R --> WEB
  R --> ART
What you get

OpenAI-compatible endpoint: http://127.0.0.1:4000/v1

Single auth gate via LITELLM_MASTER_KEY (Bearer)

Provider routing (DeepSeek / OpenAI / others) behind one API

Reproducible workbench

QA: make qa

Generator: plan -> scaffold -> verify

Web smoke: deterministic Next.js scaffold + next build

Artifacts & logs

artifacts/runs/ stores run payloads + replay outputs

logs/ stores QA logs (repo only keeps .gitkeep)

Quickstart
Prerequisites

Docker + Docker Compose

Python 3

Node + npm (only required for web_smoke)

1) Create .env (DO NOT COMMIT)
cd ~/ai-platform || exit 1

cat > .env <<'EOF'
# Router auth (your local gate key - generate a strong random string)
LITELLM_MASTER_KEY=CHANGE_ME_LONG_RANDOM

# Provider keys (fill what you actually use)
DEEPSEEK_API_KEY=CHANGE_ME
# OPENAI_API_KEY=CHANGE_ME
EOF

# sanity: .env must be ignored
git check-ignore -v .env
2) Run QA (demo-safe, no real network/provider calls)
make qa
3) Run QA (full mode, requires working provider keys)
QA_NET=1 make qa
Useful commands
Start / Stop router
docker compose up -d
docker compose down
Check router is reachable (expects 401 without auth)
curl -s -o /dev/null -w "models_no_auth=%{http_code}\n" \
  http://127.0.0.1:4000/v1/models
Check router with auth (expects 200)
set -a; source .env; set +a

curl -s -o /dev/null -w "models_with_auth=%{http_code}\n" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/v1/models
E2E websmoke
RUN_QA=1 KEEP_SERVER=0 bash scripts/e2e_websmoke_test.sh
Repo layout

infra/litellm/config.yaml — LiteLLM router config (models/providers/rules)

docker-compose.yml — local router runtime

scripts/ — QA + smoke + helper scripts

apps/router-demo/ — minimal demo client + replay tooling

apps/generated/ — generated outputs (kept small by retention)

artifacts/runs/ — run logs + replay payloads

logs/ — QA logs (content ignored; keep .gitkeep)

Security notes

.env is ignored by git. Never commit secrets.

.env.example must contain placeholders only.

If GitHub shows Secret scanning alerts, treat those secrets as compromised:

revoke/rotate the key on the provider side

remove it from the repo (and ideally history if it was committed)

resolve the alert in GitHub → Security → Secret scanning

Troubleshooting
Mermaid still shows a red error box?

99% cases are:

you forgot to close the mermaid fence with ```

you put Quickstart text inside the mermaid fence

Fix: ensure the mermaid diagram is exactly between:

```mermaid
...diagram only...

### QA shows 401 / Auth failed

- confirm `.env` is loaded in your shell: `set -a; source .env; set +a`
- confirm you are sending: `Authorization: Bearer $LITELLM_MASTER_KEY`
- confirm container sees the env:
  ```bash
  docker compose exec -T litellm sh -lc 'echo "MASTER_KEY_LEN=${#LITELLM_MASTER_KEY}"'
Roadmap

Add GitHub Actions CI for make qa (QA_NET=0)

Add provider-specific health checks

Add richer web UI for browsing artifacts/runs

Stricter schema validation + better error reporting
