SHELL := /bin/bash

MODE ?= auto
TEXT ?= Say ROUTER_OK
API_BASE ?= http://127.0.0.1:4000

.PHONY: help up ready upready down ps logs check ask doctor demo replay_latest

help:
	@echo "Targets:"
	@echo "  make up                  - docker compose up -d"
	@echo "  make ready               - wait until router is ready"
	@echo "  make upready             - up + ready"
	@echo "  make check               - ps + curl models + one ask"
	@echo "  make ask MODE=auto TEXT='...'"
	@echo "  make demo MODE=auto TEXT='...'"
	@echo "  make replay_latest       - replay last demo run"
	@echo "  make doctor              - run scripts/doctor.sh"
	@echo "  make logs                - tail litellm logs"
	@echo "  make down                - docker compose down"

up:
	docker compose up -d

ready:
	./scripts/wait_ready.sh

upready: up ready

down:
	docker compose down

ps:
	docker compose ps

logs:
	docker compose logs --tail 120 litellm

check: ps ready
	@echo "[check] curl /v1/models =>"
	@curl -sS -o /dev/null -w 'HTTP=%{http_code}\n' $(API_BASE)/v1/models || true
	@echo "[check] ask.sh =>"
	@./scripts/ask.sh --meta $(MODE) "$(TEXT)" || true
	@echo "[check] last log =>"
	@tail -n 1 logs/ask_history.log || true

ask:
	./scripts/ask.sh --meta $(MODE) "$(TEXT)" || true

doctor:
	./scripts/doctor.sh

demo:
	python3 apps/router-demo/run.py --mode "$(MODE)" --text "$(TEXT)" --api-base "$(API_BASE)"

replay_latest:
	python3 apps/router-demo/replay.py --run-dir "$$(cat artifacts/runs/LATEST)" --api-base "$(API_BASE)"
