#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-vllm-omni.sh
# Deploys vLLM-Omni as a Docker-based OpenAI-compatible omni-modality server.
# Serves TTS, diffusion, image/video generation and any-to-any omni models
# (Qwen3-Omni, Cosmos3, Z-Image, ...) via `vllm serve <model> --omni`.
#
# Prebuilt Docker Hub images (no local build):
#   NVIDIA (CUDA): vllm/vllm-omni        (amd64; arm64 via the -aarch64 tag)
#   AMD (ROCm):    vllm/vllm-omni-rocm   (amd64 only)
#
# NOTE: unlike setup-vllm.sh, this script intentionally KEEPS its Traefik
# integration (proxy-capable) — after the vllm-improvement ticket removed the
# proxy from setup-vllm.sh, the two vLLM scripts intentionally differ
# (vLLM: direct/LAN-only; vLLM-Omni: still proxy-capable). Do not copy the
# direct-only changes back here without reopening that decision.
#
# HuggingFace models downloaded via huggingface-cli are available inside the
# container (the HF cache dir is mounted).
#
# Usage:
#   ./setup-vllm-omni.sh              # auto-detect GPU, set up vLLM-Omni
#   ./setup-vllm-omni.sh --nvidia     # force NVIDIA/CUDA
#   ./setup-vllm-omni.sh --amd        # force AMD/ROCm  (amd64 only)
#   ./setup-vllm-omni.sh --cpu        # CPU only (impractical for generation)
#   ./setup-vllm-omni.sh --check      # check installation status and exit
#   ./setup-vllm-omni.sh --force      # re-create stack even if present
#   ./setup-vllm-omni.sh --help       # show help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/vllm-omni"

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-/srv/vllm-omni}"
# HF cache dir on the host — models downloaded via huggingface-cli live here.
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

VLLM_OMNI_VERSION="${VLLM_OMNI_VERSION:-latest}"   # image tag (e.g. v0.24.0)
VLLM_OMNI_PORT="${VLLM_OMNI_PORT:-8091}"           # host API port (container: 8000)
VLLM_OMNI_MODEL="${VLLM_OMNI_MODEL:-}"             # HF model ID / in-container path
HF_TOKEN="${HF_TOKEN:-}"                           # optional: gated models
# Empty default on purpose (re-run policy, ticket 12): a non-empty default
# would overwrite a value the operator stored in .env on a re-run. The 0.90
# default is applied after the .env read-back, when nothing was set/stored.
VLLM_OMNI_GPU_UTIL="${VLLM_OMNI_GPU_UTIL:-}"       # GPU mem fraction (GPU backends, default 0.90)
VLLM_OMNI_TENSOR_PARALLEL="${VLLM_OMNI_TENSOR_PARALLEL:-1}"  # # GPUs
VLLM_OMNI_MAX_MODEL_LEN="${VLLM_OMNI_MAX_MODEL_LEN:-}"       # cap context length
VLLM_OMNI_SHM_SIZE="${VLLM_OMNI_SHM_SIZE:-8g}"     # container shared memory
VLLM_OMNI_EXTRA_ARGS="${VLLM_OMNI_EXTRA_ARGS:-}"   # extra `vllm serve` args

VLLM_OMNI_TRAEFIK="${VLLM_OMNI_TRAEFIK:-false}"
VLLM_OMNI_DOMAIN="${VLLM_OMNI_DOMAIN:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

BACKEND=""       # nvidia | amd | cpu  (empty = auto-detect)
FORCE=0
CHECK_ONLY=0
INTERACTIVE=false   # re-run policy (ticket 12): offer tear-down/re-create of an existing stack

ARCH=$(uname -m) # x86_64 | aarch64

# ── Input validation ──────────────────────────────────────────────────────────
validate_model_id() {
  local model="$1"
  if [[ -n "$model" && ! "$model" =~ ^[a-zA-Z0-9_/.:-]+$ ]]; then
    error "VLLM_OMNI_MODEL contains invalid characters. Allowed: alphanumeric, hyphens, underscores, slashes, dots, colons."
  fi
}

validate_extra_args() {
  local args="$1"
  if [[ -n "$args" ]]; then
    local dangerous_pattern='[`$;|&<>]'
    if [[ "$args" =~ $dangerous_pattern ]]; then
      error "VLLM_OMNI_EXTRA_ARGS contains disallowed characters (backtick, \$, ;, |, &, <, >)."
    fi
  fi
}

validate_domain() {
  local domain="$1"
  if [[ -n "$domain" && ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
    error "VLLM_OMNI_DOMAIN is not a valid domain name."
  fi
}

validate_port() {
  local port="$1"
  if [[ -n "$port" && (! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535) ]]; then
    error "VLLM_OMNI_PORT must be a number between 1 and 65535."
  fi
}

validate_version() {
  local v="$1"
  if [[ -n "$v" && ! "$v" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    error "VLLM_OMNI_VERSION contains invalid characters. Allowed: alphanumeric, dots, underscores, hyphens."
  fi
}

validate_tensor_parallel() {
  local tp="$1"
  if [[ -n "$tp" && (! "$tp" =~ ^[0-9]+$ || "$tp" -lt 1) ]]; then
    error "VLLM_OMNI_TENSOR_PARALLEL must be a positive integer."
  fi
}

validate_max_model_len() {
  local val="$1"
  if [[ -n "$val" && (! "$val" =~ ^[0-9]+$ || "$val" -lt 1) ]]; then
    error "VLLM_OMNI_MAX_MODEL_LEN must be a positive integer."
  fi
}

validate_shm_size() {
  local sz="$1"
  if [[ -n "$sz" && ! "$sz" =~ ^[0-9]+[bBkKmMgG]?$ ]]; then
    error "VLLM_OMNI_SHM_SIZE must be a size string like '8g', '512m', '1024k'."
  fi
}

validate_gpu_util() {
  local util="$1"
  [[ -z "$util" ]] && return 0
  if ! [[ "$util" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
    error "VLLM_OMNI_GPU_UTIL must be a number between 0.0 and 1.0."
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}Usage:${RESET} $0 [OPTIONS]"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo "  --nvidia              Force NVIDIA CUDA backend"
  echo "  --amd                 Force AMD ROCm backend  (amd64 only)"
  echo "  --cpu                 Force CPU-only backend  (impractical for generation)"
  echo "  --version <tag>       Image tag  (default: latest)"
  echo "  --port <n>            Host API port  (default: 8091)"
  echo "  --model <id>          HF model ID or in-container path"
  echo "  --hf-token <token>    HuggingFace token for gated models"
  echo "  --hf-cache <path>     Host HF cache dir  (default: ~/.cache/huggingface)"
  echo "  --gpu-util <frac>     GPU memory utilization 0.0-1.0  (default: 0.90)"
  echo "  --tensor-parallel <n> Number of GPUs for tensor parallelism  (default: 1)"
  echo "  --max-model-len <n>   Max context length  (default: model max)"
  echo "  --shm-size <size>     Shared memory size  (default: 8g)"
  echo "  --dir <path>          Installation directory  (default: /srv/vllm-omni)"
  echo "  --traefik             Enable Traefik reverse-proxy integration"
  echo "  --domain <host>       Domain for Traefik  (required with --traefik)"
  echo "  --force               Re-create stack even if already present"
  echo "  --interactive         Offer tear-down/re-create of an existing stack (default: converge)"
  echo "  --check               Check installation status and exit"
  echo "  --help                Show this help"
  echo ""
  echo -e "${BOLD}Environment variables${RESET} (relevant extras):"
  echo "  VLLM_OMNI_HEALTH_TIMEOUT  Seconds to wait for the stack to come up"
  echo "                            after 'docker compose up -d' (default: 300 –"
  echo "                            model loading is slow)"
  echo ""
  echo -e "${BOLD}Model selection${RESET} (set after install, in ${PROJECT_DIR}/.env):"
  echo "  VLLM_OMNI_MODEL=Tongyi-MAI/Z-Image-Turbo   # text-to-image (quickstart)"
  echo "  VLLM_OMNI_MODEL=<HF omni/TTS/diffusion model id>"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo "  $0                                     # auto-detect GPU, set up vLLM-Omni"
  echo "  $0 --nvidia --port 8091                # CUDA on port 8091"
  echo "  $0 --model Tongyi-MAI/Z-Image-Turbo    # set model and start"
  echo "  $0 --traefik --domain omni.example.com"
  echo "  $0 --check                             # show stack status"
  echo ""
  echo -e "${BOLD}Re-run policy${RESET} (converge by default):"
  echo "  Re-running an existing stack converges it: the .env and compose file are"
  echo "  re-rendered (stored values reused), and 'docker compose up -d' reconciles"
  echo "  only what changed. Model args that diverge from the running stack are"
  echo "  printed with the exact re-create command. --force (or interactive 'y')"
  echo "  tears down and re-creates."
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nvidia)           BACKEND="nvidia" ;;
    --amd)              BACKEND="amd" ;;
    --cpu)              BACKEND="cpu" ;;
    --version)          shift; VLLM_OMNI_VERSION="$1" ;;
    --port)             shift; VLLM_OMNI_PORT="$1" ;;
    --model)            shift; VLLM_OMNI_MODEL="$1" ;;
    --hf-token)         shift; HF_TOKEN="$1" ;;
    --hf-cache)         shift; HF_CACHE_DIR="$1" ;;
    --gpu-util)         shift; VLLM_OMNI_GPU_UTIL="$1" ;;
    --tensor-parallel)  shift; VLLM_OMNI_TENSOR_PARALLEL="$1" ;;
    --max-model-len)    shift; VLLM_OMNI_MAX_MODEL_LEN="$1" ;;
    --shm-size)         shift; VLLM_OMNI_SHM_SIZE="$1" ;;
    --dir)              shift; PROJECT_DIR="$1" ;;
    --traefik)          VLLM_OMNI_TRAEFIK="true" ;;
    --domain)           shift; VLLM_OMNI_DOMAIN="$1" ;;
    --force)            FORCE=1 ;;
    --interactive)      INTERACTIVE=true ;;
    --check)            CHECK_ONLY=1 ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# Apply validations (only for non-empty values)
validate_model_id "${VLLM_OMNI_MODEL}"
validate_extra_args "${VLLM_OMNI_EXTRA_ARGS}"
validate_domain "${VLLM_OMNI_DOMAIN}"
validate_port "${VLLM_OMNI_PORT}"
validate_version "${VLLM_OMNI_VERSION}"
validate_gpu_util "${VLLM_OMNI_GPU_UTIL}"
validate_tensor_parallel "${VLLM_OMNI_TENSOR_PARALLEL}"
validate_max_model_len "${VLLM_OMNI_MAX_MODEL_LEN}"
validate_shm_size "${VLLM_OMNI_SHM_SIZE}"

# ── Guard: ROCm on arm64 is not supported ─────────────────────────────────────
if [[ "$ARCH" == "aarch64" && "$BACKEND" == "amd" ]]; then
  error "ROCm is not supported on arm64 (aarch64). Use --cpu or --nvidia instead."
fi

# ── Guard: tensor parallelism requires a GPU backend ─────────────────────────
if [[ "${VLLM_OMNI_TENSOR_PARALLEL}" -gt 1 && "$BACKEND" == "cpu" ]]; then
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
_env_reuse VLLM_OMNI_MODEL     VLLM_OMNI_MODEL
_env_reuse HF_TOKEN            HF_TOKEN
_env_reuse VLLM_OMNI_GPU_UTIL  VLLM_OMNI_GPU_UTIL
_env_reuse VLLM_OMNI_MAX_MODEL_LEN VLLM_OMNI_MAX_MODEL_LEN
_env_reuse VLLM_OMNI_EXTRA_ARGS VLLM_OMNI_EXTRA_ARGS
# Nothing set and nothing stored: apply the GPU-util default (the compose
# command resolves ${VLLM_OMNI_GPU_UTIL} from the .env at start).
VLLM_OMNI_GPU_UTIL="${VLLM_OMNI_GPU_UTIL:-0.90}"

print_found_status() {
  echo ""
  echo -e "${BOLD}${GREEN}vLLM-Omni stack is already installed.${RESET}"
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

step "Checking for existing vLLM-Omni installation"

VLLM_OMNI_STACK_RUNNING=false
RECREATE_VLLM_OMNI=false

if [[ -f "$COMPOSE_FILE" ]]; then
  print_found_status
  if docker compose -f "${COMPOSE_FILE}" ps --quiet 2>/dev/null | grep -q .; then
    VLLM_OMNI_STACK_RUNNING=true
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "Run with ${BOLD}--force${RESET} to re-create the stack."
    exit 0
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    RECREATE_VLLM_OMNI=true
    warn "--force specified - tearing down existing stack."
    (cd "$PROJECT_DIR" && docker compose down 2>/dev/null) || true
    echo ""
  elif [[ "$INTERACTIVE" == "true" && "$VLLM_OMNI_STACK_RUNNING" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      RECREATE_VLLM_OMNI=true
      warn "Re-create confirmed - tearing down existing stack."
      (cd "$PROJECT_DIR" && docker compose down 2>/dev/null) || true
      echo ""
    fi
  fi
  if [[ "$RECREATE_VLLM_OMNI" != "true" ]]; then
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
    echo -e "  ${YELLOW}vLLM-Omni does not appear to be installed.${RESET}"
    echo -e "  Run the script without ${BOLD}--check${RESET} to install it."
    echo ""
    exit 0
  fi
  success "No existing installation found - proceeding with fresh install."
fi

# ── Pre-flight ─────────────────────────────────────────────────────────────────
step "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] && warn "Running as root - not recommended."

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Continuing anyway..."
fi

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "0.0.0")
COMPOSE_MAJOR=$(echo "$COMPOSE_VER" | cut -d'.' -f1)
if [[ "$COMPOSE_MAJOR" -lt 2 ]]; then
  warn "Docker Compose v2+ recommended. Current: ${COMPOSE_VER}"
fi

# Port check (direct mode only)
if [[ "$VLLM_OMNI_TRAEFIK" != "true" ]]; then
  if ss -tln 2>/dev/null | grep -q ":${VLLM_OMNI_PORT} "; then
    error "Port ${VLLM_OMNI_PORT} is already in use. Set a different VLLM_OMNI_PORT."
  fi
fi

# Traefik pre-flight
if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
  ensure_proxy_network
  if [[ -z "$VLLM_OMNI_DOMAIN" ]]; then
    error "VLLM_OMNI_DOMAIN must be set when --traefik is used."
  fi
fi

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

  warn "No supported GPU detected - falling back to CPU-only."
  BACKEND="cpu"
}

[[ -z "$BACKEND" ]] && detect_gpu

echo -e "\n${BOLD}Selected backend:${RESET} ${GREEN}${BACKEND^^}${RESET}  |  arch: ${GREEN}${ARCH}${RESET}\n"

[[ "$BACKEND" == "cpu" ]] && warn "CPU backend: generative/diffusion Omni models are impractical on CPU (very slow)."

# The NVIDIA compose templates request the GPU as the CDI device
# nvidia.com/gpu=all, so the spec must exist before `compose up` — a missing
# one fails the container start with "unresolvable CDI devices". Checked here
# rather than in the generic pre-flight because it applies to the NVIDIA
# backend only, and the backend is only definitive after detection.
if [[ "$BACKEND" == "nvidia" ]]; then
  if ! command -v nvidia-ctk &>/dev/null; then
    error "nvidia-ctk is not installed. Required for the CDI GPU spec. Run setup-nvidia-container.sh first."
  fi
  if ! nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
    error "No CDI spec for nvidia.com/gpu=all. Run setup-nvidia-container.sh — it generates the
  spec and installs an apt hook that regenerates it after every driver upgrade.
  Manual equivalent: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
  fi
  success "CDI device nvidia.com/gpu=all is available."
fi

# ── Resolve Docker image ───────────────────────────────────────────────────────
IMAGE_SUFFIX=""
[[ "$ARCH" == "aarch64" ]] && IMAGE_SUFFIX="-aarch64"
case "$BACKEND" in
  nvidia) VLLM_OMNI_IMAGE="vllm/vllm-omni:${VLLM_OMNI_VERSION}${IMAGE_SUFFIX}" ;;
  cpu)    VLLM_OMNI_IMAGE="vllm/vllm-omni:${VLLM_OMNI_VERSION}${IMAGE_SUFFIX}" ;;
  amd)    VLLM_OMNI_IMAGE="vllm/vllm-omni-rocm:${VLLM_OMNI_VERSION}" ;;
esac
info "Docker image: ${VLLM_OMNI_IMAGE}"

# ── Prepare directories ────────────────────────────────────────────────────────
step "Creating directories"

if [[ ! -d "$PROJECT_DIR" ]]; then
  sudo mkdir -p "$PROJECT_DIR"
  sudo chown "${USER}:${USER}" "$PROJECT_DIR"
fi
mkdir -p "$HF_CACHE_DIR"
success "Project dir: ${PROJECT_DIR}"
success "HF cache dir: ${HF_CACHE_DIR}"

# ── Write .env ─────────────────────────────────────────────────────────────────
step "Writing .env"

ENV_FILE="${PROJECT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn "Backing up existing .env to ${ENV_FILE}.bak"
  cp "$ENV_FILE" "${ENV_FILE}.bak"
fi

# envsubst preflight
if ! command -v envsubst &>/dev/null; then
  error "envsubst not installed — install with: sudo apt-get install gettext-base"
fi

export PROJECT_DIR VLLM_OMNI_MODEL HF_TOKEN VLLM_OMNI_GPU_UTIL VLLM_OMNI_MAX_MODEL_LEN VLLM_OMNI_EXTRA_ARGS
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${PROJECT_DIR} ${VLLM_OMNI_MODEL} ${HF_TOKEN} ${VLLM_OMNI_GPU_UTIL} ${VLLM_OMNI_MAX_MODEL_LEN} ${VLLM_OMNI_EXTRA_ARGS}' \
  < "${TEMPLATE_DIR}/env.template" > "$ENV_FILE"

chmod 600 "$ENV_FILE"
success ".env written (mode 600): ${ENV_FILE}"

# ── Generate docker-compose.yml ────────────────────────────────────────────────
step "Generating docker-compose.yml"

# Build command flags (Docker Compose variables stay as ${VAR}, static values are literal)
VLLM_OMNI_COMMAND_FLAGS=""
case "$BACKEND" in
  nvidia|amd) VLLM_OMNI_COMMAND_FLAGS="--gpu-memory-utilization \${VLLM_OMNI_GPU_UTIL}" ;;
  cpu)        VLLM_OMNI_COMMAND_FLAGS="--device cpu" ;;
esac
if [[ "${VLLM_OMNI_TENSOR_PARALLEL}" -gt 1 ]]; then
  VLLM_OMNI_COMMAND_FLAGS="${VLLM_OMNI_COMMAND_FLAGS}
      --tensor-parallel-size ${VLLM_OMNI_TENSOR_PARALLEL}"
fi
if [[ -n "${VLLM_OMNI_MAX_MODEL_LEN}" ]]; then
  VLLM_OMNI_COMMAND_FLAGS="${VLLM_OMNI_COMMAND_FLAGS}
      --max-model-len \${VLLM_OMNI_MAX_MODEL_LEN}"
fi
VLLM_OMNI_COMMAND_FLAGS="${VLLM_OMNI_COMMAND_FLAGS}
      \${VLLM_OMNI_EXTRA_ARGS}"

GENERATED_DATE="$(date -Iseconds)"
BACKEND_UPPER="${BACKEND^^}"

# Select compose template based on backend × arch (cpu only) × exposure mode
if [[ "$BACKEND" == "cpu" ]]; then
  if [[ "$ARCH" == "aarch64" ]]; then CPU_VARIANT="cpu.aarch64"; else CPU_VARIANT="cpu.x86_64"; fi
else
  CPU_VARIANT="$BACKEND"
fi
if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.${CPU_VARIANT}.traefik.yml"
else
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.${CPU_VARIANT}.direct.yml"
fi

export GENERATED_DATE BACKEND_UPPER ARCH VLLM_OMNI_IMAGE PROXY_NETWORK \
  VLLM_OMNI_PORT VLLM_OMNI_DOMAIN VLLM_OMNI_SHM_SIZE HF_CACHE_DIR VLLM_OMNI_COMMAND_FLAGS
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${GENERATED_DATE} ${BACKEND_UPPER} ${ARCH} ${VLLM_OMNI_IMAGE} ${PROXY_NETWORK} ${VLLM_OMNI_PORT} ${VLLM_OMNI_DOMAIN} ${VLLM_OMNI_SHM_SIZE} ${HF_CACHE_DIR} ${VLLM_OMNI_COMMAND_FLAGS}' \
  < "$COMPOSE_TEMPLATE" > "$COMPOSE_FILE"

success "docker-compose.yml created: ${COMPOSE_FILE}"

# ── Re-run policy (ticket 12): model args cannot converge a running stack ──
# Model args are baked into the container command at create time (rendered
# into the compose file and/or resolved from .env at start). The rendered
# config (compose + .env, generated-date lines excluded) is compared with
# what the running stack was last created from; on divergence print the exact
# remedy and exit 0 — never silently recreate.
CONVERGE_HASH_FILE="${PROJECT_DIR}/.converge-hash"
_render_hash="$(sed '/^# Generated/d' "$COMPOSE_FILE" "$ENV_FILE" | sha256sum | awk '{print $1}')"
if [[ "$VLLM_OMNI_STACK_RUNNING" == "true" && "$RECREATE_VLLM_OMNI" != "true" ]]; then
  _stored_hash="$(cat "$CONVERGE_HASH_FILE" 2>/dev/null || true)"
  if [[ -n "${_stored_hash}" && "${_stored_hash}" != "${_render_hash}" ]]; then
    warn "Rendered vLLM-Omni config (.env model args / compose) differs from the running stack."
    warn "Model args are baked into the container command at create time."
    warn "Converge now:"
    warn "  cd ${PROJECT_DIR} && docker compose up -d --force-recreate"
    warn "Or tear down and re-create:"
    warn "  $0 --force"
    exit 0
  fi
fi

# ── Pull image ─────────────────────────────────────────────────────────────────
step "Pulling Docker image: ${VLLM_OMNI_IMAGE}"
(cd "$PROJECT_DIR" && docker compose pull)
success "Image pulled."

# ── Start stack (only when a model is configured) ─────────────────────────────
if [[ -z "$VLLM_OMNI_MODEL" ]]; then
  echo ""
  warn "No model configured - skipping container start."
  echo ""
  info "Next steps:"
  info "  1. Download a model with huggingface-cli, e.g.:"
  info "       huggingface-cli download Tongyi-MAI/Z-Image-Turbo"
  info "  2. Set VLLM_OMNI_MODEL in ${ENV_FILE}:"
  info "       VLLM_OMNI_MODEL=Tongyi-MAI/Z-Image-Turbo"
  info "  3. Start the stack:"
  info "       cd ${PROJECT_DIR} && docker compose up -d"
  echo ""
else
  step "Starting vLLM-Omni stack"
  (cd "$PROJECT_DIR" && docker compose up -d)

  # Health gate: prove the container is actually up before reporting success.
  # 300 s default: model loading is slow on inference stacks.
  mapfile -t _ids < <(cd "$PROJECT_DIR" && docker compose ps -q)
  wait_for_healthy "${VLLM_OMNI_HEALTH_TIMEOUT:-300}" "${_ids[@]}" \
    || error "vLLM-Omni stack did not come up — see the status output above"

  # Re-run policy (ticket 12): record what the stack is now created from, so
  # the next run can detect divergent model args (see hash check above).
  printf '%s\n' "${_render_hash}" > "$CONVERGE_HASH_FILE"

  step "Waiting for vLLM-Omni to respond"

  if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
    info "Traefik mode: skipping direct health check (access via https://${VLLM_OMNI_DOMAIN})."
  else
    MAX_WAIT=120
    INTERVAL=5
    ELAPSED=0
    READY=false

    while [[ $ELAPSED -lt $MAX_WAIT ]]; do
      if curl -sf "http://localhost:${VLLM_OMNI_PORT}/health" &>/dev/null; then
        READY=true; break
      fi
      echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ..."
      sleep $INTERVAL
      ELAPSED=$((ELAPSED + INTERVAL))
    done
    echo ""

    if [[ "$READY" == "true" ]]; then
      success "vLLM-Omni is up and healthy!"
    else
      warn "vLLM-Omni did not respond within ${MAX_WAIT}s - it may still be loading the model."
      warn "Follow logs: cd ${PROJECT_DIR} && docker compose logs -f"
    fi
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}vLLM-Omni installation complete!${RESET}"
echo ""
echo -e "  ${BOLD}Backend:${RESET}       ${GREEN}${BACKEND^^}${RESET}  (${ARCH})"
echo -e "  ${BOLD}Image:${RESET}         ${VLLM_OMNI_IMAGE}"
echo -e "  ${BOLD}Project dir:${RESET}   ${PROJECT_DIR}"
echo -e "  ${BOLD}HF cache:${RESET}      ${HF_CACHE_DIR}  ->  /root/.cache/huggingface (in container)"
if [[ "${VLLM_OMNI_TENSOR_PARALLEL}" -gt 1 ]]; then
  echo -e "  ${BOLD}Tensor parallel:${RESET} ${VLLM_OMNI_TENSOR_PARALLEL} GPUs"
fi
echo -e "  ${BOLD}Config:${RESET}        ${ENV_FILE}"
echo ""
if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
  echo -e "  ${BOLD}API (Traefik):${RESET} https://${VLLM_OMNI_DOMAIN}/v1"
else
  echo -e "  ${BOLD}API:${RESET}           http://localhost:${VLLM_OMNI_PORT}/v1"
fi

if [[ -n "$VLLM_OMNI_MODEL" ]]; then
  echo -e "  ${BOLD}Model:${RESET}         ${VLLM_OMNI_MODEL}"
else
  echo ""
  echo -e "  ${YELLOW}${BOLD}Model not configured yet.${RESET}  Edit ${ENV_FILE} and set VLLM_OMNI_MODEL,"
  echo -e "  then: cd ${PROJECT_DIR} && docker compose up -d"
fi

echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Start:        cd ${PROJECT_DIR} && docker compose up -d"
echo -e "  Stop:         cd ${PROJECT_DIR} && docker compose down"
echo -e "  Logs:         cd ${PROJECT_DIR} && docker compose logs -f"
echo -e "  Shell:        docker exec -it vllm-omni bash"
echo -e "  Status:       $0 --check"
echo ""
echo -e "  ${BOLD}List loaded models:${RESET}"
echo -e "    curl http://localhost:${VLLM_OMNI_PORT}/v1/models"
echo ""
