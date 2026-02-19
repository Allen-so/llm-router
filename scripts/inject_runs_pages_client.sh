#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

gen_dir="${1:-}"
if [[ -z "$gen_dir" ]]; then
  gen_dir="$(bash scripts/pick_latest_websmoke_dir.sh)"
fi
if [[ "$gen_dir" != /* ]]; then gen_dir="$ROOT/$gen_dir"; fi
[[ -d "$gen_dir" ]] || { echo "[fail] gen_dir not found: $gen_dir" >&2; exit 2; }

mkdir -p "$gen_dir/app/runs" "$gen_dir/app/runs/[id]"

# ---------------- /runs (client fetch index.json) ----------------
cat > "$gen_dir/app/runs/page.tsx" <<'TSX'
'use client';

import React, { useEffect, useMemo, useState } from 'react';

type IndexItem = {
  run_id: string;
  run_dir?: string;
  kind?: string;
  status?: string;
  start?: string;
};

function badge(status?: string) {
  const s = (status || 'unknown').toLowerCase();
  const ok = s === 'ok';
  return (
    <span style={{
      display: 'inline-block',
      padding: '4px 10px',
      borderRadius: 999,
      fontSize: 12,
      border: '1px solid rgba(0,0,0,0.12)',
      background: ok ? 'rgba(34,197,94,0.12)' : 'rgba(239,68,68,0.12)',
      color: ok ? 'rgb(21,128,61)' : 'rgb(185,28,28)',
      marginLeft: 10
    }}>
      {s}
    </span>
  );
}

export default function RunsPage() {
  const [items, setItems] = useState<IndexItem[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const r = await fetch(`/runs_data/index.json?t=${Date.now()}`, { cache: 'no-store' });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const j = await r.json();
        setItems(Array.isArray(j) ? j : []);
      } catch (e: any) {
        setErr(String(e?.message || e));
        setItems([]);
      }
    })();
  }, []);

  const sorted = useMemo(() => {
    const arr = items || [];
    return [...arr].sort((a, b) => (b.start || '').localeCompare(a.start || ''));
  }, [items]);

  return (
    <main style={{ maxWidth: 980, margin: '40px auto', padding: '0 16px' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
        <h1 style={{ fontSize: 44, fontWeight: 900, letterSpacing: '-0.02em' }}>Runs</h1>
        <button
          onClick={() => location.reload()}
          style={{ border: '1px solid rgba(0,0,0,0.12)', borderRadius: 999, padding: '10px 16px', background: 'white', fontWeight: 700 }}
        >
          Refresh
        </button>
      </div>

      <div style={{ marginTop: 14, color: 'rgba(0,0,0,0.6)' }}>
        {err ? `Load error: ${err}` : items === null ? 'Loading...' : `${sorted.length} items`}
      </div>

      <div style={{ marginTop: 18, display: 'grid', gap: 12 }}>
        {sorted.map((it) => (
          <div key={it.run_id} style={{
            border: '1px solid rgba(0,0,0,0.10)',
            borderRadius: 16,
            padding: 16,
            background: 'rgba(255,255,255,0.7)'
          }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <div style={{ fontWeight: 900 }}>
                {it.run_id}
                {badge(it.status)}
              </div>
              <a href={`/runs/${it.run_id}`} style={{ fontWeight: 800, textDecoration: 'none' }}>View →</a>
            </div>
            <div style={{ marginTop: 8, fontSize: 13, color: 'rgba(0,0,0,0.6)' }}>
              kind={it.kind || '-'} · start={it.start || '-'}
            </div>
          </div>
        ))}
      </div>
    </main>
  );
}
TSX

# ---------------- /runs/[id] (client fetch run detail) ----------------
cat > "$gen_dir/app/runs/[id]/page.tsx" <<'TSX'
'use client';

import React, { useEffect, useMemo, useState } from 'react';

type RunDetail = {
  run_id: string;
  index?: any;
  meta?: any;
  verify?: any;
  verify_payload?: any;
  events_tail?: any;
};

function truthyOk(v: any): boolean | null {
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return !!v;
  if (typeof v === 'string') {
    const s = v.trim().toLowerCase();
    if (['true','ok','pass','passed','success','1','yes'].includes(s)) return true;
    if (['false','fail','failed','error','0','no'].includes(s)) return false;
  }
  return null;
}

function inferStatus(d: RunDetail | null): string {
  const metaS = (d?.meta?.status || '').toString().trim().toLowerCase();
  const idxS  = (d?.index?.status || '').toString().trim().toLowerCase();
  if (metaS && metaS !== 'unknown') return metaS;
  if (idxS && idxS !== 'unknown') return idxS;

  const v = d?.verify_payload ?? d?.verify;
  const okv = truthyOk(v?.ok);
  if (okv === true) return 'ok';
  if (okv === false) return 'fail';
  return 'unknown';
}

function badge(status: string) {
  const s = (status || 'unknown').toLowerCase();
  const ok = s === 'ok';
  return (
    <span style={{
      display: 'inline-block',
      padding: '4px 10px',
      borderRadius: 999,
      fontSize: 12,
      border: '1px solid rgba(0,0,0,0.12)',
      background: ok ? 'rgba(34,197,94,0.12)' : 'rgba(239,68,68,0.12)',
      color: ok ? 'rgb(21,128,61)' : 'rgb(185,28,28)',
      marginLeft: 10
    }}>
      {s}
    </span>
  );
}

type Props = { params: { id: string } };

export default function RunPage({ params }: Props) {
  const id = params.id;
  const [data, setData] = useState<RunDetail | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      setErr(null);
      try {
        const r = await fetch(`/runs_data/${id}.json?t=${Date.now()}`, { cache: 'no-store' });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const j = (await r.json()) as RunDetail;
        setData(j);
      } catch (e: any) {
        setErr(String(e?.message || e));
        setData(null);
      }
    })();
  }, [id]);

  const status = useMemo(() => inferStatus(data), [data]);

  const summary = useMemo(() => {
    const meta = data?.meta || {};
    const idx  = data?.index || {};
    return {
      kind: meta.kind || idx.kind || '-',
      status,
      start: meta.ts || meta.ts_utc || idx.start || '-',
      duration_s: meta.duration_s ?? idx.duration_s ?? '-',
      last_step: meta.last_step ?? idx.last_step ?? '-',
      mode: meta.mode ?? idx.mode ?? '-',
      model: meta.model ?? idx.model ?? '-',
      run_dir: idx.run_dir || meta.run_dir || '-',
    };
  }, [data, status]);

  const verify = useMemo(() => (data?.verify_payload ?? data?.verify ?? null), [data]);

  return (
    <main style={{ maxWidth: 980, margin: '40px auto', padding: '0 16px' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
        <div>
          <h1 style={{ fontSize: 54, fontWeight: 900, letterSpacing: '-0.02em' }}>
            Run Report {badge(status)}
          </h1>
          <div style={{ marginTop: 6, color: 'rgba(0,0,0,0.55)' }}>{id}</div>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <button
            onClick={() => history.back()}
            style={{ border: '1px solid rgba(0,0,0,0.12)', borderRadius: 999, padding: '10px 16px', background: 'white', fontWeight: 800 }}
          >
            Back
          </button>
          <button
            onClick={() => location.reload()}
            style={{ border: '1px solid rgba(0,0,0,0.12)', borderRadius: 999, padding: '10px 16px', background: 'white', fontWeight: 800 }}
          >
            Refresh
          </button>
        </div>
      </div>

      {err && (
        <div style={{ marginTop: 16, padding: 14, borderRadius: 14, border: '1px solid rgba(239,68,68,0.25)', background: 'rgba(239,68,68,0.08)' }}>
          Load error: {err}
        </div>
      )}

      <section style={{ marginTop: 18, border: '1px solid rgba(0,0,0,0.10)', borderRadius: 18, background: 'rgba(255,255,255,0.7)', overflow: 'hidden' }}>
        <div style={{ padding: 16, fontWeight: 900, fontSize: 18 }}>Summary</div>
        <div style={{ borderTop: '1px solid rgba(0,0,0,0.06)' }}>
          {Object.entries(summary).map(([k, v]) => (
            <div key={k} style={{ display: 'flex', justifyContent: 'space-between', gap: 12, padding: '10px 16px', borderTop: '1px solid rgba(0,0,0,0.06)' }}>
              <div style={{ color: 'rgba(0,0,0,0.60)', fontWeight: 700 }}>{k}</div>
              <div style={{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' }}>{String(v)}</div>
            </div>
          ))}
        </div>
      </section>

      <section style={{ marginTop: 18, border: '1px solid rgba(0,0,0,0.10)', borderRadius: 18, background: 'rgba(255,255,255,0.7)' }}>
        <div style={{ padding: 16, fontWeight: 900, fontSize: 18 }}>Verify</div>
        <div style={{ padding: '0 16px 16px 16px', color: 'rgba(0,0,0,0.65)' }}>
          {verify ? (
            <pre style={{ margin: 0, padding: 12, borderRadius: 12, background: 'rgba(0,0,0,0.04)', overflow: 'auto' }}>
              {JSON.stringify(verify, null, 2)}
            </pre>
          ) : (
            <div>No verify payload.</div>
          )}
        </div>
      </section>

      <details style={{ marginTop: 18 }}>
        <summary style={{ cursor: 'pointer', fontWeight: 900 }}>Raw JSON</summary>
        <pre style={{ marginTop: 10, padding: 12, borderRadius: 12, background: 'rgba(0,0,0,0.04)', overflow: 'auto' }}>
          {data ? JSON.stringify(data, null, 2) : 'null'}
        </pre>
      </details>
    </main>
  );
}
TSX

echo "[ok] injected client-fetch /runs + /runs/[id] into: $gen_dir"
