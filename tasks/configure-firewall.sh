#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# configure-firewall.sh — Configure UFW firewall rules (lockout-safe)
# =============================================================================
#
# Description:
#   Configures UFW (Uncomplicated Firewall) rules for a development machine.
#   Uses sudo internally for privileged operations. Assumes default-deny policy.
#
#   Lockout guards:
#   - Over SSH, the script refuses to enable UFW if this session's port would
#     not be allowed (FIREWALL_ALLOW_SSH_MISMATCH=true is the explicit override).
#   - The first enable from a remote session arms the
#     'machine-setup-ufw-rollback' timer, which disables UFW again after
#     FIREWALL_ROLLBACK_MINUTES unless an operator cancels it — so a mistake
#     cannot cause a permanent lockout.
#   - Only the SSH port plus explicitly requested ports (FIREWALL_EXTRA_PORTS)
#     are opened; each service's own setup script opens its port.
#
# Environment Variables (optional):
#   SSHD_PORT (default: 2224)
#   FIREWALL_EXTRA_PORTS  Comma-separated extra ports, e.g. "1234/tcp,4096/tcp"
#   FIREWALL_ALLOW_SSH_MISMATCH  'true' = enable UFW even when this SSH
#                                session's port would not be allowed
#   FIREWALL_ARM_ROLLBACK   'true' (default) = arm the self-rollback timer on
#                           a first enable over SSH (set 'false' for headless CI)
#   FIREWALL_ROLLBACK_MINUTES  Self-rollback delay in minutes (default: 10)
#   LM_STUDIO_PORT, OPENCODE_PORT, OPENWEBUI_PORT, KUBERNETES_API_PORT,
#   GNOME_REMOTE_PORT, COMFYUI_PORT — displayed only; no rule is added for them here
#   (each service's own setup script opens its port)
#
# Usage:
#   ./configure-firewall.sh
#   SSHD_PORT=2224 FIREWALL_EXTRA_PORTS="1234/tcp,4096/tcp" ./configure-firewall.sh
#   ./configure-firewall.sh --help
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

Configures UFW (Uncomplicated Firewall) rules for a development machine.
Uses sudo internally for privileged operations. Assumes default-deny policy.
Only the SSH port and explicitly requested ports are opened — each service's
own setup script opens its port.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  SSHD_PORT                 SSH port to allow (default: 2224)
  FIREWALL_EXTRA_PORTS      Comma-separated extra ports to allow,
                            e.g. "1234/tcp,4096/tcp"
  FIREWALL_ALLOW_SSH_MISMATCH  'true' = enable UFW even when this SSH
                            session's port would not be allowed
                            (default: refuse — lockout protection)
  FIREWALL_ARM_ROLLBACK     'true' (default) = on a first enable over SSH,
                            arm the 'machine-setup-ufw-rollback' timer that
                            disables UFW again after FIREWALL_ROLLBACK_MINUTES
                            (set 'false' for headless CI)
  FIREWALL_ROLLBACK_MINUTES Self-rollback delay in minutes (default: 10)
  LM_STUDIO_PORT            (displayed only; rule not added by default) (default: 1234)
  OPENCODE_PORT             (displayed only; rule not added by default) (default: 4096)
  OPENWEBUI_PORT            (displayed only; rule not added by default) (default: 3333)
  KUBERNETES_API_PORT       (displayed only; rule not added by default) (default: 6443)
  GNOME_REMOTE_PORT         (displayed only; rule not added by default) (default: 3389)
  COMFYUI_PORT              (displayed only; rule not added by default) (default: 8188)

${BOLD}WARNING:${RESET} When running over SSH, ensure SSHD_PORT is correct before
enabling the firewall to avoid remote lockout. The lock-out pre-flight
refuses to enable UFW while this session's port would be cut, and the first
remote enable arms the self-rollback timer (stop it once a NEW ssh
connection works: 'sudo systemctl stop machine-setup-ufw-rollback.timer').
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
: "${SSHD_PORT:=2224}"
: "${FIREWALL_EXTRA_PORTS:=}"
: "${FIREWALL_ALLOW_SSH_MISMATCH:=}"
: "${FIREWALL_ARM_ROLLBACK:=true}"
: "${FIREWALL_ROLLBACK_MINUTES:=10}"
# Displayed only — each service's own setup script opens its port:
: "${LM_STUDIO_PORT:=1234}"
: "${OPENCODE_PORT:=4096}"
: "${OPENWEBUI_PORT:=3333}"
: "${KUBERNETES_API_PORT:=6443}"
: "${GNOME_REMOTE_PORT:=3389}"
: "${COMFYUI_PORT:=8188}"

# =============================================================================
# Helper functions
# =============================================================================

validate_port() {
  local port="$1" name="$2"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    error "${name}='${port}' is not a valid port number (must be 1-65535)"
  fi
}

# =============================================================================
# Main
# =============================================================================

step "Configuring UFW firewall"

# Check prerequisites
if ! ufw_available; then
  error "UFW is not installed. Please install ufw first."
fi

info "Current configuration:"
echo "  SSHD_PORT=${SSHD_PORT} (rule will be added)"
if [[ -n "${FIREWALL_EXTRA_PORTS}" ]]; then
  echo "  FIREWALL_EXTRA_PORTS=${FIREWALL_EXTRA_PORTS} (rules will be added)"
else
  echo "  FIREWALL_EXTRA_PORTS=<none>"
fi
echo "  LM_STUDIO_PORT=${LM_STUDIO_PORT} (displayed only)"
echo "  OPENCODE_PORT=${OPENCODE_PORT} (displayed only)"
echo "  OPENWEBUI_PORT=${OPENWEBUI_PORT} (displayed only)"
echo "  KUBERNETES_API_PORT=${KUBERNETES_API_PORT} (displayed only)"
echo "  GNOME_REMOTE_PORT=${GNOME_REMOTE_PORT} (displayed only)"
echo "  COMFYUI_PORT=${COMFYUI_PORT} (displayed only)"

# Validate the SSH port and the explicitly requested extra ports (before any
# state is changed).
validate_port "${SSHD_PORT}" "SSHD_PORT"
declare -a _extra_ports=() _extra_protos=()
if [[ -n "${FIREWALL_EXTRA_PORTS}" ]]; then
  IFS=',' read -ra _extras <<< "${FIREWALL_EXTRA_PORTS}"
  for _e in "${_extras[@]}"; do
    _e="${_e//[[:space:]]/}"
    if [[ -z "${_e}" ]]; then
      continue
    fi
    _port="${_e%%/*}"
    _proto="${_e##*/}"
    if [[ "${_proto}" == "${_e}" ]]; then
      _proto=tcp
    fi
    validate_port "${_port}" "FIREWALL_EXTRA_PORTS entry '${_e}'"
    if ! [[ "${_proto}" =~ ^(tcp|udp)$ ]]; then
      error "FIREWALL_EXTRA_PORTS entry '${_e}' has an invalid protocol (use <port> or <port>/tcp|udp)"
    fi
    _extra_ports+=( "${_port}" )
    _extra_protos+=( "${_proto}" )
  done
fi

# ---------------------------------------------------------------------------
# Lock-out pre-flight: never enable UFW while it would cut the live session
# ---------------------------------------------------------------------------
# ${SSH_CONNECTION} = "client_ip client_port server_ip server_port"
session_port=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  session_port="${SSH_CONNECTION##* }"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
  session_port="${SSH_CLIENT##* }"
fi

step "Lock-out pre-flight"
ufw_was_active=false
if ufw_active; then
  info "UFW already active — rules below are additive."
  ufw_was_active=true
fi

if [[ -n "${session_port}" ]]; then
  info "This session is connected on port ${session_port}."
  if ! ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE ":${SSHD_PORT}\$"; then
    warn "sshd is not listening on ${SSHD_PORT}. Run tasks/setup-sshd.sh with SSHD_PORT=${SSHD_PORT} first, or set SSHD_PORT=${session_port}."
  fi
  if [[ "${SSHD_PORT}" != "${session_port}" && "${FIREWALL_ALLOW_SSH_MISMATCH}" != "true" ]]; then
    error "Refusing to enable UFW: this SSH session is on port ${session_port}, but only ${SSHD_PORT} would be allowed. Re-run with SSHD_PORT=${session_port}, run tasks/setup-sshd.sh first, or set FIREWALL_ALLOW_SSH_MISMATCH=true if you are sure."
  fi
else
  info "No SSH_CONNECTION detected (local/console run) — session continuity check skipped."
fi

# Warn about every sshd listen port that the new rule set will NOT allow
# (the "sshd is on 22, you allow 2224" case, even when the session matches).
_sshd_listen_ports="$(sudo ss -Htlnp 2>/dev/null | awk '/users:\(\("sshd"/ || /users:\(\("systemd"/ { n = split($4, a, ":"); print a[n] }' | sort -un || true)"
while IFS= read -r _p; do
  if [[ -z "${_p}" || "${_p}" == "${SSHD_PORT}" ]]; then
    continue
  fi
  _extra_has=false
  if (( ${#_extra_ports[@]} > 0 )); then
    for _x in "${_extra_ports[@]}"; do
      if [[ "${_x}" == "${_p}" ]]; then
        _extra_has=true
        break
      fi
    done
  fi
  if [[ "${_extra_has}" != "true" ]]; then
    warn "sshd is also listening on port ${_p}, which will NOT be allowed by the firewall (reconnect only via ${SSHD_PORT})."
  fi
done <<< "${_sshd_listen_ports}"

# Show current status
step "Current firewall status"
ufw_show_status

step "Current configured rules"
sudo ufw show added || true

# Add the SSH rule FIRST to prevent lockout
ufw_add_rule "${SSHD_PORT}" "tcp" "SSHD"

# Extra ports the operator explicitly wants open, e.g. FIREWALL_EXTRA_PORTS="1234/tcp,4096/tcp"
# (Service setup scripts open their own ports; nothing is opened here on speculation.)
for _i in "${!_extra_ports[@]}"; do
  ufw_add_rule "${_extra_ports[$_i]}" "${_extra_protos[$_i]}" "EXTRA"
done

# ---------------------------------------------------------------------------
# Self-rollback for a first enable: 'ufw --force enable' is irreversible from
# the outside, so arm a self-defeating safety net when the firewall is turned
# on for the first time from a remote session. The timer is deliberately NOT
# cancelled at the end of this run — confirmation must come from a NEW
# connection.
# ---------------------------------------------------------------------------
rollback_unit="machine-setup-ufw-rollback"
if [[ "${ufw_was_active}" != "true" && -n "${session_port}" && "${FIREWALL_ARM_ROLLBACK}" == "true" ]] && command -v systemd-run >/dev/null; then
  step "Arming firewall self-rollback (${FIREWALL_ROLLBACK_MINUTES} min)"
  sudo systemd-run --quiet --no-block --unit="${rollback_unit}" \
    --on-active="${FIREWALL_ROLLBACK_MINUTES}min" /usr/sbin/ufw disable \
    || warn "Could not arm ${rollback_unit} (systemd-run failed) — verify access before leaving this session."
  warn "IF YOU LOSE ACCESS: the firewall disables itself in ${FIREWALL_ROLLBACK_MINUTES} minutes."
  warn "Console/IPMI: after you confirm a NEW ssh connection works, cancel with:  sudo systemctl stop ${rollback_unit}.timer"
  warn "Manual recovery from console/IPMI:  sudo ufw allow ${SSHD_PORT}/tcp   (or: sudo ufw disable)"
  info "This script does NOT cancel the timer — do it only after a NEW ssh connection works."
elif [[ "${ufw_was_active}" != "true" && -n "${session_port}" && "${FIREWALL_ARM_ROLLBACK}" != "true" ]]; then
  warn "Firewall self-rollback disabled by FIREWALL_ARM_ROLLBACK=false."
fi

# Enable firewall (non-interactive, prevents lockout)
step "Enabling firewall"
ufw_enable

# Show final status
step "Final firewall status"
ufw_show_status

success "Firewall configured successfully"
