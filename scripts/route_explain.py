#!/usr/bin/env python3
import os, sys, json

def main():
    if len(sys.argv) < 3:
        print('usage: route_explain.py <rules_path> <explain>', file=sys.stderr)
        return 2
    explain = int(sys.argv[2])

    raw = sys.stdin.read().strip()
    data = json.loads(raw) if raw else {}

    mode = data.get('mode','unknown')
    model = data.get('model','unknown')
    esc = data.get('escalation') or []
    esc_str = '->'.join(esc) if isinstance(esc, list) and esc else '-'
    print(f'mode={mode} model={model} escalation={esc_str}')

    if not explain:
        return 0

    ex = data.get('explain')
    if isinstance(ex, dict):
        print('explain:')
        print(f"  input_len: {ex.get('input_len','-')}  long_min: {ex.get('long_min','-')}")
        print(f"  coding_hits: {ex.get('coding_hits',[])}")
        print(f"  hard_hits: {ex.get('hard_hits',[])}")
        print(f"  coding_kw_count: {ex.get('coding_kw_count','-')}  sample: {ex.get('coding_kw_sample',[])}")
        print(f"  hard_kw_count: {ex.get('hard_kw_count','-')}  sample: {ex.get('hard_kw_sample',[])}")
        print(f"  priority: {ex.get('priority',[])}")
        print(f"  reason: {ex.get('reason','-')}")
        print(f"  route_result: mode={mode} model={model}")
        return 0

    # fallback (should rarely happen now)
    text = os.environ.get('ROUTE_TEXT','')
    print('explain:')
    print(f'  input_len: {len(text)} (fallback: ROUTE_TEXT)')
    print('  note: route.py did not include explain; set ROUTER_EXPLAIN=1')
    print(f'  route_result: mode={mode} model={model}')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
