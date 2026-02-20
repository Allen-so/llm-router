#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parents[1]
RUNS_ROOT = ROOT / "artifacts" / "runs"
LATEST = RUNS_ROOT / "LATEST"

def truthy_ok(v: Any) -> Optional[bool]:
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    if isinstance(v, str):
        s = v.strip().lower()
        if s in ("true", "ok", "pass", "passed", "success", "1", "yes"):
            return True
        if s in ("false", "fail", "failed", "error", "0", "no"):
            return False
    return None

def read_json(path: Path) -> Optional[dict[str, Any]]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None

def infer_status_from_run(run_dir: Path) -> str:
    # 1) verify_summary.json (preferred)
    v = read_json(run_dir / "verify_summary.json")
    if isinstance(v, dict):
        okv = truthy_ok(v.get("ok"))
        if okv is True:
            return "ok"
        if okv is False:
            return "fail"

    # 2) fallback: scan verify.log (best-effort)
    vp = run_dir / "verify.log"
    if vp.exists():
        t = vp.read_text(encoding="utf-8", errors="ignore").lower()
        if " ok " in t or "\n[ok]" in t:
            return "ok"
        if " fail " in t or "\n[fail]" in t or "error" in t:
            return "fail"

    return "unknown"

def resolve_target_run_dir(arg: str) -> Optional[Path]:
    if arg:
        p = Path(arg)
        if not p.is_absolute():
            p = ROOT / p
        return p if p.exists() else None

    if LATEST.exists():
        s = LATEST.read_text(encoding="utf-8", errors="ignore").strip()
        if s:
            p = Path(s)
            if not p.is_absolute():
                p = ROOT / p
            if p.exists():
                return p
    return None

def fix_one(run_dir: Path, force: bool) -> bool:
    meta_path = run_dir / "meta.run.json"
    meta = read_json(meta_path) or {}
    cur = (meta.get("status") or "").strip().lower()
    if (not force) and cur and cur != "unknown":
        return False

    new_status = infer_status_from_run(run_dir)
    meta["status"] = new_status
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[meta_fix_status] {run_dir.name}: {cur or '-'} -> {new_status}")
    return True

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default="", help="default: artifacts/runs/LATEST")
    ap.add_argument("--all", action="store_true", help="fix all run_* under artifacts/runs/")
    ap.add_argument("--force", action="store_true", help="overwrite even if status is already ok/fail")
    args = ap.parse_args()

    updated = 0
    if args.all:
        for d in sorted(RUNS_ROOT.glob("run_*"), key=lambda p: p.stat().st_mtime, reverse=True):
            if d.is_dir() and fix_one(d, force=args.force):
                updated += 1
    else:
        rd = resolve_target_run_dir(args.run_dir)
        if not rd or not rd.is_dir():
            print("[meta_fix_status] cannot resolve run_dir (set --run-dir or ensure artifacts/runs/LATEST exists)")
            return 2
        if fix_one(rd, force=args.force):
            updated += 1

    print(f"[meta_fix_status] done updated={updated}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
