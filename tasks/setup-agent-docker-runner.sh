#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-agent-docker-runner.sh — Install agent-docker-runner CLI
# =============================================================================
#
# Description:
#   Installs the agent-docker-runner (adr) CLI tool that runs coding agents
#   inside isolated Docker containers.
#
# Environment Variables (optional):
#   ADR_REPO_URL     - Git repository URL (default: official repo)
#   ADR_INSTALL_DIR  - Clone destination (default: $HOME/tools/agent-docker-runner)
#   ADR_BUILD_AGENTS - Comma-separated agents to build (default: pi,opencode,claude,codex)
#
# Usage:
#   ./setup-agent-docker-runner.sh
#   ADR_BUILD_AGENTS="pi,claude" ./setup-agent-docker-runner.sh
#   ./setup-agent-docker-runner.sh --help
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

Installs the agent-docker-runner (adr) CLI tool that runs coding agents
inside isolated Docker containers.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  ADR_REPO_URL        Git repository URL (default: https://github.com/Kubementat/agent-docker-runner.git)
  ADR_INSTALL_DIR     Clone destination (default: $HOME/tools/agent-docker-runner)
  ADR_BUILD_AGENTS    Comma-separated agents to build
                      (default: pi,opencode,claude,codex)

${BOLD}Note:${RESET} Docker must be installed and running (run setup-docker.sh first).
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
ADR_REPO_URL="${ADR_REPO_URL:-https://github.com/Kubementat/agent-docker-runner.git}"
ADR_INSTALL_DIR="${ADR_INSTALL_DIR:-${HOME}/tools/agent-docker-runner}"
ADR_BUILD_AGENTS="${ADR_BUILD_AGENTS:-pi,opencode,claude,codex}"

PI_CONFIG_DIR="${HOME}/.pi"
OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
CLAUDE_CONFIG_DIR="${HOME}/.claude"
CODEx_CONFIG_DIR="${HOME}/.codex"

# =============================================================================
# Main
# =============================================================================

step "Setting up agent-docker-runner (adr)"

# Check for git
if ! command -v git &>/dev/null; then
  error "git is not installed. Please install git first."
fi

# Pre-flight checks
step "Running pre-flight checks"
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi

if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi

success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

# Checkout repository
step "Checking out agent-docker-runner to ${ADR_INSTALL_DIR}"

if [[ -d "${ADR_INSTALL_DIR}/.git" ]]; then
  info "Repository exists, updating to latest version..."
  cd "${ADR_INSTALL_DIR}"
  git fetch origin main
  git checkout main
  git reset --hard origin/main
  success "Repository updated."
else
  info "Cloning repository from ${ADR_REPO_URL}..."
  mkdir -p "$(dirname "${ADR_INSTALL_DIR}")"
  git clone "${ADR_REPO_URL}" "${ADR_INSTALL_DIR}"
  cd "${ADR_INSTALL_DIR}"
  if [[ $(git rev-parse --abbrev-ref HEAD) != "main" ]]; then
    info "Switching to main branch..."
    git checkout main
  fi
  success "Repository cloned."
fi

# Verify install.sh exists
if [[ ! -f "${ADR_INSTALL_DIR}/install.sh" ]]; then
  error "install.sh not found in ${ADR_INSTALL_DIR}. Repository may be corrupted."
fi

# Run installer
step "Running installer"
cd "${ADR_INSTALL_DIR}"
bash install.sh --yes || bash install.sh

# Verify installation
if ! command -v adr &>/dev/null; then
  error "adr CLI not found after installation. Check PATH."
fi

success "agent-docker-runner installed successfully"

# Build agent images
step "Building Docker images for: ${ADR_BUILD_AGENTS}"
IFS=',' read -ra AGENTS <<< "${ADR_BUILD_AGENTS}"
for agent in "${AGENTS[@]}"; do
  info "Building image for '${agent}'..."
  adr build "${agent}" || warn "Failed to build image for '${agent}'"
done

# Configuration instructions
step "Configuration instructions"
echo ""
echo -e "${BOLD}Configure your agents:${RESET}"
echo ""

# Pi
echo -e "${CYAN}Pi${RESET}:"
echo "  Config directory: ${PI_CONFIG_DIR}/agent/"
if [[ ! -f "${PI_CONFIG_DIR}/agent/settings.json" ]]; then
  echo "  Actions needed:"
  echo "    1. mkdir -p ${PI_CONFIG_DIR}/agent"
  ADR_SHARE="${HOME}/.local/share/adr"
  if [[ -d "${ADR_SHARE}/config-examples/pi" ]]; then
    echo "    2. cp -r ${ADR_SHARE}/config-examples/pi/. ${PI_CONFIG_DIR}/"
  else
    echo "    2. Run 'adr build pi' first to get config examples"
  fi
  echo "    3. Edit ${PI_CONFIG_DIR}/agent/settings.json and add API keys"
else
  success "${PI_CONFIG_DIR}/agent/settings.json exists"
fi
echo ""

# Opencode
echo -e "${CYAN}Opencode${RESET}:"
if [[ ! -f "${OPENCODE_CONFIG_DIR}/opencode.json" ]]; then
  echo "  Actions needed:"
  echo "    1. mkdir -p ${OPENCODE_CONFIG_DIR}"
  ADR_SHARE="${HOME}/.local/share/adr"
  if [[ -d "${ADR_SHARE}/config-examples/opencode" ]]; then
    echo "    2. cp ${ADR_SHARE}/config-examples/opencode/opencode.json.example ${OPENCODE_CONFIG_DIR}/opencode.json"
  else
    echo "    2. Create opencode.json manually with provider configuration"
  fi
else
  success "${OPENCODE_CONFIG_DIR}/opencode.json exists"
fi
echo ""

# Claude
echo -e "${CYAN}Claude${RESET}:"
if [[ -d "${CLAUDE_CONFIG_DIR}" && -f "${CLAUDE_CONFIG_DIR}/settings.json" ]]; then
  success "${CLAUDE_CONFIG_DIR}/settings.json exists"
  if [[ -f "${HOME}/.claude.json" ]]; then
    success "${HOME}/.claude.json exists"
  else
    warn "${HOME}/.claude.json not found (needed to pre-approve API key)"
  fi
else
  echo "  Actions needed:"
  echo "    1. mkdir -p ${CLAUDE_CONFIG_DIR}"
  echo "    2. Add ANTHROPIC_API_KEY in settings.json"
fi
echo ""

# Codex
echo -e "${CYAN}Codex${RESET}:"
if [[ -d "${CODEx_CONFIG_DIR}" ]]; then
  success "${CODEx_CONFIG_DIR} exists"
else
  echo "  Actions needed:"
  echo "    1. mkdir -p ${CODEx_CONFIG_DIR}"
  echo "    2. Export OPENAI_API_KEY before running"
fi
echo ""

# Summary
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
success "agent-docker-runner setup complete!"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""

# PATH warning
if ! echo "${PATH}" | tr ':' '\n' | grep -q "${HOME}/.local/bin"; then
  warn "${HOME}/.local/bin is not on your PATH"
  warn "Add to shell config: export PATH=\"\$PATH:${HOME}/.local/bin\""
  echo ""
fi

echo -e "${BOLD}Installed version:${RESET}"
adr version
echo ""

echo -e "${BOLD}Quick start:${RESET}"
echo "  cd /path/to/project"
echo "  adr run pi"
echo ""
echo "  adr run -w ~/projects/myapp --prompt 'Write tests' pi"
echo ""

echo -e "${BOLD}Help:${RESET}"
echo "  adr --help"
echo "  adr run --help"
echo "  adr build --help"
echo ""
