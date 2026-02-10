#!/usr/bin/env python3
import argparse, json, shutil, time
from pathlib import Path

ROOT = Path("/home/suxiaocong/ai-platform")
GENERATED = ROOT / "apps" / "generated"
RUNS_DIR = ROOT / "artifacts" / "runs"

def safe_join(base: Path, rel: str) -> Path:
    p = (base / rel).resolve()
    base_r = base.resolve()
    if p != base_r and not str(p).startswith(str(base_r) + '/'):
        raise ValueError(f'path escapes base: {rel}')
    return p

def write_run_instructions(out_root: Path, name: str, plan: dict, run_dir: Path):
    lines = []
    lines.append(f'Generated: {time.strftime("%Y-%m-%d %H:%M:%S")}')
    lines.append(f'Project: {name}')
    lines.append(f'Source run: {run_dir}')
    lines.append('')
    lines.append('Recommended (project-local venv):')
    lines.append(f'  cd {out_root}')
    lines.append('  python3 -m venv .venv')
    lines.append('  source .venv/bin/activate')
    lines.append('  python -m pip install -U pip')
    lines.append('  pip install -e .')
    lines.append(f'  python -m {name}.cli --help')
    lines.append('')
    lines.append('Quick test (no venv, may not work if project expects install):')
    lines.append(f'  cd {out_root}')
    lines.append(f'  python3 -m {name}.cli --help')
    lines.append('')
    lines.append('Plan run.commands (model-provided):')
    for cmd in plan.get('run', {}).get('commands', []):
        lines.append(f'  {cmd}')
    (out_root / 'RUN_INSTRUCTIONS.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run-dir', default=None, help='artifacts/runs/run_*/ (default: LATEST)')
    ap.add_argument('--force', action='store_true', help='overwrite existing generated folder')
    args = ap.parse_args()

    run_dir = Path(args.run_dir) if args.run_dir else Path((RUNS_DIR / 'LATEST').read_text(encoding='utf-8').strip())
    plan_path = run_dir / 'plan.json'
    if not plan_path.exists():
        raise SystemExit(f'plan.json not found in {run_dir}')

    plan = json.loads(plan_path.read_text(encoding='utf-8'))
    name = plan['name']
    out_root = GENERATED / name
    out_root.parent.mkdir(parents=True, exist_ok=True)

    if out_root.exists():
        if not args.force:
            raise SystemExit(f'generated folder already exists: {out_root} (use --force to overwrite)')
        shutil.rmtree(out_root)

    out_root.mkdir(parents=True, exist_ok=True)

    for f in plan['files']:
        rel = f['path']
        dest = safe_join(out_root, rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(f['content'], encoding='utf-8')

    (out_root / '.generated_from_run').write_text(str(run_dir) + '\n', encoding='utf-8')
    write_run_instructions(out_root, name, plan, run_dir)

    print(f'[ok] generated at: {out_root}')
    print('[run] recommended:')
    print(f'  cd {out_root} && python3 -m {name}.cli --help')
    print('[run] commands:')
    for cmd in plan.get('run', {}).get('commands', []):
        print(f'  {cmd}')

if __name__ == '__main__':
    main()
