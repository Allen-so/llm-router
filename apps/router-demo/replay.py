#!/usr/bin/env python3
import argparse, json, os, time
from pathlib import Path
from urllib import request as urlreq
from urllib.error import HTTPError, URLError

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
    ap = argparse.ArgumentParser(description="Replay a saved router-demo run folder (request.json)")
    ap.add_argument("--run-dir", required=True, help="artifacts/runs/run_*/")
    ap.add_argument("--api-base", default="http://127.0.0.1:4000")
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    req_path = run_dir / "request.json"
    if not req_path.exists():
        raise SystemExit(f"request.json not found in {run_dir}")

    payload = json.loads(req_path.read_text(encoding="utf-8"))

    master_key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    headers = {}
    if master_key:
        headers["Authorization"] = f"Bearer {master_key}"

    ts0 = time.time()
    status, resp = http_post_json(
        url=f"{args.api_base.rstrip('/')}/v1/chat/completions",
        headers=headers,
        payload=payload,
        timeout=args.timeout,
    )
    dt = round(time.time() - ts0, 3)

    out_path = run_dir / f"replay_response_{int(time.time())}.json"
    out_path.write_text(json.dumps(resp, indent=2, ensure_ascii=False), encoding="utf-8")

    content = ""
    try:
        content = resp["choices"][0]["message"]["content"]
    except Exception:
        pass

    print(content if content else f"[no content] HTTP={status}")
    print(f"\n[replay] HTTP={status} duration_s={dt}")
    print(f"[saved] {out_path}")

if __name__ == "__main__":
    main()
