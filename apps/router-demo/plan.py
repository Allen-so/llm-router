#!/usr/bin/env python3
import argparse, json, os, sys, time, uuid, re
from pathlib import Path
from urllib import request as urlreq
from urllib.error import HTTPError, URLError

ROOT = Path("/home/suxiaocong/ai-platform")
RUNS_DIR = ROOT / "artifacts" / "runs"
ENV_PATH = ROOT / ".env"

SCHEMA_PATH = ROOT / "apps" / "router-demo" / "schemas" / "plan.schema.json"
NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{2,40}$")

def validate_schema_file() -> None:
    # Lightweight sanity check (no jsonschema dependency)
    if not SCHEMA_PATH.exists():
        raise SystemExit(f"[fail] missing schema file: {SCHEMA_PATH}")
    import json as _json
    obj = _json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    if not isinstance(obj, dict):
        raise SystemExit("[fail] schema must be a JSON object")

    req = obj.get("required", [])
    if not isinstance(req, list) or not set(["schema_version","name","type","description","files","run"]).issubset(set(req)):
        raise SystemExit("[fail] schema.required missing keys")

    props = obj.get("properties", {})
    if not isinstance(props, dict):
        raise SystemExit("[fail] schema.properties missing")

    sv = (props.get("schema_version") or {})
    if not isinstance(sv, dict) or sv.get("const") != 1:
        raise SystemExit("[fail] schema_version must have const=1")

    # Optional: keep schema aligned with plan.py expectations
    if props.get("type", {}).get("enum") != ["python-cli"]:
        raise SystemExit("[fail] schema type enum must be ['python-cli']")


def load_master_key() -> str:
    mk = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if mk:
        return mk
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("LITELLM_MASTER_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""

def normalize_v1(api_base: str) -> str:
    b = (api_base or "").strip().rstrip("/")
    if b.endswith("/v1"):
        return b
    return b + "/v1"

def http_post_json(url: str, headers: dict, payload: dict, timeout: int = 120):
    body = json.dumps(payload).encode("utf-8")
    req = urlreq.Request(url, data=body, headers={**headers, "Content-Type": "application/json"}, method="POST")
    with urlreq.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
        return resp.status, json.loads(raw), raw

def extract_json_object(text: str) -> dict:
    """
    Best-effort extraction:
    1) direct json.loads
    2) ```json ... ```
    3) first '{' .. last '}' slice
    """
    t = (text or "").strip()
    # 1) direct
    try:
        obj = json.loads(t)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass

    # 2) fenced
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", t, flags=re.S | re.I)
    if m:
        cand = m.group(1).strip()
        obj = json.loads(cand)
        if isinstance(obj, dict):
            return obj

    # 3) slice
    i = t.find("{")
    j = t.rfind("}")
    if i != -1 and j != -1 and j > i:
        cand = t[i : j + 1]
        obj = json.loads(cand)
        if isinstance(obj, dict):
            return obj

    raise ValueError("no JSON object found")

def validate_rel_path(p: str):
    if not isinstance(p, str):
        raise ValueError("files[].path must be string")
    p = p.strip()
    if not p:
        raise ValueError("files[].path empty")
    if len(p) > 200:
        raise ValueError("files[].path too long (>200)")
    if p.startswith(("/", "\\", "~")):
        raise ValueError("files[].path must be relative (no leading /, \\, ~)")
    if re.match(r"^[A-Za-z]:", p):
        raise ValueError("files[].path must not be windows drive path")
    # block traversal
    parts = Path(p).parts
    if any(seg in ("..",) for seg in parts):
        raise ValueError("files[].path must not contain '..'")
    # normalize to forward slashes in output expectation (optional)
    # allow subfolders, but no weird control chars
    if any(ord(ch) < 32 for ch in p):
        raise ValueError("files[].path has control chars")

def validate_plan(plan: dict):
    if not isinstance(plan, dict):
        raise ValueError("plan must be a JSON object")

    allowed_top = {"schema_version", "name", "type", "description", "files", "run"}
    extra = set(plan.keys()) - allowed_top
    if extra:
        raise ValueError(f"extra top-level keys not allowed: {sorted(extra)}")

    sv = plan.get("schema_version")
    if sv != 1:
        raise ValueError("schema_version must be 1")

    name = plan.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ValueError("name invalid (must match ^[a-z][a-z0-9_-]{2,40}$)")

    typ = plan.get("type")
    if typ != "python-cli":
        raise ValueError("type must be 'python-cli'")

    desc = plan.get("description")
    if not isinstance(desc, str) or not (1 <= len(desc) <= 280):
        raise ValueError("description must be 1..280 chars")

    files = plan.get("files")
    if not isinstance(files, list) or len(files) < 2:
        raise ValueError("files must be an array with >=2 items")

    saw_pyproject = False
    saw_src = False

    for i, f in enumerate(files):
        if not isinstance(f, dict):
            raise ValueError(f"files[{i}] must be object")
        allowed_file = {"path", "content"}
        extra_f = set(f.keys()) - allowed_file
        if extra_f:
            raise ValueError(f"files[{i}] extra keys not allowed: {sorted(extra_f)}")

        path = f.get("path")
        content = f.get("content")

        validate_rel_path(path)

        if not isinstance(content, str) or not content.strip():
            raise ValueError(f"files[{i}].content empty")
        if len(content) > 20000:
            raise ValueError(f"files[{i}].content too long (>20000)")

        if path == "pyproject.toml":
            saw_pyproject = True
        if path.startswith("src/"):
            saw_src = True

    if not (saw_pyproject and saw_src):
        raise ValueError("files must include pyproject.toml and at least one src/... file")

    run = plan.get("run")
    if not isinstance(run, dict):
        raise ValueError("run must be object")
    extra_run = set(run.keys()) - {"commands"}
    if extra_run:
        raise ValueError(f"run extra keys not allowed: {sorted(extra_run)}")

    cmds = run.get("commands")
    if not isinstance(cmds, list) or len(cmds) < 1:
        raise ValueError("run.commands must be a non-empty array")
    if len(cmds) > 20:
        raise ValueError("run.commands too many (>20)")

    for k, c in enumerate(cmds):
        if not isinstance(c, str) or not c.strip():
            raise ValueError(f"run.commands[{k}] empty")
        if len(c) > 300:
            raise ValueError(f"run.commands[{k}] too long (>300)")

def build_system_prompt() -> str:
    return (
        "You must output ONLY a single JSON object (no markdown, no code fences, no commentary). "
        "Schema:\n"
        "{\n"
        '  "schema_version": 1,\n'
        '  "name": "lowercase slug 3..41 chars, regex ^[a-z][a-z0-9_-]{2,40}$",\n'
        '  "type": "python-cli",\n'
        '  "description": "1..280 chars",\n'
        '  "files": [ {"path": "relative/path", "content": "file content"}, ... ] (>=2 items),\n'
        '  "run": {"commands": ["shell command", ...]} (>=1)\n'
        "}\n"
        "Constraints:\n"
        "- top-level keys must be EXACTLY: schema_version,name,type,description,files,run\n"
        "- files[].path must be RELATIVE, no leading /, no .., no windows drive\n"
        "- include pyproject.toml and at least one src/... file\n"
        "- keep file contents concise (each <=20000 chars)\n"
    )

def main():
    validate_schema_file()
    ap = argparse.ArgumentParser()
    ap.add_argument("--api-base", default="http://127.0.0.1:4000")
    ap.add_argument("--model", default="default-chat")
    ap.add_argument("--text", default=None)
    ap.add_argument("--text-file", default=None)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--sleep", type=float, default=0.6)
    args = ap.parse_args()

    if not args.text and not args.text_file:
        raise SystemExit("Provide --text or --text-file")

    user_text = args.text
    if args.text_file:
        user_text = Path(args.text_file).read_text(encoding="utf-8", errors="ignore")

    master = load_master_key()
    if not master:
        print("[warn] LITELLM_MASTER_KEY not found (plan may 401).", file=sys.stderr)

    v1 = normalize_v1(args.api_base)
    url = f"{v1}/chat/completions"

    headers = {"Authorization": f"Bearer {master}"} if master else {}

    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    run_dir = RUNS_DIR / f"run_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}"
    run_dir.mkdir(parents=True, exist_ok=True)

    # base payload
    sys_prompt = build_system_prompt()
    messages = [
        {"role": "system", "content": sys_prompt},
        {"role": "user", "content": user_text.strip()},
    ]

    last_err = "unknown"
    last_raw = ""

    for attempt in range(1, args.retries + 1):
        payload = {
            "model": args.model,
            "messages": messages,
            "temperature": 0,
        }

        (run_dir / f"request_attempt_{attempt}.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8"
        )

        try:
            status, resp_json, raw = http_post_json(url, headers, payload, timeout=args.timeout)
            last_raw = raw
            (run_dir / f"response_attempt_{attempt}.json").write_text(raw + "\n", encoding="utf-8")

            # extract model content
            content = ""
            try:
                content = resp_json["choices"][0]["message"]["content"]
            except Exception:
                raise ValueError("unexpected response format (missing choices[0].message.content)")

            plan = extract_json_object(content)
            validate_plan(plan)

            # success -> save plan.json + LATEST
            (run_dir / "plan.json").write_text(
                json.dumps(plan, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8"
            )
            (run_dir / "plan_raw.txt").write_text(content + "\n", encoding="utf-8")

            (RUNS_DIR / "LATEST").write_text(str(run_dir) + "\n", encoding="utf-8")

            print(f"[ok] plan saved: {run_dir}/plan.json")
            print(str(run_dir))
            return

        except (HTTPError, URLError) as e:
            last_err = f"http error: {getattr(e, 'code', None)} {e}"
        except Exception as e:
            last_err = str(e)

        # save invalid output
        (run_dir / "plan_invalid.txt").write_text(
            f"attempt={attempt}\nerror={last_err}\n\nRAW_RESPONSE:\n{last_raw}\n",
            encoding="utf-8"
        )

        # tighten instruction for next attempt
        messages = [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_text.strip()},
            {"role": "user", "content": f"Your previous output was invalid: {last_err}. Return corrected JSON ONLY."},
        ]

        time.sleep(args.sleep)

    print("[fail] could not produce valid plan.json after retries", file=sys.stderr)
    sys.exit(2)

if __name__ == "__main__":
    main()
