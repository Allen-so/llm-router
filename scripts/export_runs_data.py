#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parent.parent
RUNS_ROOT = ROOT / "artifacts" / "runs"

KEEP = int(os.environ.get("KEEP", "3"))

# Explicit candidates (kept for backward compat)
VERIFY_CANDIDATES = [
    "verify_payload.json",
    "verify.web.json",
    "verify_web.json",
    "verify_generated_web.json",
    "verify.generated_web.json",
    "verify.json",
    "verify_payload.json",
]

LOG_SUFFIX = {".log", ".txt", ".out", ".err"}

OK_PATTERNS = [
    r"\[ok\]\s+web build passed",
    r"\bCompiled successfully\b",
    r"\bReady in\b",
]
FAIL_PATTERNS = [
    r"\bFailed to compile\b",
    r"\bBuild failed\b",
    r"\bnpm ERR!\b",
    r"\bTraceback\b",
    r"\bERROR\b",
]

def read_text(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""

def read_json(p: Path) -> Optional[dict[str, Any]]:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

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

def pick_latest_websmoke_dir() -> Path:
    # Prefer existing bash helper (your repo already has it)
    try:
        out = subprocess.check_output(
            ["bash", "-lc", "bash scripts/pick_latest_websmoke_dir.sh"],
            cwd=str(ROOT),
            text=True,
        ).strip()
        if not out:
            raise RuntimeError("empty gen dir")
        p = Path(out)
        return p if p.is_absolute() else (ROOT / p)
    except Exception:
        # Fallback: apps/generated/websmoke__*
        base = ROOT / "apps" / "generated"
        cands = sorted(base.glob("websmoke__*"), key=lambda x: x.stat().st_mtime, reverse=True)
        if not cands:
            raise SystemExit("[fail] no apps/generated/websmoke__* found")
        return cands[0]

def find_verify_json(run_dir: Path) -> tuple[Optional[dict[str, Any]], Optional[str]]:
    # 1) explicit names
    for name in VERIFY_CANDIDATES:
        p = run_dir / name
        if p.exists() and p.is_file():
            j = read_json(p)
            if isinstance(j, dict):
                return j, p.name

    # 2) any *verify*.json (newest wins)
    cands = []
    for p in run_dir.glob("*.json"):
        n = p.name.lower()
        if "verify" in n:
            cands.append(p)
    cands = sorted(cands, key=lambda x: x.stat().st_mtime, reverse=True)
    for p in cands:
        j = read_json(p)
        if isinstance(j, dict):
            return j, p.name

    return None, None

def infer_ok_from_logs(run_dir: Path) -> tuple[Optional[bool], list[str]]:
    # scan last ~400 lines across recent log-ish files
    files = []
    for p in run_dir.rglob("*"):
        if p.is_file() and p.suffix.lower() in LOG_SUFFIX:
            files.append(p)
    files = sorted(files, key=lambda x: x.stat().st_mtime, reverse=True)[:12]

    text = ""
    for p in files:
        t = read_text(p)
        lines = t.splitlines()[-400:]
        if lines:
            text += "\n".join(lines) + "\n"

    if not text.strip():
        return None, []

    evidence: list[str] = []

    # Fail has priority if clearly present AND no ok marker
    ok_hit = any(re.search(pat, text, re.I) for pat in OK_PATTERNS)
    fail_hit = any(re.search(pat, text, re.I) for pat in FAIL_PATTERNS)

    # collect evidence lines
    for pat in OK_PATTERNS + FAIL_PATTERNS:
        m = re.search(pat, text, re.I)
        if m:
            # grab the matched line
            for line in text.splitlines():
                if re.search(pat, line, re.I):
                    evidence.append(line.strip())
                    break
        if len(evidence) >= 6:
            break

    if ok_hit and not fail_hit:
        return True, evidence
    if fail_hit and not ok_hit:
        return False, evidence
    if ok_hit and fail_hit:
        # ambiguous: still treat as fail unless we see explicit web build passed
        if re.search(r"\[ok\]\s+web build passed", text, re.I):
            return True, evidence
        return False, evidence

    return None, evidence

def infer_status(meta: dict[str, Any], idx: dict[str, Any], verify_payload: Optional[dict[str, Any]], ok_from_logs: Optional[bool]) -> str:
    for raw in (meta.get("status"), idx.get("status")):
        if isinstance(raw, str) and raw.strip():
            s = raw.strip().lower()
            if s and s != "unknown":
                return s

    okv = None
    if isinstance(verify_payload, dict):
        okv = truthy_ok(verify_payload.get("ok"))
    if okv is True:
        return "ok"
    if okv is False:
        return "fail"

    if ok_from_logs is True:
        return "ok"
    if ok_from_logs is False:
        return "fail"

    return "unknown"

def write_json(p: Path, obj: Any) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")

def main() -> int:
    gen_dir = pick_latest_websmoke_dir()
    out_dir = gen_dir / "public" / "runs_data"
    out_dir.mkdir(parents=True, exist_ok=True)

    run_dirs = [p for p in RUNS_ROOT.glob("run_*") if p.is_dir()]
    run_dirs = sorted(run_dirs, key=lambda x: x.stat().st_mtime, reverse=True)

    # keep last KEEP runs
    run_dirs = run_dirs[:KEEP]

    index_items: list[dict[str, Any]] = []

    for rd in run_dirs:
        run_id = rd.name

        meta = read_json(rd / "meta.run.json") or {}
        idx = {
            "run_id": run_id,
            "run_dir": str(rd),
            "kind": meta.get("kind") or "unknown",
            "status": meta.get("status") or "unknown",
            "start": meta.get("ts") or meta.get("ts_utc") or meta.get("start") or "",
        }

        verify_payload, verify_src = find_verify_json(rd)
        ok_from_logs, evidence = infer_ok_from_logs(rd)

        status = infer_status(meta, idx, verify_payload, ok_from_logs)
        meta["status"] = status
        idx["status"] = status

        # Build a verify_payload if missing but logs can infer
        if verify_payload is None and ok_from_logs is not None:
            verify_payload = {
                "ok": bool(ok_from_logs),
                "ts": meta.get("ts") or meta.get("ts_utc") or "",
                "source": f"log_infer:{rd.name}",
                "evidence": evidence[:6],
            }
        elif isinstance(verify_payload, dict):
            # normalize + keep provenance
            verify_payload.setdefault("source", verify_src or "verify_json")

        detail = {
            "run_id": run_id,
            "index": idx,
            "meta": meta,
            "verify_payload": verify_payload,
            # backward compat for older pages/tools
            "verify": verify_payload,
        }

        write_json(out_dir / f"{run_id}.json", detail)

        index_items.append({
            "run_id": run_id,
            "run_dir": str(rd),
            "kind": idx.get("kind"),
            "status": status,
            "start": idx.get("start") or "",
        })

    write_json(out_dir / "index.json", index_items)

    print(f"[ok] wrote {out_dir/'index.json'} items={len(index_items)}")
    print(f"[ok] exported details -> {out_dir} exported={len(index_items)}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
