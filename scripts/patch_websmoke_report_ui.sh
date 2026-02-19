#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

gen_dir="$(ls -1dt apps/generated/websmoke__* 2>/dev/null | head -1 || true)"
[[ -n "$gen_dir" ]] || { echo "[fail] no apps/generated/websmoke__*"; exit 2; }
if [[ "$gen_dir" != /* ]]; then gen_dir="$ROOT/$gen_dir"; fi
[[ -d "$gen_dir" ]] || { echo "[fail] gen_dir not found: $gen_dir"; exit 3; }

echo "[info] patching: $gen_dir"

# -------------------------
# Home: add Latest Report CTA
# -------------------------
cat > "$gen_dir/app/page.tsx" <<'TSX'
'use client';

import React, { useEffect, useState } from 'react';

type IndexItem = {
  run_id: string;
  run_dir?: string;
  kind?: string;
  status?: string;
  start?: string;
  is_latest?: string | null;
};

function Card(props: React.PropsWithChildren<{ title?: string; right?: React.ReactNode; }>) {
  return (
    <div className="card" style={{ borderRadius: 18, padding: 18, marginTop: 14 }}>
      {(props.title || props.right) ? (
        <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12 }}>
          <div style={{ fontWeight: 900, fontSize: 18 }}>{props.title}</div>
          <div>{props.right}</div>
        </div>
      ) : null}
      <div style={{ marginTop: (props.title || props.right) ? 12 : 0 }}>
        {props.children}
      </div>
    </div>
  );
}

export default function HomePage() {
  const [latest, setLatest] = useState<IndexItem | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const res = await fetch('/runs_data/index.json', { cache: 'no-store' });
        const j = (await res.json()) as IndexItem[];
        if (j && j.length) setLatest(j[0]);
      } catch {}
    })();
  }, []);

  const latestHref = latest?.run_id ? `/runs/${latest.run_id}` : '/runs';

  return (
    <main>
      <h1 style={{ fontSize: 56, fontWeight: 950, letterSpacing: '-0.03em', margin: '10px 0 6px' }}>Home</h1>
      <div style={{ color: 'rgba(0,0,0,0.55)', fontWeight: 700 }}>Minimal site.</div>

      <Card title="Latest Report" right={
        <a href={latestHref} style={{ fontWeight: 900, textDecoration: 'underline' }}>Open</a>
      }>
        <div style={{ color:'rgba(0,0,0,0.6)', fontSize: 13 }}>
          {latest?.run_id ? (
            <>
              <div><b>run_id</b>: {latest.run_id}</div>
              <div><b>kind</b>: {latest.kind ?? '-'}</div>
              <div><b>status</b>: {latest.status ?? '-'}</div>
              <div><b>start</b>: {latest.start ?? '-'}</div>
            </>
          ) : (
            <>No runs_data/index.json yet. Run <code style={{ fontWeight: 900 }}>make web_smoke_open</code> first.</>
          )}
        </div>
      </Card>

      <Card title="Sections">
        <ul style={{ margin: 0, paddingLeft: 18 }}>
          <li>Hero</li>
          <li>CTA</li>
        </ul>
      </Card>

      <div style={{ marginTop: 26, color: 'rgba(0,0,0,0.45)', fontSize: 12 }}>Built with Next.js</div>
    </main>
  );
}
TSX

# -------------------------
# About: also add Latest Report CTA
# -------------------------
cat > "$gen_dir/app/about/page.tsx" <<'TSX'
'use client';

import React, { useEffect, useState } from 'react';

type IndexItem = { run_id: string; kind?: string; status?: string; start?: string; };

function Card(props: React.PropsWithChildren<{ title?: string; right?: React.ReactNode; }>) {
  return (
    <div className="card" style={{ borderRadius: 18, padding: 18, marginTop: 14 }}>
      {(props.title || props.right) ? (
        <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12 }}>
          <div style={{ fontWeight: 900, fontSize: 18 }}>{props.title}</div>
          <div>{props.right}</div>
        </div>
      ) : null}
      <div style={{ marginTop: (props.title || props.right) ? 12 : 0 }}>
        {props.children}
      </div>
    </div>
  );
}

export default function AboutPage() {
  const [latest, setLatest] = useState<IndexItem | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const res = await fetch('/runs_data/index.json', { cache: 'no-store' });
        const j = (await res.json()) as IndexItem[];
        if (j && j.length) setLatest(j[0]);
      } catch {}
    })();
  }, []);

  const latestHref = latest?.run_id ? `/runs/${latest.run_id}` : '/runs';

  return (
    <main>
      <h1 style={{ fontSize: 56, fontWeight: 950, letterSpacing: '-0.03em', margin: '10px 0 6px' }}>About</h1>
      <div style={{ color: 'rgba(0,0,0,0.55)', fontWeight: 700 }}>Minimal site.</div>

      <Card title="Latest Report" right={<a href={latestHref} style={{ fontWeight: 900, textDecoration: 'underline' }}>Open</a>}>
        <div style={{ color:'rgba(0,0,0,0.6)', fontSize: 13 }}>
          {latest?.run_id ? (
            <>
              <div><b>run_id</b>: {latest.run_id}</div>
              <div><b>kind</b>: {latest.kind ?? '-'}</div>
              <div><b>status</b>: {latest.status ?? '-'}</div>
              <div><b>start</b>: {latest.start ?? '-'}</div>
            </>
          ) : (
            <>No runs yet.</>
          )}
        </div>
      </Card>

      <Card title="Sections">
        <ul style={{ margin: 0, paddingLeft: 18 }}>
          <li>Bio</li>
          <li>Links</li>
        </ul>
      </Card>

      <div style={{ marginTop: 26, color: 'rgba(0,0,0,0.45)', fontSize: 12 }}>Built with Next.js</div>
    </main>
  );
}
TSX

# -------------------------
# /runs list: enforce View column to /runs/<id>
# -------------------------
cat > "$gen_dir/app/runs/page.tsx" <<'TSX'
'use client';

import React, { useEffect, useMemo, useState } from 'react';

type Row = Record<string, any>;

function safeText(v: any, fallback: string = '-') {
  if (v === undefined || v === null) return fallback;
  const s = String(v);
  return s.trim() === '' ? fallback : s;
}

function parseCSV(text: string): Row[] {
  const lines = text.trim().split(/\r?\n/);
  if (lines.length < 2) return [];
  const headers = lines[0].split(',').map(s => s.trim());
  const rows: Row[] = [];
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(',');
    const r: Row = {};
    headers.forEach((h, idx) => (r[h] = (cols[idx] ?? '').trim()));
    const rd = String(r['run_dir'] ?? '');
    r['run_id'] = rd.split('/').filter(Boolean).pop() ?? '';
    rows.push(r);
  }
  return rows;
}

export default function RunsPage() {
  const [rows, setRows] = useState<Row[]>([]);
  const [q, setQ] = useState('');

  async function load() {
    const res = await fetch('/runs_summary_v3.csv', { cache: 'no-store' });
    const txt = await res.text();
    setRows(parseCSV(txt));
  }

  useEffect(() => { load(); }, []);

  const filtered = useMemo(() => {
    const qq = q.trim().toLowerCase();
    if (!qq) return rows;
    return rows.filter(r => JSON.stringify(r).toLowerCase().includes(qq));
  }, [rows, q]);

  return (
    <main>
      <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12, margin: '14px 0' }}>
        <div>
          <h1 style={{ fontSize: 44, fontWeight: 950, letterSpacing: '-0.02em', margin: 0 }}>Runs Dashboard</h1>
          <div style={{ marginTop: 10, color: 'rgba(0,0,0,0.55)' }}>Source: /runs_summary_v3.csv</div>
        </div>
        <button
          className="card"
          style={{ padding: '10px 14px', borderRadius: 999, fontWeight: 900, cursor:'pointer' }}
          onClick={load}
        >
          Refresh
        </button>
      </div>

      <div className="card" style={{ padding: 14, borderRadius: 18 }}>
        <div style={{ display:'flex', alignItems:'center', gap: 12 }}>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search... (kind / status / run_dir / step)"
            style={{
              width:'100%',
              padding:'12px 14px',
              borderRadius: 14,
              border: '1px solid rgba(0,0,0,0.10)',
              outline: 'none',
              fontSize: 14
            }}
          />
          <div style={{ color:'rgba(0,0,0,0.45)', fontWeight: 900, fontSize: 12 }}>{filtered.length} rows</div>
        </div>
      </div>

      <div className="card" style={{ marginTop: 14, padding: 0, borderRadius: 18, overflow:'hidden' }}>
        <div style={{ overflowX:'auto' }}>
          <table style={{ width:'100%', borderCollapse:'separate', borderSpacing: 0 }}>
            <thead>
              <tr style={{ textAlign:'left', fontSize: 12, color:'rgba(0,0,0,0.55)' }}>
                {['is_latest','kind','status','start','duration_s','mode','model','last_step','run_dir','view'].map(h => (
                  <th key={h} style={{ padding:'12px 14px', borderBottom:'1px solid rgba(0,0,0,0.06)', whiteSpace:'nowrap' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filtered.map((r, idx) => (
                <tr key={idx} style={{ background: idx === 0 ? 'rgba(0,122,255,0.06)' : 'transparent' }}>
                  {['is_latest','kind','status','start','duration_s','mode','model','last_step','run_dir'].map((c) => (
                    <td key={c} style={{ padding:'12px 14px', borderBottom:'1px solid rgba(0,0,0,0.05)', whiteSpace:'nowrap' }}>
                      {safeText(r[c])}
                    </td>
                  ))}
                  <td style={{ padding:'12px 14px', borderBottom:'1px solid rgba(0,0,0,0.05)', whiteSpace:'nowrap' }}>
                    <a href={`/runs/${safeText(r['run_id'], '')}`} style={{ fontWeight: 950, textDecoration:'underline' }}>
                      View
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div style={{ padding:'12px 14px', color:'rgba(0,0,0,0.45)', fontSize: 12 }}>
          Tip: use “View” to open /runs/&lt;id&gt;.
        </div>
      </div>
    </main>
  );
}
TSX

# -------------------------
# /runs/[id] report: Apple-style + collapse raw JSON
# -------------------------
mkdir -p "$gen_dir/app/runs/[id]"

cat > "$gen_dir/app/runs/[id]/page.tsx" <<'TSX'
'use client';

import React, { useEffect, useMemo, useState } from 'react';

type AnyObj = Record<string, any>;

function pill(ok: boolean) {
  return {
    display:'inline-flex',
    alignItems:'center',
    padding:'6px 10px',
    borderRadius: 999,
    fontWeight: 950,
    fontSize: 12,
    background: ok ? 'rgba(52,199,89,0.15)' : 'rgba(255,59,48,0.12)',
    border: `1px solid ${ok ? 'rgba(52,199,89,0.28)' : 'rgba(255,59,48,0.22)'}`,
  } as React.CSSProperties;
}

function Card(props: React.PropsWithChildren<{ title: string; right?: React.ReactNode; }>) {
  return (
    <div className="card" style={{ borderRadius: 18, padding: 18, marginTop: 14 }}>
      <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12 }}>
        <div style={{ fontWeight: 950, fontSize: 18 }}>{props.title}</div>
        <div>{props.right}</div>
      </div>
      <div style={{ marginTop: 12 }}>{props.children}</div>
    </div>
  );
}

function KV(props: { k: string; v: any }) {
  return (
    <div style={{ display:'flex', justifyContent:'space-between', gap: 12, padding:'8px 0', borderBottom:'1px solid rgba(0,0,0,0.06)' }}>
      <div style={{ color:'rgba(0,0,0,0.55)', fontWeight: 850 }}>{props.k}</div>
      <div style={{ fontWeight: 900, maxWidth: '70%', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap' }}>
        {props.v === undefined || props.v === null || String(props.v).trim() === '' ? '-' : String(props.v)}
      </div>
    </div>
  );
}

async function fetchJsonTry(urls: string[]) {
  for (const u of urls) {
    try {
      const res = await fetch(u, { cache: 'no-store' });
      if (!res.ok) continue;
      return await res.json();
    } catch {}
  }
  return null;
}

export default function RunReportPage({ params }: { params: { id: string } }) {
  const id = params.id;
  const [data, setData] = useState<AnyObj | null>(null);

  async function load() {
    const j = await fetchJsonTry([
      `/runs_data/${id}.json`,
      `/runs_data/run_${id}.json`,
    ]);
    setData(j);
  }

  useEffect(() => { load(); }, [id]);

  const summary = useMemo(() => {
    if (!data) return null;
    return (data.summary ?? data) as AnyObj;
  }, [data]);

  const verify = useMemo(() => (data?.verify ?? data?.verify_summary ?? null) as AnyObj | null, [data]);
  const meta = useMemo(() => (data?.meta ?? null) as AnyObj | null, [data]);
  const events = useMemo(() => (data?.events_tail ?? data?.events ?? null), [data]);

  const ok = String(summary?.status ?? '').toLowerCase() === 'ok' || Boolean(verify?.ok);

  const verifyHash = verify?.plan_hash ?? null;
  const metaHash = meta?.plan_hash ?? null;
  const hashMismatch = verifyHash && metaHash && String(verifyHash) !== String(metaHash);

  async function copy(text: string) {
    try { await navigator.clipboard.writeText(text); } catch {}
  }

  return (
    <main>
      <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12, margin: '14px 0' }}>
        <div>
          <div style={{ display:'flex', alignItems:'center', gap: 10 }}>
            <h1 style={{ fontSize: 44, fontWeight: 950, letterSpacing:'-0.02em', margin: 0 }}>Run Report</h1>
            <span style={pill(ok)}>{ok ? 'ok' : 'fail'}</span>
          </div>
          <div style={{ marginTop: 10, color:'rgba(0,0,0,0.55)' }}>{id}</div>
        </div>
        <div style={{ display:'flex', gap: 10 }}>
          <a className="card" href="/runs" style={{ padding:'10px 14px', borderRadius: 999, fontWeight: 950, textDecoration:'none' }}>Back</a>
          <button className="card" onClick={load} style={{ padding:'10px 14px', borderRadius: 999, fontWeight: 950, cursor:'pointer' }}>Refresh</button>
        </div>
      </div>

      {!data ? (
        <div className="card" style={{ borderRadius: 18, padding: 18 }}>
          <div style={{ fontWeight: 900 }}>Loading…</div>
          <div style={{ marginTop: 8, color:'rgba(0,0,0,0.55)', fontSize: 13 }}>
            If this keeps loading, check the file exists: <code style={{ fontWeight: 900 }}>public/runs_data/run_{id}.json</code>
          </div>
        </div>
      ) : (
        <>
          <Card title="Summary" right={
            summary?.run_dir ? (
              <button
                className="card"
                style={{ padding:'8px 12px', borderRadius: 999, fontWeight: 950, cursor:'pointer' }}
                onClick={() => copy(String(summary.run_dir))}
              >
                Copy run_dir
              </button>
            ) : null
          }>
            {['kind','status','start','duration_s','last_step','mode','model','run_dir'].map((k) => (
              <KV key={k} k={k} v={summary?.[k]} />
            ))}
            {hashMismatch ? (
              <div style={{ marginTop: 12, color:'rgba(255,59,48,0.9)', fontWeight: 950 }}>
                ⚠ plan_hash mismatch (verify vs meta)
              </div>
            ) : null}
          </Card>

          <Card title="Verify" right={verify?.ok !== undefined ? <span style={pill(Boolean(verify.ok))}>{String(verify.ok)}</span> : null}>
            {verify ? (
              <>
                {Object.keys(verify).slice(0, 8).map((k) => <KV key={k} k={k} v={verify[k]} />)}
                <details style={{ marginTop: 12 }}>
                  <summary style={{ fontWeight: 950, cursor:'pointer' }}>Raw JSON</summary>
                  <pre style={{ marginTop: 10, whiteSpace:'pre-wrap', fontSize: 12 }}>{JSON.stringify(verify, null, 2)}</pre>
                </details>
              </>
            ) : (
              <div style={{ color:'rgba(0,0,0,0.55)' }}>No verify payload.</div>
            )}
          </Card>

          <Card title="Meta">
            {meta ? (
              <>
                {Object.keys(meta).slice(0, 10).map((k) => <KV key={k} k={k} v={meta[k]} />)}
                <details style={{ marginTop: 12 }}>
                  <summary style={{ fontWeight: 950, cursor:'pointer' }}>Raw JSON</summary>
                  <pre style={{ marginTop: 10, whiteSpace:'pre-wrap', fontSize: 12 }}>{JSON.stringify(meta, null, 2)}</pre>
                </details>
              </>
            ) : (
              <div style={{ color:'rgba(0,0,0,0.55)' }}>No meta payload.</div>
            )}
          </Card>

          <Card title="Events Tail">
            {events ? (
              <pre style={{ margin: 0, whiteSpace:'pre-wrap', fontSize: 12 }}>{typeof events === 'string' ? events : JSON.stringify(events, null, 2)}</pre>
            ) : (
              <div style={{ color:'rgba(0,0,0,0.55)' }}>No events captured.</div>
            )}
          </Card>

          <details style={{ marginTop: 14 }}>
            <summary style={{ fontWeight: 950, cursor:'pointer' }}>Full payload (Raw)</summary>
            <pre style={{ marginTop: 10, whiteSpace:'pre-wrap', fontSize: 12 }}>{JSON.stringify(data, null, 2)}</pre>
          </details>
        </>
      )}

      <div style={{ marginTop: 26, color: 'rgba(0,0,0,0.45)', fontSize: 12 }}>Built with Next.js</div>
    </main>
  );
}
TSX

echo "[info] rebuilding..."
( cd "$gen_dir" && npm run build )

echo "[ok] patched report UI: $gen_dir"
echo "[tip] open: http://localhost:3000/runs  (then View)"
