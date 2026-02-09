#!/usr/bin/env python3
# __THREAD_BUILD_SUPPORT_SUMMARY_V1__
import argparse, json
from pathlib import Path

def load_jsonl(path: Path):
    items=[]
    if not path.exists():
        return items
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line=line.strip()
        if not line:
            continue
        try:
            items.append(json.loads(line))
        except Exception:
            continue
    return items

def latest_summary(items):
    # prefer {"role":"system","kind":"summary"}
    for it in reversed(items):
        if isinstance(it, dict) and it.get("role")=="system":
            if it.get("kind")=="summary" and isinstance(it.get("content"), str) and it["content"].strip():
                return it["content"].strip()
    # fallback: system content starts with SUMMARY:
    for it in reversed(items):
        if isinstance(it, dict) and it.get("role")=="system":
            c = it.get("content")
            if isinstance(c, str) and c.strip().lower().startswith("summary"):
                return c.strip()
    return ""

def collect_turns(items):
    turns=[]
    for it in items:
        if not isinstance(it, dict):
            continue
        role = it.get("role")
        content = it.get("content")
        if role in ("user","assistant") and isinstance(content, str) and content.strip():
            turns.append({"role": role, "content": content.strip()})
    return turns

def trim_history(turns, max_msgs: int, max_chars: int, sys_text: str, prompt: str):
    headroom = 300
    budget = max(0, max_chars - len(sys_text) - len(prompt) - headroom)

    tail = turns[-max_msgs:] if max_msgs > 0 else turns
    keep_rev=[]
    used=0
    for m in reversed(tail):
        cost = len(m["content"]) + 16
        if used + cost > budget:
            break
        keep_rev.append(m)
        used += cost
    return list(reversed(keep_rev))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--thread-file", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--temperature", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--max-chars", type=int, default=8000)
    ap.add_argument("--max-msgs", type=int, default=24)
    args = ap.parse_args()

    thread_file = Path(args.thread_file)
    thread_file.parent.mkdir(parents=True, exist_ok=True)

    items = load_jsonl(thread_file)
    summary = latest_summary(items)
    turns = collect_turns(items)

    sys_text = (args.prefix or "").strip()
    if summary:
        if sys_text:
            sys_text = sys_text + "\n\nConversation summary:\n" + summary
        else:
            sys_text = "Conversation summary:\n" + summary

    keep = trim_history(turns, args.max_msgs, args.max_chars, sys_text, args.prompt)

    messages=[]
    if sys_text.strip():
        messages.append({"role":"system","content":sys_text.strip()})
    messages.extend(keep)
    messages.append({"role":"user","content":args.prompt})

    payload={"model": args.model, "messages": messages, "temperature": float(args.temperature)}
    print(json.dumps(payload, ensure_ascii=False))

if __name__ == "__main__":
    main()
