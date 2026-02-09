#!/usr/bin/env python3
import json, re, sys
from pathlib import Path

rules_path = Path(sys.argv[1])
mode_in = sys.argv[2]
msg = sys.argv[3]

rules = json.loads(rules_path.read_text(encoding="utf-8"))
modes = rules.get("modes", {})
auto_rules = rules.get("auto_rules", [])
esc = rules.get("escalation", {}).get("chain", [])
log_file = rules.get("logging", {}).get("file", "logs/ask_history.log")

def pick_auto(text: str) -> str:
    n = len(text)
    for rule in auto_rules:
        mode = rule.get("mode", "daily")
        when = rule.get("when", {}) or {}
        min_chars = when.get("min_chars")
        if isinstance(min_chars, int) and n >= min_chars:
            return mode
        for pat in (when.get("regex") or []):
            try:
                if re.search(pat, text, flags=re.IGNORECASE):
                    return mode
            except re.error:
                if pat.lower() in text.lower():
                    return mode
        if when == {}:
            return mode
    return "daily"

mode = pick_auto(msg) if mode_in == "auto" else mode_in
conf = modes.get(mode) or modes.get("daily") or {"model":"default-chat","prefix":""}

out = {
    "mode": mode,
    "model": conf.get("model","default-chat"),
    "prefix": (conf.get("prefix") or "").rstrip("\n"),
    "escalation": list(esc),
    "log_file": log_file,
}
print(json.dumps(out, ensure_ascii=False))
