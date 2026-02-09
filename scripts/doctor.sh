#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1/4] docker"
command -v docker >/dev/null && docker --version || { echo "ERROR: docker not found"; exit 1; }

echo "[2/4] docker compose"
docker compose version >/dev/null || { echo "ERROR: docker compose not available"; exit 1; }

echo "[3/4] files"
[[ -f docker-compose.yml ]] || { echo "ERROR: missing docker-compose.yml"; exit 1; }
[[ -f infra/litellm/config.yaml ]] || { echo "ERROR: missing infra/litellm/config.yaml"; exit 1; }
[[ -f .env ]] || echo "WARN: .env missing (copy from .env.example)"

echo "[4/4] compose config"
docker compose config >/dev/null || { echo "ERROR: docker compose config invalid"; exit 1; }

echo "OK: doctor passed"
