#!/usr/bin/env bash
# shellcheck disable=SC2086,SC1091
# =============================================================================
# Nextcloud Docker Setup Script
# =============================================================================
#
# DESCRIPTION:
#   Automated setup of a production-grade Nextcloud stack using Docker
#   Compose: nextcloud:34-apache + PostgreSQL + authenticated Redis
#   (distributed cache + transactional file locking) + a cron sidecar.
#   Access via the shared Traefik reverse proxy (NEXTCLOUD_TRAEFIK=true) or
#   a directly published LAN port (default). Compose is rendered from
#   templates/nextcloud/ — never generated inline.
#
#   This script is PostgreSQL-only. Existing MariaDB/SQLite installs are
#   detected and refused up-front (migrate via Nextcloud's own tooling or
#   pin the previous script revision).
#
# KEY ACTIONS:
#   1. Pre-flight checks: Docker, Compose v2, openssl, envsubst, backend
#      compat guard (no MariaDB/SQLite installs), ufw/port sanity
#   2. Reuses a running stack (converge-by-default); --interactive offers a
#      tear-down/re-create
#   3. Creates persistent storage directories on the host (/srv/nextcloud)
#   4. Writes secrets (.env, mode 600) — never stored in compose config;
#      re-runs reuse the stored values (a persisted DB volume depends on
#      them, so secrets are NEVER rotated)
#   5. Renders docker-compose.yml from templates/nextcloud/ (traefik or
#      direct variant; secrets stay literal ${VAR} resolved from .env)
#   6. Pulls images, starts the stack, proves health (wait_for_healthy) and
#      install-readiness (status.php "installed":true)
#   7. Post-install occ hardening pass (memcache.*, phone region,
#      maintenance window, loglevel, missing indices, bigint filecache)
#   8. UFW rule (LAN mode only — Traefik mode publishes no ports)
#   9. Displays access information and useful management commands
#
# IMPORTANT VARIABLES (full list in --help):
#   NEXTCLOUD_HOME          - Host directory for persistent data (default: /srv/nextcloud)
#   NEXTCLOUD_IMAGE         - App image, shared by app+cron (default:
#                             nextcloud:34-apache, pinned — update
#                             deliberately ONE major at a time)
#   NEXTCLOUD_DB_IMAGE      - PostgreSQL image (default: postgres:17-alpine;
#                             follows db/PG_VERSION of an existing install)
#   NEXTCLOUD_REDIS_IMAGE   - Redis image       (default: redis:7-alpine)
#   CONTAINER_NAME          - App container name (default: nextcloud; keep
#                             it for the backup dispatcher: it dumps
#                             nextcloud / nextcloud-db and matches them only
#                             via its own NEXTCLOUD_CONTAINER var)
#   HTTP_PORT               - Host port, LAN mode   (default: 8080)
#   NEXTCLOUD_LAN_BIND      - Optional bind IP for the published port
#   NEXTCLOUD_TRAEFIK       - "true" = Traefik mode (default: false = LAN mode)
#   NEXTCLOUD_DOMAIN        - Domain for Traefik access (required with Traefik)
#   PROXY_NETWORK           - Traefik's external Docker network (default: proxy)
#   POSTGRES_* / NEXTCLOUD_ADMIN_* / REDIS_HOST_PASSWORD - credentials,
#                             secrets auto-generated once, read back from .env
#   WAIT_TIMEOUT            - Seconds for health gate + status.php poll
#                             (default: 300)
#
# DEPENDENCIES:
#   - Docker: Must be installed and daemon must be running
#   - Docker Compose v2+
#   - openssl (secret generation), envsubst (gettext-base, template rendering)
#   - Traefik instance with proxy network (when NEXTCLOUD_TRAEFIK=true)
#
# OUTPUTS:
#   - ${NEXTCLOUD_HOME}/docker-compose.yml  - Rendered compose configuration
#   - ${NEXTCLOUD_HOME}/.env                - Secrets / credentials (mode 600)
#   - ${NEXTCLOUD_HOME}/html/               - Nextcloud web root (persistent)
#   - ${NEXTCLOUD_HOME}/data/               - User data directory (persistent)
#   - ${NEXTCLOUD_HOME}/db/                 - PostgreSQL data (persistent)
#   - containers: nextcloud, nextcloud-db, nextcloud-redis, nextcloud-cron
#
# USAGE:
#   ./setup-nextcloud.sh                                     # LAN mode
#   NEXTCLOUD_TRAEFIK=true NEXTCLOUD_DOMAIN=cloud.example.com \
#     ./setup-nextcloud.sh                                   # Traefik mode
#   HTTP_PORT=9090 NEXTCLOUD_LAN_BIND=192.168.1.10 ./setup-nextcloud.sh
#   ./setup-nextcloud.sh --help
#
# UPGRADES:
#   Never bump more than one major at a time (33 -> 34 -> 35) and take a
#   backup before each bump (setup-backup-server.sh --services nextcloud).
#   The script converges on re-run but NEVER bumps the major itself.
#
# REFERENCE:
#   https://hub.docker.com/_/nextcloud
#   docs/research/nextcloud-production-setup-research.md
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures
# ─────────────────────────────────────────────────────────────────────────────

# Set to 1 immediately BEFORE 'up -d' and reset to 0 once the stack is proven
# healthy AND installed. The trap tears the stack down only while this flag is
# set, so a late failure (readiness gate, occ pass, ufw) cannot stop a stack
# that was already running before this script was invoked. Volumes in
# ${NEXTCLOUD_HOME} are never removed by the trap.
STACK_CREATED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( STACK_CREATED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). Nothing torn down — this run either never started a stack or already proved it healthy."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Removing the stack created by this run..."
  if [[ -f "${NEXTCLOUD_HOME}/docker-compose.yml" ]]; then
    if [[ -n "$(sudo docker compose -f "${NEXTCLOUD_HOME}/docker-compose.yml" ps -q 2>/dev/null || true)" ]]; then
      sudo docker compose -f "${NEXTCLOUD_HOME}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
      info "Removed partially created stack."
    else
      info "Stack from this run is already stopped — data in ${NEXTCLOUD_HOME}/html and ${NEXTCLOUD_HOME}/data is preserved."
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# COLOURS & HELPERS
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}"; }

# Register cleanup trap now that all helper functions are defined
trap cleanup_on_failure EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────
# (Parsed before CONFIGURATION on purpose: --help must work without side
# effects — in particular without touching the sudo-readable .env below.)

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Deploys a production-grade Nextcloud stack using Docker Compose:
nextcloud:34-apache + PostgreSQL + authenticated Redis (cache + transactional
file locking) + cron sidecar. Access via the shared Traefik proxy (HTTPS) or a
directly published LAN port. Compose is rendered from templates/nextcloud/.
Secrets live in ${NEXTCLOUD_HOME:-/srv/nextcloud}/.env (mode 600), never in
the compose file; re-runs reuse them (NEVER rotated) and converge the stack.

PostgreSQL-only: existing MariaDB/SQLite installs are refused up-front.

Options:
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge); prompt on other risky conditions
  -h, --help      Show this help and exit

Modes (switch by re-running with the other value — see MODE SWITCH below):
  NEXTCLOUD_TRAEFIK=true   Traefik mode: HTTPS on NEXTCLOUD_DOMAIN via the
                           shared proxy (HTTP->HTTPS redirect, .well-known
                           DAV redirect, HSTS); publishes no ports
  NEXTCLOUD_TRAEFIK=false  LAN/direct mode (default): plain HTTP on
                           HTTP_PORT; UFW rule added

Environment variables (all optional):
  NEXTCLOUD_HOME               Host directory for persistent data
                               (default: /srv/nextcloud)
  NEXTCLOUD_IMAGE              App+cron image (default: nextcloud:34-apache,
                               pinned — update deliberately ONE major at a
                               time, 33->34->35, backup first:
                               setup-backup-server.sh --services nextcloud.
                               The cron sidecar shares this var, so its tag
                               can never drift from the app.)
  NEXTCLOUD_DB_IMAGE           PostgreSQL image (default: postgres:17-alpine;
                               when ${NEXTCLOUD_HOME:-/srv/nextcloud}/db/PG_VERSION
                               exists the default follows the installed major
                               to protect the datadir; explicit override wins)
  NEXTCLOUD_REDIS_IMAGE        Redis image (default: redis:7-alpine)
   CONTAINER_NAME               App container name (default: nextcloud — keep
                                it if setup-backup-server.sh --services
                                nextcloud is used: the dispatcher dumps
                                nextcloud / nextcloud-db and honours only
                                its own NEXTCLOUD_CONTAINER var, never this
                                one)
  HTTP_PORT                    Host port for the web UI, LAN mode (default: 8080)
  NEXTCLOUD_LAN_BIND           Bind IP for the published port (default: empty
                               = all interfaces). Docker inserts published
                               ports into the FORWARD chain, bypassing UFW
                               INPUT rules — set this to the LAN IP to keep
                               the port off other interfaces.
  NEXTCLOUD_LAN_HOSTS          LAN-mode trusted-domains override,
                               space-separated (default: detected primary IP
                               + localhost)
  NEXTCLOUD_TRAEFIK            "true" enables Traefik mode (default: false)
  NEXTCLOUD_DOMAIN             Domain for Traefik access (required when
                               NEXTCLOUD_TRAEFIK=true)
  NEXTCLOUD_TRUSTED_DOMAINS_EXTRA
                               Extra trusted domains in Traefik mode,
                               space-separated (e.g. a LAN IP so direct and
                               proxied access coexist)
  PROXY_NETWORK                Traefik's external Docker network name
                               (default: proxy)
  POSTGRES_DB                  PostgreSQL database name (default: nextcloud)
  POSTGRES_USER                PostgreSQL user (default: nextcloud)
  POSTGRES_PASSWORD            PostgreSQL password (auto-generated on first
                               run, reused from .env on re-runs; set
                               explicitly to override)
  NEXTCLOUD_ADMIN_USER         Initial admin username (default: admin —
                               applied at FIRST install only)
  NEXTCLOUD_ADMIN_PASSWORD     Initial admin password (auto-generated on
                               first run, reused from .env on re-runs)
  REDIS_HOST_PASSWORD          Redis password (auto-generated on first run,
                               reused from .env on re-runs). Redis is
                               mandatory: transactional file locking needs it.
  NEXTCLOUD_PHP_MEMORY_LIMIT   PHP_MEMORY_LIMIT (default: 512M)
  NEXTCLOUD_UPLOAD_LIMIT       PHP_UPLOAD_LIMIT — upload_max_filesize and
                               post_max_size (default: 512M; the apache
                               LimitRequestBody is unlimited so the chain
                               never 413s below the PHP limit)
  NEXTCLOUD_PHONE_REGION       occ default_phone_region (default: DE)
  SMTP_HOST, SMTP_PORT, SMTP_SECURE, SMTP_AUTHTYPE, SMTP_NAME,
  SMTP_PASSWORD, MAIL_FROM_ADDRESS, MAIL_DOMAIN
                                Optional SMTP passthrough — stored in .env
                                (mode 600), kept out of the compose file;
                                unset re-runs reuse the stored values; all
                                empty = mail not configured
  WAIT_TIMEOUT                 Max seconds for BOTH the container health gate
                               and the status.php install-readiness poll
                               (default: 300 — first-run installs are slow)

Removed variables (vs. the previous MariaDB-default script):
  DB_TYPE, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD,
  REDIS_ENABLED
  The backend is now always PostgreSQL and Redis is always enabled. A
  detected MariaDB (.env) or SQLite (data/nextcloud.db) install aborts the
  run before anything is modified.

MODE SWITCH (lan <-> traefik):
  Env-written config.php values are MERGED by the image, NEVER removed. A
  stale 'overwriteprotocol=https' from a previous Traefik run breaks plain
  HTTP LAN access until you run:
    sudo docker compose -f <compose-file> --env-file <env-file> exec -T --user www-data app php occ config:system:delete overwriteprotocol

UPGRADES:
  One major at a time (33 -> 34 -> 35, never further); backup before each
  bump (setup-backup-server.sh --services nextcloud). Re-runs converge but
  never bump the major.
EOF
}

# Parse arguments
INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      INTERACTIVE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1 (see --help)"
      ;;
  esac
  shift
done


# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these variables before running
# ─────────────────────────────────────────────────────────────────────────────

# Generate a cryptographically random 24-char alphanumeric password.
# Only called when the corresponding env variable is unset/empty.
_gen_password() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; echo; }

NEXTCLOUD_HOME="${NEXTCLOUD_HOME:-/srv/nextcloud}"          # Host directory for persistent data

# App image shared by the app AND the cron sidecar. Pinned on purpose — the
# stable/latest aliases risk skipping Nextcloud majors, which the upgrade
# path forbids (one major at a time). Update deliberately after reading the
# changelog: docker buildx imagetools inspect nextcloud
NEXTCLOUD_IMAGE="${NEXTCLOUD_IMAGE:-nextcloud:34-apache}"
warn_moving_image "${NEXTCLOUD_IMAGE}" "NEXTCLOUD_IMAGE"

CONTAINER_NAME="${CONTAINER_NAME:-nextcloud}"

HTTP_PORT="${HTTP_PORT:-8080}"                 # Host port for the web UI (LAN mode)
NEXTCLOUD_LAN_BIND="${NEXTCLOUD_LAN_BIND:-}"  # Optional bind IP for the published port
NEXTCLOUD_LAN_HOSTS="${NEXTCLOUD_LAN_HOSTS:-}"  # LAN trusted-domains override (space-separated)

# PostgreSQL is the only supported backend (repo standard engine, one
# pg_dump strategy; no MariaDB isolation/binlog footguns, no SQLite-for-prod).
# Pin rule: never start a newer-major postgres against an older datadir —
# default to the major recorded in db/PG_VERSION when one exists.
if [[ -z "${NEXTCLOUD_DB_IMAGE:-}" ]]; then
  _pg_major="$(sudo cat "${NEXTCLOUD_HOME}/db/PG_VERSION" 2>/dev/null || true)"
  if [[ "${_pg_major}" =~ ^[0-9]+$ ]]; then
    NEXTCLOUD_DB_IMAGE="postgres:${_pg_major}-alpine"
  else
    NEXTCLOUD_DB_IMAGE="postgres:17-alpine"
  fi
fi
NEXTCLOUD_REDIS_IMAGE="${NEXTCLOUD_REDIS_IMAGE:-redis:7-alpine}"

POSTGRES_DB="${POSTGRES_DB:-nextcloud}"
POSTGRES_USER="${POSTGRES_USER:-nextcloud}"

# Nextcloud admin account (auto-configured on FIRST install only)
NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"

# Tuning / locale
NEXTCLOUD_PHP_MEMORY_LIMIT="${NEXTCLOUD_PHP_MEMORY_LIMIT:-512M}"
NEXTCLOUD_UPLOAD_LIMIT="${NEXTCLOUD_UPLOAD_LIMIT:-512M}"
NEXTCLOUD_PHONE_REGION="${NEXTCLOUD_PHONE_REGION:-DE}"

# Optional SMTP passthrough (empty = mail unconfigured; the image applies
# nothing unless at least SMTP_HOST + MAIL_FROM_ADDRESS + MAIL_DOMAIN are set)
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-}"
SMTP_SECURE="${SMTP_SECURE:-}"
SMTP_AUTHTYPE="${SMTP_AUTHTYPE:-}"
SMTP_NAME="${SMTP_NAME:-}"
MAIL_FROM_ADDRESS="${MAIL_FROM_ADDRESS:-}"
MAIL_DOMAIN="${MAIL_DOMAIN:-}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"   # health gate + status.php poll (first install is slow)

# ── Secrets: reuse-first ────────────────────────────────────────────────────────────
# A re-run must never rotate a secret that an existing database volume or
# Nextcloud config still depends on. ${NEXTCLOUD_HOME}/.env (mode 600,
# root-owned; written later in this script) is the source of truth: values
# stored there are reused unless the operator set them explicitly.
# The .env is read once (sudo cat — it is root-owned) and parsed with plain
# grep/cut; it is never sourced or shell-evaluated.
ENV_FILE="${NEXTCLOUD_HOME}/.env"
_existing_env=""
[[ -f "$ENV_FILE" ]] && _existing_env="$(sudo cat "$ENV_FILE")"

_env_reuse() { # <VAR_NAME> <key>
  local __n="$1" __k="$2" __cur="${!1:-}" __old
  [[ -n "$__cur" ]] && return 0   # explicit env wins
  __old="$(grep -m1 "^${__k}=" <<<"${_existing_env}" | cut -d= -f2- || true)"
  if [[ -n "$__old" ]]; then
    printf -v "$__n" '%s' "$__old"
    return 0
  fi
  printf -v "$__n" '%s' "$(_gen_password)"
}
# Re-run policy (ticket 12): remember whether the admin password was supplied
# explicitly (it wins in _env_reuse) so the existing-stack check below can
# detect a divergence that a running Nextcloud cannot converge.
NEXTCLOUD_ADMIN_PASSWORD_SUPPLIED="${NEXTCLOUD_ADMIN_PASSWORD:-}"
_stored_admin_password="$(grep -m1 '^NEXTCLOUD_ADMIN_PASSWORD=' <<<"${_existing_env}" | cut -d= -f2- || true)"

_env_reuse POSTGRES_PASSWORD          POSTGRES_PASSWORD
_env_reuse NEXTCLOUD_ADMIN_PASSWORD   NEXTCLOUD_ADMIN_PASSWORD
# Redis password: rotation would be harmless (cache + locks only) but it is
# generated once anyway so the .env stays stable across re-runs.
_env_reuse REDIS_HOST_PASSWORD        REDIS_HOST_PASSWORD

# SMTP/MAIL passthrough: explicit env wins, else reuse whatever .env holds
# (a re-run without SMTP vars must never silently drop a configured mail
# relay), else stay empty. The password is a SECRET (via .env only) and is
# never generated.
for _smtp_key in SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_AUTHTYPE SMTP_NAME \
                 SMTP_PASSWORD MAIL_FROM_ADDRESS MAIL_DOMAIN; do
  [[ -n "${!_smtp_key:-}" ]] || printf -v "$_smtp_key" '%s' \
    "$(grep -m1 "^${_smtp_key}=" <<<"${_existing_env}" | cut -d= -f2- || true)"
done

# Traefik reverse-proxy integration (opt-in)
NEXTCLOUD_TRAEFIK="${NEXTCLOUD_TRAEFIK:-false}"     # Set to "true" to enable Traefik routing
NEXTCLOUD_DOMAIN="${NEXTCLOUD_DOMAIN:-}"            # e.g. cloud.example.com (required when Traefik=true)
NEXTCLOUD_TRUSTED_DOMAINS_EXTRA="${NEXTCLOUD_TRUSTED_DOMAINS_EXTRA:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"             # Traefik's external Docker network name

# trusted_domains (non-secret layout value, envsubst-ed at render time).
# Traefik: domain + optional extras (LAN IP etc.). LAN: operator override or
# detected primary IP + localhost (the image alone would write localhost only,
# which makes LAN installs unusable).
_detect_primary_ip() {
  ip route get 1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}
if [[ "$NEXTCLOUD_TRAEFIK" == "true" ]]; then
  NEXTCLOUD_TRUSTED_DOMAINS="${NEXTCLOUD_DOMAIN}${NEXTCLOUD_TRUSTED_DOMAINS_EXTRA:+ ${NEXTCLOUD_TRUSTED_DOMAINS_EXTRA}}"
elif [[ -n "$NEXTCLOUD_LAN_HOSTS" ]]; then
  NEXTCLOUD_TRUSTED_DOMAINS="$NEXTCLOUD_LAN_HOSTS"
else
  _lan_ip="$(_detect_primary_ip || true)"
  NEXTCLOUD_TRUSTED_DOMAINS="${_lan_ip:+${_lan_ip} }localhost"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not in PATH. Run setup-docker.sh first."
fi

if ! sudo docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi

success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

# Check Docker Compose v2+
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "0.0.0")
COMPOSE_MAJOR=$(echo "$COMPOSE_VERSION" | cut -d'.' -f1)
if [[ "$COMPOSE_MAJOR" -lt 2 ]]; then
  warn "Docker Compose v2+ recommended. Current version: ${COMPOSE_VERSION}"
fi

if ! command -v openssl &>/dev/null; then
  error "openssl is not installed. Required for generating secrets. Install with: sudo apt-get install openssl"
fi

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
fi

# ── Backend compatibility guard (BEFORE anything is modified) ───────────────
# This script version supports PostgreSQL only. An existing MariaDB or
# SQLite install must never be touched by accident.
if grep -q '^MYSQL_ROOT_PASSWORD=' <<<"${_existing_env}"; then
  error "Existing MariaDB-based Nextcloud install detected (${ENV_FILE} contains MYSQL_ROOT_PASSWORD). This script supports PostgreSQL only — migrate via Nextcloud's own tooling or pin the previous script revision. Nothing was modified."
fi
if sudo test -f "${NEXTCLOUD_HOME}/data/nextcloud.db"; then
  error "Existing SQLite-based Nextcloud install detected (${NEXTCLOUD_HOME}/data/nextcloud.db). This script supports PostgreSQL only — migrate via Nextcloud's own tooling or pin the previous script revision. Nothing was modified."
fi

# Traefik pre-flight (only when opt-in)
if [[ "$NEXTCLOUD_TRAEFIK" == "true" ]]; then
  if ! ensure_proxy_network; then
    error "Traefik proxy network '${PROXY_NETWORK}' not found or inaccessible."
  fi
  if [[ -z "$NEXTCLOUD_DOMAIN" ]]; then
    error "NEXTCLOUD_DOMAIN must be set when NEXTCLOUD_TRAEFIK=true."
  fi
fi

COMPOSE_FILE="${NEXTCLOUD_HOME}/docker-compose.yml"

# LAN mode port check — only when no compose file exists yet: the converge
# case legitimately "owns" the port via its own running containers.
if [[ "$NEXTCLOUD_TRAEFIK" != "true" && ! -f "$COMPOSE_FILE" ]]; then
  if ss -tln 2>/dev/null | grep -q ":${HTTP_PORT} " || \
     netstat -tln 2>/dev/null | grep -q ":${HTTP_PORT} "; then
    error "Port ${HTTP_PORT} is already in use. Choose a different HTTP_PORT."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STOP & REMOVE EXISTING COMPOSE STACK (if any)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for an existing Nextcloud compose stack"

if [[ -f "$COMPOSE_FILE" ]]; then
  warn "Existing docker-compose.yml found at ${COMPOSE_FILE}."
  echo ""
  info "Re-running converges the existing stack: the config is re-rendered, the"
  info "stored secrets in ${ENV_FILE} are reused, and 'docker compose up -d'"
  info "reconciles only what changed. Your Nextcloud data in ${NEXTCLOUD_HOME}/html"
  info "and ${NEXTCLOUD_HOME}/data is PRESERVED."
  # Mode switch traefik -> lan: env-written config.php values are merged by
  # the image, never removed. A stale overwriteprotocol breaks plain HTTP.
  if [[ "$NEXTCLOUD_TRAEFIK" != "true" ]] && grep -q "traefik.enable" "$COMPOSE_FILE"; then
    warn "Switching from Traefik to LAN mode: config.php still carries values the"
    warn "Traefik run wrote (env values are merged, never removed). A stale"
    warn "'overwriteprotocol=https' breaks plain-HTTP LAN access. Fix it with:"
    warn "  sudo docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} exec -T --user www-data app php occ config:system:delete overwriteprotocol"
  fi
  # Re-run policy (ticket 12): the admin password is applied only at FIRST
  # install, so an explicitly changed value cannot be converged onto the
  # existing stack. Print the exact remedy and exit 0 (nothing is modified;
  # the stored password in ${ENV_FILE} stays in effect).
  if [[ -n "${NEXTCLOUD_ADMIN_PASSWORD_SUPPLIED}" && "${NEXTCLOUD_ADMIN_PASSWORD_SUPPLIED}" != "${_stored_admin_password}" ]]; then
    warn "NEXTCLOUD_ADMIN_PASSWORD was explicitly changed, but Nextcloud applies the"
    warn "admin password only at first install. Nothing was changed — the stored"
    warn "password in ${ENV_FILE} stays in effect."
    warn "Change the admin password on the instance (start the stack first if it is stopped):"
    warn "  sudo docker exec -u www-data ${CONTAINER_NAME} php occ user:resetpassword ${NEXTCLOUD_ADMIN_USER}"
    warn "Or tear down and re-create interactively (data preserved):"
    warn "  $0 --interactive"
    exit 0
  fi
  RECREATE=false
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      RECREATE=true
    fi
  fi
  if [[ "$RECREATE" == "true" ]]; then
    # The operator confirmed the re-create: the cleanup trap must cover it,
    # so a failure before 'up -d' or a half-created re-create is still
    # cleaned up — and the trap must not claim "nothing torn down".
    STACK_CREATED_THIS_RUN=1
    info "Stopping and removing existing stack..."
    sudo docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    success "Old stack removed."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE PERSISTENT HOST DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating persistent storage directories under ${NEXTCLOUD_HOME}"

sudo mkdir -p "${NEXTCLOUD_HOME}/html"   # Nextcloud web root (config, apps, themes)
sudo mkdir -p "${NEXTCLOUD_HOME}/data"   # User files
sudo mkdir -p "${NEXTCLOUD_HOME}/db"     # PostgreSQL data (initialized by the image)
# www-data (uid 33) must own the app-visible dirs (idempotent on re-runs);
# the db dir is left to the postgres image.
sudo chown 33:33 "${NEXTCLOUD_HOME}/html" "${NEXTCLOUD_HOME}/data"

success "Directories ready."

# ─────────────────────────────────────────────────────────────────────────────
# WRITE SECRETS TO .env (mode 600)
# ─────────────────────────────────────────────────────────────────────────────

step "Writing secrets to ${ENV_FILE}"

# Build the complete .env content in a temp file with printf (never a heredoc
# that could expand $, `, etc.), then install it atomically with mode 600.
# The credentials above were already resolved against the existing .env
# (reuse-first), so a no-op re-run produces byte-identical content. No
# timestamp line: a changing one would make every re-run look like a change.
# DB_TYPE=postgres makes the docker-backup.sh dispatcher dump deterministically.
_env_new="$(mktemp)"
{
  printf '# Nextcloud Environment — KEEP THIS FILE SECURE (mode 600)\n\n'
  printf 'DB_TYPE=postgres\n'
  printf 'NEXTCLOUD_ADMIN_USER=%s\n' "${NEXTCLOUD_ADMIN_USER}"
  printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\n' "${NEXTCLOUD_ADMIN_PASSWORD}"
  printf 'POSTGRES_DB=%s\n'       "${POSTGRES_DB}"
  printf 'POSTGRES_USER=%s\n'     "${POSTGRES_USER}"
  printf 'POSTGRES_PASSWORD=%s\n' "${POSTGRES_PASSWORD}"
  printf 'REDIS_HOST_PASSWORD=%s\n' "${REDIS_HOST_PASSWORD}"
  printf 'SMTP_HOST=%s\n'         "${SMTP_HOST}"
  printf 'SMTP_PORT=%s\n'         "${SMTP_PORT}"
  printf 'SMTP_SECURE=%s\n'       "${SMTP_SECURE}"
  printf 'SMTP_AUTHTYPE=%s\n'     "${SMTP_AUTHTYPE}"
  printf 'SMTP_NAME=%s\n'         "${SMTP_NAME}"
  printf 'SMTP_PASSWORD=%s\n'     "${SMTP_PASSWORD}"
  printf 'MAIL_FROM_ADDRESS=%s\n' "${MAIL_FROM_ADDRESS}"
  printf 'MAIL_DOMAIN=%s\n'       "${MAIL_DOMAIN}"
} > "$_env_new"

# Back up the existing .env only when its content actually changes, so a
# no-op re-run never clobbers a good .env.bak.
if [[ -f "$ENV_FILE" ]]; then
  if sudo cmp -s "$_env_new" "$ENV_FILE"; then
    info "Existing ${ENV_FILE} unchanged — keeping it and its backup."
  else
    warn "Existing .env file found. Backing up to ${ENV_FILE}.bak"
    sudo install -m 600 "$ENV_FILE" "${ENV_FILE}.bak"
  fi
fi
sudo install -m 600 "$_env_new" "$ENV_FILE"
rm -f "$_env_new"

success "Secrets stored in ${ENV_FILE} (mode: 600)."

# ─────────────────────────────────────────────────────────────────────────────
# RENDER DOCKER COMPOSE FILE (templates/nextcloud/, no inline templates)
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${COMPOSE_FILE}"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates/nextcloud"
if [[ "$NEXTCLOUD_TRAEFIK" == "true" ]]; then
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.traefik.yml"
else
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.direct.yml"
fi

# Non-secret layout values ONLY. Secrets (POSTGRES_*, NEXTCLOUD_ADMIN_*,
# REDIS_HOST_PASSWORD, SMTP_*) deliberately stay literal ${VAR} in the
# generated file and are resolved at runtime by 'docker compose --env-file'
# from ${ENV_FILE}. Render as the invoking user, install with sudo.
GENERATED_DATE="$(date -Iseconds)"
export GENERATED_DATE NEXTCLOUD_HOME CONTAINER_NAME NEXTCLOUD_IMAGE \
  NEXTCLOUD_DB_IMAGE NEXTCLOUD_REDIS_IMAGE PROXY_NETWORK NEXTCLOUD_DOMAIN \
  NEXTCLOUD_TRUSTED_DOMAINS HTTP_PORT NEXTCLOUD_LAN_BIND \
  NEXTCLOUD_PHP_MEMORY_LIMIT NEXTCLOUD_UPLOAD_LIMIT
_render_tmp="$(mktemp)"
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${GENERATED_DATE} ${NEXTCLOUD_HOME} ${CONTAINER_NAME} ${NEXTCLOUD_IMAGE} ${NEXTCLOUD_DB_IMAGE} ${NEXTCLOUD_REDIS_IMAGE} ${PROXY_NETWORK} ${NEXTCLOUD_DOMAIN} ${NEXTCLOUD_TRUSTED_DOMAINS} ${HTTP_PORT} ${NEXTCLOUD_LAN_BIND} ${NEXTCLOUD_PHP_MEMORY_LIMIT} ${NEXTCLOUD_UPLOAD_LIMIT}' \
  < "$COMPOSE_TEMPLATE" > "$_render_tmp"
sudo install -m 644 "$_render_tmp" "$COMPOSE_FILE"
rm -f "$_render_tmp"

success "docker-compose.yml rendered to ${COMPOSE_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# PULL IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling Docker images"
sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
success "Images pulled."

# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Starting Nextcloud stack (detached)"
STACK_CREATED_THIS_RUN=1
sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

# Health gate: prove the containers are actually up before reporting success
# (db/redis have healthchecks; app/cron count as ready once running).
mapfile -t _ids < <(sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT}" "${_ids[@]}" \
  || error "Nextcloud stack did not come up — see the status output above"

# ─────────────────────────────────────────────────────────────────────────────
# READINESS GATE: wait for the Nextcloud INSTALLATION to finish
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Nextcloud to report installed=true (status.php)"

ELAPSED=0
READY=false
while (( ELAPSED < WAIT_TIMEOUT )); do
  # Transient exec failures (container restarting mid-install) are tolerated;
  # only the final timeout fails the run.
  if sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T app \
       curl -sf http://localhost/status.php 2>/dev/null | grep -q '"installed":true'; then
    READY=true
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${WAIT_TIMEOUT}s (waiting for install to finish) ..."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo ""
if [[ "$READY" != "true" ]]; then
  error "Nextcloud did not report '\"installed\":true' within ${WAIT_TIMEOUT}s — check: sudo docker compose -f ${COMPOSE_FILE} logs app"
fi
STACK_CREATED_THIS_RUN=0   # proven up AND installed -> a later failure must not tear it down

success "Nextcloud is installed and responding."

# ─────────────────────────────────────────────────────────────────────────────
# POST-INSTALL OCC HARDENING PASS (idempotent, warn-only)
# ─────────────────────────────────────────────────────────────────────────────

step "Applying production settings via occ"

# Never run occ as root; every line warn-only: a failed occ call must not
# abort an otherwise healthy instance (config:system:set is idempotent).
_occ() {
  sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
    exec -T --user www-data app php occ "$@" \
    || warn "occ $* failed (non-fatal — set it manually if needed)"
}

# memcache.* are NOT covered by the image env vars — occ is the way.
# Redis locking takes transactional file locks off the database.
_occ config:system:set memcache.local       --value='\OC\Memcache\APCu'
_occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
_occ config:system:set memcache.locking     --value='\OC\Memcache\Redis'
_occ config:system:set default_phone_region --value="${NEXTCLOUD_PHONE_REGION}"
_occ config:system:set maintenance_window_start --type=integer --value=1
_occ config:system:set loglevel             --type=integer --value=2

info "occ db:add-missing-indices (best effort)..."
_occ db:add-missing-indices
info "occ db:convert-filecache-bigint (best effort)..."
_occ db:convert-filecache-bigint --no-interaction

success "occ hardening pass applied."

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL (LAN mode only — Traefik mode publishes no ports)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$NEXTCLOUD_TRAEFIK" == "true" ]]; then
  step "Skipping UFW (Traefik mode publishes no ports; Traefik owns 80/443)"
else
  ufw_firewall_section "Nextcloud" "${HTTP_PORT}" tcp "Nextcloud (LAN mode)"
  warn "Docker inserts published ports into the FORWARD chain, BYPASSING UFW"
  warn "INPUT rules: ${HTTP_PORT}/tcp may be reachable beyond the LAN even"
  warn "with UFW active. Bind it to the LAN IP to restrict exposure:"
  warn "  NEXTCLOUD_LAN_BIND=<host-LAN-IP> $0"
fi

# Disable cleanup trap on successful completion
trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Nextcloud setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""

if [[ "$NEXTCLOUD_TRAEFIK" == "true" ]]; then
  echo -e "  ${BOLD}Web UI (Traefik)${RESET}   https://${NEXTCLOUD_DOMAIN}"
  echo -e "  ${BOLD}TLS${RESET}                Enabled via Let's Encrypt (HSTS 180d)"
  echo ""
  echo -e "${YELLOW}  Verify the proxy config:${RESET}"
  echo -e "  curl -I https://${NEXTCLOUD_DOMAIN}/.well-known/caldav  (expect 301 -> /remote.php/dav)"
  echo -e "  curl -sI https://${NEXTCLOUD_DOMAIN}/ | grep -i strict-transport  (expect the HSTS header)"
else
  echo -e "  ${BOLD}Web UI${RESET}             http://${NEXTCLOUD_LAN_BIND:-localhost}:${HTTP_PORT}  (plain HTTP — LAN traffic is unencrypted)"
fi

echo ""
echo -e "  ${BOLD}Admin user${RESET}         ${NEXTCLOUD_ADMIN_USER}"
echo -e "  ${BOLD}Admin password${RESET}     sudo grep NEXTCLOUD_ADMIN_PASSWORD ${ENV_FILE}"
echo -e "  ${BOLD}Database${RESET}           PostgreSQL (${NEXTCLOUD_DB_IMAGE})"
echo -e "  ${BOLD}Redis${RESET}              ${NEXTCLOUD_REDIS_IMAGE} (locking + cache, password in .env)"
echo -e "  ${BOLD}Background jobs${RESET}    cron sidecar (${CONTAINER_NAME}-cron, every 5 min)"
echo -e "  ${BOLD}Trusted domains${RESET}    ${NEXTCLOUD_TRUSTED_DOMAINS}"
echo -e "  ${BOLD}Web root${RESET}           ${NEXTCLOUD_HOME}/html"
echo -e "  ${BOLD}User data${RESET}          ${NEXTCLOUD_HOME}/data"
echo -e "  ${BOLD}Compose file${RESET}       ${COMPOSE_FILE}"
echo -e "  ${BOLD}Secrets file${RESET}       ${ENV_FILE}"
echo ""
echo -e "${YELLOW}  First-time setup:${RESET}"
echo -e "  Nextcloud was auto-configured via environment variables and the occ"
echo -e "  pass. Log in as '${NEXTCLOUD_ADMIN_USER}' and check Admin settings"
echo -e "  overview for remaining warnings (e.g. set up fail2ban on"
echo -e "  ${NEXTCLOUD_HOME}/data/nextcloud.log)."
echo ""
echo -e "${YELLOW}  Backup:${RESET}"
echo -e "  setup-backup-server.sh --services nextcloud  (logical pg_dump -Fc"
echo -e "  from the running ${CONTAINER_NAME}-db container + borg file copy of"
echo -e "  ${NEXTCLOUD_HOME}). Do NOT add nextcloud to --stop-services: that stops"
echo -e "  the whole stack incl. the db container and breaks the pg_dump."
echo ""
echo -e "${YELLOW}  Upgrades:${RESET}"
echo -e "  One major at a time (NEXTCLOUD_IMAGE 33 -> 34 -> 35), backup first;"
echo -e "  re-running this script converges but never bumps the major."
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs   :  sudo docker compose -f ${COMPOSE_FILE} logs -f"
echo -e "  App logs only :  sudo docker compose -f ${COMPOSE_FILE} logs -f app"
echo -e "  Stop stack    :  sudo docker compose -f ${COMPOSE_FILE} down"
echo -e "  Start stack   :  sudo docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} up -d"
echo -e "  Restart app   :  sudo docker compose -f ${COMPOSE_FILE} restart app"
echo -e "  Shell into app:  sudo docker exec -it ${CONTAINER_NAME} bash"
echo -e "  occ command   :  sudo docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} exec -T --user www-data app php occ <command>"
echo ""
echo -e "${BOLD}🔐 Security Notice:${RESET}"
echo -e "  Credentials are stored in ${ENV_FILE} (mode: 600); the compose file"
echo -e "  carries only literal \${VAR} placeholders resolved from it at runtime."
echo -e "  Do not expose this file or the web UI without TLS protection."
echo ""
