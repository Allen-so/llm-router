#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

PATTERNS = [
    ("rate_limit", [r"\b429\b", r"rate limit", r"too many requests"]),
    ("timeout", [r"timeout", r"timed out", r"ETIMEDOUT"]),
    ("conn_refused", [r"ECONNREFUSED", r"Connection refused"]),
    ("dns", [r"ENOTFOUND", r"getaddrinfo"]),
    ("auth_missing", [r"No api key passed in", r"Missing env LITELLM_MASTER_KEY", r"\b401\b.*(unauthorized|auth)"]),
    ("json_parse", [r"JSONDecodeError", r"Expecting value", r"invalid json"]),
    ("schema_invalid", [r"jsonschema", r"ValidationError", r"schema"]),
    ("next_build_fail", [r"next build", r"Failed to compile", r"Type error"]),
    ("npm_install_fail", [r"npm ERR!", r"ERR_PNPM", r"code ERESOLVE"]),
    ("docker", [r"docker", r"compose", r"Cannot connect to the Docker daemon"]),
]

def tail_text(path: Path, n_chars: int = 8000) -> str:
    try:
        t = path.read_text(encoding="utf-8", errors="ignore")
        return t[-n_chars:]
    except Exception:
        return ""

def classify(text: str, rc: int, step: str) -> tuple[str, str]:
    low = (text or "").lower()
    for cls, regs in PATTERNS:
        for r in regs:
            if re.search(r, low, flags=re.IGNORECASE):
                return cls, "matched_pattern"
    if rc != 0:
        return f"rc_{rc}", "nonzero_rc"
    return "ok", ""

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", required=True)
    ap.add_argument("--rc", type=int, required=True)
    ap.add_argument("--log-file", default="")
    ap.add_argument("--plain", action="store_true", help="print: <class>\\t<message>")
    args = ap.parse_args()

    txt = ""
    if args.log_file:
        txt = tail_text(Path(args.log_file))

    cls, msg = classify(txt, args.rc, args.step)
    if args.plain:
        print(f"{cls}\t{msg}")
    else:
        print({"error_class": cls, "message": msg, "step": args.step, "rc": args.rc, "log_file": args.log_file})
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
