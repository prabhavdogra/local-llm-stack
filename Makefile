# ── Local LLM Stack (MLX Backend) ────────────────────────────────────────────
# Usage:
#   make up                              Start everything (auto-installs deps)
#   make down                            Stop everything
#   make pull MODEL=mlx-community/...    Pre-download a model
#   make pull-all                        Download all models in models.yaml
#   make models                          List downloaded models
#   make status                          Show running services + MLX server
#   make test                            Smoke-test the LiteLLM gateway
# ─────────────────────────────────────────────────────────────────────────────

DC       := docker compose
VENV     := .venv
PIP      := $(VENV)/bin/pip
PYTHON   := $(VENV)/bin/python
MLX_PORT := 8800
MLX_PID  := .mlx.pid
MLX_LOG  := .mlx.log

# Default model loaded at startup (override: make up MLX_DEFAULT_MODEL=...)
MLX_DEFAULT_MODEL ?= mlx-community/Qwen2.5-Coder-7B-Instruct-4bit

.PHONY: up down restart logs status \
        setup mlx-start mlx-stop \
        pull pull-all models test \
        restart-litellm clean

# ── Stack Lifecycle ──────────────────────────────────────────────────────────

## Install Python 3.12 + mlx-lm (idempotent)
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

## Start MLX inference server in the background
mlx-start: setup
	@if [ -f $(MLX_PID) ] && kill -0 $$(cat $(MLX_PID)) 2>/dev/null; then \
		echo "MLX server already running (PID $$(cat $(MLX_PID)))"; exit 0; fi
	@echo "Starting MLX server with $(MLX_DEFAULT_MODEL)..."
	@$(PYTHON) -m mlx_lm.server \
		--model $(MLX_DEFAULT_MODEL) \
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

## Start MLX server + all Docker services
up: mlx-start
	$(DC) up -d
	@echo ""
	@echo "Stack is up:"
	@echo "  Open WebUI   → http://localhost:3001"
	@echo "  LiteLLM API  → http://localhost:4000"
	@echo "  Grafana      → http://localhost:3000"
	@echo "  MLX Server   → http://localhost:$(MLX_PORT)"

## Stop everything
down:
	$(DC) down
	@$(MAKE) --no-print-directory mlx-stop

## Restart everything
restart: down up

## Tail Docker logs (usage: make logs  or  make logs s=litellm)
logs:
	$(DC) logs -f $(s)

## Show service status
status:
	@echo "── Docker Services ──"
	@$(DC) ps
	@echo "\n── MLX Server ──"
	@if [ -f $(MLX_PID) ] && kill -0 $$(cat $(MLX_PID)) 2>/dev/null; then \
		echo "Running (PID $$(cat $(MLX_PID)), port $(MLX_PORT))"; \
		curl -s http://localhost:$(MLX_PORT)/v1/models 2>/dev/null \
			| python3 -c "import sys,json;[print('  '+m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
			|| echo "  (could not query models)"; \
	else echo "Not running"; fi

# ── Model Management ────────────────────────────────────────────────────────

## Pre-download a model (usage: make pull MODEL=mlx-community/Qwen2.5-Coder-7B-Instruct-4bit)
pull: setup
ifndef MODEL
	$(error MODEL is required. Usage: make pull MODEL=mlx-community/Qwen2.5-Coder-7B-Instruct-4bit)
endif
	$(VENV)/bin/huggingface-cli download $(MODEL)

## Download all models defined in models.yaml
pull-all: setup
	@grep 'model: openai/' models.yaml | sed 's|.*openai/||' | while read m; do \
		echo "Downloading $$m..."; \
		$(VENV)/bin/huggingface-cli download "$$m"; \
	done

## List downloaded MLX models
models:
	@echo "Downloaded models in HuggingFace cache:"
	@ls ~/.cache/huggingface/hub/ 2>/dev/null \
		| grep "^models--" \
		| sed 's/^models--//; s/--/\//g' \
		| sort \
		|| echo "  (none — run 'make pull-all' to download)"

# ── LiteLLM ─────────────────────────────────────────────────────────────────

## Restart LiteLLM to pick up models.yaml changes
restart-litellm:
	$(DC) restart litellm

## Smoke-test the LiteLLM API
test:
	@echo "Listing models via LiteLLM..."
	@curl -s http://localhost:4000/v1/models \
		-H "Authorization: Bearer sk-llmstack-local" | python3 -m json.tool

# ── MLX Server Logs ─────────────────────────────────────────────────────────

## Tail MLX server log
mlx-logs:
	@tail -f $(MLX_LOG) 2>/dev/null || echo "No MLX log file found"

# ── Cleanup ──────────────────────────────────────────────────────────────────

## Stop stack and remove all volumes (destructive — deletes chat history, metrics)
clean:
	$(DC) down -v
	@$(MAKE) --no-print-directory mlx-stop
	rm -f $(MLX_LOG)
