#!/usr/bin/env python3
import json
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
RUNS_DIR = ROOT / "artifacts" / "runs"
REPORTS = ROOT / "artifacts" / "reports"

def load_meta(run_dir: Path) -> dict:
    p = run_dir / "meta.run.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}

def main() -> int:
    if not RUNS_DIR.exists():
        print("[runs_summary] no runs dir")
        return 2

    runs = [p for p in RUNS_DIR.iterdir() if p.is_dir() and p.name.startswith("run_")]
    runs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    rows = []
    for r in runs[:30]:
        m = load_meta(r)
        if not m:
            continue
        rows.append({
            "ts_utc": m.get("ts_utc",""),
            "kind": m.get("kind",""),
            "status": m.get("status",""),
            "plan_name": m.get("plan_name",""),
            "plan_hash": m.get("plan_hash",""),
            "gen_dir": m.get("gen_dir",""),
            "run_dir": m.get("run_dir",""),
        })

    lines = []
    lines.append("| ts_utc | kind | status | plan_name | plan_hash | gen_dir |")
    lines.append("|---|---|---|---|---|---|")
    for x in rows:
        lines.append(f"| {x['ts_utc']} | {x['kind']} | {x['status']} | {x['plan_name']} | {x['plan_hash']} | {x['gen_dir']} |")

    out = "\n".join(lines) + "\n"
    print(out)

    REPORTS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    (REPORTS / f"runs_summary_{stamp}.md").write_text(out, encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
