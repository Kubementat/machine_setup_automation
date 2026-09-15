#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-opencode.sh — Install Opencode AI Coding Agent
# =============================================================================
#
# Description:
#   Installs the Opencode CLI by default (npm). Optionally installs the
#   "opencode" systemd service (OPENCODE_SERVICE=true) or deploys the
#   Opencode server as a Docker Compose stack (USE_DOCKER=true).
#   The CLI install initializes the user-level config file
#   (~/.config/opencode/opencode.json) as {} when it does not exist yet.
#
# Environment Variables:
#   OPENCODE_SERVICE         - Install the opencode systemd service (default: false)
#   USE_DOCKER               - Use Docker Compose mode (default: false)
#   OPENCODE_PORT            - Server port (default: 4096)
#   OPENCODE_HOSTNAME        - Bind address (default: 0.0.0.0; alias: OPENCODE_HOST)
#   OPENCODE_SERVER_USERNAME - Auth username (default: admin)
#   OPENCODE_SERVER_PASSWORD - Auth password (auto-generated if empty)
#   OPENCODE_DATA_DIR        - Data directory (default: /srv/opencode)
#   OPENCODE_TRAEFIK         - Enable Traefik (default: false)
#   OPENCODE_DOMAIN          - Public domain for Traefik routing (required when OPENCODE_TRAEFIK=true)
#   PROXY_NETWORK            - Traefik Docker network (default: proxy)
#   OPENCODE_IMAGE           - Opencode image (default: ghcr.io/anomalyco/opencode:1.18.25, pinned)
#   WAIT_TIMEOUT             - Max seconds to wait for the stack to become healthy (default: 180)
#
# Usage:
#   ./setup-opencode.sh                        # CLI only (default)
#   OPENCODE_SERVICE=true ./setup-opencode.sh  # CLI + systemd service
#   USE_DOCKER=true ./setup-opencode.sh        # Docker Compose stack
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/opencode-server"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

SERVICE_NAME="opencode"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

load_config() {
    OPENCODE_SERVICE="${OPENCODE_SERVICE:-false}"
    USE_DOCKER="${USE_DOCKER:-false}"
    OPENCODE_PORT="${OPENCODE_PORT:-4096}"
    OPENCODE_HOSTNAME="${OPENCODE_HOSTNAME:-${OPENCODE_HOST:-0.0.0.0}}"
    OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-admin}"
    OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-}"
    DATA_DIR="${OPENCODE_DATA_DIR:-/srv/opencode}"
    OPENCODE_TRAEFIK="${OPENCODE_TRAEFIK:-false}"
    OPENCODE_DOMAIN="${OPENCODE_DOMAIN:-}"
    PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
    # Pinned on purpose (ticket improvements-2/17): `:latest` made the generated
    # docker-compose.yml pull a moving reference. Default looked up 2026-08-31
    # from https://github.com/anomalyco/opencode/releases (latest release
    # v1.18.25; the GHCR tag carries no leading 'v').
    # Update deliberately: docker buildx imagetools inspect ghcr.io/anomalyco/opencode
    OPENCODE_IMAGE="${OPENCODE_IMAGE:-ghcr.io/anomalyco/opencode:1.18.25}"
    warn_moving_image "${OPENCODE_IMAGE}" "OPENCODE_IMAGE"
}

print_config() {
    local mode
    if [[ "$USE_DOCKER" == "true" ]]; then
        mode="docker"
    elif [[ "$OPENCODE_SERVICE" == "true" ]]; then
        mode="cli + systemd service"
    else
        mode="cli only"
    fi

    echo "Opencode Configuration:"
    echo "  Mode:                     $mode"
    if [[ "$USE_DOCKER" == "true" ]]; then
        echo "  OPENCODE_PORT:            $OPENCODE_PORT"
        echo "  OPENCODE_SERVER_USERNAME: $OPENCODE_SERVER_USERNAME"
        echo "  OPENCODE_SERVER_PASSWORD: ${OPENCODE_SERVER_PASSWORD:+*** (set)}"
        echo "  DATA_DIR:                 $DATA_DIR"
        if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
            echo "  OPENCODE_DOMAIN:          ${OPENCODE_DOMAIN:-(required for Traefik)}"
            echo "  PROXY_NETWORK:            $PROXY_NETWORK"
        fi
    else
        echo "  OPENCODE_SERVICE:         $OPENCODE_SERVICE"
        if [[ "$OPENCODE_SERVICE" == "true" ]]; then
            echo "  OPENCODE_PORT:            $OPENCODE_PORT"
            echo "  OPENCODE_HOSTNAME:        $OPENCODE_HOSTNAME"
            echo "  OPENCODE_SERVER_USERNAME: $OPENCODE_SERVER_USERNAME"
            echo "  OPENCODE_SERVER_PASSWORD: ${OPENCODE_SERVER_PASSWORD:+*** (set)}"
        fi
    fi
    echo "--------------------------------"
}

maybe_generate_password() {
    if [[ -n "$OPENCODE_SERVER_PASSWORD" ]]; then
        return
    fi

    # Re-read persisted credentials so re-runs never rotate secrets a
    # running service or volume depends on (specification/project/conventions.md).
    if [[ "$USE_DOCKER" == "true" ]]; then
        # .env is root-owned mode 600 — read it with sudo (env_file_get cannot
        # read it as the invoking user, which would silently rotate the secret).
        local env_file="${DATA_DIR}/.env"
        if [[ -f "$env_file" ]]; then
            OPENCODE_SERVER_USERNAME="$(sudo sed -n 's/^[[:space:]]*OPENCODE_SERVER_USERNAME=//p' "$env_file" 2>/dev/null | tail -n1 || true)"
            OPENCODE_SERVER_PASSWORD="$(sudo sed -n 's/^[[:space:]]*OPENCODE_SERVER_PASSWORD=//p' "$env_file" 2>/dev/null | tail -n1 || true)"
        fi
    elif [[ "$OPENCODE_SERVICE" == "true" ]] && [[ -f "$SERVICE_FILE" ]]; then
        OPENCODE_SERVER_USERNAME="$(sed -n 's/^Environment="OPENCODE_SERVER_USERNAME=\(.*\)"$/\1/p' "$SERVICE_FILE" | tail -n1)"
        OPENCODE_SERVER_PASSWORD="$(sed -n 's/^Environment="OPENCODE_SERVER_PASSWORD=\(.*\)"$/\1/p' "$SERVICE_FILE" | tail -n1)"
    fi
    OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-admin}"

    if [[ -n "$OPENCODE_SERVER_PASSWORD" ]]; then
        info "Reusing existing Opencode server credentials."
        return
    fi

    step "Generating secure random password..."
    OPENCODE_SERVER_PASSWORD=$(openssl rand -base64 32)

    echo ""
    echo "=============================================="
    echo "IMPORTANT: Generated Opencode Server Password"
    echo "=============================================="
    echo ""
    echo "Username: $OPENCODE_SERVER_USERNAME"
    echo "Password: $OPENCODE_SERVER_PASSWORD"
    echo ""
    echo "Please save this password securely. It will not be displayed again."
    echo "You can set OPENCODE_SERVER_PASSWORD environment variable to reuse it."
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures (docker mode)
# ─────────────────────────────────────────────────────────────────────────────

# Set to 1 immediately BEFORE 'up -d' and reset to 0 once the stack is proven
# healthy. The trap tears the stack down only while this flag is set, so a late
# failure (health gate, ufw, .env write) cannot stop a stack that was already
# running before this script was invoked.
STACK_CREATED_THIS_RUN=0

cleanup_on_failure() {
    local exit_code=$?
    (( exit_code == 0 )) && return 0
    if (( STACK_CREATED_THIS_RUN != 1 )); then
        warn "Setup failed (exit code: ${exit_code}). No stack was started by this run — nothing torn down."
        return 0
    fi
    echo ""
    warn "Setup failed (exit code: ${exit_code})! Removing the stack created by this run..."
    if [[ -d "${DATA_DIR:-}" ]] && cd "$DATA_DIR" 2>/dev/null; then
        if [[ -n "$(sudo docker compose ps -q 2>/dev/null || true)" ]]; then
            sudo docker compose down --remove-orphans 2>/dev/null || true
            info "Removed partially created stack."
        else
            info "Stack from this run is already stopped — data volume (opencode_data) is preserved."
        fi
    fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

preflight_cli() {
    step "Running pre-flight checks (CLI mode)"

    if ! command -v sudo &>/dev/null; then
        error "sudo is not installed."
    fi
    if ! command -v npm &>/dev/null && ! command -v apt &>/dev/null; then
        error "npm is not installed and apt is unavailable. Install Node.js/npm or set up the basics first (tasks/setup-basics.sh)."
    fi
    success "Pre-flight checks passed."
}

preflight_docker() {
    step "Running pre-flight checks (Docker mode)"

    if ! command -v docker &>/dev/null; then
        error "Docker is not installed or not in PATH. Run setup-docker.sh first."
    fi

    if ! sudo docker info &>/dev/null; then
        error "Docker daemon is not running. Start it with: sudo systemctl start docker"
    fi

    success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

    if [[ -z "$OPENCODE_SERVER_PASSWORD" ]] && ! command -v openssl &>/dev/null; then
        error "openssl is not installed. Required for generating secure password. Install it or set OPENCODE_SERVER_PASSWORD manually."
    fi

    if ! command -v envsubst &>/dev/null; then
        error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
    fi

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        _preflight_traefik
    fi
}

_preflight_traefik() {
    if ! ensure_proxy_network; then
        warn "Traefik proxy network '${PROXY_NETWORK}' not found or inaccessible."
        warn "If you want Traefik integration, run setup-traefik.sh first."
        warn "Continuing in direct-access mode..."
        OPENCODE_TRAEFIK="false"
        return
    fi

    if [[ -z "$OPENCODE_DOMAIN" ]]; then
        error "OPENCODE_DOMAIN must be set when OPENCODE_TRAEFIK=true (e.g., opencode.example.com)."
    fi
}

preflight_systemd() {
    step "Running pre-flight checks (systemd mode)"

    if ! command -v openssl &>/dev/null; then
        warn "openssl not found. Generating password may fail, or set OPENCODE_SERVER_PASSWORD manually."
    fi

    if ! command -v envsubst &>/dev/null; then
        error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI INSTALL (npm)
# ─────────────────────────────────────────────────────────────────────────────

install_opencode_cli() {
    step "Installing/Updating Opencode CLI..."

    if ! command -v npm &>/dev/null; then
        info "npm is not installed. Installing Node.js and npm..."
        sudo apt update
        sudo apt install -y nodejs npm
    fi

    if command -v opencode &>/dev/null; then
        info "Opencode CLI already installed at $(which opencode). Updating to latest version..."
    else
        info "Installing opencode globally via npm..."
    fi

    sudo npm install -g opencode-ai --force

    if ! opencode --version &>/dev/null; then
        warn "Opencode CLI installation verification failed, but continuing..."
    fi

    success "Opencode CLI installed/updated successfully."

    # Ensure the user-level config file (config + provider/model definitions)
    # exists; initialize it as {} when missing. Tools that merge models into
    # it (e.g. tasks/sync-models.py) require the file to exist.
    step "Ensuring Opencode config file exists"
    local opencode_config="${HOME}/.config/opencode/opencode.json"
    if [[ ! -f "${opencode_config}" ]]; then
        mkdir -p "$(dirname "${opencode_config}")"
        echo '{}' > "${opencode_config}"
        info "Initialized ${opencode_config}"
    else
        info "Already present: ${opencode_config}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER MODE
# ─────────────────────────────────────────────────────────────────────────────

_generate_compose_file() {
    local compose_file="$1"
    local compose_template

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        compose_template="${TEMPLATE_DIR}/docker-compose.traefik.yml"
    else
        compose_template="${TEMPLATE_DIR}/docker-compose.direct.yml"
    fi

    GENERATED_DATE="$(date -Iseconds)"
    export GENERATED_DATE OPENCODE_PORT PROXY_NETWORK OPENCODE_DOMAIN OPENCODE_IMAGE
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${GENERATED_DATE} ${OPENCODE_PORT} ${PROXY_NETWORK} ${OPENCODE_DOMAIN} ${OPENCODE_IMAGE}' \
        < "$compose_template" | sudo tee "$compose_file" > /dev/null
}

_generate_env_file() {
    local env_file="${DATA_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        warn "Existing .env file found. Backing up to ${env_file}.bak"
        sudo cp "$env_file" "${env_file}.bak"
    fi

    export OPENCODE_SERVER_USERNAME OPENCODE_SERVER_PASSWORD
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${OPENCODE_SERVER_USERNAME} ${OPENCODE_SERVER_PASSWORD}' \
        < "${TEMPLATE_DIR}/env.template" | sudo tee "$env_file" > /dev/null

    sudo chmod 600 "$env_file"
    success "Secrets stored securely in .env file (mode: 600)."
}

_generate_start_script() {
    sudo cp "${TEMPLATE_DIR}/start_opencode.sh" "${DATA_DIR}/start_opencode.sh"
    sudo chmod +x "${DATA_DIR}/start_opencode.sh"
    success "start_opencode.sh created."
}

_wait_for_opencode_docker() {
    step "Waiting for Opencode to respond"

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        info "Traefik mode: skipping direct health check (TLS access at https://${OPENCODE_DOMAIN})"
        info "Container will be accessible once DNS resolves and TLS is provisioned."
        return 0
    fi

    local access_url="http://localhost:${OPENCODE_PORT}"
    local max_wait=120 interval=5 elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "$access_url" | grep -qE "^(200|302|303|401)"; then
            echo ""
            success "Opencode is up and responding!"
            return 0
        fi
        echo -ne "\r    Waited ${elapsed}s / ${max_wait}s ..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    warn "Opencode did not respond within ${max_wait}s."
    warn "It may still be starting. Check logs with: docker compose logs -f"
}

# Opens OPENCODE_PORT for direct (non-Traefik) server access. Traefik owns
# the public edge in proxy mode, so no direct rule is added there.
_configure_ufw() {
    ufw_firewall_section "opencode" "$OPENCODE_PORT" tcp "OPENCODE"
}

setup_docker() {
    local compose_file="${DATA_DIR}/docker-compose.yml"

    sudo mkdir -p "$DATA_DIR"

    step "Generating ${compose_file}"
    _generate_compose_file "$compose_file"
    success "docker-compose.yml created."

    step "Generating ${DATA_DIR}/.env"
    _generate_env_file

    step "Creating start script"
    _generate_start_script

    step "Pulling Docker images"
    cd "$DATA_DIR"
    sudo docker compose pull
    success "Images pulled."

    step "Starting Opencode stack (detached)"
    STACK_CREATED_THIS_RUN=1
    sudo docker compose up -d

    # Health gate: prove the containers are actually up before reporting
    # success (on failure the EXIT trap tears the stack down while the
    # STACK_CREATED_THIS_RUN flag is set).
    mapfile -t _ids < <(sudo docker compose ps -q)
    wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
      || error "Opencode stack did not come up — see the status output above"
    STACK_CREATED_THIS_RUN=0     # proven healthy -> a later failure must not tear it down

    _wait_for_opencode_docker
    if [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        _configure_ufw
    fi

    trap - EXIT
}

summary_docker() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Opencode Server (Docker) setup complete!${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        echo -e "  ${BOLD}Web UI (Traefik)${RESET}   https://${OPENCODE_DOMAIN}"
        echo -e "  ${BOLD}TLS${RESET}                Enabled via Let's Encrypt"
    else
        echo -e "  ${BOLD}Web UI${RESET}             http://localhost:${OPENCODE_PORT}"
    fi

    echo ""
    echo -e "  ${BOLD}Data directory${RESET}     Persistent volume (opencode_data)"
    echo -e "  ${BOLD}Compose file${RESET}       ${DATA_DIR}/docker-compose.yml"
    echo -e "  ${BOLD}Environment file${RESET}   ${DATA_DIR}/.env"

    if [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        echo ""
        echo -e "${YELLOW}  Note:${RESET}"
        echo -e "  - OPENCODE_SERVER_PASSWORD is stored in .env (not exposed in docker-compose.yml)"
        echo -e "  - To use a custom password, set OPENCODE_SERVER_PASSWORD before running this script"
    fi

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}Traefik-specific commands:${RESET}"
        echo -e "  Check access logs:  docker logs traefik | grep ${OPENCODE_DOMAIN}"
        echo -e "  Verify DNS:         dig ${OPENCODE_DOMAIN}"
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${RESET}"
    echo -e "  Start:        ./start_opencode.sh"
    echo -e "  Stop:         docker compose down"
    echo -e "  Restart:      docker compose restart"
    echo -e "  Follow logs:  docker compose logs -f"
    echo -e "  Shell into:   docker exec -it ${SERVICE_NAME} bash"

    if [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        echo ""
        echo -e "${BOLD}Security Notice:${RESET}"
        echo -e "  Your OPENCODE_SERVER_PASSWORD is stored in .env (mode: 600)."
        echo -e "  Do not share this file or expose it without TLS protection."
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEMD MODE
# ─────────────────────────────────────────────────────────────────────────────

_write_service_file() {
    if [[ -f "$SERVICE_FILE" ]]; then
        info "Service file $SERVICE_FILE already exists. Skipping write."
        return
    fi

    export USER HOME OPENCODE_SERVER_USERNAME OPENCODE_SERVER_PASSWORD \
        OPENCODE_HOSTNAME OPENCODE_PORT
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${USER} ${HOME} ${OPENCODE_SERVER_USERNAME} ${OPENCODE_SERVER_PASSWORD} ${OPENCODE_HOSTNAME} ${OPENCODE_PORT}' \
        < "${TEMPLATE_DIR}/${SERVICE_NAME}.service" | sudo tee "$SERVICE_FILE" > /dev/null
    success "Service file written to $SERVICE_FILE"
}

_test_health_endpoint() {
    if [[ "$OPENCODE_HOSTNAME" == "127.0.0.1" || "$OPENCODE_HOSTNAME" == "localhost" ]]; then
        return
    fi

    info "Testing health endpoint..."
    sleep 3
    if command -v curl &>/dev/null; then
        curl -s --user "${OPENCODE_SERVER_USERNAME}:${OPENCODE_SERVER_PASSWORD}" \
            "http://$OPENCODE_HOSTNAME:$OPENCODE_PORT/global/health" || true
    fi
}

setup_systemd() {
    step "Creating systemd service file"
    _write_service_file

    step "Reloading systemd daemon"
    sudo systemctl daemon-reload
    success "Systemd daemon reloaded."

    step "Enabling ${SERVICE_NAME}.service"
    sudo systemctl enable "${SERVICE_NAME}.service"
    success "Service enabled (will start on boot)."

    step "Starting/restarting ${SERVICE_NAME}.service"
    if sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        info "Service is running. Restarting to apply changes..."
        sudo systemctl restart "${SERVICE_NAME}.service"
    else
        info "Service not running. Starting..."
        sudo systemctl start "${SERVICE_NAME}.service"
    fi
    success "Opencode service started/restarted successfully."

    _configure_ufw
    _test_health_endpoint
}

summary_systemd() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Opencode Server (systemd) setup complete!${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Web UI${RESET}   http://${OPENCODE_HOSTNAME}:${OPENCODE_PORT}"
    echo ""
    echo -e "${BOLD}${CYAN}Admin credentials:${RESET}"
    echo -e "  Username: $OPENCODE_SERVER_USERNAME"
    if [[ -n "$OPENCODE_SERVER_PASSWORD" ]]; then
        echo -e "  Password: *** (configured)"
    else
        echo -e "  Password: *** (auto-generated on first run via env vars)"
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${RESET}"
    echo -e "  Status:       sudo systemctl status ${SERVICE_NAME}"
    echo -e "  Start:        sudo systemctl start ${SERVICE_NAME}"
    echo -e "  Stop:         sudo systemctl stop ${SERVICE_NAME}"
    echo -e "  Restart:      sudo systemctl restart ${SERVICE_NAME}"
    echo -e "  Logs:         sudo journalctl -u ${SERVICE_NAME} -f"

    echo ""
    echo -e "${BOLD}Security Notice:${RESET}"
    echo -e "  Environment variables are stored in the systemd service file."
    echo -e "  View with: sudo systemctl cat ${SERVICE_NAME}"
    echo ""
}

summary_cli() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Opencode CLI setup complete!${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Version${RESET}  $(opencode --version 2>/dev/null || echo 'unknown')"
    echo ""
    echo -e "${BOLD}Useful commands:${RESET}"
    echo -e "  Run interactively:  opencode"
    echo -e "  Start server:       opencode serve --hostname 0.0.0.0 --port ${OPENCODE_PORT}"
    echo -e "  Install the systemd service:"
    echo -e "                     OPENCODE_SERVICE=true ./setup-opencode.sh"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────

uninstall_cli() {
    step "Uninstalling Opencode CLI"

    if command -v npm &>/dev/null; then
        info "Removing opencode-ai npm package..."
        sudo npm uninstall -g opencode-ai
        success "Opencode CLI removed."
    else
        warn "npm not found. Nothing to remove."
    fi

    success "Opencode CLI uninstalled."
}

uninstall_docker() {
    step "Uninstalling Opencode Server (Docker mode)"

    if [[ -f "${DATA_DIR}/docker-compose.yml" ]]; then
        info "Stopping and removing Docker stack..."
        cd "$DATA_DIR"
        sudo docker compose down --remove-orphans
        success "Docker stack removed."
    else
        warn "No docker-compose.yml found in ${DATA_DIR}. Skipping stack teardown."
    fi

    if [[ -d "$DATA_DIR" ]]; then
        info "Removing data directory ${DATA_DIR}..."
        sudo rm -rf "$DATA_DIR"
        success "Data directory removed."
    fi

    if ufw_available && [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        step "Removing UFW firewall rule for port ${OPENCODE_PORT}"
        ufw_delete_rule "$OPENCODE_PORT" "tcp"
    fi

    success "Opencode Server (Docker) uninstalled."
}

uninstall_systemd() {
    step "Uninstalling Opencode Server (systemd mode)"

    if sudo systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        info "Stopping ${SERVICE_NAME}.service..."
        sudo systemctl stop "${SERVICE_NAME}.service"
        success "Service stopped."
    fi

    if sudo systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        info "Disabling ${SERVICE_NAME}.service..."
        sudo systemctl disable "${SERVICE_NAME}.service"
        success "Service disabled."
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        info "Removing service file ${SERVICE_FILE}..."
        sudo rm "$SERVICE_FILE"
        sudo systemctl daemon-reload
        success "Service file removed and daemon reloaded."
    else
        warn "Service file ${SERVICE_FILE} not found. Already removed?"
    fi

    if ufw_available; then
        step "Removing UFW firewall rule for port ${OPENCODE_PORT}"
        ufw_delete_rule "$OPENCODE_PORT" "tcp"
    fi

    success "Opencode Server (systemd) uninstalled."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: setup-opencode.sh [--help] [--uninstall]

Installs the Opencode AI coding agent.
By default only the CLI is installed (npm). The systemd service and the
Docker Compose stack are opt-in via environment variables.
All configuration is provided via environment variables.

GENERAL OPTIONS
  OPENCODE_PORT                Port to bind the server to.
                               Default: 4096
  OPENCODE_SERVER_USERNAME     Username for HTTP basic auth (server modes).
                               Default: admin
  OPENCODE_SERVER_PASSWORD     Password for HTTP basic auth (server modes).
                               Default: auto-generated (printed once at startup)

INSTALL MODES
  OPENCODE_SERVICE             Set to "true" to install the "opencode" systemd
                               service (in addition to the CLI).
                               Default: false (CLI only)
  USE_DOCKER                   Set to "true" to use Docker Compose deployment
                               instead of the CLI/systemd install.
                               Default: false

DOCKER MODE OPTIONS            (only used when USE_DOCKER=true)
  OPENCODE_DATA_DIR            Host directory for Docker Compose files and .env.
                               Default: /srv/opencode
  OPENCODE_IMAGE               Image used by the generated docker-compose.yml.
                               Pinned by default; override with an explicit
                               version tag, not a moving tag.
                               Default: ghcr.io/anomalyco/opencode:1.18.25
  WAIT_TIMEOUT                 Max seconds to wait for the stack to come up and
                               become healthy after 'docker compose up -d'.
                               Default: 180

SYSTEMD MODE OPTIONS           (only used when OPENCODE_SERVICE=true)
  OPENCODE_HOSTNAME            Hostname/IP to bind the server to.
                               Default: 0.0.0.0 (alias: OPENCODE_HOST)

TRAEFIK OPTIONS                (only used when USE_DOCKER=true)
  OPENCODE_TRAEFIK             Set to "true" to enable Traefik reverse proxy integration.
                               Default: false
  OPENCODE_DOMAIN              Public domain name for Traefik routing.
                               Required when OPENCODE_TRAEFIK=true
                               Example: opencode.example.com
  PROXY_NETWORK                Name of the external Docker network Traefik listens on.
                               Default: proxy

PRIVILEGES
  Run as your normal user — the script escalates with sudo internally where
  needed (npm/apt installs, /srv/opencode, systemd, ufw, docker).

NOTES
  The CLI install ensures the user-level config file
  (~/.config/opencode/opencode.json) exists, initializing it to {} when
  missing, so model-sync tooling can merge into it.

EXAMPLES
  # CLI only (default):
  ./setup-opencode.sh

  # CLI + systemd service with explicit password:
  OPENCODE_SERVICE=true OPENCODE_SERVER_PASSWORD=mysecret ./setup-opencode.sh

  # Docker mode with Traefik:
  USE_DOCKER=true OPENCODE_TRAEFIK=true OPENCODE_DOMAIN=opencode.example.com \
    ./setup-opencode.sh

  # Docker mode, direct port binding:
  USE_DOCKER=true OPENCODE_PORT=4096 ./setup-opencode.sh

  # Uninstall (CLI, default):
  ./setup-opencode.sh --uninstall

  # Uninstall (systemd service):
  OPENCODE_SERVICE=true ./setup-opencode.sh --uninstall

  # Uninstall (Docker mode):
  USE_DOCKER=true ./setup-opencode.sh --uninstall
EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    load_config

    if [[ "${1:-}" == "--uninstall" ]]; then
        if [[ "$USE_DOCKER" == "true" ]]; then
            uninstall_docker
        elif [[ "$OPENCODE_SERVICE" == "true" ]]; then
            uninstall_systemd
        else
            uninstall_cli
        fi
        exit 0
    fi

    print_config

    if [[ "$USE_DOCKER" == "true" ]]; then
        maybe_generate_password
        preflight_docker
        setup_docker
        summary_docker
    else
        preflight_cli
        install_opencode_cli
        if [[ "$OPENCODE_SERVICE" == "true" ]]; then
            maybe_generate_password
            preflight_systemd
            setup_systemd
            summary_systemd
        else
            summary_cli
        fi
    fi
}

main "$@"
