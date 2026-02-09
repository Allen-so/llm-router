SHELL := /usr/bin/env bash

# ---- user knobs ----
MODE ?= auto
TEXT ?= Say ROUTER_OK
ROUTER_DEBUG ?= 0
HOURS ?= 24
THREAD ?= default
N ?= 30

# thresholds (P3-2)
THRESH_PREMIUM_ESCALATED_PER_HOUR ?= 3
THRESH_P95_MS ?= 10000

.PHONY: help up down restart ps ready test check ask cost24 guard1 stats cleanlogs

help:
	@echo "ai-platform commands:"
	@echo "  make up                 - docker compose up -d"
	@echo "  make down               - docker compose down"
	@echo "  make ps                 - docker compose ps"
	@echo "  make ready              - wait readiness"
	@echo "  make test               - test_router.sh"
	@echo "  make check              - up + ready + test + route preview + cost + guard"
	@echo "  make ask MODE=auto TEXT='...' ROUTER_DEBUG=1"
	@echo "  make cost24             - cost summary last 24h"
	@echo "  make guard1             - cost guard last 1h (OK/WARN/FAIL)"
	@echo "  make stats              - route stats last 24h"
	@echo "  make cleanlogs           - remove ask_last_run.log only (optional)"

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose down
	docker compose up -d

ps:
	docker compose ps

ready:
	./scripts/wait_ready.sh

test:
	./scripts/test_router.sh

check: up ready test
	@echo
	@echo "== route preview sample =="
	@ROUTER_DEBUG=0 ./scripts/route_preview.sh "Traceback: KeyError in pandas"
	@echo
	@echo "== cost summary (last $(HOURS)h) =="
	@./scripts/cost_summary.sh --since-hours $(HOURS)
	@echo
	@echo "== cost guard (last 1h) =="
	@THRESH_PREMIUM_ESCALATED_PER_HOUR=$(THRESH_PREMIUM_ESCALATED_PER_HOUR) THRESH_P95_MS=$(THRESH_P95_MS) ./scripts/cost_guard.sh --since-hours 1
	@echo
	@echo "== OK: check completed =="

ask:
	ROUTER_DEBUG=$(ROUTER_DEBUG) ./scripts/ask.sh $(MODE) "$(TEXT)"

cost24:
	./scripts/cost_summary.sh --since-hours 24

guard1:
	THRESH_PREMIUM_ESCALATED_PER_HOUR=$(THRESH_PREMIUM_ESCALATED_PER_HOUR) THRESH_P95_MS=$(THRESH_P95_MS) ./scripts/cost_guard.sh --since-hours 1

stats:
	./scripts/route_stats.sh --since-hours 24

cleanlogs:
	@rm -f logs/ask_last_run.log
	@echo "OK: removed logs/ask_last_run.log"

.PHONY: ask-thread thread-show thread-reset

ask-thread:
	ROUTER_DEBUG=$(ROUTER_DEBUG) ./scripts/ask.sh $(MODE) --thread $(THREAD) "$(TEXT)"

thread-show:
	./scripts/thread_show.sh $(THREAD) $(N)

thread-reset:
	./scripts/thread_reset.sh $(THREAD)
