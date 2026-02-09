#!/usr/bin/env python3
# __ROUTE_SCHEMA_AGNOSTIC_V2__
import json, os, sys
from pathlib import Path

def load_rules(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding='utf-8', errors='ignore'))

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
        return [str(i) for i in x if isinstance(i, (str,int,float))]
    if isinstance(x, str) and x.strip():
        return [x.strip()]
    return []

def find_key_anywhere(obj, target_key: str):
    """Return list of values for dict entries where key==target_key (recursive)."""
    found=[]
    if isinstance(obj, dict):
        for k,v in obj.items():
            if k == target_key:
                found.append(v)
            found.extend(find_key_anywhere(v, target_key))
    elif isinstance(obj, list):
        for it in obj:
            found.extend(find_key_anywhere(it, target_key))
    return found

def pick_mode_section(rules: dict, mode_name: str):
    """Try common paths, otherwise pick the first dict found under key=mode_name."""
    # common paths first
    for path in [
        ('rules', mode_name),
        ('routing', 'rules', mode_name),
        ('modes', mode_name),
        ('router', 'rules', mode_name),
    ]:
        sec = get(rules, *path, default=None)
        if isinstance(sec, dict):
            return sec

    # fallback: anywhere key==mode_name and value is dict
    vals = find_key_anywhere(rules, mode_name)
    for v in vals:
        if isinstance(v, dict):
            return v
    return {}

def collect_keywords(section: dict):
    """Collect list[str] from many schema styles inside section."""
    kw=[]
    if not isinstance(section, dict):
        return kw

    # direct common keys
    for k in ('keywords','keyword','kw','contains','includes'):
        kw.extend(as_list(section.get(k)))

    # match blocks like: match: { any:[...], contains:[...] }
    m = section.get('match')
    if isinstance(m, dict):
        for k in ('any','contains','includes','keywords'):
            kw.extend(as_list(m.get(k)))

    # deeper: conditions / rules arrays (rare but possible)
    # we scan for key name 'keywords' inside section recursively
    for v in find_key_anywhere(section, 'keywords'):
        kw.extend(as_list(v))

    # normalize: lowercase unique keep order
    seen=set()
    out=[]
    for x in kw:
        s=str(x).strip()
        if not s:
            continue
        s=s.lower()
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out

def get_long_min(rules: dict) -> int:
    for path in [
        ('routing','long_text_min_chars'),
        ('long_text_min_chars',),
        ('rules','long','min_chars'),
        ('long','min_chars'),
    ]:
        v = get(rules, *path, default=None)
        if v is not None:
            try:
                return int(v)
            except Exception:
                pass
    return 1200

def mode_to_model(rules: dict, mode: str) -> str:
    mapping = (get(rules,'mode_to_model') or get(rules,'mode_model') or get(rules,'models_by_mode') or get(rules,'models') or {})
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
    pref = (get(rules,'prefix') or get(rules,'prefixes') or get(rules,'system_prefix') or get(rules,'system_prompts') or {})
    if isinstance(pref, dict):
        return str(pref.get(mode) or pref.get('default') or '')
    return ''

def escalation_chain(rules: dict):
    chain = get(rules,'escalation','chain', default=None)
    if isinstance(chain, list) and chain:
        return [str(x) for x in chain]
    # keep your previous default
    return ['best-effort-chat','premium-chat']

def find_mode(rules: dict, msg: str):
    text = msg or ''
    low = text.lower()
    n = len(text)

    long_min = get_long_min(rules)

    coding_sec = pick_mode_section(rules, 'coding')
    hard_sec = pick_mode_section(rules, 'hard')

    coding_kw = collect_keywords(coding_sec)
    hard_kw   = collect_keywords(hard_sec)

    coding_hit = [k for k in coding_kw if k in low]
    hard_hit   = [k for k in hard_kw if k in low]
    hit_long = n >= long_min

    # Priority (Phase2 spec): long > coding > hard > daily
    if hit_long:
        mode='long'; reason=f'length>={long_min}'
    elif coding_hit:
        mode='coding'; reason='coding_keywords'
    elif hard_hit:
        mode='hard'; reason='hard_keywords'
    else:
        mode='daily'; reason='fallback'

    explain = {
        'input_len': n,
        'long_min': long_min,
        'coding_hits': coding_hit,
        'hard_hits': hard_hit,
        'coding_kw_count': len(coding_kw),
        'hard_kw_count': len(hard_kw),
        'coding_kw_sample': coding_kw[:8],
        'hard_kw_sample': hard_kw[:8],
        'priority': ['long','coding','hard','daily'],
        'reason': reason,
    }
    return mode, explain

def main():
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
        _, explain = find_mode(rules, msg)
        explain['reason'] = f'forced:{mode_in}'

    model = mode_to_model(rules, mode)
    prefix = pick_prefix(rules, mode)
    chain = escalation_chain(rules)
    log_file = str(get(rules,'log_file', default='logs/ask_history.log'))

    out = {'mode': mode, 'model': model, 'prefix': prefix, 'escalation': chain, 'log_file': log_file}
    if explain_on:
        out['explain'] = explain
    print(json.dumps(out, ensure_ascii=False))

if __name__ == '__main__':
    main()
