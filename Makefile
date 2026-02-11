SHELL := /bin/bash
.NOTPARALLEL:

MODE ?= auto
TEXT ?= Say ROUTER_OK
API_BASE ?= http://127.0.0.1:4000
MODEL ?= default-chat
FORCE ?= 0

PLAN_TEXT_FILE := artifacts/tmp/plan_input.txt

.PHONY: help up ready upready down ps logs check ask doctor demo replay_latest plan scaffold gen qa

help:
	@echo "Targets:"
	@echo "  make upready                         - up + wait_ready"
	@echo "  make check                           - ps + curl models + ask"
	@echo "  make demo MODE=auto TEXT='...'       - demo run (text)"
	@echo "  make replay_latest                   - replay last demo run"
	@echo "  make plan MODEL=default-chat TEXT='...'   - generate plan.json (JSON-only, auto-retry)"
	@echo "  make scaffold                        - scaffold from LATEST plan.json"
	@echo "  make gen TEXT='...'                  - upready + plan + scaffold (atomic)"
	@echo "  make doctor                          - repo + env + port checks"
	@echo "  make qa                              - global QA"

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
	./scripts/ask.sh --meta auto "Reply with exactly ROUTER_OK and nothing else." || true
	@echo "[check] last log =>"
	@tail -n 1 logs/ask_history.log || true

ask:

doctor:
	./scripts/doctor.sh

demo:
	python3 apps/router-demo/run.py --mode "$(MODE)" --text "$(TEXT)" --api-base "$(API_BASE)"

replay_latest:
	python3 apps/router-demo/replay.py --run-dir "$$(cat artifacts/runs/LATEST)" --api-base "$(API_BASE)"

plan:
	@mkdir -p artifacts/tmp
	@printf '%s' "$(TEXT)" > "$(PLAN_TEXT_FILE)"
	python3 apps/router-demo/plan.py --text-file "$(PLAN_TEXT_FILE)" --api-base "$(API_BASE)" --model "$(MODEL)"

scaffold:
	python3 apps/router-demo/scaffold.py $(if $(filter 1,$(FORCE)),--force,)

qa:
	./scripts/qa_all.sh
