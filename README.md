# Local LLM Stack

Run local LLMs with a unified API gateway, chat UI, and monitoring — all from a single `models.yaml`.

## Architecture

```
macOS (native, Apple Silicon):
  └── MLX-LM Server (:8800)

Docker Compose:
  ├── LiteLLM    (:4000)  ──→  MLX server via host.docker.internal
  ├── Open WebUI (:3001)  ──→  LiteLLM
  ├── Prometheus (:9090)  ──→  scrapes LiteLLM /metrics
  └── Grafana    (:3000)  ──→  reads Prometheus
```

All inference flows through LiteLLM. Swapping the backend = updating `models.yaml`.

## Quick Start

```bash
# 1. Start everything (installs deps, starts MLX server + Docker services)
make up

# 2. Open the UI
open http://localhost:3001
```

| Service      | URL                        |
|-------------|----------------------------|
| Open WebUI  | http://localhost:3001       |
| LiteLLM API | http://localhost:4000       |
| Grafana     | http://localhost:3000       |
| Prometheus  | http://localhost:9090       |
| MLX Server  | http://localhost:8800       |

## Adding a Model

**1. Add it to `models.yaml`:**

```yaml
  - model_name: deepseek-coder-v2:16b
    litellm_params:
      model: openai/mlx-community/DeepSeek-Coder-V2-Instruct-4bit
      api_key: none
      api_base: http://host.docker.internal:8800/v1
    model_info:
      id: deepseek-coder-v2-16b
      description: "MoE 16B code model from DeepSeek."
      tasks: [code]
      params_b: 16
      active_b: 2.4
      arch: moe
      quant: 4bit
      context: 131072
      vram_gb: 9
```

**2. Pull the model:**

```bash
mlx_lm.server --model mlx-community/Qwen2.5-Coder-7B-Instruct-4bit --port 11434
```

**3. Reload LiteLLM:**

```bash
make restart-litellm
```

The model now appears in Open WebUI and is accessible via the LiteLLM API.

## Monitoring

Open Grafana at http://localhost:3000 (default password: `admin`/`admin`).

The provisioned dashboard ("LLM Inference Metrics") shows:
- **Overview** — requests in-flight, total, failed, LiteLLM memory
- **Throughput** — tokens/sec, request rate by model
- **Latency** — end-to-end request latency (p50/p95), LLM API latency
- **Tokens & Models** — cumulative tokens by model, latency per output token

## Swapping a Component

| Component     | Swap for             | What to change                                        |
|---------------|----------------------|-------------------------------------------------------|
| MLX-LM        | vLLM / Ollama       | Update `models.yaml` api_base + backend service        |
| LiteLLM       | Nginx / Traefik      | Point Open WebUI at new proxy; update Makefile targets |
| Open WebUI    | LobeChat / LibreChat | Replace the `open-webui` service in compose            |
| Grafana       | Netdata / Uptime Kuma| Replace the `grafana` service, keep Prometheus         |
| Prometheus    | VictoriaMetrics      | Drop-in replacement, same scrape config                |

The key abstraction: **all consumers talk to LiteLLM, never directly to the backend**.

## File Reference

```
.
├── .env                    Environment variables (ports, keys)
├── docker-compose.yml      All services
├── models.yaml             Model definitions + LiteLLM config (single source of truth)
├── Makefile                Convenience targets
├── prometheus/
│   └── prometheus.yml      Scrape config
└── grafana/
    └── provisioning/
        ├── datasources/
        │   └── datasource.yml
        └── dashboards/
            ├── dashboard.yml
            └── llm-metrics.json
```

## Make Targets

```
make up                  Start everything (auto-installs deps)
make down                Stop all services
make restart             Restart everything
make logs                Tail all logs (make logs s=litellm for one service)
make status              Show running services + loaded models

make pull MODEL=...      Pre-download a model from HuggingFace
make pull-all            Download all models in models.yaml
make models              List downloaded models

make restart-litellm     Reload models.yaml changes
make test                Smoke-test the LiteLLM API
make mlx-logs            Tail MLX server log
make clean               Stop stack + delete all volumes (destructive)
```
