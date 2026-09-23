# setup-vllm-omni.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone, idempotent `tasks/setup-vllm-omni.sh` that deploys a Docker-based, OpenAI-compatible vLLM-Omni inference server for omni-modality models, and register/document it in the repo.

**Architecture:** The new script mirrors the existing [`tasks/setup-vllm.sh`](../../../tasks/setup-vllm.sh) almost 1:1 — validate → parse args → detect backend → resolve a **prebuilt** Docker Hub image → generate `.env` + `docker-compose.yml` inline → pull → (only if a model is set) start + health-check → print summary. It differs only in the image (`vllm/vllm-omni` / `vllm/vllm-omni-rocm`), the `--omni` serve flag, a dedicated `VLLM_OMNI_*` env namespace, project dir `/srv/vllm-omni`, and default port `8091`. The existing `setup-vllm.sh` is not touched.

**Tech Stack:** Bash 4+, Docker + Docker Compose v2, `lib/helpers.sh` (shared logging + `ensure_proxy_network`), `shellcheck`, `yamllint`.

**Spec:** [`behaviors.md`](./behaviors.md) · **Research:** [`research.md`](./research.md)

## Global Constraints

- **Idempotent:** re-running without `--force` must not destroy `.env`, config, or model data (copy verbatim from spec).
- **Source shared lib:** `source "${SCRIPT_DIR}/../lib/helpers.sh"` — reuse `info/success/warn/error/step` and `ensure_proxy_network`.
- **Env-var config with defaults:** every tunable is a `VLLM_OMNI_*` env var with a sane default; CLI flags mirror env vars.
- **Data dir:** service files live under `/srv/vllm-omni` (project convention `/srv/<service>`).
- **Compose generation is inline** (heredocs) — justified under the AGENTS.md "except explicitly required" clause because backend/traefik/arch make the compose strongly conditional.
- **No UFW code in the script** (parity with `setup-vllm.sh`).
- **Docker Compose v2+** required; **Ubuntu** target.
- **Lint gates:** `shellcheck` clean on the `.sh`; `yamllint` clean on edited YAML.
- **Testing reality:** the repo has no bash unit-test framework. Verification = `shellcheck` + `bash -n` + `--help`/`--check` smoke runs + `yamllint`. Full GPU serve is verified on the target server (out of scope here).

---

### Task 1: Create `tasks/setup-vllm-omni.sh`

**Files:**
- Create: `tasks/setup-vllm-omni.sh`

**Interfaces:**
- Consumes (from `lib/helpers.sh`): `step`, `info`, `success`, `warn`, `error`, `ensure_proxy_network`, colour vars `BOLD/RESET/RED/GREEN/YELLOW/CYAN`.
- Produces (runtime, on the target host): `/srv/vllm-omni/.env` (mode 600) and `/srv/vllm-omni/docker-compose.yml` whose service `vllm-omni` runs `vllm serve ${VLLM_OMNI_MODEL} --omni --host 0.0.0.0 --port 8000`.

- [ ] **Step 1: Write the script file**

Create `tasks/setup-vllm-omni.sh` with exactly this content:

```bash
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
VLLM_OMNI_GPU_UTIL="${VLLM_OMNI_GPU_UTIL:-0.90}"   # GPU mem fraction (GPU backends)
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
  echo "  --check               Check installation status and exit"
  echo "  --help                Show this help"
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

if [[ -f "$COMPOSE_FILE" ]]; then
  print_found_status

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "Run with ${BOLD}--force${RESET} to re-create the stack."
    exit 0
  fi

  if [[ "$FORCE" -eq 0 ]]; then
    echo -e "  ${YELLOW}Nothing to do.${RESET} Use ${BOLD}--force${RESET} to re-create the stack."
    echo ""
    exit 0
  fi

  warn "--force specified - tearing down existing stack."
  (cd "$PROJECT_DIR" && docker compose down 2>/dev/null) || true
  echo ""
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

  warn "No supported GPU detected - falling back to CPU-only."
  BACKEND="cpu"
}

[[ -z "$BACKEND" ]] && detect_gpu

echo -e "\n${BOLD}Selected backend:${RESET} ${GREEN}${BACKEND^^}${RESET}  |  arch: ${GREEN}${ARCH}${RESET}\n"

[[ "$BACKEND" == "cpu" ]] && warn "CPU backend: generative/diffusion Omni models are impractical on CPU (very slow)."

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

cat > "$ENV_FILE" << EOF
# vLLM-Omni configuration
# Edit this file then restart the stack:  cd ${PROJECT_DIR} && docker compose up -d

# ── Model ────────────────────────────────────────────────────────────────────
# HuggingFace model ID (fetched into the mounted HF cache), examples:
#   VLLM_OMNI_MODEL=Tongyi-MAI/Z-Image-Turbo          # text-to-image (quickstart)
#   VLLM_OMNI_MODEL=<HF TTS / diffusion / any-to-any Omni model id>
# Or a path to an HF snapshot inside the container:
#   VLLM_OMNI_MODEL=/root/.cache/huggingface/hub/models--.../snapshots/latest
VLLM_OMNI_MODEL=${VLLM_OMNI_MODEL}

# ── HuggingFace token (leave empty if not needed) ────────────────────────────
HF_TOKEN=${HF_TOKEN}

# ── GPU memory utilization fraction (0.0-1.0) - ignored for CPU backend ──────
VLLM_OMNI_GPU_UTIL=${VLLM_OMNI_GPU_UTIL}

# ── Max context length (tokens) - leave empty to use the model's default ─────
VLLM_OMNI_MAX_MODEL_LEN=${VLLM_OMNI_MAX_MODEL_LEN}

# ── Extra `vllm serve` arguments (space-separated, appended to the command) ──
VLLM_OMNI_EXTRA_ARGS=${VLLM_OMNI_EXTRA_ARGS}
EOF

chmod 600 "$ENV_FILE"
success ".env written (mode 600): ${ENV_FILE}"

# ── Generate docker-compose.yml ────────────────────────────────────────────────
step "Generating docker-compose.yml"

# Header + networks
cat > "$COMPOSE_FILE" << EOF
# vLLM-Omni Docker Compose
# Generated: $(date -Iseconds)
# Backend: ${BACKEND^^} | Arch: ${ARCH} | Image: ${VLLM_OMNI_IMAGE}

networks:
  vllm-omni:
    external: false
EOF

if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
  cat >> "$COMPOSE_FILE" << EOF
  ${PROXY_NETWORK}:
    external: true
EOF
fi

# Service header + static environment
cat >> "$COMPOSE_FILE" << EOF

services:
  vllm-omni:
    image: ${VLLM_OMNI_IMAGE}
    container_name: vllm-omni
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - HF_HOME=/root/.cache/huggingface
      - VLLM_NO_USAGE_STATS=1
EOF

# Volumes + shared memory
cat >> "$COMPOSE_FILE" << EOF
    volumes:
      - ${HF_CACHE_DIR}:/root/.cache/huggingface
    shm_size: '${VLLM_OMNI_SHM_SIZE}'
EOF

# ipc: host recommended for all GPU backends (required for tensor-parallel > 1)
if [[ "$BACKEND" != "cpu" ]]; then
  echo "    ipc: \"host\"" >> "$COMPOSE_FILE"
fi

# Ports (direct mode)
if [[ "$VLLM_OMNI_TRAEFIK" != "true" ]]; then
  cat >> "$COMPOSE_FILE" << EOF
    ports:
      - "${VLLM_OMNI_PORT}:8000"
EOF
fi

# Backend GPU configuration
case "$BACKEND" in
  nvidia)
    cat >> "$COMPOSE_FILE" << 'EOF'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
    ;;
  amd)
    cat >> "$COMPOSE_FILE" << 'EOF'
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - video
    cap_add:
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
EOF
    ;;
esac

# Traefik labels
if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
  cat >> "$COMPOSE_FILE" << EOF
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${PROXY_NETWORK}"
      - "traefik.http.routers.vllm-omni.rule=Host(\`${VLLM_OMNI_DOMAIN}\`)"
      - "traefik.http.routers.vllm-omni.entrypoints=websecure"
      - "traefik.http.routers.vllm-omni.tls.certresolver=letsencrypt"
      - "traefik.http.services.vllm-omni.loadbalancer.server.port=8000"
EOF
fi

# Network references
cat >> "$COMPOSE_FILE" << 'EOF'
    networks:
      - vllm-omni
EOF
if [[ "$VLLM_OMNI_TRAEFIK" == "true" ]]; then
  echo "      - ${PROXY_NETWORK}" >> "$COMPOSE_FILE"
fi

# Command — docker compose substitutes ${VLLM_OMNI_*} from .env at compose time.
# The vllm/vllm-omni images have an empty ENTRYPOINT, so the command must start
# with `vllm serve` and take the model positionally (see behaviors.md edge case).
{
  echo "    command: >"
  echo "      vllm serve \${VLLM_OMNI_MODEL}"
  echo "      --omni"
  echo "      --host 0.0.0.0"
  echo "      --port 8000"
  case "$BACKEND" in
    nvidia|amd) echo "      --gpu-memory-utilization \${VLLM_OMNI_GPU_UTIL}" ;;
    cpu)        echo "      --device cpu" ;;
  esac
  if [[ "${VLLM_OMNI_TENSOR_PARALLEL}" -gt 1 ]]; then
    echo "      --tensor-parallel-size ${VLLM_OMNI_TENSOR_PARALLEL}"
  fi
  if [[ -n "${VLLM_OMNI_MAX_MODEL_LEN}" ]]; then
    echo "      --max-model-len \${VLLM_OMNI_MAX_MODEL_LEN}"
  fi
  echo "      \${VLLM_OMNI_EXTRA_ARGS}"
} >> "$COMPOSE_FILE"

success "docker-compose.yml created: ${COMPOSE_FILE}"

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
  success "Stack started."

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
```

- [ ] **Step 2: Make it executable and run shellcheck**

Run:
```bash
chmod +x tasks/setup-vllm-omni.sh
shellcheck tasks/setup-vllm-omni.sh
```
Expected: no output, exit code 0 (clean).

- [ ] **Step 3: Syntax check**

Run: `bash -n tasks/setup-vllm-omni.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Smoke-test `--help`**

Run: `bash tasks/setup-vllm-omni.sh --help`
Expected: usage text is printed (including the `--omni`-related model-selection examples), exit code 0, no Docker interaction.

- [ ] **Step 5: Smoke-test `--check` on a machine with no install**

Run: `PROJECT_DIR=/tmp/vllm-omni-nonexistent bash tasks/setup-vllm-omni.sh --check`
Expected: prints "vLLM-Omni does not appear to be installed.", exit code 0, no Docker interaction.

- [ ] **Step 6: Commit**

```bash
git add tasks/setup-vllm-omni.sh
git commit -m "feat: add setup-vllm-omni.sh (Docker-based vLLM-Omni server)"
```

---

### Task 2: Register the script in `machine-config.yml.example`

**Files:**
- Modify: `machine-config.yml.example`

**Interfaces:**
- Consumes: the orchestrator (`run-setup.sh`) reads `.scripts.<name>.enabled/env/args`. Script key is `setup-vllm-omni` (filename without `.sh`).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the config entry**

Add this block to `machine-config.yml.example` immediately after the existing `setup-vllm:` entry (keep the two-space indentation used by the other entries):

```yaml
  setup-vllm-omni:
    enabled: false
    description: Deploy vLLM-Omni (omni-modality: TTS, diffusion, image/video, any-to-any)
    env:
      VLLM_OMNI_PORT: '8091'
      # VLLM_OMNI_MODEL: Tongyi-MAI/Z-Image-Turbo
    args: []
```

- [ ] **Step 2: Lint the YAML**

Run: `yamllint machine-config.yml.example`
Expected: no errors (warnings pre-existing in the file are acceptable; introduce no new errors).

- [ ] **Step 3: Verify the orchestrator lists the new task**

Run:
```bash
cp machine-config.yml.example /tmp/mc-omni.yml
./run-setup.sh --config /tmp/mc-omni.yml status
```
Expected: the status table includes a `setup-vllm-omni.sh` row (requires `yq`; if absent, run `setup-basics` first or skip this step and rely on Step 2).

- [ ] **Step 4: Commit**

```bash
git add machine-config.yml.example
git commit -m "chore: register setup-vllm-omni in machine-config example"
```

---

### Task 3: Document the script (README + assistant skill + CONTEXT)

**Files:**
- Modify: `README.md`
- Modify: `skills/kwisatz-assistant/SKILL.md`
- Modify: `CONTEXT.md`

**Interfaces:** none consumed by later tasks (documentation only).

- [ ] **Step 1: Add a README subsection**

In `README.md`, under the **AI & LLM Services** section, add this subsection immediately after the `setup-vllm.sh` subsection:

```markdown
#### `setup-vllm-omni.sh`
Deploys **vLLM-Omni** — the official vLLM sub-project for omni-modality serving (TTS/speech, diffusion, image/video generation, any-to-any models like Qwen3-Omni / Cosmos3) — as a Docker-based, OpenAI-compatible server. Uses prebuilt Docker Hub images (no local build), auto-detects the GPU backend, and serves via `vllm serve <model> --omni`. Runs alongside `setup-vllm.sh` on its own port and directory.

**Environment variables:** `PROJECT_DIR` (default `/srv/vllm-omni`), `HF_CACHE_DIR`, `VLLM_OMNI_VERSION` (default `latest`), `VLLM_OMNI_PORT` (default `8091`), `VLLM_OMNI_MODEL`, `HF_TOKEN`, `VLLM_OMNI_GPU_UTIL` (default `0.90`), `VLLM_OMNI_TENSOR_PARALLEL` (default `1`), `VLLM_OMNI_MAX_MODEL_LEN`, `VLLM_OMNI_SHM_SIZE` (default `8g`), `VLLM_OMNI_EXTRA_ARGS`, `VLLM_OMNI_TRAEFIK` (default `false`), `VLLM_OMNI_DOMAIN`, `PROXY_NETWORK` (default `proxy`)

**Features:**
- Prebuilt images: `vllm/vllm-omni` (NVIDIA, amd64/arm64) and `vllm/vllm-omni-rocm` (AMD)
- Auto-detects NVIDIA / AMD / CPU backend (CPU is impractical for generative models)
- Model-agnostic: without `VLLM_OMNI_MODEL` the container is not started (prints next steps)
- Optional Traefik reverse-proxy integration
- Idempotent; supports `--force` and `--check`
```

- [ ] **Step 2: Add the script to the assistant skill's category table**

In `skills/kwisatz-assistant/SKILL.md`, in the "Service Categories" table, change the **AI / LLM** row's script list to include `setup-vllm-omni`:

Find:
```markdown
| **AI / LLM** | setup-llama-cpp, setup-llama-swap, setup-vllm, setup-lm-studio, setup-openwebui |
```
Replace with:
```markdown
| **AI / LLM** | setup-llama-cpp, setup-llama-swap, setup-vllm, setup-vllm-omni, setup-lm-studio, setup-openwebui |
```

- [ ] **Step 3: Add a CONTEXT.md domain term**

In `CONTEXT.md`, under the `### AI/ML` list, add this bullet after the `vllm` entry:

```markdown
- **vllm-omni** — vLLM sub-project extending inference to omni-modality models (TTS, diffusion, image/video generation, any-to-any); served via `vllm serve <model> --omni`
```

- [ ] **Step 4: Verify formatting**

Run: `git diff --check`
Expected: no whitespace errors. Visually confirm the README subsection and table row render as valid Markdown.

- [ ] **Step 5: Commit**

```bash
git add README.md skills/kwisatz-assistant/SKILL.md CONTEXT.md
git commit -m "docs: document setup-vllm-omni (README, assistant skill, CONTEXT)"
```

---

## Final Verification

After all tasks, run the full local gate:

```bash
shellcheck tasks/setup-vllm-omni.sh          # clean
bash -n tasks/setup-vllm-omni.sh             # clean
bash tasks/setup-vllm-omni.sh --help         # exit 0
yamllint machine-config.yml.example          # no new errors
git log --oneline -3                          # three focused commits
```

Server-side (out of scope for local verification, run on the target NVIDIA host): `bash tasks/setup-vllm-omni.sh --nvidia`, confirm the generated `/srv/vllm-omni/docker-compose.yml` contains `--omni` and passes `docker compose -f /srv/vllm-omni/docker-compose.yml config`, then set `VLLM_OMNI_MODEL` and start.

## Self-Review Notes

- **Spec coverage:** input validation, arg parsing, pre-flight, backend detection + image resolution, idempotency (`--check`/`--force`), dir/`.env`/compose generation, model-agnostic start, health check, summary, and all four registration/doc edits each map to a task/step above.
- **Deviation from `setup-vllm.sh` (intentional):** the Blackwell-specific image swap, the CUDA-13 hard gate, the INT8-on-Blackwell guard, and the LM Studio models mount are **omitted** — vLLM-Omni ships its own prebuilt images and those checks are specific to `vllm-openai`. Recorded here so a reviewer does not flag the absence as a mistake.
- **Placeholder scan:** none — all steps contain concrete code/commands.
- **Naming consistency:** `VLLM_OMNI_*` env names, the `vllm-omni` service/container/network name, and the `setup-vllm-omni` config key are used consistently across script, config, and docs.
