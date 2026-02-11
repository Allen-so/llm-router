#!/usr/bin/env python3
import argparse, json, time, hashlib, shutil
from pathlib import Path
import uuid
import shutil

ROOT = Path("/home/suxiaocong/ai-platform")
GENERATED = ROOT / "apps" / "generated"
RUNS_DIR = ROOT / "artifacts" / "runs"

def safe_join(base: Path, rel: str) -> Path:
    # no absolute paths
    if rel.startswith("/") or rel.startswith("\\"):
        raise ValueError(f"absolute path not allowed: {rel}")
    # normalize and prevent escaping
    p = (base / rel).resolve()
    base_r = base.resolve()
    if p != base_r and not str(p).startswith(str(base_r) + "/"):
        raise ValueError(f"path escapes base: {rel}")
    return p

def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8", errors="replace")).hexdigest()

def same_hash(existing: str, plan_sha: str) -> bool:
    e = (existing or '').strip()
    p = (plan_sha or '').strip()
    if not e or not p:
        return False
    # allow stored prefix (e.g. 12 chars) to match full sha
    return p.startswith(e) if len(e) < len(p) else (e == p)

def alt_name(name: str, plan_sha: str) -> str:
    # stable, short suffix to avoid collisions
    return f"{name}__{plan_sha[:12]}"


    return hashlib.sha256(s.encode("utf-8", errors="replace")).hexdigest()

def write_run_instructions(out_root: Path, name: str, plan: dict, run_dir: Path, plan_sha: str):
    lines = []
    lines.append(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Project: {name}")
    lines.append(f"Source run: {run_dir}")
    lines.append(f"Plan SHA256: {plan_sha}")
    lines.append("")

    lines.append("Recommended (project-local venv):")
    lines.append(f"  cd {out_root}")
    lines.append("  python3 -m venv .venv")
    lines.append("  source .venv/bin/activate")
    lines.append("  python -m pip install -U pip")
    lines.append("  pip install -e .")

    # best-effort default help command
    pkg_help = None
    if (out_root / "src" / name / "cli.py").exists():
        pkg_help = f"python -m {name}.cli --help"
    elif (out_root / "src" / name / "__main__.py").exists():
        pkg_help = f"python -m {name} --help"

    if pkg_help:
        lines.append(f"  {pkg_help}")

    lines.append("")
    lines.append("Quick test (no venv, may not work if project expects install):")
    lines.append(f"  cd {out_root}")
    if pkg_help:
        lines.append(f"  {pkg_help.replace('python ', 'python3 ')}")
    else:
        lines.append("  # run a command from the section below")

    lines.append("")
    lines.append("Plan run.commands (model-provided):")
    cmds = (plan.get("run") or {}).get("commands") or []
    for c in cmds:
        lines.append(f"  {c}")

    (out_root / "RUN_INSTRUCTIONS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default=None, help="artifacts/runs/run_*/ (default: LATEST)")
    ap.add_argument("--force", action="store_true", help="overwrite if generated folder exists")
    args = ap.parse_args()

    run_dir = Path(args.run_dir) if args.run_dir else Path((RUNS_DIR / "LATEST").read_text(encoding="utf-8").strip())
    plan_path = run_dir / "plan.json"
    if not plan_path.exists():
        raise SystemExit(f"plan.json not found in {run_dir}")

    plan_txt = plan_path.read_text(encoding="utf-8")
    plan = json.loads(plan_txt)

    name = plan.get("name")
    if not isinstance(name, str) or not name:
        raise SystemExit("[fail] plan.name missing/invalid")

    out_root = GENERATED / name

    plan_sha = sha256_text(plan_txt)

    # If folder exists:
    if out_root.exists():
        sha_path = out_root / ".generated_from_plan_sha256"
        existing_sha = sha_path.read_text(encoding="utf-8", errors="ignore").strip() if sha_path.exists() else ""

        # Idempotent: same plan hash => OK (do not fail)
        if existing_sha and same_hash(existing_sha, plan_sha) and not args.force:
            print(f"[ok] already generated (same plan hash): {out_root}")
            print(f"[hint] see: {out_root}/RUN_INSTRUCTIONS.txt")
            return 0

        if args.force:
            shutil.rmtree(out_root)
        else:
            # auto-rename on hash mismatch (or missing sha metadata)
            base = name.split("__", 1)[0]
            cand = GENERATED / alt_name(base, plan_sha)

            # if candidate exists and matches => OK
            if cand.exists():
                sha2p = cand / ".generated_from_plan_sha256"
                sha2 = sha2p.read_text(encoding="utf-8", errors="ignore").strip() if sha2p.exists() else ""
                if sha2 and sha2 == plan_sha:
                    print(f"[ok] already generated (same plan hash): {cand}")
                    print(f"[hint] see: {cand}/RUN_INSTRUCTIONS.txt")
                    return 0
                # collision: add a short random suffix
                cand = GENERATED / f"{alt_name(base, plan_sha)}__{uuid.uuid4().hex[:6]}"

            out_root = cand
            name = out_root.name
            print(f"[warn] generated folder exists with different plan; using: {out_root}")

    out_root.mkdir(parents=True, exist_ok=True)

    # write plan files
    files = plan.get("files") or []
    if not isinstance(files, list) or len(files) < 2:
        raise SystemExit("[fail] plan.files missing/invalid")

    for f in files:
        if not isinstance(f, dict) or "path" not in f or "content" not in f:
            raise SystemExit("[fail] invalid file entry in plan.files")
        rel = f["path"]
        content = f["content"]
        if not isinstance(rel, str) or not isinstance(content, str):
            raise SystemExit("[fail] file.path/content must be strings")
        target = safe_join(out_root, rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content if content.endswith("\n") else (content + "\n"), encoding="utf-8")

    # write instructions + metadata
    write_run_instructions(out_root, name, plan, run_dir, plan_sha)

    meta = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "source_run": str(run_dir),
        "plan_sha256": plan_sha,
        "name": name,
        "schema_version": plan.get("schema_version", None),
    }
    (out_root / ".generated_from_run").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

    # minimal README (optional, keep existing if provided by plan)
    readme = out_root / "README.md"
    if not readme.exists():
        readme.write_text(f"# {name}\n\nGenerated by ai-platform scaffold.\n", encoding="utf-8")

    print(f"[ok] generated at: {out_root}")
    print("[run] recommended:")
    print(f"  cd {out_root} && python3 -m {name}.cli --help" if (out_root / "src" / name / "cli.py").exists()
          else f"  cd {out_root} && cat RUN_INSTRUCTIONS.txt")

    cmds = (plan.get("run") or {}).get("commands") or []
    if cmds:
        print("[run] commands:")
        for c in cmds:
            print(f"  {c}")

if __name__ == "__main__":
    main()
