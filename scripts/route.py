#!/usr/bin/env python3
# __ROUTE_P4_EXPLAIN_V1__
import json, os, re, sys
from pathlib import Path

def load_rules(path: str) -> dict:
    p = Path(path)
    return json.loads(p.read_text(encoding='utf-8', errors='ignore'))

def as_list(x):
    if isinstance(x, list):
        return [str(i) for i in x]
    return []

def get(d, *keys, default=None):
    cur = d
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return default
    return cur

def find_mode(rules: dict, msg: str):
    text = msg or ''
    low = text.lower()
    n = len(text)

    long_min = (get(rules, 'routing', 'long_text_min_chars')
                or get(rules, 'long_text_min_chars')
                or 1200)
    try:
        long_min = int(long_min)
    except Exception:
        long_min = 1200

    coding_kw = as_list(get(rules, 'rules', 'coding', 'keywords', default=[])) or as_list(get(rules, 'coding', 'keywords', default=[]))
    hard_kw   = as_list(get(rules, 'rules', 'hard', 'keywords', default=[]))   or as_list(get(rules, 'hard', 'keywords', default=[]))

    coding_hit = [k for k in coding_kw if k and k.lower() in low]
    hard_hit   = [k for k in hard_kw if k and k.lower() in low]
    hit_long = n >= long_min

    # Priority (matches your Phase2 spec): long > coding > hard > daily
    if hit_long:
        mode = 'long'
        reason = f'length>={long_min}'
    elif coding_hit:
        mode = 'coding'
        reason = 'coding_keywords'
    elif hard_hit:
        mode = 'hard'
        reason = 'hard_keywords'
    else:
        mode = 'daily'
        reason = 'fallback'

    explain = {
        'input_len': n,
        'long_min': long_min,
        'coding_hits': coding_hit,
        'hard_hits': hard_hit,
        'priority': ['long','coding','hard','daily'],
        'reason': reason,
    }
    return mode, explain

def mode_to_model(rules: dict, mode: str) -> str:
    # try common mapping keys, then fallback
    mapping = (get(rules, 'mode_to_model') or get(rules, 'mode_model') or get(rules, 'models_by_mode') or {})
    if isinstance(mapping, dict) and mode in mapping:
        return str(mapping[mode])
    fallback = {
        'daily': 'default-chat',
        'coding': 'default-chat',
        'long': 'long-chat',
        'hard': 'best-effort-chat',
        'best-effort': 'best-effort-chat',
        'premium': 'premium-chat',
    }
    return fallback.get(mode, 'default-chat')

def pick_prefix(rules: dict, mode: str) -> str:
    pref = get(rules, 'prefix', default={})
    if isinstance(pref, dict):
        return str(pref.get(mode) or pref.get('default') or '')
    return ''

def escalation_chain(rules: dict):
    chain = get(rules, 'escalation', 'chain', default=[])
    if isinstance(chain, list) and chain:
        return [str(x) for x in chain]
    # safe default
    return ['best-effort-chat','premium-chat']

def main():
    # expected: route.py <rules_path> <mode> <msg>
    if len(sys.argv) < 4:
        raise SystemExit('usage: route.py <rules_path> <mode> <msg>')

    rules_path = sys.argv[1]
    mode_in = sys.argv[2]
    msg = sys.argv[3]

    rules = load_rules(rules_path)

    explain_on = os.getenv('ROUTER_EXPLAIN','0') == '1'

    if mode_in == 'auto':
        mode, explain = find_mode(rules, msg)
    else:
        mode = mode_in
        # still compute explain for visibility when enabled
        _, explain = find_mode(rules, msg)
        explain['reason'] = f'forced:{mode_in}'

    model = mode_to_model(rules, mode)
    prefix = pick_prefix(rules, mode)
    chain = escalation_chain(rules)
    log_file = str(get(rules, 'log_file', default='logs/ask_history.log'))

    out = {
        'mode': mode,
        'model': model,
        'prefix': prefix,
        'escalation': chain,
        'log_file': log_file,
    }
    if explain_on:
        out['explain'] = explain

    print(json.dumps(out, ensure_ascii=False))

if __name__ == '__main__':
    main()
