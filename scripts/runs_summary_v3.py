#!/usr/bin/env python3
from __future__ import annotations
import csv, json, time
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parent.parent
RUNS_ROOT = ROOT / "artifacts" / "runs"
OUT = RUNS_ROOT / "runs_summary_v3.csv"

def read_json(p: Path) -> Optional[dict[str, Any]]:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

def iso_from_mtime(p: Path) -> str:
    # local time + offset
    t = time.localtime(p.stat().st_mtime)
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", t)

def main() -> int:
    RUNS_ROOT.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []

    for d in sorted(RUNS_ROOT.glob("run_*"), key=lambda x: x.stat().st_mtime, reverse=True):
        if not d.is_dir():
            continue
        run_id = d.name
        meta = read_json(d / "meta.run.json") or {}
        kind = meta.get("kind") or ("web_smoke" if "web_smoke" in run_id else "unknown")
        status = meta.get("status") or "unknown"
        start = meta.get("ts") or meta.get("ts_utc") or meta.get("ts_iso") or iso_from_mtime(d)
        duration_s = meta.get("duration_s") or ""
        plan_hash = meta.get("plan_hash") or ""
        gen_dir = meta.get("gen_dir") or ""
        rows.append({
            "run_id": run_id,
            "run_dir": str(d),
            "kind": kind,
            "status": status,
            "start": start,
            "duration_s": duration_s,
            "plan_hash": plan_hash,
            "gen_dir": gen_dir,
        })

    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["run_id","run_dir","kind","status","start","duration_s","plan_hash","gen_dir"])
        w.writeheader()
        for r in rows:
            w.writerow(r)

    print(f"[ok] wrote {OUT} rows={len(rows)}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
