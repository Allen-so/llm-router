#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple, List

ROOT = Path(__file__).resolve().parent.parent
RUNS_ROOT = ROOT / "artifacts" / "runs"

def _read_text(p: Path, max_bytes: int = 800_000) -> Optional[str]:
    if not p.exists() or not p.is_file():
        return None
    try:
        b = p.read_bytes()
        if len(b) > max_bytes:
            head = b[:max_bytes].decode("utf-8", errors="replace")
            return head + f"\n\n...[truncated {len(b)-max_bytes} bytes]"
        return b.decode("utf-8", errors="replace")
    except Exception:
        return None

def _read_json(p: Path) -> Optional[Dict[str, Any]]:
    txt = _read_text(p, max_bytes=2_000_000)
    if not txt:
        return None
    try:
        return json.loads(txt)
    except Exception:
        return None

def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

def _parse_ts_to_iso(v: Any) -> Optional[str]:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        try:
            return datetime.fromtimestamp(float(v), tz=timezone.utc).isoformat().replace("+00:00", "Z")
        except Exception:
            return None
    if isinstance(v, str):
        s = v.strip()
        if not s:
            return None
        # normalize +0800 -> +08:00
        m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\+\d{4})$", s)
        if m:
            base, off = m.group(1), m.group(2)
            s = f"{base}{off[:3]}:{off[3:]}"
        return s
    return None

def _infer_kind(meta: Optional[Dict[str, Any]], run_id: str) -> str:
    if meta:
        k = (meta.get("kind") or "").strip()
        if k:
            return k
    if run_id.startswith("run_web_smoke_"):
        return "web_smoke"
    if run_id.startswith("run_generated_smoke_"):
        return "generated_smoke"
    return "unknown"

def _load_verify(run_dir: Path) -> Tuple[Optional[Dict[str, Any]], Optional[Path]]:
    # canonical
    p = run_dir / "verify_summary.json"
    v = _read_json(p)
    if v is not None:
        return v, p
    # fallbacks (older)
    for name in ("verify.web.json","verify_web.json","verify.json"):
        p = run_dir / name
        v = _read_json(p)
        if v is not None:
            return v, p
    return None, None

def _infer_status(meta: Optional[Dict[str, Any]], verify: Optional[Dict[str, Any]]) -> str:
    if verify is not None:
        ok = verify.get("ok", None)
        if ok is True:
            return "ok"
        if ok is False:
            return "fail"
    if meta is not None:
        ms = (meta.get("status") or "").strip().lower()
        if ms in ("ok","pass","passed","success"):
            return "ok"
        if ms in ("fail","failed","error"):
            return "fail"
        if ms and ms != "unknown":
            return ms
    return "unknown"

def _extract_start_iso(meta: Optional[Dict[str, Any]], run_dir: Path, verify: Optional[Dict[str, Any]]) -> str:
    if meta:
        for k in ("ts_utc","start","ts"):
            s = _parse_ts_to_iso(meta.get(k))
            if s:
                return s
    if verify:
        s = _parse_ts_to_iso(verify.get("ts"))
        if s:
            return s
    try:
        return datetime.fromtimestamp(run_dir.stat().st_mtime, tz=timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
        return _iso_now()

def _pick_gen_dir() -> Path:
    env = os.environ.get("GEN_DIR","").strip()
    if env:
        p = Path(env).expanduser()
        return p if p.is_absolute() else (ROOT / p)

    picker = ROOT / "scripts" / "pick_latest_websmoke_dir.sh"
    if picker.exists():
        try:
            out = subprocess.check_output(["bash","-lc", str(picker)], cwd=str(ROOT), text=True).strip()
            if out:
                p = Path(out)
                return p if p.is_absolute() else (ROOT / p)
        except Exception:
            pass

    base = ROOT / "apps" / "generated"
    cands = sorted(base.glob("websmoke__*"), key=lambda d: d.stat().st_mtime, reverse=True)
    if not cands:
        raise SystemExit("[err] cannot find generated websmoke dir (set GEN_DIR=...)")
    return cands[0]

def _list_run_dirs() -> List[Path]:
    if not RUNS_ROOT.exists():
        return []
    ds = [p for p in RUNS_ROOT.iterdir() if p.is_dir() and p.name.startswith("run_")]
    ds.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return ds

def _load_verify_log(run_dir: Path) -> Optional[str]:
    # prefer verify.log, fallback to verify_summary.json text
    txt = _read_text(run_dir / "verify.log")
    if txt:
        return txt
    return _read_text(run_dir / "verify_summary.json", max_bytes=200_000)

def main() -> int:
    gen_dir = _pick_gen_dir()
    out_dir = gen_dir / "public" / "runs_data"
    out_dir.mkdir(parents=True, exist_ok=True)

    limit = int(os.environ.get("RUNS_EXPORT_LIMIT","80"))
    run_dirs = _list_run_dirs()[:limit]

    items: List[Dict[str, Any]] = []
    n_detail = 0

    for rd in run_dirs:
        run_id = rd.name
        meta = _read_json(rd / "meta.run.json") or _read_json(rd / "meta.json") or {}
        verify, verify_file = _load_verify(rd)
        verify = verify or {}
        status = _infer_status(meta, verify)
        kind = _infer_kind(meta, run_id)
        start = _extract_start_iso(meta, rd, verify)

        # ---- INDEX (for /runs list) ----
        idx = {
            "run_id": run_id,
            "run_dir": str(rd),
            "kind": kind,
            "status": status,
            "start": start,
        }
        items.append(idx)

        # ---- SUMMARY (for /runs/[id] Summary table) ----
        # keep keys aligned with UI: kind/status/start/duration_s/last_step/mode/model/run_dir
        summary = {
            "kind": kind,
            "status": status,
            "start": start,
            "duration_s": meta.get("duration_s", None),
            "last_step": meta.get("last_step", None),
            "mode": meta.get("mode", None),
            "model": meta.get("model", None),
            "run_dir": str(rd),
        }

        detail = {
            "run_id": run_id,
            "summary": summary,     # <-- 关键：补回 summary，页面就不会再全是 "-"
            "index": idx,
            "meta": meta,
            "verify": verify,
            "verify_log": _load_verify_log(rd),
            "source": {
                "run_dir": str(rd),
                "meta_file": str(rd / "meta.run.json") if (rd / "meta.run.json").exists() else (str(rd / "meta.json") if (rd / "meta.json").exists() else None),
                "verify_file": str(verify_file) if verify_file else None,
                "verify_log_file": str(rd / "verify.log") if (rd / "verify.log").exists() else None,
                "exported_at": _iso_now(),
                "gen_dir": str(gen_dir),
            },
        }

        (out_dir / f"{run_id}.json").write_text(json.dumps(detail, ensure_ascii=False, indent=2), encoding="utf-8")
        n_detail += 1

    # newest first
    items.sort(key=lambda x: str(x.get("start") or ""), reverse=True)
    (out_dir / "index.json").write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"[ok] wrote {out_dir/'index.json'} items={len(items)}")
    print(f"[ok] exported details -> {out_dir} exported={n_detail}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
