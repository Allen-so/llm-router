# ai-platform (LiteLLM Router Base)

A minimal, reusable local AI router base using LiteLLM Proxy (OpenAI-compatible).

## Quickstart (WSL)

```bash
cp .env.example .env
# edit .env and set DEEPSEEK_API_KEY
./scripts/up.sh
./scripts/test_router.sh

Endpoints

Base: http://localhost:4000/v1

Auth: Authorization: Bearer $LITELLM_MASTER_KEY

Model: deepseek-chat

Repo layout

infra/litellm/config.yaml (model mapping)

docker-compose.yml (runs LiteLLM proxy)

scripts/ (up/down/test)
