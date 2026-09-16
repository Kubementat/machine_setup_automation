#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-virt-runner.sh — Install virt-runner and KVM/libvirt prerequisites
# =============================================================================
#
# Description:
#   Installs the virt-runner CLI tool and all host prerequisites needed to
#   run the VM-based integration test suite (see tests/README.md).
#
#   This script:
#     1. Clones the virt-runner repository (if not already cloned)
#     2. Runs install-prerequisites.sh to set up KVM, libvirt, pools, etc.
#     3. Installs virt-runner as a uv tool (or verifies existing installation)
#     4. Verifies the installation works
#
#   Idempotent: safe to re-run on an already-configured system.
#
# Options:
#   --help    Show help message
#
# Environment variables (all optional):
#   VIRT_RUNNER_REPO   URL of the virt-runner repository
#                      (default: https://github.com/Kubementat/virt-runner.git)
#   VIRT_RUNNER_DIR    Local directory to clone to
#                      (default: ~/dev/os_projects/virt-runner)
#   VIRT_USERNAME      User to add to libvirt/kvm groups
#                      (default: current user)
#
# Usage:
#   ./setup-virt-runner.sh
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

# Configuration
VIRT_RUNNER_REPO="${VIRT_RUNNER_REPO:-https://github.com/Kubementat/virt-runner.git}"
VIRT_RUNNER_DIR="${VIRT_RUNNER_DIR:-${HOME}/dev/os_projects/virt-runner}"
VIRT_USERNAME="${VIRT_USERNAME:-${USER:-}}"

# Parse arguments
# shellcheck disable=SC2317
while [[ $# -gt 0 ]]; do
  case $1 in
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --help    Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  VIRT_RUNNER_REPO   URL of the virt-runner repository"
      echo "                     (default: https://github.com/Kubementat/virt-runner.git)"
      echo "  VIRT_RUNNER_DIR    Local directory to clone to"
      echo "                     (default: ~/dev/os_projects/virt-runner)"
      echo "  VIRT_USERNAME      User to add to libvirt/kvm groups"
      echo "                     (default: current user)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
  shift
done

log() { echo "[setup-virt-runner] $*"; }

# ---------------------------------------------------------------------------
# Step 1: Clone the virt-runner repository
# ---------------------------------------------------------------------------

log "Step 1: Cloning virt-runner repository"

if [[ -d "${VIRT_RUNNER_DIR}" ]]; then
  log "Repository already exists at ${VIRT_RUNNER_DIR}, updating..."
  cd "${VIRT_RUNNER_DIR}"
  git pull --ff-only || log "Warning: Could not update repository (not a git repo or pull failed)"
else
  log "Cloning to ${VIRT_RUNNER_DIR}"
  mkdir -p "$(dirname "${VIRT_RUNNER_DIR}")"
  git clone "${VIRT_RUNNER_REPO}" "${VIRT_RUNNER_DIR}"
fi

cd "${VIRT_RUNNER_DIR}"
log "Repository ready at ${VIRT_RUNNER_DIR}"

# ---------------------------------------------------------------------------
# Step 2: Run install-prerequisites.sh
# ---------------------------------------------------------------------------

log "Step 2: Installing host prerequisites (KVM, libvirt, pools)"

if [[ -f "${VIRT_RUNNER_DIR}/install-prerequisites.sh" ]]; then
  # Run in non-interactive mode with default answers
  export DEBIAN_FRONTEND=noninteractive
  bash "${VIRT_RUNNER_DIR}/install-prerequisites.sh"
else
  log "Warning: install-prerequisites.sh not found in ${VIRT_RUNNER_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 3: Install virt-runner as a uv tool
# ---------------------------------------------------------------------------

log "Step 3: Installing virt-runner as a uv tool"

# Check if uv is available
if ! command -v uv &>/dev/null; then
  log "Installing uv from astral.sh..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # Add to PATH for this session
  export PATH="${HOME}/.local/bin:${PATH}"
fi

# Install the tool from the local directory
log "Installing virt-runner from ${VIRT_RUNNER_DIR}"
uv tool install "${VIRT_RUNNER_DIR}"

# Verify installation
if command -v virt-runner &>/dev/null; then
  log "virt-runner installed successfully"
  virt-runner --help | head -5
else
  log "Warning: virt-runner not found in PATH after installation"
  log "You may need to add ~/.local/bin to your PATH or run: . ~/.local/bin/env"
fi

# ---------------------------------------------------------------------------
# Step 4: Verify installation
# ---------------------------------------------------------------------------

log "Step 4: Verifying installation"

# Check if virt-runner can list VMs (even if none exist)
if virt-runner list --json 2>/dev/null | jq -e '.vms' >/dev/null 2>&1; then
  log "virt-runner is working correctly"
else
  log "Warning: virt-runner list failed (may need to log out/in for group membership)"
  log "Try: newgrp libvirt"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log ""
log "virt-runner setup complete!"
log ""
log "To run the VM-based test suite:"
log "  cd ${SCRIPT_DIR}/.."
log "  tests/run-vm-tests.sh"
log ""
log "To test virt-runner directly:"
log "  virt-runner create test-vm"
log "  virt-runner ssh test-vm"
log "  virt-runner destroy test-vm"
log ""
log "Note: If you see 'libvirt not reachable' errors, you may need to log out"
log "and log back in for group membership changes to take effect, or run:"
log "  newgrp libvirt"
