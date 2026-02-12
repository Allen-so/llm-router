#!/usr/bin/env python3
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


def iso_utc(ts_ms: int) -> str:
    dt = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_events(run_dir: Path) -> List[Dict[str, Any]]:
    p = run_dir / "events.jsonl"
    if not p.exists():
        return []
    out = []
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:
            continue
    out = [e for e in out if isinstance(e.get("ts_ms"), int)]
    out.sort(key=lambda e: e["ts_ms"])
    return out


def infer_kind(run_dir: Path) -> str:
    if (run_dir / "plan.web.json").exists():
        return "plan_web"
    if (run_dir / "plan.json").exists():
        return "plan"
    return "unknown"


def session_start_ts(evs: List[Dict[str, Any]]) -> Optional[int]:
    # prefer replay session; else plan session
    keys = [("web_replay_start", "start"), ("plan_web", "start"), ("plan", "start")]
    candidates = []
    for e in evs:
        for step, ph in keys:
            if e.get("step") == step and e.get("phase") == ph:
                candidates.append(e["ts_ms"])
    if candidates:
        return candidates[-1]
    return evs[0]["ts_ms"] if evs else None


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    runs_root = repo / "artifacts" / "runs"

    run_dirs = []
    if runs_root.exists():
        run_dirs = sorted([p for p in runs_root.iterdir() if p.is_dir() and p.name.startswith("run_")],
                          key=lambda x: x.name, reverse=True)[:50]

    print("| ts_utc | kind | status | plan_name | plan_hash | gen_dir | last_step | duration_ms | fail_reason |")
    print("|---|---|---|---|---|---|---|---:|---|")

    for rd in run_dirs:
        meta = read_json(rd / "meta.run.json") or {}
        kind = meta.get("kind") or infer_kind(rd)
        status = meta.get("status") or "unknown"
        plan_name = meta.get("plan_name") or meta.get("name") or ""
        plan_hash = meta.get("plan_hash") or ""
        gen_dir = meta.get("gen_dir") or ""

        evs = load_events(rd)
        last_step = ""
        duration_ms = ""
        fail_reason = ""

        if evs:
            ss = session_start_ts(evs)
            sess = [e for e in evs if e["ts_ms"] >= ss] if ss is not None else evs

            # duration
            ts_list = [e["ts_ms"] for e in sess]
            if ts_list:
                duration_ms = str(max(ts_list) - min(ts_list))

            # last_step (end)
            ends = [e for e in sess if e.get("phase") == "end"]
            if ends:
                last_step = str(ends[-1].get("step") or "")

            # fail_reason (last fail end)
            fails = [e for e in sess if e.get("phase") == "end" and e.get("status") == "fail"]
            if fails:
                f = fails[-1]
                status = "fail"
                fail_reason = f'{f.get("step","")}/{f.get("error_class","")}/{f.get("message","")}'.strip("/")

            ts_ms = max(ts_list) if ts_list else int(rd.stat().st_mtime * 1000)
        else:
            ts_ms = int(rd.stat().st_mtime * 1000)

        row = [
            iso_utc(ts_ms),
            kind,
            status,
            plan_name,
            plan_hash,
            gen_dir,
            last_step,
            duration_ms,
            fail_reason,
        ]
        print("| " + " | ".join((x if x is not None else "") for x in row) + " |")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
