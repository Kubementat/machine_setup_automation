# vLLM Usage Guide

This guide explains how to use vLLM after running the setup script. vLLM runs as a Docker container exposing an **OpenAI-compatible API** for LLM inference.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuring a Model](#configuring-a-model)
- [Starting and Stopping vLLM](#starting-and-stopping-vllm)
- [Making API Calls](#making-api-calls)
- [Using the Web UI](#using-the-web-ui)
- [Managing Models](#managing-models)
- [Configuration Reference](#configuration-reference)
- [Traefik Integration (Optional)](#traefik-integration-optional)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Software

- **Docker** with Docker Compose v2+
- **NVIDIA drivers** (for GPU acceleration) or **ROCm** (for AMD GPUs)

### Verify Docker

```bash
docker --version
docker compose version
```

### Verify GPU (NVIDIA)

```bash
nvidia-smi
```

### Verify GPU (AMD)

```bash
rocminfo
```

---

## Quick Start

### 1. Run the Setup Script

The script auto-detects your GPU and configures vLLM accordingly:

```bash
./tasks/setup-vllm.sh
```

**Force a specific backend:**

```bash
./tasks/setup-vllm.sh --nvidia   # NVIDIA CUDA
./tasks/setup-vllm.sh --amd      # AMD ROCm
./tasks/setup-vllm.sh --cpu      # CPU-only
```

### 2. Set a Model

Edit `/srv/vllm/.env` and set `VLLM_MODEL`:

```bash
# HuggingFace model ID (auto-downloaded by vLLM)
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct

# Or a local model path (after downloading)
VLLM_MODEL=/root/.cache/huggingface/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/latest
```

### 3. Start vLLM

```bash
cd /srv/vllm && docker compose up -d
```

### 4. Verify It's Running

```bash
# Health check
curl http://localhost:8000/health

# List loaded models
curl http://localhost:8000/v1/models
```

---

## Configuring a Model

### Option A: Use a HuggingFace Model ID

Set the model ID in `/srv/vllm/.env`:

```bash
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct
```

vLLM will automatically download the model on first start.

### Option B: Download a Model Manually

```bash
# Download a specific model
huggingface-cli download Qwen/Qwen2.5-7B-Instruct

# Then set the path in .env (vLLM will find it in the mounted HF cache)
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct
```

### Option C: Use an LM Studio Model

If you have models in `~/.lmstudio/models/`, they are auto-mounted into the container. Set the path:

```bash
VLLM_MODEL=/lmstudio-models/lmstudio-community/Qwen2.5-7B-Instruct-GGUF
```

---

## Starting and Stopping vLLM

### Start the Service

```bash
cd /srv/vllm && docker compose up -d
```

### Stop the Service

```bash
cd /srv/vllm && docker compose down
```

### View Logs

```bash
cd /srv/vllm && docker compose logs -f
```

### Check Status

```bash
./tasks/setup-vllm.sh --check
```

### Restart After Configuration Changes

After editing `/srv/vllm/.env`, restart the container:

```bash
cd /srv/vllm && docker compose down && docker compose up -d
```

---

## Making API Calls

vLLM exposes an **OpenAI-compatible API** at `http://localhost:8000/v1`.

### Chat Completions

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "temperature": 0.7,
    "max_tokens": 100
  }'
```

### Text Completions

```bash
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "prompt": "The capital of France is",
    "max_tokens": 50
  }'
```

### Using Python with OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="not-needed"  # vLLM doesn't require auth by default
)

response = client.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct",
    messages=[{"role": "user", "content": "Hello!"}],
    temperature=0.7
)

print(response.choices[0].message.content)
```

### Available API Endpoints

| Endpoint | Description |
|---|---|
| `/v1/chat/completions` | Chat completions |
| `/v1/completions` | Text completions |
| `/v1/models` | List available models |
| `/health` | Health check |
| `/ui` | Web UI (if enabled) |

---

## Using the Web UI

vLLM includes a built-in web interface accessible at `http://localhost:8000/ui` (or your configured port).

---

## Managing Models

### List Models in HF Cache

```bash
ls -la ~/.cache/huggingface/hub/
```

### Download a New Model

```bash
# Search for models
huggingface-cli search "Qwen3.6"

# Download a specific model
huggingface-cli download unsloth/Qwen3.6-35B-A3B-GGUF Qwen3.6-35B-A3B-UD-Q4_K_M.gguf

# Or download all files
huggingface-cli download unsloth/Qwen3.6-35B-A3B-GGUF
```

### Switch Models

1. Ensure the new model is downloaded (via HF cache or LM Studio)
2. Edit `/srv/vllm/.env` and set `VLLM_MODEL` to the new model
3. Restart vLLM:

```bash
cd /srv/vllm && docker compose down && docker compose up -d
```

---

## Configuration Reference

### Environment Variables in `/srv/vllm/.env`

| Variable | Default | Description |
|---|---|---|
| `VLLM_MODEL` | *(empty)* | HuggingFace model ID or local path |
| `HF_TOKEN` | *(empty)* | HuggingFace token for gated models |
| `VLLM_PORT` | `8000` | API port |
| `VLLM_GPU_UTIL` | `0.90` | GPU memory utilization (0.0–1.0) |
| `VLLM_DTYPE` | `auto` | Model dtype: `auto`, `bfloat16`, `float16`, `float32` |
| `VLLM_MAX_MODEL_LEN` | *(empty)* | Max context length in tokens |
| `VLLM_TENSOR_PARALLEL` | `1` | Number of GPUs for tensor parallelism |
| `VLLM_SHM_SIZE` | `8g` | Shared memory size for the container |
| `VLLM_EXTRA_ARGS` | *(empty)* | Additional vLLM server arguments |

### Example .env with Optimized Settings

```bash
# Model configuration
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct

# Performance tuning
VLLM_GPU_UTIL=0.85
VLLM_DTYPE=bfloat16
VLLM_MAX_MODEL_LEN=8192
VLLM_TENSOR_PARALLEL=1

# Enable prefix caching (reuse KV cache across requests)
VLLM_EXTRA_ARGS="--enable-prefix-caching"

# Optional: Enable API authentication
# VLLM_EXTRA_ARGS="--api-key secret123 --enable-prefix-caching"
```

---

## Traefik Integration (Optional)

For remote access via HTTPS with automatic certificate management.

### During Setup

```bash
./tasks/setup-vllm.sh --traefik --domain vllm.example.com
```

### After Setup

1. Edit `/srv/vllm/.env`:
```bash
VLLM_TRAEFIK=true
VLLM_DOMAIN=vllm.example.com
```

2. Restart vLLM:
```bash
cd /srv/vllm && docker compose down && docker compose up -d
```

### Access the API

```bash
curl https://vllm.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

---

## Troubleshooting

### vLLM Not Responding After Start

The container may still be loading the model. Wait a few minutes and check logs:

```bash
cd /srv/vllm && docker compose logs -f
```

### Port Already in Use

```bash
# Check what's using the port
ss -tln | grep :8000

# Use a different port
VLLM_PORT=8001 ./tasks/setup-vllm.sh
```

### GPU Not Detected

**NVIDIA:**
```bash
# Check if NVIDIA drivers are loaded
nvidia-smi
lsmod | grep nvidia

# If missing, install drivers or reboot
```

**AMD:**
```bash
# Check ROCm installation
rocminfo
ls /dev/kfd
ls /dev/dri/renderD*

# If missing, run the ROCm setup script first
./tasks/setup-rocm.sh
```

### Model Not Loading

1. Verify the model is downloaded:
```bash
ls ~/.cache/huggingface/hub/
```

2. Check the `.env` file for correct `VLLM_MODEL` path

3. Check container logs for errors:
```bash
cd /srv/vllm && docker compose logs vllm | grep -i error
```

### Container Won't Start

1. Check for configuration errors:
```bash
cd /srv/vllm && docker compose config
```

2. Check disk space:
```bash
df -h
```

3. Check if Docker daemon is running:
```bash
systemctl status docker
```

### Force Reinstallation

If something goes wrong, force a fresh setup:

```bash
./tasks/setup-vllm.sh --force --nvidia
```

---

## Useful Commands Summary

```bash
# Start vLLM
cd /srv/vllm && docker compose up -d

# Stop vLLM
cd /srv/vllm && docker compose down

# View logs
cd /srv/vllm && docker compose logs -f

# Open a shell inside the container
docker exec -it vllm bash

# Check installation status
./tasks/setup-vllm.sh --check

# List loaded models
curl http://localhost:8000/v1/models

# Download a model on the host
huggingface-cli download Qwen/Qwen2.5-7B-Instruct

# Make an API call
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen2.5-7B-Instruct", "messages": [{"role": "user", "content": "Hello!"}]}'
```
