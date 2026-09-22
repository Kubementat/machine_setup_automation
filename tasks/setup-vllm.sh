#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-vllm.sh
# Deploys vLLM as a Docker-based OpenAI-compatible inference server.
# Supports: NVIDIA (CUDA) | AMD (ROCm, amd64 only) | CPU fallback
# Architectures: amd64 (x86_64) | arm64 (aarch64, CUDA and CPU only)
#
# Images are pinned release tags by default (override with --image / VLLM_IMAGE).
# DGX Spark (GB10, sm_121) is auto-detected and gets Spark-appropriate
# defaults (lower gpu-memory-utilization, tuning guidance).
#
# HuggingFace models downloaded via 'hf download' are automatically
# available inside the container (HF cache dir is mounted).
#
# Usage:
#   ./setup-vllm.sh              # auto-detect GPU, set up vLLM
#   ./setup-vllm.sh --nvidia     # force NVIDIA/CUDA
#   ./setup-vllm.sh --amd        # force AMD/ROCm  (amd64 only)
#   ./setup-vllm.sh --cpu        # CPU only
#   ./setup-vllm.sh --check      # check installation status and exit
#   ./setup-vllm.sh --force      # re-create stack even if already present
#   ./setup-vllm.sh --help       # show help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/vllm"

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ── Pinned default image tags (verified: amd64 + arm64) ──────────────────────
# Nightly/:latest tags move — deployments should be reproducible. Override
# with --image / VLLM_IMAGE (e.g. nvcr.io/nvidia/vllm, lharillo/..., :gemma).
# C5/F2: v0.27.x is the first line with the SM121 kernel-less-build fix (#49904).
# Before bumping to >= 0.28, re-check: default --max-num-batched-tokens
# 8192->16384 (more reserved memory on a unified-memory box), reasoning_content
# output removal (#50624, breaks clients that parse thinking traces),
# KV-tiering metrics renamed block->chunk (#52812, breaks Grafana dashboards).
# AMD track (vllm/vllm-openai-rocm, pinned to the same tag): v0.27.1 verified
# present 2026-09-02 (F21 registry probe) — amd64-only single manifest
# (consistent with the aarch64 guard), Entrypoint=["vllm","serve"] (A1's
# nvcr.io/*-only prefix is correct for AMD), PYTORCH_ROCM_ARCH includes gfx1151
# (= AMD Strix Halo / evobox: prebuilt kernels at the pin). Re-run the F21
# registry probe before bumping either pin.
VLLM_DEFAULT_TAG="v0.27.1"

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-/srv/vllm}"
# HF cache dir on the host — models downloaded via 'hf download' live here.
# Mounted into the container so vLLM can serve them by HF model ID or path.
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_MODEL="${VLLM_MODEL:-}"            # HF model ID or /root/.cache/huggingface path
HF_TOKEN="${HF_TOKEN:-}"               # optional: required for gated models
VLLM_IMAGE="${VLLM_IMAGE:-}"           # full image override (default: pinned vllm/vllm-openai)
# Empty = resolved after backend detection:
#   0.80 on DGX Spark (sm_121, unified memory), 0.90 other GPU backends
VLLM_GPU_UTIL="${VLLM_GPU_UTIL:-}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"  # additional vLLM server arguments
# Unified-memory override (F1): DGX Spark GB10 and AMD Strix Halo share one DRAM
# pool between CPU, GPU, OS and page cache. Empty = auto-detect (Spark via
# compute capability 12.1, Strix Halo via rocminfo/lspci); true|false forces it.
VLLM_UNIFIED_MEMORY="${VLLM_UNIFIED_MEMORY:-}"
# Command-prefix asymmetry (A1): "vllm serve" is prepended for nvcr.io/* images
# only; resolved after the image is pinned. Empty = upstream/ROCm entrypoint is
# already ["vllm","serve"].
VLLM_COMMAND_PREFIX=""

# ── Multi-GPU / memory tuning ─────────────────────────────────────────────────
VLLM_TENSOR_PARALLEL="${VLLM_TENSOR_PARALLEL:-1}"  # tensor-parallel degree (# GPUs)
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-}"        # cap context length to reduce KV memory
# Empty default on purpose (re-run policy, ticket 12): a non-empty default
# would overwrite a value the operator stored in .env on a re-run. vLLM's
# own default is 'auto'; the --dtype flag is emitted only when set.
VLLM_DTYPE="${VLLM_DTYPE:-}"                       # model dtype: auto|bfloat16|float16|float32
VLLM_SHM_SIZE="${VLLM_SHM_SIZE:-8g}"               # shared memory size (increase for multi-GPU)
VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-}"           # max concurrent sequences (default: vLLM default)
VLLM_MAX_NUM_BATCHED_TOKENS="${VLLM_MAX_NUM_BATCHED_TOKENS:-}"  # max batched tokens per iteration (default: vLLM default)

# ── Serving options (flags emitted only when set) ─────────────────────────────
VLLM_SERVED_MODEL_NAME="${VLLM_SERVED_MODEL_NAME:-}"
VLLM_TRUST_REMOTE_CODE="${VLLM_TRUST_REMOTE_CODE:-}"    # true|false
VLLM_LOAD_FORMAT="${VLLM_LOAD_FORMAT:-}"                # e.g. fastsafetensors
VLLM_REASONING_PARSER="${VLLM_REASONING_PARSER:-}"      # e.g. qwen3, nemotron_v3
VLLM_TOOL_CALL_PARSER="${VLLM_TOOL_CALL_PARSER:-}"      # e.g. qwen3, qwen3_xml
VLLM_ENABLE_AUTO_TOOL_CHOICE="${VLLM_ENABLE_AUTO_TOOL_CHOICE:-}"  # true|false

# ── Speculative decoding (A4: quoting-free shortcuts for --speculative-config) ─
VLLM_SPEC_METHOD="${VLLM_SPEC_METHOD:-}"   # e.g. mtp (needs an MTP-capable checkpoint)
VLLM_SPEC_MODEL="${VLLM_SPEC_MODEL:-}"     # draft model for methods that use one
VLLM_SPEC_TOKENS="${VLLM_SPEC_TOKENS:-}"   # num_speculative_tokens (positive int)

# ── Backend / quantization levers (C3, research §5.3 — all default to auto) ───
# Contested levers stay opt-in: empty/'auto' emits no flag (vLLM picks).
VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-}"           # e.g. modelopt | mxfp4 | gptq_marlin
VLLM_MOE_BACKEND="${VLLM_MOE_BACKEND:-}"             # MoE kernel backend
VLLM_LINEAR_BACKEND="${VLLM_LINEAR_BACKEND:-}"       # linear-layer kernel backend
VLLM_ATTENTION_BACKEND="${VLLM_ATTENTION_BACKEND:-}" # attention kernel backend
VLLM_KV_CACHE_DTYPE="${VLLM_KV_CACHE_DTYPE:-}"       # e.g. fp8
VLLM_ASYNC_SCHEDULING="${VLLM_ASYNC_SCHEDULING:-}"   # true|false
VLLM_ENABLE_CHUNKED_PREFILL="${VLLM_ENABLE_CHUNKED_PREFILL:-}"  # true|false

# ── Operator-injected container env (F3 — any backend) ────────────────────
# Opt-in KEY=VALUE pairs, space-separated inside the one value. Injected into
# the container via extra-vars.env. Version-specific workarounds, e.g.:
#   VLLM_EXTRA_ENV="TORCH_CUDA_ARCH_LIST=12.1a VLLM_MARLIN_USE_ATOMIC_ADD=1"
#     (NVIDIA: TORCH_CUDA_ARCH_LIST only steers JIT builds — the shipped image's
#      arch list has no 12.1; VLLM_MARLIN_USE_ATOMIC_ADD is live in 0.27.1 and
#      per research §2 reported required for correct Marlin output on sm_121
#      [field report]. The old FLASHINFER MXFP4 env var is NOT known to 0.27.1.)
#   VLLM_EXTRA_ENV="HSA_OVERRIDE_GFX_VERSION=11.0.0"  (AMD ROCm escape hatches)
VLLM_EXTRA_ENV="${VLLM_EXTRA_ENV:-}"
VLLM_SPARK_EXTRA_ENV="${VLLM_SPARK_EXTRA_ENV:-}"  # deprecated alias (F3): mapped to VLLM_EXTRA_ENV after arg parsing, warns once
VLLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-}"  # empty = 900s (GPU) / 120s (CPU)
WARMUP=1                                          # post-health warmup request (--no-warmup to skip)

BACKEND=""    # nvidia | amd | cpu  (empty = auto-detect)
FORCE=0
CHECK_ONLY=0
INTERACTIVE=false   # re-run policy (ticket 12): offer tear-down/re-create of an existing stack

ARCH=$(uname -m)  # x86_64 | aarch64

# ── Input validation ──────────────────────────────────────────────────────────
# Validate and sanitize user-controlled variables to prevent template injection
# in envsubst templates. This ensures safe writing to .env and compose files.

validate_model_id() {
  local model="$1"
  # Allow alphanumeric, hyphens, underscores, slashes, colons (for paths/HF IDs)
  if [[ -n "$model" && ! "$model" =~ ^[a-zA-Z0-9_/.:-]+$ ]]; then
    error "VLLM_MODEL contains invalid characters. Allowed: alphanumeric, hyphens, underscores, slashes, colons."
  fi
}

validate_extra_args() {
  local args="$1"
  # Allow only safe characters for command-line arguments
  # Reject backticks, dollar, semicolon, pipe, ampersand, redirection which could break config
  if [[ -n "$args" ]]; then
    local dangerous_pattern='[\`\$;|&<>]'
    if [[ "$args" =~ $dangerous_pattern ]]; then
      error "VLLM_EXTRA_ARGS contains disallowed characters (backtick, \$, \;, \|, \&, \<, \>)."
    fi
  fi
}

validate_port() {
  local port="$1"
  if [[ -n "$port" && (! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535) ]]; then
    error "VLLM_PORT must be a number between 1 and 65535."
  fi
}

validate_gpu_util() {
  local util="$1"
  [[ -z "$util" ]] && return 0
  # A2: strict number check first (the old bc-based range check was unreachable
  # for short values and evaluated non-numeric junk to 0, accepting 'abc').
  if [[ ! "$util" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    error "VLLM_GPU_UTIL must be a number between 0.0 and 1.0 (got: ${util})."
  fi
  awk -v u="$util" 'BEGIN { exit (u > 0 && u <= 1) ? 0 : 1 }' \
    || error "VLLM_GPU_UTIL must be > 0.0 and <= 1.0 (got: ${util})."
}

validate_tensor_parallel() {
  local tp="$1"
  if [[ -n "$tp" && (! "$tp" =~ ^[0-9]+$ || "$tp" -lt 1) ]]; then
    error "VLLM_TENSOR_PARALLEL must be a positive integer."
  fi
}

validate_dtype() {
  local dtype="$1"
  if [[ -z "$dtype" ]]; then return 0; fi
  case "$dtype" in
    auto|bfloat16|float16|float32|float8_e4m3fn|float8_e5m2) ;;
    *) error "VLLM_DTYPE must be one of: auto bfloat16 float16 float32 float8_e4m3fn float8_e5m2" ;;
  esac
}

validate_max_num_seqs() {
  local val="$1"
  if [[ -n "$val" && (! "$val" =~ ^[0-9]+$ || "$val" -lt 1) ]]; then
    error "VLLM_MAX_NUM_SEQS must be a positive integer."
  fi
}

validate_max_num_batched_tokens() {
  local val="$1"
  if [[ -n "$val" && (! "$val" =~ ^[0-9]+$ || "$val" -lt 1) ]]; then
    error "VLLM_MAX_NUM_BATCHED_TOKENS must be a positive integer."
  fi
}

validate_spec_tokens() {
  local val="$1"
  if [[ -n "$val" && (! "$val" =~ ^[0-9]+$ || "$val" -lt 1) ]]; then
    error "VLLM_SPEC_TOKENS must be a positive integer."
  fi
}

validate_shm_size() {
  local sz="$1"
  if [[ -n "$sz" && ! "$sz" =~ ^[0-9]+[bBkKmMgG]?$ ]]; then
    error "VLLM_SHM_SIZE must be a size string like '8g', '512m', '1024k'."
  fi
}

validate_image() {
  local img="$1"
  if [[ -n "$img" && ! "$img" =~ ^[a-zA-Z0-9_./:@-]+$ ]]; then
    error "VLLM_IMAGE contains invalid characters. Expected a Docker image reference like repo/org/image:tag."
  fi
  if [[ -n "$img" ]] && { [[ "$img" == *:latest ]] || [[ "$img" != *:* && "$img" != *@* ]]; }; then
    warn "VLLM_IMAGE '${img}' uses a moving tag — deployments with :latest/digest-less tags are not reproducible. Pin a release tag or digest."
  fi
}

validate_bool_opt() {
  local name="$1" val="$2"
  if [[ -n "$val" && ! ( "$val" == "true" || "$val" == "false" ) ]]; then
    error "${name} must be true or false (got: ${val})."
  fi
}

# Identifier-like free values: parser names, served model names, load formats
validate_ident_opt() {
  local name="$1" val="$2"
  if [[ -n "$val" && ! "$val" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
    error "${name} contains invalid characters. Allowed: alphanumeric, dot, underscore, slash, hyphen."
  fi
}

validate_extra_env() {
  local kv
  if [[ -z "$1" ]]; then return 0; fi
  for kv in $1; do
    if [[ ! "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:@+-]+$ ]]; then
      error "VLLM_EXTRA_ENV entry '${kv}' is not a valid KEY=VALUE pair (no spaces, no shell characters)."
    fi
  done
}

# Apply validations (only for non-empty values)
validate_model_id "${VLLM_MODEL}"
validate_extra_args "${VLLM_EXTRA_ARGS}"
validate_port "${VLLM_PORT}"
validate_gpu_util "${VLLM_GPU_UTIL}"
validate_image "${VLLM_IMAGE}"
validate_tensor_parallel "${VLLM_TENSOR_PARALLEL}"
validate_dtype "${VLLM_DTYPE}"
validate_shm_size "${VLLM_SHM_SIZE}"
validate_max_num_seqs "${VLLM_MAX_NUM_SEQS}"
validate_max_num_batched_tokens "${VLLM_MAX_NUM_BATCHED_TOKENS}"
validate_ident_opt "VLLM_SERVED_MODEL_NAME" "${VLLM_SERVED_MODEL_NAME}"
validate_bool_opt "VLLM_TRUST_REMOTE_CODE" "${VLLM_TRUST_REMOTE_CODE}"
validate_ident_opt "VLLM_LOAD_FORMAT" "${VLLM_LOAD_FORMAT}"
validate_ident_opt "VLLM_REASONING_PARSER" "${VLLM_REASONING_PARSER}"
validate_ident_opt "VLLM_TOOL_CALL_PARSER" "${VLLM_TOOL_CALL_PARSER}"
validate_bool_opt "VLLM_ENABLE_AUTO_TOOL_CHOICE" "${VLLM_ENABLE_AUTO_TOOL_CHOICE}"
validate_bool_opt "VLLM_UNIFIED_MEMORY" "${VLLM_UNIFIED_MEMORY}"
validate_ident_opt "VLLM_SPEC_METHOD" "${VLLM_SPEC_METHOD}"
validate_ident_opt "VLLM_SPEC_MODEL" "${VLLM_SPEC_MODEL}"
validate_spec_tokens "${VLLM_SPEC_TOKENS}"
validate_ident_opt "VLLM_QUANTIZATION" "${VLLM_QUANTIZATION}"
validate_ident_opt "VLLM_MOE_BACKEND" "${VLLM_MOE_BACKEND}"
validate_ident_opt "VLLM_LINEAR_BACKEND" "${VLLM_LINEAR_BACKEND}"
validate_ident_opt "VLLM_ATTENTION_BACKEND" "${VLLM_ATTENTION_BACKEND}"
validate_ident_opt "VLLM_KV_CACHE_DTYPE" "${VLLM_KV_CACHE_DTYPE}"
validate_bool_opt "VLLM_ASYNC_SCHEDULING" "${VLLM_ASYNC_SCHEDULING}"
validate_bool_opt "VLLM_ENABLE_CHUNKED_PREFILL" "${VLLM_ENABLE_CHUNKED_PREFILL}"
validate_extra_env "${VLLM_EXTRA_ENV}"
if [[ -n "${VLLM_HEALTH_TIMEOUT}" && (! "${VLLM_HEALTH_TIMEOUT}" =~ ^[0-9]+$ || "${VLLM_HEALTH_TIMEOUT}" -lt 1) ]]; then
  error "VLLM_HEALTH_TIMEOUT must be a positive integer (seconds)."
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}Usage:${RESET} $0 [OPTIONS]"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo "  --nvidia              Force NVIDIA CUDA backend"
  echo "  --amd                 Force AMD ROCm backend  (amd64 only; ROCm image"
  echo "                        vllm/vllm-openai-rocm pinned at the same tag — registry-verified"
  echo "                        amd64-only with prebuilt gfx1151 (Strix Halo) kernels)"
  echo "  --cpu                 Force CPU-only backend (BEST-EFFORT: the pinned"
  echo "                        vllm/vllm-openai image is a CUDA build and currently fails"
  echo "                        to serve --device cpu — follow-up ticket vllm-cpu-image)"
  echo "  --port <n>            API port  (default: 8000)"
  echo "  --hf-token <token>    HuggingFace token for gated models"
  echo "  --hf-cache <path>     Host HF cache dir  (default: ~/.cache/huggingface)"
  echo "  --image <image:tag>   Docker image override (default: pinned vllm/vllm-openai)"
  echo "  --gpu-util <frac>     GPU memory utilization 0.0–1.0"
  echo "                        (default: 0.80 on DGX Spark, 0.90 other NVIDIA/AMD GPUs)"
  echo "  --tensor-parallel <n> Number of GPUs for tensor parallelism  (default: 1)"
  echo "  --max-model-len <n>   Max context length – reduce to save KV memory  (default: model max)"
  echo "  --dtype <dtype>       Model dtype: auto|bfloat16|float16|float32  (default: auto)"
  echo "  --shm-size <size>     Container shm size (the CPU backend's mechanism — GPU"
  echo "                        backends run with ipc: host, which wins at runtime)  (default: 8g)"
  echo "  --max-num-seqs <n>    Max concurrent sequences  (default: vLLM default)"
  echo "  --max-num-batched-tokens <n>  Max batched tokens per iteration  (default: vLLM default)"
  echo "  --served-model-name <name>  Client-facing model ID"
  echo "  --trust-remote-code   Trust remote code in the model repo"
  echo "  --load-format <fmt>   Weight load format (e.g. fastsafetensors)"
  echo "  --reasoning-parser <name>  Reasoning parser for agent-ready serving"
  echo "  --tool-call-parser <name>  Tool-call parser for agent-ready serving"
  echo "  --enable-auto-tool-choice  Enable automatic tool choice"
  echo "  --spec-method <name>  Speculative decoding method (e.g. mtp) — quoting-free"
  echo "                        shortcut for --speculative-config"
  echo "  --spec-model <model>  Draft model for speculative decoding"
  echo "  --spec-tokens <n>     num_speculative_tokens (research: start 6, sweep ±3)"
  echo "  --quantization <name>       Quantization kernel (default: auto; NVFP4 -> modelopt;"
  echo "                              leave UNSET for pre-quantized checkpoints)"
  echo "  --moe-backend <name>        MoE kernel backend (default: auto)"
  echo "  --linear-backend <name>     Linear-layer kernel backend (default: auto)"
  echo "  --attention-backend <name>  Attention kernel backend (default: auto — forcing one"
  echo "                              global backend can crash hybrid models at init_device)"
  echo "  --kv-cache-dtype <dtype>    KV cache dtype fp8 (repetition-loop risk; never with DFlash)"
  echo "  --async-scheduling          Enable asynchronous scheduling"
  echo "  --enable-chunked-prefill    Enable chunked prefill (up to ~9x slower on Mamba-dominant MoE)"
  echo "  --extra-env <KEY=VALUE>    Extra container env vars, any backend — version-specific"
  echo "                             workarounds; one KEY=VALUE per invocation, several"
  echo "                             vars = space-separated inside the one value"
  echo "  --spark-env <KEY=VALUE>    Deprecated alias for --extra-env (warns once)"
  echo "  --health-timeout <s>  Seconds to wait for the stack to come up and for /health (default: 900 GPU / 120 CPU)."
  echo "                        Also drives the compose healthcheck start_period (C1): cold start —"
  echo "                        JIT + weight load — can exceed 7 min on DGX Spark (sm_121)."
  echo "  --no-warmup           Skip the post-health warmup request"
  echo "  --dir <path>          Installation directory  (default: /srv/vllm)"
  echo "  --force               Re-create stack even if already present"
  echo "  --interactive         Offer tear-down/re-create of an existing stack (default: converge)"
  echo "  --check               Check installation status and exit"
  echo "  --help                Show this help"
  echo ""
  echo -e "${BOLD}Environment variables${RESET} (all flags above have env-var equivalents):"
  echo "  PROJECT_DIR, HF_CACHE_DIR, VLLM_PORT, HF_TOKEN, VLLM_IMAGE,"
  echo "  VLLM_GPU_UTIL, VLLM_TENSOR_PARALLEL, VLLM_MAX_MODEL_LEN,"
  echo "  VLLM_DTYPE, VLLM_SHM_SIZE, VLLM_EXTRA_ARGS,"
  echo "  VLLM_MAX_NUM_SEQS, VLLM_MAX_NUM_BATCHED_TOKENS,"
  echo "  VLLM_SPEC_METHOD, VLLM_SPEC_MODEL, VLLM_SPEC_TOKENS,"
  echo "  VLLM_QUANTIZATION, VLLM_MOE_BACKEND, VLLM_LINEAR_BACKEND,"
  echo "  VLLM_ATTENTION_BACKEND, VLLM_KV_CACHE_DTYPE, VLLM_ASYNC_SCHEDULING,"
  echo "  VLLM_ENABLE_CHUNKED_PREFILL,"
  echo "  VLLM_SERVED_MODEL_NAME, VLLM_TRUST_REMOTE_CODE, VLLM_LOAD_FORMAT,"
  echo "  VLLM_REASONING_PARSER, VLLM_TOOL_CALL_PARSER,"
  echo "  VLLM_ENABLE_AUTO_TOOL_CHOICE, VLLM_EXTRA_ENV (VLLM_SPARK_EXTRA_ENV deprecated), VLLM_HEALTH_TIMEOUT,"
  echo "  VLLM_UNIFIED_MEMORY (true|false forces the unified-memory verdict;"
  echo "                       empty = auto-detect: DGX Spark or AMD Strix Halo)"
  echo ""
  echo -e "${BOLD}Model selection${RESET} (set after install, in ${PROJECT_DIR}/.env):"
  echo "  VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct            # HF model ID (auto-downloaded)"
  echo "  VLLM_MODEL=/root/.cache/huggingface/hub/...    # local snapshot path in container"
  echo ""
  echo -e "${BOLD}Model fit (DGX Spark, 128 GB unified memory):${RESET}"
  echo "  100–130B MoE NVFP4 (~10–15B active) is the best Spark fit;"
  echo "  up to ~130B NVFP4 fits the 128 GB pool with usable KV headroom."
  echo "  Dense models are poorly"
  echo "  matched. See the NVIDIA DGX Spark vLLM model support matrix:"
  echo "  https://github.com/NVIDIA/dgx-spark-playbooks/blob/main/nvidia/vllm/README.md"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo "  $0                                  # auto-detect GPU, set up vLLM"
  echo "  $0 --nvidia --port 8001             # CUDA on port 8001"
  echo "  $0 --amd                            # ROCm  (amd64 only)"
  echo "  $0 --cpu                            # CPU-only"
  echo "  $0 --port 8000                       # published on the LAN; restrict with ufw"
  echo "  $0 --image nvcr.io/nvidia/vllm:26.05-py3   # NGC image (needs: docker login nvcr.io)"
  echo "  $0 --check                          # show stack status"
  echo "  $0 --force --nvidia                 # re-create CUDA stack"
  echo ""
  echo -e "${BOLD}Re-run policy${RESET} (converge by default):"
  echo "  Re-running an existing stack converges it: the .env and compose file are"
  echo "  re-rendered (stored values reused), and 'docker compose up -d' reconciles"
  echo "  only what changed. Model args that diverge from the running stack are"
  echo "  printed with the exact re-create command. --force (or interactive 'y')"
  echo "  tears down and re-creates."
  echo ""
  echo -e "${BOLD}Exposure${RESET} (direct, local network — no reverse proxy):"
  echo "  vLLM is published on VLLM_PORT and consumed from the LAN only. A proxy"
  echo "  front was deliberately removed (operator decision, 2026-09-01; no in-repo"
  echo "  consumer needs the proxy network). This is a deliberate divergence from"
  echo "  research §12.9 — access control is ufw + LAN trust, not a proxy front."
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nvidia)           BACKEND="nvidia" ;;
    --amd)              BACKEND="amd" ;;
    --cpu)              BACKEND="cpu" ;;
    --port)             shift; VLLM_PORT="$1" ;;
    --hf-token)         shift; HF_TOKEN="$1" ;;
    --hf-cache)         shift; HF_CACHE_DIR="$1" ;;
    --image)            shift; VLLM_IMAGE="$1" ;;
    --gpu-util)         shift; VLLM_GPU_UTIL="$1" ;;
    --tensor-parallel)  shift; VLLM_TENSOR_PARALLEL="$1" ;;
    --max-model-len)    shift; VLLM_MAX_MODEL_LEN="$1" ;;
    --dtype)            shift; VLLM_DTYPE="$1" ;;
    --shm-size)         shift; VLLM_SHM_SIZE="$1" ;;
    --max-num-seqs)         shift; VLLM_MAX_NUM_SEQS="$1" ;;
    --max-num-batched-tokens) shift; VLLM_MAX_NUM_BATCHED_TOKENS="$1" ;;
    --served-model-name) shift; VLLM_SERVED_MODEL_NAME="$1" ;;
    --trust-remote-code) VLLM_TRUST_REMOTE_CODE="true" ;;
    --load-format)      shift; VLLM_LOAD_FORMAT="$1" ;;
    --reasoning-parser) shift; VLLM_REASONING_PARSER="$1" ;;
    --tool-call-parser) shift; VLLM_TOOL_CALL_PARSER="$1" ;;
    --enable-auto-tool-choice) VLLM_ENABLE_AUTO_TOOL_CHOICE="true" ;;
    --spec-method)      shift; VLLM_SPEC_METHOD="$1" ;;
    --spec-model)       shift; VLLM_SPEC_MODEL="$1" ;;
    --spec-tokens)      shift; VLLM_SPEC_TOKENS="$1" ;;
    --quantization)     shift; VLLM_QUANTIZATION="$1" ;;
    --moe-backend)      shift; VLLM_MOE_BACKEND="$1" ;;
    --linear-backend)   shift; VLLM_LINEAR_BACKEND="$1" ;;
    --attention-backend) shift; VLLM_ATTENTION_BACKEND="$1" ;;
    --kv-cache-dtype)   shift; VLLM_KV_CACHE_DTYPE="$1" ;;
    --async-scheduling) VLLM_ASYNC_SCHEDULING="true" ;;
    --enable-chunked-prefill) VLLM_ENABLE_CHUNKED_PREFILL="true" ;;
    --extra-env)        shift; VLLM_EXTRA_ENV="$1" ;;
    --spark-env)        shift; VLLM_SPARK_EXTRA_ENV="$1" ;;  # deprecated alias, mapped below
    --health-timeout)   shift; VLLM_HEALTH_TIMEOUT="$1" ;;
    --no-warmup)        WARMUP=0 ;;
    --dir)              shift; PROJECT_DIR="$1" ;;
    --traefik|--domain)
      error "Traefik integration was removed from setup-vllm.sh: the vLLM endpoint is always published directly on VLLM_PORT for the local network. Use --port to pick the port and tasks/configure-firewall.sh (ufw) to restrict which networks may reach it."
      ;;
    --force)            FORCE=1 ;;
    --interactive)      INTERACTIVE=true ;;
    --check)            CHECK_ONLY=1 ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# F3: map the deprecated VLLM_SPARK_EXTRA_ENV / --spark-env to VLLM_EXTRA_ENV
# (single site → warns exactly once). Explicit VLLM_EXTRA_ENV wins.
if [[ -n "${VLLM_SPARK_EXTRA_ENV}" && -z "${VLLM_EXTRA_ENV}" ]]; then
  warn "VLLM_SPARK_EXTRA_ENV / --spark-env is deprecated — use VLLM_EXTRA_ENV (works on every backend)."
  VLLM_EXTRA_ENV="${VLLM_SPARK_EXTRA_ENV}"
elif [[ -n "${VLLM_SPARK_EXTRA_ENV}" ]]; then
  warn "VLLM_SPARK_EXTRA_ENV / --spark-env is deprecated — both it and VLLM_EXTRA_ENV are set; using VLLM_EXTRA_ENV."
fi
validate_extra_env "${VLLM_EXTRA_ENV}"

# ── Guard: ROCm on arm64 is not supported ─────────────────────────────────────
if [[ "$ARCH" == "aarch64" && "$BACKEND" == "amd" ]]; then
  error "ROCm is not supported on arm64 (aarch64). Use --cpu or --nvidia (Grace-Hopper) instead."
fi

# ── Guard: tensor parallelism requires a GPU backend ─────────────────────────
if [[ "${VLLM_TENSOR_PARALLEL}" -gt 1 && "$BACKEND" == "cpu" ]]; then
  error "Tensor parallelism (--tensor-parallel > 1) requires a GPU backend (--nvidia or --amd)."
fi

# ── Detect existing stack ──────────────────────────────────────────────────────
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
ENV_FILE="${PROJECT_DIR}/.env"

# Re-run policy (ticket 12): reuse-first .env values. An explicitly set value
# (env or CLI) wins; otherwise the value stored in the existing .env is reused
# so a re-run never resets operator configuration (incl. the HF_TOKEN secret).
_env_reused=()
_env_reuse() { # <var-name> <key>
  local var_name="$1" key="$2" current
  if [[ -z "${!var_name}" && -f "$ENV_FILE" ]]; then
    current="$(grep -m1 "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    if [[ -n "$current" ]]; then
      printf -v "$var_name" '%s' "$current"
      _env_reused+=("${key}")
    fi
  fi
}
_env_reuse VLLM_MODEL                  VLLM_MODEL
_env_reuse HF_TOKEN                    HF_TOKEN
_env_reuse VLLM_GPU_UTIL               VLLM_GPU_UTIL
_env_reuse VLLM_DTYPE                  VLLM_DTYPE
_env_reuse VLLM_MAX_MODEL_LEN          VLLM_MAX_MODEL_LEN
_env_reuse VLLM_SERVED_MODEL_NAME      VLLM_SERVED_MODEL_NAME
_env_reuse VLLM_TRUST_REMOTE_CODE      VLLM_TRUST_REMOTE_CODE
_env_reuse VLLM_LOAD_FORMAT            VLLM_LOAD_FORMAT
_env_reuse VLLM_REASONING_PARSER       VLLM_REASONING_PARSER
_env_reuse VLLM_TOOL_CALL_PARSER       VLLM_TOOL_CALL_PARSER
_env_reuse VLLM_ENABLE_AUTO_TOOL_CHOICE VLLM_ENABLE_AUTO_TOOL_CHOICE
_env_reuse VLLM_EXTRA_ARGS             VLLM_EXTRA_ARGS
_env_reuse VLLM_MAX_NUM_SEQS           VLLM_MAX_NUM_SEQS
_env_reuse VLLM_MAX_NUM_BATCHED_TOKENS VLLM_MAX_NUM_BATCHED_TOKENS
_env_reuse VLLM_SPEC_METHOD            VLLM_SPEC_METHOD
_env_reuse VLLM_SPEC_MODEL             VLLM_SPEC_MODEL
_env_reuse VLLM_SPEC_TOKENS            VLLM_SPEC_TOKENS
_env_reuse VLLM_QUANTIZATION           VLLM_QUANTIZATION
_env_reuse VLLM_MOE_BACKEND            VLLM_MOE_BACKEND
_env_reuse VLLM_LINEAR_BACKEND         VLLM_LINEAR_BACKEND
_env_reuse VLLM_ATTENTION_BACKEND      VLLM_ATTENTION_BACKEND
_env_reuse VLLM_KV_CACHE_DTYPE         VLLM_KV_CACHE_DTYPE
_env_reuse VLLM_ASYNC_SCHEDULING       VLLM_ASYNC_SCHEDULING
_env_reuse VLLM_ENABLE_CHUNKED_PREFILL VLLM_ENABLE_CHUNKED_PREFILL

# D1: reused .env values must pass the same validation as fresh input — a
# hand-edited .env previously bypassed these validators entirely.
validate_model_id "${VLLM_MODEL}"
validate_gpu_util "${VLLM_GPU_UTIL}"
validate_extra_args "${VLLM_EXTRA_ARGS}"
validate_max_num_seqs "${VLLM_MAX_NUM_SEQS}"
validate_max_num_batched_tokens "${VLLM_MAX_NUM_BATCHED_TOKENS}"
validate_dtype "${VLLM_DTYPE}"

print_found_status() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║     vLLM stack is already installed ✓        ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Compose file:${RESET}  ${COMPOSE_FILE}"
  if docker compose -f "${COMPOSE_FILE}" ps --quiet 2>/dev/null | grep -q .; then
    echo -e "  ${BOLD}Status:${RESET}        ${GREEN}running${RESET}"
    docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null | tail -n +2 | \
      while IFS= read -r line; do echo "    ${line}"; done
  else
    echo -e "  ${BOLD}Status:${RESET}        ${YELLOW}stopped${RESET}"
  fi
  echo ""
}

step "Checking for existing vLLM installation"

VLLM_STACK_RUNNING=false
RECREATE_VLLM=false

if [[ -f "$COMPOSE_FILE" ]]; then
  print_found_status
  if docker compose -f "${COMPOSE_FILE}" ps --quiet 2>/dev/null | grep -q .; then
    VLLM_STACK_RUNNING=true
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "Run with ${BOLD}--force${RESET} to re-create the stack."
    exit 0
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    RECREATE_VLLM=true
    warn "--force specified – tearing down existing stack."
    (cd "$PROJECT_DIR" && docker compose down 2>/dev/null) || true
    echo ""
  elif [[ "$INTERACTIVE" == "true" && "$VLLM_STACK_RUNNING" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      RECREATE_VLLM=true
      warn "Re-create confirmed – tearing down existing stack."
      (cd "$PROJECT_DIR" && docker compose down 2>/dev/null) || true
      echo ""
    fi
  fi
  if [[ "$RECREATE_VLLM" != "true" ]]; then
    # Re-run policy (ticket 12): CONVERGE — the .env and compose file are
    # re-rendered below (stored values reused) and 'docker compose up -d'
    # reconciles only what changed. Model-arg divergence on the running stack
    # is printed with the exact remedy (see the hash check after render).
    info "Converging the existing stack (no tear-down)."
    if [[ ${#_env_reused[@]} -gt 0 ]]; then
      info "Reused ${#_env_reused[@]} value(s) from ${ENV_FILE}: ${_env_reused[*]}"
    fi
  fi
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo ""
    echo -e "  ${YELLOW}vLLM does not appear to be installed.${RESET}"
    echo -e "  Run the script without ${BOLD}--check${RESET} to install it."
    echo ""
    exit 0
  fi
  success "No existing installation found – proceeding with fresh install."
fi

# ── Pre-flight: sanity ────────────────────────────────────────────────────────
step "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] && warn "Running as root – not recommended."

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Continuing anyway…"
fi

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
fi

# NVIDIA pre-flight: driver + container toolkit (for Docker deployments the
# host CUDA *toolkit* is irrelevant — the image ships CUDA, the driver matters).
if [[ "$BACKEND" == "nvidia" ]] || [[ -z "$BACKEND" ]]; then
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    if [[ -n "$DRIVER_VER" ]]; then
      DRIVER_MAJOR="${DRIVER_VER%%.*}"
      if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ && "$DRIVER_MAJOR" -lt 580 ]]; then
        if nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | grep -qi "12\.1"; then
          error "GPU driver $DRIVER_VER is too old for DGX Spark (GB10) — a CUDA 13-era driver (>= 580) is required."
        fi
        warn "GPU driver $DRIVER_VER is old; the pinned vLLM image (CUDA 13) needs driver >= 580. Update the driver or override the image with --image."
      else
        info "GPU driver ${DRIVER_VER} detected (CUDA 13 compatible: >= 580)."
        # B5: community field report (research §3.2), NOT a vendor advisory.
        if is_spark && [[ "$DRIVER_MAJOR" == "590" ]]; then
          warn "Driver 590.x is reported to deadlock CUDA graphs on GB10 — community guidance is to stay on 580.x (field report, not a vendor advisory; verify: nvidia-smi --query-gpu=driver_version)."
        fi
      fi
    fi
    # The rendered compose file requests the GPU as the CDI device
    # nvidia.com/gpu=all, so the spec must exist before `compose up` — a
    # missing one fails the container start with "unresolvable CDI devices".
    if ! command -v nvidia-ctk &>/dev/null; then
      error "nvidia-ctk is not installed. Required for the CDI GPU spec. Run setup-nvidia-container.sh first."
    fi
    if ! nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
      error "No CDI spec for nvidia.com/gpu=all. Run setup-nvidia-container.sh — it generates the
  spec and installs an apt hook that regenerates it after every driver upgrade.
  Manual equivalent: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    fi
    success "CDI device nvidia.com/gpu=all is available."
    # Host CUDA toolkit — informational only (the container image ships CUDA)
    if command -v nvcc &>/dev/null; then
      CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1 || true)
      [[ -n "$CUDA_VER" ]] && info "Host CUDA toolkit: $CUDA_VER (informational — the image ships its own CUDA)."
    else
      info "No host CUDA toolkit (nvcc) — fine for Docker deployments."
    fi
  fi
fi

# Blackwell INT8 quantization warning
if [[ "$BACKEND" == "nvidia" ]] || [[ -z "$BACKEND" ]]; then
  if nvidia-smi &>/dev/null && nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | grep -qi "12\.1"; then
    if echo "${VLLM_EXTRA_ARGS}" | grep -qi "int8"; then
      error "INT8 quantization is NOT supported on Blackwell (GB10). The Spark path is NVFP4/MXFP4 (research §12):"
      error "  ModelOpt NVFP4 checkpoints -> --quantization modelopt"
      error "  openai/gpt-oss-* (MXFP4)   -> --quantization mxfp4"
      error "  GPTQ checkpoints           -> --quantization gptq_marlin"
      error "  pre-quantized checkpoints  -> leave --quantization UNSET (vLLM auto-detects)"
      error "Landmine (research §4.2): --quantization mxfp4 on a BF16 HF checkpoint crashes in fused_moe/layer.py (IndexError)."
    fi
  fi
fi

COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "0.0.0")
COMPOSE_MAJOR=$(echo "$COMPOSE_VER" | cut -d'.' -f1)
if [[ "$COMPOSE_MAJOR" -lt 2 ]]; then
  warn "Docker Compose v2+ recommended. Current: ${COMPOSE_VER}"
fi

# Port check — direct exposure is the only mode (E1). A running vllm stack owns
# its own published port; only a foreign listener is a conflict (A3, F11) —
# otherwise a converge re-run of a running stack would hard-error.
_own_ports="$(docker inspect --format \
  '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}} {{end}}{{end}}' \
  vllm 2>/dev/null || true)"
if ss -tln 2>/dev/null | grep -q ":${VLLM_PORT} " \
   && ! grep -qw "${VLLM_PORT}" <<<"${_own_ports:-}"; then
  error "Port ${VLLM_PORT} is already in use by another service. Set a different VLLM_PORT."
fi

# ── DGX Spark (GB10) detection: compute capability 12.1 (sm_121) ─────────────
# Note: nvidia-smi reports N/A for memory fields on Spark (UMA) — never use
# memory-based logic here; compute capability is the reliable signal.
is_spark() {
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | grep -qi "12\.1"
}

# Unified-memory hosts: CPU, GPU, OS and page cache share one DRAM pool (DGX Spark GB10, AMD Strix
# Halo). Memory queries are misleading there and vLLM's KV pre-allocation competes with the page
# cache — see research §5.1 and F12.
is_strix_halco() {
  if command -v rocminfo &>/dev/null; then
    rocminfo 2>/dev/null | grep -qi "gfx1151" && return 0
  fi
  lspci -n 2>/dev/null | grep -q "1002:1586" && return 0   # Radeon 8060S (Strix Halo iGPU), works without ROCm userspace
  return 1
}

# VLLM_UNIFIED_MEMORY=true|false forces the verdict; empty = auto-detect.
is_unified_memory() {
  [[ "${VLLM_UNIFIED_MEMORY}" == "true" ]]  && return 0
  [[ "${VLLM_UNIFIED_MEMORY}" == "false" ]] && return 1
  is_spark && return 0
  [[ "$BACKEND" == "amd" ]] && is_strix_halco && return 0
  return 1
}

# ── Auto-detect GPU backend ────────────────────────────────────────────────────
detect_gpu() {
  step "Auto-detecting GPU"

  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    info "NVIDIA GPU detected via nvidia-smi."
    BACKEND="nvidia"; return
  fi

  if command -v lspci &>/dev/null; then
    if lspci 2>/dev/null | grep -qi "NVIDIA"; then
      info "NVIDIA GPU detected via lspci."
      BACKEND="nvidia"; return
    fi
    if lspci 2>/dev/null | grep -Eqi "AMD|Radeon"; then
      if [[ "$ARCH" == "aarch64" ]]; then
        warn "AMD GPU detected but ROCm is not supported on arm64. Falling back to CPU."
        BACKEND="cpu"; return
      fi
      info "AMD GPU detected via lspci."
      BACKEND="amd"; return
    fi
  fi

  if ls /dev/dri/renderD* &>/dev/null; then
    if command -v vulkaninfo &>/dev/null; then
      GPU_INFO=$(vulkaninfo 2>/dev/null || true)
      if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
        info "NVIDIA GPU detected via vulkaninfo."
        BACKEND="nvidia"; return
      fi
      if echo "$GPU_INFO" | grep -Eqi "AMD|Radeon"; then
        if [[ "$ARCH" == "aarch64" ]]; then
          warn "AMD GPU detected but ROCm is not supported on arm64. Falling back to CPU."
          BACKEND="cpu"; return
        fi
        info "AMD GPU detected via vulkaninfo."
        BACKEND="amd"; return
      fi
    fi
  fi

  warn "No supported GPU detected – falling back to CPU-only."
  BACKEND="cpu"
}

[[ -z "$BACKEND" ]] && detect_gpu

echo -e "\n${BOLD}Selected backend:${RESET} ${GREEN}${BACKEND^^}${RESET}  |  arch: ${GREEN}${ARCH}${RESET}\n"

# ── ROCm host driver check ─────────────────────────────────────────────────────
if [[ "$BACKEND" == "amd" ]]; then
  step "Checking ROCm host drivers"
  ROCM_OK=1

  if [[ ! -e /dev/kfd ]]; then
    warn "/dev/kfd not found – amdgpu kernel driver may not be loaded."
    ROCM_OK=0
  else
    success "/dev/kfd present."
  fi

  if ! ls /dev/dri/renderD* &>/dev/null; then
    warn "/dev/dri/renderD* not found – GPU render nodes unavailable."
    ROCM_OK=0
  else
    success "/dev/dri/renderD* present."
  fi

  if command -v rocminfo &>/dev/null; then
    if rocminfo 2>/dev/null | grep -qi "Device Type.*GPU"; then
      success "rocminfo reports a GPU device."
    else
      warn "rocminfo found but reports no GPU device."
      ROCM_OK=0
    fi
  else
    warn "rocminfo not found – ROCm may be incomplete."
    warn "Consider running setup-rocm.sh first."
    ROCM_OK=0
  fi

  if [[ "$ROCM_OK" -eq 0 ]]; then
    warn "ROCm host drivers appear incomplete."
    warn "Run setup-rocm.sh to install ROCm, then re-run this script."
    warn "To continue without GPU support, use --cpu instead."
    # Non-fatal: the container may still work if the kernel driver is loaded.
  fi
fi

# ── Resolve Docker image ───────────────────────────────────────────────────────
case "$BACKEND" in
  nvidia)
    if is_spark; then
      info "DGX Spark (GB10, sm_121) detected — using Spark-appropriate defaults."
    fi
    if [[ -z "$VLLM_IMAGE" ]]; then
      VLLM_IMAGE="vllm/vllm-openai:${VLLM_DEFAULT_TAG}"
      info "Default image pinned: ${VLLM_IMAGE} (override with --image)"
    fi
    ;;
  amd)    [[ -z "$VLLM_IMAGE" ]] && VLLM_IMAGE="vllm/vllm-openai-rocm:${VLLM_DEFAULT_TAG}" ;;
  cpu)    [[ -z "$VLLM_IMAGE" ]] && VLLM_IMAGE="vllm/vllm-openai:${VLLM_DEFAULT_TAG}" ;;
esac
info "Docker image: ${VLLM_IMAGE}"

# Command-prefix asymmetry (A1, F2/F3): upstream vllm/vllm-openai* images have
# Entrypoint=["vllm","serve"]; NGC images (nvcr.io/*) do not and need the
# full subcommand — with args-only the container dies immediately (research
# §6.1 "the #1 first-run failure"). See dgx-spark-playbooks/nvidia/vllm/README.md.
# The ROCm image's entrypoint is ["vllm","serve"] as well (F21) — nvcr.io/*-only.
VLLM_COMMAND_PREFIX=""
if [[ "$VLLM_IMAGE" == nvcr.io/* ]]; then
  VLLM_COMMAND_PREFIX="vllm serve"
  info "NGC image detected — prefixing the container command with 'vllm serve'."
fi

# ── Resolve defaults that depend on the backend ─────────────────────────────
if [[ -z "$VLLM_GPU_UTIL" && "$BACKEND" != "cpu" ]]; then
  # F1: unified memory (DGX Spark AND AMD Strix Halo) defaults lower — the KV
  # pool competes with OS/page cache for the same DRAM.
  if is_unified_memory; then
    VLLM_GPU_UTIL="0.80"
  else
    VLLM_GPU_UTIL="0.90"
  fi
  info "VLLM_GPU_UTIL not set — defaulting to ${VLLM_GPU_UTIL}."
fi

if [[ -z "$VLLM_HEALTH_TIMEOUT" ]]; then
  if [[ "$BACKEND" == "cpu" ]]; then
    VLLM_HEALTH_TIMEOUT=120
  else
    VLLM_HEALTH_TIMEOUT=900
  fi
fi
# Compose healthcheck start_period (C1): give the container the same budget as
# the script-level /health poll — cold start (JIT + weight load) is the slow part.
VLLM_HEALTH_START_PERIOD="${VLLM_HEALTH_TIMEOUT}s"
validate_gpu_util "${VLLM_GPU_UTIL}"

# A2 unified-memory band (gates on is_unified_memory — Spark AND Strix Halo, F1):
# NVIDIA documents --gpu-memory-utilization≈1.0 OOMs on unified memory (F12).
if is_unified_memory && [[ -n "$VLLM_GPU_UTIL" ]]; then
  awk -v u="$VLLM_GPU_UTIL" 'BEGIN { exit (u <= 0.90) ? 0 : 1 }' \
    || error "VLLM_GPU_UTIL=${VLLM_GPU_UTIL} exceeds the unified-memory ceiling (0.90): CPU, OS, page cache and the runtime share one pool with the KV pre-allocation (DGX Spark field data, F12)."
  awk -v u="$VLLM_GPU_UTIL" 'BEGIN { exit (u <= 0.85) ? 0 : 1 }' \
    || warn "VLLM_GPU_UTIL=${VLLM_GPU_UTIL} is above the 0.85 practical range on unified memory — watch for OOM/Xid 43 under load (same budget logic on DGX Spark and Strix Halo)."
fi

if [[ "${VLLM_TENSOR_PARALLEL}" -gt 1 && "$BACKEND" == "nvidia" ]]; then
  GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || true)
  if [[ "$GPU_COUNT" == "1" ]]; then
    warn "VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL} but only 1 GPU is visible."
    warn "Tensor parallelism across multiple DGX Sparks needs the Ray cluster path"
    warn "(see https://github.com/NVIDIA/dgx-spark-playbooks/blob/main/nvidia/vllm/README.md)."
  fi
fi

# ── Prepare directories ────────────────────────────────────────────────────────
step "Creating directories"

if [[ ! -d "$PROJECT_DIR" ]]; then
  sudo mkdir -p "$PROJECT_DIR"
  sudo chown "${USER}:${USER}" "$PROJECT_DIR"
fi
mkdir -p "$HF_CACHE_DIR"
# vLLM compile cache (torch.compile/Inductor/Triton) — survives container restarts
VLLM_CACHE_DIR="${PROJECT_DIR}/.vllm-cache"
mkdir -p "$VLLM_CACHE_DIR"
# LM Studio models dir (mounted at /lmstudio-models); created if absent so the
# bind mount in the compose template is always valid.
LMSTUDIO_MODELS_DIR="${HOME}/.lmstudio/models"
mkdir -p "$LMSTUDIO_MODELS_DIR"
success "Project dir: ${PROJECT_DIR}"
success "HF cache dir: ${HF_CACHE_DIR}"
success "vLLM cache dir: ${VLLM_CACHE_DIR}"

# ── Backend-conditional guidance (for .env comments) ──────────────────────────
if is_spark; then
  VLLM_GPU_UTIL_NOTE='# On DGX Spark this fraction applies to the 128 GB *unified* pool shared'
  VLLM_GPU_UTIL_NOTE="${VLLM_GPU_UTIL_NOTE}"$'\n'"# with the OS, page cache and the container runtime — leave headroom."
  VLLM_GPU_UTIL_NOTE="${VLLM_GPU_UTIL_NOTE}"$'\n'"# If the box shows memory pressure:  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
  VLLM_CONCURRENCY_NOTE='# DGX Spark is bandwidth-bound, not a large GPU:'
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   max-num-seqs 4 is REQUIRED for Nemotron Nano/Super V3 NVFP4"
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   (NVIDIA vLLM release notes 26.08); other MoE models tolerate more — sweep it."
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   Above ~4 concurrent decode streams the bandwidth tax outweighs batching"
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   and TTFT spikes. (datacenter: 128–256)"
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   max-num-batched-tokens: 8192 is the NVIDIA Spark recipe value."
elif is_unified_memory; then
  # Generic unified-memory fallback for non-Spark UMA hosts (AMD Strix Halo, F1)
  VLLM_GPU_UTIL_NOTE='# Unified memory: this fraction applies to the one shared DRAM pool'
  VLLM_GPU_UTIL_NOTE="${VLLM_GPU_UTIL_NOTE}"$'\n'"# (CPU, GPU, OS, page cache) — leave headroom."
  VLLM_CONCURRENCY_NOTE='# Bandwidth-bound APU with one shared memory pool — keep max-num-seqs low'
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   (4–8), leave several GB host headroom, flush the page cache when memory"
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"#   pressure appears (sync; echo 3 > /proc/sys/vm/drop_caches)."
else
  VLLM_GPU_UTIL_NOTE='# Fraction of GPU memory vLLM may use. Higher = more KV cache, less headroom.'
  VLLM_CONCURRENCY_NOTE='# Higher max-num-seqs = more throughput, higher latency.'
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"# Example: VLLM_MAX_NUM_SEQS=256  (tune to your request profile)"
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"# max-num-batched-tokens: >8192 for optimal throughput on large GPUs,"
  VLLM_CONCURRENCY_NOTE="${VLLM_CONCURRENCY_NOTE}"$'\n'"# smaller = better input latency (ITL)."
fi

# ── Write .env (rendered from templates/vllm/env.template) ───────────────────
step "Writing .env"

ENV_FILE="${PROJECT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn "Backing up existing .env to ${ENV_FILE}.bak"
  cp "$ENV_FILE" "${ENV_FILE}.bak"
fi

GENERATED_DATE="$(date -Iseconds)"
export PROJECT_DIR VLLM_MODEL HF_TOKEN VLLM_GPU_UTIL VLLM_DTYPE VLLM_MAX_MODEL_LEN \
  VLLM_SERVED_MODEL_NAME VLLM_TRUST_REMOTE_CODE VLLM_LOAD_FORMAT \
  VLLM_REASONING_PARSER VLLM_TOOL_CALL_PARSER VLLM_ENABLE_AUTO_TOOL_CHOICE \
  VLLM_EXTRA_ARGS VLLM_MAX_NUM_SEQS VLLM_MAX_NUM_BATCHED_TOKENS \
  VLLM_SPEC_METHOD VLLM_SPEC_MODEL VLLM_SPEC_TOKENS \
  VLLM_QUANTIZATION VLLM_MOE_BACKEND VLLM_LINEAR_BACKEND VLLM_ATTENTION_BACKEND \
  VLLM_KV_CACHE_DTYPE VLLM_ASYNC_SCHEDULING VLLM_ENABLE_CHUNKED_PREFILL \
  VLLM_GPU_UTIL_NOTE VLLM_CONCURRENCY_NOTE
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${PROJECT_DIR} ${VLLM_MODEL} ${HF_TOKEN} ${VLLM_GPU_UTIL} ${VLLM_DTYPE} ${VLLM_MAX_MODEL_LEN} ${VLLM_SERVED_MODEL_NAME} ${VLLM_TRUST_REMOTE_CODE} ${VLLM_LOAD_FORMAT} ${VLLM_REASONING_PARSER} ${VLLM_TOOL_CALL_PARSER} ${VLLM_ENABLE_AUTO_TOOL_CHOICE} ${VLLM_EXTRA_ARGS} ${VLLM_MAX_NUM_SEQS} ${VLLM_MAX_NUM_BATCHED_TOKENS} ${VLLM_SPEC_METHOD} ${VLLM_SPEC_MODEL} ${VLLM_SPEC_TOKENS} ${VLLM_QUANTIZATION} ${VLLM_MOE_BACKEND} ${VLLM_LINEAR_BACKEND} ${VLLM_ATTENTION_BACKEND} ${VLLM_KV_CACHE_DTYPE} ${VLLM_ASYNC_SCHEDULING} ${VLLM_ENABLE_CHUNKED_PREFILL} ${VLLM_GPU_UTIL_NOTE} ${VLLM_CONCURRENCY_NOTE}' \
  < "${TEMPLATE_DIR}/env.template" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
success ".env written (mode 600): ${ENV_FILE}"

# ── Write extra-vars.env (backend-specific env vars, kept out of .env) ───────
EXTRA_VARS_FILE="${PROJECT_DIR}/extra-vars.env"
{
  echo "# Generated by setup-vllm.sh — re-rendered on --force, safe to delete."
  # F3: VLLM_EXTRA_ENV works on every backend (ROCm needs the same escape hatch).
  if [[ -n "${VLLM_EXTRA_ENV}" ]]; then
    echo "# Operator-injected env vars (VLLM_EXTRA_ENV) — version-specific workarounds"
    for _kv in ${VLLM_EXTRA_ENV}; do
      echo "${_kv}"
    done
  fi
} > "$EXTRA_VARS_FILE"
chmod 600 "$EXTRA_VARS_FILE"
success "extra-vars.env written: ${EXTRA_VARS_FILE}"

# ── Build optional server flags (space-joined flag groups; the template's
#    one-line folded-scalar command block joins them with spaces. Empty flags
#    collapse safely. E2 rule 8 / review R1: the join MUST be a single space —
#    the previous newline+indent join terminated the folded scalar mid-command
#    whenever ${VLLM_COMMAND_PREFIX} on the first line expanded to nothing.) ─────
VLLM_COMMAND_FLAGS=""
_add_flag() { VLLM_COMMAND_FLAGS="${VLLM_COMMAND_FLAGS:+${VLLM_COMMAND_FLAGS} }$1"; }

# tensor-parallel: emit flag only when > 1 (vLLM default is 1)
if [[ "${VLLM_TENSOR_PARALLEL}" -gt 1 ]]; then
  _add_flag "--tensor-parallel-size ${VLLM_TENSOR_PARALLEL}"
fi
# dtype: emit flag only when set and not 'auto' (vLLM default is auto)
if [[ -n "${VLLM_DTYPE}" && "${VLLM_DTYPE}" != "auto" ]]; then
  _add_flag "--dtype ${VLLM_DTYPE}"
fi
# Values from .env stay compose-time substitutions (\$ kept literal)
if [[ -n "${VLLM_MAX_MODEL_LEN}" ]]; then
  _add_flag "--max-model-len \${VLLM_MAX_MODEL_LEN}"
fi
if [[ -n "${VLLM_MAX_NUM_SEQS}" ]]; then
  _add_flag "--max-num-seqs \${VLLM_MAX_NUM_SEQS}"
fi
if [[ -n "${VLLM_MAX_NUM_BATCHED_TOKENS}" ]]; then
  _add_flag "--max-num-batched-tokens \${VLLM_MAX_NUM_BATCHED_TOKENS}"
fi
if [[ -n "${VLLM_SERVED_MODEL_NAME}" ]]; then
  _add_flag "--served-model-name ${VLLM_SERVED_MODEL_NAME}"
fi
if [[ "${VLLM_TRUST_REMOTE_CODE}" == "true" ]]; then
  _add_flag "--trust-remote-code"
fi
if [[ -n "${VLLM_LOAD_FORMAT}" ]]; then
  _add_flag "--load-format ${VLLM_LOAD_FORMAT}"
fi
if [[ -n "${VLLM_REASONING_PARSER}" ]]; then
  _add_flag "--reasoning-parser ${VLLM_REASONING_PARSER}"
fi
if [[ -n "${VLLM_TOOL_CALL_PARSER}" ]]; then
  _add_flag "--tool-call-parser ${VLLM_TOOL_CALL_PARSER}"
fi
if [[ "${VLLM_ENABLE_AUTO_TOOL_CHOICE}" == "true" ]]; then
  _add_flag "--enable-auto-tool-choice"
fi

# ── Speculative decoding (quoting-free: vLLM --spec-* flags) ────────────────
# These bypass the compose quote-stripping trap of --speculative-config <json>
# (F9/F10) — no quoting needed.
if [[ -n "${VLLM_SPEC_METHOD}" ]]; then
  _add_flag "--spec-method ${VLLM_SPEC_METHOD}"
fi
if [[ -n "${VLLM_SPEC_MODEL}" ]]; then
  _add_flag "--spec-model ${VLLM_SPEC_MODEL}"
fi
if [[ -n "${VLLM_SPEC_TOKENS}" ]]; then
  _add_flag "--spec-tokens ${VLLM_SPEC_TOKENS}"
fi

# ── Backend / quantization levers (C3 — emit only when set, 'auto' never emits) ─
if [[ -n "${VLLM_QUANTIZATION}" && "${VLLM_QUANTIZATION}" != "auto" ]]; then
  _add_flag "--quantization ${VLLM_QUANTIZATION}"
fi
if [[ -n "${VLLM_MOE_BACKEND}" && "${VLLM_MOE_BACKEND}" != "auto" ]]; then
  _add_flag "--moe-backend ${VLLM_MOE_BACKEND}"
fi
if [[ -n "${VLLM_LINEAR_BACKEND}" && "${VLLM_LINEAR_BACKEND}" != "auto" ]]; then
  _add_flag "--linear-backend ${VLLM_LINEAR_BACKEND}"
fi
if [[ -n "${VLLM_ATTENTION_BACKEND}" && "${VLLM_ATTENTION_BACKEND}" != "auto" ]]; then
  _add_flag "--attention-backend ${VLLM_ATTENTION_BACKEND}"
fi
if [[ -n "${VLLM_KV_CACHE_DTYPE}" && "${VLLM_KV_CACHE_DTYPE}" != "auto" ]]; then
  _add_flag "--kv-cache-dtype ${VLLM_KV_CACHE_DTYPE}"
fi
if [[ "${VLLM_ASYNC_SCHEDULING}" == "true" ]]; then
  _add_flag "--async-scheduling"
fi
if [[ "${VLLM_ENABLE_CHUNKED_PREFILL}" == "true" ]]; then
  _add_flag "--enable-chunked-prefill"
fi

# ── Render docker-compose.yml (from templates/vllm/docker-compose.yml.tmpl) ──
step "Generating docker-compose.yml"

# E1 migration: a stack previously rendered in proxy mode switches to direct
# exposure on this run. Fresh installs have no compose file yet — the -f guard
# is required (review R7).
if [[ -f "$COMPOSE_FILE" ]] && grep -q 'traefik.enable' "$COMPOSE_FILE"; then
  warn "Previous render used Traefik (routed via a domain). vLLM is now direct-only:"
  warn "  * the container is re-created without traefik labels and leaves the '${PROXY_NETWORK:-proxy}' network"
  warn "  * clients must use http://<this-host>:${VLLM_PORT}/v1 — the old https:// URL stops working"
  warn "  * the old router/DNS entry is yours to clean up (traefik keeps no stale router after the labels are gone)"
  warn "  * restrict the port to your LAN: sudo ufw deny <port> && sudo ufw allow from 192.168.0.0/16 to any port <port>"
fi

COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.yml.tmpl"

# ── Backend YAML fragments — anchored here by the E2 render verification ──────
# One case statement replaces the old ${BACKEND}.${EXPOSURE_MODE} template lookup
# (removed with the Traefik integration — see the E1/E2 ticket sections).
# Indentation is part of the value: these are YAML lines, not prose. Kept inline
# on purpose (AGENTS.md forbids inline templates in scripts, but compose -f
# override files replace — not merge — sequences, ticket 19 §1; these 3–6 fixed
# lines are the only remaining option that keeps ONE template file).
case "$BACKEND" in
  nvidia)
    VLLM_IPC_BLOCK='    ipc: "host"'
    # GPU via CDI, not deploy.resources.reservations.devices: the legacy path
    # injects /dev/nvidia* from an OCI prestart hook, after runc created the
    # container's systemd scope, so a later `systemctl daemon-reload` rebuilds
    # the scope's device filter and revokes GPU access from the RUNNING
    # container (CUDA fails, /health stays 200). CDI puts the devices in the
    # OCI spec before creation. Spec upkeep: tasks/setup-nvidia-container.sh.
    VLLM_VENDOR_BLOCK=$'    devices:\n      - "nvidia.com/gpu=all"'
    # NOTE: ${VLLM_GPU_UTIL} must survive this envsubst (it is non-recursive, F15) so that
    # compose still resolves the value from /srv/vllm/.env at runtime, exactly as the
    # per-backend templates did. Do NOT add VLLM_GPU_UTIL to the envsubst list.
    # shellcheck disable=SC2016  # the ${VLLM_GPU_UTIL} token stays literal for compose
    VLLM_BACKEND_ARGS='--gpu-memory-utilization ${VLLM_GPU_UTIL}'
    ;;
  amd)
    VLLM_IPC_BLOCK='    ipc: "host"'
    VLLM_VENDOR_BLOCK=$'    devices:\n      - /dev/kfd\n      - /dev/dri\n    group_add:\n      - video\n    cap_add:\n      - SYS_PTRACE\n    security_opt:\n      - seccomp=unconfined'
    # shellcheck disable=SC2016  # the ${VLLM_GPU_UTIL} token stays literal for compose
    VLLM_BACKEND_ARGS='--gpu-memory-utilization ${VLLM_GPU_UTIL}'
    ;;
  cpu)
    VLLM_IPC_BLOCK=""        # no ipc:host, shm_size only (D3)
    VLLM_VENDOR_BLOCK=""     # no device/reservation block
    VLLM_BACKEND_ARGS='--device cpu'
    ;;
esac
export VLLM_IPC_BLOCK VLLM_VENDOR_BLOCK VLLM_BACKEND_ARGS VLLM_COMMAND_PREFIX VLLM_HEALTH_START_PERIOD

export VLLM_IMAGE VLLM_SHM_SIZE HF_CACHE_DIR PROJECT_DIR LMSTUDIO_MODELS_DIR \
  VLLM_PORT VLLM_COMMAND_FLAGS GENERATED_DATE
# shellcheck disable=SC2016  # envsubst expects the literal variable list
# Note: VLLM_MODEL / VLLM_GPU_UTIL / VLLM_EXTRA_ARGS are deliberately NOT in
# the list — the compose file keeps them for runtime substitution from .env.
envsubst '${VLLM_IMAGE} ${VLLM_SHM_SIZE} ${HF_CACHE_DIR} ${PROJECT_DIR} ${LMSTUDIO_MODELS_DIR} ${VLLM_PORT} ${VLLM_COMMAND_FLAGS} ${GENERATED_DATE} ${VLLM_IPC_BLOCK} ${VLLM_VENDOR_BLOCK} ${VLLM_BACKEND_ARGS} ${VLLM_COMMAND_PREFIX} ${VLLM_HEALTH_START_PERIOD}' \
  < "$COMPOSE_TEMPLATE" > "$COMPOSE_FILE"
# An empty VLLM_COMMAND_FLAGS leaves a whitespace-only line — strip for clean YAML
sed -i 's/[[:space:]]*$//' "$COMPOSE_FILE"
success "docker-compose.yml created: ${COMPOSE_FILE} (backend: ${BACKEND}, template: docker-compose.yml.tmpl)"

# ── Re-run policy (ticket 12): model args cannot converge a running stack ──
# Model args are baked into the container command at create time (rendered
# into the compose file and/or resolved from .env at start). The rendered
# config (compose + .env + extra-vars.env, generated-date lines excluded)
# is compared with what the running stack was last created from; on
# divergence print the exact remedy and exit 0 — never silently recreate.
CONVERGE_HASH_FILE="${PROJECT_DIR}/.converge-hash"
_render_hash="$(sed '/^# Generated/d' "$COMPOSE_FILE" "$ENV_FILE" "$EXTRA_VARS_FILE" | sha256sum | awk '{print $1}')"
if [[ "$VLLM_STACK_RUNNING" == "true" && "$RECREATE_VLLM" != "true" ]]; then
  _stored_hash="$(cat "$CONVERGE_HASH_FILE" 2>/dev/null || true)"
  if [[ -n "${_stored_hash}" && "${_stored_hash}" != "${_render_hash}" ]]; then
    warn "Rendered vLLM config (.env model args / compose) differs from the running stack."
    warn "Model args are baked into the container command at create time."
    warn "Converge now:"
    warn "  cd ${PROJECT_DIR} && docker compose up -d --force-recreate"
    warn "Or tear down and re-create:"
    warn "  $0 --force"
    exit 0
  fi
fi

# ── Pull image ─────────────────────────────────────────────────────────────────
step "Pulling Docker image: ${VLLM_IMAGE}"
(cd "$PROJECT_DIR" && docker compose pull) || {
  # Surface the common case: nvcr.io images need NGC authentication
  if [[ "$VLLM_IMAGE" == nvcr.io/* ]]; then
    error "docker compose pull failed for NGC image ${VLLM_IMAGE}."
    error "NGC images require authentication: create a free API key at https://api.ngc.nvidia.com,"
    error "then run:  docker login nvcr.io"
  fi
  error "docker compose pull failed for ${VLLM_IMAGE} (see output above)."
}
success "Image pulled."

# ── Start stack (only when a model is configured) ─────────────────────────────
if [[ -z "$VLLM_MODEL" ]]; then
  echo ""
  warn "No model configured – skipping container start."
  echo ""
  info "Next steps:"
  info "Next steps:"
  info "  1. Download a model with the HF CLI, e.g.:"
  info "       hf download Qwen/Qwen2.5-7B-Instruct"
  info "       (CLI: pip install -U \"huggingface_hub[cli]\" — huggingface-cli is deprecated)"
  info "  2. Set VLLM_MODEL in ${ENV_FILE}:"
  info "       VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct"
  info "  3. Start the stack:"
  info "       cd ${PROJECT_DIR} && docker compose up -d"
  echo ""
else
  step "Starting vLLM stack"
  # C2 (NVIDIA playbook step, research §5.1/§10): vLLM pre-allocates its KV pool
  # out of the one DRAM pool a unified-memory host shares with the page cache —
  # flushing first avoids "OOM with free RAM" at launch. Gates on
  # is_unified_memory (Spark AND Strix Halo, F1); failure is never fatal.
  if is_unified_memory; then
    _um="unified-memory host"; is_spark && _um="DGX Spark"
    step "Freeing page cache before launch (${_um})"
    if sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'; then
      success "Page cache dropped."
    else
      warn "Could not drop the page cache (needs sudo) — ignore if the box has plenty of free RAM."
    fi
  fi
  (cd "$PROJECT_DIR" && docker compose up -d)

  # Health gate: prove the container is actually up before reporting success.
  # Reuses VLLM_HEALTH_TIMEOUT (the script's existing timeout convention):
  # the budget must cover model loading for stacks whose image start is slow.
  mapfile -t _ids < <(cd "$PROJECT_DIR" && docker compose ps -q)
  wait_for_healthy "${VLLM_HEALTH_TIMEOUT}" "${_ids[@]}" \
    || error "vLLM stack did not come up — see the status output above"

  # Re-run policy (ticket 12): record what the stack is now created from, so
  # the next run can detect divergent model args (see hash check above).
  printf '%s\n' "${_render_hash}" > "$CONVERGE_HASH_FILE"

  # ── Health check ──────────────────────────────────────────────────────────
  step "Waiting for vLLM to respond (timeout: ${VLLM_HEALTH_TIMEOUT}s)"
  info "Large models (NVFP4 100B+) can take 10–15 min to load weights."

  INTERVAL=10
  ELAPSED=0
  READY=false
  _polls=0

  while [[ $ELAPSED -lt $VLLM_HEALTH_TIMEOUT ]]; do
    if curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
      READY=true; break
    fi
    echo -ne "\r    Waited ${ELAPSED}s / ${VLLM_HEALTH_TIMEOUT}s …"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    # D4: the /health poll cannot notice the container dying mid-wait — every
    # 3rd iteration (~30 s) re-check the state and bail early on a crash loop
    # instead of burning the whole timeout (mirrors wait_for_healthy hardfail).
    _polls=$((_polls + 1))
    if (( _polls % 3 == 0 )); then
      _state="$(docker inspect --format '{{.State.Status}} {{.State.Health.Status}}' vllm 2>/dev/null || true)"
      case "$_state" in
        exited*|dead*|restarting*|*unhealthy*)
          echo ""
          error "vLLM container is not coming up (state: ${_state:-uninspectable}) — check the logs: cd ${PROJECT_DIR} && docker compose logs -f"
          ;;
      esac
    fi
  done
  echo ""

  if [[ "$READY" == "true" ]]; then
    success "vLLM is up and healthy!"

    # ── Warmup: absorb the JIT cold-start (Inductor/FlashInfer ~25 s)
    # so the first real user request is fast.
    if [[ "$WARMUP" -eq 1 ]]; then
      WARMUP_MODEL="${VLLM_SERVED_MODEL_NAME:-${VLLM_MODEL}}"
      info "Sending warmup request (first request triggers JIT compilation, ~25 s)…"
      if curl -sf --max-time "${VLLM_HEALTH_TIMEOUT}" -X POST "http://localhost:${VLLM_PORT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"model":"%s","max_tokens":3,"messages":[{"role":"user","content":"ping"}]}' "${WARMUP_MODEL}")" \
        &>/dev/null; then
        success "Warmup complete — the server is ready for real requests."
      else
        warn "Warmup request failed or timed out — the server may still be warming up."
        warn "Follow logs: cd ${PROJECT_DIR} && docker compose logs -f"
      fi
    fi

    # C4: an unsupported FP4 path can produce silently wrong output — point the
    # operator at the logs that prove the fast paths actually engaged
    # (research §2/§7.3). Nested fallback is mandatory (R4): under --no-warmup
    # WARMUP_MODEL is unset and set -u would abort the summary on this line.
    if [[ "$BACKEND" == "nvidia" ]] && is_spark; then
      info "Verify the fast paths actually engaged:"
      info "  docker logs vllm 2>&1 | grep -Ei 'NvFp4|MoE backend|AttentionBackend|KV cache size|Maximum concurrency'"
      info "Smoke test (must answer 204):"
      info "  curl -sS http://localhost:${VLLM_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${WARMUP_MODEL:-${VLLM_SERVED_MODEL_NAME:-$VLLM_MODEL}}\",\"messages\":[{\"role\":\"user\",\"content\":\"12*17\"}],\"max_tokens\":64}'"
    fi
  else
    warn "vLLM did not respond within ${VLLM_HEALTH_TIMEOUT}s – it may still be loading the model."
    warn "Follow logs: cd ${PROJECT_DIR} && docker compose logs -f"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║        vLLM installation complete!           ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Backend:${RESET}       ${GREEN}${BACKEND^^}${RESET}  (${ARCH})"
if is_unified_memory; then
  echo -e "  ${BOLD}Unified memory:${RESET} yes"
else
  echo -e "  ${BOLD}Unified memory:${RESET} no"
fi
echo -e "  ${BOLD}Image:${RESET}         ${VLLM_IMAGE}"
echo -e "  ${BOLD}Project dir:${RESET}   ${PROJECT_DIR}"
echo -e "  ${BOLD}HF cache:${RESET}      ${HF_CACHE_DIR}  →  /root/.cache/huggingface (in container)"
echo -e "  ${BOLD}vLLM cache:${RESET}    ${VLLM_CACHE_DIR}  →  /root/.cache/vllm (compile cache)"
if [[ "$BACKEND" != "cpu" && -n "${VLLM_GPU_UTIL}" ]]; then
  echo -e "  ${BOLD}GPU util:${RESET}      ${VLLM_GPU_UTIL}"
fi
if [[ "${VLLM_TENSOR_PARALLEL}" -gt 1 ]]; then
  echo -e "  ${BOLD}Tensor parallel:${RESET} ${VLLM_TENSOR_PARALLEL} GPUs"
fi
if [[ "${VLLM_DTYPE}" != "auto" ]]; then
  echo -e "  ${BOLD}Dtype:${RESET}         ${VLLM_DTYPE}"
fi
if [[ -n "${VLLM_MAX_MODEL_LEN}" ]]; then
  echo -e "  ${BOLD}Max model len:${RESET} ${VLLM_MAX_MODEL_LEN} tokens"
fi
if [[ -n "${VLLM_MAX_NUM_SEQS}" ]]; then
  echo -e "  ${BOLD}Max num seqs:${RESET}    ${VLLM_MAX_NUM_SEQS}"
fi
if [[ -n "${VLLM_MAX_NUM_BATCHED_TOKENS}" ]]; then
  echo -e "  ${BOLD}Max batched toks:${RESET} ${VLLM_MAX_NUM_BATCHED_TOKENS}"
fi
if [[ -n "${VLLM_SERVED_MODEL_NAME}" ]]; then
  echo -e "  ${BOLD}Served as:${RESET}     ${VLLM_SERVED_MODEL_NAME}"
fi
if [[ -n "${VLLM_REASONING_PARSER}" || -n "${VLLM_TOOL_CALL_PARSER}" || "${VLLM_ENABLE_AUTO_TOOL_CHOICE}" == "true" ]]; then
  echo -e "  ${BOLD}Agent serving:${RESET} enabled (reasoning-parser: ${VLLM_REASONING_PARSER:-—}, tool-call-parser: ${VLLM_TOOL_CALL_PARSER:-—}, auto-tool-choice: ${VLLM_ENABLE_AUTO_TOOL_CHOICE})"
fi
echo -e "  ${BOLD}LM Studio:${RESET}     ${LMSTUDIO_MODELS_DIR}  →  /lmstudio-models (in container)"
echo -e "  ${BOLD}Config:${RESET}        ${ENV_FILE}"
echo ""
echo -e "  ${BOLD}API:${RESET}           http://localhost:${VLLM_PORT}/v1"
echo -e "  ${BOLD}Access:${RESET}         restrict VLLM_PORT to your LAN with ufw (tasks/configure-firewall.sh):"
echo -e "                  everyone on that network can call the endpoint, enumerate models"
echo -e "                  and consume the GPU — the firewall is the only real boundary."

if [[ -n "$VLLM_MODEL" ]]; then
  echo -e "  ${BOLD}Model:${RESET}         ${VLLM_MODEL}"
else
  echo ""
  echo -e "  ${YELLOW}${BOLD}Model not configured yet.${RESET}  Edit ${ENV_FILE} and set VLLM_MODEL,"
  echo -e "  then: cd ${PROJECT_DIR} && docker compose up -d"
fi

if [[ "$BACKEND" == "nvidia" ]] && is_spark; then
  echo ""
  echo -e "  ${BOLD}Model fit (DGX Spark, 128 GB unified memory):${RESET}"
  echo -e "  100–130B MoE NVFP4 (~10–15B active) is the best fit; up to ~130B NVFP4"
  echo -e "  fits the pool with usable KV headroom; dense models are poorly matched."
  echo -e "  Matrix: https://github.com/NVIDIA/dgx-spark-playbooks/blob/main/nvidia/vllm/README.md"
fi

echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Start:        cd ${PROJECT_DIR} && docker compose up -d"
echo -e "  Stop:         cd ${PROJECT_DIR} && docker compose down"
echo -e "  Logs:         cd ${PROJECT_DIR} && docker compose logs -f"
echo -e "  Shell:        docker exec -it vllm bash"
echo -e "  Status:       $0 --check"
echo ""
echo -e "  ${BOLD}List loaded models:${RESET}"
echo -e "    curl http://localhost:${VLLM_PORT}/v1/models"
echo ""
echo -e "  ${BOLD}Metrics (Prometheus — KV cache usage, TTFT/ITL histograms):${RESET}"
echo -e "    curl http://localhost:${VLLM_PORT}/metrics"
echo ""
echo -e "  ${BOLD}Change the model:${RESET} edit VLLM_MODEL in ${ENV_FILE},"
echo -e "  then: cd ${PROJECT_DIR} && docker compose up -d"
echo ""
echo -e "  ${BOLD}Download a model (on the host):${RESET}"
echo -e "    hf download Qwen/Qwen2.5-7B-Instruct"
echo ""
