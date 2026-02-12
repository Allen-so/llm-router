#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import time
from datetime import datetime
from pathlib import Path
from urllib import request, error


ROOT = Path(__file__).resolve().parents[2]
RUNS_DIR = ROOT / "artifacts" / "runs"
LATEST_FILE = RUNS_DIR / "LATEST"
DOTENV = ROOT / ".env"


def utc_stamp() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def load_dotenv_if_needed() -> None:
    if os.environ.get("LITELLM_MASTER_KEY", "").strip():
        return
    if not DOTENV.exists():
        return
    for line in DOTENV.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k and k not in os.environ:
            os.environ[k] = v


def canonical_hash(obj: dict) -> str:
    raw = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:12]


def extract_json(text: str) -> str:
    t = (text or "").strip()
    m = re.search(r"```json\s*(\{.*?\})\s*```", t, flags=re.S)
    if m:
        return m.group(1).strip()
    start = t.find("{")
    end = t.rfind("}")
    if start != -1 and end != -1 and end > start:
        return t[start : end + 1].strip()
    return t


def validate_plan(plan: dict) -> list[str]:
    errs: list[str] = []
    if not isinstance(plan, dict):
        return ["$: must be an object"]

    if plan.get("project_type") != "nextjs_site":
        errs.append("$.project_type: must be 'nextjs_site'")

    name = plan.get("name")
    if not isinstance(name, str) or not re.match(r"^[a-z][a-z0-9-]+$", name) or not (2 <= len(name) <= 40):
        errs.append("$.name: must match ^[a-z][a-z0-9-]+$ and length 2..40")

    app_title = plan.get("app_title")
    if not isinstance(app_title, str) or len(app_title.strip()) == 0 or len(app_title) > 80:
        errs.append("$.app_title: must be non-empty string length <= 80")

    tagline = plan.get("tagline")
    if tagline is not None and (not isinstance(tagline, str) or len(tagline) > 240):
        errs.append("$.tagline: must be string length <= 240")

    pages = plan.get("pages")
    if not isinstance(pages, list) or len(pages) == 0:
        errs.append("$.pages: must be a non-empty array")
        return errs
    if len(pages) > 12:
        errs.append("$.pages: maxItems is 12")

    for i, p in enumerate(pages):
        if not isinstance(p, dict):
            errs.append(f"$.pages[{i}]: must be object")
            continue
        route = p.get("route")
        title = p.get("title")
        if not isinstance(route, str) or not re.match(r"^/([a-z0-9-]+)?$", route):
            errs.append(f"$.pages[{i}].route: must match ^/([a-z0-9-]+)?$")
        if not isinstance(title, str) or len(title.strip()) == 0 or len(title) > 80:
            errs.append(f"$.pages[{i}].title: must be non-empty string length <= 80")

        sections = p.get("sections")
        if sections is not None:
            if not isinstance(sections, list) or any((not isinstance(x, str) or len(x) > 40) for x in sections):
                errs.append(f"$.pages[{i}].sections: must be array of short strings")

    return errs


def post_json(url: str, headers: dict[str, str], payload: dict, timeout_s: int) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw)
    except error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else ""
        raise SystemExit(f"HTTPError {e.code} url={url}\n{body}")
    except error.URLError as e:
        raise SystemExit(f"URLError url={url} err={e}")


def call_router(api_base: str, model: str, messages: list[dict], timeout_s: int) -> str:
    load_dotenv_if_needed()
    key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if not key:
        raise SystemExit("Missing env LITELLM_MASTER_KEY (add it to .env or export it)")

    url = api_base.rstrip("/") + "/v1/chat/completions"
    headers = {"Authorization": f"Bearer {key}"}
    payload = {"model": model, "messages": messages, "temperature": 0.2}
    resp = post_json(url, headers, payload, timeout_s)
    return resp["choices"][0]["message"]["content"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text-file", required=True)
    ap.add_argument("--api-base", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--max-attempts", type=int, default=6)
    ap.add_argument("--timeout-s", type=int, default=60)
    args = ap.parse_args()

    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    run_dir = RUNS_DIR / f"run_plan_web_{utc_stamp()}"
    run_dir.mkdir(parents=True, exist_ok=True)

    text = Path(args.text_file).read_text(encoding="utf-8").strip()
    (run_dir / "plan_web_input.txt").write_text(text, encoding="utf-8")

    system = (
        "Return ONLY valid JSON.\n"
        "No markdown. No code fences. No commentary.\n"
        "Schema:\n"
        "- project_type: 'nextjs_site'\n"
        "- name: lowercase, starts with letter, only [a-z0-9-]\n"
        "- app_title: short title\n"
        "- tagline: optional short string\n"
        "- pages: array (1..12). Each item needs route and title. sections optional.\n"
    )

    example = {
        "project_type": "nextjs_site",
        "name": "ai-landing",
        "app_title": "AI Landing",
        "tagline": "Minimal product site.",
        "pages": [
            {"route": "/", "title": "Home", "sections": ["Hero", "CTA"]},
            {"route": "/about", "title": "About", "sections": ["Bio", "Links"]}
        ]
    }

    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": "User request:\n" + text},
        {"role": "user", "content": "Output format example (follow keys exactly):\n" + json.dumps(example, ensure_ascii=False)},
    ]

    meta = {"kind": "plan_web", "api_base": args.api_base, "model": args.model, "attempts": []}

    for i in range(1, args.max_attempts + 1):
        content = call_router(args.api_base, args.model, messages, args.timeout_s)
        (run_dir / f"attempt_{i:02d}.txt").write_text(content, encoding="utf-8")

        raw = extract_json(content)
        try:
            plan = json.loads(raw)
        except Exception as e:
            meta["attempts"].append({"i": i, "ok": False, "error": f"json_parse: {e}"})
            messages.append({"role": "user", "content": "Invalid JSON. Return ONLY JSON."})
            continue

        errs = validate_plan(plan)
        if not errs:
            plan_hash = canonical_hash(plan)
            meta["attempts"].append({"i": i, "ok": True, "plan_hash": plan_hash})
            meta["plan_hash"] = plan_hash

            (run_dir / "plan.web.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            (run_dir / "meta.plan_web.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            LATEST_FILE.write_text(str(run_dir) + "\n", encoding="utf-8")

            print(f"[plan_web] OK run_dir={run_dir} plan_hash={plan_hash}")
            return 0

        meta["attempts"].append({"i": i, "ok": False, "error": "validate", "details": errs[:20]})
        messages.append({"role": "user", "content": "Validation failed. Fix and return ONLY JSON.\n- " + "\n- ".join(errs[:20])})
        time.sleep(min(1.5, 0.2 * i))

    (run_dir / "meta.plan_web.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[plan_web] FAIL run_dir={run_dir}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
