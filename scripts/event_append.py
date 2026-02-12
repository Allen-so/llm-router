#!/usr/bin/env python3
import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional


def _iso_utc(ts_ms: int) -> str:
    dt = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _read_latest(repo: Path) -> str:
    p = repo / "artifacts" / "runs" / "LATEST"
    try:
        return p.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def _append_jsonl(path: Path, obj: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default="", help="optional, default = artifacts/runs/LATEST")
    ap.add_argument("--kind", default="", help="plan_web / plan / verify_web etc")
    ap.add_argument("--step", required=True)
    ap.add_argument("--phase", required=True, choices=["start", "end"])
    ap.add_argument("--status", default="ok", choices=["ok", "fail"])
    ap.add_argument("--rc", type=int, default=0)
    ap.add_argument("--duration-ms", type=int, default=-1)
    ap.add_argument("--message", default="")
    ap.add_argument("--error-class", default="")
    ap.add_argument("--ts-ms", type=int, default=0, help="optional override timestamp")
    args = ap.parse_args()

    repo = _repo_root()
    run_dir = args.run_dir.strip() or _read_latest(repo)

    ts_ms = args.ts_ms if args.ts_ms > 0 else int(time.time() * 1000)
    ev: Dict[str, Any] = {
        "ts_ms": ts_ms,
        "ts_utc": _iso_utc(ts_ms),
        "run_dir": run_dir,
        "kind": args.kind,
        "step": args.step,
        "phase": args.phase,
        "status": args.status,
        "rc": args.rc,
    }

    if args.duration_ms >= 0:
        ev["duration_ms"] = args.duration_ms
    if args.message:
        ev["message"] = args.message
    if args.error_class:
        ev["error_class"] = args.error_class

    # 1) per-run events
    if run_dir:
        _append_jsonl(Path(run_dir) / "events.jsonl", ev)

    # 2) global events
    _append_jsonl(repo / "logs" / "events.jsonl", ev)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
