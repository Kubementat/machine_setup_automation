#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-comfyui.sh — ComfyUI as a systemd service (tuned for DGX Spark / GB10)
# =============================================================================
#
# DESCRIPTION:
#   Installs ComfyUI from a pinned release tag into a uv-managed venv and runs
#   it either as its own systemd service (COMFYUI_SUPERVISOR=systemd, default)
#   or as the model comfyui_auto behind llama-swap (COMFYUI_SUPERVISOR=
#   llama-swap), where opening /comfyui/ starts it and requesting any other
#   model stops it. The script's main job is to encode a known-good
#   combination of versions and flags for NVIDIA DGX Spark (GB10, sm_121,
#   aarch64) so it does not have to be rediscovered on the next machine.
#
#   Other hardware is not rejected: an NVIDIA GPU that is not a GB10 takes the
#   generic path (no optional native builds), a machine without an NVIDIA GPU
#   gets CPU wheels and runs ComfyUI with --cpu. Use --check to see the path.
#
# THE INSTALL HAZARD THIS SCRIPT EXISTS FOR:
#   ComfyUI's requirements.txt lists torch, torchvision and torchaudio without
#   a version. Installing it after the CUDA wheels, without a constraint, lets
#   the resolver replace them with builds from the default index — a silently
#   CPU-only or broken install. So the torch stack is installed from the
#   PyTorch index first, frozen into a constraints file, and every later
#   install runs with --constraint. The verify step then checks
#   torch.version.cuda and runs a real CUDA matmul.
#
# KEY ACTIONS:
#   1. Pre-flight checks: platform path, uv, git, curl, envsubst, systemd
#   2. Clones ComfyUI and checks out COMFYUI_REF (a release tag)
#   3. Creates the venv and installs torch/torchvision/torchaudio from the
#      PyTorch index, then writes the constraints file
#   4. Installs requirements.txt (incl. the pinned comfy-aimdo) and, on NVIDIA
#      platforms, onnxruntime-gpu — all under the constraints
#   5. Cleans up conflicting OpenCV variants left behind by custom nodes
#   6. Optionally builds SageAttention from source (GB10 only, opt-in)
#   7. Verifies the install and records the resolved versions
#   8. Renders the launcher, then per supervisor:
#      systemd    — renders comfyui.service and converges its state
#      llama-swap — writes a validated config fragment and unit limits for
#                   llama-swap, restarts it only when those change, and unloads
#                   an outdated ComfyUI instead of restarting llama-swap
#
# IMPORTANT VARIABLES:
#   COMFYUI_DIR                   - Service directory (default: /srv/comfyui)
#   COMFYUI_REF                   - ComfyUI release tag (default: v0.35.0)
#   COMFYUI_SUPERVISOR            - systemd | llama-swap (default: systemd)
#   COMFYUI_USER                  - User the service runs as (default: invoking user)
#   COMFYUI_LISTEN                - Bind address (default: 127.0.0.1 — ComfyUI has no auth)
#   COMFYUI_PORT                  - Listen port (default: 8188)
#   COMFYUI_AUTOSTART             - Enable the service at boot (default: false)
#   COMFYUI_SAGE_BUILD            - Build SageAttention from source (default: false)
#   (see --help for the complete list)
#
# DEPENDENCIES:
#   - uv:        venv and package management (installed by setup-basics.sh)
#   - git, curl: checkout and health checks
#   - envsubst:  template rendering (package: gettext-base)
#   - systemctl: service management
#   - apt-get:   ffmpeg (optional)
#   - llama-swap v249+ with --config-dir, and setpriv (llama-swap mode only)
#
# OUTPUTS:
#   - ${COMFYUI_DIR}/ComfyUI/            - ComfyUI checkout (models, custom_nodes, output)
#   - ${COMFYUI_DIR}/.venv/              - Python environment
#   - ${COMFYUI_DIR}/bin/comfyui-launch  - Launcher with the configured flags
#   - ${COMFYUI_DIR}/state/              - constraints.txt, install-manifest
#   - /etc/systemd/system/comfyui.service             (systemd mode)
#   - <llama-swap --config-dir>/50-comfyui.yaml         (llama-swap mode)
#   - /etc/systemd/system/llama-swap.service.d/50-comfyui.conf (llama-swap mode)
#
# USAGE:
#   ./setup-comfyui.sh                          # install / converge
#   ./setup-comfyui.sh --check                  # verify, change nothing
#   COMFYUI_AUTOSTART=true ./setup-comfyui.sh   # also start at boot
#   COMFYUI_SUPERVISOR=llama-swap ./setup-comfyui.sh   # run behind llama-swap
#   ./setup-comfyui.sh --force                  # rebuild the venv from scratch
#   ./setup-comfyui.sh --help
#
# REFERENCE:
#   https://github.com/Comfy-Org/ComfyUI
#   https://build.nvidia.com/spark/comfyui
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/comfyui")"

# shellcheck source=lib/helpers.sh
# shellcheck disable=SC1091
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

COMFYUI_DIR="${COMFYUI_DIR:-/srv/comfyui}"
COMFYUI_REF="${COMFYUI_REF:-v0.35.0}"
COMFYUI_REPO_URL="${COMFYUI_REPO_URL:-https://github.com/Comfy-Org/ComfyUI.git}"
COMFYUI_SUPERVISOR="${COMFYUI_SUPERVISOR:-systemd}"
COMFYUI_USER="${COMFYUI_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
COMFYUI_LISTEN="${COMFYUI_LISTEN:-127.0.0.1}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_MODELS_DIR="${COMFYUI_MODELS_DIR:-${COMFYUI_DIR}/ComfyUI/models}"
COMFYUI_AUTOSTART="${COMFYUI_AUTOSTART:-false}"
COMFYUI_PYTHON="${COMFYUI_PYTHON:-3.12}"
COMFYUI_TORCH_INDEX_URL="${COMFYUI_TORCH_INDEX_URL:-}"   # default depends on platform
COMFYUI_INSTALL_FFMPEG="${COMFYUI_INSTALL_FFMPEG:-true}"
COMFYUI_RESERVE_VRAM="${COMFYUI_RESERVE_VRAM:-8}"
COMFYUI_DISABLE_PINNED_MEMORY="${COMFYUI_DISABLE_PINNED_MEMORY:-false}"
COMFYUI_EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:-}"
COMFYUI_SAGE_BUILD="${COMFYUI_SAGE_BUILD:-false}"
# SageAttention main at a commit that contains c03f15fb (sm_121 support restored).
COMFYUI_SAGE_REF="${COMFYUI_SAGE_REF:-d1a57a546c3d395b1ffcbeecc66d81db76f3b4b5}"
COMFYUI_SAGE_BUILD_JOBS="${COMFYUI_SAGE_BUILD_JOBS:-4}"
COMFYUI_WAIT_TIMEOUT="${COMFYUI_WAIT_TIMEOUT:-180}"
FORCE="${FORCE:-0}"
INTERACTIVE="${INTERACTIVE:-false}"

SAGE_REPO_URL="https://github.com/thu-ml/SageAttention.git"
TORCH_INDEX_CUDA="https://download.pytorch.org/whl/cu130"
TORCH_INDEX_CPU="https://download.pytorch.org/whl/cpu"
SERVICE_NAME="comfyui"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MANAGED_MARKER="Managed by tasks/setup-comfyui.sh"
OPENCV_VARIANTS=(opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless)

# llama-swap mode. Paths and user are read from the installed llama-swap unit
# (run-setup.sh gives each task only its own env), see read_llama_swap_unit.
LLAMA_SWAP_SERVICE="llama-swap"
LLAMA_SWAP_MIN_VERSION=249   # first release with the /comfyui/ endpoint
LLAMA_SWAP_MODEL_ID="comfyui_auto"
LLAMA_SWAP_DROPIN="/etc/systemd/system/${LLAMA_SWAP_SERVICE}.service.d/50-comfyui.conf"
FRAGMENT_NAME="50-comfyui.yaml"

CHECK_ONLY=0

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs ComfyUI from a pinned release tag into a uv venv and runs it either
as its own systemd service or behind llama-swap. Tuned for NVIDIA DGX Spark
(GB10); other hardware takes a generic path (NVIDIA GPU) or a CPU path.

${BOLD}Options:${RESET}
  --check        Verify the installation and service, change nothing;
                 exits non-zero if anything is wrong
  --force        Rebuild the venv from scratch and restart / unload ComfyUI
  --interactive  Ask before restarting ComfyUI or llama-swap, or unloading
                 ComfyUI (either kills the job ComfyUI is working on)
  -h, --help     Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  COMFYUI_SUPERVISOR             Who runs ComfyUI (default: systemd)
                                   systemd     own comfyui.service
                                   llama-swap  model comfyui_auto behind llama-swap
                                               (v249+, installed by setup-llama-swap.sh):
                                               http://<host>:<llama-swap port>/comfyui/
                                               starts it, any other model stops it.
                                               Ignores COMFYUI_LISTEN, COMFYUI_PORT and
                                               COMFYUI_AUTOSTART; switching back cleans up.
  COMFYUI_DIR                    Service directory (default: /srv/comfyui)
  COMFYUI_REF                    ComfyUI release tag to check out (default: v0.35.0)
                                 Upgrades are an explicit change of this value.
  COMFYUI_REPO_URL               ComfyUI git remote (default: https://github.com/Comfy-Org/ComfyUI.git)
  COMFYUI_USER                   User the service runs as (default: invoking user)
  COMFYUI_LISTEN                 Bind address (default: 127.0.0.1)
                                 ComfyUI has no authentication — do not expose it
                                 without an authenticating proxy in front.
  COMFYUI_PORT                   Listen port (default: 8188)
  COMFYUI_MODELS_DIR             Model directory (default: \${COMFYUI_DIR}/ComfyUI/models)
                                 Anything else gets an extra_model_paths.yaml.
  COMFYUI_AUTOSTART              Enable the service at boot (default: false)
                                 ComfyUI next to a loaded LLM can exhaust unified
                                 memory — keep this off unless workloads are sized.
  COMFYUI_PYTHON                 Python version for the venv (default: 3.12)
  COMFYUI_TORCH_INDEX_URL        PyTorch wheel index (default: ${TORCH_INDEX_CUDA}
                                 with an NVIDIA GPU, ${TORCH_INDEX_CPU} without)
  COMFYUI_INSTALL_FFMPEG         Install ffmpeg via apt (default: true)
  COMFYUI_RESERVE_VRAM           --reserve-vram in GB (default: 8)
  COMFYUI_DISABLE_PINNED_MEMORY  Pass --disable-pinned-memory (default: false)
  COMFYUI_EXTRA_ARGS             Extra ComfyUI arguments, appended verbatim
                                 (e.g. "--bf16-unet --bf16-vae --bf16-text-enc")
  COMFYUI_SAGE_BUILD             Build SageAttention from source, GB10 only (default: false)
                                 Rebuilt automatically when torch changes.
  COMFYUI_SAGE_REF               SageAttention commit SHA (default: ${COMFYUI_SAGE_REF:0:12})
  COMFYUI_SAGE_BUILD_JOBS        Parallel compile jobs for SageAttention (default: 4)
  COMFYUI_WAIT_TIMEOUT           Seconds to wait for ComfyUI / llama-swap to answer (default: 180)
  FORCE                          Same as --force (default: 0)
  INTERACTIVE                    Same as --interactive (default: false)

${BOLD}Examples:${RESET}
  ./setup-comfyui.sh
  ./setup-comfyui.sh --check
  COMFYUI_AUTOSTART=true ./setup-comfyui.sh
  COMFYUI_SUPERVISOR=llama-swap ./setup-comfyui.sh
  COMFYUI_REF=v0.36.0 ./setup-comfyui.sh          # upgrade ComfyUI
  COMFYUI_SAGE_BUILD=true ./setup-comfyui.sh      # add SageAttention
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)       CHECK_ONLY=1 ;;
    --force)       FORCE=1 ;;
    --interactive) INTERACTIVE=true ;;
    -h|--help)     usage; exit 0 ;;
    *)             error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

is_true() { [[ "$1" == "true" || "$1" == "1" || "$1" == "yes" ]]; }

# Runs a command as COMFYUI_USER, who owns everything below COMFYUI_DIR.
as_comfy() {
  if [[ "$(id -un)" == "$COMFYUI_USER" ]]; then
    "$@"
  else
    sudo -u "$COMFYUI_USER" -H -- "$@"
  fi
}

# Every package operation targets the service venv explicitly.
uv_pip() { as_comfy "$UV" pip "$1" --python "$VENV_PY" "${@:2}"; }

# Sets PLATFORM (gb10 | nvidia | cpu) and GPU_NAME.
detect_platform() {
  GPU_NAME=""
  if command -v nvidia-smi &>/dev/null; then
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$GPU_NAME" ]]; then
    PLATFORM="cpu"
  elif [[ "$(uname -m)" == "aarch64" && "$GPU_NAME" == *GB10* ]]; then
    PLATFORM="gb10"
  else
    PLATFORM="nvidia"
  fi
}

# Prints the CUDA version a wheel index serves ("13.0" for .../cu130), or
# nothing for a CPU index. Used to detect replaced torch wheels.
#   index_cuda_version [index-url]   (default: COMFYUI_TORCH_INDEX_URL)
index_cuda_version() {
  local tag="${1:-$COMFYUI_TORCH_INDEX_URL}"
  tag="${tag%/}"
  tag="${tag##*/}"
  if [[ "$tag" =~ ^cu([0-9]+)([0-9])$ ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi
}

# Finds a uv binary COMFYUI_USER can run: their own install first (sudo does
# not carry the user's PATH), then whatever is on PATH.
resolve_uv() {
  local home candidate
  home="$(getent passwd "$COMFYUI_USER" | cut -d: -f6)"
  for candidate in "${home}/.local/bin/uv" "$(command -v uv || true)"; do
    if [[ -n "$candidate" ]] && as_comfy test -x "$candidate" 2>/dev/null; then
      UV="$candidate"
      return 0
    fi
  done
  return 1
}

# Renders a template with an explicit variable list and installs it when the
# result differs from what is on disk. Returns 0 when the file changed.
#   render_install <template> <dest> <mode> <owner:group> <envsubst-vars>
render_install() {
  local template="$1" dest="$2" mode="$3" owner="$4" vars="$5" rendered
  rendered="$(mktempfile "$(basename "$dest")")"
  envsubst "$vars" < "$template" > "$rendered"
  if [[ -f "$dest" ]] && cmp -s "$rendered" "$dest" && ! is_true "$FORCE"; then
    rm -f "$rendered"
    return 1
  fi
  sudo install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$rendered" "$dest"
  rm -f "$rendered"
  return 0
}

# Runs the post-install verification inside the venv. Prints INFO/FAIL/VER
# lines; exits non-zero when any check failed.
run_verify() {
  local expect_cuda require_gpu expect_cap check_ort
  expect_cuda="$(index_cuda_version "$VERIFY_INDEX")"
  require_gpu=0; expect_cap=""; check_ort=0
  if [[ "$PLATFORM" != "cpu" ]]; then require_gpu=1; check_ort=1; fi
  if [[ "$PLATFORM" == "gb10" ]]; then expect_cap="12.1"; fi

  EXPECT_CUDA="$expect_cuda" REQUIRE_GPU="$require_gpu" EXPECT_CAP="$expect_cap" \
  CHECK_ORT="$check_ort" OPENCV_VARIANTS="${OPENCV_VARIANTS[*]}" \
    "$VENV_PY" - <<'PY'
import importlib
import importlib.metadata as md
import os
import sys

failed = False

def report(kind, msg):
    global failed
    failed = failed or kind == "FAIL"
    print(f"{kind} {msg}", flush=True)

def version(name):
    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return None

import torch

expect_cuda = os.environ["EXPECT_CUDA"] or None
report("INFO", f"torch {torch.__version__} — CUDA build {torch.version.cuda}")
if torch.version.cuda != expect_cuda:
    report("FAIL", f"torch.version.cuda is {torch.version.cuda}, expected {expect_cuda} — "
                   "the torch wheels from the index were replaced")

if os.environ["REQUIRE_GPU"] == "1":
    if not torch.cuda.is_available():
        report("FAIL", "torch.cuda.is_available() is False")
    else:
        cap = "%d.%d" % torch.cuda.get_device_capability()
        report("INFO", f"GPU {torch.cuda.get_device_name(0)} — compute capability {cap}")
        if os.environ["EXPECT_CAP"] and cap != os.environ["EXPECT_CAP"]:
            report("FAIL", f"compute capability {cap}, expected {os.environ['EXPECT_CAP']}")
        # is_available() alone does not prove kernels run on this architecture.
        a = torch.randn(512, 512, device="cuda")
        torch.cuda.synchronize()
        if not torch.isfinite((a @ a).sum()).item():
            report("FAIL", "CUDA matmul produced a non-finite result")
        else:
            report("INFO", "CUDA matmul OK")
        free, total = torch.cuda.mem_get_info()
        report("INFO", f"GPU memory {free / 2**30:.1f} GiB free of {total / 2**30:.1f} GiB")

for module in ("torchaudio", "comfy_aimdo"):
    try:
        importlib.import_module(module)
    except Exception as exc:  # noqa: BLE001 — any import failure is a finding
        report("FAIL", f"import {module} failed: {exc}")

if os.environ["CHECK_ORT"] == "1":
    try:
        import onnxruntime
        if "CUDAExecutionProvider" in onnxruntime.get_available_providers():
            report("INFO", "onnxruntime CUDAExecutionProvider available")
        else:
            report("FAIL", "onnxruntime has no CUDAExecutionProvider")
    except Exception as exc:  # noqa: BLE001
        report("FAIL", f"import onnxruntime failed: {exc}")

opencv = [n for n in os.environ["OPENCV_VARIANTS"].split() if version(n)]
if len(opencv) > 1:
    report("FAIL", f"several OpenCV variants installed ({', '.join(opencv)}) — "
                   "they overwrite each other's cv2/ directory")

for name in ("torch", "torchvision", "torchaudio", "comfy-aimdo",
             "onnxruntime-gpu", "sageattention"):
    if version(name):
        print(f"VER {name}={version(name)}")

sys.exit(1 if failed else 0)
PY
}

# Consumes run_verify output: logs INFO/FAIL lines, collects VER lines into
# VERIFY_VERSIONS. Returns the verification exit code.
verify_install() {
  local out rc=0 line
  VERIFY_VERSIONS=""
  out="$(run_verify 2>&1)" || rc=$?
  while IFS= read -r line; do
    case "$line" in
      "INFO "*) info "${line#INFO }" ;;
      "FAIL "*) warn "${line#FAIL }" ;;
      "VER "*)  VERIFY_VERSIONS+="${line#VER }"$'\n' ;;
      *)        [[ -n "$line" ]] && echo "    $line" ;;
    esac
  done <<< "$out"
  return "$rc"
}

# True when every _qattn_sm*.so in the venv carries sm_121 SASS.
sage_has_sm121() {
  local so cuobjdump found=0
  cuobjdump="$(command -v cuobjdump || echo "${CUDA_HOME:-/usr/local/cuda}/bin/cuobjdump")"
  [[ -x "$cuobjdump" ]] || return 1
  while IFS= read -r so; do
    found=1
    "$cuobjdump" --list-elf "$so" 2>/dev/null | grep -q 'sm_121' || return 1
  done < <(find "$VENV_DIR" -name '_qattn_sm*.so' 2>/dev/null)
  [[ $found -eq 1 ]]
}

# Reads one key from the install manifest.
manifest_get() {
  [[ -f "$MANIFEST" ]] || return 0
  sed -n "s/^$1=//p" "$MANIFEST" | head -1
}

# True when any of the given files is newer than <epoch>.
#   inputs_newer_than <epoch> <file...>
inputs_newer_than() {
  local started="$1" file
  for file in "${@:2}"; do
    if [[ -f "$file" ]] && (( $(stat -c %Y "$file") > started )); then
      return 0
    fi
  done
  return 1
}

# Start time of an active systemd unit as epoch seconds; fails when inactive.
unit_started_epoch() {
  local started
  started="$(systemctl show -p ActiveEnterTimestamp --value "$1" 2>/dev/null)"
  [[ -n "$started" ]] || return 1
  date -d "$started" +%s
}

# True when the running service predates one of its runtime inputs — also
# catches a change from an earlier run whose restart was declined.
restart_pending() {
  local started
  started="$(unit_started_epoch "$SERVICE_NAME")" || return 1
  inputs_newer_than "$started" "$LAUNCHER" "$SERVICE_FILE" "$MANIFEST" "$EXTRA_PATHS"
}

# PID of a running ComfyUI (under either supervisor); empty when none.
comfyui_pid() {
  pgrep -o -f "^${VENV_PY} main.py" 2>/dev/null || true
}

# True when the ComfyUI process <pid> started before its launcher, manifest or
# model paths last changed.
comfyui_outdated() {
  local elapsed
  elapsed="$(ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ -n "$elapsed" ]] || return 1
  inputs_newer_than "$(( $(date +%s) - elapsed ))" "$LAUNCHER" "$MANIFEST" "$EXTRA_PATHS"
}

# Parses the installed llama-swap unit into LS_BIN, LS_CONFIG, LS_FRAGMENT_DIR,
# LS_USER and LS_URL. run-setup.sh passes each task only its own env, so the
# unit written by setup-llama-swap.sh is the one source of truth.
read_llama_swap_unit() {
  local argv listen="" host port i arg
  local -a args
  LS_BIN=""; LS_CONFIG=""; LS_FRAGMENT_DIR=""; LS_USER=""; LS_URL=""
  if [[ "$(systemctl show -p LoadState --value "$LLAMA_SWAP_SERVICE" 2>/dev/null)" != "loaded" ]]; then
    err_msg "llama-swap is not installed as a systemd service — run setup-llama-swap.sh first"
    return 1
  fi
  argv="$(systemctl show -p ExecStart --value "$LLAMA_SWAP_SERVICE" | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p')"
  read -ra args <<< "$argv"
  LS_BIN="${args[0]:-}"
  for (( i = 1; i < ${#args[@]}; i++ )); do
    arg="${args[i]}"
    case "$arg" in
      -config=*|--config=*)         LS_CONFIG="${arg#*=}" ;;
      -config|--config)             LS_CONFIG="${args[++i]:-}" ;;
      -config-dir=*|--config-dir=*) LS_FRAGMENT_DIR="${arg#*=}" ;;
      -config-dir|--config-dir)     LS_FRAGMENT_DIR="${args[++i]:-}" ;;
      -listen=*|--listen=*)         listen="${arg#*=}" ;;
      -listen|--listen)             listen="${args[++i]:-}" ;;
    esac
  done
  if [[ -z "$LS_BIN" || ! -x "$LS_BIN" ]]; then
    err_msg "Cannot find the llama-swap binary in the unit's ExecStart (${argv:-empty})"
    return 1
  fi
  LS_USER="$(systemctl show -p User --value "$LLAMA_SWAP_SERVICE" 2>/dev/null)"
  LS_USER="${LS_USER:-root}"
  listen="${listen:-:8080}"   # llama-swap's own default
  host="${listen%:*}"
  port="${listen##*:}"
  if [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "[::]" ]]; then host="127.0.0.1"; fi
  LS_URL="http://${host}:${port}"
}

# read_llama_swap_unit plus everything the llama-swap mode requires. Sets LS_VERSION.
discover_llama_swap() {
  read_llama_swap_unit || return 1
  if [[ -z "$LS_FRAGMENT_DIR" ]]; then
    err_msg "llama-swap runs without --config-dir — re-run setup-llama-swap.sh to add the fragment directory"
    return 1
  fi
  LS_VERSION="$("$LS_BIN" -version 2>/dev/null | sed -nE 's/^version: v?([0-9]+).*/\1/p')"
  if [[ -z "$LS_VERSION" ]] || (( LS_VERSION < LLAMA_SWAP_MIN_VERSION )); then
    err_msg "llama-swap ${LS_VERSION:-of unknown version} is too old — /comfyui/ needs v${LLAMA_SWAP_MIN_VERSION}+ (update: setup-llama-swap.sh --force)"
    return 1
  fi
}

# Prints the cmd prefix that makes llama-swap start ComfyUI as COMFYUI_USER.
# setpriv needs root; a non-root llama-swap can only run ComfyUI as itself.
llama_swap_cmd_prefix() {
  if [[ "$LS_USER" == "$COMFYUI_USER" ]]; then
    echo ""
  elif [[ "$LS_USER" == "root" ]]; then
    echo "setpriv --reuid=${COMFYUI_USER} --regid=${COMFYUI_GROUP} --init-groups -- "
  else
    err_msg "llama-swap runs as ${LS_USER} and cannot start processes as COMFYUI_USER=${COMFYUI_USER} — run llama-swap as root or set COMFYUI_USER=${LS_USER}"
    return 1
  fi
}

# Prints the fragment for the given cmd prefix.
render_fragment() {
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  COMFYUI_CMD_PREFIX="$1" COMFYUI_DIR="$COMFYUI_DIR" \
    envsubst '${COMFYUI_CMD_PREFIX} ${COMFYUI_DIR}' < "${TEMPLATE_DIR}/llama-swap-fragment.yaml"
}

# Runs `llama-swap -validate` over config.yaml and the fragment directory. With
# a <candidate> file it stands in for our fragment, so a change is validated
# before it is installed. Prints llama-swap's verdict; returns its exit code.
validate_llama_swap() {
  local candidate="${1:-}" dir out rc=0 f
  local -a config_args=()
  dir="$(mktemp -d)"
  for f in "$LS_FRAGMENT_DIR"/*.yml "$LS_FRAGMENT_DIR"/*.yaml; do
    [[ -f "$f" ]] || continue
    if [[ -n "$candidate" && "$(basename "$f")" == "$FRAGMENT_NAME" ]]; then continue; fi
    cp "$f" "$dir/"
  done
  if [[ -n "$candidate" ]]; then cp "$candidate" "${dir}/${FRAGMENT_NAME}"; fi
  if [[ -n "$LS_CONFIG" ]]; then config_args=(-config "$LS_CONFIG"); fi
  out="$("$LS_BIN" -validate "${config_args[@]}" -config-dir "$dir" 2>&1)" || rc=$?
  rm -rf "$dir"
  printf '%s\n' "$out"
  return "$rc"
}

# Restarts llama-swap and waits for /health (unauthenticated). A restart
# unloads every model, so it happens only when llama-swap's own inputs changed.
restart_llama_swap() {
  local elapsed=0
  if ! systemctl is-active --quiet "$LLAMA_SWAP_SERVICE"; then
    info "llama-swap is not running — the change applies when it starts"
    return 0
  fi
  if is_true "$INTERACTIVE" && ! confirm "Restart llama-swap now ($1)? Every loaded model is unloaded."; then
    warn "llama-swap not restarted — apply later with: sudo systemctl restart ${LLAMA_SWAP_SERVICE}"
    return 0
  fi
  warn "Restarting llama-swap ($1) — every loaded model is unloaded"
  sudo systemctl restart "$LLAMA_SWAP_SERVICE"
  until curl -fs -o /dev/null --max-time 5 "${LS_URL}/health"; do
    if systemctl is-failed --quiet "$LLAMA_SWAP_SERVICE" || (( elapsed >= COMFYUI_WAIT_TIMEOUT )); then
      error "llama-swap did not come back — see: journalctl -u ${LLAMA_SWAP_SERVICE} -n 50"
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done
  success "llama-swap is back (${LS_URL}/health)"
}

# True when llama-swap started before the fragment or unit limits last changed
# (e.g. a restart declined in an earlier --interactive run).
llama_swap_restart_pending() {
  local started
  started="$(unit_started_epoch "$LLAMA_SWAP_SERVICE")" || return 1
  inputs_newer_than "$started" "${LS_FRAGMENT_DIR}/${FRAGMENT_NAME}" "$LLAMA_SWAP_DROPIN"
}

# Unloads the llama-swap-managed ComfyUI so its next start picks up changes.
# The unload endpoint needs llama-swap's API key when apiKeys are set, which
# this task does not hold — then the operator unloads it in the llama-swap UI.
unload_comfyui() {
  local code
  if is_true "$INTERACTIVE" && ! confirm "ComfyUI is loaded in llama-swap; unload it now (kills any running job)?"; then
    warn "Not unloaded — ComfyUI keeps running the previous state until its next start"
    return 0
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 60 \
    "${LS_URL}/api/models/unload/${LLAMA_SWAP_MODEL_ID}" || true)"
  case "$code" in
    200) info "Unloaded ${LLAMA_SWAP_MODEL_ID} — the next visit to /comfyui/ starts the new state" ;;
    401) warn "ComfyUI runs the previous state, and unloading it needs llama-swap's API key. Unload ${LLAMA_SWAP_MODEL_ID} in the llama-swap UI (${LS_URL}/ui)." ;;
    *)   warn "Could not unload ${LLAMA_SWAP_MODEL_ID} (HTTP ${code:-no answer}) — unload it in the llama-swap UI (${LS_URL}/ui)" ;;
  esac
}

# Removes what COMFYUI_SUPERVISOR=llama-swap installed (files carrying the
# managed marker only). Returns 0 when something was removed.
remove_llama_swap_integration() {
  local removed=1 fragment
  if read_llama_swap_unit 2>/dev/null && [[ -n "$LS_FRAGMENT_DIR" ]]; then
    fragment="${LS_FRAGMENT_DIR}/${FRAGMENT_NAME}"
    if [[ -f "$fragment" ]] && grep -q "$MANAGED_MARKER" "$fragment"; then
      sudo rm -f "$fragment"
      info "Removed ${fragment} (COMFYUI_SUPERVISOR=systemd)"
      removed=0
    fi
  fi
  if [[ -f "$LLAMA_SWAP_DROPIN" ]] && grep -q "$MANAGED_MARKER" "$LLAMA_SWAP_DROPIN"; then
    sudo rm -f "$LLAMA_SWAP_DROPIN"
    sudo systemctl daemon-reload
    info "Removed ${LLAMA_SWAP_DROPIN} (COMFYUI_SUPERVISOR=systemd)"
    removed=0
  fi
  return "$removed"
}

confirm() {
  local answer
  read -rp "    $1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# DERIVED VALUES
# ─────────────────────────────────────────────────────────────────────────────

APP_DIR="${COMFYUI_DIR}/ComfyUI"
VENV_DIR="${COMFYUI_DIR}/.venv"
VENV_PY="${VENV_DIR}/bin/python"
STATE_DIR="${COMFYUI_DIR}/state"
CONSTRAINTS="${STATE_DIR}/constraints.txt"
MANIFEST="${STATE_DIR}/install-manifest"
LAUNCHER="${COMFYUI_DIR}/bin/comfyui-launch"
EXTRA_PATHS="${APP_DIR}/extra_model_paths.yaml"
SAGE_SRC="${COMFYUI_DIR}/src/SageAttention"

detect_platform
if [[ -z "$COMFYUI_TORCH_INDEX_URL" ]]; then
  if [[ "$PLATFORM" == "cpu" ]]; then
    COMFYUI_TORCH_INDEX_URL="$TORCH_INDEX_CPU"
  else
    COMFYUI_TORCH_INDEX_URL="$TORCH_INDEX_CUDA"
  fi
fi

VERIFY_INDEX="$COMFYUI_TORCH_INDEX_URL"

SAGE_ENABLED=false
if is_true "$COMFYUI_SAGE_BUILD" && [[ "$PLATFORM" == "gb10" ]]; then
  SAGE_ENABLED=true
fi

# Launcher arguments. The unit and any other supervisor share this list.
LAUNCH_ARGS=(--listen "$COMFYUI_LISTEN" --port "$COMFYUI_PORT")
if [[ "$PLATFORM" == "cpu" ]]; then
  LAUNCH_ARGS+=(--cpu)
else
  LAUNCH_ARGS+=(--reserve-vram "$COMFYUI_RESERVE_VRAM")
fi
if is_true "$COMFYUI_DISABLE_PINNED_MEMORY"; then LAUNCH_ARGS+=(--disable-pinned-memory); fi
if [[ "$SAGE_ENABLED" == "true" ]]; then LAUNCH_ARGS+=(--use-sage-attention); fi
COMFYUI_LAUNCH_ARGS="${LAUNCH_ARGS[*]}${COMFYUI_EXTRA_ARGS:+ ${COMFYUI_EXTRA_ARGS}}"

# The health probe cannot connect to a wildcard address.
PROBE_HOST="$COMFYUI_LISTEN"
if [[ "$PROBE_HOST" == "0.0.0.0" || "$PROBE_HOST" == "::" ]]; then PROBE_HOST="127.0.0.1"; fi
HEALTH_URL="http://${PROBE_HOST}:${COMFYUI_PORT}/system_stats"

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

case "$PLATFORM" in
  gb10)   success "Platform: DGX Spark (${GPU_NAME}, aarch64) — sm_121 path" ;;
  nvidia) info "Platform: ${GPU_NAME} ($(uname -m)) — generic NVIDIA path, no optional native builds" ;;
  cpu)    warn "Platform: no NVIDIA GPU found — CPU path (ComfyUI runs with --cpu)" ;;
esac
info "PyTorch index: ${COMFYUI_TORCH_INDEX_URL}"
if is_true "$COMFYUI_SAGE_BUILD" && [[ "$SAGE_ENABLED" != "true" ]]; then
  warn "COMFYUI_SAGE_BUILD=true is ignored on the ${PLATFORM} path (GB10 only)"
fi

if ! [[ "$COMFYUI_PORT" =~ ^[0-9]+$ ]] || (( COMFYUI_PORT < 1 || COMFYUI_PORT > 65535 )); then
  error "COMFYUI_PORT must be a port number, got '${COMFYUI_PORT}'"
fi
[[ "$COMFYUI_RESERVE_VRAM" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || error "COMFYUI_RESERVE_VRAM must be a number of GB, got '${COMFYUI_RESERVE_VRAM}'"
[[ "$COMFYUI_WAIT_TIMEOUT" =~ ^[0-9]+$ ]] \
  || error "COMFYUI_WAIT_TIMEOUT must be a number of seconds, got '${COMFYUI_WAIT_TIMEOUT}'"
case "$COMFYUI_SUPERVISOR" in
  systemd|llama-swap) info "Supervisor: ${COMFYUI_SUPERVISOR}" ;;
  *) error "COMFYUI_SUPERVISOR must be 'systemd' or 'llama-swap', got '${COMFYUI_SUPERVISOR}'" ;;
esac

id "$COMFYUI_USER" &>/dev/null || error "COMFYUI_USER '${COMFYUI_USER}' does not exist"
COMFYUI_GROUP="$(id -gn "$COMFYUI_USER")"
if [[ "$COMFYUI_USER" == "root" ]]; then
  warn "ComfyUI will run as root — custom nodes are arbitrary Python code. Set COMFYUI_USER."
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK MODE — verify and exit
# ─────────────────────────────────────────────────────────────────────────────

if [[ $CHECK_ONLY -eq 1 ]]; then
  CHECK_FAILED=0
  check_fail() { warn "$1"; CHECK_FAILED=1; }

  step "ComfyUI status"
  echo "  Platform:   ${PLATFORM}${GPU_NAME:+ (${GPU_NAME})}"
  echo "  Directory:  ${COMFYUI_DIR}"
  echo "  User:       ${COMFYUI_USER}"

  if [[ -d "${APP_DIR}/.git" ]]; then
    current_ref="$(git -c safe.directory="$APP_DIR" -C "$APP_DIR" describe --tags --exact-match 2>/dev/null || echo 'untagged')"
    if [[ "$current_ref" == "$COMFYUI_REF" ]]; then
      success "ComfyUI checkout at ${current_ref}"
    else
      check_fail "ComfyUI checkout is at ${current_ref}, configured COMFYUI_REF is ${COMFYUI_REF}"
    fi
  else
    check_fail "No ComfyUI checkout at ${APP_DIR}"
  fi

  if [[ -x "$VENV_PY" ]]; then
    # Judge torch against the index it was installed from, so a replaced build
    # is caught however --check is invoked; a changed setting is reported apart.
    installed_index="$(manifest_get torch_index)"
    if [[ -n "$installed_index" ]]; then
      VERIFY_INDEX="$installed_index"
      if [[ "$installed_index" != "$COMFYUI_TORCH_INDEX_URL" ]]; then
        check_fail "torch was installed from ${installed_index}, configured index is ${COMFYUI_TORCH_INDEX_URL}"
      fi
    fi
    if verify_install; then
      success "Python environment verified"
    else
      check_fail "Python environment verification failed (see above)"
    fi
    if [[ "$SAGE_ENABLED" == "true" ]]; then
      if sage_has_sm121; then
        success "SageAttention kernels carry sm_121"
      else
        check_fail "SageAttention is enabled but no _qattn_sm*.so with sm_121 was found"
      fi
    fi
    if [[ -f "$MANIFEST" ]]; then
      info "Recorded install (${MANIFEST}):"
      sed 's/^/    /' "$MANIFEST"
    else
      check_fail "No install manifest at ${MANIFEST}"
    fi
  else
    check_fail "No venv at ${VENV_DIR}"
  fi

  if [[ "$COMFYUI_SUPERVISOR" == "llama-swap" ]]; then
    step "llama-swap integration"
    if ! discover_llama_swap; then
      check_fail "llama-swap integration cannot be checked (see above)"
    else
      success "llama-swap v${LS_VERSION} at ${LS_URL} (user ${LS_USER}, fragments in ${LS_FRAGMENT_DIR})"
      if [[ -f "$SERVICE_FILE" ]]; then
        check_fail "${SERVICE_FILE} is still installed — COMFYUI_SUPERVISOR=llama-swap does not use it"
      fi
      fragment="${LS_FRAGMENT_DIR}/${FRAGMENT_NAME}"
      if cmd_prefix="$(llama_swap_cmd_prefix)"; then
        if [[ ! -f "$fragment" ]]; then
          check_fail "No ComfyUI fragment at ${fragment}"
        elif [[ "$(cat "$fragment")" != "$(render_fragment "$cmd_prefix")" ]]; then
          check_fail "${fragment} is out of date"
        else
          success "Fragment up to date: ${fragment}"
        fi
      else
        check_fail "ComfyUI cannot be started by llama-swap as ${COMFYUI_USER} (see above)"
      fi
      if validation="$(validate_llama_swap)"; then
        success "llama-swap -validate: ${validation}"
      else
        check_fail "llama-swap -validate failed: ${validation}"
      fi
      if [[ -f "$LLAMA_SWAP_DROPIN" ]] && cmp -s "$LLAMA_SWAP_DROPIN" "${TEMPLATE_DIR}/llama-swap-dropin.conf"; then
        success "Unit limits up to date: ${LLAMA_SWAP_DROPIN}"
      else
        check_fail "Unit limits missing or out of date: ${LLAMA_SWAP_DROPIN}"
      fi
      if llama_swap_restart_pending; then
        check_fail "llama-swap runs an older configuration — restart pending (sudo systemctl restart ${LLAMA_SWAP_SERVICE})"
      fi
      # Never probe /comfyui/ itself: the root path would start ComfyUI.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${LS_URL}/comfyui/system_stats" || true)"
      case "$code" in
        401)     success "llama-swap requires an API key for /comfyui/" ;;
        200|409) warn "llama-swap has no apiKeys — /comfyui/ is open to everyone who reaches its port" ;;
        404)     check_fail "llama-swap does not serve ${LLAMA_SWAP_MODEL_ID} — restart llama-swap" ;;
        *)       check_fail "llama-swap did not answer /comfyui/system_stats (HTTP ${code:-no answer})" ;;
      esac
      pid="$(comfyui_pid)"
      if [[ -n "$pid" ]]; then
        owner="$(ps -o user= -p "$pid" | tr -d ' ')"
        comm="$(ps -o comm= -p "$pid")"
        parent="$(ps -o comm= -p "$(ps -o ppid= -p "$pid" | tr -d ' ')")"
        if [[ "$owner" == "$COMFYUI_USER" && "$comm" == "python" && "$parent" == "llama-swap" ]]; then
          success "ComfyUI loaded (pid ${pid}): user ${owner}, process python, parent llama-swap"
        else
          check_fail "ComfyUI loaded (pid ${pid}) as user ${owner}, process ${comm}, parent ${parent} — expected ${COMFYUI_USER}, python, llama-swap"
        fi
        if grep -qE '^Max locked memory +unlimited' "/proc/${pid}/limits" \
           && grep -qE '^Max stack size +67108864' "/proc/${pid}/limits"; then
          success "Unit limits in effect for ComfyUI"
        else
          check_fail "ComfyUI (pid ${pid}) does not run with the unit limits"
        fi
        if comfyui_outdated "$pid"; then
          check_fail "Loaded ComfyUI predates its launcher/manifest — unload ${LLAMA_SWAP_MODEL_ID} (llama-swap UI)"
        fi
      else
        info "ComfyUI is not loaded — open ${LS_URL}/comfyui/ to start it"
      fi
    fi
  elif [[ -f "$SERVICE_FILE" ]]; then
    success "Unit installed: ${SERVICE_FILE}"
    enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    if is_true "$COMFYUI_AUTOSTART" && [[ "$enabled" != "enabled" ]]; then
      check_fail "COMFYUI_AUTOSTART=true but the service is ${enabled:-not enabled}"
    elif ! is_true "$COMFYUI_AUTOSTART" && [[ "$enabled" == "enabled" ]]; then
      check_fail "COMFYUI_AUTOSTART=false but the service is enabled at boot"
    else
      success "Boot state matches COMFYUI_AUTOSTART (${enabled:-disabled})"
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      if curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL"; then
        success "Service active and answering on ${HEALTH_URL}"
      else
        check_fail "Service active but ${HEALTH_URL} does not answer"
      fi
      if restart_pending; then
        check_fail "Service runs an older configuration — restart pending (sudo systemctl restart ${SERVICE_NAME})"
      fi
    else
      info "Service is not running (start: sudo systemctl start ${SERVICE_NAME})"
    fi
  else
    check_fail "Unit not installed: ${SERVICE_FILE}"
  fi
  if [[ "$COMFYUI_SUPERVISOR" == "systemd" ]]; then
    if read_llama_swap_unit 2>/dev/null && [[ -n "$LS_FRAGMENT_DIR" && -f "${LS_FRAGMENT_DIR}/${FRAGMENT_NAME}" ]]; then
      check_fail "Leftover from llama-swap mode: ${LS_FRAGMENT_DIR}/${FRAGMENT_NAME}"
    fi
    if [[ -f "$LLAMA_SWAP_DROPIN" ]]; then
      check_fail "Leftover from llama-swap mode: ${LLAMA_SWAP_DROPIN}"
    fi
  fi

  echo ""
  if [[ $CHECK_FAILED -eq 1 ]]; then
    warn "ComfyUI check FAILED — run without --check to converge"
    exit 1
  fi
  success "All ComfyUI checks passed"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS (apply)
# ─────────────────────────────────────────────────────────────────────────────

for cmd in git curl systemctl; do
  command -v "$cmd" &>/dev/null || error "${cmd} is not installed."
done
command -v envsubst &>/dev/null || error "envsubst is not installed — install it with: sudo apt-get install gettext-base"
if [[ $EUID -ne 0 ]]; then
  command -v sudo &>/dev/null || error "sudo is required when not running as root"
fi
resolve_uv || error "uv not found for user ${COMFYUI_USER} — run setup-basics.sh first"
info "uv: ${UV}"

if [[ "$COMFYUI_SUPERVISOR" == "llama-swap" ]]; then
  # Fail before the long install, not after it.
  discover_llama_swap || error "COMFYUI_SUPERVISOR=llama-swap needs a suitable llama-swap (see above)"
  COMFYUI_CMD_PREFIX="$(llama_swap_cmd_prefix)" || error "ComfyUI cannot be started by llama-swap (see above)"
  if [[ -n "$COMFYUI_CMD_PREFIX" ]] && ! command -v setpriv &>/dev/null; then
    error "setpriv (util-linux) is required to start ComfyUI as ${COMFYUI_USER} from llama-swap"
  fi
  info "llama-swap v${LS_VERSION} at ${LS_URL} (runs as ${LS_USER}, fragments in ${LS_FRAGMENT_DIR})"
fi

if [[ "$SAGE_ENABLED" == "true" ]]; then
  # The system default on the Spark is gcc 11; SageAttention needs gcc 13.
  if ! command -v gcc-13 &>/dev/null || ! command -v g++-13 &>/dev/null; then
    error "SageAttention needs gcc-13/g++-13 — install them: sudo apt-get install gcc-13 g++-13"
  fi
  if [[ -z "${CUDA_HOME:-}" ]]; then
    if command -v nvcc &>/dev/null; then
      CUDA_HOME="$(dirname "$(dirname "$(command -v nvcc)")")"
    else
      CUDA_HOME="/usr/local/cuda"
    fi
  fi
  [[ -x "${CUDA_HOME}/bin/nvcc" ]] || error "SageAttention needs nvcc — not found at ${CUDA_HOME}/bin/nvcc (set CUDA_HOME)"
  info "SageAttention build: CUDA_HOME=${CUDA_HOME}, CC=gcc-13, ${COMFYUI_SAGE_BUILD_JOBS} jobs"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM PACKAGES
# ─────────────────────────────────────────────────────────────────────────────

if is_true "$COMFYUI_INSTALL_FFMPEG"; then
  step "Checking ffmpeg"
  if is_apt_package_installed ffmpeg; then
    success "ffmpeg already installed"
  else
    info "Installing ffmpeg (video workflows and many custom nodes need the binary)"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg
    success "ffmpeg installed"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Preparing ${COMFYUI_DIR}"

sudo install -d -m 755 -o "$COMFYUI_USER" -g "$COMFYUI_GROUP" \
  "$COMFYUI_DIR" "$STATE_DIR" "${COMFYUI_DIR}/cache" "${COMFYUI_DIR}/config" "${COMFYUI_DIR}/src"
sudo install -d -m 755 -o root -g root "${COMFYUI_DIR}/bin"
success "Directory layout ready (owner: ${COMFYUI_USER})"

# ─────────────────────────────────────────────────────────────────────────────
# COMFYUI CHECKOUT
# ─────────────────────────────────────────────────────────────────────────────

step "ComfyUI checkout (${COMFYUI_REF})"

REF_CHANGED=0
if [[ ! -e "$APP_DIR" ]]; then
  as_comfy git -c advice.detachedHead=false clone --quiet --filter=blob:none \
    --branch "$COMFYUI_REF" "$COMFYUI_REPO_URL" "$APP_DIR"
  REF_CHANGED=1
  success "Cloned ComfyUI ${COMFYUI_REF}"
elif [[ ! -d "${APP_DIR}/.git" ]]; then
  error "${APP_DIR} exists but is not a git checkout — move it away and re-run"
else
  if [[ "$(as_comfy git -C "$APP_DIR" remote get-url origin)" != "$COMFYUI_REPO_URL" ]]; then
    as_comfy git -C "$APP_DIR" remote set-url origin "$COMFYUI_REPO_URL"
    info "Remote set to ${COMFYUI_REPO_URL}"
  fi
  current_ref="$(as_comfy git -C "$APP_DIR" describe --tags --exact-match 2>/dev/null || echo 'untagged')"
  if [[ "$current_ref" == "$COMFYUI_REF" ]]; then
    success "Checkout already at ${COMFYUI_REF}"
  else
    if [[ -n "$(as_comfy git -C "$APP_DIR" status --porcelain --untracked-files=no)" ]] && ! is_true "$FORCE"; then
      as_comfy git -C "$APP_DIR" status --short --untracked-files=no | sed 's/^/    /'
      error "Tracked files in ${APP_DIR} were modified — commit/stash them or re-run with --force to discard"
    fi
    info "Switching ${current_ref} → ${COMFYUI_REF}"
    as_comfy git -C "$APP_DIR" fetch --quiet --tags --force origin
    as_comfy git -c advice.detachedHead=false -C "$APP_DIR" checkout --quiet --force "$COMFYUI_REF"
    REF_CHANGED=1
    success "Checked out ${COMFYUI_REF}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PYTHON ENVIRONMENT — torch stack first, then everything under constraints
# ─────────────────────────────────────────────────────────────────────────────

step "Python environment"

if is_true "$FORCE" && [[ -d "$VENV_DIR" ]]; then
  info "--force: removing ${VENV_DIR}"
  as_comfy rm -rf "$VENV_DIR"
fi
if [[ ! -x "$VENV_PY" ]]; then
  as_comfy "$UV" venv --quiet --python "$COMFYUI_PYTHON" --python-preference system "$VENV_DIR"
  success "Created venv (Python $("$VENV_PY" -c 'import platform; print(platform.python_version())'))"
else
  success "venv present (Python $("$VENV_PY" -c 'import platform; print(platform.python_version())'))"
fi

# Reinstall the torch stack when it is missing, came from another index, or
# no longer is the build the index serves (replaced by a later install).
TORCH_REASON=""
installed_cuda="$("$VENV_PY" -c 'import torch; print(torch.version.cuda)' 2>/dev/null || echo 'missing')"
expected_cuda="$(index_cuda_version)"
if [[ "$installed_cuda" == "missing" ]]; then
  TORCH_REASON="not installed"
elif [[ "$(manifest_get torch_index)" != "$COMFYUI_TORCH_INDEX_URL" ]]; then
  TORCH_REASON="index changed to ${COMFYUI_TORCH_INDEX_URL}"
elif [[ "$installed_cuda" != "${expected_cuda:-None}" ]]; then
  TORCH_REASON="installed build is CUDA ${installed_cuda}, index serves ${expected_cuda:-CPU}"
elif [[ ! -f "$CONSTRAINTS" ]]; then
  TORCH_REASON="constraints file missing"
fi

TORCH_CHANGED=0
if [[ -n "$TORCH_REASON" ]]; then
  info "Installing torch, torchvision, torchaudio from ${COMFYUI_TORCH_INDEX_URL} (${TORCH_REASON})"
  uv_pip install --index-url "$COMFYUI_TORCH_INDEX_URL" \
    --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
    torch torchvision torchaudio \
    || error "Installing the torch stack failed (see uv's message above). The CUDA wheels also pull from pypi.nvidia.com; network errors clear on a re-run."
  # Freeze exactly what the index delivered — including the CUDA runtime
  # wheels torch depends on — so no later install can move any of it.
  uv_pip freeze \
    | grep -E '^(torch|torchvision|torchaudio|triton|nvidia-[^=]+|cuda-[^=]+)==' \
    | as_comfy tee "$CONSTRAINTS" > /dev/null
  TORCH_CHANGED=1
  success "torch stack installed; $(wc -l < "$CONSTRAINTS" | tr -d ' ') packages pinned in ${CONSTRAINTS}"
else
  success "torch stack present (CUDA build ${installed_cuda}); constraints unchanged"
fi

info "Installing ComfyUI requirements under constraints"
uv_pip install --quiet --requirement "${APP_DIR}/requirements.txt" --constraint "$CONSTRAINTS" \
  || error "Installing ComfyUI's requirements under ${CONSTRAINTS} failed (see uv's message above)"
success "requirements.txt satisfied"

if [[ "$PLATFORM" != "cpu" ]]; then
  # Official aarch64 wheel with native sm_121 kernels; the extras pull the
  # CUDA 13 runtime and cuDNN wheels it links against.
  uv_pip install --quiet "onnxruntime-gpu[cuda,cudnn]" --constraint "$CONSTRAINTS" \
    || error "Installing onnxruntime-gpu under ${CONSTRAINTS} failed (see uv's message above)"
  success "onnxruntime-gpu satisfied"
fi

# ─────────────────────────────────────────────────────────────────────────────
# OPENCV CLEANUP — custom nodes pull in variants that overwrite each other
# ─────────────────────────────────────────────────────────────────────────────

mapfile -t installed_opencv < <(
  uv_pip list --format freeze 2>/dev/null | cut -d= -f1 | grep -xF -f <(printf '%s\n' "${OPENCV_VARIANTS[@]}") || true
)
if (( ${#installed_opencv[@]} > 1 )); then
  step "Resolving conflicting OpenCV variants"
  keep="opencv-python-headless"
  if printf '%s\n' "${installed_opencv[@]}" | grep -q contrib; then keep="opencv-contrib-python-headless"; fi
  warn "Installed together: ${installed_opencv[*]} — keeping only ${keep}"
  uv_pip uninstall --quiet "${installed_opencv[@]}"
  uv_pip install --quiet "$keep" --constraint "$CONSTRAINTS"
  success "OpenCV reduced to ${keep}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SAGEATTENTION (opt-in, GB10 only)
# ─────────────────────────────────────────────────────────────────────────────

SAGE_CHANGED=0
if [[ "$SAGE_ENABLED" == "true" ]]; then
  step "SageAttention (${COMFYUI_SAGE_REF:0:12})"
  torch_version="$("$VENV_PY" -c 'import torch; print(torch.__version__)')"
  if [[ "$(manifest_get sage_ref)" == "$COMFYUI_SAGE_REF" && "$(manifest_get sage_torch)" == "$torch_version" ]] \
     && [[ $TORCH_CHANGED -eq 0 ]] && ! is_true "$FORCE" && sage_has_sm121; then
    success "Built for torch ${torch_version}, sm_121 kernels present"
  else
    if [[ ! -d "${SAGE_SRC}/.git" ]]; then
      as_comfy git clone --quiet "$SAGE_REPO_URL" "$SAGE_SRC"
    else
      as_comfy git -C "$SAGE_SRC" fetch --quiet origin
    fi
    as_comfy git -c advice.detachedHead=false -C "$SAGE_SRC" checkout --quiet --force "$COMFYUI_SAGE_REF"
    uv_pip install --quiet setuptools wheel ninja packaging --constraint "$CONSTRAINTS"
    info "Compiling (several minutes; nvcc is memory-hungry, ${COMFYUI_SAGE_BUILD_JOBS} jobs)"
    as_comfy env CC=gcc-13 CXX=g++-13 CUDA_HOME="$CUDA_HOME" PATH="${CUDA_HOME}/bin:${PATH}" \
      TORCH_CUDA_ARCH_LIST="12.1" MAX_JOBS="$COMFYUI_SAGE_BUILD_JOBS" EXT_PARALLEL=1 \
      NVCC_APPEND_FLAGS="--threads 1" \
      "$UV" pip install --python "$VENV_PY" --no-build-isolation \
        --reinstall-package sageattention --constraint "$CONSTRAINTS" "$SAGE_SRC"
    sage_has_sm121 || error "SageAttention built, but its kernels carry no sm_121 code"
    SAGE_CHANGED=1
    success "SageAttention built with sm_121 kernels"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY AND RECORD
# ─────────────────────────────────────────────────────────────────────────────

step "Verifying the installation"

verify_install || error "Verification failed — see the findings above. Re-run with --force to rebuild the venv."
success "Installation verified"

new_manifest="comfyui_ref=${COMFYUI_REF}"$'\n'"torch_index=${COMFYUI_TORCH_INDEX_URL}"$'\n'"${VERIFY_VERSIONS}"
if [[ "$SAGE_ENABLED" == "true" ]]; then
  new_manifest+="sage_ref=${COMFYUI_SAGE_REF}"$'\n'"sage_torch=$("$VENV_PY" -c 'import torch; print(torch.__version__)')"$'\n'
fi
# Show upgrades as a diff against the previous run.
if [[ -f "$MANIFEST" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    old="$(manifest_get "$key")"
    if [[ "$old" != "$value" ]]; then
      info "${key}: ${old:-<none>} → ${value}"
    fi
  done <<< "$new_manifest"
fi
# Rewrite only on change: the manifest's mtime tells restart_pending whether
# the running process predates the installed versions.
if [[ "$(cat "$MANIFEST" 2>/dev/null)" != "$(printf '%s' "$new_manifest")" ]]; then
  printf '%s' "$new_manifest" | as_comfy tee "$MANIFEST" > /dev/null
  success "Recorded versions in ${MANIFEST}"
else
  success "Recorded versions unchanged (${MANIFEST})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MODEL DIRECTORY
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$COMFYUI_MODELS_DIR" != "${APP_DIR}/models" ]]; then
  step "Model directory ${COMFYUI_MODELS_DIR}"
  sudo install -d -m 755 -o "$COMFYUI_USER" -g "$COMFYUI_GROUP" "$COMFYUI_MODELS_DIR"
  for category in checkpoints clip_vision controlnet diffusion_models embeddings loras text_encoders upscale_models vae; do
    sudo install -d -m 755 -o "$COMFYUI_USER" -g "$COMFYUI_GROUP" "${COMFYUI_MODELS_DIR}/${category}"
  done
  export COMFYUI_MODELS_DIR
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  if render_install "${TEMPLATE_DIR}/extra_model_paths.yaml" "$EXTRA_PATHS" 644 "${COMFYUI_USER}:${COMFYUI_GROUP}" '${COMFYUI_MODELS_DIR}'; then
    REF_CHANGED=1   # ComfyUI reads the file at start only
    success "Wrote ${EXTRA_PATHS}"
  else
    success "${EXTRA_PATHS} up to date"
  fi
elif [[ -f "$EXTRA_PATHS" ]] && grep -q "$MANAGED_MARKER" "$EXTRA_PATHS"; then
  as_comfy rm -f "$EXTRA_PATHS"
  REF_CHANGED=1
  info "Removed ${EXTRA_PATHS} (COMFYUI_MODELS_DIR is back to the default)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# LAUNCHER AND SYSTEMD UNIT
# ─────────────────────────────────────────────────────────────────────────────

step "Launcher"

export COMFYUI_DIR COMFYUI_APP_DIR="$APP_DIR" COMFYUI_LAUNCH_ARGS COMFYUI_USER COMFYUI_GROUP

RUNTIME_CHANGED=$(( REF_CHANGED || TORCH_CHANGED || SAGE_CHANGED ))
# shellcheck disable=SC2016  # envsubst expects the literal variable list
if render_install "${TEMPLATE_DIR}/comfyui-launch.sh" "$LAUNCHER" 755 root:root \
     '${COMFYUI_DIR} ${COMFYUI_APP_DIR} ${COMFYUI_LAUNCH_ARGS}'; then
  RUNTIME_CHANGED=1
  success "Wrote ${LAUNCHER}"
else
  success "${LAUNCHER} up to date"
fi
info "ComfyUI arguments: ${COMFYUI_LAUNCH_ARGS}"

if [[ "$COMFYUI_SUPERVISOR" == "llama-swap" ]]; then
  step "llama-swap integration"

  # Validate before installing: a broken merge would keep llama-swap from
  # starting, and every other model with it.
  FRAGMENT="${LS_FRAGMENT_DIR}/${FRAGMENT_NAME}"
  rendered_fragment="$(mktempfile "$FRAGMENT_NAME")"
  render_fragment "$COMFYUI_CMD_PREFIX" > "$rendered_fragment"
  if ! validation="$(validate_llama_swap "$rendered_fragment")"; then
    printf '%s\n' "$validation" | sed 's/^/    /'
    error "llama-swap rejects its configuration with the ComfyUI fragment — nothing changed. A hand-written ${LLAMA_SWAP_MODEL_ID} in ${LS_CONFIG:-config.yaml} is the usual cause."
  fi
  success "llama-swap -validate: ${validation}"

  # Only now retire the own unit: had validation failed, ComfyUI would have
  # been left without any supervisor.
  if [[ -f "$SERVICE_FILE" ]]; then
    sudo systemctl disable --now --quiet "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    info "Removed ${SERVICE_FILE} (COMFYUI_SUPERVISOR=llama-swap)"
  fi

  LS_CHANGED=0
  if [[ -f "$FRAGMENT" ]] && cmp -s "$rendered_fragment" "$FRAGMENT"; then
    success "${FRAGMENT} up to date"
  else
    sudo install -m 644 -o root -g root "$rendered_fragment" "$FRAGMENT"
    LS_CHANGED=1
    success "Wrote ${FRAGMENT}"
  fi
  rm -f "$rendered_fragment"

  # Compared by hand rather than via render_install: --force must not restart
  # llama-swap (and unload every model) when the limits did not change.
  if [[ -f "$LLAMA_SWAP_DROPIN" ]] && cmp -s "${TEMPLATE_DIR}/llama-swap-dropin.conf" "$LLAMA_SWAP_DROPIN"; then
    success "${LLAMA_SWAP_DROPIN} up to date"
  else
    sudo install -d -m 755 "$(dirname "$LLAMA_SWAP_DROPIN")"
    sudo install -m 644 -o root -g root "${TEMPLATE_DIR}/llama-swap-dropin.conf" "$LLAMA_SWAP_DROPIN"
    sudo systemctl daemon-reload
    LS_CHANGED=1
    success "Wrote ${LLAMA_SWAP_DROPIN}"
  fi

  if (( LS_CHANGED )) || llama_swap_restart_pending; then
    restart_llama_swap "ComfyUI fragment or unit limits changed"
  else
    # llama-swap keeps running; only a loaded ComfyUI can be out of date.
    COMFYUI_PID="$(comfyui_pid)"
    if [[ -n "$COMFYUI_PID" ]] && { (( RUNTIME_CHANGED )) || is_true "$FORCE" || comfyui_outdated "$COMFYUI_PID"; }; then
      unload_comfyui
    else
      success "llama-swap unchanged${COMFYUI_PID:+, loaded ComfyUI is current}"
    fi
  fi
else
  if remove_llama_swap_integration; then
    restart_llama_swap "ComfyUI moved back to its own service"
  fi

  step "systemd unit"
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  if render_install "${TEMPLATE_DIR}/comfyui.service" "$SERVICE_FILE" 644 root:root \
       '${COMFYUI_USER} ${COMFYUI_GROUP} ${COMFYUI_DIR} ${COMFYUI_APP_DIR}'; then
    RUNTIME_CHANGED=1
    sudo systemctl daemon-reload
    success "Wrote ${SERVICE_FILE}"
  else
    success "${SERVICE_FILE} up to date"
  fi

  step "Service state"

  if is_true "$COMFYUI_AUTOSTART"; then
    if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
      sudo systemctl enable --quiet "$SERVICE_NAME"
      success "Enabled at boot"
    fi
  elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    sudo systemctl disable --quiet "$SERVICE_NAME"
    info "Disabled at boot (COMFYUI_AUTOSTART=false)"
  fi

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    if (( RUNTIME_CHANGED )) || is_true "$FORCE" || restart_pending; then
      if is_true "$INTERACTIVE" && ! confirm "ComfyUI is running; restart it now (kills any running job)?"; then
        warn "Not restarted — changes apply at the next start: sudo systemctl restart ${SERVICE_NAME}"
      else
        sudo systemctl restart "$SERVICE_NAME"
        info "Restarted to apply changes"
      fi
    else
      success "Running, nothing changed"
    fi
  elif is_true "$COMFYUI_AUTOSTART"; then
    sudo systemctl start "$SERVICE_NAME"
    info "Started"
  else
    info "Not started (COMFYUI_AUTOSTART=false) — start with: sudo systemctl start ${SERVICE_NAME}"
  fi

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Waiting up to ${COMFYUI_WAIT_TIMEOUT}s for ${HEALTH_URL}"
    elapsed=0
    until curl -fs -o /dev/null --max-time 5 "$HEALTH_URL"; do
      if systemctl is-failed --quiet "$SERVICE_NAME" || (( elapsed >= COMFYUI_WAIT_TIMEOUT )); then
        error "ComfyUI did not come up — see: journalctl -u ${SERVICE_NAME} -n 50"
      fi
      sleep 3
      elapsed=$(( elapsed + 3 ))
    done
    success "ComfyUI answers on ${HEALTH_URL}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ComfyUI setup complete${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
if [[ "$COMFYUI_SUPERVISOR" == "llama-swap" ]]; then
  echo -e "  ${BOLD}URL${RESET}          ${LS_URL}/comfyui/  (llama-swap; opening it starts ComfyUI)"
else
  echo -e "  ${BOLD}URL${RESET}          http://${PROBE_HOST}:${COMFYUI_PORT}"
fi
echo -e "  ${BOLD}Version${RESET}      ComfyUI ${COMFYUI_REF}, torch $(manifest_get torch) (${PLATFORM} path)"
echo -e "  ${BOLD}Directory${RESET}    ${COMFYUI_DIR}"
echo -e "  ${BOLD}Models${RESET}       ${COMFYUI_MODELS_DIR}"
if [[ "$COMFYUI_SUPERVISOR" == "llama-swap" ]]; then
  echo -e "  ${BOLD}Supervisor${RESET}   llama-swap, model ${LLAMA_SWAP_MODEL_ID} ($([[ -n "$(comfyui_pid)" ]] && echo loaded || echo 'not loaded'))"
  echo ""
  echo -e "  Start:         open ${LS_URL}/comfyui/"
  echo -e "  Stop:          request any other model, or unload ${LLAMA_SWAP_MODEL_ID} in ${LS_URL}/ui"
  echo -e "  Logs:          journalctl -u ${LLAMA_SWAP_SERVICE} -f"
else
  echo -e "  ${BOLD}Service${RESET}      ${SERVICE_NAME} ($(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true), boot: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true))"
  echo ""
  echo -e "  Start / stop:  sudo systemctl start|stop ${SERVICE_NAME}"
  echo -e "  Logs:          journalctl -u ${SERVICE_NAME} -f"
fi
echo -e "  Verify:        $0 --check"
if [[ "$COMFYUI_SUPERVISOR" == "systemd" && "$COMFYUI_LISTEN" != "127.0.0.1" && "$COMFYUI_LISTEN" != "localhost" ]]; then
  echo ""
  warn "ComfyUI listens on ${COMFYUI_LISTEN} and has no authentication."
fi
