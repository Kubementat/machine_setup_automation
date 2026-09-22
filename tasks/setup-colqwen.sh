#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-colqwen.sh
# Generates a ColQwen2.5 embedding-service Docker project under /srv/colqwen.
#
# The script only GENERATES the project - build and start it yourself:
#   cd /srv/colqwen && docker compose build && docker compose up -d
#
# Models are never downloaded and never baked into the image; they are
# mounted read-only from COLQWEN_MODEL_DIR. You are responsible for choosing
# compatible NGC PyTorch / colpali-engine versions (no validation happens).
#
# Usage:
#   ./setup-colqwen.sh                 # generate with defaults
#   ./setup-colqwen.sh --check         # show status and exit
#   ./setup-colqwen.sh --force         # re-generate over an existing project
#   ./setup-colqwen.sh --help          # show help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates/colqwen"

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-/srv/colqwen}"
COLQWEN_MODEL_DIR="${COLQWEN_MODEL_DIR:-}"   # empty = default (HF cache)
COLQWEN_MODEL="${COLQWEN_MODEL:-vidore/colqwen2.5-v0.2}"
COLPALI_VERSION="${COLPALI_VERSION:-0.3.13}"
NGC_PYTORCH_TAG="${NGC_PYTORCH_TAG:-25.10-py3}"
COLQWEN_PORT="${COLQWEN_PORT:-8100}"

FORCE=0
CHECK_ONLY=0
INTERACTIVE=false   # re-run policy (ticket 12): offer re-generate of an existing project
COLQWEN_HEALTH_TIMEOUT="${COLQWEN_HEALTH_TIMEOUT:-600}"   # model loading is slow
WARNINGS=()

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}Usage:${RESET} $0 [OPTIONS]"
  echo ""
  echo "Generates a ColQwen2.5 embedding-service Docker project."
  echo "A FRESH project is NOT built or started - do that yourself afterwards:"
  echo "  cd ${PROJECT_DIR} && docker compose build && docker compose up -d"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo "  --dir <path>              Project directory  (default: /srv/colqwen)"
  echo "  --model-dir <path>        Host directory with the models - typically the"
  echo "                            HF cache. Mounted read-only at the IDENTICAL"
  echo "                            path in the container so absolute base-model"
  echo "                            paths in adapter_config.json resolve."
  echo "                            (default: \$HOME/.cache/huggingface)"
  echo "  --model <id-or-path>      Model to load: HF model ID (resolved offline"
  echo "                            from the mounted cache) or absolute model dir"
  echo "                            path  (default: vidore/colqwen2.5-v0.2)"
  echo "  --colpali-version <ver>   colpali-engine version  (default: 0.3.13)"
  echo "  --ngc-tag <tag>           NGC PyTorch base image tag  (default: 25.10-py3)"
  echo "  --port <n>                Host port for the service  (default: 8100)"
  echo "  --force                   Re-generate over an existing project"
  echo "  --interactive             Offer tear-down/re-create of an existing stack (default: converge)"
  echo "  --check                   Show installation status and exit"
  echo "  --help                    Show this help"
  echo ""
  echo -e "${BOLD}Environment variables${RESET} (flag equivalents):"
  echo "  PROJECT_DIR, COLQWEN_MODEL_DIR, COLQWEN_MODEL,"
  echo "  COLPALI_VERSION, NGC_PYTORCH_TAG, COLQWEN_PORT"
  echo "  COLQWEN_HEALTH_TIMEOUT  Seconds to wait for the stack to come up"
  echo "                           after 'docker compose up -d' (default: 600 -"
  echo "                           model loading is slow)"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo "  $0                                        # generate with defaults"
  echo "  $0 --model vidore/colqwen2.5-v0.2 --port 8101"
  echo "  $0 --model-dir /srv/models --model /srv/models/colqwen2.5-v0.2"
  echo "  $0 --ngc-tag 25.10-py3 --colpali-version 0.3.13"
  echo "  $0 --force                                # re-generate (.env backed up)"
  echo ""
  echo -e "${BOLD}Re-run policy${RESET} (converge by default):"
  echo "  Re-running an existing project converges the stack: the .env is re-rendered"
  echo "  (stored values reused) and 'docker compose up -d' starts/reconciles the"
  echo "  container. Model args that diverge from the running stack are printed"
  echo "  with the exact re-create command. --force re-generates the project."
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)              shift; PROJECT_DIR="$1" ;;
    --model-dir)        shift; COLQWEN_MODEL_DIR="$1" ;;
    --model)            shift; COLQWEN_MODEL="$1" ;;
    --colpali-version)  shift; COLPALI_VERSION="$1" ;;
    --ngc-tag)          shift; NGC_PYTORCH_TAG="$1" ;;
    --port)             shift; COLQWEN_PORT="$1" ;;
    --force)            FORCE=1 ;;
    --interactive)      INTERACTIVE=true ;;
    --check)            CHECK_ONLY=1 ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# Resolve the model dir default and remember whether it was user-provided.
MODEL_DIR_EXPLICIT=1
if [[ -z "$COLQWEN_MODEL_DIR" ]]; then
  COLQWEN_MODEL_DIR="${HOME}/.cache/huggingface"
  MODEL_DIR_EXPLICIT=0
fi

# ── Input validation ──────────────────────────────────────────────────────────
# Values end up in .env via envsubst - restrict them to safe characters to
# prevent template injection.

validate_safe_string() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    error "${name} contains invalid characters. Allowed: A-Z a-z 0-9 . _ -"
  fi
}

validate_abs_path() {
  local name="$1" value="$2"
  if [[ "$value" != /* ]]; then
    error "${name} must be an absolute path (got: ${value})"
  fi
}

validate_port() {
  if [[ ! "$COLQWEN_PORT" =~ ^[0-9]+$ || "$COLQWEN_PORT" -lt 1 || "$COLQWEN_PORT" -gt 65535 ]]; then
    error "COLQWEN_PORT must be a number between 1 and 65535 (got: ${COLQWEN_PORT})"
  fi
}

# HF model ID or absolute path - like safe strings but slashes are allowed.
validate_model() {
  if [[ ! "$COLQWEN_MODEL" =~ ^[A-Za-z0-9._/-]+$ || "$COLQWEN_MODEL" == *..* ]]; then
    error "COLQWEN_MODEL contains invalid characters. Allowed: A-Z a-z 0-9 . _ / -  (no '..')"
  fi
}

validate_abs_path  "PROJECT_DIR"        "$PROJECT_DIR"
validate_abs_path  "COLQWEN_MODEL_DIR"  "$COLQWEN_MODEL_DIR"
validate_model
validate_safe_string "COLPALI_VERSION"    "$COLPALI_VERSION"
validate_safe_string "NGC_PYTORCH_TAG"    "$NGC_PYTORCH_TAG"
validate_port

# ── Pre-flight checks ─────────────────────────────────────────────────────────
step "Pre-flight checks"

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "0.0.0")
if [[ "$(echo "$COMPOSE_VER" | cut -d'.' -f1)" -lt 2 ]]; then
  warn "Docker Compose v2+ recommended. Current: ${COMPOSE_VER}"
fi

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
fi

# The compose file requests the GPU as a CDI device ("nvidia.com/gpu=all")
# rather than via deploy.resources.reservations.devices. The legacy path hands
# the devices to the container from an OCI prestart hook, after runc has
# created its systemd scope, so a later `systemctl daemon-reload` rewrites the
# scope's device filter and revokes GPU access from the running container
# without killing it. CDI puts the devices in the OCI spec up front, which
# survives a reload. That means the CDI spec must exist before `compose up`.
if ! command -v nvidia-ctk &>/dev/null; then
  error "nvidia-ctk is not installed. Required for the CDI GPU spec. Run setup-nvidia-container.sh first."
fi
if ! nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
  error "No CDI spec for nvidia.com/gpu=all. Run setup-nvidia-container.sh — it generates the
  spec and installs an apt hook that regenerates it after every driver upgrade.
  Manual equivalent: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
fi
success "CDI spec for nvidia.com/gpu=all present."

# ── Existing installation / status ────────────────────────────────────────────
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

print_status() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║   ColQwen project is already generated ✓     ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Project dir:${RESET}   ${PROJECT_DIR}"
  echo -e "  ${BOLD}Config:${RESET}        ${PROJECT_DIR}/.env"
  if docker compose -f "${COMPOSE_FILE}" ps --quiet 2>/dev/null | grep -q .; then
    echo -e "  ${BOLD}Status:${RESET}        ${GREEN}running${RESET}"
  else
    echo -e "  ${BOLD}Status:${RESET}        ${YELLOW}stopped${RESET}"
  fi
  echo ""
  echo -e "  ${CYAN}Nothing was changed.${RESET}"
  echo ""
}

step "Checking for existing ColQwen project"

COLQWEN_PREEXISTING=false
if [[ -f "$COMPOSE_FILE" ]]; then
  COLQWEN_PREEXISTING=true
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    print_status
    exit 0
  fi
  if [[ "$FORCE" -eq 0 ]]; then
    print_status
    # Re-run policy (ticket 12): a re-run does NOT exit silently — it CONVERGES
    # the existing stack below (re-render .env, 'docker compose up -d', health
    # gate). With --interactive the operator may re-generate instead.
    if [[ "$INTERACTIVE" == "true" ]]; then
      read -rp "    Stack exists. Converge (default) or re-generate the project (re-create)? [c/N] " answer
      if [[ "${answer,,}" == "y" ]]; then
        FORCE=1
      fi
    fi
  fi
  if [[ "$FORCE" -eq 1 ]]; then
    warn "--force specified - re-generating over the existing project."
  fi
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo ""
    echo -e "  ${YELLOW}ColQwen project is not generated yet.${RESET}"
    echo -e "  Run the script without ${BOLD}--check${RESET} to generate it."
    echo -e "  ${CYAN}Nothing was changed.${RESET}"
    echo ""
    exit 0
  fi
  success "No existing project found - proceeding with fresh generation."
fi

# ── Directories ───────────────────────────────────────────────────────────────
step "Creating directories"

if [[ ! -d "$PROJECT_DIR" ]]; then
  sudo mkdir -p "$PROJECT_DIR"
  sudo chown "${USER}:${USER}" "$PROJECT_DIR"
fi
mkdir -p "${PROJECT_DIR}/app"
success "Project dir: ${PROJECT_DIR}"

# ── Model directory handling ──────────────────────────────────────────────────
step "Checking model directory"

add_warning() {
  warn "$1"
  WARNINGS+=("$1")
}

if [[ ! -d "$COLQWEN_MODEL_DIR" ]]; then
  if [[ "$MODEL_DIR_EXPLICIT" -eq 0 ]]; then
    mkdir -p "$COLQWEN_MODEL_DIR"
    add_warning "Model directory ${COLQWEN_MODEL_DIR} was created empty - place your models there before starting the service."
  else
    add_warning "Model directory ${COLQWEN_MODEL_DIR} does not exist (typo?) - it was NOT created."
  fi
fi
# Path-form model: the directory itself must exist.
# ID-form model (e.g. vidore/colqwen2.5-v0.2): expect the HF cache layout.
if [[ "$COLQWEN_MODEL" == /* ]]; then
  MODEL_CHECK_DIR="$COLQWEN_MODEL"
else
  MODEL_CHECK_DIR="${COLQWEN_MODEL_DIR}/hub/models--${COLQWEN_MODEL//\//--}"
fi
if [[ ! -d "$MODEL_CHECK_DIR" ]]; then
  add_warning "Configured model '${COLQWEN_MODEL}' not found (expected: ${MODEL_CHECK_DIR}) - the service will not start until it is present."
fi
if [[ ${#WARNINGS[@]} -eq 0 ]]; then
  success "Model found: ${MODEL_CHECK_DIR}"
fi

# ── Generate project files ────────────────────────────────────────────────────
step "Generating project files"

ENV_FILE="${PROJECT_DIR}/.env"

# Re-run policy (ticket 12): reuse-first .env values. An explicitly set value
# (env or CLI) wins; otherwise the value stored in the existing .env is reused
# so a re-run never resets operator configuration.
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
_env_reuse NGC_PYTORCH_TAG NGC_PYTORCH_TAG
_env_reuse COLPALI_VERSION COLPALI_VERSION
_env_reuse COLQWEN_MODEL_DIR COLQWEN_MODEL_DIR
_env_reuse COLQWEN_MODEL     COLQWEN_MODEL
_env_reuse COLQWEN_PORT      COLQWEN_PORT
if [[ ${#_env_reused[@]} -gt 0 ]]; then
  info "Reused ${#_env_reused[@]} value(s) from ${ENV_FILE} (explicit env/CLI values win)."
fi

if [[ -f "$ENV_FILE" ]]; then
  warn "Backing up existing .env to ${ENV_FILE}.bak"
  cp "$ENV_FILE" "${ENV_FILE}.bak"
fi

GENERATED_DATE="$(date -Iseconds)"
export NGC_PYTORCH_TAG COLPALI_VERSION COLQWEN_MODEL_DIR COLQWEN_MODEL \
  COLQWEN_PORT GENERATED_DATE
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${NGC_PYTORCH_TAG} ${COLPALI_VERSION} ${COLQWEN_MODEL_DIR} ${COLQWEN_MODEL} ${COLQWEN_PORT} ${GENERATED_DATE}' \
  < "${TEMPLATE_DIR}/env.template" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
success ".env written (mode 600): ${ENV_FILE}"

cp "${TEMPLATE_DIR}/Dockerfile"         "${PROJECT_DIR}/Dockerfile"
cp "${TEMPLATE_DIR}/docker-compose.yml" "$COMPOSE_FILE"
cp "${TEMPLATE_DIR}/requirements.txt"   "${PROJECT_DIR}/requirements.txt"
cp "${TEMPLATE_DIR}/app/main.py"        "${PROJECT_DIR}/app/main.py"
cp "${TEMPLATE_DIR}/test.sh"            "${PROJECT_DIR}/test.sh"
cp "${TEMPLATE_DIR}/test.png"           "${PROJECT_DIR}/test.png"
chmod +x "${PROJECT_DIR}/test.sh"
success "Dockerfile, docker-compose.yml, requirements.txt, app/ and test.sh written."

# ── Converge existing stack (re-run policy, ticket 12) ──────────────────────
COLQWEN_CONVERGED=false
if [[ "$COLQWEN_PREEXISTING" == "true" && "$FORCE" -eq 0 ]]; then
  COLQWEN_STACK_RUNNING=false
  if docker compose -f "$COMPOSE_FILE" ps --quiet 2>/dev/null | grep -q .; then
    COLQWEN_STACK_RUNNING=true
  fi

  # Model args are baked into the container at create time (build args + env
  # resolved from .env). Compare the rendered .env with what the running stack
  # was last created from; on divergence print the exact remedy and exit 0.
  CONVERGE_HASH_FILE="${PROJECT_DIR}/.converge-hash"
  _render_hash="$(sed '/^# Generated/d' "$ENV_FILE" | sha256sum | awk '{print $1}')"
  if [[ "$COLQWEN_STACK_RUNNING" == "true" ]]; then
    _stored_hash="$(cat "$CONVERGE_HASH_FILE" 2>/dev/null || true)"
    if [[ -n "${_stored_hash}" && "${_stored_hash}" != "${_render_hash}" ]]; then
      warn "Rendered ColQwen config (.env) differs from the running stack."
      warn "Model args are baked into the container at create time."
      warn "Converge now:"
      warn "  cd ${PROJECT_DIR} && docker compose up -d --force-recreate"
      warn "Or re-run interactively to re-generate the project:"
      warn "  $0 --interactive"
      exit 0
    fi
  fi

  step "Converging existing ColQwen stack"
  if ! (cd "$PROJECT_DIR" && docker compose up -d); then
    error "Failed to converge the ColQwen stack. Check the error output above."
  fi

  # Health gate: prove the container is actually up before reporting success.
  mapfile -t _ids < <(cd "$PROJECT_DIR" && docker compose ps -q)
  wait_for_healthy "${COLQWEN_HEALTH_TIMEOUT}" "${_ids[@]}" \
    || error "ColQwen stack did not come up — see the status output above"

  # Record what the stack is now created from (see hash check above).
  printf '%s\n' "${_render_hash}" > "$CONVERGE_HASH_FILE"
  COLQWEN_CONVERGED=true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║      ColQwen project generated!              ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Project dir:${RESET}      ${PROJECT_DIR}"
echo -e "  ${BOLD}Model dir:${RESET}        ${COLQWEN_MODEL_DIR}  (mounted read-only at the identical path)"
echo -e "  ${BOLD}Model:${RESET}            ${COLQWEN_MODEL}"
echo -e "  ${BOLD}NGC PyTorch tag:${RESET}  ${NGC_PYTORCH_TAG}"
echo -e "  ${BOLD}colpali-engine:${RESET}   ${COLPALI_VERSION}"
echo -e "  ${BOLD}Port:${RESET}             ${COLQWEN_PORT}"
echo -e "  ${BOLD}Config:${RESET}           ${ENV_FILE}"
echo ""
if [[ "$COLQWEN_CONVERGED" == "true" ]]; then
  echo -e "${BOLD}Stack status${RESET} (re-run policy, ticket 12): CONVERGED — 'docker compose up -d"
echo -e "  started or reconciled the container. If the Dockerfile/requirements changed:"
echo -e "    cd ${PROJECT_DIR} && docker compose build && docker compose up -d --force-recreate"
else
  echo -e "${BOLD}Next steps${RESET} (the service was NOT built or started):"
  echo -e "  cd ${PROJECT_DIR}"
  echo -e "  docker compose build"
  echo -e "  docker compose up -d"
  echo -e "  ./test.sh    # smoke test, once the log shows 'Application startup complete'"
  echo ""
  echo -e "${BOLD}Example requests:${RESET}"
  echo -e "  curl -X POST http://localhost:${COLQWEN_PORT}/embed/queries \\\\"
  echo -e "    -H 'Content-Type: application/json' -d '{\"queries\":[\"example query\"]}'"
  echo -e "  curl -X POST http://localhost:${COLQWEN_PORT}/embed/images -F 'files=@page1.png'"
  echo ""
  echo -e "  Change configuration: edit ${ENV_FILE},"
  echo -e "  then: cd ${PROJECT_DIR} && docker compose build && docker compose up -d"
  echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo -e "${BOLD}${YELLOW}Warnings:${RESET}"
  for w in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}•${RESET} ${w}"
  done
  echo ""
fi
