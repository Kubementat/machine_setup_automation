#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-nvidia-container.sh — NVIDIA Container Toolkit + CDI GPU spec
# =============================================================================
#
# Description:
#   Makes the host's GPU usable from containers via CDI (Container Device
#   Interface). Installs the NVIDIA Container Toolkit when missing, generates
#   /etc/cdi/nvidia.yaml, and installs an apt hook that regenerates the spec
#   after a driver upgrade.
#
#   Prerequisite for every GPU task in this repo (setup-colqwen.sh,
#   setup-vllm.sh, setup-vllm-omni.sh). Does NOT install the GPU driver
#   itself — the driver comes from the distribution (DGX OS, ubuntu-drivers).
#
# Behaviour:
#   Idempotent. Re-running converges: an installed toolkit is left alone, and
#   the CDI spec is rewritten only when it went stale (or with --force).
#
#   WHY CDI AND NOT `deploy.resources.reservations.devices`:
#     The legacy nvidia-container-runtime injects /dev/nvidia* from an OCI
#     prestart hook, i.e. AFTER runc has created the container's systemd
#     scope, so systemd never learns about those device nodes. Any later
#     `systemctl daemon-reload` (snapd triggers one every few hours) rebuilds
#     the scope's cgroup-v2 device filter from its own DeviceAllow list and
#     silently revokes GPU access from the RUNNING container: open() on
#     /dev/nvidiactl returns EPERM, the first cuBLAS call fails, and the CUDA
#     context stays poisoned for the life of the process while the container
#     keeps answering /health with 200.
#     CDI injects the devices into the OCI spec BEFORE the container is
#     created, so runc records them in the scope and a reload re-applies them.
#
#   WHY THE APT HOOK:
#     A CDI spec pins version-suffixed driver libraries
#     (libcuda.so.580.142). A driver upgrade renames them and every mount in
#     the spec dangles, so containers fail to start with "unresolvable CDI
#     devices nvidia.com/gpu=all". The hook regenerates the spec as part of
#     the same apt transaction that replaced the driver.
#
# Options:
#   --force              Regenerate the CDI spec even when it is current
#   --no-apt-hook        Do not install the apt post-invoke hook
#   --skip-smoke-test    Do not run the container GPU smoke test
#   --help               Show help message
#
# Environment:
#   NVIDIA_CDI_SPEC         Spec path                  (default /etc/cdi/nvidia.yaml)
#   NVIDIA_CDI_REFRESH_BIN  Refresh helper path        (default /usr/local/sbin/nvidia-cdi-refresh)
#   NVIDIA_CDI_APT_HOOK     Install the apt hook       (default true)
#   NVIDIA_SMOKE_TEST       Run the container test     (default true)
#   NVIDIA_SMOKE_IMAGE      Image for the smoke test   (default ubuntu:24.04)
#
# Usage:
#   ./setup-nvidia-container.sh
#   ./setup-nvidia-container.sh --force
#   NVIDIA_CDI_APT_HOOK=false ./setup-nvidia-container.sh
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/nvidia-container")"

# Configuration
FORCE=false
NVIDIA_CDI_SPEC="${NVIDIA_CDI_SPEC:-/etc/cdi/nvidia.yaml}"
NVIDIA_CDI_REFRESH_BIN="${NVIDIA_CDI_REFRESH_BIN:-/usr/local/sbin/nvidia-cdi-refresh}"
NVIDIA_CDI_APT_HOOK="${NVIDIA_CDI_APT_HOOK:-true}"
NVIDIA_SMOKE_TEST="${NVIDIA_SMOKE_TEST:-true}"
# nvidia-smi is itself mounted into the container by the CDI spec, so the smoke
# test needs no CUDA image — a plain base image proves the injection works and
# keeps the pull small.
NVIDIA_SMOKE_IMAGE="${NVIDIA_SMOKE_IMAGE:-ubuntu:24.04}"

APT_HOOK_PATH="/etc/apt/apt.conf.d/99-nvidia-cdi-refresh"
TOOLKIT_KEY_URL="https://nvidia.github.io/libnvidia-container/gpgkey"
TOOLKIT_KEY_PATH="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
TOOLKIT_LIST_URL="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
TOOLKIT_LIST_PATH="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
CDI_DEVICE="nvidia.com/gpu=all"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --force)           FORCE=true; shift ;;
    --no-apt-hook)     NVIDIA_CDI_APT_HOOK=false; shift ;;
    --skip-smoke-test) NVIDIA_SMOKE_TEST=false; shift ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Installs the NVIDIA Container Toolkit, generates the CDI GPU spec, and"
      echo "keeps that spec current across driver upgrades via an apt hook."
      echo "Prerequisite for setup-colqwen.sh, setup-vllm.sh and setup-vllm-omni.sh."
      echo ""
      echo "Options:"
      echo "  --force              Regenerate the CDI spec even when it is current"
      echo "  --no-apt-hook        Do not install the apt post-invoke hook"
      echo "  --skip-smoke-test    Do not run the container GPU smoke test"
      echo "  --help               Show this help message"
      echo ""
      echo "Environment:"
      echo "  NVIDIA_CDI_SPEC         Spec path                 (default /etc/cdi/nvidia.yaml)"
      echo "  NVIDIA_CDI_REFRESH_BIN  Refresh helper path       (default /usr/local/sbin/nvidia-cdi-refresh)"
      echo "  NVIDIA_CDI_APT_HOOK     Install the apt hook      (default true)"
      echo "  NVIDIA_SMOKE_TEST       Run the container test    (default true)"
      echo "  NVIDIA_SMOKE_IMAGE      Smoke-test image          (default ubuntu:24.04)"
      echo ""
      echo "Behaviour:"
      echo "  Idempotent. Does NOT install the GPU driver — that comes from the"
      echo "  distribution (DGX OS, ubuntu-drivers). Re-run after a driver upgrade"
      echo "  if the apt hook is disabled; the hook does it automatically otherwise."
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# =============================================================================
# Main
# =============================================================================

step "Setting up NVIDIA container GPU access (CDI)"

# ── Pre-flight ────────────────────────────────────────────────────────────────
# The driver is a hard prerequisite and is deliberately not installed here:
# picking a driver branch is a host decision (DGX OS ships its own), and a
# wrong choice costs a reboot.
if ! command -v nvidia-smi &>/dev/null; then
  error "nvidia-smi not found — no NVIDIA driver on this host.
  This task configures container access to an existing GPU; it does not install the driver.
  Install one first (e.g. 'sudo ubuntu-drivers install', or via DGX OS), reboot, then re-run."
fi

if ! DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]')" \
   || [[ -z "${DRIVER_VERSION}" ]]; then
  error "nvidia-smi is present but did not report a driver version — the driver is not loaded.
  Check 'nvidia-smi' output; a reboot is usually needed after a driver install."
fi
success "NVIDIA driver ${DRIVER_VERSION} is loaded."

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi

# ── NVIDIA Container Toolkit ──────────────────────────────────────────────────
step "Checking NVIDIA Container Toolkit"

if command -v nvidia-ctk &>/dev/null; then
  success "NVIDIA Container Toolkit already installed: $(nvidia-ctk --version | head -n1)"
else
  info "nvidia-ctk not found — installing nvidia-container-toolkit."

  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg

  step "Adding the NVIDIA Container Toolkit repository"
  if [[ -f "${TOOLKIT_KEY_PATH}" ]]; then
    info "Keyring already exists at ${TOOLKIT_KEY_PATH}"
  else
    # Render as the invoking user and install with sudo (repo convention:
    # never pipe a download straight into a sudo-owned path).
    key_tmp="$(mktempfile nvidia-container-toolkit.gpgkey)"
    # Both temp files go through mktempfile so the EXIT trap removes them even
    # when one of the steps below aborts the script.
    key_bin="$(mktempfile nvidia-container-toolkit.gpg)"
    curl -fsSL "${TOOLKIT_KEY_URL}" -o "${key_tmp}" \
      || error "Could not download the NVIDIA Container Toolkit GPG key from ${TOOLKIT_KEY_URL}"
    gpg --dearmor < "${key_tmp}" > "${key_bin}" \
      || error "Could not dearmor the NVIDIA Container Toolkit GPG key"
    sudo install -m 644 "${key_bin}" "${TOOLKIT_KEY_PATH}"
  fi

  list_tmp="$(mktempfile nvidia-container-toolkit.list)"
  curl -fsSL "${TOOLKIT_LIST_URL}" -o "${list_tmp}" \
    || error "Could not download the repository list from ${TOOLKIT_LIST_URL}"
  # Upstream ships the list without signed-by; pin it to the keyring installed
  # above so apt does not fall back to trusting it globally.
  sed -i "s#deb https://#deb [signed-by=${TOOLKIT_KEY_PATH}] https://#g" "${list_tmp}"
  sudo install -m 644 "${list_tmp}" "${TOOLKIT_LIST_PATH}"

  step "Installing nvidia-container-toolkit"
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit

  command -v nvidia-ctk &>/dev/null \
    || error "nvidia-container-toolkit installed but nvidia-ctk is still not on PATH."
  success "NVIDIA Container Toolkit installed: $(nvidia-ctk --version | head -n1)"
fi

# ── CDI refresh helper ────────────────────────────────────────────────────────
# Installed before the spec is generated: the task uses the very same helper to
# create it, so there is one implementation of "is the spec stale" rather than
# a copy here and another in the hook.
step "Installing the CDI refresh helper"

[[ -f "${TEMPLATE_DIR}/nvidia-cdi-refresh.sh" ]] \
  || error "Template not found: ${TEMPLATE_DIR}/nvidia-cdi-refresh.sh"

sudo install -d -m 755 "$(dirname "${NVIDIA_CDI_REFRESH_BIN}")"
sudo install -m 755 "${TEMPLATE_DIR}/nvidia-cdi-refresh.sh" "${NVIDIA_CDI_REFRESH_BIN}"
success "Refresh helper installed: ${NVIDIA_CDI_REFRESH_BIN}"

# ── CDI spec ──────────────────────────────────────────────────────────────────
step "Generating the CDI spec"

refresh_args=(--spec "${NVIDIA_CDI_SPEC}")
[[ "${FORCE}" == true ]] && refresh_args+=(--force)

sudo "${NVIDIA_CDI_REFRESH_BIN}" "${refresh_args[@]}" \
  || error "CDI spec generation failed — see the output above."

# Verify what the runtime will actually see, not just that a file exists: a
# spec can parse and still expose no usable device.
if ! nvidia-ctk cdi list 2>/dev/null | grep -qF "${CDI_DEVICE}"; then
  error "CDI spec was written to ${NVIDIA_CDI_SPEC} but '${CDI_DEVICE}' is not listed.
  Inspect with: nvidia-ctk cdi list"
fi
success "CDI device ${CDI_DEVICE} is available."

# ── apt hook ──────────────────────────────────────────────────────────────────
step "Configuring the driver-upgrade apt hook"

if [[ "${NVIDIA_CDI_APT_HOOK}" == true ]]; then
  [[ -f "${TEMPLATE_DIR}/apt-hook.conf" ]] \
    || error "Template not found: ${TEMPLATE_DIR}/apt-hook.conf"

  hook_tmp="$(mktempfile nvidia-cdi-apt-hook.conf)"
  # Only non-secret layout values are substituted (repo convention).
  # shellcheck disable=SC2016  # the SHELL-FORMAT argument must stay literal:
  # it names the variables envsubst may replace, so the shell must not expand it.
  NVIDIA_CDI_REFRESH_BIN="${NVIDIA_CDI_REFRESH_BIN}" NVIDIA_CDI_SPEC="${NVIDIA_CDI_SPEC}" \
    envsubst '${NVIDIA_CDI_REFRESH_BIN} ${NVIDIA_CDI_SPEC}' \
    < "${TEMPLATE_DIR}/apt-hook.conf" > "${hook_tmp}"
  sudo install -m 644 "${hook_tmp}" "${APT_HOOK_PATH}"
  success "apt hook installed: ${APT_HOOK_PATH}"
  info "The CDI spec is now regenerated automatically after a driver upgrade."
else
  if [[ -f "${APT_HOOK_PATH}" ]]; then
    warn "apt hook disabled — removing the previously installed ${APT_HOOK_PATH}"
    sudo rm -f "${APT_HOOK_PATH}"
  else
    info "apt hook disabled (NVIDIA_CDI_APT_HOOK=false)."
  fi
  warn "Without the hook you MUST re-run this task after every driver upgrade,"
  warn "or containers will fail with 'unresolvable CDI devices ${CDI_DEVICE}'."
fi

# ── Smoke test ────────────────────────────────────────────────────────────────
# Non-fatal, matching setup-docker.sh: a host without egress must not fail an
# otherwise successful configuration.
if [[ "${NVIDIA_SMOKE_TEST}" == true ]]; then
  step "Testing GPU access from a container"
  warn_moving_image "${NVIDIA_SMOKE_IMAGE}" "NVIDIA_SMOKE_IMAGE"
  if sudo docker run --rm --device "${CDI_DEVICE}" "${NVIDIA_SMOKE_IMAGE}" nvidia-smi -L 2>&1; then
    success "Container GPU smoke test passed."
  else
    warn "Container GPU smoke test failed (image pull or runtime issue?)."
    warn "Verify manually: sudo docker run --rm --device ${CDI_DEVICE} ${NVIDIA_SMOKE_IMAGE} nvidia-smi"
  fi
else
  info "Smoke test skipped."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
step "Summary"
success "NVIDIA container GPU access is configured."
info "Driver:        ${DRIVER_VERSION}"
info "CDI spec:      ${NVIDIA_CDI_SPEC}"
info "CDI device:    ${CDI_DEVICE}"
info "Refresh:       ${NVIDIA_CDI_REFRESH_BIN} [--check|--force]"
info "apt hook:      $([[ "${NVIDIA_CDI_APT_HOOK}" == true ]] && echo "${APT_HOOK_PATH}" || echo "disabled")"
echo ""
info "Use the GPU in a compose file with:"
info "    devices:"
info "      - \"${CDI_DEVICE}\""
