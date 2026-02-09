#!/usr/bin/env python3
import os, sys, json
from pathlib import Path

def get(d, *keys, default=None):
    cur = d
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return default
    return cur

def as_list(x):
    if isinstance(x, list):
        return [str(i) for i in x]
    return []

def main():
    # argv: <rules_path> <explain:0|1>
    if len(sys.argv) < 3:
        print('usage: route_explain.py <rules_path> <explain>', file=sys.stderr)
        return 2
    rules_path = Path(sys.argv[1])
    explain = int(sys.argv[2])

    raw = sys.stdin.read().strip()
    data = json.loads(raw) if raw else {}
    mode = data.get('mode', 'unknown')
    model = data.get('model', 'unknown')
    esc = data.get('escalation') or data.get('escalation_chain') or []
    esc_str = '->'.join(esc) if isinstance(esc, list) and esc else '-'
    print(f"mode={mode} model={model} escalation={esc_str}")

    if not explain:
        return 0

    text = os.environ.get('ROUTE_TEXT', '')
    txt = text.lower()
    l = len(text)

    try:
        rules = json.loads(rules_path.read_text(encoding='utf-8', errors='ignore'))
    except Exception:
        rules = {}

    # long threshold: try common locations, fallback 1200
    long_min = (get(rules, 'routing', 'long_text_min_chars')
                or get(rules, 'long_text_min_chars')
                or 1200)
    try:
        long_min = int(long_min)
    except Exception:
        long_min = 1200

    # keywords: best-effort schema
    coding_kw = as_list(get(rules, 'rules', 'coding', 'keywords', default=[])) or as_list(get(rules, 'coding', 'keywords', default=[]))
    hard_kw   = as_list(get(rules, 'rules', 'hard', 'keywords', default=[]))   or as_list(get(rules, 'hard', 'keywords', default=[]))

    coding_hit = [k for k in coding_kw if k and k.lower() in txt]
    hard_hit   = [k for k in hard_kw if k and k.lower() in txt]
    hit_long = l >= long_min

    print('explain:')
    print(f'  length_chars: {l} (long_min={long_min}) -> ' + ('long' if hit_long else 'not long'))
    print(f'  coding_keywords_hit: {coding_hit}')
    print(f'  hard_keywords_hit: {hard_hit}')

    # Phase2 priority assumption: long > coding > hard > daily
    guess = 'daily'
    if hit_long:
        guess = 'long'
    elif coding_hit:
        guess = 'coding'
    elif hard_hit:
        guess = 'hard'
    print(f'  rule_priority_guess: {guess}')
    print(f'  route_result: mode={mode} model={model}')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
