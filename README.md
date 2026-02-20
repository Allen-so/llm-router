# ai-platform

Local **AI Router + Generator Workbench** with a **Web Smoke** run-report viewer.

Core idea: **reproducible runs + verifiable outputs + browsable reports**.

---

## Requirements

- WSL2 Ubuntu
- Docker Desktop (with `docker compose`)
- Node.js + npm (for the generated Next.js viewer)

Optional (auto-open browser from WSL):
- `wslu` (provides `wslview`)

```bash
sudo apt-get update && sudo apt-get install -y wslu
Router (LiteLLM)
Base URL: http://127.0.0.1:4000/v1

Auth: Authorization: Bearer $LITELLM_MASTER_KEY

Common commands:

make up
make ready
make upready
make ps
make logs
make down
Sanity checks:

make doctor
make check
CLI: ask
Main entry:

./scripts/ask.sh auto "hello"
./scripts/ask.sh coding "write a bash script to list files"
Modes (see scripts/ask.sh --help):

auto | daily | coding | long | hard | best-effort | premium

Runs & Artifacts (local evidence)
Runs live here (gitignored):

artifacts/runs/<run_id>/

Typical run files:

meta.run.json — run metadata

verify_summary.json — verify result (e.g., ok=true)

verify.log — verify logs

events.jsonl — step events

plan.web.json — web smoke plan

Generated apps (also gitignored):

apps/generated/...

Web Smoke Viewer (Next.js)
One-command pipeline:

make web_smoke_open
What it does:

Run web_smoke (generate + verify)

Build run summary (runs_summary_v3)

Export runs_data JSON into the generated Next.js app public folder

Inject /runs and /runs/[id] pages + patch UI

Build and start Next.js on a free port

Print the report URL

Viewer routes:

/runs — list runs

/runs/<run_id> — run report detail

Cleanup / Keep only latest N
Keep only latest 3 generated apps + runs + key logs:

make prune_keep3
# or:
KEEP=3 bash scripts/retain_keep3.sh
Notes (Do NOT commit)
artifacts/ and apps/generated/ are intentionally gitignored.

If you accidentally staged them:

git reset -- apps/generated 2>/dev/null || true
git reset -- artifacts 2>/dev/null || true
Troubleshooting
WSL cannot auto-open the report URL
Install wslu so wslview exists:

sudo apt-get update && sudo apt-get install -y wslu
NPM audit vulnerabilities
The viewer uses standard Next.js deps; vulnerabilities may appear in npm audit.
They do not block the smoke/report workflow. Fix only if you want to harden deps.
