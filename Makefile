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

up:

ready:

upready: up ready

down:

ps:
	docker compose ps

logs:
	docker compose logs --tail 120 litellm

check: ps ready
	@echo "[check] curl /v1/models =>"
	@curl -sS -o /dev/null -w 'HTTP=%{http_code}\n' $(API_BASE)/v1/models || true
	@echo "[check] ask.sh =>"
	@echo "[check] ask strict =>"
	@OUT="$$(./scripts/ask.sh --meta auto \"Reply with exactly ROUTER_OK and nothing else.\")" || { echo "[fail] ask.sh failed"; exit 1; }; \
	FIRST="$$(printf '%s\n' "$$OUT" | head -n1 | tr -d '\r')"; \
	if [[ "$$FIRST" != "ROUTER_OK" ]]; then \
	  echo "[fail] ask did not return exact ROUTER_OK"; \
	  echo "$$OUT"; \
	  exit 1; \
	fi; \
	echo "$$OUT"
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
	python3 apps/router-demo/plan_policy.py --text-file "$(PLAN_TEXT_FILE)" --api-base "$(API_BASE)" --model "$(MODEL)"

scaffold:
	python3 apps/router-demo/scaffold.py $(if $(filter 1,$(FORCE)),--force,)

qa:
	./scripts/qa_all.sh

# --- QA must always run ---
.PHONY: qa FORCE
qa: FORCE
FORCE:

# --- Generated project verification ---
.PHONY: verify_generated
verify_generated:
	./scripts/verify_generated.sh

# --- One-shot: plan -> scaffold -> verify (safe alternative to gen) ---
MODEL ?= default-chat
.PHONY: genv
genv:
	@test -n "$(TEXT)" || (echo "TEXT is required. Example: make genv TEXT='Build a python CLI tool named x'"; exit 2)
	@$(MAKE) plan MODEL="$(MODEL)" TEXT="$(TEXT)"
	@$(MAKE) scaffold
	@$(MAKE) verify_generated

# --- Next.js site pipeline ---
.PHONY: plan_web scaffold_web verify_generated_web gen_nextjs

plan_web:
	@test -n "$(TEXT)" || (echo "TEXT is required. Example: make plan_web TEXT='Build a Next.js site ...'"; exit 2)
	@mkdir -p artifacts/tmp
	@printf "%s" "$(TEXT)" > artifacts/tmp/plan_web_input.txt
	python3 apps/router-demo/plan_web_policy.py --text-file "artifacts/tmp/plan_web_input.txt" --api-base "http://127.0.0.1:4000" --model "$(MODEL)"

scaffold_web:
	./scripts/run_step_log.sh scaffold_web -- python3 apps/router-demo/scaffold_web.py

verify_generated_web:
	./scripts/run_step_log.sh verify_generated_web -- ./scripts/verify_generated_web.sh

gen_nextjs: upready
	@$(MAKE) plan_web MODEL="$(MODEL)" TEXT="$(TEXT)"
	@$(MAKE) scaffold_web
	./scripts/run_step_log.sh apply_plan_web -- python3 apps/router-demo/apply_plan_web.py
	@$(MAKE) verify_generated_web


	@$(MAKE) post_run
meta_latest:
	./scripts/run_step_log.sh meta_latest -- python3 scripts/write_run_meta.py --append-events

runs_summary:
	python3 scripts/runs_summary_v2.py

policy_smoke:
	bash scripts/policy_smoke.sh

.PHONY: web_replay_latest
web_replay_latest:
	./scripts/web_replay_latest.sh


.PHONY: web_smoke
web_smoke: upready
	bash scripts/web_smoke.sh
	@$(MAKE) post_run


	KEEP=3 bash scripts/retain_keep3.sh


	KEEP=3 bash scripts/retain_keep3.sh


	@$(MAKE) meta_latest
	@$(MAKE) prune_keep3

.PHONY: prune_keep3
prune_keep3:
	KEEP=3 bash scripts/retain_keep3.sh

.PHONY: post_run
post_run:
	@$(MAKE) meta_latest
	@$(MAKE) prune_keep3
