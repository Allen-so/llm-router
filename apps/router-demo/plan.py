#!/usr/bin/env python3
import argparse, json, os, re, time, uuid
from pathlib import Path
from urllib import request as urlreq
from urllib.error import HTTPError, URLError

ROOT = Path("/home/suxiaocong/ai-platform")
RUNS_DIR = ROOT / "artifacts" / "runs"
ENV_PATH = ROOT / ".env"

def load_master_key() -> str:
    mk = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if mk:
        return mk
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("LITELLM_MASTER_KEY="):
                v = line.split('=', 1)[1].strip()
                return v.strip().strip('"').strip("'")
    return ""

def http_post_json(url: str, headers: dict, payload: dict, timeout: int = 120):
    body = json.dumps(payload).encode('utf-8')
    req = urlreq.Request(url, data=body, headers={**headers, 'Content-Type': 'application/json'}, method='POST')
    try:
        with urlreq.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode('utf-8', errors='replace')
            return resp.status, json.loads(raw)
    except HTTPError as e:
        raw = ''
        try:
            raw = e.read().decode('utf-8', errors='replace')
        except Exception:
            raw = str(e)
        try:
            return e.code, json.loads(raw) if raw else {'error': str(e)}
        except Exception:
            return e.code, {'error': raw or str(e)}
    except URLError as e:
        return 0, {'error': f'URLError: {e}'}
    except Exception as e:
        return 0, {'error': str(e)}

def strip_code_fences(s: str) -> str:
    s = (s or '').strip()
    if s.startswith('```'):
        s = re.sub(r'^```[a-zA-Z0-9_-]*\s*', '', s)
        s = re.sub(r'\s*```$', '', s)
    return s.strip()

def extract_json_object(s: str):
    s = strip_code_fences(s)
    if s.startswith('{') and s.endswith('}'):
        return s
    i = s.find('{')
    j = s.rfind('}')
    if i != -1 and j != -1 and j > i:
        return s[i:j+1]
    return None

def validate_plan(plan: dict):
    # schema_version is required (we may inject it if missing, for compatibility)
    for k in ('schema_version', 'name', 'type', 'description', 'files', 'run'):
        if k not in plan:
            raise ValueError(f'missing key: {k}')
    if plan['schema_version'] != 1:
        raise ValueError('schema_version must be 1')
    name = plan['name']
    if (not isinstance(name, str)) or (not re.match(r'^[a-z][a-z0-9_-]{2,40}$', name)):
        raise ValueError('invalid name (^[a-z][a-z0-9_-]{2,40}$)')
    if plan['type'] != 'python-cli':
        raise ValueError('type must be "python-cli"')
    if not isinstance(plan['description'], str) or not plan['description'].strip():
        raise ValueError('description must be non-empty string')
    files = plan['files']
    if not isinstance(files, list) or len(files) < 2:
        raise ValueError('files must be an array with at least 2 items')
    for f in files:
        if not isinstance(f, dict) or 'path' not in f or 'content' not in f:
            raise ValueError('each files[] item must be {path, content}')
        path = f['path']
        if not isinstance(path, str) or not path or len(path) > 200:
            raise ValueError('invalid file path')
        if path.startswith('/') or '..' in Path(path).parts:
            raise ValueError(f'unsafe file path: {path}')
        if not isinstance(f['content'], str) or not f['content']:
            raise ValueError(f'empty content: {path}')
    run = plan['run']
    if not isinstance(run, dict) or 'commands' not in run:
        raise ValueError('run.commands missing')
    if not isinstance(run['commands'], list) or len(run['commands']) < 1:
        raise ValueError('run.commands must be a non-empty array')

SYSTEM = (
    'You are a software generator. Output MUST be valid JSON and MUST match this contract:\n'
    '- Top-level keys: schema_version, name, type, description, files, run\n'
    '- schema_version must be 1\n'
    '- type must be "python-cli"\n'
    '- files is an array of {path, content}\n'
    '- Minimal runnable Python CLI project (stdlib only):\n'
    '  * README.md\n'
    '  * pyproject.toml (preferred) OR requirements.txt\n'
    '  * src/<name>/__init__.py\n'
    '  * src/<name>/cli.py (argparse only)\n'
    '- run.commands must be runnable after scaffold when CWD is the generated project folder, e.g. python -m <name>.cli --help\n'
    '\nRules:\n'
    '- Output JSON ONLY. No markdown. No code fences. No extra commentary.\n'
)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--text', default=None)
    ap.add_argument('--text-file', default=None)
    ap.add_argument('--api-base', default='http://127.0.0.1:4000')
    ap.add_argument('--model', default='default-chat')
    ap.add_argument('--timeout', type=int, default=120)
    ap.add_argument('--retries', type=int, default=3)
    args = ap.parse_args()

    if not args.text and not args.text_file:
        raise SystemExit('need --text or --text-file')
    text = args.text
    if args.text_file:
        text = Path(args.text_file).read_text(encoding='utf-8')
    text = (text or '').strip()
    if not text:
        raise SystemExit('empty text')

    run_id = time.strftime('%Y%m%d_%H%M%S') + '_' + uuid.uuid4().hex[:8]
    run_dir = RUNS_DIR / f'run_{run_id}'
    run_dir.mkdir(parents=True, exist_ok=True)

    headers = {}
    mk = load_master_key()
    if mk:
        headers['Authorization'] = f'Bearer {mk}'

    base_messages = [
        {'role': 'system', 'content': ''.join(SYSTEM)},
        {'role': 'user', 'content': text},
    ]

    last_err = None
    for attempt in range(1, max(1, args.retries) + 1):
        messages = list(base_messages)
        if attempt > 1 and last_err:
            messages.append({'role': 'user', 'content': f'Previous output invalid ({last_err}). Return ONLY corrected JSON. No extra text.'})

        payload = {
            'model': args.model,
            'messages': messages,
            'temperature': 0.0 if attempt > 1 else 0.1,
            'max_tokens': 2200,
            'response_format': {'type': 'json_object'},
        }
        (run_dir / f'plan_request_attempt{attempt}.json').write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding='utf-8')

        status, resp = http_post_json(
            url=f"{args.api_base.rstrip('/')}/v1/chat/completions",
            headers=headers,
            payload=payload,
            timeout=args.timeout,
        )
        (run_dir / f'plan_raw_response_attempt{attempt}.json').write_text(json.dumps(resp, indent=2, ensure_ascii=False), encoding='utf-8')

        content = ''
        try:
            content = resp['choices'][0]['message'].get('content') or ''
        except Exception:
            content = ''

        if status != 200 or not content.strip():
            last_err = f'HTTP={status} or empty content'
            continue

        extracted = extract_json_object(content) or ''
        try:
            plan = json.loads(extracted if extracted else content)
        except Exception:
            (run_dir / f'plan_invalid_attempt{attempt}.txt').write_text(content, encoding='utf-8')
            last_err = 'not valid JSON'
            continue

        if 'schema_version' not in plan:
            plan['schema_version'] = 1

        try:
            validate_plan(plan)
        except Exception as e:
            (run_dir / f'plan_invalid_attempt{attempt}.txt').write_text(content, encoding='utf-8')
            (run_dir / f'plan_validation_error_attempt{attempt}.txt').write_text(str(e), encoding='utf-8')
            last_err = f'validation failed: {e}'
            continue

        (run_dir / 'plan.json').write_text(json.dumps(plan, indent=2, ensure_ascii=False), encoding='utf-8')
        (RUNS_DIR / 'LATEST').write_text(str(run_dir), encoding='utf-8')
        print(f'[ok] plan saved: {run_dir / "plan.json"}')
        print(str(run_dir))
        return

    (run_dir / 'plan_final_error.txt').write_text(str(last_err or 'unknown'), encoding='utf-8')
    print('[fail] plan failed; see artifacts in:')
    print(str(run_dir))
    raise SystemExit(2)

if __name__ == '__main__':
    main()
