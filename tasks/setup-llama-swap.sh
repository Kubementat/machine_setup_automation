#!/usr/bin/env bash
# shellcheck disable=SC2086,SC1091,SC2016
# =============================================================================
# setup-llama-swap.sh — Deploy llama-swap as a systemd daemon
# =============================================================================
#
# DESCRIPTION:
#   Installs llama-swap, a multi-model LLM proxy with hot-swap support, as a
#   native systemd service. Runs the single Go binary directly on the host.
#
# KEY ACTIONS:
#   1. Pre-flight checks: systemctl, curl, port availability
#   2. Keeps an existing installation unless `--force`; prompts only with `--interactive`
#   3. Downloads the latest llama-swap binary from GitHub releases
#   4. Generates config.yaml from template (comprehensive example with all options)
#   5. Generates and installs llama-swap.service from template, including
#      --config-dir for config fragments other tasks drop in (e.g. ComfyUI)
#   6. Reloads systemd, starts and enables the service
#   7. Waits for the /health endpoint to respond
#   8. Displays access information and management commands
#
# IMPORTANT VARIABLES:
#   LLAMA_SWAP_PORT       - Host port for web UI access (default: 9292)
#   LLAMA_SWAP_DIR        - Host directory for config & data (default: /srv/llama-swap)
#   LLAMA_SWAP_HEALTH_TIMEOUT - Health check timeout in seconds (default: 500)
#   LLAMA_SWAP_LOG_LEVEL  - Log level: debug, info, warn, error (default: info)
#   LLAMA_SWAP_START_PORT - Starting port for ${PORT} macro in config (default: 10001)
#   LLAMA_SWAP_GLOBAL_TTL - Default model idle TTL in seconds (default: 0 = never)
#   LLAMA_SWAP_LISTEN_ADDR - Bind address (default: 0.0.0.0:9292)
#   LLAMA_SWAP_USER       - Service runtime user (default: root)
#   LLAMA_SWAP_BIN_PATH   - Binary install path (default: /usr/local/bin/llama-swap)
#   LLAMA_SWAP_VERSION    - Release version to install (default: latest)
#   LLAMA_SWAP_FRAGMENT_DIR - Extra config files merged into config.yaml
#                           (default: ${LLAMA_SWAP_DIR}/conf.d)
#
# DEPENDENCIES:
#   - curl: Used for health check polling and binary download
#   - systemctl: systemd management
#   - envsubst: Used for template rendering
#   - jq: Used for GitHub API parsing (binary download)
#
# OUTPUTS:
#   - ${LLAMA_SWAP_DIR}/config/config.yaml - llama-swap configuration
#   - ${LLAMA_SWAP_FRAGMENT_DIR}/          - config fragments (--config-dir)
#   - /etc/systemd/system/llama-swap.service - systemd unit file
#   - ${LLAMA_SWAP_BIN_PATH} - installed binary
#
# USAGE:
#   ./setup-llama-swap.sh                          # defaults
#   ./setup-llama-swap.sh --check                  # check status only
#   ./setup-llama-swap.sh --force                  # force reinstall/update without prompts
#   ./setup-llama-swap.sh --interactive            # prompt before replacing an existing install
#   ./setup-llama-swap.sh --help                   # show help and exit
#
#   An existing installation is kept by default: binary and config.yaml stay
#   untouched, only the unit and the fragment directory are converged.
#   --force takes precedence over --interactive (no prompt, re-install).
#
# REFERENCE:
#   https://github.com/mostlygeek/llama-swap
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures
# ─────────────────────────────────────────────────────────────────────────────

# Set to 1 immediately BEFORE this run stops/disables or enables/starts the
# llama-swap unit, and reset to 0 once the service is proven healthy. The trap
# touches the unit only while this flag is set, so a late failure (download,
# config write, ufw) cannot stop a unit that was running before this script
# was invoked.
SERVICE_TOUCHED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( SERVICE_TOUCHED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). The llama-swap service was not touched by this run — nothing stopped or disabled."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Cleaning up the service state from this run..."
  # If service was partially installed, disable and stop it
  if sudo systemctl cat llama-swap &>/dev/null 2>&1; then
    if sudo systemctl is-active llama-swap &>/dev/null; then
      info "Disabling and stopping partially installed service..."
      sudo systemctl stop llama-swap 2>/dev/null || true
      sudo systemctl disable llama-swap 2>/dev/null || true
      sudo systemctl daemon-reload 2>/dev/null || true
      success "Partial service removed."
    else
      info "Service from this run is already stopped — config and data in ${LLAMA_SWAP_DIR} are preserved."
    fi
  fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/llama-swap")"

# shellcheck source=lib/helpers.sh
source "${LIB_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

LLAMA_SWAP_PORT="${LLAMA_SWAP_PORT:-9292}"               # Host port
LLAMA_SWAP_DIR="${LLAMA_SWAP_DIR:-/srv/llama-swap}"      # Base directory
LLAMA_SWAP_HEALTH_TIMEOUT="${LLAMA_SWAP_HEALTH_TIMEOUT:-500}"  # Health check timeout (s)
LLAMA_SWAP_LOG_LEVEL="${LLAMA_SWAP_LOG_LEVEL:-info}"     # Log level
LLAMA_SWAP_START_PORT="${LLAMA_SWAP_START_PORT:-10001}"  # Starting port macro
LLAMA_SWAP_GLOBAL_TTL="${LLAMA_SWAP_GLOBAL_TTL:-0}"      # Global model TTL
LLAMA_SWAP_LISTEN_ADDR="${LLAMA_SWAP_LISTEN_ADDR:-0.0.0.0:9292}"  # Bind address
LLAMA_SWAP_USER="${LLAMA_SWAP_USER:-root}"               # Service user
LLAMA_SWAP_BIN_PATH="${LLAMA_SWAP_BIN_PATH:-/usr/local/bin/llama-swap}"  # Binary path
LLAMA_SWAP_VERSION="${LLAMA_SWAP_VERSION:-latest}"       # Release version
LLAMA_SWAP_FRAGMENT_DIR="${LLAMA_SWAP_FRAGMENT_DIR:-${LLAMA_SWAP_DIR}/conf.d}"  # --config-dir

# ─────────────────────────────────────────────────────────────────────────────
# COMPUTED VALUES
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_DIR="${LLAMA_SWAP_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/llama-swap.service"
CHECK_ONLY=0
FORCE=0
INTERACTIVE=false
GITHUB_REPO="mostlygeek/llama-swap"

# ─────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs llama-swap, a multi-model LLM proxy with hot-swap support, as a
native systemd service. Runs the single Go binary directly on the host.

${BOLD}Options:${RESET}
  --check        Check installation status only (no changes)
  --force        Force reinstall/update without prompts
  --interactive  Prompt before replacing an existing install (default: keep it, exit 0)
  -h, --help     Show this help and exit

  An existing installation is kept by default: binary and config.yaml stay
  untouched, only the unit and the fragment directory are converged.
  --force wins: no prompt, re-installs and updates the binary.

${BOLD}Environment variables${RESET} (all optional):
  LLAMA_SWAP_PORT          Host port for web UI access (default: 9292)
  LLAMA_SWAP_DIR           Host directory for config & data (default: /srv/llama-swap)
  LLAMA_SWAP_HEALTH_TIMEOUT  Health check timeout in seconds (default: 500)
  LLAMA_SWAP_LOG_LEVEL     Log level: debug, info, warn, error (default: info)
  LLAMA_SWAP_START_PORT    Starting port for \${PORT} macro in config (default: 10001)
  LLAMA_SWAP_GLOBAL_TTL    Default model idle TTL in seconds (default: 0 = never)
  LLAMA_SWAP_LISTEN_ADDR   Bind address (default: 0.0.0.0:9292)
  LLAMA_SWAP_USER          Service runtime user (default: root)
  LLAMA_SWAP_BIN_PATH      Binary install path (default: /usr/local/bin/llama-swap)
  LLAMA_SWAP_VERSION       Release version to install (default: latest)
  LLAMA_SWAP_FRAGMENT_DIR  Directory of extra *.yaml config files merged into
                           config.yaml via --config-dir (default: \${LLAMA_SWAP_DIR}/conf.d)
                           Other tasks drop their models here (e.g. setup-comfyui.sh).
EOF
}

# Parse additional flags
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

# Check systemd
if ! command -v systemctl &>/dev/null; then
  error "systemctl is not available. This script requires systemd."
fi

# Check curl
if ! command -v curl &>/dev/null; then
  error "curl is not installed. Required for binary download and health checks."
fi

# Check envsubst
if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
fi

# Check jq (for GitHub API)
if ! command -v jq &>/dev/null; then
  error "jq is not installed. Required for GitHub release detection. Install with: sudo apt-get install jq"
fi

# llama-swap refuses a --config-dir that also contains the --config file.
if [[ "$(realpath -m "$LLAMA_SWAP_FRAGMENT_DIR")" == "$(realpath -m "$CONFIG_DIR")" ]]; then
  error "LLAMA_SWAP_FRAGMENT_DIR must not be ${CONFIG_DIR} — that directory holds config.yaml"
fi

# Warn if not running as root (will use sudo for privileged commands)
if [[ $EUID -ne 0 ]]; then
  warn "Not running as root. Commands requiring root privileges will use sudo."
fi

# No fallback argument: an unsupported architecture must fail this task loudly.
# shellcheck disable=SC2119
LLAMA_SWAP_ARCH="$(detect_arch)"
info "Detected architecture: ${LLAMA_SWAP_ARCH}"

# ─────────────────────────────────────────────────────────────────────────────
# UNIT RENDERING
# ─────────────────────────────────────────────────────────────────────────────

render_unit() {
  export LLAMA_SWAP_USER LLAMA_SWAP_DIR LLAMA_SWAP_BIN_PATH CONFIG_FILE LLAMA_SWAP_LISTEN_ADDR LLAMA_SWAP_FRAGMENT_DIR
  envsubst '${LLAMA_SWAP_USER} ${LLAMA_SWAP_DIR} ${LLAMA_SWAP_BIN_PATH} ${CONFIG_FILE} ${LLAMA_SWAP_LISTEN_ADDR} ${LLAMA_SWAP_FRAGMENT_DIR}' \
    < "${TEMPLATE_DIR}/llama-swap.service"
}

# Converges the unit of an installation that is otherwise kept as it is, so a
# template change (e.g. --config-dir) reaches it without replacing the binary.
converge_existing_unit() {
  local rendered
  # The directory must exist before the unit references it: llama-swap does
  # not start with a missing --config-dir.
  sudo install -d -m 755 "$LLAMA_SWAP_FRAGMENT_DIR"
  rendered="$(mktempfile llama-swap.service)"
  render_unit > "$rendered"
  if cmp -s "$rendered" "$SERVICE_FILE"; then
    rm -f "$rendered"
    success "Service file up to date (${SERVICE_FILE})"
  else
    sudo install -m 644 "$rendered" "$SERVICE_FILE"
    rm -f "$rendered"
    sudo systemctl daemon-reload
    success "Service file updated (${SERVICE_FILE})"
  fi
  # Restart whenever the running process predates the unit file — this also
  # applies an update from an earlier run that did not restart.
  if sudo systemctl is-active --quiet llama-swap && unit_newer_than_service; then
    warn "Restarting llama-swap to apply the unit change — loaded models are unloaded"
    sudo systemctl restart llama-swap
  fi
}

# True when the unit file changed after the running llama-swap was started.
unit_newer_than_service() {
  local started
  started="$(sudo systemctl show -p ActiveEnterTimestamp --value llama-swap)"
  [[ -n "$started" ]] && (( $(stat -c %Y "$SERVICE_FILE") > $(date -d "$started" +%s) ))
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK FOR EXISTING INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for existing llama-swap installation"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ -f "$SERVICE_FILE" ]]; then
    success "systemd service file found at ${SERVICE_FILE}"
    if sudo systemctl is-active llama-swap &>/dev/null; then
      success "Service is currently running."
      sudo systemctl status llama-swap --no-pager
    else
      warn "Service is not running. Start with: sudo systemctl start llama-swap"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
      success "Config file found at ${CONFIG_FILE}"
    else
      warn "Config file not found at ${CONFIG_FILE}"
    fi
    if grep -q -- '--config-dir' "$SERVICE_FILE"; then
      success "Config fragments loaded from ${LLAMA_SWAP_FRAGMENT_DIR}"
    else
      warn "Service file has no --config-dir — re-run this script to add ${LLAMA_SWAP_FRAGMENT_DIR}"
    fi
    if [[ -x "$LLAMA_SWAP_BIN_PATH" ]]; then
      success "Binary found at ${LLAMA_SWAP_BIN_PATH} ($(llama-swap -version 2>/dev/null || echo 'unknown version'))"
    else
      warn "Binary not found at ${LLAMA_SWAP_BIN_PATH}"
    fi
    exit 0
  else
    warn "No existing installation found."
    info "Run without --check to install."
    exit 0
  fi
fi

# Check for existing service
if [[ -f "$SERVICE_FILE" ]]; then
  warn "Existing systemd service file found at ${SERVICE_FILE}."
  echo ""
  info "Existing config at ${CONFIG_FILE} will be PRESERVED (not overwritten)."
  info "The llama-swap binary will be updated to the latest version."
  if [[ "$FORCE" -eq 1 ]]; then
    info "--force flag set — proceeding automatically."
  elif [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Re-install and update binary? [y/N] " answer
    if [[ "${answer,,}" != "y" ]]; then
      info "Keeping existing binary and config.yaml; converging the unit."
      converge_existing_unit
      exit 0
    fi
  else
    info "Non-interactive: keeping existing binary and config.yaml; converging the unit."
    info "Re-run with --interactive to be asked, or --force to re-install and update the binary."
    converge_existing_unit
    exit 0
  fi
  # Stop and disable existing service before re-install
  info "Stopping existing service..."
  # The operator accepted the re-install: from here on the unit is owned by
  # this run, so a later failure must not leave it half-configured running.
  SERVICE_TOUCHED_THIS_RUN=1
  sudo systemctl stop llama-swap 2>/dev/null || true
  sudo systemctl disable llama-swap 2>/dev/null || true
  success "Old service stopped and disabled."
else
  # No existing installation — check port availability
  if ss -tln 2>/dev/null | grep -q ":${LLAMA_SWAP_PORT} " || \
     netstat -tln 2>/dev/null | grep -q ":${LLAMA_SWAP_PORT} "; then
    error "Port ${LLAMA_SWAP_PORT} is already in use. Choose a different LLAMA_SWAP_PORT."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating directories at ${LLAMA_SWAP_DIR}"

sudo mkdir -p "$CONFIG_DIR"
# Must exist before the unit references it (llama-swap fails on a missing --config-dir).
sudo install -d -m 755 "$LLAMA_SWAP_FRAGMENT_DIR"
success "Directories ready."

# ─────────────────────────────────────────────────────────────────────────────
# DOWNLOAD AND INSTALL BINARY
# ─────────────────────────────────────────────────────────────────────────────

step "Downloading llama-swap binary"

SKIP_BINARY_DOWNLOAD=0
if [[ -x "$LLAMA_SWAP_BIN_PATH" ]]; then
  EXISTING_VERSION=$("$LLAMA_SWAP_BIN_PATH" -version 2>/dev/null || echo "unknown")
  info "Existing binary found: ${EXISTING_VERSION}"
  if [[ "$FORCE" -eq 1 ]]; then
    info "--force flag set — proceeding with binary replacement."
  elif [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Re-download and replace binary? [y/N] " answer
    if [[ "${answer,,}" != "y" ]]; then
      info "Keeping existing binary. Skipping download."
      SKIP_BINARY_DOWNLOAD=1
    fi
  else
    info "Non-interactive: keeping existing binary (${LLAMA_SWAP_BIN_PATH})."
    info "Re-run with --interactive to be asked, or --force to update it."
    SKIP_BINARY_DOWNLOAD=1
  fi
fi

if [[ "$SKIP_BINARY_DOWNLOAD" -eq 1 ]]; then
  INSTALLED_VERSION=$("$LLAMA_SWAP_BIN_PATH" -version 2>/dev/null || echo "unknown")
  success "Binary unchanged at ${LLAMA_SWAP_BIN_PATH} (version: ${INSTALLED_VERSION})"
else
  # Determine download URL
  if [[ "$LLAMA_SWAP_VERSION" == "latest" ]]; then
    info "Fetching latest release from GitHub..."
    RELEASE_INFO=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r '.tag_name')
    if [[ -z "$RELEASE_INFO" || "$RELEASE_INFO" == "null" ]]; then
      error "Failed to fetch latest release from GitHub. Check network connectivity."
    fi
    LLAMA_SWAP_VERSION="$RELEASE_INFO"
    info "Latest release: ${LLAMA_SWAP_VERSION}"
  fi

  # Build tarball name: llama-swap_<version_without_v>_linux_<arch>.tar.gz
  VERSION_TAG="${LLAMA_SWAP_VERSION#v}"  # strip leading 'v' if present
  TARBALL_NAME="llama-swap_${VERSION_TAG}_linux_${LLAMA_SWAP_ARCH}.tar.gz"
  DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LLAMA_SWAP_VERSION}/${TARBALL_NAME}"

  info "Downloading from: ${DOWNLOAD_URL}"

  # Download the tar.gz archive to a temp file
  TEMP_TARBALL="$(mktemp /tmp/llama-swap-download.XXXXXX.tar.gz)"
  if ! curl -fsSL --retry 3 --retry-delay 5 -o "$TEMP_TARBALL" "$DOWNLOAD_URL"; then
    error "Failed to download binary archive from ${DOWNLOAD_URL}"
  fi

  # Extract the binary from the archive
  TEMP_EXTRACT_DIR="$(mktemp -d /tmp/llama-swap-extract.XXXXXX)"
  if ! tar -xzf "$TEMP_TARBALL" -C "$TEMP_EXTRACT_DIR"; then
    error "Failed to extract binary archive from ${TEMP_TARBALL}"
  fi

  # Find the extracted binary (it may be named llama-swap inside the tarball)
  TEMP_BIN="$(find "$TEMP_EXTRACT_DIR" -name 'llama-swap' -type f | head -1)"
  if [[ -z "$TEMP_BIN" ]]; then
    error "Could not find 'llama-swap' binary inside extracted archive. Contents:"
    ls -laR "$TEMP_EXTRACT_DIR"
  fi

  # Verify it's a valid ELF binary
  if ! file "$TEMP_BIN" | grep -q "ELF"; then
    error "Extracted file is not a valid ELF binary. Possible corrupted download."
  fi

  # Install to target path
  if [[ -x "$LLAMA_SWAP_BIN_PATH" ]]; then
    info "Replacing existing binary at ${LLAMA_SWAP_BIN_PATH}"
  fi

  sudo install -m 755 "$TEMP_BIN" "$LLAMA_SWAP_BIN_PATH"

  # Cleanup temp files
  rm -f "$TEMP_TARBALL"
  rm -rf "$TEMP_EXTRACT_DIR"

  INSTALLED_VERSION=$("$LLAMA_SWAP_BIN_PATH" -version 2>/dev/null || echo "unknown")
  success "Binary installed at ${LLAMA_SWAP_BIN_PATH} (version: ${INSTALLED_VERSION})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE CONFIG.YAML FROM TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${CONFIG_FILE}"

if [[ -f "$CONFIG_FILE" ]]; then
  info "Config file already exists at ${CONFIG_FILE}. Skipping generation to preserve existing configuration."
  info "Edit ${CONFIG_FILE} manually if you need to update settings."
else
  export LLAMA_SWAP_HEALTH_TIMEOUT LLAMA_SWAP_LOG_LEVEL LLAMA_SWAP_START_PORT LLAMA_SWAP_GLOBAL_TTL

  envsubst '${LLAMA_SWAP_HEALTH_TIMEOUT} ${LLAMA_SWAP_LOG_LEVEL} ${LLAMA_SWAP_START_PORT} ${LLAMA_SWAP_GLOBAL_TTL}' \
    < "${TEMPLATE_DIR}/config.yaml" \
    | sudo tee "$CONFIG_FILE" > /dev/null

  sudo chmod 644 "$CONFIG_FILE"
  success "Config file created with all available options documented."
  info "Edit ${CONFIG_FILE} to customize model configurations."
fi

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE AND INSTALL SYSTEMD SERVICE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating systemd service file"

render_unit | sudo tee "$SERVICE_FILE" > /dev/null

sudo chmod 644 "$SERVICE_FILE"
success "Service file installed at ${SERVICE_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# RELOAD SYSTEMD AND START SERVICE
# ─────────────────────────────────────────────────────────────────────────────

step "Reloading systemd daemon"

sudo systemctl daemon-reload
success "Daemon reloaded."

step "Starting llama-swap service"

# This run now owns the unit: a failure from here on may stop/disable it.
SERVICE_TOUCHED_THIS_RUN=1
sudo systemctl enable llama-swap
sudo systemctl start llama-swap
success "Service started and enabled."

# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR HEALTH CHECK
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for llama-swap to respond"

MAX_WAIT=120
INTERVAL=5
ELAPSED=0
READY=false

ACCESS_URL="http://localhost:${LLAMA_SWAP_PORT}/health"

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$ACCESS_URL" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    READY=true
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ... (HTTP ${HTTP_CODE})"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

if [[ "$READY" == "true" ]]; then
  success "llama-swap is up and responding!"
  SERVICE_TOUCHED_THIS_RUN=0   # proven healthy -> a later failure must not stop the service
else
  warn "llama-swap did not respond within ${MAX_WAIT}s."
  warn "Check service status and logs:"
  warn "  systemctl status llama-swap"
  warn "  journalctl -u llama-swap -n 50"
fi

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE CLEANUP TRAP ON SUCCESS
# ─────────────────────────────────────────────────────────────────────────────

trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  llama-swap setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""

echo -e "  ${BOLD}Web UI${RESET}            http://localhost:${LLAMA_SWAP_PORT}/ui"
echo -e "  ${BOLD}OpenAI API${RESET}        http://localhost:${LLAMA_SWAP_PORT}/v1/chat/completions"
echo -e "  ${BOLD}Health check${RESET}      http://localhost:${LLAMA_SWAP_PORT}/health"
echo -e "  ${BOLD}Running models${RESET}    http://localhost:${LLAMA_SWAP_PORT}/running"
echo -e "  ${BOLD}Config file${RESET}       ${CONFIG_FILE}"
echo -e "  ${BOLD}Config fragments${RESET}  ${LLAMA_SWAP_FRAGMENT_DIR}"
echo -e "  ${BOLD}Service file${RESET}      ${SERVICE_FILE}"
echo -e "  ${BOLD}Binary${RESET}            ${LLAMA_SWAP_BIN_PATH} (${INSTALLED_VERSION})"
echo -e "  ${BOLD}Listen address${RESET}    ${LLAMA_SWAP_LISTEN_ADDR}"
echo -e "  ${BOLD}Runtime user${RESET}      ${LLAMA_SWAP_USER}"

echo ""
echo -e "${YELLOW}  Next steps:${RESET}"
echo -e "  1. Edit ${CONFIG_FILE} to add your model configurations."
echo -e "  2. Restart the service: sudo systemctl restart llama-swap"
echo -e "  3. Test with: curl http://localhost:${LLAMA_SWAP_PORT}/v1/models"

echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Start:          sudo systemctl start llama-swap"
echo -e "  Stop:           sudo systemctl stop llama-swap"
echo -e "  Restart:        sudo systemctl restart llama-swap"
echo -e "  Enable on boot: sudo systemctl enable llama-swap"
echo -e "  Status:         sudo systemctl status llama-swap"
echo -e "  Follow logs:    sudo journalctl -u llama-swap -f"
echo -e "  Recent logs:    sudo journalctl -u llama-swap --no-pager -n 50"
echo -e "  Check status:   $0 --check"

echo ""
echo -e "${YELLOW}  Note:${RESET}"
echo -e "  The config.yaml contains a comprehensive example with ALL available"
echo -e "  options documented. Uncomment and customize sections as needed."

echo ""
info "llama-swap is now running as a systemd service. Add models to config.yaml and restart to load them."
