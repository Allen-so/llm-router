#!/usr/bin/env python3
import argparse, json, datetime as dt
from pathlib import Path

def ts_utc():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--thread-file", required=True)
    ap.add_argument("--role", required=True, choices=["user","assistant","system"])
    ap.add_argument("--content", required=True)
    ap.add_argument("--mode", default="")
    ap.add_argument("--model", default="")
    ap.add_argument("--status", default="")
    ap.add_argument("--tokens", default="")
    ap.add_argument("--ms", default="")
    args = ap.parse_args()

    p = Path(args.thread_file)
    p.parent.mkdir(parents=True, exist_ok=True)

    rec = {
        "ts": ts_utc(),
        "role": args.role,
        "content": args.content,
    }
    # optional metadata (kept minimal)
    if args.mode: rec["mode"] = args.mode
    if args.model: rec["model"] = args.model
    if args.status: rec["status"] = args.status
    if args.tokens != "": rec["tokens"] = args.tokens
    if args.ms != "": rec["ms"] = args.ms

    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
