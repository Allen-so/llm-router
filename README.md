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

<!-- AI-PLATFORM-QUICKSTART-BEGIN -->

## Quickstart (Makefile)

### Requirements
- Docker + Docker Compose plugin
- Linux shell (WSL2 OK)

### 30 seconds
```bash
cd /home/suxiaocong/ai-platform
make upready
make check

Expected:

/v1/models => HTTP=401 means router is alive (auth required; expected)

ROUTER_OK means ask path works

Common targets
make help
make upready
make check
make ask  TEXT='Say ROUTER_OK'
make demo TEXT='Reply with exactly ROUTER_OK and nothing else.'
make replay_latest
make qa
make down

Generate a Python CLI tool (plan → scaffold)
make upready
make plan MODEL=default-chat TEXT='Build a minimal python CLI tool named plancheck. It supports --help and prints parsed args.'
make scaffold

Atomic (upready + plan + scaffold):
make gen TEXT='Build a python CLI tool that batch renames files in a folder. Features: dry-run, regex replace, suffix/prefix add. Name it "renamekit".'
Outputs:

artifacts/runs/run_*/plan.json

apps/generated/<name>/RUN_INSTRUCTIONS.txt

apps/generated/<name>/.generated_from_run
QA / Diagnostics
make qa
ls -1t logs/qa_*.log | head
./scripts/doctor.sh
./scripts/secrets_scan.sh

<!-- AI-PLATFORM-QUICKSTART-END -->

