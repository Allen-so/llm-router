#!/usr/bin/env python3
import json
import sys
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
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("infra/router_rules.json")
    errors = []
    warnings = []

    if not path.exists():
        errors.append(f"rules file not found: {path}")
        sys.exit(fail(errors, warnings))

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as ex:
        errors.append(f"invalid JSON: {path} ({ex})")
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

    # required modes: base + priority + premium (if referenced)
    required_modes = set(REQ_MODES_BASE)
    required_modes.update(priority_list)

    # If escalation chain exists, ensure premium mode exists OR chain models exist
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

    # If priority mentions a mode but mode_to_model missing -> error
    for m in sorted(required_modes):
        if m not in mode_to_model:
            # allow "premium" to be optional unless your config uses it explicitly
            if m == "premium":
                warnings.append("mode_to_model missing 'premium' (ok if you only reference premium-chat as a model id)")
            else:
                errors.append(f"mode_to_model missing required mode: '{m}'")

    # Validate mode_to_model values
    model_ids = set()
    for k, v in mode_to_model.items():
        if not is_nonempty_str(k):
            errors.append("mode_to_model contains invalid key (must be non-empty string)")
            continue
        if not is_nonempty_str(v):
            errors.append(f"mode_to_model['{k}'] must be a non-empty string model id")
            continue
        model_ids.add(v.strip())

    # Validate escalation chain model ids exist in mode_to_model values
    if isinstance(chain, list):
        for mid in chain:
            if mid not in model_ids:
                warnings.append(f"escalation.chain model id '{mid}' not found in mode_to_model values (ensure it's a valid model id in LiteLLM)")

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

    # ---- summary ----
    rc = fail(errors, warnings)
    if rc == 0:
        print(f"OK: rules validate passed ({path})")
        print(f"- long_text_min_chars: {long_min}")
        print(f"- priority: {priority_list}")
        print(f"- modes in mode_to_model: {len(mode_to_model)}")
        if isinstance(chain, list):
            print(f"- escalation.chain: {chain}")
    sys.exit(rc)

if __name__ == "__main__":
    main()
