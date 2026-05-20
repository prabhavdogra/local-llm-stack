# ── Local LLM Stack ──────────────────────────────────────────────────────────
# Usage:
#   make config                    Create .env from .env.example + generate secrets
#   make config FORCE=1            Overwrite .env and regenerate secrets
#   make check-env                 Report required / missing optional .env vars
#   make up                        Start (reads BACKEND from .env)
#   make up-ngrok                  Start with ngrok (needs NGROK_* in .env)
#   make up BACKEND=nvidia         Override backend for this run
#   make down                      Stop everything
#   make restart                   Restart everything
#   make health                    Probe all service health endpoints
#   make status                    Show running containers + loaded model
#   make logs [s=SERVICE]          Tail logs (e.g. make logs s=vllm)
#   make test                      Smoke-test the LiteLLM API
#   make pull MODEL=<hf-id>        Pre-download a model
#   make sync                      Rsync repo to DGX Spark (see scripts/sync-to-dgx.sh)
#   make remote-up                 sync + make up on DGX
# ─────────────────────────────────────────────────────────────────────────────

# DGX Spark — override if your SSH config differs
DGX_HOST ?= prabhav@spark-2393.local
DGX_PATH ?= ~/Desktop/repositories/local-llm-stack
export DGX_HOST DGX_PATH

# Load .env as Make variables; export them to child processes (docker compose).
-include .env
export

# ── Configurable defaults (override via .env or command line) ───────────────
BACKEND          ?= nvidia
MLX_MODEL        ?= mlx-community/Qwen2.5-Coder-7B-Instruct-4bit
MLX_PORT         ?= 8800
VLLM_MODEL       ?= Qwen/Qwen3-Coder-Next
VLLM_PORT        ?= 8000
LITELLM_PORT     ?= 4000
# LITELLM_MASTER_KEY has no default — must come from .env. `make test` fails
# loudly with an empty Authorization header if it's missing.
WEBUI_PORT       ?= 3001
GRAFANA_PORT     ?= 3000
PROMETHEUS_PORT  ?= 9090

# ── Internal ────────────────────────────────────────────────────────────────
VENV    := .venv
PIP     := $(VENV)/bin/pip
PYTHON  := $(VENV)/bin/python
MLX_PID := .mlx.pid
MLX_LOG := .mlx.log

ifeq ($(BACKEND),nvidia)
DC := docker compose -f docker-compose.yml -f docker-compose.nvidia.yml
else
DC := docker compose
endif
ifneq ($(COMPOSE_PROFILES),)
export COMPOSE_PROFILES
endif

.PHONY: up up-do up-ngrok down restart logs status health test config ensure-config config-secrets check-env \
        sync sync-dry ssh-dgx remote-up remote-config seed-admin \
        setup mlx-start mlx-stop mlx-logs \
        pull pull-all models restart-litellm clean

# ── DGX sync / remote ───────────────────────────────────────────────────────

## Rsync this repo to DGX (excludes .env, .venv — run make config on the DGX)
sync:
	@bash scripts/sync-to-dgx.sh

sync-dry:
	@DRY_RUN=1 bash scripts/sync-to-dgx.sh

## Open SSH shell in the project dir on the DGX
ssh-dgx:
	@ssh -t $(DGX_HOST) "cd $(DGX_PATH) && exec bash -l"

## First-time .env setup on the DGX (after sync)
remote-config:
	@ssh -t $(DGX_HOST) "cd $(DGX_PATH) && make config && make check-env"

## Sync then start the stack on the DGX
remote-up: sync
	@ssh -t $(DGX_HOST) "cd $(DGX_PATH) && make ensure-config && make check-env QUIET=1 && make up-do"

## Seed Open WebUI admin user (runs automatically in make up)
seed-admin:
	@python3 scripts/seed-admin.py

# ── Configuration ───────────────────────────────────────────────────────────

## Idempotent: create .env if missing; fill secrets only while placeholders remain
ensure-config:
	@test -f .env.example || { echo "ERROR: .env.example not found"; exit 1; }
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env from .env.example"; \
		$(MAKE) --no-print-directory config-secrets; \
	else \
		$(MAKE) --no-print-directory config-secrets ONLY_PLACEHOLDERS=1 QUIET=1; \
	fi

## Create .env from .env.example and generate LITELLM_MASTER_KEY + GRAFANA_ADMIN_PASSWORD
config:
	@if [ "$(FORCE)" = "1" ]; then \
		test -f .env.example || { echo "ERROR: .env.example not found"; exit 1; }; \
		cp .env.example .env; \
		echo "Reset .env from .env.example"; \
		$(MAKE) --no-print-directory config-secrets; \
	elif [ -f .env ]; then \
		echo ".env already exists — skipping copy."; \
		echo "  Run 'make config FORCE=1' to reset from .env.example."; \
		$(MAKE) --no-print-directory config-secrets ONLY_PLACEHOLDERS=1; \
	else \
		$(MAKE) --no-print-directory ensure-config; \
	fi
	@$(MAKE) --no-print-directory check-env

config-secrets:
	@ONLY_PLACEHOLDERS="$(ONLY_PLACEHOLDERS)" QUIET="$(QUIET)" python3 scripts/config-secrets.py

## Validate .env (required secrets + conditional HF_TOKEN / NGROK_*)
check-env:
	@BACKEND="$(BACKEND)" COMPOSE_PROFILES="$(COMPOSE_PROFILES)" QUIET="$(QUIET)" python3 scripts/check-env.py

## Start with ngrok tunnel (requires NGROK_AUTHTOKEN + NGROK_DOMAIN in .env)
up-ngrok:
	@COMPOSE_PROFILES=ngrok $(MAKE) --no-print-directory ensure-config
	@COMPOSE_PROFILES=ngrok BACKEND="$(BACKEND)" $(MAKE) --no-print-directory check-env
	@COMPOSE_PROFILES=ngrok $(MAKE) --no-print-directory up-do

# ── Stack Lifecycle ──────────────────────────────────────────────────────────

## Start the full stack (backend-aware; runs ensure-config first)
up: ensure-config
	@$(MAKE) --no-print-directory check-env QUIET=1
	@$(MAKE) --no-print-directory up-do

up-do:
ifeq ($(BACKEND),nvidia)
	@echo "Starting stack  [nvidia → vLLM → $(VLLM_MODEL)]"
else
	@echo "Starting stack  [mlx → $(MLX_MODEL)]"
	@$(MAKE) --no-print-directory mlx-start
endif
	$(DC) up -d
	@python3 scripts/seed-admin.py
	@echo ""
	@echo "Stack is up  ($(BACKEND)):"
	@echo "  LiteLLM API (OpenAI-compat)  →  http://localhost:$(LITELLM_PORT)"
	@echo "  Open WebUI                   →  http://localhost:$(WEBUI_PORT)"
	@echo "  Grafana                      →  http://localhost:$(GRAFANA_PORT)"
	@echo "  Health                       →  http://localhost:$(LITELLM_PORT)/health"
ifeq ($(BACKEND),nvidia)
	@echo ""
	@echo "  Model : $(VLLM_MODEL)"
	@echo "  First run downloads the model — watch with:  make logs s=vllm"
else
	@echo "  MLX Server                   →  http://localhost:$(MLX_PORT)"
endif

## Stop everything
down:
	$(DC) down
ifneq ($(BACKEND),nvidia)
	@$(MAKE) --no-print-directory mlx-stop
endif

## Restart everything
restart: down up

## Tail Docker logs (usage: make logs  or  make logs s=litellm)
logs:
	$(DC) logs -f $(s)

## Show service status
status:
	@echo "── Services ($(BACKEND)) ──"
	@$(DC) ps
ifeq ($(BACKEND),nvidia)
	@echo ""
	@echo "── vLLM ──"
	@curl -s http://localhost:$(VLLM_PORT)/v1/models 2>/dev/null \
		| python3 -c "import sys,json;[print('  '+m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
		|| echo "  (not responding)"
else
	@echo ""
	@echo "── MLX Server ──"
	@if [ -f $(MLX_PID) ] && kill -0 $$(cat $(MLX_PID)) 2>/dev/null; then \
		echo "Running  (PID $$(cat $(MLX_PID)),  port $(MLX_PORT))"; \
		curl -s http://localhost:$(MLX_PORT)/v1/models 2>/dev/null \
			| python3 -c "import sys,json;[print('  '+m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
			|| echo "  (could not query models)"; \
	else echo "Not running"; fi
endif

# ── Health ──────────────────────────────────────────────────────────────────

## Probe every service endpoint
health:
	@echo "── Health ──"
	@printf "  LiteLLM ............. " && \
		curl -sf http://localhost:$(LITELLM_PORT)/health/liveliness >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
	@printf "  LiteLLM (models) .... " && \
		curl -sf http://localhost:$(LITELLM_PORT)/health/readiness >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
	@printf "  Open WebUI .......... " && \
		curl -sf http://localhost:$(WEBUI_PORT) >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
	@printf "  Prometheus .......... " && \
		curl -sf http://localhost:$(PROMETHEUS_PORT)/-/healthy >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
	@printf "  Grafana ............. " && \
		curl -sf http://localhost:$(GRAFANA_PORT)/api/health >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
ifeq ($(BACKEND),nvidia)
	@printf "  vLLM ................ " && \
		curl -sf http://localhost:$(VLLM_PORT)/health >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
else
	@printf "  MLX ................. " && \
		curl -sf http://localhost:$(MLX_PORT)/v1/models >/dev/null 2>&1 \
		&& echo "ok" || echo "FAIL"
endif

# ── MLX Backend (macOS Apple Silicon) ────────────────────────────────────────

## Install Python + mlx-lm (idempotent)
setup:
	@PYBIN=$$(command -v python3.12 2>/dev/null || \
	          command -v python3.11 2>/dev/null || \
	          command -v python3.10 2>/dev/null || echo ""); \
	if [ -z "$$PYBIN" ]; then \
		echo "Python >= 3.10 not found. Installing via Homebrew..."; \
		brew install python@3.12; \
		PYBIN=$$(command -v python3.12); \
	fi; \
	if [ ! -d $(VENV) ]; then \
		echo "Creating virtual environment with $$PYBIN..."; \
		$$PYBIN -m venv $(VENV); \
	fi
	@$(PIP) show mlx-lm >/dev/null 2>&1 || \
		(echo "Installing mlx-lm..." && $(PIP) install --quiet mlx-lm)

## Start MLX inference server in background
mlx-start: setup
	@if [ -f $(MLX_PID) ] && kill -0 $$(cat $(MLX_PID)) 2>/dev/null; then \
		echo "MLX server already running (PID $$(cat $(MLX_PID)))"; exit 0; fi
	@echo "Starting MLX server with $(MLX_MODEL)..."
	@# Bind to 0.0.0.0 is REQUIRED on macOS so the LiteLLM container can reach
	@# the host MLX server via host.docker.internal. The MLX server has no auth,
	@# so this also exposes it to the LAN — protect with a host firewall if you
	@# don't trust your network.
	@$(PYTHON) -m mlx_lm.server \
		--model $(MLX_MODEL) \
		--host 0.0.0.0 \
		--port $(MLX_PORT) > $(MLX_LOG) 2>&1 & echo $$! > $(MLX_PID)
	@echo "Waiting for MLX server..."; \
	for i in $$(seq 1 30); do \
		curl -sf http://localhost:$(MLX_PORT)/v1/models >/dev/null 2>&1 \
			&& { echo "MLX server ready on port $(MLX_PORT)"; exit 0; }; \
		kill -0 $$(cat $(MLX_PID)) 2>/dev/null \
			|| { echo "ERROR: MLX server crashed:"; tail -20 $(MLX_LOG); rm -f $(MLX_PID); exit 1; }; \
		sleep 2; \
	done; \
	echo "ERROR: MLX server timed out. See $(MLX_LOG)"; tail -20 $(MLX_LOG); exit 1

## Stop MLX server
mlx-stop:
	@[ -f $(MLX_PID) ] \
		&& { kill $$(cat $(MLX_PID)) 2>/dev/null; rm -f $(MLX_PID); echo "MLX server stopped"; } \
		|| echo "MLX server not running"

## Tail MLX server log
mlx-logs:
	@tail -f $(MLX_LOG) 2>/dev/null || echo "No MLX log file found"

# ── Model Management ────────────────────────────────────────────────────────

## Pre-download a model from HuggingFace
pull:
ifndef MODEL
	$(error Usage: make pull MODEL=Qwen/Qwen2.5-Coder-32B-Instruct)
endif
ifeq ($(BACKEND),nvidia)
	docker run --rm -v $$(docker volume inspect local-llm-stack_huggingface_cache -f '{{.Mountpoint}}' 2>/dev/null || echo huggingface_cache):/root/.cache/huggingface \
		python:3.12-slim pip install -q huggingface_hub && huggingface-cli download $(MODEL) \
		|| (echo "Falling back to local download..." && pip install -q huggingface_hub && huggingface-cli download $(MODEL))
else
	@$(MAKE) --no-print-directory setup
	$(VENV)/bin/huggingface-cli download $(MODEL)
endif

## List downloaded models
models:
	@echo "Downloaded models in HuggingFace cache:"
	@ls ~/.cache/huggingface/hub/ 2>/dev/null \
		| grep "^models--" \
		| sed 's/^models--//; s/--/\//g' \
		| sort \
		|| echo "  (none — run 'make pull MODEL=...' to download)"

# ── LiteLLM ─────────────────────────────────────────────────────────────────

## Restart LiteLLM to reload config
restart-litellm:
	$(DC) restart litellm

## Smoke-test the LiteLLM API
test:
	@echo "── Models available via LiteLLM ──"
	@curl -s http://localhost:$(LITELLM_PORT)/v1/models \
		-H "Authorization: Bearer $(LITELLM_MASTER_KEY)" | python3 -m json.tool

# ── Cleanup ──────────────────────────────────────────────────────────────────

## Stop stack and remove all volumes (destructive — deletes chat history, metrics)
clean:
	$(DC) down -v
ifneq ($(BACKEND),nvidia)
	@$(MAKE) --no-print-directory mlx-stop
endif
	rm -f $(MLX_LOG)
