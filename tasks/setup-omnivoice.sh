#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-omnivoice.sh — OmniVoice.cpp TTS REST API as a systemd service
# =============================================================================
#
# DESCRIPTION:
#   Builds the OmniVoice.cpp `tts-server` (an OpenAI-compatible text-to-speech
#   HTTP server) from source for the detected GPU backend (Vulkan / CUDA / CPU)
#   and runs it as a native systemd service under a dedicated non-root user.
#   There is no official Docker image, so the single self-contained binary is
#   built from source and installed to /usr/local/bin.
#
# KEY ACTIONS:
#   1.  Pre-flight checks: systemctl, curl, envsubst, git, hf, ref shape
#   2.  Auto-detect (or honour) the GPU backend: vulkan | cuda | cpu
#   3.  Install base + backend build dependencies (idempotent apt)
#   4.  Ensure the non-root service user + GPU (render/video) groups
#   5.  Clone / update the source (ggml is a submodule)
#   6.  Build (only when the binary is missing or ref/backend changed, or --force)
#   7.  Install the binary to /usr/local/bin
#   8.  Download the base + tokenizer models (skipped when already present)
#   9.  Render + install the systemd unit; restart only when it changed
#   10. Bounded GET /health gate (non-zero exit on timeout)
#   11. UFW inbound rule for the port when bound to a non-loopback address
#
# IMPORTANT VARIABLES (all optional, OMNIVOICE_*):
#   OMNIVOICE_HOME           Base dir for models + build source (default: /srv/omnivoice)
#   OMNIVOICE_PORT           Listen port (default: 8977)
#   OMNIVOICE_HOST           Bind address (default: 127.0.0.1; 0.0.0.0 = LAN + ufw rule)
#   OMNIVOICE_BACKEND        Build backend: auto | vulkan | cuda | cpu (default: auto)
#   OMNIVOICE_BASE_MODEL     Base LLM GGUF file name (default: omnivoice-base-Q8_0.gguf)
#   OMNIVOICE_TOKENIZER_MODEL Codec GGUF file name (default: omnivoice-tokenizer-F32.gguf)
#   OMNIVOICE_HF_REPO        Hugging Face repo (default: Serveurperso/OmniVoice-GGUF)
#   OMNIVOICE_USER           systemd runtime user (default: omnivoice)
#   OMNIVOICE_LANG           Default --lang label; empty = server default (None)
#   OMNIVOICE_NO_FA          Pass --no-fa (disable flash attention) (default: false)
#   OMNIVOICE_CLAMP_FP16     Pass --clamp-fp16 (clamp hidden states to FP16) (default: false)
#   OMNIVOICE_REF            Source ref to build (default: master; pin a tag for repro builds)
#   OMNIVOICE_REPO_URL       Upstream git URL (default: https://github.com/ServeurpersoCom/omnivoice.cpp.git)
#   OMNIVOICE_HEALTH_TIMEOUT Seconds to wait for GET /health (default: 600)
#
# DEPENDENCIES:
#   - systemctl, curl, envsubst (gettext-base), git, hf (setup-basics.sh)
#   - build-essential, cmake (installed by this script)
#
# OUTPUTS:
#   - /srv/omnivoice/models/            — the two GGUF model files
#   - /srv/omnivoice/src/omnivoice.cpp/ — build source (kept for rebuilds)
#   - /usr/local/bin/omnivoice-tts-server
#   - /etc/systemd/system/omnivoice.service
#
# USAGE:
#   ./setup-omnivoice.sh                    # defaults (auto backend, loopback)
#   ./setup-omnivoice.sh --check            # check status only (no changes)
#   ./setup-omnivoice.sh --force            # force rebuild + re-render + restart
#   ./setup-omnivoice.sh --interactive      # prompt before replacing an install
#   OMNIVOICE_BACKEND=cpu ./setup-omnivoice.sh   # CPU build (no GPU)
#
#   Re-runs converge by default: models are never re-downloaded, the build is
#   skipped unless the binary is missing or ref/backend changed, and the
#   service is restarted only when the rendered unit differs.
#
# REFERENCE:
#   https://github.com/ServeurpersoCom/omnivoice.cpp
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures
# ─────────────────────────────────────────────────────────────────────────────
# Set to 1 immediately before this run stops/enables/starts the unit, reset to 0
# once the service is proven healthy. A late failure (download, ufw) then cannot
# stop a unit that was running before this script was invoked.
SERVICE_TOUCHED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( SERVICE_TOUCHED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). The omnivoice service was not touched by this run — nothing stopped or disabled."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Cleaning up the service state from this run..."
  if sudo systemctl cat omnivoice &>/dev/null 2>&1; then
    if sudo systemctl is-active omnivoice &>/dev/null; then
      info "Disabling and stopping partially configured service..."
      sudo systemctl stop omnivoice 2>/dev/null || true
      sudo systemctl disable omnivoice 2>/dev/null || true
      sudo systemctl daemon-reload 2>/dev/null || true
      success "Partial service stopped."
    else
      info "Service from this run is already stopped — config and data in ${OMNIVOICE_HOME} are preserved."
    fi
  fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/omnivoice")"

# shellcheck disable=SC1090
source "${LIB_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

OMNIVOICE_HOME="${OMNIVOICE_HOME:-/srv/omnivoice}"
OMNIVOICE_PORT="${OMNIVOICE_PORT:-8977}"
OMNIVOICE_HOST="${OMNIVOICE_HOST:-127.0.0.1}"
OMNIVOICE_BACKEND="${OMNIVOICE_BACKEND:-auto}"            # auto | vulkan | cuda | cpu
OMNIVOICE_BASE_MODEL="${OMNIVOICE_BASE_MODEL:-omnivoice-base-Q8_0.gguf}"
OMNIVOICE_TOKENIZER_MODEL="${OMNIVOICE_TOKENIZER_MODEL:-omnivoice-tokenizer-F32.gguf}"
OMNIVOICE_HF_REPO="${OMNIVOICE_HF_REPO:-Serveurperso/OmniVoice-GGUF}"
OMNIVOICE_USER="${OMNIVOICE_USER:-omnivoice}"
OMNIVOICE_LANG="${OMNIVOICE_LANG:-}"
OMNIVOICE_NO_FA="${OMNIVOICE_NO_FA:-false}"
OMNIVOICE_CLAMP_FP16="${OMNIVOICE_CLAMP_FP16:-false}"
OMNIVOICE_REF="${OMNIVOICE_REF:-master}"
OMNIVOICE_REPO_URL="${OMNIVOICE_REPO_URL:-https://github.com/ServeurpersoCom/omnivoice.cpp.git}"
OMNIVOICE_HEALTH_TIMEOUT="${OMNIVOICE_HEALTH_TIMEOUT:-600}"

# The port is baked into the unit's ExecStart, the health URL and the UFW rule —
# fail fast on a typo instead of rendering a broken unit.
if ! [[ "${OMNIVOICE_PORT}" =~ ^[0-9]+$ ]] || (( OMNIVOICE_PORT < 1 || OMNIVOICE_PORT > 65535 )); then
  error "OMNIVOICE_PORT '${OMNIVOICE_PORT}' is not a valid port number (must be 1-65535)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# COMPUTED VALUES
# ─────────────────────────────────────────────────────────────────────────────

OMNIVOICE_SRC="${OMNIVOICE_HOME}/src/omnivoice.cpp"
OMNIVOICE_BUILD_BIN="${OMNIVOICE_SRC}/build/tts-server"
OMNIVOICE_MODEL_DIR="${OMNIVOICE_HOME}/models"
OMNIVOICE_BIN_PATH="/usr/local/bin/omnivoice-tts-server"
SERVICE_FILE="/etc/systemd/system/omnivoice.service"
BUILD_MARKER="${OMNIVOICE_HOME}/src/.build-marker"
CHECK_ONLY=0
FORCE=0
INTERACTIVE=false

# The ref reaches git as --branch/checkout arguments — keep it ref-shaped so a
# stray option (leading '-') or shell metacharacter can never reach git.
if [[ ! "${OMNIVOICE_REF}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
  error "OMNIVOICE_REF '${OMNIVOICE_REF}' is not a valid tag/branch name (letters, digits, dot, underscore, slash, hyphen; must not start with '-')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Builds the OmniVoice.cpp tts-server (OpenAI-compatible TTS) from source and runs
it as a native systemd service under a non-root user. There is no official Docker
image, so the single binary is built from source and installed to /usr/local/bin.

${BOLD}Options:${RESET}
  --check        Check installation status only (no changes)
  --force        Force rebuild + re-render + restart even when unchanged
  --interactive  Prompt before replacing an existing install (default: converge)
  -h, --help     Show this help and exit

  Re-runs converge by default: models are never re-downloaded, the build is
  skipped unless the binary is missing or ref/backend changed, and the service
  is restarted only when the rendered unit differs.

${BOLD}Environment variables${RESET} (all optional, OMNIVOICE_*):
  OMNIVOICE_HOME           Base dir for models + build source (default: /srv/omnivoice)
  OMNIVOICE_PORT           Listen port (default: 8977)
  OMNIVOICE_HOST           Bind address (default: 127.0.0.1; 0.0.0.0 = LAN, adds a ufw rule)
  OMNIVOICE_BACKEND        Build backend: auto | vulkan | cuda | cpu (default: auto)
  OMNIVOICE_BASE_MODEL     Base LLM GGUF file (default: omnivoice-base-Q8_0.gguf)
  OMNIVOICE_TOKENIZER_MODEL Codec GGUF file (default: omnivoice-tokenizer-F32.gguf)
  OMNIVOICE_HF_REPO        Hugging Face repo (default: Serveurperso/OmniVoice-GGUF)
  OMNIVOICE_USER           systemd runtime user (default: omnivoice)
  OMNIVOICE_LANG           Default --lang label (default: empty = server default None)
  OMNIVOICE_NO_FA          Pass --no-fa to disable flash attention (default: false)
  OMNIVOICE_CLAMP_FP16     Pass --clamp-fp16 to clamp hidden states (default: false)
  OMNIVOICE_REF            Source ref to build (default: master; pin a tag to repro)
  OMNIVOICE_REPO_URL       Upstream git URL (default: https://github.com/ServeurpersoCom/omnivoice.cpp.git)
  OMNIVOICE_HEALTH_TIMEOUT Seconds to wait for GET /health (default: 600)
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    --interactive) INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

if ! command -v systemctl &>/dev/null; then
  error "systemctl is not available. This script requires systemd."
fi
if ! command -v curl &>/dev/null; then
  error "curl is not installed. Required for the /health gate. Install: sudo apt-get install curl"
fi
if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install: sudo apt-get install gettext-base"
fi
if ! command -v git &>/dev/null; then
  error "git is not installed. Required for the source build. Install: sudo apt-get install git"
fi
if ! command -v hf &>/dev/null && [[ -x "$HOME/.local/bin/hf" ]]; then
  # setup-basics.sh installs hf into ~/.local/bin, which non-login shells
  # (sudo, orchestrator runs) do not have on PATH.
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v hf &>/dev/null; then
  error "hf CLI is not installed. Required to download the models. Run tasks/setup-basics.sh, or: pip install -U \"huggingface_hub[cli]\""
fi

if [[ $EUID -eq 0 ]]; then
  warn "Running as root — the service user will still be created and used for the unit."
fi
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Continuing anyway…"
fi

# ─────────────────────────────────────────────────────────────────────────────
# GPU BACKEND SELECTION
# ─────────────────────────────────────────────────────────────────────────────

# Resolved build backend: vulkan | cuda | cpu
BACKEND="${OMNIVOICE_BACKEND}"

detect_backend() {
  step "Auto-detecting GPU backend"
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    info "NVIDIA GPU detected via nvidia-smi."
    BACKEND="cuda"; return
  fi
  if command -v lspci &>/dev/null; then
    if lspci 2>/dev/null | grep -qi "NVIDIA"; then
      info "NVIDIA GPU detected via lspci."
      BACKEND="cuda"; return
    fi
    if lspci 2>/dev/null | grep -Eqi "AMD|Radeon"; then
      info "AMD/Intel (Vulkan) GPU detected via lspci."
      BACKEND="vulkan"; return
    fi
  fi
  if ls /dev/dri/renderD* &>/dev/null; then
    info "Render node present under /dev/dri (Vulkan-capable)."
    BACKEND="vulkan"; return
  fi
  warn "No supported GPU detected — falling back to a CPU build (usable but latency-limited for a 612M LLM + codec)."
  BACKEND="cpu"
}

if [[ "${BACKEND}" == "auto" ]]; then
  detect_backend
else
  case "${BACKEND}" in
    vulkan|cuda|cpu) ;;
    *) error "OMNIVOICE_BACKEND '${BACKEND}' is invalid (expected: auto, vulkan, cuda, or cpu)" ;;
  esac
fi
info "Selected build backend: ${BACKEND^^}"

# ─────────────────────────────────────────────────────────────────────────────
# CHECK-ONLY MODE (status report, no side effects)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  step "Checking omnivoice installation status"
  if [[ -f "${SERVICE_FILE}" ]]; then
    success "Systemd unit found at ${SERVICE_FILE}"
    if systemctl is-active omnivoice &>/dev/null 2>&1; then
      success "Service is currently running."
    else
      warn "Service is not running. Start with: sudo systemctl start omnivoice"
    fi
  else
    warn "No systemd unit at ${SERVICE_FILE} — omnivoice does not appear to be installed."
  fi
  if [[ -x "${OMNIVOICE_BIN_PATH}" ]]; then
    success "Binary found at ${OMNIVOICE_BIN_PATH}"
  else
    warn "Binary not found at ${OMNIVOICE_BIN_PATH}"
  fi
  for f in "${OMNIVOICE_BASE_MODEL}" "${OMNIVOICE_TOKENIZER_MODEL}"; do
    if [[ -f "${OMNIVOICE_MODEL_DIR}/${f}" ]]; then
      success "Model present: ${OMNIVOICE_MODEL_DIR}/${f}"
    else
      warn "Model missing:  ${OMNIVOICE_MODEL_DIR}/${f}"
    fi
  done
  info "Run without --check to install (backend: ${BACKEND})."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE GUARD
# ─────────────────────────────────────────────────────────────────────────────
# Non-interactive runs converge by default. With --interactive, ask before
# converging an existing install (converge is the safe path; `n` keeps it).
if [[ "${INTERACTIVE}" == "true" && "${FORCE}" -eq 0 && -f "${SERVICE_FILE}" ]]; then
  echo ""
  read -rp "    An omnivoice install exists at ${SERVICE_FILE}. Re-converge (re-render unit, rebuild if needed)? [y/N] " _answer
  if [[ "${_answer,,}" != "y" ]]; then
    info "Keeping the existing install. Exiting."
    exit 0
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL DEPENDENCIES
# ─────────────────────────────────────────────────────────────────────────────

step "Installing build dependencies (base + ${BACKEND})"
sudo apt-get update -qq
sudo apt-get install -y \
  build-essential cmake git pkg-config curl ca-certificates

case "${BACKEND}" in
  vulkan)
    sudo apt-get install -y mesa-vulkan-drivers vulkan-tools libvulkan-dev glslc
    success "Vulkan build dependencies installed."
    ;;
  cuda)
    # buildcuda.sh hard-codes /usr/local/cuda/bin/nvcc, so only a toolkit under
    # /usr/local/cuda* is usable. The apt nvidia-cuda-toolkit is broken on
    # aarch64 (ARM64 SVE header conflict) — do not apt-install it.
    if compgen -G "/usr/local/cuda*/bin/nvcc" >/dev/null 2>&1; then
      success "CUDA toolkit (nvcc) found under /usr/local/cuda*."
    else
      error "NVIDIA backend needs a CUDA toolkit (nvcc under /usr/local/cuda) but none was found."
      error "Install it from https://developer.nvidia.com/cuda-downloads (the apt nvidia-cuda-toolkit is broken on aarch64), or set OMNIVOICE_BACKEND=cpu."
    fi
    ;;
  cpu)
    sudo apt-get install -y libopenblas-dev
    success "CPU build dependencies installed (OpenBLAS)."
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# ENSURE SERVICE USER
# ─────────────────────────────────────────────────────────────────────────────

step "Ensuring service user '${OMNIVOICE_USER}'"
if ! id -u "${OMNIVOICE_USER}" &>/dev/null; then
  sudo useradd -r -s /usr/sbin/nologin "${OMNIVOICE_USER}"
  success "Created system user '${OMNIVOICE_USER}'."
else
  info "User '${OMNIVOICE_USER}' already exists."
fi
# GPU access for Vulkan (/dev/dri): render + video. No-op when a group is absent.
for _grp in render video; do
  if getent group "${_grp}" &>/dev/null; then
    sudo usermod -aG "${_grp}" "${OMNIVOICE_USER}" 2>/dev/null || true
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# ENSURE DIRECTORY LAYOUT
# ─────────────────────────────────────────────────────────────────────────────

step "Ensuring directory layout under ${OMNIVOICE_HOME}"
sudo mkdir -p "${OMNIVOICE_MODEL_DIR}" "${OMNIVOICE_HOME}/src"
# The clone, build and model download run as the invoking user (unprivileged);
# the models dir is handed to the service user after the download completes.
sudo chown "$(id -un)" "${OMNIVOICE_MODEL_DIR}" "${OMNIVOICE_HOME}/src"

# ─────────────────────────────────────────────────────────────────────────────
# CLONE / UPDATE SOURCE
# ─────────────────────────────────────────────────────────────────────────────

step "Fetching OmniVoice.cpp source (ref: ${OMNIVOICE_REF})"
# sudo-created dir: register as a safe.directory so git does not refuse to read
# it (idempotent — never add the same entry twice to ~/.gitconfig).
_existing_safe_dirs="$(git config --global --get-all safe.directory 2>/dev/null || true)"
if [[ "${_existing_safe_dirs}" != *"${OMNIVOICE_SRC}"* ]]; then
  git config --global --add safe.directory "${OMNIVOICE_SRC}" 2>/dev/null || true
fi
if [[ -d "${OMNIVOICE_SRC}/.git" ]]; then
  info "Existing repo at ${OMNIVOICE_SRC} — fetching and checking out ${OMNIVOICE_REF}…"
  git -C "${OMNIVOICE_SRC}" fetch --tags --force
  git -C "${OMNIVOICE_SRC}" checkout "${OMNIVOICE_REF}" \
    || git -C "${OMNIVOICE_SRC}" checkout -B "${OMNIVOICE_REF}" "origin/${OMNIVOICE_REF}" \
    || error "OMNIVOICE_REF '${OMNIVOICE_REF}' not found in ${OMNIVOICE_SRC} — list refs with: git -C ${OMNIVOICE_SRC} ls-remote --tags origin"
  git -C "${OMNIVOICE_SRC}" submodule update --init --recursive
else
  info "Cloning into ${OMNIVOICE_SRC} at ${OMNIVOICE_REF} (ggml is a submodule)…"
  git clone --recurse-submodules --branch "${OMNIVOICE_REF}" \
    "${OMNIVOICE_REPO_URL}" "${OMNIVOICE_SRC}"
fi
success "Source ready at ${OMNIVOICE_SRC}."

# ─────────────────────────────────────────────────────────────────────────────
# BUILD
# ─────────────────────────────────────────────────────────────────────────────

# Rebuild only when the binary is missing, the recorded ref|backend differs, or
# --force. The backend build scripts wipe build/ and re-run cmake from scratch,
# so the expensive step is skipped entirely when the marker matches.
MARKER="${OMNIVOICE_REF}|${BACKEND}"
need_build=0
if [[ ! -x "${OMNIVOICE_BUILD_BIN}" ]]; then
  info "No built binary — a build is required."
  need_build=1
elif [[ ! -f "${BUILD_MARKER}" || "$(cat "${BUILD_MARKER}" 2>/dev/null || true)" != "${MARKER}" ]]; then
  info "Build marker differs (want '${MARKER}') — rebuilding."
  need_build=1
elif [[ "${FORCE}" -eq 1 ]]; then
  info "--force set — rebuilding."
  need_build=1
fi

if [[ "${need_build}" -eq 1 ]]; then
  # The upstream build scripts parallelise with their own -j $(nproc).
  step "Building tts-server (backend: ${BACKEND})"
  cd "${OMNIVOICE_SRC}"
  case "${BACKEND}" in
    vulkan) bash ./buildvulkan.sh ;;
    cuda)   bash ./buildcuda.sh   ;;
    cpu)    bash ./buildcpu.sh    ;;
  esac
  if [[ ! -x "${OMNIVOICE_BUILD_BIN}" ]]; then
    error "Build finished but ${OMNIVOICE_BUILD_BIN} is missing — check the build output above."
  fi
  printf '%s\n' "${MARKER}" > "${BUILD_MARKER}"
  success "Build complete: ${OMNIVOICE_BUILD_BIN}"
else
  info "Built binary up to date (marker: ${MARKER}) — skipping build."
fi

step "Installing binary to ${OMNIVOICE_BIN_PATH}"
sudo install -m 755 "${OMNIVOICE_BUILD_BIN}" "${OMNIVOICE_BIN_PATH}"
success "Binary installed at ${OMNIVOICE_BIN_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# DOWNLOAD MODELS
# ─────────────────────────────────────────────────────────────────────────────

step "Downloading models from ${OMNIVOICE_HF_REPO}"
for _model in "${OMNIVOICE_BASE_MODEL}" "${OMNIVOICE_TOKENIZER_MODEL}"; do
  if [[ -f "${OMNIVOICE_MODEL_DIR}/${_model}" ]]; then
    info "Model already present, skipping: ${_model}"
  else
    info "Downloading ${_model}…"
    hf download "${OMNIVOICE_HF_REPO}" "${_model}" --local-dir "${OMNIVOICE_MODEL_DIR}"
  fi
  if [[ ! -f "${OMNIVOICE_MODEL_DIR}/${_model}" ]]; then
    error "Model download failed: ${OMNIVOICE_MODEL_DIR}/${_model} is not present after the download."
  fi
done
# The service user reads the GGUFs.
sudo chown "${OMNIVOICE_USER}:${OMNIVOICE_USER}" "${OMNIVOICE_MODEL_DIR}"
success "Models ready in ${OMNIVOICE_MODEL_DIR}."

# ─────────────────────────────────────────────────────────────────────────────
# RENDER + INSTALL UNIT
# ─────────────────────────────────────────────────────────────────────────────

step "Rendering systemd unit"
# Optional server flags, composed ahead of time so the template stays a single
# clean envsubst file. Both render empty when the corresponding option is off.
OMNIVOICE_LANG_ARG=""
[[ -n "${OMNIVOICE_LANG}" ]] && OMNIVOICE_LANG_ARG=" --lang ${OMNIVOICE_LANG}"
OMNIVOICE_EXTRA_FLAGS=""
[[ "${OMNIVOICE_NO_FA}" == "true" ]] && OMNIVOICE_EXTRA_FLAGS="${OMNIVOICE_EXTRA_FLAGS} --no-fa"
[[ "${OMNIVOICE_CLAMP_FP16}" == "true" ]] && OMNIVOICE_EXTRA_FLAGS="${OMNIVOICE_EXTRA_FLAGS} --clamp-fp16"

# Render into a temp file as the invoking user, then install with sudo
# (never `sudo envsubst` — envsubst reads the environment of the rendering user).
export OMNIVOICE_USER OMNIVOICE_HOME OMNIVOICE_BASE_MODEL OMNIVOICE_TOKENIZER_MODEL \
       OMNIVOICE_HOST OMNIVOICE_PORT OMNIVOICE_LANG_ARG OMNIVOICE_EXTRA_FLAGS
UNIT_TMP="$(mktempfile omnivoice.service)"
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${OMNIVOICE_USER} ${OMNIVOICE_HOME} ${OMNIVOICE_BASE_MODEL} ${OMNIVOICE_TOKENIZER_MODEL} ${OMNIVOICE_HOST} ${OMNIVOICE_PORT} ${OMNIVOICE_LANG_ARG} ${OMNIVOICE_EXTRA_FLAGS}' \
  < "${TEMPLATE_DIR}/omnivoice.service" > "${UNIT_TMP}"

# Converge: the unit is "changed" when it is new or its content differs; --force
# always re-applies. (cmp -s exits non-zero when the files differ.)
unit_changed=0
if [[ ! -f "${SERVICE_FILE}" ]]; then
  unit_changed=1
elif ! cmp -s "${UNIT_TMP}" "${SERVICE_FILE}"; then
  unit_changed=1
fi
[[ "${FORCE}" -eq 1 ]] && unit_changed=1

if [[ "${unit_changed}" -eq 1 ]]; then
  step "Installing unit to ${SERVICE_FILE}"
  sudo install -m 644 "${UNIT_TMP}" "${SERVICE_FILE}"
  sudo systemctl daemon-reload
  # This run now owns the unit: a later failure may stop/disable it.
  SERVICE_TOUCHED_THIS_RUN=1
  sudo systemctl enable omnivoice
  if sudo systemctl is-active omnivoice &>/dev/null; then
    sudo systemctl restart omnivoice
  else
    sudo systemctl start omnivoice
  fi
  success "Service installed, enabled and (re)started."
else
  info "Unit unchanged."
  if sudo systemctl is-active omnivoice &>/dev/null; then
    info "Service already running — not restarting a healthy service."
  else
    SERVICE_TOUCHED_THIS_RUN=1
    sudo systemctl enable omnivoice
    sudo systemctl start omnivoice
    success "Service started."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# HEALTH GATE
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for omnivoice to answer GET /health (timeout: ${OMNIVOICE_HEALTH_TIMEOUT}s)"
HEALTH_URL="http://127.0.0.1:${OMNIVOICE_PORT}/health"
ELAPSED=0
READY=false
while [[ "${ELAPSED}" -lt "${OMNIVOICE_HEALTH_TIMEOUT}" ]]; do
  # curl prints 000 via -w on connection failure; only default it when empty.
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${HEALTH_URL}" 2>/dev/null || true)"
  [[ -n "${HTTP_CODE}" ]] || HTTP_CODE="000"
  if [[ "${HTTP_CODE}" == "200" ]]; then
    READY=true
    break
  fi
  echo -ne "\r    waited ${ELAPSED}s / ${OMNIVOICE_HEALTH_TIMEOUT}s … (HTTP ${HTTP_CODE})   "
  sleep 5
  ELAPSED=$(( ELAPSED + 5 ))
done
echo ""

if [[ "${READY}" != "true" ]]; then
  warn "omnivoice did not answer /health within ${OMNIVOICE_HEALTH_TIMEOUT}s."
  warn "Check:  systemctl status omnivoice"
  warn "        journalctl -u omnivoice -n 50 --no-pager"
  error "omnivoice did not answer ${HEALTH_URL} — see the journal for the cause."
fi
success "omnivoice is up and answering /health."
SERVICE_TOUCHED_THIS_RUN=0   # proven healthy — a later failure must not stop it

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${OMNIVOICE_HOST}" != "127.0.0.1" ]]; then
  ufw_firewall_section "omnivoice" "${OMNIVOICE_PORT}" tcp "omnivoice-tts"
else
  info "Bound to loopback (127.0.0.1) — no UFW rule required."
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  OmniVoice TTS server setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Speech endpoint${RESET}   http://${OMNIVOICE_HOST}:${OMNIVOICE_PORT}/v1/audio/speech"
echo -e "  ${BOLD}List models${RESET}       http://${OMNIVOICE_HOST}:${OMNIVOICE_PORT}/v1/models"
echo -e "  ${BOLD}Health${RESET}            http://${OMNIVOICE_HOST}:${OMNIVOICE_PORT}/health"
echo -e "  ${BOLD}Bind${RESET}              ${OMNIVOICE_HOST}:${OMNIVOICE_PORT}"
echo -e "  ${BOLD}Backend${RESET}           ${BACKEND^^}"
echo -e "  ${BOLD}Runtime user${RESET}      ${OMNIVOICE_USER}"
echo -e "  ${BOLD}Binary${RESET}            ${OMNIVOICE_BIN_PATH}"
echo -e "  ${BOLD}Unit${RESET}              ${SERVICE_FILE}"
echo -e "  ${BOLD}Models${RESET}            ${OMNIVOICE_MODEL_DIR}"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Start:    sudo systemctl start omnivoice"
echo -e "  Stop:     sudo systemctl stop omnivoice"
echo -e "  Restart:  sudo systemctl restart omnivoice"
echo -e "  Status:   sudo systemctl status omnivoice"
echo -e "  Logs:     sudo journalctl -u omnivoice -f"
echo -e "  Check:    $0 --check"
echo ""
echo -e "${YELLOW}  Notes:${RESET}"
echo -e "  • Voices are in-memory only — they are wiped on restart and must be"
echo -e "    re-registered (POST /v1/audio/voices) after each (re)start."
echo -e "  • The server has no TLS/auth. For anything beyond the LAN, front it"
echo -e "    with Traefik (TLS) using the host-services file provider — see"
echo -e "    /opt/traefik/dynamic/host-services.yml.example."
echo ""
