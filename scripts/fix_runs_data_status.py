#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Optional

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

def infer_status(doc: dict[str, Any]) -> str:
    meta = doc.get("meta") or {}
    idx  = doc.get("index") or {}
    for raw in (meta.get("status"), idx.get("status")):
        if isinstance(raw, str) and raw.strip():
            s = raw.strip().lower()
            if s != "unknown":
                return s

    v = doc.get("verify_payload") or doc.get("verify") or {}
    okv = truthy_ok(v.get("ok")) if isinstance(v, dict) else None
    if okv is True:
        return "ok"
    if okv is False:
        return "fail"
    return "unknown"

def load_json(p: Path) -> dict[str, Any]:
    return json.loads(p.read_text(encoding="utf-8"))

def save_json(p: Path, obj: Any) -> None:
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")

def main() -> int:
    if len(sys.argv) < 2:
        print("usage: fix_runs_data_status.py <gen_dir>")
        return 2

    gen_dir = Path(sys.argv[1]).resolve()
    runs_dir = gen_dir / "public" / "runs_data"
    if not runs_dir.exists():
        print(f"[fail] runs_data dir not found: {runs_dir}")
        return 3

    changed = 0
    # 1) patch each run_*.json
    for p in sorted(runs_dir.glob("run_*.json")):
        doc = load_json(p)
        meta = doc.setdefault("meta", {})
        idx  = doc.setdefault("index", {})

        s = infer_status(doc)
        # write back
        if meta.get("status") != s:
            meta["status"] = s
            changed += 1
        if idx.get("status") != s:
            idx["status"] = s
            changed += 1

        # make sure verify_payload exists for UI
        if "verify_payload" not in doc and "verify" in doc:
            doc["verify_payload"] = doc.get("verify")

        save_json(p, doc)

    # 2) patch index.json by reading each run file status
    idx_path = runs_dir / "index.json"
    if idx_path.exists():
        index_list = json.loads(idx_path.read_text(encoding="utf-8"))
        if isinstance(index_list, list):
            for item in index_list:
                if not isinstance(item, dict):
                    continue
                rid = item.get("run_id")
                if not rid:
                    continue
                rp = runs_dir / f"{rid}.json"
                if not rp.exists():
                    continue
                doc = load_json(rp)
                s = infer_status(doc)
                if item.get("status") != s:
                    item["status"] = s
                    changed += 1
            save_json(idx_path, index_list)

    print(f"[ok] runs_data status fixup done. changed={changed} dir={runs_dir}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
