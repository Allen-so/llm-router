#!/usr/bin/env python3
import argparse, datetime as dt, re, sys
from pathlib import Path
from collections import defaultdict

LINE_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+'
    r'mode=(?P<mode>\S+)\s+model=(?P<model>\S+)\s+status=(?P<status>\S+)\s+'
    r'rc=(?P<rc>-?\d+)\s+tokens=(?P<tokens>\S+)\s+ms=(?P<ms>\S+)\s*$'
)

def parse_int(x):
    try:
        return int(x)
    except Exception:
        return None

def percentile(values, p):
    """Nearest-rank percentile, p in [0,100]."""
    if not values:
        return None
    v = sorted(values)
    k = int((p/100.0) * len(v))
    if k <= 0:
        return v[0]
    if k >= len(v):
        return v[-1]
    return v[k-1]  # nearest-rank

def fmt_ms(x):
    if x is None:
        return "-"
    if x < 1000:
        return f"{x}ms"
    return f"{x/1000:.2f}s"

def fmt_int(x):
    return "-" if x is None else str(x)

def utc_today():
    return dt.datetime.now(dt.timezone.utc).date()

def parse_ts(ts):
    # ts is like 2026-02-09T14:59:58Z
    return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)

def main():
    ap = argparse.ArgumentParser(description="Summarize ask_history.log usage/cost signals.")
    ap.add_argument("--log", default="logs/ask_history.log", help="Path to ask_history.log")
    ap.add_argument("--date", default=None, help="UTC date filter: YYYY-MM-DD (default: today UTC)")
    ap.add_argument("--since-hours", type=float, default=None, help="Only include last N hours (UTC)")
    ap.add_argument("--all", action="store_true", help="Include all lines (ignore date filter)")
    ap.add_argument("--json", action="store_true", help="Output JSON (minimal fields)")
    args = ap.parse_args()

    path = Path(args.log)
    if not path.exists():
        print(f"ERROR: log not found: {path}", file=sys.stderr)
        sys.exit(1)

    raw_lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()

    rows = []
    for line in raw_lines:
        m = LINE_RE.match(line.strip())
        if not m:
            continue
        d = m.groupdict()
        ts = parse_ts(d["ts"])
        rows.append({
            "ts": ts,
            "mode": d["mode"],
            "model": d["model"],
            "status": d["status"],
            "rc": int(d["rc"]),
            "tokens": parse_int(d["tokens"]),
            "ms": parse_int(d["ms"]),
            "raw": line.strip()
        })

    if args.all:
        filtered = rows
        window = "ALL"
    else:
        if args.since_hours is not None:
            cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=args.since_hours)
            filtered = [r for r in rows if r["ts"] >= cutoff]
            window = f"last {args.since_hours:g}h (UTC)"
        else:
            day = utc_today() if args.date is None else dt.date.fromisoformat(args.date)
            filtered = [r for r in rows if r["ts"].date() == day]
            window = f"{day.isoformat()} (UTC)"

    if args.json:
        import json
        out = {
            "log": str(path),
            "window": window,
            "total_lines": len(raw_lines),
            "parsed": len(rows),
            "filtered": len(filtered),
        }
        # quick totals
        out["ok"] = sum(1 for r in filtered if r["status"] == "ok" and r["rc"] == 0)
        out["empty"] = sum(1 for r in filtered if r["status"] != "ok" or r["rc"] != 0)
        toks = [r["tokens"] for r in filtered if isinstance(r["tokens"], int)]
        ms = [r["ms"] for r in filtered if isinstance(r["ms"], int)]
        out["tokens_total"] = sum(toks) if toks else 0
        out["tokens_avg"] = (sum(toks)/len(toks)) if toks else None
        out["ms_p50"] = percentile(ms, 50)
        out["ms_p95"] = percentile(ms, 95)
        print(json.dumps(out, ensure_ascii=False))
        return

    # -------- pretty text output --------
    total = len(filtered)
    ok = sum(1 for r in filtered if r["status"] == "ok" and r["rc"] == 0)
    empty = total - ok

    toks = [r["tokens"] for r in filtered if isinstance(r["tokens"], int)]
    ms = [r["ms"] for r in filtered if isinstance(r["ms"], int)]

    tokens_total = sum(toks) if toks else 0
    tokens_avg = (tokens_total/len(toks)) if toks else None

    ms_p50 = percentile(ms, 50)
    ms_p95 = percentile(ms, 95)
    ms_avg = (sum(ms)/len(ms)) if ms else None

    # per-model stats
    per = defaultdict(lambda: {"n":0,"ok":0,"tokens":[],"ms":[],"modes":defaultdict(int)})
    for r in filtered:
        s = per[r["model"]]
        s["n"] += 1
        if r["status"] == "ok" and r["rc"] == 0:
            s["ok"] += 1
        if isinstance(r["tokens"], int):
            s["tokens"].append(r["tokens"])
        if isinstance(r["ms"], int):
            s["ms"].append(r["ms"])
        s["modes"][r["mode"]] += 1

    # premium escalation estimate: model=premium-chat but mode != premium
    premium_total = sum(1 for r in filtered if r["model"] == "premium-chat")
    premium_forced = sum(1 for r in filtered if r["model"] == "premium-chat" and r["mode"] == "premium")
    premium_escalated = premium_total - premium_forced

    best_effort_total = sum(1 for r in filtered if r["model"] == "best-effort-chat")

    print(f"== cost summary ==")
    print(f"log: {path}")
    print(f"window: {window}")
    print(f"parsed: {len(rows)} / total_lines: {len(raw_lines)}  |  filtered: {total}")
    print("")
    print(f"requests: {total}  ok: {ok}  empty/fail: {empty}")
    print(f"tokens: total={tokens_total}  avg={tokens_avg:.2f}" if tokens_avg is not None else f"tokens: total={tokens_total}  avg=-")
    print(f"latency: avg={fmt_ms(ms_avg)}  p50={fmt_ms(ms_p50)}  p95={fmt_ms(ms_p95)}")
    print(f"premium-chat: {premium_total} (forced={premium_forced}, escalated≈{premium_escalated})  |  best-effort-chat: {best_effort_total}")
    print("")
    # table
    header = f"{'model':<18} {'n':>4} {'ok%':>5} {'tokens':>10} {'avg_tok':>8} {'p95_ms':>8} {'avg_ms':>8}"
    print(header)
    print("-"*len(header))

    def model_sort_key(item):
        model, s = item
        tok_sum = sum(s["tokens"]) if s["tokens"] else 0
        return (tok_sum, s["n"])

    for model, s in sorted(per.items(), key=model_sort_key, reverse=True):
        n = s["n"]
        okp = (100.0*s["ok"]/n) if n else 0.0
        tok_sum = sum(s["tokens"]) if s["tokens"] else 0
        tok_avg = (tok_sum/len(s["tokens"])) if s["tokens"] else None
        ms_p95_m = percentile(s["ms"], 95)
        ms_avg_m = (sum(s["ms"])/len(s["ms"])) if s["ms"] else None
        print(f"{model:<18} {n:>4} {okp:>4.0f}% {tok_sum:>10} {tok_avg:>8.2f} {fmt_ms(ms_p95_m):>8} {fmt_ms(ms_avg_m):>8}" if tok_avg is not None
              else f"{model:<18} {n:>4} {okp:>4.0f}% {tok_sum:>10} {'-':>8} {fmt_ms(ms_p95_m):>8} {fmt_ms(ms_avg_m):>8}")

if __name__ == "__main__":
    main()
