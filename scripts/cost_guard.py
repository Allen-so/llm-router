#!/usr/bin/env python3
import argparse
import datetime as dt
import os
import sys
import math

def parse_line(line: str):
    line = line.strip()
    if not line:
        return None
    parts = line.split()
    if len(parts) < 2:
        return None
    ts = parts[0]
    kv = {}
    for tok in parts[1:]:
        if "=" not in tok:
            continue
        k, v = tok.split("=", 1)
        kv[k] = v
    kv["_ts"] = ts
    return kv

def parse_ts(ts: str):
    try:
        return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None

def quantile(vals, q):
    if not vals:
        return None
    vals = sorted(vals)
    if q <= 0:
        return vals[0]
    if q >= 1:
        return vals[-1]
    idx = int(math.ceil(q * len(vals))) - 1
    idx = max(0, min(idx, len(vals) - 1))
    return vals[idx]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="logs/ask_history.log")
    ap.add_argument("--hours", type=float, default=1.0)
    ap.add_argument("--since-hours", dest="hours", type=float)  # alias
    ap.add_argument("--min-req", type=int, default=5)
    ap.add_argument("--max-empty-rate", type=float, default=0.25)
    ap.add_argument("--max-avg-ms", type=int, default=25000)
    ap.add_argument("--max-p95-ms", type=int, default=60000)
    ap.add_argument("--strict", type=int, default=1)  # 1=fail on violation
    args, _unknown = ap.parse_known_args()

    log_path = args.log
    hours = float(args.hours)
    min_req = int(args.min_req)

    now = dt.datetime.now(dt.timezone.utc)
    start = now - dt.timedelta(hours=hours)

    rows = []
    if os.path.exists(log_path):
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                kv = parse_line(line)
                if not kv:
                    continue
                ts = parse_ts(kv.get("_ts",""))
                if not ts or ts < start:
                    continue
                rows.append(kv)

    req = len(rows)
    ok = 0
    empty = 0
    ms_list = []

    for r in rows:
        status = r.get("status","")
        rc = r.get("rc","")
        try:
            rc_i = int(rc) if rc else 0
        except Exception:
            rc_i = 0

        is_ok = (rc_i == 200) and (status == "ok" or status == "")
        if status in ("empty", "json_invalid"):
            is_ok = False

        if is_ok:
            ok += 1
        else:
            empty += 1

        try:
            ms = int(r.get("ms","") or 0)
        except Exception:
            ms = 0
        if ms > 0:
            ms_list.append(ms)

    if req < min_req:
        print(f"OK: last {hours:g}h (UTC)  requests={req} (<{min_req}) ok={ok} empty={empty} (insufficient sample)")
        return 0

    empty_rate = empty / req if req else 0.0
    avg_ms = int(sum(ms_list)/len(ms_list)) if ms_list else 0
    p95_ms = quantile(ms_list, 0.95) if ms_list else 0

    violations = []
    if empty_rate > args.max_empty_rate:
        violations.append(f"empty_rate={empty_rate:.2f} > {args.max_empty_rate:.2f}")
    if avg_ms > args.max_avg_ms:
        violations.append(f"avg_ms={avg_ms} > {args.max_avg_ms}")
    if p95_ms and p95_ms > args.max_p95_ms:
        violations.append(f"p95_ms={p95_ms} > {args.max_p95_ms}")

    if violations:
        msg = f"FAIL: last {hours:g}h (UTC) requests={req} ok={ok} empty={empty} | " + "; ".join(violations)
        print(msg)
        return 2 if args.strict else 0

    print(f"OK: last {hours:g}h (UTC) requests={req} ok={ok} empty={empty} | avg_ms={avg_ms} p95_ms={p95_ms}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
