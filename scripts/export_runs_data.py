#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
RUNS_ROOT = ROOT / "artifacts" / "runs"

META_CANDIDATES = ["meta.run.json", "meta.json"]
VERIFY_SUMMARY_CANDIDATES = ["verify_summary.json"]
VERIFY_LOG_CANDIDATES = ["verify.log"]
PLAN_CANDIDATES = ["plan.web.json", "plan.json"]
STEP_META_CANDIDATES = ["step_meta_latest.log", "step_meta.log"]

def _read_json(p: Path) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

def _read_text(p: Path, limit_bytes: int = 200_000) -> Optional[str]:
    try:
        s = p.read_text(encoding="utf-8", errors="replace")
        b = s.encode("utf-8", errors="replace")
        if len(b) > limit_bytes:
            return s[: max(10_000, int(limit_bytes / 4))] + "\n\n[truncated]\n"
        return s
    except Exception:
        return None

def _mtime_iso(p: Path) -> str:
    dt = datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")

def _norm_status(x: Any) -> str:
    s = (str(x) if x is not None else "").strip().lower()
    if s in ("ok", "pass", "passed", "success", "succeeded", "true"):
        return "ok"
    if s in ("fail", "failed", "error", "false"):
        return "fail"
    if s in ("unknown", ""):
        return "unknown"
    return s

def _pick_first_existing(rd: Path, names: List[str]) -> Optional[Path]:
    for n in names:
        p = rd / n
        if p.exists() and p.is_file():
            return p
    return None

def _load_meta(rd: Path) -> Tuple[Dict[str, Any], Optional[Path]]:
    mp = _pick_first_existing(rd, META_CANDIDATES)
    if mp:
        j = _read_json(mp)
        if isinstance(j, dict):
            return j, mp
    return {}, None

def _infer_kind(run_id: str, meta: Dict[str, Any]) -> str:
    k = (meta.get("kind") or "").strip()
    if k:
        return k
    if run_id.startswith("run_web_smoke_"):
        return "web_smoke"
    if run_id.startswith("run_generated_smoke_"):
        return "generated_smoke"
    return "unknown"

def _start_ts(meta: Dict[str, Any], rd: Path) -> str:
    for k in ("ts_utc", "start", "started_at"):
        v = meta.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return _mtime_iso(rd)

def _build_verify(rd: Path, meta: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], Optional[Path]]:
    vp = _pick_first_existing(rd, VERIFY_SUMMARY_CANDIDATES)
    if not vp:
        return None, None
    j = _read_json(vp)
    if not isinstance(j, dict):
        return None, vp

    ok = j.get("ok")
    if isinstance(ok, str):
        ok = ok.strip().lower() in ("1", "true", "yes", "ok", "pass", "passed")
    if ok is None:
        ok = _norm_status(j.get("status")) == "ok"

    out = dict(j)
    out["ok"] = bool(ok)

    out.setdefault("plan_hash", meta.get("plan_hash"))
    if meta.get("gen_dir"):
        try:
            out.setdefault("gen_dir", str(Path(meta["gen_dir"]).relative_to(ROOT)))
        except Exception:
            out.setdefault("gen_dir", str(meta["gen_dir"]))
    out.setdefault("ts", meta.get("ts_utc") or _mtime_iso(rd))
    return out, vp

def _build_verify_log(rd: Path) -> Tuple[Optional[str], Optional[Path]]:
    lp = _pick_first_existing(rd, VERIFY_LOG_CANDIDATES)
    if lp:
        return _read_text(lp), lp
    return None, None

def _build_plan(rd: Path) -> Tuple[Optional[Dict[str, Any]], Optional[Path]]:
    pp = _pick_first_existing(rd, PLAN_CANDIDATES)
    if pp:
        j = _read_json(pp)
        if isinstance(j, dict):
            return j, pp
    return None, None

def _parse_step_meta(rd: Path) -> Dict[str, Any]:
    sp = _pick_first_existing(rd, STEP_META_CANDIDATES)
    if not sp:
        return {}
    txt = _read_text(sp, limit_bytes=50_000)
    if not txt:
        return {}

    s = txt.strip()
    if s.startswith("{") and s.endswith("}"):
        j = _read_json(sp)
        return j if isinstance(j, dict) else {}

    out: Dict[str, Any] = {}
    for line in s.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, v = line.split("=", 1)
        elif ":" in line:
            k, v = line.split(":", 1)
        else:
            continue
        k = k.strip()
        v = v.strip()
        if not k:
            continue
        # simple numeric cast
        try:
            if "." in v:
                out[k] = float(v)
            else:
                out[k] = int(v)
        except Exception:
            out[k] = v
    return out

def _status(meta: Dict[str, Any], verify: Optional[Dict[str, Any]]) -> str:
    s = _norm_status(meta.get("status"))
    if s in ("ok", "fail"):
        return s
    if verify and isinstance(verify.get("ok"), bool):
        return "ok" if verify["ok"] else "fail"
    return "unknown"

def _read_runs_summary_csv() -> Optional[List[Dict[str, str]]]:
    p = RUNS_ROOT / "runs_summary_v3.csv"
    if not p.exists():
        return None
    try:
        return list(csv.DictReader(p.open("r", encoding="utf-8")))
    except Exception:
        return None

def _pick_gen_dir(arg_gen: Optional[str]) -> Path:
    if arg_gen:
        return Path(arg_gen).expanduser().resolve()
    out = subprocess.check_output(
        ["bash", "-lc", "bash scripts/pick_latest_websmoke_dir.sh"],
        cwd=str(ROOT),
        text=True
    ).strip()
    return Path(out).expanduser().resolve()

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen-dir", default=None)
    ap.add_argument("--max-items", type=int, default=200)
    args = ap.parse_args()

    gen_dir = _pick_gen_dir(args.gen_dir)
    out_dir = gen_dir / "public" / "runs_data"
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = _read_runs_summary_csv()
    run_dirs: List[Path] = []

    if rows:
        def _key(r: Dict[str, str]) -> str:
            return (r.get("start") or r.get("ts_utc") or "")
        rows_sorted = sorted(rows, key=_key, reverse=True)
        for r in rows_sorted:
            rd = r.get("run_dir") or ""
            if not rd:
                continue
            p = Path(rd)
            if p.exists() and p.is_dir():
                run_dirs.append(p)
            if len(run_dirs) >= args.max_items:
                break
    else:
        candidates = [p for p in RUNS_ROOT.glob("run_*") if p.is_dir()]
        candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        run_dirs = candidates[: args.max_items]

    index_items: List[Dict[str, Any]] = []
    exported = 0

    for rd in run_dirs:
        run_id = rd.name
        meta, meta_file = _load_meta(rd)
        kind = _infer_kind(run_id, meta)
        step_meta = _parse_step_meta(rd)
        verify, verify_file = _build_verify(rd, meta)
        verify_log, verify_log_file = _build_verify_log(rd)
        plan, plan_file = _build_plan(rd)

        start = _start_ts(meta, rd)
        status = _status(meta, verify)

        # summary fields (try meta -> step_meta -> fallback)
        duration_s = meta.get("duration_s", step_meta.get("duration_s"))
        last_step = meta.get("last_step", step_meta.get("last_step"))
        mode = meta.get("mode", step_meta.get("mode"))
        model = meta.get("model", step_meta.get("model"))

        summary = {
            "kind": kind,
            "status": status,
            "start": start,
            "duration_s": duration_s,
            "last_step": last_step,
            "mode": mode,
            "model": model,
            "run_dir": str(rd),
        }

        index_obj = {
            "run_id": run_id,
            "run_dir": str(rd),
            "kind": kind,
            "status": status,
            "start": start,
        }

        detail = {
            "run_id": run_id,

            # ✅ 兼容：Summary 可能读顶层字段
            **summary,

            # ✅ 兼容：Summary 也可能读 summary.*
            "summary": summary,

            # ✅ 兼容：Runs list / 旧页面读 index.*
            "index": index_obj,

            "meta": meta,
            "step_meta": step_meta if step_meta else None,

            "verify": verify,
            "verify_log": verify_log,

            "plan": plan,

            "source": {
                "meta_file": str(meta_file) if meta_file else None,
                "verify_file": str(verify_file) if verify_file else None,
                "verify_log_file": str(verify_log_file) if verify_log_file else None,
                "plan_file": str(plan_file) if plan_file else None,
            },
        }

        (out_dir / f"{run_id}.json").write_text(
            json.dumps(detail, ensure_ascii=False, indent=2),
            encoding="utf-8"
        )
        exported += 1

        index_items.append(index_obj)

    index_items.sort(key=lambda it: str(it.get("start") or ""), reverse=True)

    (out_dir / "index.json").write_text(
        json.dumps(index_items, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    print(f"[ok] wrote {out_dir/'index.json'} items={len(index_items)}")
    print(f"[ok] exported details -> {out_dir} exported={exported}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
