#!/usr/bin/env python3
import argparse, json
from pathlib import Path

def load_jsonl(path: Path):
    msgs = []
    if not path.exists():
        return msgs
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        role = obj.get("role")
        content = obj.get("content")
        if role in ("user", "assistant", "system") and isinstance(content, str) and content.strip():
            msgs.append({"role": role, "content": content})
    return msgs

def trim_history(msgs, max_msgs: int, max_chars: int, prefix: str, prompt: str):
    # Reserve some headroom for JSON overhead / model differences
    headroom = 300
    budget = max(0, max_chars - len(prefix) - len(prompt) - headroom)

    tail = msgs[-max_msgs:] if max_msgs > 0 else msgs
    keep_rev = []
    used = 0

    # keep most recent messages within char budget
    for m in reversed(tail):
        cost = len(m["content"]) + 16  # small overhead
        if used + cost > budget:
            break
        keep_rev.append(m)
        used += cost

    keep = list(reversed(keep_rev))
    return keep

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

    hist = load_jsonl(thread_file)
    hist = [m for m in hist if m["role"] in ("user", "assistant")]  # keep only conversational turns

    keep = trim_history(hist, args.max_msgs, args.max_chars, args.prefix or "", args.prompt)

    messages = []
    if (args.prefix or "").strip():
        messages.append({"role": "system", "content": args.prefix.strip()})
    messages.extend(keep)
    messages.append({"role": "user", "content": args.prompt})

    payload = {
        "model": args.model,
        "messages": messages,
        "temperature": float(args.temperature),
    }
    print(json.dumps(payload, ensure_ascii=False))

if __name__ == "__main__":
    main()
