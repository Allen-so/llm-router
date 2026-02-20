# ai-platform

Local **AI Router + Generator Workbench** with a **Web Smoke** run-report viewer.

This repo is designed around one principle: **reproducible runs + verifiable outputs**.

---

## Key Modules

### 1) Router (LiteLLM, OpenAI-compatible)
- Base URL: `http://127.0.0.1:4000/v1`
- Auth header: `Authorization: Bearer $LITELLM_MASTER_KEY`
- Goal: unify multiple providers/models behind one API.

> Router configs live under `infra/` (and Docker-related files if present).

---

### 2) Runs & Artifacts (local only)
Runs are stored under:
- `artifacts/runs/<run_id>/`

Typical files inside a run folder:
- `meta.run.json` — run metadata (kind/status/start/run_dir/plan_hash/gen_dir, etc.)
- `verify_summary.json` — minimal verify result (e.g., `{ ok: true, ... }`)
- `verify.log` — verify logs
- `events.jsonl` — step events
- `plan.web.json` — web smoke plan input

> `artifacts/` is gitignored on purpose (local evidence store).

---

### 3) Web Smoke Viewer (Next.js, generated)
The viewer app is generated under:
- `apps/generated/websmoke__<plan_hash>/`

It reads exported JSON data from:
- `apps/generated/.../public/runs_data/index.json`
- `apps/generated/.../public/runs_data/<run_id>.json`

Routes:
- `/runs` — list runs
- `/runs/<run_id>` — run report detail

> `apps/generated/` is gitignored on purpose (re-generated anytime).

---

## Main Commands

### Full QA
```bash
make qa
One-command Web Smoke (export → build → start → open)
make web_smoke_open
You should see output including:

a free port like http://localhost:3007

/runs

/runs/<run_id>

Verification Checklist (Shipping Gate)
After make web_smoke_open:

Open /runs and confirm the latest run appears.

Open /runs/<run_id> and confirm:

Summary shows kind/status/start/run_dir

Verify shows ok=true when run passed

Meta is present

API check (replace PORT/RID accordingly):

curl -sS "http://localhost:<PORT>/runs_data/index.json" | head
curl -sS -o /dev/null -w "%{http_code}\n" "http://localhost:<PORT>/runs_data/<RID>.json"
curl -sS -o /dev/null -w "%{http_code}\n" "http://localhost:<PORT>/runs/<RID>"
Repo Notes (Do NOT commit)
artifacts/ is ignored (local run evidence).

apps/generated/ is ignored (generated viewer apps).

If you accidentally staged them:

git reset -- apps/generated 2>/dev/null || true
git reset -- artifacts 2>/dev/null || true
Common Issues
1) WSL cannot auto-open browser
Install wslu to enable wslview:

sudo apt-get update && sudo apt-get install -y wslu
2) Port already in use
The pipeline automatically picks a free port, but you can check:

ps aux | rg "next start -p"
