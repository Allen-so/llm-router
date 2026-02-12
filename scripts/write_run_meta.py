#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNS_DIR = ROOT / "artifacts" / "runs"
LATEST = RUNS_DIR / "LATEST"
EVENTS = ROOT / "logs" / "events.jsonl"

def now_utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

def sh(cmd: list[str]) -> str:
    try:
        out = subprocess.check_output(cmd, cwd=str(ROOT), stderr=subprocess.DEVNULL)
        return out.decode("utf-8", errors="replace").strip()
    except Exception:
        return ""

def canonical_hash(obj: dict) -> str:
    raw = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:12]

def parse_kv_file(path: Path) -> dict:
    if not path.exists():
        return {}
    d = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d

def detect_kind(run_dir: Path) -> str:
    name = run_dir.name
    if name.startswith("run_plan_web_"):
        return "plan_web"
    if name.startswith("run_web_smoke_"):
        return "web_smoke"
    if name.startswith("run_plan_"):
        return "plan"
    if name.startswith("run_demo_"):
        return "demo"
    return "unknown"

def parse_verify_versions(verify_log: Path) -> tuple[str, str]:
    node_v = ""
    npm_v = ""
    if not verify_log.exists():
        return node_v, npm_v
    lines = verify_log.read_text(encoding="utf-8", errors="replace").splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("v") and len(s) <= 20 and node_v == "":
            node_v = s
            continue
        if s and all(ch.isdigit() or ch == "." for ch in s) and npm_v == "":
            npm_v = s
    return node_v, npm_v

def parse_gen_dir_from_logs(run_dir: Path) -> str:
    # priority: apply_web.log -> verify_web.log
    apply_log = run_dir / "apply_web.log"
    if apply_log.exists():
        for line in apply_log.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("gen_dir="):
                return line.split("=", 1)[1].strip()
    verify_log = run_dir / "verify_web.log"
    if verify_log.exists():
        for line in verify_log.read_text(encoding="utf-8", errors="replace").splitlines():
            if "gen_dir=" in line:
                return line.split("gen_dir=", 1)[1].strip()
    return ""

def compute_expected_gen_dir(run_dir: Path) -> str:
    plan_web = run_dir / "plan.web.json"
    if not plan_web.exists():
        return ""
    plan = json.loads(plan_web.read_text(encoding="utf-8"))
    name = plan.get("name")
    if not name:
        return ""
    h = canonical_hash(plan)
    return str(ROOT / "apps" / "generated" / f"{name}__{h}")

def verify_status(run_dir: Path) -> str:
    v = run_dir / "verify_web.log"
    if v.exists():
        txt = v.read_text(encoding="utf-8", errors="replace")
        if "[ok] web build passed" in txt:
            return "ok"
        if "FAILED" in txt or "Error" in txt:
            return "fail"
    return "unknown"

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default="")
    ap.add_argument("--append-events", action="store_true")
    args = ap.parse_args()

    if args.run_dir:
        run_dir = Path(args.run_dir)
    else:
        if not LATEST.exists():
            print("[meta] Missing artifacts/runs/LATEST")
            return 2
        run_dir = Path(LATEST.read_text(encoding="utf-8").strip())

    if not run_dir.exists():
        print(f"[meta] run_dir not found: {run_dir}")
        return 2

    kind = detect_kind(run_dir)
    plan_web = run_dir / "plan.web.json"
    plan_json = run_dir / "plan.json"

    plan_hash = ""
    plan_name = ""
    if plan_web.exists():
        plan = json.loads(plan_web.read_text(encoding="utf-8"))
        plan_hash = canonical_hash(plan)
        plan_name = plan.get("name", "")
    elif plan_json.exists():
        plan = json.loads(plan_json.read_text(encoding="utf-8"))
        plan_hash = canonical_hash(plan)
        plan_name = plan.get("name", "")

    gen_dir = parse_gen_dir_from_logs(run_dir)
    if not gen_dir:
        gen_dir = compute_expected_gen_dir(run_dir)

    status = verify_status(run_dir)
    node_v, npm_v = parse_verify_versions(run_dir / "verify_web.log")

    git_commit = sh(["git", "rev-parse", "HEAD"])
    git_dirty = "1" if sh(["git", "status", "--porcelain"]) else "0"

    meta_path = run_dir / "meta.run.json"
    old = {}
    if meta_path.exists():
        try:
            old = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            old = {}

    policy = {}
    polp = run_dir / "policy.decision.json"
    if polp.exists():
        try:
            policy = json.loads(polp.read_text(encoding="utf-8"))
        except Exception:
            policy = {}

    meta = {
        **old,
        "ts_utc": now_utc_iso(),
        "run_dir": str(run_dir),
        "kind": kind,
        "status": status,
        "plan_hash": plan_hash,
        "plan_name": plan_name,
        "gen_dir": gen_dir,
        "node_version": node_v,
        "npm_version": npm_v,
        "git_commit": git_commit,
        "git_dirty": git_dirty,
        "policy": policy,
    }

    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.append_events:
        EVENTS.parent.mkdir(parents=True, exist_ok=True)
        EVENTS.open("a", encoding="utf-8").write(json.dumps(meta, ensure_ascii=False) + "\n")

    print(f"[meta] OK run_dir={run_dir} status={status} kind={kind}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
