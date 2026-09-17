#!/usr/bin/env bash
# =============================================================================
# setup-backup-server.sh — Central Borg backup infrastructure: storage host
# =============================================================================
#
# DESCRIPTION:
#   Turns one machine into the "dumb" storage host of a Borg backup fleet:
#   installs BorgBackup, verifies the backup drive (mounted + fstab-persistent
#   — the script never formats or edits fstab), creates the repo directory
#   layout, and fixes group/ownership so regular users can push encrypted
#   repos via SSH (`borg serve` is implicit in sshd).
#
#   Clients are added with tasks/setup-backup-client.sh — this script makes
#   no client-side changes, stores no passphrases, and never deletes data.
#
# KEY ACTIONS:
#   1. Root + systemd pre-flight
#   2. Installs borgbackup if missing, reports version
#   3. Verifies ${BACKUP_MOUNT} is a mounted fs (ext4/xfs/btrfs) present in /etc/fstab
#   4. Warns if free space < BACKUP_MIN_FREE_GB
#   5. Ensures ${BACKUP_GROUP} exists; adds ${BACKUP_USER} to it
#   6. Creates/verifies ${BACKUP_REPO_ROOT} and ${BACKUP_MANUAL_DIR}
#      (chown BACKUP_USER:BACKUP_GROUP, mode 775; existing data untouched)
#   7. Write-permission probe for ${BACKUP_USER}
#   8. Summary + exact client invocation
#
#   --check: report install/version, mount + free space, group, layout and
#   exit non-zero on any problem (for future monitoring integration).
#
# IMPORTANT VARIABLES:
#   BACKUP_MOUNT        - Mount point of the backup drive (default: /media/backups)
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

BACKUP_MOUNT="${BACKUP_MOUNT:-/media/backups}"
BACKUP_REPO_ROOT="${BACKUP_REPO_ROOT:-${BACKUP_MOUNT}/automatic}"
BACKUP_MANUAL_DIR="${BACKUP_MANUAL_DIR:-${BACKUP_MOUNT}/manual}"
BACKUP_GROUP="${BACKUP_GROUP:-backups}"
BACKUP_USER="${BACKUP_USER:-${SUDO_USER:-$(id -un)}}"
BACKUP_MIN_FREE_GB="${BACKUP_MIN_FREE_GB:-100}"

CHECK_ONLY=false

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<'HELP'
setup-backup-server.sh — set up this machine as the central Borg backup
storage host (installs borg, verifies the drive, creates the repo layout).

Usage: sudo ./tasks/setup-backup-server.sh [OPTIONS]

Options:
  --mount <dir>        Mount point of the backup drive
                       (env: BACKUP_MOUNT, default: /media/backups)
  --repo-root <dir>    Root for per-client borg repos
                       (env: BACKUP_REPO_ROOT, default: <mount>/automatic)
  --manual-dir <dir>   Manual full-dump directory
                       (env: BACKUP_MANUAL_DIR, default: <mount>/manual)
  --group <name>       Group with write access to the mount
                       (env: BACKUP_GROUP, default: backups)
  --user <name>        Regular user that must be able to write repos
                        (env: BACKUP_USER, default: the sudo caller)
  --min-free-gb <n>    Warn if the drive has less than n GB free
                       (env: BACKUP_MIN_FREE_GB, default: 100)
  --check              Report status, exit non-zero on problems (no changes)
  --help, -h           Show this help

Examples:
  sudo ./tasks/setup-backup-server.sh
  BACKUP_MOUNT=/mnt/backup BACKUP_USER=alice sudo ./tasks/setup-backup-server.sh
  sudo ./tasks/setup-backup-server.sh --check

The backup drive must already be mounted AND persistent in /etc/fstab —
this script verifies that state but never formats or edits fstab.

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
  local fsinfo
  if fsinfo="$(_check_mount)"; then
    _warn_fstype "${fsinfo%% *}"
    success "Mount: ${BACKUP_MOUNT} (${fsinfo%% *}, $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $2" total, "$4" free"}'))"
  else
    CHECKS_FAILED=$(( CHECKS_FAILED + 1 ))
    echo -e "${RED}[FAIL]${RESET} ${BACKUP_MOUNT} is not a mounted filesystem"
    echo -e "${RED}[FAIL]${RESET} Mount the backup drive and add a /etc/fstab entry first, then re-run."
  fi
  _check_borg
  _check_free_space
  _check_group
  _check_layout
  if [[ -z "${fsinfo:-}" ]]; then
    :
  else
    _check_fstab
  fi

  if [[ "$CHECKS_FAILED" -gt 0 ]]; then
    echo
    error "Backup server check FAILED (${CHECKS_FAILED} problem(s))"
  fi
  success "Backup server check passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "Run as root: sudo ./tasks/setup-backup-server.sh"
  fi

  if ! getent passwd "${BACKUP_USER}" >/dev/null; then
    error "User '${BACKUP_USER}' does not exist"
  fi

  if [[ ! -d "${BACKUP_MOUNT}" ]]; then
    error "${BACKUP_MOUNT} does not exist. Mount the backup drive first (this script never formats or mounts), e.g.:
  sudo mkdir -p ${BACKUP_MOUNT}
  sudo mount /dev/sdX1 ${BACKUP_MOUNT}
  sudo blkid /dev/sdX1          # get the UUID
  # add to /etc/fstab:  UUID=<uuid>  ${BACKUP_MOUNT}  ext4  defaults,noatime  0  2"
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    _check_report
    return 0
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

  _check_borg
  _check_group
  _check_layout

  echo
  step "Backup server ready"
  success "Repo root:   ${BACKUP_REPO_ROOT}"
  success "Manual dir:  ${BACKUP_MANUAL_DIR}"
  success "Group:       ${BACKUP_GROUP} (user: ${BACKUP_USER})"
  success "Free space:  $(df -h "${BACKUP_MOUNT}" | tail -n1 | awk '{print $4}')"
  echo
  info "Add a client (from the client machine):"
  cat <<ADDCLIENT
  sudo ${SCRIPT_DIR}/setup-backup-client.sh \\
    --client <name> --host <this-host> --port 22 --user ${BACKUP_USER} \\
    --repo-path ${BACKUP_REPO_ROOT} --paths "<paths>" --services "<services>" --initial
ADDCLIENT
  info "Or run: sudo ./tasks/setup-backup-client.sh --client <name> --paths \"<paths>\" (local mode, this host backs up itself)."
}

main "$@"
