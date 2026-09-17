#!/usr/bin/env bash
# =============================================================================
# setup-backup-server.sh — Central Borg backup infrastructure: storage host
# =============================================================================
#
# DESCRIPTION:
#   Turns one machine into the "dumb" storage host of a Borg backup fleet:
#   installs BorgBackup, prepares the backup storage (a mounted drive, or a
#   local directory on the main fs — the script never formats or edits fstab),
#   creates the repo directory layout, fixes group/ownership, and then runs the
#   client in local mode so a bare invocation yields a working self-backup.
#
#   More clients are added later with tasks/setup-backup-client.sh (this script
#   stores no passphrases and never deletes data).
#
# KEY ACTIONS:
#   1. Root + systemd pre-flight
#   2. Installs borgbackup if missing, reports version
#   3. Prepares ${BACKUP_MOUNT}: a separate mounted fs is verified present in
#      /etc/fstab (drive mode); otherwise it is created and used as a local
#      directory on the main fs (local-disk mode — warns: same disk)
#   4. Warns if free space < BACKUP_MIN_FREE_GB
#   5. Ensures ${BACKUP_GROUP} exists; adds ${BACKUP_USER} to it
#   6. Creates/verifies ${BACKUP_REPO_ROOT} and ${BACKUP_MANUAL_DIR}
#      (chown BACKUP_USER:BACKUP_GROUP, mode 775; existing data untouched)
#   7. Write-permission probe for ${BACKUP_USER}
#   8. Runs setup-backup-client.sh in local mode (--initial by default) with an
#      auto-detected scope + services, so backups are running at the end
#   9. Summary
#
#   --check: report install/version, mount + free space, group, layout and
#   exit non-zero on any problem (for future monitoring integration).
#
# IMPORTANT VARIABLES:
#   BACKUP_MOUNT        - Where repos live (default: /var/backups). A separate
#                         mounted drive = drive mode; the main fs = local-disk
#                         mode (warns: same disk, no protection vs disk failure)
#   BACKUP_REPO_ROOT    - Root for per-client borg repos (default: ${BACKUP_MOUNT}/automatic)
#   BACKUP_MANUAL_DIR   - Manual full-dump dir (default: ${BACKUP_MOUNT}/manual)
#   BACKUP_GROUP        - Group with write access to the mount (default: backups)
#   BACKUP_USER         - Regular user that must write repos (default: sudo caller)
#   BACKUP_MIN_FREE_GB  - Warn if the drive has less free GB (default: 100)
#
# USAGE:
#   sudo ./tasks/setup-backup-server.sh
#   BACKUP_MOUNT=/mnt/backup BACKUP_USER=alice sudo ./tasks/setup-backup-server.sh
#   sudo ./tasks/setup-backup-server.sh --check
#
# SPEC: specification/features/setup-backup-server.md (Behavior 1)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — all env vars with defaults
# ─────────────────────────────────────────────────────────────────────────────

BACKUP_MOUNT="${BACKUP_MOUNT:-/var/backups}"
BACKUP_REPO_ROOT="${BACKUP_REPO_ROOT:-${BACKUP_MOUNT}/automatic}"
BACKUP_MANUAL_DIR="${BACKUP_MANUAL_DIR:-${BACKUP_MOUNT}/manual}"
BACKUP_GROUP="${BACKUP_GROUP:-backups}"
BACKUP_USER="${BACKUP_USER:-${SUDO_USER:-$(id -un)}}"
BACKUP_MIN_FREE_GB="${BACKUP_MIN_FREE_GB:-100}"

# Self-backup: once the storage host is ready, run the client in local mode so
# a bare invocation yields a working backup. Empty BACKUP_PATHS /
# BACKUP_SERVICES let the client auto-detect the scope + services.
SELF_BACKUP=true
RUN_INITIAL=true
BACKUP_PATHS="${BACKUP_PATHS:-}"
BACKUP_SERVICES="${BACKUP_SERVICES:-}"
BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-}"
BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-}"

CHECK_ONLY=false

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<'HELP'
setup-backup-server.sh — set up this machine as the central Borg backup
storage host AND start a working self-backup in one step (installs borg,
prepares the backup storage, creates the repo layout, runs the client in
local mode).

Usage: sudo ./tasks/setup-backup-server.sh [OPTIONS]

Storage options:
  --mount <dir>        Where repos live (env: BACKUP_MOUNT, default:
                       /var/backups). A mounted drive = drive mode; the main
                       fs = local-disk mode (warns: same disk).
  --repo-root <dir>    Root for per-client borg repos
                       (env: BACKUP_REPO_ROOT, default: <mount>/automatic)
  --manual-dir <dir>   Manual full-dump directory
                       (env: BACKUP_MANUAL_DIR, default: <mount>/manual)
  --group <name>       Group with write access to the storage
                       (env: BACKUP_GROUP, default: backups)
  --user <name>        Regular user that must be able to write repos
                       (env: BACKUP_USER, default: the sudo caller)
  --min-free-gb <n>    Warn if the storage has less than n GB free
                       (env: BACKUP_MIN_FREE_GB, default: 100)

Self-backup options (forwarded to setup-backup-client.sh, local mode):
  --paths <p1 p2 ...>  Backup scope (env: BACKUP_PATHS). Omit to auto-detect.
  --services <a,b>     Docker services to dump (env: BACKUP_SERVICES). Omit to
                       auto-detect installed/running ones.
  --keep-daily <n>     Retention: daily archives to keep (env: BACKUP_KEEP_DAILY)
  --keep-weekly <n>    Retention: weekly archives to keep (env: BACKUP_KEEP_WEEKLY)
  --keep-monthly <n>   Retention: monthly archives to keep (env: BACKUP_KEEP_MONTHLY)
  --compression <alg>  lz4 or zstd (env: BACKUP_COMPRESSION, default: lz4)
  --no-self-backup     Prepare the storage host only; do not run the client
  --no-initial         Do not run the first full backup in the foreground

Other:
  --check              Report status, exit non-zero on problems (no changes)
  --help, -h           Show this help

Examples:
  sudo ./tasks/setup-backup-server.sh                       # zero-config
  sudo ./tasks/setup-backup-server.sh --paths "/home/u /etc /srv"
  BACKUP_MOUNT=/mnt/backup sudo ./tasks/setup-backup-server.sh   # drive mode
  sudo ./tasks/setup-backup-server.sh --check

A mounted backup drive is verified present in /etc/fstab (drive mode) but this
script never formats or edits fstab. With no drive mounted it falls back to a
local directory on the main fs (local-disk mode) and warns accordingly.

Spec: specification/features/setup-backup-server.md
HELP
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENTS
# ─────────────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount)        BACKUP_MOUNT="${2:?--mount needs a value}"; shift 2 ;;
    --repo-root)    BACKUP_REPO_ROOT="${2:?--repo-root needs a value}"; shift 2 ;;
    --manual-dir)   BACKUP_MANUAL_DIR="${2:?--manual-dir needs a value}"; shift 2 ;;
    --group)        BACKUP_GROUP="${2:?--group needs a value}"; shift 2 ;;
    --user)         BACKUP_USER="${2:?--user needs a value}"; shift 2 ;;
    --min-free-gb)  BACKUP_MIN_FREE_GB="${2:?--min-free-gb needs a value}"; shift 2 ;;
    --paths)        BACKUP_PATHS="${2:?--paths needs a value}"; shift 2 ;;
    --services)     BACKUP_SERVICES="${2:?--services needs a value}"; shift 2 ;;
    --keep-daily)   BACKUP_KEEP_DAILY="${2:?--keep-daily needs a value}"; shift 2 ;;
    --keep-weekly)  BACKUP_KEEP_WEEKLY="${2:?--keep-weekly needs a value}"; shift 2 ;;
    --keep-monthly) BACKUP_KEEP_MONTHLY="${2:?--keep-monthly needs a value}"; shift 2 ;;
    --compression)  BACKUP_COMPRESSION="${2:?--compression needs a value}"; shift 2 ;;
    --no-self-backup) SELF_BACKUP=false; shift ;;
    --no-initial)   RUN_INITIAL=false; shift ;;
    --check)        CHECK_ONLY=true; shift ;;
    --help|-h)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# LOAD HELPERS
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ─────────────────────────────────────────────────────────────────────────────
# SHARED CHECKS (used by --check and the full run)
# ─────────────────────────────────────────────────────────────────────────────

CHECKS_FAILED=0

# Storage mode: a "drive" is a separate mounted filesystem (different device
# than /) — verified fstab-persistent, protects against root-disk failure.
# "local" is a plain directory on the main fs — created if missing, warns it
# shares the disk with the data (guards software corruption, not disk failure).
STORAGE_MODE=""
ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
resolve_storage_mode() {
  local source
  source="$(findmnt -n -o SOURCE "${BACKUP_MOUNT}" 2>/dev/null || true)"
  if [[ -n "$source" && -n "$ROOT_DEV" && "$source" != "$ROOT_DEV" ]]; then
    STORAGE_MODE="drive"
  else
    STORAGE_MODE="local"
  fi
}

# Drive mode: ensure BACKUP_MOUNT is a mounted, fstab-persistent filesystem.
# Local mode: ensure the directory exists; warn it is on the main fs.
prepare_storage() {
  resolve_storage_mode
  if [[ "$STORAGE_MODE" == "drive" ]]; then
    if [[ ! -d "${BACKUP_MOUNT}" ]]; then
      error "${BACKUP_MOUNT} does not exist. Mount the backup drive first (this script never formats or mounts), e.g.:
  sudo mkdir -p ${BACKUP_MOUNT}
  sudo mount /dev/sdX1 ${BACKUP_MOUNT}
  sudo blkid /dev/sdX1          # get the UUID
  # add to /etc/fstab:  UUID=<uuid>  ${BACKUP_MOUNT}  ext4  defaults,noatime  0  2"
    fi
    step "Verifying backup drive ${BACKUP_MOUNT}"
    local fsinfo
    if ! fsinfo="$(_check_mount)"; then
      error "${BACKUP_MOUNT} is not a mounted filesystem. Mount the drive and add a /etc/fstab entry first:"
    fi
    _warn_fstype "${fsinfo%% *}"
    success "Mounted: ${BACKUP_MOUNT} (${fsinfo%% *})"
    info "Size: $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $2" total, "$4" free"}')"
    _check_free_space
    _check_fstab
  else
    if [[ ! -d "${BACKUP_MOUNT}" ]]; then
      step "Creating ${BACKUP_MOUNT}"
      sudo mkdir -p "${BACKUP_MOUNT}"
      success "${BACKUP_MOUNT} created"
    fi
    step "Backup storage ${BACKUP_MOUNT} (local disk)"
    info "Size: $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $2" total, "$4" free"}')"
    warn "Local-disk mode: ${BACKUP_MOUNT} is on the main filesystem — this protects against software corruption and accidental deletion, NOT disk failure. Mount a separate drive (--mount) for that."
    _check_free_space
  fi
}

_check_borg() {
  if is_apt_package_installed borgbackup; then
    success "borgbackup installed ($(borg --version 2>/dev/null | head -n1 || echo 'unknown'))"
  else
    if [[ "$CHECK_ONLY" == true ]]; then
      CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
      echo -e "${RED}[FAIL]${RESET} borgbackup not installed — run: sudo ./tasks/setup-backup-server.sh"
    else
      step "Installing BorgBackup"
      sudo apt-get update -qq
      sudo apt-get install -y borgbackup
      success "borgbackup installed ($(borg --version | head -n1))"
    fi
  fi
}

# Prints "<fstype> <uuid> <source>" for a mounted dir; returns 1 if not
# mounted. Must NOT log: stdout is captured by callers (a warn line here used
# to pollute the captured "<fstype> <uuid> <source>" value).
_check_mount() {
  local source fstype uuid
  source="$(findmnt -n -o SOURCE "${BACKUP_MOUNT}" 2>/dev/null || true)"
  [[ -n "$source" ]] || return 1
  fstype="$(findmnt -n -o FSTYPE "${BACKUP_MOUNT}" 2>/dev/null || true)"
  # UUID for the fstab persistence check (fall back to the raw device name).
  uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
  uuid="${uuid%%$'\n'*}"
  [[ -n "$uuid" ]] || uuid="$source"
  printf '%s %s %s\n' "$fstype" "$uuid" "$source"
}

# Called OUTSIDE command substitution to report an unexpected filesystem type.
_warn_fstype() {
  case "$1" in
    ext4|xfs|btrfs) : ;;
    *) warn "Mount ${BACKUP_MOUNT} has unexpected filesystem type: $1" ;;
  esac
}

_check_free_space() {
  local avail_gb
  avail_gb="$(df --output=avail -BG "${BACKUP_MOUNT}" | tail -n1 | tr -dc '0-9')"
  if [[ -n "$avail_gb" && "$avail_gb" -lt "$BACKUP_MIN_FREE_GB" ]]; then
    warn "Backup drive has only ${avail_gb}GB free (< ${BACKUP_MIN_FREE_GB}GB) — backups may exhaust it"
  fi
  return 0
}

_check_group() {
  if getent group "${BACKUP_GROUP}" >/dev/null; then
    success "Group '${BACKUP_GROUP}' exists"
  else
    if [[ "$CHECK_ONLY" == true ]]; then
      CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
      echo -e "${RED}[FAIL]${RESET} Group '${BACKUP_GROUP}' missing"
    else
      step "Creating group ${BACKUP_GROUP}"
      sudo groupadd "${BACKUP_GROUP}"
      success "Group '${BACKUP_GROUP}' created"
    fi
  fi

  if id -nG "${BACKUP_USER}" | tr ' ' '\n' | grep -qx "${BACKUP_GROUP}"; then
    success "User '${BACKUP_USER}' is in group '${BACKUP_GROUP}'"
  else
    if [[ "$CHECK_ONLY" == true ]]; then
      CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
      echo -e "${RED}[FAIL]${RESET} User '${BACKUP_USER}' not in group '${BACKUP_GROUP}'"
    else
      sudo usermod -aG "${BACKUP_GROUP}" "${BACKUP_USER}"
      success "User '${BACKUP_USER}' added to group '${BACKUP_GROUP}'"
    fi
  fi
}

_check_layout() {
  local dir
  for dir in "${BACKUP_REPO_ROOT}" "${BACKUP_MANUAL_DIR}"; do
    if [[ -d "$dir" ]]; then
      local owner
      owner="$(stat -c '%U:%G' "$dir")"
      if [[ "$owner" != "${BACKUP_USER}:${BACKUP_GROUP}" ]]; then
        if [[ "$CHECK_ONLY" == true ]]; then
          CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
          echo -e "${RED}[FAIL]${RESET} ${dir} owned by ${owner} (expected ${BACKUP_USER}:${BACKUP_GROUP})"
        else
          warn "${dir} owned by ${owner} — re-chowning to ${BACKUP_USER}:${BACKUP_GROUP} (contents are never touched)"
          sudo chown "${BACKUP_USER}:${BACKUP_GROUP}" "$dir"
          success "${dir} ownership fixed"
        fi
      else
        success "${dir} exists (owned ${owner})"
      fi
      [[ "$CHECK_ONLY" == true ]] || sudo chmod 775 "$dir"
    else
      if [[ "$CHECK_ONLY" == true ]]; then
        CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
        echo -e "${RED}[FAIL]${RESET} ${dir} missing"
      else
        step "Creating ${dir}"
        sudo mkdir -p "$dir"
        sudo chown "${BACKUP_USER}:${BACKUP_GROUP}" "$dir"
        sudo chmod 775 "$dir"
        success "${dir} created"
      fi
    fi
  done

  # Write probe: the repo root must be writable by BACKUP_USER — covers both
  # root:group and user:user mount ownership layouts.
  if sudo -u "${BACKUP_USER}" bash -c "touch '${BACKUP_REPO_ROOT}/.write-probe' && rm -f '${BACKUP_REPO_ROOT}/.write-probe'" 2>/dev/null; then
    success "${BACKUP_USER} can write ${BACKUP_REPO_ROOT}"
  else
    if [[ "$CHECK_ONLY" == true ]]; then
      CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
      echo -e "${RED}[FAIL]${RESET} ${BACKUP_USER} cannot write ${BACKUP_REPO_ROOT}"
    else
      error "${BACKUP_USER} cannot write ${BACKUP_REPO_ROOT} — check the mount's ownership/options (e.g. user/group/fmask in fstab)"
    fi
  fi
}

_check_fstab() {
  local fsinfo fstype uuid source
  fsinfo="$(_check_mount)" || return 1
  fstype="${fsinfo%% *}"; uuid="${fsinfo#* }"; uuid="${uuid%% *}"; source="${fsinfo##* }"
  local persistent=false
  if command -v findmnt >/dev/null 2>&1; then
    # Precise primitive: is this mount point listed in /etc/fstab at all?
    findmnt --fstab -n -o SOURCE "${BACKUP_MOUNT}" >/dev/null 2>&1 && persistent=true
  else
    # Fallback without findmnt: fstab line referencing this exact uuid or device.
    grep -qsF "$uuid" /etc/fstab && persistent=true
    grep -qsF "$source" /etc/fstab && persistent=true
  fi
  if [[ "$persistent" == true ]]; then
    success "${BACKUP_MOUNT} is fstab-persistent (${fstype}, ${uuid})"
  elif [[ "$CHECK_ONLY" == true ]]; then
    CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
    echo -e "${RED}[FAIL]${RESET} No /etc/fstab entry for ${BACKUP_MOUNT} (${uuid}) — the mount may not survive reboots"
  else
    error "No /etc/fstab entry for ${BACKUP_MOUNT} (${uuid}) — the mount may not survive reboots. Add one first (this script never edits fstab), e.g.:
  UUID=${uuid}  ${BACKUP_MOUNT}  ${fstype}  defaults,noatime  0  2"
  fi
  return 0
}

_check_report() {
  step "Backup server status"
  resolve_storage_mode
  if [[ "$STORAGE_MODE" == "drive" ]]; then
    local fsinfo
    if fsinfo="$(_check_mount)"; then
      _warn_fstype "${fsinfo%% *}"
      success "Mount: ${BACKUP_MOUNT} (${fsinfo%% *}, $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $2" total, "$4" free"}'))"
      _check_fstab
    else
      CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
      echo -e "${RED}[FAIL]${RESET} ${BACKUP_MOUNT} is not a mounted filesystem"
      echo -e "${RED}[FAIL]${RESET} Mount the backup drive and add a /etc/fstab entry first, then re-run."
    fi
  else
    if [[ -d "${BACKUP_MOUNT}" ]]; then
      success "Storage: ${BACKUP_MOUNT} (local disk, $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $4" free"}'))"
    else
      CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
      echo -e "${RED}[FAIL]${RESET} ${BACKUP_MOUNT} does not exist"
    fi
  fi
  _check_borg
  _check_free_space
  _check_group
  _check_layout

  if [[ "$CHECKS_FAILED" -gt 0 ]]; then
    echo
    error "Backup server check FAILED (${CHECKS_FAILED} problem(s))"
  fi
  success "Backup server check passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

# Run the client in local mode so a bare invocation yields a working
# self-backup. Scope options are forwarded; empty values let the client
# auto-detect. Fails the run if the client fails.
run_self_backup() {
  echo
  step "Running self-backup (local mode)"
  local -a args=()
  [[ "$RUN_INITIAL" == true ]] && args+=(--initial)
  env \
    BACKUP_SERVER_HOST="" \
    BACKUP_REPO_PATH="${BACKUP_REPO_ROOT}" \
    BACKUP_USER="${BACKUP_USER}" \
    BACKUP_PATHS="${BACKUP_PATHS}" \
    BACKUP_SERVICES="${BACKUP_SERVICES}" \
    BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY}" \
    BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY}" \
    BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY}" \
    BACKUP_COMPRESSION="${BACKUP_COMPRESSION}" \
    bash "${SCRIPT_DIR}/setup-backup-client.sh" "${args[@]}"
}

main() {
  if ! getent passwd "${BACKUP_USER}" >/dev/null; then
    error "User '${BACKUP_USER}' does not exist"
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    _check_report
    return 0
  fi

  prepare_storage

  _check_borg
  _check_group
  _check_layout

  echo
  step "Backup server ready"
  success "Repo root:   ${BACKUP_REPO_ROOT}"
  success "Manual dir:  ${BACKUP_MANUAL_DIR}"
  success "Group:       ${BACKUP_GROUP} (user: ${BACKUP_USER})"
  success "Free space:  $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $4}')"

  if [[ "$SELF_BACKUP" == true ]]; then
    run_self_backup
  else
    echo
    info "Add another client (from a client machine):"
    cat <<ADDCLIENT
  sudo ${SCRIPT_DIR}/setup-backup-client.sh \\
    --client <name> --host <this-host> --port 22 --user ${BACKUP_USER} \\
    --repo-path ${BACKUP_REPO_ROOT} --paths "<paths>" --services "<services>" --initial
ADDCLIENT
    info "Or on this host: sudo ${SCRIPT_DIR}/setup-backup-client.sh --paths \"<paths>\" (local mode)."
  fi
}

main "$@"
