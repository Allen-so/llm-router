# ai-platform

Local LiteLLM router that exposes one OpenAI-compatible API for multiple providers.

- Base URL: `http://127.0.0.1:4000/v1`
- Auth header: `Authorization: Bearer $LITELLM_MASTER_KEY`
- Runs on: WSL2 + Docker Desktop

## Quickstart

```bash
cp .env.example .env
nano .env

docker compose up -d
./scripts/test_router.sh
./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

Recommended model aliases

default-chat — daily (DeepSeek)

long-chat — long-form (Kimi; temperature=1 enforced by test script)

premium-chat — strongest (Opus via Anthropic gateway)

best-effort-chat — escalation allowed (fallback chain enabled)

Endpoints

Readiness: http://127.0.0.1:4000/health/readiness

Models: http://127.0.0.1:4000/v1/models

Chat: http://127.0.0.1:4000/v1/chat/completions

Routing policy (Phase 2)

default-chat does not auto-escalate to premium-chat

Context overflow: default-chat → long-chat

Escalation is allowed only on best-effort-chat:

best-effort-chat → long-chat → premium-chat

Notes

Run scripts inside WSL bash (Ubuntu), not Windows CMD/PowerShell.

Port is bound to localhost only: 127.0.0.1:4000 (not exposed to LAN).
