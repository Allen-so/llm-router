#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[1/7] run web_smoke"
make web_smoke

echo "[2/7] runs summary"
python3 scripts/runs_summary_v3.py

GEN="$(bash scripts/pick_latest_websmoke_dir.sh)"
echo "[info] gen_dir=$GEN"

echo "[3/7] export runs_data"
python3 scripts/export_runs_data.py

echo "[4/7] inject runs pages + patch UI"
bash scripts/inject_runs_detail_pages.sh "$GEN"
bash scripts/patch_websmoke_report_ui.sh

echo "[5/7] rebuild"
cd "$GEN"
npm run build
cd "$ROOT"

echo "[6/7] start next on free port"
PORT="$(python3 scripts/pick_free_port.py "${PORT_MIN:-3001}" "${PORT_MAX:-3200}")"
[[ "$PORT" != "0" ]] || { echo "[fail] no free port found" >&2; exit 3; }

log="/tmp/websmoke_${PORT}.log"
nohup npm --prefix "$GEN" run start -- -p "$PORT" >"$log" 2>&1 &
pid="$!"
echo "$pid" >"/tmp/websmoke_${PORT}.pid"
echo "[ok] next pid=$pid log=$log"
echo "[info] Local: http://localhost:${PORT}"

# 等服务起来（最多 10s）
for _ in $(seq 1 40); do
  curl -fsS "http://localhost:${PORT}/" >/dev/null 2>&1 && break || true
  sleep 0.25
done

echo "[7/7] open latest report"
RID="$(python3 - <<'PY'
import csv
from pathlib import Path
p = Path("artifacts/runs/runs_summary_v3.csv")
rid = ""
if p.exists():
    rows = list(csv.DictReader(p.open("r", encoding="utf-8")))
    # 找最新 web_smoke
    for r in rows:
        if (r.get("kind") or "").strip() == "web_smoke":
            rid = r.get("run_id","")
            break
print(rid)
PY
)"
[[ -n "$RID" ]] || RID="runs"
url="http://localhost:${PORT}/runs/${RID}"
bash scripts/open_url.sh "$url" || true
