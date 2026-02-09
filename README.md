# ai-platform

Local LiteLLM router exposing a single OpenAI-compatible API across providers.

- Base URL: `http://127.0.0.1:4000/v1`
- Auth: `Authorization: Bearer $LITELLM_MASTER_KEY`
- Local-only bind: `127.0.0.1:4000`

## Quickstart

```bash
cp .env.example .env
nano .env

docker compose up -d
./scripts/test_router.sh
./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

Model aliases

default-chat — daily (DeepSeek)

long-chat — long-form (Kimi; temperature=1 enforced in scripts)

premium-chat — strongest (Opus via Anthropic gateway)

best-effort-chat — escalation allowed

Endpoints

Readiness: http://127.0.0.1:4000/health/readiness

Models: http://127.0.0.1:4000/v1/models

Chat: http://127.0.0.1:4000/v1/chat/completions

Routing policy (Phase 2)

No auto-escalation on default-chat

Context overflow: default-chat → long-chat

Escalation only on best-effort-chat: best-effort-chat → long-chat → premium-chat

Notes

Run scripts inside WSL bash (Ubuntu), not Windows CMD/PowerShell.
