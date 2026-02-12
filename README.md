# ai-platform

Local LiteLLM router + generator workbench (V2).  
Expose a single OpenAI-compatible API across providers, plus a reproducible **plan → scaffold → verify** pipeline.

- Base URL: `http://127.0.0.1:4000/v1`
- Auth: `Authorization: Bearer $LITELLM_MASTER_KEY`
- Local-only bind: `127.0.0.1:4000`

## What you get

- **Router**: one API, multiple model aliases
- **Generators**
  - **Python CLI generator**: `plan → scaffold → verify_generated`
  - **Next.js generator**: `plan_web → scaffold_web → verify_generated_web`
- **QA gate**: `make qa` as the single acceptance gate
- **Run artifacts**: every run persists inputs/outputs/traces under `artifacts/runs/`

## Model aliases

- `default-chat` — daily (DeepSeek)
- `long-chat` — long-form (Kimi)
- `premium-chat` — strongest (Opus via Anthropic gateway)
- `best-effort-chat` — escalation allowed (fallback chain enabled)

## Endpoints

- Readiness: `http://127.0.0.1:4000/health/readiness`
- Models: `http://127.0.0.1:4000/v1/models`
- Chat: `http://127.0.0.1:4000/v1/chat/completions`

<!-- AI-PLATFORM-QUICKSTART-BEGIN -->

## Quickstart (Makefile)

### Requirements

- Docker + Docker Compose plugin
- Bash-compatible shell
- Run commands at the repo root (where the `Makefile` lives)

### 30 seconds

1) Configure env:

```bash
cp .env.example .env
# edit .env
Bring up router + basic checks:

make upready
make check
Expected (high level):

/v1/models => HTTP=401 means router is alive (auth required; expected)

ROUTER_OK means the ask path works

Common targets
make help
make upready
make check
make ask  TEXT='Say ROUTER_OK'
make demo TEXT='Reply with exactly ROUTER_OK and nothing else.'
make replay_latest
make qa
make down
Generator: Python CLI (LLM-driven)
Plan:

make upready
make plan MODEL=default-chat TEXT='Build a minimal python CLI tool named plancheck. It supports --help and prints parsed args.'
Scaffold:

make scaffold
Atomic (plan + scaffold):

make gen TEXT='Build a python CLI tool that batch renames files in a folder. Features: dry-run, regex replace, suffix/prefix add. Name it "renamekit".'
Outputs:

artifacts/runs/run_*/plan.json

apps/generated/<name>/RUN_INSTRUCTIONS.txt

apps/generated/<name>/.generated_from_run

Smoke test (generated project install + help):

./scripts/verify_generated.sh
Generator: Next.js site (LLM-driven)
Generate:

make upready
make gen_nextjs MODEL=default-chat TEXT='Build a Next.js site named v2-demo. Home and /about. Minimal product style.'
make meta_latest
make runs_summary
Inspect latest run:

RUN_DIR="$(cat artifacts/runs/LATEST)"
ls -la "$RUN_DIR"
cat "$RUN_DIR/policy.decision.json"
cat "$RUN_DIR/policy.trace.json"
tail -n 50 "$RUN_DIR/events.jsonl"
Verify the generated web build:

./scripts/verify_generated_web.sh
Policy / Retry
make policy_smoke
QA / Diagnostics
make qa
ls -1t logs/qa_*.log | head -n 5
./scripts/doctor.sh
./scripts/secrets_scan.sh
<!-- AI-PLATFORM-QUICKSTART-END -->

---