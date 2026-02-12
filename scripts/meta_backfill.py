#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNS_DIR = ROOT / "artifacts" / "runs"

def main() -> int:
    if not RUNS_DIR.exists():
        print("[meta_backfill] no runs dir")
        return 2
    runs = [p for p in RUNS_DIR.iterdir() if p.is_dir() and p.name.startswith("run_")]
    runs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    runs = runs[:50]
    n = 0
    for r in runs:
        subprocess.run(["python3", "scripts/write_run_meta.py", "--run-dir", str(r)], check=False)
        n += 1
    print(f"[meta_backfill] OK updated={n}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
