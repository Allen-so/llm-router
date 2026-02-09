#!/usr/bin/env python3
import argparse, datetime as dt, re, sys
from pathlib import Path

LINE_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+'
    r'mode=(?P<mode>\S+)\s+model=(?P<model>\S+)\s+status=(?P<status>\S+)\s+'
    r'rc=(?P<rc>-?\d+)\s+tokens=(?P<tokens>\S+)\s+ms=(?P<ms>\S+)\s*$'
)

def parse_ts(s: str) -> dt.datetime:
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)

def parse_int(x):
    try:
        return int(x)
    except Exception:
        return None

def percentile(values, p):
    if not values:
        return None
    v = sorted(values)
    k = int((p/100.0) * len(v))
    if k <= 0:
        return v[0]
    if k >= len(v):
        return v[-1]
    return v[k-1]

def main():
    ap = argparse.ArgumentParser(description="Guardrail check for ask_history.log")
    ap.add_argument("--log", default="logs/ask_history.log")
    ap.add_argument("--since-hours", type=float, default=1.0)
    args = ap.parse_args()

    path = Path(args.log)
    if not path.exists():
        print(f"FAIL: log not found: {path}", file=sys.stderr)
        sys.exit(2)

    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(hours=args.since_hours)

    rows = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = LINE_RE.match(line.strip())
        if not m:
            continue
        d = m.groupdict()
        ts = parse_ts(d["ts"])
        if ts < cutoff:
            continue
        rows.append({
            "ts": ts,
            "mode": d["mode"],
            "model": d["model"],
            "status": d["status"],
            "rc": int(d["rc"]),
            "tokens": parse_int(d["tokens"]),
            "ms": parse_int(d["ms"]),
        })

    total = len(rows)
    ok = sum(1 for r in rows if r["status"] == "ok" and r["rc"] == 0)
    empty = total - ok

    ms = [r["ms"] for r in rows if isinstance(r["ms"], int)]
    p95_ms = percentile(ms, 95)

    premium_total = sum(1 for r in rows if r["model"] == "premium-chat")
    premium_forced = sum(1 for r in rows if r["model"] == "premium-chat" and r["mode"] == "premium")
    premium_escalated = premium_total - premium_forced

    # thresholds (env)
    thr_premium_per_h = int(float((__import__("os").environ.get("THRESH_PREMIUM_ESCALATED_PER_HOUR", "3"))))
    thr_p95_ms = int(float((__import__("os").environ.get("THRESH_P95_MS", "10000"))))

    # scale by window hours
    allowed_escalated = thr_premium_per_h * max(1, int(round(args.since_hours)))

    # decide level
    level = "OK"
    rc = 0

    reasons = []

    if empty > 0:
        level = "FAIL"
        rc = 2
        reasons.append(f"empty/fail={empty}")

    if p95_ms is not None and p95_ms > thr_p95_ms:
        if level != "FAIL":
            level = "WARN"
            rc = 1
        reasons.append(f"p95_ms={p95_ms} > {thr_p95_ms}")

    if premium_escalated > allowed_escalated:
        if premium_escalated > 2 * allowed_escalated:
            level = "FAIL"
            rc = 2
        else:
            if level != "FAIL":
                level = "WARN"
                rc = 1
        reasons.append(f"premium_escalated≈{premium_escalated} > {allowed_escalated}")

    window = f"last {args.since_hours:g}h (UTC)"
    print(f"{level}: {window}  requests={total} ok={ok} empty={empty} p95_ms={p95_ms if p95_ms is not None else '-'} premium_escalated≈{premium_escalated}")
    if reasons:
        print("reasons: " + "; ".join(reasons))

    sys.exit(rc)

if __name__ == "__main__":
    main()
