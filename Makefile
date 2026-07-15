# Homelab Control Plane — one entrypoint for the common tasks. Run `make help`.
.DEFAULT_GOAL := help
SHELL := /bin/bash

help: ## Show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-11s\033[0m %s\n",$$1,$$2}'

setup: ## Bootstrap this box (idempotent; needs sudo)
	sudo ./setup.sh

dashboard: ## Launch the physical-screen ops dashboard
	./smart_display.sh

health: ## Run the health check once, now
	./healthcheck.sh

lint: ## Shellcheck every script
	shellcheck *.sh

up: ## Start the app layer (Kairos) in Docker
	docker compose up -d

down: ## Stop the app layer
	docker compose down

logs: ## Tail Kairos logs
	docker compose logs -f kairos

.PHONY: help setup dashboard health lint up down logs
