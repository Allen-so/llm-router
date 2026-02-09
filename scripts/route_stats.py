#!/usr/bin/env python3
import argparse, datetime as dt, re
from collections import Counter
from pathlib import Path

LINE_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+'
    r'mode=(?P<mode>\S+)\s+model=(?P<model>\S+)\s+status=(?P<status>\S+)\s+'
    r'rc=(?P<rc>-?\d+)\s+tokens=(?P<tokens>\S+)\s+ms=(?P<ms>\S+)\s*$'
)

def parse_ts(s: str) -> dt.datetime:
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)

def main():
    ap = argparse.ArgumentParser(description="Stats for ask_history.log: mode/model distribution.")
    ap.add_argument("--log", default="logs/ask_history.log")
    ap.add_argument("--since-hours", type=float, default=24.0)
    args = ap.parse_args()

    p = Path(args.log)
    if not p.exists():
        print(f"ERROR: log not found: {p}")
        return 1

    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(hours=args.since_hours)

    modes = Counter()
    models = Counter()
    ok = 0
    total = 0

    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = LINE_RE.match(line.strip())
        if not m:
            continue
        d = m.groupdict()
        ts = parse_ts(d["ts"])
        if ts < cutoff:
            continue
        total += 1
        if d["status"] == "ok" and int(d["rc"]) == 0:
            ok += 1
        modes[d["mode"]] += 1
        models[d["model"]] += 1

    window = f"last {args.since_hours:g}h (UTC)"
    print(f"== route stats ==  window: {window}")
    print(f"requests: {total}  ok: {ok}  ok%: {(100.0*ok/total):.0f}%" if total else "requests: 0")

    print("\nmode distribution:")
    for k,v in modes.most_common():
        print(f"  {k:<10} {v}")

    print("\nmodel distribution:")
    for k,v in models.most_common():
        print(f"  {k:<18} {v}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
