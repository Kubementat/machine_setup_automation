#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-pi.sh — Install Pi coding agent
# =============================================================================
#
# Description:
#   Installs and configures the Pi coding agent environment.
#   Ensures latest Node.js version is installed and then installs Pi globally.
#   Initializes the Pi config and model files (~/.pi/agent/settings.json,
#   ~/.pi/agent/models.json) as {} when they do not exist yet.
#
# Environment Variables (optional):
#   NVM_DIR - NVM directory path (default: $HOME/.nvm)
#
# Usage:
#   ./setup-pi.sh
#   ./setup-pi.sh --help
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

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs and configures the Pi coding agent environment. Ensures the latest
Node.js version is installed (via NVM) and then installs Pi globally,
including a set of Pi extensions. Initializes the Pi config and model files
(~/.pi/agent/settings.json, ~/.pi/agent/models.json) as {} when missing.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  NVM_DIR     NVM directory path (default: $HOME/.nvm)

${BOLD}Note:${RESET} NVM must be installed (run setup-basics.sh first).
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1 (see --help)"
      ;;
  esac
done

# Configuration
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Pi extensions to install
declare -a PI_EXTENSIONS=(
  "npm:pi-subagents"
  "npm:pi-mcp-adapter"
  "npm:pi-markdown-preview"
  "npm:pi-web-access"
  "npm:pi-extmgr"
  "npm:pi-token-speed"
)

# =============================================================================
# Main
# =============================================================================

step "Setting up Pi coding agent"

# Load NVM if not already loaded
if ! command -v nvm &>/dev/null; then
  step "Loading NVM"
  export NVM_DIR
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
fi

# Check if nvm is available now
if ! command -v nvm &>/dev/null; then
  error "NVM is not installed. Please install NVM first."
fi

# Install latest Node.js
step "Installing latest Node.js version"
nvm install node

# Check if Pi is already installed
if command -v pi &>/dev/null; then
  info "Pi coding agent is already installed: $(pi --version 2>/dev/null || echo 'version unknown')"
  info "Updating Pi..."
else
  step "Installing Pi coding agent"
fi

npm install -g @earendil-works/pi-coding-agent

# Install Pi extensions
step "Installing Pi extensions"
for extension in "${PI_EXTENSIONS[@]}"; do
  info "Installing: ${extension}"
  pi install "${extension}"
done

# Update Pi
step "Updating Pi extensions"
pi update

# Install Codegraph
step "Installing Codegraph"
if ! command -v codegraph &>/dev/null; then
  step "Installing Codegraph"
  npm install -g @colbymchenry/codegraph
  codegraph  install -y || true
fi

# Install Playwright
step "Installing Playwright browsers and dependencies"
npx playwright install-deps || true
npx playwright install || true
npx playwright install chrome || true

# Ensure Pi's config and model files exist; initialize missing files as {}.
# Tools that merge into these files (e.g. tasks/sync-models.py) require the
# files to exist before their first run.
step "Ensuring Pi config and model files exist"
PI_AGENT_DIR="${HOME}/.pi/agent"
mkdir -p "${PI_AGENT_DIR}"
for pi_file in "${PI_AGENT_DIR}/settings.json" "${PI_AGENT_DIR}/models.json"; do
  if [[ ! -f "${pi_file}" ]]; then
    echo '{}' > "${pi_file}"
    info "Initialized ${pi_file}"
  else
    info "Already present: ${pi_file}"
  fi
done

success "Pi coding agent and extras installed successfully"
info "Run 'pi --help' to see available commands"
