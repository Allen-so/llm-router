#!/usr/bin/env bash
set -euo pipefail

gen_dir="${1:-}"
if [[ -z "$gen_dir" || ! -d "$gen_dir" ]]; then
  echo "[err] usage: $0 <gen_dir>"; exit 1
fi

mkdir -p "$gen_dir/app/runs/[id]"

# ---------------- /runs (SSR)
cat > "$gen_dir/app/runs/page.tsx" <<'TSX'
import path from "path";
import { promises as fs } from "fs";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type RunIndex = {
  run_id: string;
  run_dir?: string;
  kind?: string;
  status?: string;
  start?: string;
};

function Badge({ v }: { v?: string }) {
  const s = (v || "unknown").toLowerCase();
  const ok = s === "ok";
  const fail = s === "fail";
  const bg = ok ? "rgba(34,197,94,0.12)" : fail ? "rgba(239,68,68,0.12)" : "rgba(245,158,11,0.12)";
  const fg = ok ? "rgb(21,128,61)" : fail ? "rgb(185,28,28)" : "rgb(161,98,7)";
  return (
    <span style={{ display: "inline-block", padding: "3px 10px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.10)", background: bg, color: fg, fontSize: 12, fontWeight: 700 }}>
      {s}
    </span>
  );
}

async function readIndex(): Promise<RunIndex[]> {
  const p = path.join(process.cwd(), "public", "runs_data", "index.json");
  try {
    const txt = await fs.readFile(p, "utf-8");
    const arr = JSON.parse(txt);
    return Array.isArray(arr) ? (arr as RunIndex[]) : [];
  } catch {
    return [];
  }
}

export default async function RunsPage() {
  const rows = await readIndex();

  return (
    <main style={{ maxWidth: 1100, margin: "40px auto", padding: "0 16px" }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
        <h1 style={{ fontSize: 46, fontWeight: 900, letterSpacing: "-0.02em", margin: 0 }}>Runs</h1>
        <a href="/runs" style={{ textDecoration: "none", padding: "10px 14px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.12)", background: "white", fontWeight: 700 }}>
          Refresh
        </a>
      </div>

      <div style={{ marginTop: 18, borderRadius: 16, border: "1px solid rgba(0,0,0,0.10)", overflow: "hidden", background: "white" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ background: "rgba(0,0,0,0.03)" }}>
              <th style={{ textAlign: "left", padding: "12px 14px", fontSize: 13 }}>run_id</th>
              <th style={{ textAlign: "left", padding: "12px 14px", fontSize: 13 }}>kind</th>
              <th style={{ textAlign: "left", padding: "12px 14px", fontSize: 13 }}>status</th>
              <th style={{ textAlign: "left", padding: "12px 14px", fontSize: 13 }}>start</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.run_id} style={{ borderTop: "1px solid rgba(0,0,0,0.06)" }}>
                <td style={{ padding: "12px 14px", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>
                  <a href={`/runs/${r.run_id}`} style={{ color: "inherit" }}>{r.run_id}</a>
                </td>
                <td style={{ padding: "12px 14px" }}>{r.kind || "-"}</td>
                <td style={{ padding: "12px 14px" }}><Badge v={r.status} /></td>
                <td style={{ padding: "12px 14px", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>{r.start || "-"}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={4} style={{ padding: "14px", color: "rgba(0,0,0,0.55)" }}>
                  No runs_data/index.json found or empty. Try re-export.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </main>
  );
}
TSX

# ---------------- /runs/[id] (SSR)
cat > "$gen_dir/app/runs/[id]/page.tsx" <<'TSX'
import path from "path";
import { promises as fs } from "fs";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type RunDetail = {
  run_id: string;
  index?: { run_id?: string; run_dir?: string; kind?: string; status?: string; start?: string };
  meta?: any;
  verify?: any;
  source?: any;
};

function Badge({ v }: { v?: string }) {
  const s = (v || "unknown").toLowerCase();
  const ok = s === "ok";
  const fail = s === "fail";
  const bg = ok ? "rgba(34,197,94,0.12)" : fail ? "rgba(239,68,68,0.12)" : "rgba(245,158,11,0.12)";
  const fg = ok ? "rgb(21,128,61)" : fail ? "rgb(185,28,28)" : "rgb(161,98,7)";
  return (
    <span style={{ display: "inline-block", padding: "4px 12px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.10)", background: bg, color: fg, fontSize: 12, fontWeight: 800 }}>
      {s}
    </span>
  );
}

function row(k: string, v: any) {
  const s = (v === null || v === undefined || v === "") ? "-" : String(v);
  return (
    <tr key={k} style={{ borderTop: "1px solid rgba(0,0,0,0.06)" }}>
      <td style={{ padding: "12px 14px", width: 220, color: "rgba(0,0,0,0.65)", fontWeight: 700 }}>{k}</td>
      <td style={{ padding: "12px 14px", textAlign: "right", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>{s}</td>
    </tr>
  );
}

async function readDetail(id: string): Promise<RunDetail | null> {
  const p = path.join(process.cwd(), "public", "runs_data", `${id}.json`);
  try {
    const txt = await fs.readFile(p, "utf-8");
    return JSON.parse(txt) as RunDetail;
  } catch {
    return null;
  }
}

export default async function RunPage({ params }: { params: { id: string } }) {
  const id = params.id;
  const d = await readDetail(id);

  if (!d) {
    return (
      <main style={{ maxWidth: 980, margin: "40px auto", padding: "0 16px" }}>
        <h1 style={{ fontSize: 54, fontWeight: 900, letterSpacing: "-0.02em", margin: 0 }}>Run Report <Badge v="fail" /></h1>
        <p style={{ marginTop: 10, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>{id}</p>
        <div style={{ marginTop: 16, padding: 14, borderRadius: 14, border: "1px solid rgba(0,0,0,0.12)", background: "rgba(0,0,0,0.03)" }}>
          If this keeps happening, check file exists: <b>public/runs_data/{id}.json</b>
        </div>
        <p style={{ marginTop: 18 }}><a href="/runs">Back</a></p>
      </main>
    );
  }

  const idx = d.index || {};
  const meta = d.meta || {};
  const verify = d.verify;

  // status 优先：index.status -> verify.ok -> meta.status
  let status = idx.status || meta.status || "unknown";
  if (verify && typeof verify.ok === "boolean") status = verify.ok ? "ok" : "fail";

  const kind = idx.kind || meta.kind || "unknown";
  const start = idx.start || meta.ts_utc || meta.start || "unknown";
  const run_dir = idx.run_dir || meta.run_dir || d.run_id || "-";

  return (
    <main style={{ maxWidth: 980, margin: "40px auto", padding: "0 16px" }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
        <div>
          <h1 style={{ fontSize: 54, fontWeight: 900, letterSpacing: "-0.02em", margin: 0 }}>
            Run Report <Badge v={status} />
          </h1>
          <div style={{ marginTop: 8, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: "rgba(0,0,0,0.65)" }}>
            {id}
          </div>
        </div>
        <div style={{ display: "flex", gap: 10 }}>
          <a href="/runs" style={{ textDecoration: "none", padding: "10px 14px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.12)", background: "white", fontWeight: 800 }}>Back</a>
          <a href={`/runs/${id}`} style={{ textDecoration: "none", padding: "10px 14px", borderRadius: 999, border: "1px solid rgba(0,0,0,0.12)", background: "white", fontWeight: 800 }}>Refresh</a>
        </div>
      </div>

      <section style={{ marginTop: 18, borderRadius: 16, border: "1px solid rgba(0,0,0,0.10)", background: "white", overflow: "hidden" }}>
        <div style={{ padding: "14px 16px", fontWeight: 900, fontSize: 18, borderBottom: "1px solid rgba(0,0,0,0.06)" }}>Summary</div>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <tbody>
            {row("kind", kind)}
            {row("status", status)}
            {row("start", start)}
            {row("run_dir", run_dir)}
          </tbody>
        </table>
      </section>

      <section style={{ marginTop: 18, borderRadius: 16, border: "1px solid rgba(0,0,0,0.10)", background: "white", overflow: "hidden" }}>
        <div style={{ padding: "14px 16px", fontWeight: 900, fontSize: 18, borderBottom: "1px solid rgba(0,0,0,0.06)" }}>Verify</div>
        <div style={{ padding: "14px 16px", color: "rgba(0,0,0,0.75)" }}>
          {verify ? (
            <pre style={{ margin: 0, whiteSpace: "pre-wrap", wordBreak: "break-word", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>
              {JSON.stringify(verify, null, 2)}
            </pre>
          ) : (
            <div>No verify payload.</div>
          )}
        </div>
      </section>

      <details style={{ marginTop: 18 }}>
        <summary style={{ cursor: "pointer", fontWeight: 900 }}>Raw JSON</summary>
        <pre style={{ marginTop: 10, padding: 14, borderRadius: 14, background: "rgba(0,0,0,0.03)", overflow: "auto", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>
          {JSON.stringify(d, null, 2)}
        </pre>
      </details>
    </main>
  );
}
TSX

echo "[ok] injected SSR pages: /runs + /runs/[id] -> $gen_dir"
