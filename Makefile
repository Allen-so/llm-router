SHELL := /usr/bin/env bash

.PHONY: up down restart ps logs ping test chat config

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose down
	docker compose up -d

ps:
	docker compose ps

logs:
	docker compose logs -n 200 -f litellm

ping:
	./scripts/wait_ready.sh

test:
	./scripts/test_router.sh
	./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

chat:
	./scripts/chat.sh "$(MODEL)" "$(MSG)"

config:
	./scripts/print_client_config.sh

ask:
	./scripts/ask.sh "$(MODE)" "$(MSG)"

coding:
	./scripts/ask.sh coding "$(MSG)"

long:
	./scripts/ask.sh long "$(MSG)"

hard:
	./scripts/ask.sh hard "$(MSG)"

premium:
	./scripts/ask.sh premium "$(MSG)"

auto:
	./scripts/ask.sh auto "$(MSG)"
