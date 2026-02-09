# ai-platform (LiteLLM Router Base)

A local, OpenAI-compatible router for hot-swapping multiple LLM providers behind one base URL.

- Base URL: `http://127.0.0.1:4000/v1`
- Auth: `Authorization: Bearer $LITELLM_MASTER_KEY`
- Stack: WSL2 + Docker Desktop + LiteLLM Proxy

## Quickstart

1) Configure env vars

```bash
cp .env.example .env
nano .env
Start

docker compose up -d
Verify

./scripts/test_router.sh
./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat
Endpoints
Health (readiness): http://127.0.0.1:4000/health/readiness

Models: http://127.0.0.1:4000/v1/models

Chat Completions: http://127.0.0.1:4000/v1/chat/completions

Example (models):

set -a; source .env; set +a
curl -sS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
Model Aliases (what you should use)
default-chat — daily use (DeepSeek)

long-chat — long context / long-form (Kimi; temperature must be 1)

premium-chat — strongest (Opus via Anthropic gateway)

best-effort-chat — allows escalation when needed (fallback chain enabled)

Provider-backed model groups also exist:

deepseek-chat, kimi-chat

Routing Policy (Phase 2)
Cost-control by default:

default-chat does not auto-escalate to premium-chat

Context overflow: default-chat → long-chat

Escalation is allowed only on best-effort-chat:

best-effort-chat → long-chat → premium-chat

Scripts
./scripts/wait_ready.sh
Wait until the router is ready (uses readiness + models endpoint).

./scripts/test_router.sh
Readiness + /v1/models + default-chat smoke test.

./scripts/test_models.sh <model...>
Batch test models. Automatically forces temperature=1 for Kimi / long-chat.

Required Environment Variables
Stored in .env (do NOT commit).

Router auth:

LITELLM_MASTER_KEY=...

DeepSeek:

DEEPSEEK_API_KEY=...

Moonshot/Kimi:

MOONSHOT_API_KEY=...

Opus via Anthropic gateway (elbnt.ai):

ANTHROPIC_API_BASE=https://www.elbnt.ai

ANTHROPIC_API_KEY=...

Troubleshooting
Kimi temperature constraint
If you see:
invalid temperature: only 1 is allowed

Use the provided scripts (they enforce temperature=1 for kimi-* and long-chat).

Router starts but tests fail with connection reset
Run:

docker compose logs -n 200 litellm
Then retry after a few seconds. The provided wait_ready.sh prevents most false negatives.

Must run scripts inside WSL
Run scripts in WSL bash (Ubuntu), not Windows CMD/PowerShell.

Security (local use)
Ports are bound to localhost only:

127.0.0.1:4000 -> 4000

So the router is not accessible from LAN by default.
