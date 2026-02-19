#!/usr/bin/env python3
from __future__ import annotations
import csv, json, subprocess, time
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parent.parent
RUNS_ROOT = ROOT / "artifacts" / "runs"

def read_json(p: Path) -> Optional[dict[str, Any]]:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

def tail_lines(p: Path, n: int = 200) -> list[str]:
    try:
        return p.read_text(encoding="utf-8", errors="replace").splitlines()[-n:]
    except Exception:
        return []

def tail_events_jsonl(p: Path, n: int = 160) -> list[Any]:
    out: list[Any] = []
    for line in tail_lines(p, n=n):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out

def pick_latest_websmoke_dir() -> Path:
    p = subprocess.check_output(["bash","-lc","bash scripts/pick_latest_websmoke_dir.sh"], cwd=str(ROOT), text=True).strip()
    return Path(p)

def pick_verify_file(run_dir: Path) -> Optional[Path]:
    # 常见命名都兼容一下
    candidates = [
        run_dir / "verify.web.json",
        run_dir / "verify.json",
        run_dir / "verify.payload.json",
    ]
    for c in candidates:
        if c.exists():
            return c
    # fallback: 任意 verify*.json
    for c in sorted(run_dir.glob("verify*.json")):
        if c.is_file():
            return c
    return None

def get_versions() -> dict[str, str]:
    out: dict[str, str] = {}
    for cmd, key in [(["bash","-lc","node -v"], "node_version"), (["bash","-lc","npm -v"], "npm_version")]:
        try:
            out[key] = subprocess.check_output(cmd, cwd=str(ROOT), text=True).strip()
        except Exception:
            out[key] = ""
    return out

def main() -> int:
    gen_dir = pick_latest_websmoke_dir()
    out_dir = gen_dir / "public" / "runs_data"
    out_dir.mkdir(parents=True, exist_ok=True)

    # 读 summary，没有就先生成
    summary = RUNS_ROOT / "runs_summary_v3.csv"
    if not summary.exists():
        subprocess.check_call(["bash","-lc","python3 scripts/runs_summary_v3.py"], cwd=str(ROOT))

    items: list[dict[str, Any]] = []
    with summary.open("r", encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            items.append({
                "run_id": r.get("run_id",""),
                "run_dir": r.get("run_dir",""),
                "kind": r.get("kind",""),
                "status": r.get("status","unknown") or "unknown",
                "start": r.get("start",""),
            })

    # index.json
    (out_dir / "index.json").write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[ok] wrote {out_dir/'index.json'} items={len(items)}")

    versions_now = get_versions()
    exported = 0

    for it in items:
        rid = it["run_id"]
        run_dir = Path(it["run_dir"])
        meta = read_json(run_dir / "meta.run.json") or {}
        meta.setdefault("run_dir", str(run_dir))
        meta.setdefault("kind", it.get("kind") or "unknown")
        meta.setdefault("status", it.get("status") or "unknown")

        verify_obj: Any = None
        vf = pick_verify_file(run_dir)
        if vf:
            verify_obj = read_json(vf) or {"raw_tail": tail_lines(vf, 40)}
            verify_obj.setdefault("source", str(vf))
        else:
            # derived: 至少给一个不空的 payload
            verify_obj = {
                "derived": True,
                "ok": str(meta.get("status","unknown")).lower() == "ok",
                "captured_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                **versions_now,
            }

        events_tail: list[Any] = []
        ev = run_dir / "events.jsonl"
        if ev.exists():
            events_tail = tail_events_jsonl(ev, 160)

        logs_tail: list[str] = []
        for name in ["run.log", "steps.log", "stdout.log", "stderr.log", "web_smoke.log"]:
            p = run_dir / name
            if p.exists():
                logs_tail = tail_lines(p, 200)
                break

        detail = {
            "run_id": rid,
            "index": it,
            "meta": meta,
            "verify": verify_obj,
            "events_tail": events_tail,
            "logs_tail": logs_tail,
        }

        (out_dir / f"{rid}.json").write_text(json.dumps(detail, ensure_ascii=False, indent=2), encoding="utf-8")
        exported += 1

    print(f"[ok] exported details -> {out_dir} exported={exported}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
