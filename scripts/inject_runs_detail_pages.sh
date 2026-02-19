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
import path from "path";
import { promises as fs } from "fs";
import type { CSSProperties } from "react";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Props = { params: { id: string } };

function Badge({ status }: { status: string }) {
  const s = (status || "unknown").toLowerCase();
  const ok = s === "ok";
  const style: CSSProperties = {
    display: "inline-flex",
    alignItems: "center",
    padding: "4px 10px",
    borderRadius: 999,
    fontSize: 12,
    border: "1px solid rgba(0,0,0,0.12)",
    background: ok ? "rgba(34,197,94,0.12)" : "rgba(239,68,68,0.12)",
    color: ok ? "rgb(21,128,61)" : "rgb(185,28,28)",
    marginLeft: 10,
    verticalAlign: "middle",
    textTransform: "lowercase",
  };
  return <span style={style}>{ok ? "ok" : s}</span>;
}

async function readJson(absPath: string): Promise<any | null> {
  try {
    const raw = await fs.readFile(absPath, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export default async function RunDetailPage({ params }: Props) {
  const id = params.id;

  const fileRel = path.join("public", "runs_data", `${id}.json`);
  const fileAbs = path.join(process.cwd(), fileRel);
  const detail = await readJson(fileAbs);

  if (!detail) {
    return (
      <main style={{ maxWidth: 980, margin: "40px auto", padding: "0 16px" }}>
        <h1 style={{ fontSize: 54, fontWeight: 900, letterSpacing: "-0.02em" }}>
          Run Report <Badge status="fail" />
        </h1>
        <div style={{ opacity: 0.65, marginTop: 8 }}>{id}</div>
        <div style={{ opacity: 0.55, marginTop: 6 }}>
          file: <code>{fileRel}</code>
        </div>

        <section style={{ marginTop: 18, borderRadius: 18, border: "1px solid rgba(0,0,0,0.12)", padding: 18 }}>
          <b>Data not found</b>
          <div style={{ marginTop: 8, opacity: 0.7 }}>abs: {fileAbs}</div>
          <div style={{ marginTop: 12 }}>
            <a href="/runs" style={{ textDecoration: "underline" }}>Back to runs</a>
          </div>
        </section>
      </main>
    );
  }

  const index = detail.index ?? {};
  const meta = detail.meta ?? {};

  const status = String(meta.status ?? index.status ?? "unknown");
  const kind = String(meta.kind ?? index.kind ?? "-");
  const start = String(index.start ?? meta.ts ?? meta.ts_utc ?? "-");
  const duration_s = String(meta.duration_s ?? index.duration_s ?? "-");
  const last_step = String(meta.last_step ?? index.last_step ?? "-");
  const mode = String(meta.mode ?? index.mode ?? "-");
  const model = String(meta.model ?? index.model ?? "-");
  const run_dir = String(meta.run_dir ?? index.run_dir ?? "-");

  const rows: Array<[string, string]> = [
    ["kind", kind],
    ["status", status],
    ["start", start],
    ["duration_s", duration_s],
    ["last_step", last_step],
    ["mode", mode],
    ["model", model],
    ["run_dir", run_dir],
  ];

  const verify = detail.verify ?? null;

  return (
    <main style={{ maxWidth: 980, margin: "40px auto", padding: "0 16px" }}>
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 12 }}>
        <div>
          <h1 style={{ fontSize: 54, fontWeight: 900, letterSpacing: "-0.02em" }}>
            Run Report <Badge status={status} />
          </h1>
          <div style={{ opacity: 0.65, marginTop: 8 }}>{id}</div>
          <div style={{ opacity: 0.55, marginTop: 6 }}>
            file: <code>public/runs_data/{id}.json</code>
          </div>
        </div>

        <div style={{ display: "flex", gap: 10, marginTop: 10 }}>
          <a href="/runs" style={{ padding: "10px 16px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.12)" }}>Back</a>
          <a
            href={`/runs/${id}?t=${Date.now()}`}
            style={{ padding: "10px 16px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.12)" }}
          >
            Refresh
          </a>
        </div>
      </div>

      <section style={{ marginTop: 18, borderRadius: 18, border: "1px solid rgba(0,0,0,0.12)", padding: 18 }}>
        <h2 style={{ fontSize: 18, fontWeight: 800 }}>Summary</h2>
        <div style={{ marginTop: 12 }}>
          {rows.map(([k, v]) => (
            <div
              key={k}
              style={{
                display: "flex",
                justifyContent: "space-between",
                padding: "10px 0",
                borderTop: "1px solid rgba(0,0,0,0.06)",
              }}
            >
              <div style={{ opacity: 0.7, fontWeight: 700 }}>{k}</div>
              <div style={{ fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace" }}>{v}</div>
            </div>
          ))}
        </div>
      </section>

      <section style={{ marginTop: 18, borderRadius: 18, border: "1px solid rgba(0,0,0,0.12)", padding: 18 }}>
        <h2 style={{ fontSize: 18, fontWeight: 800 }}>Verify</h2>
        {verify ? (
          <pre style={{ marginTop: 12, padding: 12, borderRadius: 12, background: "rgba(0,0,0,0.04)", overflow: "auto" }}>
{JSON.stringify(verify, null, 2)}
          </pre>
        ) : (
          <div style={{ marginTop: 10, opacity: 0.7 }}>No verify payload.</div>
        )}
      </section>

      <details style={{ marginTop: 18 }}>
        <summary style={{ cursor: "pointer", fontWeight: 800 }}>Raw JSON</summary>
        <pre style={{ marginTop: 12, padding: 12, borderRadius: 12, background: "rgba(0,0,0,0.04)", overflow: "auto" }}>
{JSON.stringify(detail, null, 2)}
        </pre>
      </details>
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
