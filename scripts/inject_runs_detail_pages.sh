#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

gen_dir="${1:-}"
if [[ -z "$gen_dir" ]]; then
  gen_dir="$(ls -1dt apps/generated/websmoke__* 2>/dev/null | head -1 || true)"
fi
[[ -n "$gen_dir" ]] || { echo "[fail] no websmoke__* dir"; exit 2; }
if [[ "$gen_dir" != /* ]]; then gen_dir="$ROOT/$gen_dir"; fi
[[ -d "$gen_dir" ]] || { echo "[fail] gen_dir not found: $gen_dir"; exit 2; }

mkdir -p "$gen_dir/app/runs" "$gen_dir/app/runs/[id]"

# ---------------- /runs (server) ----------------
cat > "$gen_dir/app/runs/page.tsx" <<'TSX'
import fs from 'fs';
import path from 'path';
import Link from 'next/link';

type Row = Record<string, any>;

function readJson(p: string): any | null {
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')); } catch { return null; }
}

function safe(v: any, fb = '-') {
  if (v === undefined || v === null) return fb;
  const s = String(v);
  return s.trim() === '' ? fb : s;
}

export const dynamic = 'force-dynamic';

export default function RunsPage() {
  const root = process.cwd();
  const idxPath = path.join(root, 'public', 'runs_data', 'index.json');
  const rows = (readJson(idxPath) ?? []) as Row[];

  return (
    <main>
      <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12, margin:'14px 0' }}>
        <div>
          <h1 style={{ fontSize: 52, fontWeight: 950, letterSpacing:'-0.03em', margin: 0 }}>Runs Dashboard</h1>
          <div style={{ marginTop: 10, color:'rgba(0,0,0,0.55)' }}>
            Source: <code style={{ fontWeight: 900 }}>/runs_data/index.json</code>
          </div>
        </div>
        <a
          href="/runs"
          style={{ textDecoration:'none', fontWeight: 950, padding:'10px 14px', borderRadius: 999,
                   border:'1px solid rgba(0,0,0,0.08)', background:'white' }}
        >
          Refresh
        </a>
      </div>

      <div style={{ border:'1px solid rgba(0,0,0,0.08)', background:'rgba(255,255,255,0.72)', borderRadius: 18, overflow:'hidden' }}>
        <div style={{ overflowX:'auto' }}>
          <table style={{ width:'100%', borderCollapse:'collapse', fontSize: 14 }}>
            <thead>
              <tr style={{ textAlign:'left', color:'rgba(0,0,0,0.55)', background:'rgba(0,0,0,0.02)' }}>
                {['is_latest','kind','status','start','duration_s','mode','model','last_step','run_dir'].map(h => (
                  <th key={h} style={{ padding:'14px 14px', fontWeight: 900, borderBottom:'1px solid rgba(0,0,0,0.06)' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => {
                const runId = safe(r.run_id, '');
                const href = runId ? `/runs/${encodeURIComponent(runId)}` : '#';
                const ok = String(r.status ?? '').toLowerCase() === 'ok';
                return (
                  <tr key={i} style={{ borderTop:'1px solid rgba(0,0,0,0.06)' }}>
                    <td style={{ padding:'12px 14px', fontWeight: 900 }}>{safe(r.is_latest)}</td>
                    <td style={{ padding:'12px 14px' }}>{safe(r.kind)}</td>
                    <td style={{ padding:'12px 14px' }}>
                      <span style={{
                        display:'inline-flex', alignItems:'center',
                        padding:'6px 10px', borderRadius: 999, fontWeight: 950, fontSize: 12,
                        background: ok ? 'rgba(52,199,89,0.15)' : 'rgba(255,59,48,0.12)',
                        border: `1px solid ${ok ? 'rgba(52,199,89,0.28)' : 'rgba(255,59,48,0.22)'}`,
                      }}>
                        {safe(r.status)}
                      </span>
                    </td>
                    <td style={{ padding:'12px 14px' }}>{safe(r.start)}</td>
                    <td style={{ padding:'12px 14px', fontFamily:'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace' }}>{safe(r.duration_s)}</td>
                    <td style={{ padding:'12px 14px' }}>{safe(r.mode)}</td>
                    <td style={{ padding:'12px 14px' }}>{safe(r.model)}</td>
                    <td style={{ padding:'12px 14px' }}>{safe(r.last_step)}</td>
                    <td style={{ padding:'12px 14px' }}>
                      {runId ? (
                        <Link href={href} style={{ fontWeight: 950, textDecoration:'underline' }}>
                          {safe(r.run_dir)}
                        </Link>
                      ) : (
                        <span style={{ color:'rgba(0,0,0,0.55)' }}>{safe(r.run_dir)}</span>
                      )}
                    </td>
                  </tr>
                );
              })}
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={9} style={{ padding:'16px 14px', color:'rgba(0,0,0,0.55)' }}>
                    No runs. (index.json missing or empty)
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </div>

      <div style={{ marginTop: 18, color:'rgba(0,0,0,0.45)', fontSize: 12 }}>
        Tip: run <code style={{ fontWeight: 900 }}>make web_smoke_open</code> to regenerate runs_data then refresh.
      </div>
      <div style={{ marginTop: 26, color:'rgba(0,0,0,0.45)', fontSize: 12 }}>Built with Next.js</div>
    </main>
  );
}
TSX

# ---------------- /runs/[id] (server) ----------------
cat > "$gen_dir/app/runs/[id]/page.tsx" <<'TSX'
import fs from 'fs';
import path from 'path';
import Link from 'next/link';
import { notFound } from 'next/navigation';

type AnyObj = Record<string, any>;

function readJson(p: string): AnyObj | null {
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')); } catch { return null; }
}

function safe(v: any, fb = '-') {
  if (v === undefined || v === null) return fb;
  const s = String(v);
  return s.trim() === '' ? fb : s;
}

function Card(props: React.PropsWithChildren<{ title: string; right?: React.ReactNode }>) {
  return (
    <div style={{ border:'1px solid rgba(0,0,0,0.08)', background:'rgba(255,255,255,0.72)', borderRadius: 18, padding: 18, marginTop: 14 }}>
      <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12 }}>
        <div style={{ fontWeight: 950, fontSize: 18 }}>{props.title}</div>
        <div>{props.right}</div>
      </div>
      <div style={{ marginTop: 12 }}>{props.children}</div>
    </div>
  );
}

export const dynamic = 'force-dynamic';

export default function RunDetailPage({ params }: { params: { id: string } }) {
  const root = process.cwd();
  const id = params?.id ? decodeURIComponent(params.id) : '';
  if (!id) notFound();

  const strip = id.replace(/^run_/, '');

  const candidates = [
    path.join(root, 'public', 'runs_data', `run_${id}.json`),
    path.join(root, 'public', 'runs_data', `${id}.json`),
    path.join(root, 'public', 'runs_data', `run_${strip}.json`),
    path.join(root, 'public', 'runs_data', `${strip}.json`),
  ];

  let data: AnyObj | null = null;
  let picked: string | null = null;
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      data = readJson(p);
      picked = p;
      break;
    }
  }

  if (!data) notFound();

  const summary = (data.summary ?? data) as AnyObj;
  const verify = (data.verify ?? data.verify_summary ?? null) as AnyObj | null;
  const meta = (data.meta ?? null) as AnyObj | null;
  const events = (data.events_tail ?? data.events ?? null) as any;

  const ok = String(summary?.status ?? '').toLowerCase() === 'ok' || Boolean(verify?.ok);

  return (
    <main>
      <div style={{ display:'flex', justifyContent:'space-between', alignItems:'baseline', gap: 12, margin:'14px 0' }}>
        <div>
          <div style={{ display:'flex', alignItems:'center', gap: 10 }}>
            <h1 style={{ fontSize: 52, fontWeight: 950, letterSpacing:'-0.03em', margin: 0 }}>Run Report</h1>
            <span style={{
              display:'inline-flex', alignItems:'center',
              padding:'6px 10px', borderRadius: 999, fontWeight: 950, fontSize: 12,
              background: ok ? 'rgba(52,199,89,0.15)' : 'rgba(255,59,48,0.12)',
              border: `1px solid ${ok ? 'rgba(52,199,89,0.28)' : 'rgba(255,59,48,0.22)'}`,
            }}>
              {ok ? 'ok' : 'fail'}
            </span>
          </div>
          <div style={{ marginTop: 10, color:'rgba(0,0,0,0.55)' }}>{id}</div>
          <div style={{ marginTop: 6, color:'rgba(0,0,0,0.45)', fontSize: 12 }}>
            file: <code style={{ fontWeight: 900 }}>{picked?.split('/').slice(-3).join('/')}</code>
          </div>
        </div>

        <div style={{ display:'flex', gap: 10 }}>
          <Link href="/runs" style={{ textDecoration:'none', fontWeight: 950, padding:'10px 14px', borderRadius: 999, border:'1px solid rgba(0,0,0,0.08)', background:'white' }}>
            Back
          </Link>
        </div>
      </div>

      <Card title="Summary">
        {['kind','status','start','duration_s','last_step','mode','model','run_dir'].map((k) => (
          <div key={k} style={{ display:'flex', justifyContent:'space-between', gap: 12, padding:'8px 0', borderBottom:'1px solid rgba(0,0,0,0.06)' }}>
            <div style={{ color:'rgba(0,0,0,0.55)', fontWeight: 850 }}>{k}</div>
            <div style={{ fontWeight: 900, maxWidth:'70%', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap' }}>{safe(summary?.[k])}</div>
          </div>
        ))}
      </Card>

      <Card title="Verify" right={verify?.ok !== undefined ? <span style={{ fontWeight: 950 }}>{String(verify.ok)}</span> : null}>
        <pre style={{ margin: 0, whiteSpace:'pre-wrap', fontSize: 12 }}>
          {verify ? JSON.stringify(verify, null, 2) : 'No verify payload.'}
        </pre>
      </Card>

      <Card title="Meta">
        <pre style={{ margin: 0, whiteSpace:'pre-wrap', fontSize: 12 }}>
          {meta ? JSON.stringify(meta, null, 2) : 'No meta payload.'}
        </pre>
      </Card>

      <Card title="Events Tail">
        <pre style={{ margin: 0, whiteSpace:'pre-wrap', fontSize: 12 }}>
          {events ? (typeof events === 'string' ? events : JSON.stringify(events, null, 2)) : 'No events captured.'}
        </pre>
      </Card>

      <details style={{ marginTop: 14 }}>
        <summary style={{ fontWeight: 950, cursor:'pointer' }}>Full payload (Raw)</summary>
        <pre style={{ marginTop: 10, whiteSpace:'pre-wrap', fontSize: 12 }}>{JSON.stringify(data, null, 2)}</pre>
      </details>

      <div style={{ marginTop: 26, color:'rgba(0,0,0,0.45)', fontSize: 12 }}>Built with Next.js</div>
    </main>
  );
}
TSX

cat > "$gen_dir/app/runs/[id]/not-found.tsx" <<'TSX'
import Link from 'next/link';

export default function NotFound() {
  return (
    <main>
      <h1 style={{ fontSize: 52, fontWeight: 950, letterSpacing:'-0.03em', margin:'14px 0 8px' }}>Run Report</h1>
      <div style={{ color:'rgba(0,0,0,0.55)', fontWeight: 800 }}>Not found.</div>
      <div style={{ marginTop: 14 }}>
        <Link href="/runs" style={{ fontWeight: 950, textDecoration:'underline' }}>Back to /runs</Link>
      </div>
      <div style={{ marginTop: 26, color:'rgba(0,0,0,0.45)', fontSize: 12 }}>Built with Next.js</div>
    </main>
  );
}
TSX

echo "[ok] injected /runs + /runs/[id] (server rendered) into: $gen_dir"
