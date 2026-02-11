#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
import time
import uuid
from pathlib import Path

ROOT = Path("/home/suxiaocong/ai-platform")
GENERATED = ROOT / "apps" / "generated"
RUNS_DIR = ROOT / "artifacts" / "runs"

META_FILE = ".generated_from_run"

def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8", errors="replace")).hexdigest()

def sha12(sha: str) -> str:
    return (sha or "")[:12]

def safe_join(base: Path, rel: str) -> Path:
    rel = rel.strip().lstrip("./")
    if rel.startswith("/") or rel.startswith(".."):
        raise ValueError(f"unsafe path: {rel}")
    p = (base / rel).resolve()
    b = base.resolve()
    if p != b and not str(p).startswith(str(b) + "/"):
        raise ValueError(f"path escapes base: {rel}")
    return p

def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")

def read_meta(dirpath: Path) -> dict:
    mp = dirpath / META_FILE
    if not mp.exists():
        return {}
    meta = {}
    for line in read_text(mp).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()
    return meta

def same_hash(stored: str, plan_sha: str) -> bool:
    s = (stored or "").strip()
    p = (plan_sha or "").strip()
    if not s or not p:
        return False
    # allow stored prefix (12 chars) to match full sha
    return p.startswith(s) if len(s) < len(p) else (s == p)

def dir_matches_plan(dirpath: Path, name: str, plan_sha: str) -> bool:
    meta = read_meta(dirpath)
    stored = (
        meta.get("plan_sha256")
        or meta.get("plan_sha")
        or meta.get("plan_sha256_short")
        or ""
    )
    if same_hash(stored, plan_sha):
        return True

    # fallback: match by directory name (supports name__sha12 and name__sha12__xxxxxx)
    suf = f"{name}__{sha12(plan_sha)}"
    return dirpath.name == suf or dirpath.name.startswith(suf + "__")

def pick_existing_for_plan(name: str, plan_sha: str) -> Path | None:
    prefix = f"{name}__{sha12(plan_sha)}"
    cands = sorted([d for d in GENERATED.glob(prefix + "*") if d.is_dir()])
    for d in cands:
        if dir_matches_plan(d, name, plan_sha):
            return d
    return None

def write_meta(out_root: Path, run_dir: Path, plan_sha: str, plan: dict):
    meta = [
        f"created={time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"source_run={run_dir}",
        f"plan_sha256={plan_sha}",
        f"plan_sha256_short={sha12(plan_sha)}",
        f"name={plan.get('name','')}",
        f"type={plan.get('type','')}",
        f"schema_version={plan.get('schema_version','')}",
    ]
    (out_root / META_FILE).write_text("\n".join(meta) + "\n", encoding="utf-8")

def write_run_instructions(out_root: Path, name: str, run_dir: Path, plan_sha: str, plan: dict):
    lines = []
    lines.append(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Project: {name}")
    lines.append(f"Source run: {run_dir}")
    lines.append(f"Plan sha256: {plan_sha}")
    lines.append("")
    lines.append("Recommended (project-local venv):")
    lines.append(f"  cd {out_root}")
    lines.append("  python3 -m venv .venv")
    lines.append("  source .venv/bin/activate")
    lines.append("  python -m pip install -U pip")
    lines.append("  pip install -e .")
    lines.append(f"  python -m {name}.cli --help")
    lines.append("")
    lines.append("Quick test (no venv, may not work if project expects install):")
    lines.append(f"  cd {out_root}")
    lines.append(f"  python3 -m {name}.cli --help")
    lines.append("")
    lines.append("Plan run.commands (model-provided):")
    cmds = plan.get("run", {}).get("commands", [])
    for c in cmds:
        lines.append(f"  {c}")
    (out_root / "RUN_INSTRUCTIONS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default=None, help="artifacts/runs/run_*/ (default: LATEST)")
    ap.add_argument("--force", action="store_true", help="overwrite destination if exists")
    args = ap.parse_args()

    GENERATED.mkdir(parents=True, exist_ok=True)

    run_dir = Path(args.run_dir) if args.run_dir else Path((RUNS_DIR / "LATEST").read_text(encoding="utf-8").strip())
    plan_path = run_dir / "plan.json"
    if not plan_path.exists():
        raise SystemExit(f"plan.json not found in {run_dir}")

    raw = read_text(plan_path)
    plan_sha = sha256_text(raw)
    plan = json.loads(raw)

    name = plan["name"]
    base = GENERATED / name

    # 0) If already generated for this plan hash (any matching dir), reuse it
    existing = pick_existing_for_plan(name, plan_sha)
    if existing and not args.force:
        print(f"[ok] already generated (same plan hash): {existing}")
        print(f"[run] recommended:")
        print(f"  cd {existing} && cat RUN_INSTRUCTIONS.txt")
        return

    # 1) decide target dir
    target = base
    if target.exists():
        if dir_matches_plan(target, name, plan_sha) and not args.force:
            print(f"[ok] already generated (same plan hash): {target}")
            print(f"[run] recommended:")
            print(f"  cd {target} && cat RUN_INSTRUCTIONS.txt")
            return
        if args.force:
            shutil.rmtree(target)
        else:
            target = GENERATED / f"{name}__{sha12(plan_sha)}"

    # 2) if alt exists, handle idempotent / conflict
    if target.exists():
        if dir_matches_plan(target, name, plan_sha) and not args.force:
            print(f"[ok] already generated (same plan hash): {target}")
            print(f"[run] recommended:")
            print(f"  cd {target} && cat RUN_INSTRUCTIONS.txt")
            return
        if args.force:
            shutil.rmtree(target)
        else:
            # collision: add short random suffix
            target = GENERATED / f"{name}__{sha12(plan_sha)}__{uuid.uuid4().hex[:6]}"
            if target.exists() and not args.force:
                raise SystemExit(f"collision: {target} already exists (rerun or use --force)")

    target.mkdir(parents=True, exist_ok=True)

    # 3) write files from plan
    files = plan.get("files", [])
    for f in files:
        rel = f["path"]
        content = f["content"]
        outp = safe_join(target, rel)
        outp.parent.mkdir(parents=True, exist_ok=True)
        outp.write_text(content, encoding="utf-8")

    write_meta(target, run_dir, plan_sha, plan)
    write_run_instructions(target, name, run_dir, plan_sha, plan)

    print(f"[ok] generated at: {target}")
    print("[run] recommended:")
    print(f"  cd {target} && cat RUN_INSTRUCTIONS.txt")
    cmds = plan.get("run", {}).get("commands", [])
    if cmds:
        print("[run] commands:")
        for c in cmds:
            print(f"  {c}")

if __name__ == "__main__":
    main()
