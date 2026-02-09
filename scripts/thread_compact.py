#!/usr/bin/env python3
import argparse, json, os, sys, datetime as dt
from pathlib import Path
from urllib import request

def ts_utc():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def safe_name(name: str) -> str:
    import re
    return re.sub(r'[^A-Za-z0-9._-]+', '_', name.strip()) or "default"

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

def write_jsonl(path: Path, items):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for it in items:
            f.write(json.dumps(it, ensure_ascii=False) + "\n")

def api_chat(base_url: str, master_key: str, payload: dict, timeout: int = 120) -> str:
    url = base_url.rstrip("/") + "/chat/completions"
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = request.Request(url, data=data, headers={
        "Authorization": f"Bearer {master_key}",
        "Content-Type": "application/json",
    })
    with request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="ignore")
    d = json.loads(raw)
    c = (d.get("choices") or [{}])[0]
    m = (c.get("message") or {})
    return (m.get("content") or "").strip()

def main():
    ap = argparse.ArgumentParser(description="Compact a thread jsonl: write a system summary + keep last turns.")
    ap.add_argument("thread", help="thread name")
    ap.add_argument("--file", default="", help="override thread file path (optional)")
    ap.add_argument("--max-chars", type=int, default=int(os.getenv("THREAD_COMPACT_MAX_CHARS", "12000")))
    ap.add_argument("--keep-last", type=int, default=int(os.getenv("THREAD_COMPACT_KEEP_LAST", "12")))
    ap.add_argument("--model", default=os.getenv("THREAD_SUMMARY_MODEL", "default-chat"))
    ap.add_argument("--base-url", default=os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:4000/v1"))
    ap.add_argument("--master-key", default=os.getenv("LITELLM_MASTER_KEY", ""))
    args = ap.parse_args()

    if not args.master_key:
        print("thread_compact: missing LITELLM_MASTER_KEY in env/.env", file=sys.stderr)
        return 2

    thread_name = safe_name(args.thread)
    path = Path(args.file) if args.file else Path("logs/threads") / f"{thread_name}.jsonl"
    items = load_jsonl(path)

    # only compact if above threshold
    total_chars = sum(len((it.get("content") or "")) for it in items if isinstance(it, dict))
    if total_chars < args.max_chars:
        print(f"SKIP: thread under max-chars ({total_chars} < {args.max_chars})")
        return 0

    # Separate summary records vs turns
    turns = []
    for it in items:
        if not isinstance(it, dict):
            continue
        role = it.get("role")
        content = it.get("content")
        if role in ("user","assistant") and isinstance(content, str) and content.strip():
            turns.append({"role": role, "content": content.strip()})

    if len(turns) <= args.keep_last + 2:
        print("SKIP: not enough turns to compact safely")
        return 0

    # Build summarization prompt
    # Keep it concise + actionable; no extra fluff.
    convo = []
    for m in turns[:-args.keep_last]:
        tag = "USER" if m["role"]=="user" else "ASSISTANT"
        convo.append(f"{tag}: {m['content']}")
    convo_text = "\n".join(convo)

    sys_prompt = (
        "You are a compression engine for a CLI assistant.\n"
        "Summarize the conversation so far so the assistant can continue accurately.\n"
        "Rules:\n"
        "- Preserve key facts, code context, decisions, constraints, file paths/commands.\n"
        "- List open questions / next steps.\n"
        "- Be concise. No greetings. No fluff.\n"
        "- Output plain text.\n"
    )
    user_prompt = f"Conversation:\n{convo_text}\n\nWrite the summary now."

    payload = {
        "model": args.model,
        "messages": [
            {"role":"system","content":sys_prompt},
            {"role":"user","content":user_prompt},
        ],
        "temperature": 0.2,
    }

    try:
        summary = api_chat(args.base_url, args.master_key, payload)
    except Exception as e:
        print(f"FAIL: summarization call failed: {e}", file=sys.stderr)
        return 2

    summary_rec = {
        "ts": ts_utc(),
        "role": "system",
        "kind": "summary",
        "content": summary.strip(),
        "model": args.model,
    }

    kept = turns[-args.keep_last:]
    new_items = [summary_rec]
    # re-add kept turns with minimal metadata
    for m in kept:
        new_items.append({"ts": ts_utc(), "role": m["role"], "content": m["content"]})

    write_jsonl(path, new_items)
    print(f"OK: compacted {path}  (kept_last={args.keep_last}, max_chars={args.max_chars})")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
