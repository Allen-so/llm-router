#!/usr/bin/env python3
import argparse, os, re
from datetime import datetime, timezone, timedelta
from pathlib import Path

LINE_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+'
    r'.*?\bstatus=(?P<status>\w+)\b.*?'
    r'\btokens=(?P<tokens>\d+)\b.*?'
    r'\bms=(?P<ms>\d+)\b.*?'
    r'\bmodel=(?P<model>[^\s]+)\b'
)

def parse_ts(s: str) -> datetime:
    # "2026-02-09T14:54:28Z"
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

def percentile(xs, p: float) -> int:
    if not xs:
        return 0
    xs = sorted(xs)
    if len(xs) == 1:
        return xs[0]
    k = int(round((len(xs) - 1) * p))
    k = max(0, min(k, len(xs) - 1))
    return xs[k]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="logs/ask_history.log")
    ap.add_argument("--hours", type=float, default=1.0)
    ap.add_argument("--since-hours", dest="hours", type=float, help="alias of --hours")
    args = ap.parse_args()

    # knobs (env)
    min_req = int(os.getenv("COST_GUARD_MIN_REQ", "5"))
    warn_p95_ms = int(os.getenv("COST_GUARD_WARN_P95_MS", "10000"))
    fail_p95_ms = int(os.getenv("COST_GUARD_FAIL_P95_MS", "30000"))
    strict = os.getenv("COST_GUARD_STRICT", "0") == "1"

    path = Path(args.log)
    if not path.exists():
        print(f"OK: no log file: {args.log} (skip)")
        return 0

    now = datetime.now(timezone.utc)
    window = timedelta(hours=args.hours)

    ms = []
    statuses = []
    premium = 0
    total = 0

    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = LINE_RE.search(line)
        if not m:
            continue
        total += 1
        ts = parse_ts(m.group("ts"))
        if now - ts > window:
            continue
        statuses.append(m.group("status"))
        ms.append(int(m.group("ms")))
        if m.group("model") == "premium-chat":
            premium += 1

    n = len(ms)
    ok = sum(1 for s in statuses if s == "ok")
    empty = n - ok

    # If sample is too small, don't overreact
    if n < min_req:
        print(f"OK: last {args.hours:g}h (UTC)  requests={n} (<{min_req}) ok={ok} empty={empty} (insufficient sample)")
        return 0

    p95 = percentile(ms, 0.95)

    # Decide severity
    reasons = []
    severity = "OK"
    rc = 0

    if p95 > warn_p95_ms:
        severity = "WARN"
        reasons.append(f"p95_ms={p95} > {warn_p95_ms}")
        rc = 0  # WARN should NOT fail by default

    if p95 > fail_p95_ms:
        severity = "FAIL"
        reasons.append(f"p95_ms={p95} > {fail_p95_ms}")
        rc = 1

    if strict and severity == "WARN":
        # in strict mode, WARN fails
        rc = 1

    reasons_str = ("reasons: " + ", ".join(reasons)) if reasons else ""

    if severity == "OK":
        print(f"OK: last {args.hours:g}h (UTC)  requests={n} ok={ok} empty={empty} p95_ms={p95} premium={premium}")
    elif severity == "WARN":
        print(f"WARN: last {args.hours:g}h (UTC)  requests={n} ok={ok} empty={empty} p95_ms={p95} premium={premium}")
        if reasons_str:
            print(reasons_str)
    else:
        print(f"FAIL: last {args.hours:g}h (UTC)  requests={n} ok={ok} empty={empty} p95_ms={p95} premium={premium}")
        if reasons_str:
            print(reasons_str)

    return rc

if __name__ == "__main__":
    raise SystemExit(main())
