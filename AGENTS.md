# Agent notes — local-llm-stack

## Connect to DGX Spark

From the Mac, open an interactive shell on the DGX:

```bash
ssh -t dgx_spark "cd /home/prabhav/; bash -l"
```

- SSH host alias: `dgx_spark` (NVIDIA Sync / Tailscale — **not** `spark-2393.local`)
- Project path on DGX: `~/Desktop/repositories/local-llm-stack`

### Quick checks after connect

```bash
tailscale status | grep gpu    # from Mac — should not say offline
ssh dgx_spark "hostname && uptime"
```

## Sync & run (from Mac)

```bash
export DGX_HOST=dgx_spark
export DGX_PATH=~/Desktop/repositories/local-llm-stack

make sync              # rsync code (skips .env)
make remote-config     # first time: .env + secrets on DGX
make remote-up         # sync + start stack on DGX
```

Or on the DGX after SSH:

```bash
cd ~/Desktop/repositories/local-llm-stack
make config
make up                # or: make up-ngrok
make health
make logs s=vllm
```

## Docker on DGX

If `docker ps` fails with permission denied, add the user to the `docker` group (interactive password required):

```bash
ssh -t dgx_spark 'sudo usermod -aG docker $USER'
# then reconnect so the group applies:
ssh -t dgx_spark "cd /home/prabhav/; bash -l"
docker ps
```

## Defaults

| Setting | Value |
|---------|--------|
| `DGX_HOST` | `dgx_spark` |
| `DGX_PATH` | `~/Desktop/repositories/local-llm-stack` |
| Backend | `nvidia` (vLLM) |
| Weights (`VLLM_MODEL`) | `Inferact/Qwen3.8-27B-NVFP4` (Blackwell-optimized 4-bit) |
| Client model names | `qwen3.8`, `qwen3.8-coder`, `qwen3-coder`, `qwen3.6-coder`, `qwen3.6`, `default` — all → Qwen3.8 weights |

Changing `VLLM_MODEL` does **not** require downstream clients to change their `model` field.
