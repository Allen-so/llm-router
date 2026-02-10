#!/usr/bin/env python3
import argparse
import datetime as dt
import math
import os
import sys
from collections import defaultdict

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
    # "2026-02-10T12:34:56Z"
    try:
        return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None

def pct(n, d):
    return 0.0 if d == 0 else (100.0 * n / d)

def quantile(vals, q):
    if not vals:
        return None
    vals = sorted(vals)
    if q <= 0:
        return vals[0]
    if q >= 1:
        return vals[-1]
    # nearest-rank
    idx = int(math.ceil(q * len(vals))) - 1
    idx = max(0, min(idx, len(vals) - 1))
    return vals[idx]

def fmt_s(ms):
    if ms is None:
        return "n/a"
    return f"{ms/1000:.2f}s"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", default="logs/ask_history.log")
    ap.add_argument("--hours", type=float, default=24.0)
    ap.add_argument("--since-hours", dest="hours", type=float)  # alias
    args, _unknown = ap.parse_known_args()

    log_path = args.log
    hours = float(args.hours)

    now = dt.datetime.now(dt.timezone.utc)
    start = now - dt.timedelta(hours=hours)

    if not os.path.exists(log_path):
        print("== cost summary ==")
        print(f"log: {log_path}")
        print(f"window: last {hours:g}h (UTC)")
        print("parsed: 0 / total_lines: 0  |  filtered: 0")
        print()
        print("requests: 0  ok: 0  empty/fail: 0")
        print("tokens: total=0  avg=0")
        print("latency: avg=n/a  p50=n/a  p95=n/a")
        print("premium-chat: 0 (forced=0, escalated≈0)  |  best-effort-chat: 0")
        return 0

    total_lines = 0
    parsed = 0
    filtered = 0

    rows = []
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            total_lines += 1
            kv = parse_line(line)
            if not kv:
                continue
            ts = parse_ts(kv.get("_ts", ""))
            if not ts:
                continue
            parsed += 1
            if ts < start:
                continue
            filtered += 1
            rows.append(kv)

    # aggregates
    req = len(rows)
    ok = 0
    empty = 0

    tokens_list = []
    ms_list = []

    per_model = defaultdict(lambda: {"n":0,"ok":0,"tokens":0,"ms":[]} )

    premium_n = 0
    premium_forced = 0
    premium_escal = 0

    be_n = 0
    be_forced = 0

    for r in rows:
        model = r.get("model", "")
        mode  = r.get("mode", "")
        status = r.get("status", "")
        rc = r.get("rc", "")
        escal = r.get("escalated", "0")

        try:
            rc_i = int(rc) if rc else 0
        except Exception:
            rc_i = 0

        tok = 0
        ms = None
        try:
            tok = int(r.get("tokens","") or 0)
        except Exception:
            tok = 0
        try:
            ms = int(r.get("ms","") or 0)
        except Exception:
            ms = None

        is_ok = (rc_i == 200) and (status == "ok" or status == "" )
        if rc_i == 200 and status == "empty":
            is_ok = False

        if is_ok and (r.get("status","") != "json_invalid"):
            ok += 1
        else:
            # treat json_invalid as fail too
            empty += 1

        if tok > 0:
            tokens_list.append(tok)
        if ms is not None and ms > 0:
            ms_list.append(ms)

        pm = per_model[model]
        pm["n"] += 1
        pm["ok"] += 1 if is_ok else 0
        pm["tokens"] += tok
        if ms is not None and ms > 0:
            pm["ms"].append(ms)

        if model == "premium-chat":
            premium_n += 1
            if mode in ("premium","premium-chat"):
                premium_forced += 1
            if str(escal) == "1":
                premium_escal += 1

        if model == "best-effort-chat":
            be_n += 1
            if mode in ("best-effort","best-effort-chat","hard"):
                be_forced += 1

    total_tokens = sum(tokens_list) if tokens_list else 0
    avg_tokens = (total_tokens / req) if req else 0.0

    avg_ms = (sum(ms_list) / len(ms_list)) if ms_list else None
    p50_ms = quantile(ms_list, 0.50) if ms_list else None
    p95_ms = quantile(ms_list, 0.95) if ms_list else None

    print("== cost summary ==")
    print(f"log: {log_path}")
    print(f"window: last {hours:g}h (UTC)")
    print(f"parsed: {parsed} / total_lines: {total_lines}  |  filtered: {filtered}")
    print()
    print(f"requests: {req}  ok: {ok}  empty/fail: {empty}")
    print(f"tokens: total={total_tokens}  avg={avg_tokens:.2f}")
    print(f"latency: avg={fmt_s(avg_ms)}  p50={fmt_s(p50_ms)}  p95={fmt_s(p95_ms)}")
    print(f"premium-chat: {premium_n} (forced={premium_forced}, escalated≈{premium_escal})  |  best-effort-chat: {be_n} (forced={be_forced})")
    print()
    print(f"{'model':<20} {'n':>3} {'ok%':>5} {'tokens':>10} {'avg_tok':>8} {'p95_ms':>8} {'avg_ms':>8}")
    print("-"*67)

    # sort by n desc
    for model, st in sorted(per_model.items(), key=lambda x: x[1]["n"], reverse=True):
        n = st["n"]
        okp = pct(st["ok"], n)
        tok = st["tokens"]
        avg_tok_m = (tok / n) if n else 0.0
        p95m = quantile(st["ms"], 0.95) if st["ms"] else None
        avgm = (sum(st["ms"]) / len(st["ms"])) if st["ms"] else None
        print(f"{model:<20} {n:>3} {okp:>5.0f}% {tok:>10} {avg_tok_m:>8.2f} {fmt_s(p95m):>8} {fmt_s(avgm):>8}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
