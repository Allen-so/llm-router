#!/usr/bin/env python3
import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


def _load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _merge(a: Dict[str, Any], b: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(a)
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def _text_len(text: str) -> int:
    return len(text or "")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True, help="plan | plan_web | other")
    ap.add_argument("--text", default="", help="inline text")
    ap.add_argument("--text-file", default="", help="path to text file")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parents[1]
    policy_path = repo / "infra" / "policy.json"
    if not policy_path.exists():
        print(json.dumps({"error": "missing infra/policy.json"}))
        return 2

    policy = _load_json(policy_path)

    defaults = policy.get("defaults", {})
    tasks = policy.get("tasks", {})
    task_cfg = tasks.get(args.task, {})

    text = args.text
    src = "text"
    if args.text_file:
        tf = Path(args.text_file)
        text = tf.read_text(encoding="utf-8") if tf.exists() else ""
        src = "text_file"

    decision: Dict[str, Any] = {}
    decision = _merge(decision, defaults)
    decision = _merge(decision, task_cfg)

    # compatibility defaults
    decision.setdefault("model", "default-chat")
    decision.setdefault("timeout_s", 120)
    decision.setdefault("json_only", False)
    decision.setdefault("fallback_models", [])
    decision.setdefault("max_total_attempts", 1)
    decision.setdefault("retry_on_http", [429, 500, 502, 503, 504])
    decision.setdefault("retry_on_empty", True)

    reasons: List[str] = []
    lt = policy.get("length_thresholds", {}) or {}
    long_chars = int(lt.get("long_chars", 1200))
    n = _text_len(text)

    if n >= long_chars and decision.get("model") == "default-chat":
        decision["model"] = "long-chat"
        reasons.append(f"text_len_gte_{long_chars}_use_long_chat")

    # normalize
    if not isinstance(decision.get("fallback_models"), list):
        decision["fallback_models"] = []
    if not isinstance(decision.get("retry_on_http"), list):
        decision["retry_on_http"] = [429, 500, 502, 503, 504]
    try:
        decision["max_total_attempts"] = int(decision.get("max_total_attempts", 1))
    except Exception:
        decision["max_total_attempts"] = 1

    out = {
        "policy_version": policy.get("version", 0),
        "task": args.task,
        "model": decision["model"],
        "timeout_s": decision["timeout_s"],
        "json_only": bool(decision["json_only"]),
        "fallback_models": decision["fallback_models"],
        "max_total_attempts": decision["max_total_attempts"],
        "max_attempts": decision["max_total_attempts"],
        "retry_on_http": decision["retry_on_http"],
        "retry_on_empty": bool(decision["retry_on_empty"]),
        "input": {
            "source": src,
            "len_chars": n,
            "text_file": args.text_file or "",
        },
        "reasons": reasons,
        "decided_at": int(time.time()),
    }

    sys.stdout.write(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
