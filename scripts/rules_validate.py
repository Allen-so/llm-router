#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path

REQ_MODES_BASE = {"daily", "coding", "long", "hard"}  # baseline contract

def eprint(*a):
    print(*a, file=sys.stderr)

def is_nonempty_str(x):
    return isinstance(x, str) and x.strip() != ""

def as_list_str(x):
    if not isinstance(x, list):
        return None
    out = []
    for it in x:
        if not is_nonempty_str(it):
            return None
        out.append(it.strip())
    return out

def read_env_file(root: Path) -> dict:
    env_path = root / ".env"
    out = {}
    if not env_path.exists():
        return out
    try:
        for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            out[k] = v
    except Exception:
        return out
    return out

def fetch_models(base_url: str, master_key: str, timeout_s: float = 5.0) -> set[str]:
    base = base_url.rstrip("/")
    url = f"{base}/models"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {master_key}")
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            body = resp.read().decode("utf-8", errors="replace").strip()
    except urllib.error.HTTPError as ex:
        body = ex.read().decode("utf-8", errors="replace").strip() if hasattr(ex, "read") else ""
        raise RuntimeError(f"HTTP {ex.code} from {url}: {body[:200]}")
    except Exception as ex:
        raise RuntimeError(f"failed to GET {url}: {ex}")

    try:
        obj = json.loads(body)
    except Exception as ex:
        raise RuntimeError(f"invalid JSON from {url}: {ex}")

    data = obj.get("data")
    if not isinstance(data, list):
        raise RuntimeError(f"unexpected /models schema (missing data[]): {str(obj)[:200]}")
    ids = set()
    for it in data:
        if isinstance(it, dict) and is_nonempty_str(it.get("id")):
            ids.add(it["id"].strip())
    return ids

def fail(errors, warnings):
    if warnings:
        eprint("WARN:")
        for w in warnings:
            eprint(f"  - {w}")
    if errors:
        eprint("ERROR:")
        for er in errors:
            eprint(f"  - {er}")
        return 1
    return 0

def main():
    args = sys.argv[1:]
    live = False
    base_url = None
    master_key = None
    path = None

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--live":
            live = True
            i += 1
        elif a == "--base-url":
            base_url = args[i+1] if i+1 < len(args) else None
            i += 2
        elif a == "--master-key":
            master_key = args[i+1] if i+1 < len(args) else None
            i += 2
        else:
            path = a
            i += 1

    rules_path = Path(path) if path else Path("infra/router_rules.json")
    root = Path.cwd()

    errors = []
    warnings = []

    if not rules_path.exists():
        errors.append(f"rules file not found: {rules_path}")
        sys.exit(fail(errors, warnings))

    try:
        data = json.loads(rules_path.read_text(encoding="utf-8"))
    except Exception as ex:
        errors.append(f"invalid JSON: {rules_path} ({ex})")
        sys.exit(fail(errors, warnings))

    if not isinstance(data, dict):
        errors.append("root must be a JSON object")
        sys.exit(fail(errors, warnings))

    routing = data.get("routing")
    rules = data.get("rules")
    mode_to_model = data.get("mode_to_model")
    escalation = data.get("escalation")
    log_file = data.get("log_file")

    # ---- routing ----
    if not isinstance(routing, dict):
        errors.append("missing/invalid: routing (object)")
        routing = {}

    long_min = routing.get("long_text_min_chars")
    if not isinstance(long_min, int) or long_min <= 0:
        errors.append("routing.long_text_min_chars must be a positive integer")

    priority = routing.get("priority")
    if not isinstance(priority, list) or not all(is_nonempty_str(x) for x in priority):
        errors.append("routing.priority must be a list of non-empty strings")
        priority_list = []
    else:
        priority_list = [x.strip() for x in priority]
        if len(priority_list) != len(set(priority_list)):
            warnings.append("routing.priority contains duplicates (order still matters, but duplicates are suspicious)")

    # ---- rules keywords ----
    if not isinstance(rules, dict):
        errors.append("missing/invalid: rules (object)")
        rules = {}

    for bucket in ("coding", "hard"):
        b = rules.get(bucket)
        if not isinstance(b, dict):
            errors.append(f"rules.{bucket} must be an object with keywords[]")
            continue
        kw = as_list_str(b.get("keywords"))
        if kw is None:
            errors.append(f"rules.{bucket}.keywords must be a list of non-empty strings")
            continue
        if len(kw) == 0:
            warnings.append(f"rules.{bucket}.keywords is empty (routing will never match this bucket)")
        if len(kw) != len(set(kw)):
            warnings.append(f"rules.{bucket}.keywords contains duplicates")

    # ---- mode_to_model ----
    if not isinstance(mode_to_model, dict) or not mode_to_model:
        errors.append("missing/invalid: mode_to_model (object, non-empty)")
        mode_to_model = {}

    required_modes = set(REQ_MODES_BASE)
    required_modes.update(priority_list)

    for m in sorted(required_modes):
        if m not in mode_to_model:
            if m == "premium":
                warnings.append("mode_to_model missing 'premium' (ok if you only reference premium-chat as a model id)")
            else:
                errors.append(f"mode_to_model missing required mode: '{m}'")

    model_ids = set()
    for k, v in mode_to_model.items():
        if not is_nonempty_str(k):
            errors.append("mode_to_model contains invalid key (must be non-empty string)")
            continue
        if not is_nonempty_str(v):
            errors.append(f"mode_to_model['{k}'] must be a non-empty string model id")
            continue
        model_ids.add(v.strip())

    # ---- escalation ----
    chain = None
    if escalation is not None:
        if not isinstance(escalation, dict):
            errors.append("escalation must be an object when present")
        else:
            chain = escalation.get("chain")
            if chain is not None:
                chain_list = as_list_str(chain)
                if chain_list is None:
                    errors.append("escalation.chain must be a list of non-empty strings (model IDs)")
                else:
                    chain = chain_list
                    if len(chain) < 2:
                        warnings.append("escalation.chain has <2 entries (upgrade path may be ineffective)")
                    for mid in chain:
                        if mid not in model_ids:
                            warnings.append(f"escalation.chain model id '{mid}' not found in mode_to_model values (ensure it's a valid LiteLLM model id)")

    # ---- log_file ----
    if log_file is not None:
        if not is_nonempty_str(log_file):
            errors.append("log_file must be a non-empty string when present")
        else:
            lf = log_file.strip()
            if not lf.startswith("logs/"):
                warnings.append("log_file does not start with 'logs/' (ok, but usually logs are kept under logs/)")
    else:
        warnings.append("log_file not set (ok if scripts define it elsewhere)")

    # ---- LIVE validation ----
    live_models = None
    if live:
        envf = read_env_file(root)
        base_url = base_url or os.getenv("LITELLM_BASE_URL") or envf.get("LITELLM_BASE_URL") or "http://127.0.0.1:4000/v1"
        master_key = master_key or os.getenv("LITELLM_MASTER_KEY") or envf.get("LITELLM_MASTER_KEY")

        if not is_nonempty_str(master_key):
            errors.append("live validation requires LITELLM_MASTER_KEY (env or .env) or --master-key")
        else:
            try:
                live_models = fetch_models(base_url, master_key)
            except Exception as ex:
                errors.append(f"live validation failed: {ex}")

        if isinstance(live_models, set):
            # hard checks: all mode_to_model values should exist in /v1/models
            for mid in sorted(model_ids):
                if mid not in live_models:
                    errors.append(f"live: model id not exposed by /v1/models: '{mid}' (check infra/litellm/config.yaml mapping)")
            if isinstance(chain, list):
                for mid in chain:
                    if mid not in live_models:
                        errors.append(f"live: escalation.chain model not exposed by /v1/models: '{mid}'")

    rc = fail(errors, warnings)
    if rc == 0:
        print(f"OK: rules validate passed ({rules_path})")
        print(f"- long_text_min_chars: {long_min}")
        print(f"- priority: {priority_list}")
        print(f"- modes in mode_to_model: {len(mode_to_model)}")
        if isinstance(chain, list):
            print(f"- escalation.chain: {chain}")
        if live and isinstance(live_models, set):
            print(f"- live models: {len(live_models)} (base_url={base_url.rstrip('/')})")
    sys.exit(rc)

if __name__ == "__main__":
    main()
