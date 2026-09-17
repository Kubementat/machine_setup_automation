#!/usr/bin/env bash
# =============================================================================
# setup-backup-client.sh — Central Borg backup infrastructure: client
# =============================================================================
#
# DESCRIPTION:
#   Adds this machine to the Borg backup fleet: installs BorgBackup,
#   initializes this machine's repository (over SSH to the backup server, or
#   on a local path), generates and stores the repo passphrase, installs a
#   per-client wrapper + systemd timer that runs `borg create` + `borg prune`
#   daily — including CONSISTENT engine-level dumps of Docker-based databases
#   (lib/docker-backup.sh) staged into the same archive.
#
#   Two modes:
#     - remote (default): repo at ssh://USER@HOST:PORT/REPO_PATH/CLIENT/
#     - local  (BACKUP_SERVER_HOST empty): repo at REPO_PATH/CLIENT/
#       (e.g. the backup server backing up itself — spec Decision 12)
#
# KEY ACTIONS:
#   1. Auto-detects paths/services when unset, then validates client name /
#      paths / services
#   2. Installs borgbackup if missing
#   3. Remote mode: SSH preflight (BatchMode) + remote borg version compare
#   4. Repo init (idempotent: reuse / init / abort-with-passphrase-message)
#   5. Passphrase file ~/.config/borg/<client>.pass (0600, generated once)
#   6. Installs lib/docker-backup.sh -> /usr/local/lib/borg-backup/
#   7. Generates wrapper /usr/local/bin/borg-backup-<client>
#      (create / list / check / restore / restore-db)
#   8. Installs systemd service + daily timer (Persistent, 15m jitter),
#      daemon-reload, enable --now
#   9. Optional --initial: run the first (full) backup in the foreground
#
#   --check: report install, passphrase, repo reachability, timer state,
#   last run result, latest snapshot; exit non-zero on problems.
#
# IMPORTANT VARIABLES:
#   BACKUP_CLIENT_NAME     - Repo name & archive prefix (default: hostname)
#   BACKUP_SERVER_HOST     - Server address; EMPTY = local repo mode
#   BACKUP_SERVER_PORT     - SSH port on the server (default: 22)
#   BACKUP_SERVER_USER     - SSH user on the server (default: sudo caller)
#   BACKUP_USER            - Local user the timer runs as (default: sudo caller)
#   BACKUP_REPO_PATH       - Parent dir for the repo (default: /var/backups/automatic)
#   BACKUP_PATHS           - Source paths (space-separated). EMPTY = auto-detect
#                            (/home/<user>, /etc, /srv, + docker volumes)
#   BACKUP_SERVICES        - Comma list of Docker services to dump before
#                            'borg create' (forgejo,planka,kestra,nextcloud,
#                            n8n,concourse,openwebui,omnigent). EMPTY = auto-detect
#                            installed/running ones (none -> plain file backup).
#   BACKUP_STOP_SERVICES   - Services to `docker compose stop` around the
#                            whole run (short downtime, raw-copy safety)
#   BACKUP_STAGING_DIR     - Host dir for dumps (default: /var/backup-staging;
#                            must NOT be inside BACKUP_PATHS)
#   BACKUP_EXCLUDE_REGEXES - Extra borg --exclude regexes
#   BACKUP_KEEP_DAILY/WEEKLY/MONTHLY - Prune retention (7/4/12)
#   BACKUP_COMPRESSION     - lz4 (default) or zstd
#   BACKUP_ONE_FILE_SYSTEM - true (default): skip bind/overlay mounts
#   BACKUP_SSH_KEY         - SSH key for remote mode (default: <user>'s id_ed25519)
#
# USAGE:
#   sudo ./tasks/setup-backup-client.sh           # zero-config (auto-detect)
#
#   sudo ./tasks/setup-backup-client.sh --client mybox \
#        --host backup.example.com --port 22 --user alice \
#        --repo-path /var/backups/automatic \
#        --paths "/home/alice /etc /srv" \
#        --services "forgejo,planka,kestra" \
#        [--initial]
#
#   # Local mode (server backs up itself):
#   sudo ./tasks/setup-backup-client.sh --client server-self \
#        --repo-path /var/backups/automatic \
#        --paths "/home/alice /etc /srv" --services "forgejo,openwebui"
#
# SPEC: specification/features/setup-backup-server.md (Behaviors 2–4)
#       docs/research/docker-volume-backup-research.md (Docker/DB layer)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — all env vars with defaults
# ─────────────────────────────────────────────────────────────────────────────

# The user the timer runs as; default: the sudo caller (not root).
BACKUP_USER="${BACKUP_USER:-${SUDO_USER:-$(id -un)}}"
USER_HOME="$(getent passwd "${BACKUP_USER}" 2>/dev/null | cut -d: -f6 || true)"

BACKUP_CLIENT_NAME="${BACKUP_CLIENT_NAME:-$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')}"
BACKUP_SERVER_HOST="${BACKUP_SERVER_HOST:-}"
BACKUP_SERVER_PORT="${BACKUP_SERVER_PORT:-22}"
BACKUP_SERVER_USER="${BACKUP_SERVER_USER:-${BACKUP_USER}}"
BACKUP_REPO_PATH="${BACKUP_REPO_PATH:-/var/backups/automatic}"
BACKUP_PATHS="${BACKUP_PATHS:-}"
BACKUP_SERVICES="${BACKUP_SERVICES:-}"
BACKUP_STOP_SERVICES="${BACKUP_STOP_SERVICES:-}"
# /var/backup-staging (not /srv/...) so the default does not land inside the
# default backup scope (/etc /srv /home) and trip the nesting validation.
BACKUP_STAGING_DIR="${BACKUP_STAGING_DIR:-/var/backup-staging}"
BACKUP_EXCLUDE_REGEXES="${BACKUP_EXCLUDE_REGEXES:-}"
BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-12}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-lz4}"
BACKUP_ONE_FILE_SYSTEM="${BACKUP_ONE_FILE_SYSTEM:-true}"
BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-${USER_HOME}/.ssh/id_ed25519}"
BACKUP_RUN_INITIAL="${BACKUP_RUN_INITIAL:-false}"
# Device the repo path sits on (local mode, full runs only) — baked into the
# wrapper so create() refuses to write when the backup drive is not mounted.
REPO_MOUNT_SOURCE=""
FULL_CHECK=false
SHOW_PASSPHRASE=false
FORCE_VERSION_MISMATCH=false
CHECK_ONLY=false

SUPPORTED_SERVICES="forgejo planka kestra nextcloud n8n concourse openwebui omnigent"

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<'HELP'
setup-backup-client.sh — add this machine to the Borg backup fleet (installs
borg, inits the repo, generates the wrapper + daily systemd timer, with
optional consistent Docker/database dumps).

Usage: sudo ./tasks/setup-backup-client.sh [OPTIONS]

Options:
  --paths <p1 p2 ...>    Source paths to back up (env: BACKUP_PATHS).
                         Omit to auto-detect: /home/<user>, /etc, /srv (if
                         non-empty) and /var/lib/docker/volumes (if Docker is
                         running). The chosen scope is printed.
  --client <name>        Repo dir name & archive prefix, [a-z0-9-]
                         (env: BACKUP_CLIENT_NAME, default: hostname)
  --host <addr>          Backup server address (env: BACKUP_SERVER_HOST).
                         OMIT / empty = local repo mode (repo on this machine)
  --port <n>             SSH port on the server (env: BACKUP_SERVER_PORT, 22)
  --user <name>          SSH user on the server (env: BACKUP_SERVER_USER)
  --local-user <name>    Local user the timer runs as (env: BACKUP_USER,
                         default: the sudo caller)
  --repo-path <dir>      Parent dir for the repo (env: BACKUP_REPO_PATH,
                          default: /var/backups/automatic); final repo is
                         <repo-path>/<client>/
  --services <a,b>       Docker services to dump consistently before 'borg
                         create' (env: BACKUP_SERVICES). Omit to auto-detect
                         installed/running ones. Supported: forgejo, planka,
                         kestra, nextcloud, n8n, concourse, openwebui,
                         omnigent. Empty = plain file backup.
  --stop-services <a,b>  Services to `docker compose stop` around the whole
                         run (env: BACKUP_STOP_SERVICES) — short downtime,
                         for services whose raw data must not be copied
                         mid-write.
  --staging-dir <dir>    Host dir for engine dumps (env: BACKUP_STAGING_DIR,
                         default: /var/backup-staging). Must not be inside
                         --paths.
  --keep-daily <n>       Retention: daily archives to keep (default: 7)
  --keep-weekly <n>      Retention: weekly archives to keep (default: 4)
  --keep-monthly <n>     Retention: monthly archives to keep (default: 12)
  --compression <alg>    lz4 (default) or zstd (env: BACKUP_COMPRESSION)
  --ssh-key <path>       SSH key for remote mode (env: BACKUP_SSH_KEY)
  --initial              Run the first (full) backup in the foreground after
                         setup (env: BACKUP_RUN_INITIAL)
  --full                 With --check: also run 'borg check --verify-data' (slow)
  --show-passphrase      Print the (re)used repo passphrase (opt-in!)
  --force-version-mismatch  Proceed despite client/server borg version mismatch
  --check                Report status, exit non-zero on problems
  --help, -h             Show this help

Examples:
   # Zero-config (auto-detects scope + services, local repo, --initial):
   sudo ./tasks/setup-backup-client.sh

   # Remote client:
   sudo ./tasks/setup-backup-client.sh --client mybox --host backup.example.com \
       --user alice --paths "/home/alice /etc /srv" \
       --services "forgejo,planka,kestra" --initial

  # Server self-backup (local mode):
  sudo ./tasks/setup-backup-client.sh --client server-self \
       --paths "/home/alice /etc /srv" --services "forgejo,openwebui"

Spec: specification/features/setup-backup-server.md
      docs/research/docker-volume-backup-research.md
HELP
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENTS
# ─────────────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client)                 BACKUP_CLIENT_NAME="${2:?}"; shift 2 ;;
    --host)                   BACKUP_SERVER_HOST="${2:?}"; shift 2 ;;
    --port)                   BACKUP_SERVER_PORT="${2:?}"; shift 2 ;;
    --user)                   BACKUP_SERVER_USER="${2:?}"; shift 2 ;;
    --local-user)             BACKUP_USER="${2:?}"; USER_HOME="$(getent passwd "${BACKUP_USER}" 2>/dev/null | cut -d: -f6 || true)"; shift 2 ;;
    --repo-path)              BACKUP_REPO_PATH="${2:?}"; shift 2 ;;
    --paths)                  BACKUP_PATHS="${2:?}"; shift 2 ;;
    --services)               BACKUP_SERVICES="${2:?}"; shift 2 ;;
    --stop-services)          BACKUP_STOP_SERVICES="${2:?}"; shift 2 ;;
    --staging-dir)            BACKUP_STAGING_DIR="${2:?}"; shift 2 ;;
    --keep-daily)             BACKUP_KEEP_DAILY="${2:?}"; shift 2 ;;
    --keep-weekly)            BACKUP_KEEP_WEEKLY="${2:?}"; shift 2 ;;
    --keep-monthly)           BACKUP_KEEP_MONTHLY="${2:?}"; shift 2 ;;
    --compression)            BACKUP_COMPRESSION="${2:?}"; shift 2 ;;
    --ssh-key)                BACKUP_SSH_KEY="${2:?}"; shift 2 ;;
    --initial)                BACKUP_RUN_INITIAL=true; shift ;;
    --full)                   FULL_CHECK=true; shift ;;
    --show-passphrase)        SHOW_PASSPHRASE=true; shift ;;
    --force-version-mismatch) FORCE_VERSION_MISMATCH=true; shift ;;
    --check)                  CHECK_ONLY=true; shift ;;
    --help|-h)                usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# LOAD HELPERS
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/backup-client"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/helpers.sh"

WRAPPER_BIN="/usr/local/bin/borg-backup-${BACKUP_CLIENT_NAME}"
LIB_DEST="/usr/local/lib/borg-backup/docker-backup.sh"
PASS_DIR="${USER_HOME}/.config/borg"
PASS_FILE="${PASS_DIR}/${BACKUP_CLIENT_NAME}.pass"
SERVICE_UNIT="borg-backup-${BACKUP_CLIENT_NAME}.service"
TIMER_UNIT="borg-backup-${BACKUP_CLIENT_NAME}.timer"

# ─────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

csv_check_services() {
  local csv="$1" label="$2" svc
  [[ -n "$csv" ]] || return 0
  for svc in ${csv//,/ }; do
    if ! grep -qw "$svc" <<< "$SUPPORTED_SERVICES"; then
      error "Unsupported ${label}: '${svc}' — supported services: ${SUPPORTED_SERVICES}"
    fi
  done
  return 0
}

# Fill BACKUP_PATHS from the box's actual layout when the operator left it
# empty. Inspects the machine (not a hardcoded scope) and prints the result;
# --paths always overrides.
detect_backup_paths() {
  local -a paths=()
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] && paths+=("$USER_HOME")
  [[ -d /etc ]] && paths+=("/etc")
  [[ -d /srv && -n "$(find /srv -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && paths+=("/srv")
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [[ -d /var/lib/docker/volumes ]]; then
    # /var/lib/docker is 0710 root:root — a non-root backup user cannot
    # traverse it; grant the (traverse-only) bit so the volume contents read.
    sudo chmod 755 /var/lib/docker 2>/dev/null || true
    paths+=("/var/lib/docker/volumes")
  fi
  if [[ ${#paths[@]} -eq 0 ]]; then
    error "Could not auto-detect a backup scope and --paths was not given — pass --paths explicitly."
  fi
  BACKUP_PATHS="${paths[*]}"
  info "Auto-detected backup scope: ${BACKUP_PATHS}"
}

# Fill BACKUP_SERVICES from what is actually installed/running when empty:
# each supported service with a /srv/<svc> home dir (the setup-*.sh
# convention) or a running Docker container. Empty result = plain file backup.
detect_backup_services() {
  local -a running=() detected=()
  local svc name
  if command -v docker >/dev/null 2>&1; then
    mapfile -t running < <(docker ps --format '{{.Names}}' 2>/dev/null)
  fi
  for svc in $SUPPORTED_SERVICES; do
    [[ -d "/srv/${svc}" ]] && { detected+=("$svc"); continue; }
    for name in "${running[@]}"; do
      if [[ "$name" == *"$svc"* ]]; then
        detected+=("$svc")
        break
      fi
    done
  done
  BACKUP_SERVICES="$(IFS=,; echo "${detected[*]:-}")"
  if [[ -n "$BACKUP_SERVICES" ]]; then
    info "Auto-detected services to back up: ${BACKUP_SERVICES}"
  else
    info "No supported Docker services detected — plain file backup (add any with --services)"
  fi
}

validate() {
  if [[ ! "$BACKUP_CLIENT_NAME" =~ ^[a-z0-9-]+$ ]]; then
    error "BACKUP_CLIENT_NAME must match [a-z0-9-]+ (got: ${BACKUP_CLIENT_NAME})"
  fi
  if ! getent passwd "${BACKUP_USER}" >/dev/null; then
    error "Backup user '${BACKUP_USER}' does not exist"
  fi
  if [[ "$BACKUP_COMPRESSION" != "lz4" && "$BACKUP_COMPRESSION" != "zstd" ]]; then
    error "BACKUP_COMPRESSION must be lz4 or zstd (got: ${BACKUP_COMPRESSION})"
  fi

  csv_check_services "$BACKUP_SERVICES" "BACKUP_SERVICES entry"
  csv_check_services "$BACKUP_STOP_SERVICES" "BACKUP_STOP_SERVICES entry"

  if [[ -z "$BACKUP_PATHS" ]]; then
    error "No backup scope: pass --paths (auto-detection found nothing to back up)."
  fi
  local -a paths
  read -r -a paths <<< "$BACKUP_PATHS"
  local p
  for p in "${paths[@]}"; do
    if [[ ! -d "$p" ]]; then
      error "Backup path does not exist: ${p}"
    fi
  done

  # These values are baked single-quoted into the generated wrapper — a quote
  # in them would break or inject into it.
  if [[ "$BACKUP_PATHS" == *"'"* || "$BACKUP_STAGING_DIR" == *"'"* ]]; then
    error "BACKUP_PATHS and BACKUP_STAGING_DIR must not contain single quotes"
  fi
  if [[ -n "$BACKUP_EXCLUDE_REGEXES" ]]; then
    local -a extra_excl
    read -r -a extra_excl <<< "$BACKUP_EXCLUDE_REGEXES"
    for p in "${extra_excl[@]}"; do
      if [[ "$p" == *"'"* ]]; then
        error "BACKUP_EXCLUDE_REGEXES entries must not contain single quotes: ${p}"
      fi
    done
  fi

  # The staging dir must not itself be inside a backed-up path (it is appended
  # as an explicit extra source — a nested copy would duplicate the dumps).
  if [[ -n "$BACKUP_SERVICES" ]]; then
    for p in "${paths[@]}"; do
      if [[ "$BACKUP_STAGING_DIR" == "$p" || "$BACKUP_STAGING_DIR" == "$p"/* ]]; then
        error "BACKUP_STAGING_DIR (${BACKUP_STAGING_DIR}) must not be inside a backed-up path (${p})"
      fi
    done
  fi

  if [[ -n "$BACKUP_SERVER_HOST" ]]; then
    if [[ ! -f "$BACKUP_SSH_KEY" ]]; then
      error "SSH key not found: ${BACKUP_SSH_KEY} (set BACKUP_SSH_KEY)"
    fi
    if [[ ! -r "$BACKUP_SSH_KEY" && "$(id -u)" -ne 0 ]]; then
      error "SSH key not readable: ${BACKUP_SSH_KEY}"
    fi
    # The timer later runs 'borg serve' over ssh AS BACKUP_USER — a key that
    # user cannot read would fail at the first unattended run with a generic
    # BatchMode error.
    if ! sudo -u "$BACKUP_USER" test -r "$BACKUP_SSH_KEY" 2>/dev/null; then
      error "SSH key ${BACKUP_SSH_KEY} is not readable by backup user ${BACKUP_USER} — fix ownership/permissions or set BACKUP_SSH_KEY"
    fi
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# BORG + SSH PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────

ensure_borg() {
  if is_apt_package_installed borgbackup; then
    success "borgbackup installed ($(borg --version | head -n1))"
  else
    step "Installing BorgBackup"
    sudo apt-get update -qq
    sudo apt-get install -y borgbackup
    success "borgbackup installed ($(borg --version | head -n1))"
  fi
}

ensure_envsubst() {
  # Needed to render the wrapper + systemd units from templates/backup-client/.
  if command -v envsubst >/dev/null 2>&1; then
    return 0
  fi
  step "Installing gettext-base (envsubst)"
  sudo apt-get update -qq
  sudo apt-get install -y gettext-base
  command -v envsubst >/dev/null 2>&1 || error "envsubst not available after install"
}

ssh_preflight() {
  step "SSH preflight to ${BACKUP_SERVER_USER}@${BACKUP_SERVER_HOST}:${BACKUP_SERVER_PORT}"
  # Run as BACKUP_USER (the timer user), not root: BatchMode host-key checks
  # use ~/.ssh/known_hosts — preflight must populate the SAME user's file.
  local ssh_base=(sudo -u "${BACKUP_USER}" ssh -o BatchMode=yes -o ConnectTimeout=10 -i "${BACKUP_SSH_KEY}" -p "${BACKUP_SERVER_PORT}" "${BACKUP_SERVER_USER}@${BACKUP_SERVER_HOST}")
  if ! "${ssh_base[@]}" true; then
    error "SSH BatchMode authentication failed. Set up key-based auth first:
  ssh-copy-id -i ${BACKUP_SSH_KEY} -p ${BACKUP_SERVER_PORT} ${BACKUP_SERVER_USER}@${BACKUP_SERVER_HOST}
  then re-run."
  fi
  success "SSH BatchMode authentication OK"

  local remote_ver local_ver
  remote_ver="$("${ssh_base[@]}" 'borg --version' 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  local_ver="$(borg --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ -n "$remote_ver" && -n "$local_ver" && "$remote_ver" != "$local_ver" ]]; then
    warn "Borg version mismatch: client ${local_ver} vs server ${remote_ver}."
    if [[ "$FORCE_VERSION_MISMATCH" != true ]]; then
      error "Refusing to continue on a major/minor mismatch — use --force-version-mismatch to override (apt borgbackup on the same Ubuntu release is the recommended fix)."
    fi
  elif [[ -n "$remote_ver" ]]; then
    success "Borg versions match (${local_ver})"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# REPO URI + PASSPHRASE + INIT
# ─────────────────────────────────────────────────────────────────────────────

resolve_repo_uri() {
  local repo_path
  repo_path="${BACKUP_REPO_PATH%/}"
  if [[ -z "$BACKUP_SERVER_HOST" ]]; then
    REPO_URI="${repo_path}/${BACKUP_CLIENT_NAME}"
    BORG_RSH=""
    info "Mode: LOCAL (repo: ${REPO_URI})"
    if [[ "$CHECK_ONLY" != true ]]; then
      # A freshly created parent would be root-owned while the timer runs as
      # BACKUP_USER; take ownership only of dirs we create, never touch an
      # existing (e.g. setup-backup-server-managed) tree's ownership.
      local parent="${repo_path%/*}"
      local need_parent=false need_repo=false
      if [[ -n "$parent" && ! -e "$parent" ]]; then need_parent=true; fi
       [[ -e "$repo_path" ]] || need_repo=true
       sudo mkdir -p "$repo_path"
       [[ -n "$parent" ]] && $need_parent && sudo chown "${BACKUP_USER}:${BACKUP_USER}" "$parent"
       $need_repo && sudo chown "${BACKUP_USER}:${BACKUP_USER}" "$repo_path"
      # Device the repo lives on, baked into the wrapper's create() mount
      # guard (empty when findmnt is unavailable/fails -> guard inactive).
      REPO_MOUNT_SOURCE="$(findmnt -n -o SOURCE --target "$repo_path" 2>/dev/null || true)"
    fi
  else
    REPO_URI="ssh://${BACKUP_SERVER_USER}@${BACKUP_SERVER_HOST}:${BACKUP_SERVER_PORT}${repo_path}/${BACKUP_CLIENT_NAME}"
    BORG_RSH="ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -i ${BACKUP_SSH_KEY}"
    info "Mode: REMOTE (repo: ${REPO_URI})"
  fi
}

ensure_passphrase() {
  step "Repo passphrase"
  if [[ -f "$PASS_FILE" ]]; then
    success "Reusing existing passphrase file: ${PASS_FILE}"
  else
    sudo mkdir -p "$PASS_DIR"
    sudo chmod 700 "$PASS_DIR"
    local pass group
    group="$(id -gn "${BACKUP_USER}" 2>/dev/null || id -gn)"
    # NOT `tr | head -c` — under `set -o pipefail` the killed `tr` makes the
    # pipeline return 141 (SIGPIPE). read -n stops after 32 chars and the
    # process substitution's exit status is ignored.
    IFS= read -r -n 32 pass < <(tr -dc 'A-Za-z0-9' < /dev/urandom)
    [[ -n "$pass" ]] || error "Could not generate a passphrase from /dev/urandom"
    printf '%s\n' "$pass" | sudo install -m 600 -o "$BACKUP_USER" -g "$group" /dev/stdin "$PASS_FILE"
    # .config may have just been created by root (mkdir -p above) — the whole
    # chain must belong to BACKUP_USER, who reads the file at every backup run.
    sudo chown "${BACKUP_USER}:${group}" "$PASS_DIR" 2>/dev/null || true
    sudo chown "${BACKUP_USER}:${group}" "${PASS_DIR%/*}" 2>/dev/null || true
    success "Generated passphrase -> ${PASS_FILE} (mode 600)"
    warn "Move this passphrase to your password manager NOW — it is stored only at ${PASS_FILE} and the passphrase file must never land inside a backed-up path."
  fi
  if [[ "$SHOW_PASSPHRASE" == true ]]; then
    info "Passphrase: $(cat "$PASS_FILE")"
  fi
}

# run_borg_as_user <probe|init> <borg args...>
#   Runs borg as BACKUP_USER (the timer user): host-key acceptance and the
#   chunk-cache land in the SAME home the daily service runs as. The
#   passphrase is read from its file INSIDE the target user's shell — never
#   via sudo --preserve-env (sudo-rs silently drops it; classic sudo needs a
#   setenv policy) and never on the ps-visible command line. 'init' also
#   exports BORG_NEW_PASSPHRASE (same value) so 'borg init' never prompts.
run_borg_as_user() {
  local mode="$1"; shift
  sudo -H -u "${BACKUP_USER}" sh -c '
    BORG_PASSPHRASE="$(cat "$1")"
    export BORG_PASSPHRASE
    if [ "$2" = init ]; then
      BORG_NEW_PASSPHRASE="$BORG_PASSPHRASE"
      export BORG_NEW_PASSPHRASE
    fi
    if [ -n "$3" ]; then BORG_RSH="$3"; export BORG_RSH; fi
    shift 3
    "$@"
  ' _ "$PASS_FILE" "$mode" "$BORG_RSH" "$@"
}

init_repo() {
  step "Repository"
  # apt borg 1.x only reads BORG_PASSPHRASE / BORG_NEW_PASSPHRASE from the
  # environment (the *_FILE variants are borg 2.x features).

  if run_borg_as_user probe borg list "$REPO_URI" >/dev/null 2>&1; then
    success "Repository exists and opens with the stored passphrase: ${REPO_URI}"
    return 0
  fi

  info "Initializing new repository: ${REPO_URI}"
  if run_borg_as_user init borg init -e repokey "$REPO_URI" >/dev/null; then
    success "Repository initialized: ${REPO_URI}"
  else
    error "Repository exists but the stored passphrase does not open it (or init failed). Restore ${PASS_FILE} from your password manager, then re-run."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# LIB + WRAPPER + UNITS
# ─────────────────────────────────────────────────────────────────────────────

install_lib() {
  step "Installing backup library"
  local src="${SCRIPT_DIR}/../lib/docker-backup.sh"
  [[ -f "$src" ]] || error "lib/docker-backup.sh not found next to the task scripts: ${src}"
  sudo mkdir -p "$(dirname "$LIB_DEST")"
  sudo install -m 644 "$src" "$LIB_DEST"
  success "Installed ${LIB_DEST}"
}

install_staging_dir() {
  # The wrapper (running as BACKUP_USER) creates <staging>/dumps itself, but
  # the staging parent (e.g. /var/backup-staging) needs to exist and be owned
  # by BACKUP_USER — the parent dir (/var) is root:root 755.
  step "Installing staging dir ${BACKUP_STAGING_DIR}"
  if [[ -d "$BACKUP_STAGING_DIR" ]]; then
    sudo chmod 700 "$BACKUP_STAGING_DIR"
    sudo chown "${BACKUP_USER}:${BACKUP_USER}" "$BACKUP_STAGING_DIR"
    success "Staging dir ready: ${BACKUP_STAGING_DIR} (dumps live in ${BACKUP_STAGING_DIR}/dumps)"
  else
    sudo install -d -m 700 -o "$BACKUP_USER" -g "$BACKUP_USER" "$BACKUP_STAGING_DIR"
    success "Created ${BACKUP_STAGING_DIR} (owner: ${BACKUP_USER}, mode 700)"
  fi
}

render_excludes_block() {
  local -a excl=(
    '(^|/)snap/'
    '(^|/)node_modules/'
    '(^|/)\.cache/'
    '(^|/)\.npm/'
    '(^|/)\.cargo/registry/'
    '(^|/)\.rustup/'
  )
  if [[ -n "$BACKUP_EXCLUDE_REGEXES" ]]; then
    local -a extra
    read -r -a extra <<< "$BACKUP_EXCLUDE_REGEXES"
    excl+=("${extra[@]}")
  fi
  local block="" re
  for re in "${excl[@]}"; do
    block+=" '${re}'"
  done
  printf '%s' "$block"
}

write_wrapper() {
  step "Generating wrapper ${WRAPPER_BIN}"
  GENERATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
  EXCLUDES_BLOCK="$(render_excludes_block)"

  # Render-time vars are substituted into the template; the wrapper's runtime
  # bash vars (CLIENT, ts, …) are absent from the list and stay literal.
  # shellcheck disable=SC2086  # a list of variable names, not expansions
  export BACKUP_CLIENT_NAME GENERATED_DATE REPO_URI PASS_FILE BORG_RSH \
    BACKUP_PATHS BACKUP_SERVICES BACKUP_STOP_SERVICES BACKUP_STAGING_DIR \
    REPO_MOUNT_SOURCE BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY BACKUP_KEEP_MONTHLY \
    BACKUP_COMPRESSION BACKUP_ONE_FILE_SYSTEM EXCLUDES_BLOCK
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${BACKUP_CLIENT_NAME} ${GENERATED_DATE} ${REPO_URI} ${PASS_FILE} ${BORG_RSH} ${BACKUP_PATHS} ${BACKUP_SERVICES} ${BACKUP_STOP_SERVICES} ${BACKUP_STAGING_DIR} ${REPO_MOUNT_SOURCE} ${BACKUP_KEEP_DAILY} ${BACKUP_KEEP_WEEKLY} ${BACKUP_KEEP_MONTHLY} ${BACKUP_COMPRESSION} ${BACKUP_ONE_FILE_SYSTEM} ${EXCLUDES_BLOCK}' \
    < "${TEMPLATE_DIR}/borg-backup-wrapper.sh" > "$tmp"
  sudo install -m 0755 "$tmp" "$WRAPPER_BIN"
  rm -f "$tmp"
  success "Wrapper installed: ${WRAPPER_BIN}"
}

write_units() {
  step "Installing systemd units"

  # shellcheck disable=SC2086  # a list of variable names, not expansions
  export BACKUP_CLIENT_NAME BACKUP_USER WRAPPER_BIN SERVICE_UNIT
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${BACKUP_CLIENT_NAME} ${BACKUP_USER} ${WRAPPER_BIN}' \
    < "${TEMPLATE_DIR}/borg-backup.service" | sudo tee "/etc/systemd/system/${SERVICE_UNIT}" >/dev/null
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${BACKUP_CLIENT_NAME} ${SERVICE_UNIT}' \
    < "${TEMPLATE_DIR}/borg-backup.timer" | sudo tee "/etc/systemd/system/${TIMER_UNIT}" >/dev/null

  sudo systemctl daemon-reload
  # enable is idempotent and required for persistence across reboots even
  # when the timer is already active (e.g. installed by a pre-[Install]
  # version of this script and left "static").
  sudo systemctl enable "${TIMER_UNIT}"
  if sudo systemctl is-active --quiet "${TIMER_UNIT}" 2>/dev/null; then
    success "Timer enabled (active, state preserved): ${TIMER_UNIT}"
  else
    sudo systemctl start "${TIMER_UNIT}"
    success "Timer enabled and started: ${TIMER_UNIT}"
  fi
}

run_initial_backup() {
  step "Initial backup (full — this can take a while)"
  warn "Starting the first full backup in the foreground..."
  if ! sudo -u "$BACKUP_USER" "$WRAPPER_BIN" create; then
    error "Initial backup FAILED — fix the issue and re-run: sudo ${WRAPPER_BIN} create"
  fi
  success "Initial backup completed"
}

# ─────────────────────────────────────────────────────────────────────────────
# --check MODE
# ─────────────────────────────────────────────────────────────────────────────

check_mode() {
  local failed=0
  step "Backup client status (${BACKUP_CLIENT_NAME})"

  if is_apt_package_installed borgbackup; then
    success "borg: $(borg --version | head -n1)"
  else
    failed=1; echo -e "${RED}[FAIL]${RESET} borgbackup not installed"
  fi

  if [[ -f "$PASS_FILE" ]]; then
    local mode
    mode="$(stat -c '%a' "$PASS_FILE")"
    if [[ "$mode" == "600" ]]; then
      success "Passphrase file: ${PASS_FILE} (mode 600)"
    else
      failed=1; echo -e "${RED}[FAIL]${RESET} Passphrase file mode is ${mode} (expected 600): ${PASS_FILE}"
    fi
  else
    failed=1; echo -e "${RED}[FAIL]${RESET} Passphrase file missing: ${PASS_FILE}"
  fi

  local pp=""
  if [[ -f "$PASS_FILE" ]]; then
    pp="$(cat "$PASS_FILE")"
    export BORG_PASSPHRASE="$pp"
  fi
  if [[ -n "${BORG_RSH:-}" ]]; then
    export BORG_RSH
  fi
  # When running as root, probe as BACKUP_USER so host-key acceptance and the
  # chunk-cache checks mirror the unattended timer runs. Empty array -> borg
  # runs directly with the env exported above (running AS BACKUP_USER).
  local -a as_user=()
  if [[ "$(id -u)" -eq 0 && -n "$pp" && "$(id -un)" != "$BACKUP_USER" ]]; then
    as_user=(run_borg_as_user probe)
  fi
  if [[ -f "$PASS_FILE" ]] && "${as_user[@]}" borg list "$REPO_URI" >/dev/null 2>&1; then
    success "Repo reachable: ${REPO_URI}"
  else
    failed=1; echo -e "${RED}[FAIL]${RESET} Repo not reachable / passphrase does not open it: ${REPO_URI}"
  fi

  if systemctl is-active --quiet "${TIMER_UNIT}" 2>/dev/null; then
    local next
    next="$(systemctl list-timers --no-legend "${TIMER_UNIT}" 2>/dev/null | awk '{print $1" "$2" "$3}' | head -n1 || echo unknown)"
    success "Timer active (next: ${next})"
  else
    failed=1; echo -e "${RED}[FAIL]${RESET} Timer not active: ${TIMER_UNIT} — systemctl enable --now ${TIMER_UNIT}"
  fi

  local result
  result="$(systemctl show -p Result --value "${SERVICE_UNIT}" 2>/dev/null || echo unknown)"
  if [[ "$result" == "success" || "$result" == "" ]]; then
    success "Last service run: ${result:-never ran}"
  else
    failed=1; echo -e "${RED}[FAIL]${RESET} Last service run: ${result} — journalctl -u ${SERVICE_UNIT}"
  fi

  if [[ -f "$PASS_FILE" ]]; then
    local snap
    snap="$("${as_user[@]}" borg list --short "$REPO_URI" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$snap" ]]; then
      success "Latest snapshot: ${snap}"
    else
      failed=1; echo -e "${RED}[FAIL]${RESET} No snapshots in repo yet"
    fi
  fi

  if [[ "$FULL_CHECK" == true && -f "$PASS_FILE" ]]; then
    step "Full integrity check (borg check --verify-data) — slow"
    if "${as_user[@]}" borg check --verify-data "$REPO_URI"; then
      success "Full integrity check passed"
    else
      failed=1; echo -e "${RED}[FAIL]${RESET} Full integrity check FAILED"
    fi
  fi

  echo
  if [[ "$failed" -ne 0 ]]; then
    error "Backup client check FAILED"
  fi
  success "Backup client check passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
  if [[ "$CHECK_ONLY" == true ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
      warn "--check is most useful as root (timer/service checks); continuing as $(id -un)"
    fi
    if [[ -z "$USER_HOME" ]]; then
      error "Backup user '${BACKUP_USER}' does not exist (no home directory) — use --local-user <name>"
    fi
    resolve_repo_uri
    check_mode
    return 0
  fi

  # Auto-detect the scope when the operator left it empty (before validate).
  [[ -z "$BACKUP_PATHS" ]] && detect_backup_paths
  [[ -z "$BACKUP_SERVICES" ]] && detect_backup_services

  # validate so argument errors surface before any privileged work
  validate

  ensure_borg
  ensure_envsubst

  if [[ -n "$BACKUP_SERVER_HOST" ]]; then
    ssh_preflight
  fi

  resolve_repo_uri
  ensure_passphrase
  init_repo
  install_lib
  if [[ -n "$BACKUP_SERVICES" ]]; then
    install_staging_dir
  fi
  write_wrapper
  write_units

  echo
  step "Backup client ready: ${BACKUP_CLIENT_NAME}"
  success "Repo:       ${REPO_URI}"
  success "Passphrase: ${PASS_FILE} (move it to your password manager!)"
  success "Paths:      ${BACKUP_PATHS}"
  if [[ -n "$BACKUP_SERVICES" ]]; then
    success "Services:   ${BACKUP_SERVICES} (dumps staged in ${BACKUP_STAGING_DIR}/dumps)"
  else
    info "Services:   none (plain file backup)"
  fi
  success "Timer:      ${TIMER_UNIT} (daily, next: $(systemctl list-timers --no-legend "${TIMER_UNIT}" | awk '{print $1" "$2}' | head -n1))"
  echo
  info "Manage:   sudo ${WRAPPER_BIN} <create|list|check|restore|restore-db>"
  info "Restore:  sudo ${WRAPPER_BIN} restore <snapshot> --dest <dir> [paths...]"
  info "Check:    sudo ./tasks/setup-backup-client.sh --client ${BACKUP_CLIENT_NAME} --host ${BACKUP_SERVER_HOST} --repo-path ${BACKUP_REPO_PATH} --check"

  if [[ "$BACKUP_RUN_INITIAL" == true ]]; then
    run_initial_backup
  fi
}

main "$@"
