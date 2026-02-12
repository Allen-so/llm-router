#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def _now_ms() -> int:
    return int(time.time() * 1000)


def _read_latest(repo: Path) -> str:
    p = repo / "artifacts" / "runs" / "LATEST"
    try:
        return p.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def _write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _event(repo: Path, run_dir: str, *, kind: str, step: str, phase: str,
           status: str = "ok", rc: int = 0, duration_ms: Optional[int] = None,
           message: str = "", error_class: str = "", ts_ms: Optional[int] = None) -> None:
    try:
        cmd = [sys.executable, str(repo / "scripts" / "event_append.py"),
               "--step", step, "--phase", phase, "--status", status, "--rc", str(rc),
               "--kind", kind]
        if run_dir:
            cmd += ["--run-dir", run_dir]
        if duration_ms is not None:
            cmd += ["--duration-ms", str(duration_ms)]
        if message:
            cmd += ["--message", message]
        if error_class:
            cmd += ["--error-class", error_class]
        if ts_ms is not None:
            cmd += ["--ts-ms", str(ts_ms)]
        subprocess.run(cmd, check=False, capture_output=True, text=True)
    except Exception:
        pass


def _classify(repo: Path, step: str, rc: int, log_file: str) -> Tuple[str, str]:
    try:
        out = subprocess.run(
            [sys.executable, str(repo / "scripts" / "error_classify.py"),
             "--step", step, "--rc", str(rc), "--log-file", log_file, "--plain"],
            capture_output=True, text=True, check=False
        )
        parts = (out.stdout or "").strip().split()
        if parts:
            cls = parts[0].strip()
            msg = parts[1].strip() if len(parts) > 1 else ""
            return cls, msg
    except Exception:
        pass
    return (f"rc_{rc}" if rc != 0 else "ok", "")


def _extract_http_status(text: str) -> Optional[int]:
    if not text:
        return None
    low = text.lower()
    for key in ("http", "status", "code"):
        idx = low.find(key)
        if idx >= 0:
            chunk = low[idx: idx + 160]
            for n in (408, 429, 500, 502, 503, 504):
                if str(n) in chunk:
                    return n
    # fallback: look anywhere but keep it conservative
    for n in (408, 429, 500, 502, 503, 504):
        if f" {n} " in f" {low} ":
            return n
    return None


def _budget_per_model(max_total: int, candidates: List[str]) -> List[int]:
    k = len(candidates)
    if k == 0:
        return []
    if max_total <= k:
        return [1] * max_total + [0] * (k - max_total)
    extra = max_total - k
    return [1 + extra] + [1] * (k - 1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="")
    ap.add_argument("--text-file", default="")
    ap.add_argument("--api-base", required=True)
    ap.add_argument("--model", default="default-chat")  # compatibility
    args = ap.parse_args()

    repo = Path(__file__).resolve().parents[2]
    policy_decide = repo / "scripts" / "policy_decide.py"
    plan_web = repo / "apps" / "router-demo" / "plan_web.py"

    t0 = _now_ms()
    before_latest = _read_latest(repo)

    decide_cmd = [sys.executable, str(policy_decide), "--task", "plan_web"]
    if args.text_file:
        decide_cmd += ["--text-file", args.text_file]
    else:
        decide_cmd += ["--text", args.text]

    dec = subprocess.run(decide_cmd, capture_output=True, text=True)
    if dec.returncode != 0:
        sys.stderr.write(dec.stderr)
        return dec.returncode

    decision: Dict[str, Any] = json.loads(dec.stdout)

    base_model = decision.get("model", args.model or "default-chat")
    fallbacks = decision.get("fallback_models", []) or []
    max_total_attempts = int(decision.get("max_total_attempts", decision.get("max_attempts", 1) or 1) or 1)

    retry_on_empty = bool(decision.get("retry_on_empty", False))
    retry_on_http = decision.get("retry_on_http", []) or []

    candidates: List[str] = [base_model] + [m for m in fallbacks if m and m != base_model]
    candidates = candidates[:3]
    per_model_budget = _budget_per_model(max_total_attempts, candidates)

    attempts: List[Dict[str, Any]] = []
    final_ok = False
    final_model = ""
    final_run_dir = ""

    total_used = 0

    for i, model in enumerate(candidates):
        cap = per_model_budget[i] if i < len(per_model_budget) else 0
        if cap <= 0:
            continue

        for _ in range(cap):
            if total_used >= max_total_attempts:
                break
            total_used += 1

            step_name = f"plan_web_attempt_{total_used:02d}"
            a0 = _now_ms()

            rd0 = _read_latest(repo)
            _event(repo, rd0, kind="plan_web", step=step_name, phase="start", ts_ms=a0)

            cmd = [sys.executable, str(plan_web), "--api-base", args.api_base, "--model", model]
            if args.text_file:
                cmd += ["--text-file", args.text_file]
            else:
                cmd += ["--text", args.text]

            p = subprocess.run(cmd, capture_output=True, text=True)
            a1 = _now_ms()

            run_dir = _read_latest(repo) or ""
            ok = (p.returncode == 0)

            # attempt log
            log_file = ""
            if run_dir:
                log_file = str(Path(run_dir) / f"attempt_{total_used:02d}.log")
                try:
                    Path(log_file).write_text((p.stdout or "") + "\n" + (p.stderr or ""), encoding="utf-8")
                except Exception:
                    log_file = ""

            combined = (p.stdout or "") + "\n" + (p.stderr or "")
            http_status = _extract_http_status(combined)

            # empty-like detection: rc ok but plan.web.json missing
            empty_like = False
            if ok and run_dir:
                if not (Path(run_dir) / "plan.web.json").exists():
                    empty_like = True

            if ok and not empty_like:
                attempts.append({
                    "attempt": total_used,
                    "model": model,
                    "ok": True,
                    "returncode": 0,
                    "duration_ms": a1 - a0,
                    "run_dir": run_dir,
                    "log_file": log_file,
                    "http_status": http_status,
                    "error_class": "",
                    "message": "",
                    "stdout_tail": (p.stdout or "")[-1500:],
                    "stderr_tail": (p.stderr or "")[-1500:],
                })
                _event(repo, run_dir, kind="plan_web", step=step_name, phase="end",
                       status="ok", rc=0, duration_ms=a1 - a0)

                final_ok = True
                final_model = model
                final_run_dir = run_dir
                break

            # failure
            error_class = ""
            message = ""

            if empty_like:
                error_class = "empty_output"
                message = "empty_output"
            else:
                cls, msg = _classify(repo, step_name, p.returncode, log_file or "")
                error_class = cls
                message = msg or "attempt_failed"
                if http_status is not None:
                    message = f"http_{http_status}"

            transient = False
            if http_status is not None and http_status in retry_on_http:
                transient = True
            if retry_on_empty and error_class == "empty_output":
                transient = True
            if error_class in ("timeout", "conn_refused", "dns", "rate_limit"):
                transient = True  # ok to keep as backup

            attempts.append({
                "attempt": total_used,
                "model": model,
                "ok": False,
                "returncode": p.returncode,
                "duration_ms": a1 - a0,
                "run_dir": run_dir,
                "log_file": log_file,
                "http_status": http_status,
                "error_class": error_class,
                "message": message,
                "stdout_tail": (p.stdout or "")[-1500:],
                "stderr_tail": (p.stderr or "")[-1500:],
            })
            _event(repo, run_dir, kind="plan_web", step=step_name, phase="end",
                   status="fail", rc=1 if empty_like else p.returncode,
                   duration_ms=a1 - a0, error_class=error_class, message=message)

            if not transient:
                break

        if final_ok:
            break

    after_latest = _read_latest(repo)
    t1 = _now_ms()

    trace = {
        "task": "plan_web",
        "decision": decision,
        "candidates": candidates,
        "per_model_budget": per_model_budget,
        "attempts": attempts,
        "final": {"ok": final_ok, "model": final_model, "run_dir": final_run_dir},
        "before_latest": before_latest,
        "after_latest": after_latest,
        "generated_at": int(time.time()),
    }

    _write_json(repo / "artifacts" / "tmp" / "policy.trace.latest.json", trace)

    target_run_dir = final_run_dir or after_latest
    if target_run_dir:
        rd = Path(target_run_dir)
        _write_json(rd / "policy.decision.json", decision)
        _write_json(rd / "policy.trace.json", trace)
        _event(repo, target_run_dir, kind="plan_web", step="plan_web", phase="start", ts_ms=t0)
        _event(repo, target_run_dir, kind="plan_web", step="plan_web", phase="end",
               status="ok" if final_ok else "fail",
               rc=0 if final_ok else 1,
               duration_ms=t1 - t0,
               error_class="" if final_ok else "all_attempts_failed")

    if not final_ok:
        sys.stderr.write("[policy] all attempts failed\n")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
