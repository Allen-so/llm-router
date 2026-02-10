#!/usr/bin/env python3
import argparse, json, os, time, uuid
from pathlib import Path
from urllib import request as urlreq
from urllib.error import HTTPError, URLError

ROOT = Path("/home/suxiaocong/ai-platform")
RULES_PATH = ROOT / "infra" / "router_rules.json"
RUNS_DIR = ROOT / "artifacts" / "runs"

DEFAULT_MODE_TO_MODEL = {
    "daily": "default-chat",
    "coding": "default-chat",
    "long": "long-chat",
    "hard": "best-effort-chat",
    "premium": "premium-chat",
}

def load_rules():
    if RULES_PATH.exists():
        try:
            data = json.loads(RULES_PATH.read_text(encoding="utf-8"))
            long_chars = int(data.get("length_thresholds", {}).get("long_chars", 1200))
            modes = data.get("modes", {})
            mode_to_model = {}
            for k, v in modes.items():
                if isinstance(v, dict) and "model" in v:
                    mode_to_model[k] = v["model"]
            return long_chars, {**DEFAULT_MODE_TO_MODEL, **mode_to_model}
        except Exception:
            pass
    return 1200, DEFAULT_MODE_TO_MODEL.copy()

def pick_mode_and_model(mode: str, text: str, long_chars: int, mode_to_model: dict, model_override: str | None):
    mode = (mode or "auto").strip()
    if mode == "auto":
        chosen_mode = "long" if len(text) >= long_chars else "daily"
    else:
        chosen_mode = mode

    model = model_override or mode_to_model.get(chosen_mode) or DEFAULT_MODE_TO_MODEL.get(chosen_mode) or "default-chat"
    return chosen_mode, model

def http_post_json(url: str, headers: dict, payload: dict, timeout: int = 120):
    body = json.dumps(payload).encode("utf-8")
    req = urlreq.Request(url, data=body, headers={**headers, "Content-Type": "application/json"}, method="POST")
    try:
        with urlreq.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw)
    except HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else ""
        try:
            return e.code, json.loads(raw) if raw else {"error": raw or str(e)}
        except Exception:
            return e.code, {"error": raw or str(e)}
    except URLError as e:
        return 0, {"error": f"URLError: {e}"}
    except Exception as e:
        return 0, {"error": str(e)}

def main():
    ap = argparse.ArgumentParser(description="router-demo: call LiteLLM router and save artifacts")
    ap.add_argument("--text", required=True, help="User input text")
    ap.add_argument("--mode", default="auto", help="auto|daily|coding|long|hard|premium")
    ap.add_argument("--model", default=None, help="Override model name (e.g. default-chat)")
    ap.add_argument("--api-base", default="http://127.0.0.1:4000", help="Router base URL")
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--max-tokens", type=int, default=800)
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()

    long_chars, mode_to_model = load_rules()
    chosen_mode, chosen_model = pick_mode_and_model(args.mode, args.text, long_chars, mode_to_model, args.model)

    master_key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if not master_key:
        # Try .env (best-effort, do not fully parse shell syntax)
        env_path = ROOT / ".env"
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
                if line.startswith("LITELLM_MASTER_KEY="):
                    master_key = line.split("=", 1)[1].strip().strip('"').strip("'")
                    break

    headers = {}
    if master_key:
        headers["Authorization"] = f"Bearer {master_key}"

    run_id = time.strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:8]
    run_dir = RUNS_DIR / f"run_{run_id}"
    run_dir.mkdir(parents=True, exist_ok=True)

    payload = {
        "model": chosen_model,
        "messages": [{"role": "user", "content": args.text}],
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
    }

    meta = {
        "run_id": run_id,
        "chosen_mode": chosen_mode,
        "chosen_model": chosen_model,
        "text_chars": len(args.text),
        "api_base": args.api_base,
        "ts_start": time.time(),
    }

    (run_dir / "input.txt").write_text(args.text, encoding="utf-8")
    (run_dir / "request.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    (run_dir / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")

    status, resp = http_post_json(
        url=f"{args.api_base.rstrip('/')}/v1/chat/completions",
        headers=headers,
        payload=payload,
        timeout=args.timeout,
    )

    meta["http_status"] = status
    meta["ts_end"] = time.time()
    meta["duration_s"] = round(meta["ts_end"] - meta["ts_start"], 3)

    (run_dir / "response.json").write_text(json.dumps(resp, indent=2, ensure_ascii=False), encoding="utf-8")
    (run_dir / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")

    # Print assistant content (best-effort)
    content = ""
    try:
        content = resp["choices"][0]["message"]["content"]
    except Exception:
        pass

    print(content if content else f"[no content] HTTP={status}")
    print(f"\n[artifacts] {run_dir}")

    # Update latest pointer file (portable)
    (RUNS_DIR / "LATEST").write_text(str(run_dir), encoding="utf-8")

if __name__ == "__main__":
    main()
