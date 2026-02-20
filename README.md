# llm-router

Reproducible LLM routing + generation workbench (Docker, LiteLLM).

## Quickstart
```bash
make qa
E2E web smoke gate
RUN_QA=1 KEEP_SERVER=0 bash scripts/e2e_websmoke_test.sh
What you get

OpenAI-compatible router endpoint (LiteLLM)

QA gate: make qa

Reproducible runs + artifacts

Web smoke report with /runs + /runs_data
