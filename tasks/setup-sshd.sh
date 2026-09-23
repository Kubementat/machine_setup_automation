#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-sshd.sh — Configure SSH server (lockout-safe drop-in)
# =============================================================================
#
# Description:
#   Installs the OpenSSH server and configures it through a managed drop-in
#   (/etc/ssh/sshd_config.d/99-machine-setup.conf). The main sshd_config is
#   never modified — Ubuntu's `Include /etc/ssh/sshd_config.d/*.conf` runs
#   first, so appended lines in the main file are unreliable.
#
#   Lockout guards (this script must never make the server unreachable):
#   - 'PasswordAuthentication no' is only written when a usable public key
#     already exists in ~/.ssh/authorized_keys (otherwise SSHD_ALLOW_PASSWORDAUTH
#     must be 'yes').
#   - When the port changes, the previous/live session port keeps listening.
#   - The new port is allowed in UFW (when available) BEFORE the restart.
#   - On socket-activated systems (Ubuntu 24.04+ default, ssh.socket), the
#     socket is disabled when the new port set would not be served by it —
#     a socket-activated sshd does NOT bind extra 'Port' lines from the config.
#   - 'sshd -t' validates the whole config tree before any restart; an invalid
#     drop-in is reverted and the service is NOT restarted.
#   - After the restart, the EFFECTIVE config is proven via 'sshd -T'.
#
# Environment Variables (optional):
#   SSHD_PORT                 SSH daemon port (default: 2224)
#   SSHD_LEGACY_PORT          Extra port to keep listening on while migrating
#                             (the live session port is added automatically
#                             when it differs from SSHD_PORT)
#   SSHD_ALLOW_PASSWORDAUTH   'yes' keeps 'PasswordAuthentication yes' when no
#                             usable public key is present (default: refuse)
#
# Usage:
#   ./setup-sshd.sh
#   SSHD_PORT=2224 ./setup-sshd.sh
#   ./setup-sshd.sh --help
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

Installs the OpenSSH server and configures it via the managed drop-in
/etc/ssh/sshd_config.d/99-machine-setup.conf (the main sshd_config is never
touched). Idempotent: an unchanged drop-in does not trigger a restart.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  SSHD_PORT                 SSH daemon port (default: 2224)
  SSHD_LEGACY_PORT          Extra port to keep listening on while migrating
                            (the live session port is added automatically when
                            it differs from SSHD_PORT)
  SSHD_ALLOW_PASSWORDAUTH   'yes' keeps 'PasswordAuthentication yes' when no
                            usable public key is present (default: refuse)

${BOLD}Lockout guards:${RESET}
  - 'PasswordAuthentication no' only when a usable key is in
    ~/.ssh/authorized_keys
  - when moving the port, the old/live port keeps listening
  - the new port is allowed in UFW before the restart
  - socket-activated ssh (ssh.socket) is disabled for a port move, since a
    socket-activated sshd would not bind the new port
  - 'sshd -t' validates before any restart (invalid drop-in is reverted)
  - the effective config is proven with 'sshd -T' after the restart

${BOLD}Note:${RESET} Keep this session open and test a NEW connection from a
second terminal before closing it.
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
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-machine-setup.conf"

if ! [[ "${SSHD_PORT}" =~ ^[0-9]+$ ]] || (( SSHD_PORT < 1 || SSHD_PORT > 65535 )); then
  error "SSHD_PORT='${SSHD_PORT}' is not a valid port (must be 1-65535)"
fi
if [[ -n "${SSHD_LEGACY_PORT:-}" ]] && { ! [[ "${SSHD_LEGACY_PORT}" =~ ^[0-9]+$ ]] || (( SSHD_LEGACY_PORT < 1 || SSHD_LEGACY_PORT > 65535 )); }; then
  error "SSHD_LEGACY_PORT='${SSHD_LEGACY_PORT}' is not a valid port (must be 1-65535)"
fi

# ---------------------------------------------------------------------------
# 'sshd -t' / 'sshd -T' require the privilege-separation runtime directory,
# which systemd creates only while ssh.service is active (RuntimeDirectory=sshd)
# and removes on stop. A standalone validation right after a clean stop
# (e.g. an openssh package upgrade that leaves the service stopped on
# socket-activated systems) would fail with "Missing privilege separation
# directory: /run/sshd" — a false config error. Create it when absent, with
# the same ownership/mode the unit would use.
# ---------------------------------------------------------------------------
ensure_sshd_runtime_dir() {
  if [[ ! -d /run/sshd ]]; then
    sudo mkdir -p -m 0755 /run/sshd
  fi
}

# =============================================================================
# Main
# =============================================================================

step "Setting up SSH server (port: ${SSHD_PORT})"

# Install OpenSSH server
step "Installing openssh-server"
sudo apt update
sudo apt install -y openssh-server

# Show SSH status
step "SSHD current status"
sudo systemctl status sshd --no-pager || true

# ---------------------------------------------------------------------------
# Authorized keys first — never disable password auth without a usable key
# ---------------------------------------------------------------------------
step "Preparing ~/.ssh directory"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/authorized_keys"
chmod 600 "${HOME}/.ssh/authorized_keys"

# Match the key type of any real public key line (incl. FIDO2/sk- variants).
if ! grep -qsE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-|ecdsa-ssh-)ed25519)(@[a-zA-Z0-9.-]+)?[[:space:]]' "${HOME}/.ssh/authorized_keys"; then
  if [[ "${SSHD_ALLOW_PASSWORDAUTH:-}" == "yes" ]]; then
    warn "No public key in ${HOME}/.ssh/authorized_keys — PasswordAuthentication stays 'yes' (SSHD_ALLOW_PASSWORDAUTH=yes)."
    PASSWORD_AUTH="yes"
  else
    error "No usable public key in ${HOME}/.ssh/authorized_keys — refusing to set 'PasswordAuthentication no' (lockout risk). Add your key, or re-run with SSHD_ALLOW_PASSWORDAUTH=yes to keep password auth on."
  fi
else
  info "Usable public key found in ${HOME}/.ssh/authorized_keys"
  PASSWORD_AUTH="no"
fi

# ---------------------------------------------------------------------------
# Drop-in config (the main sshd_config is left untouched)
# ---------------------------------------------------------------------------
step "Writing sshd drop-in"

# Listen on the previous port too when we are moving off it, so the live
# session (and any scripted client) survives the restart.
ports=( "${SSHD_PORT}" )
if [[ -n "${SSHD_LEGACY_PORT:-}" && "${SSHD_LEGACY_PORT}" != "${SSHD_PORT}" ]]; then
  ports+=( "${SSHD_LEGACY_PORT}" )
  warn "sshd will listen on BOTH ${SSHD_LEGACY_PORT} (legacy) and ${SSHD_PORT}. Re-run with SSHD_LEGACY_PORT unset once ${SSHD_PORT} is confirmed working."
elif [[ -n "${SSH_CONNECTION:-}" && "${SSH_CONNECTION##* }" != "${SSHD_PORT}" ]]; then
  live_port="${SSH_CONNECTION##* }"
  ports+=( "${live_port}" )
  warn "Current SSH session is on port ${live_port}; sshd will keep listening there as well. Remove it once you can connect on ${SSHD_PORT}."
fi

_dropin_tmp="$(mktemp)"
{
  printf '# Managed by kwisatz setup-sshd.sh — do not edit by hand.\n'
  printf 'PubkeyAuthentication yes\n'
  printf 'PasswordAuthentication %s\n' "${PASSWORD_AUTH}"
  for p in "${ports[@]}"; do printf 'Port %s\n' "$p"; done
} > "${_dropin_tmp}"

info "Rendering drop-in for ports: ${ports[*]} (PasswordAuthentication ${PASSWORD_AUTH})"

# Idempotent install: an unchanged drop-in does not need a restart.
if sudo cmp -s "${_dropin_tmp}" "${SSHD_DROPIN}" 2>/dev/null; then
  info "Drop-in ${SSHD_DROPIN} unchanged — sshd will NOT be restarted"
  rm -f "${_dropin_tmp}"
  _dropin_changed=false
else
  sudo install -m 600 -o root -g root "${_dropin_tmp}" "${SSHD_DROPIN}"
  rm -f "${_dropin_tmp}"
  info "Drop-in ${SSHD_DROPIN} installed:"
  sudo sed 's/^/    /' "${SSHD_DROPIN}"
  _dropin_changed=true
fi

# Allow the new port in UFW BEFORE the restart (adding rules while UFW is
# inactive is only a warning; an unreadable status fails loudly — ticket 02).
if ufw_available; then
  ufw_add_rule "${SSHD_PORT}" "tcp" "SSHD (setup-sshd)"
fi

# ---------------------------------------------------------------------------
# Validate, then restart (revert on invalid config)
# ---------------------------------------------------------------------------
if [[ "${_dropin_changed}" == "true" ]]; then
  warn "Keeping this session open: test a NEW connection (ssh -p ${SSHD_PORT}) from a second terminal BEFORE closing it."

  ensure_sshd_runtime_dir
  if ! sudo sshd -t; then
    sudo rm -f "${SSHD_DROPIN}"
    sudo sshd -t || error "sshd config is invalid even after reverting ${SSHD_DROPIN} — inspect /etc/ssh/sshd_config and /etc/ssh/sshd_config.d/ before restarting sshd."
    warn "Reverted ${SSHD_DROPIN}; sshd was NOT restarted."
    error "Invalid sshd drop-in (see 'sshd -t' output above)."
  fi

  # Socket-activated sshd (Ubuntu 24.04+ default: ssh.socket owns the port)
  # does NOT bind extra 'Port' lines from the config, so a port move would
  # silently keep listening only on the socket's port. Keep the socket only
  # when it already serves exactly the configured port set; otherwise switch
  # to plain service activation (existing connections survive; the service
  # re-listens on the legacy/live port as well right after the restart).
  if sudo systemctl is-active --quiet ssh.socket 2>/dev/null; then
    # 'Listen' (not 'ListenStream') is the property this systemd version
    # exposes; the addresses are generated from sshd_config by the ssh generator.
    _sock_port_list="$(systemctl show -p Listen --value ssh.socket 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | sort -un || true)"
    if [[ "$(printf '%s\n' "${ports[@]}" | sort -un | wc -l)" -eq 1 && "${_sock_port_list}" == "${SSHD_PORT}" ]]; then
      info "ssh.socket is active and already serves port ${SSHD_PORT} — keeping socket activation."
    else
      warn "sshd is socket-activated (ssh.socket serves: ${_sock_port_list:-unknown}). Disabling the socket so sshd binds port ${SSHD_PORT} (service activation)."
      sudo systemctl disable --now ssh.socket
    fi
  fi

  step "Restarting SSH service"
  sudo systemctl enable --now ssh
  sudo systemctl restart ssh
else
  info "sshd service not restarted (config unchanged)"
fi

# ---------------------------------------------------------------------------
# Prove the EFFECTIVE config (Ubuntu's Include position makes this the only
# trustworthy check)
# ---------------------------------------------------------------------------
step "Verifying effective sshd configuration"
ensure_sshd_runtime_dir
_effective=""
if ! _effective="$(sudo sshd -T 2>/dev/null | grep -Ei '^(port|passwordauthentication|pubkeyauthentication) ' | sort -u)"; then
  # Without this guard a failing 'sshd -T' would kill the script silently
  # under 'set -euo pipefail' (stderr is redirected) instead of failing loudly.
  error "Could not read the effective sshd configuration ('sudo sshd -T' failed) — inspect the sshd configuration before continuing."
fi
echo "${_effective}"
if [[ "${PASSWORD_AUTH}" == "no" ]] && ! grep -qi '^passwordauthentication no' <<<"${_effective}"; then
  error "sshd is still not running with PasswordAuthentication no (an earlier Include/drop-in wins). Inspect: sudo sshd -T"
fi
if ! ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE ":${SSHD_PORT}\$"; then
  error "sshd is not listening on ${SSHD_PORT} — verify from a SECOND terminal before closing this session."
fi

success "SSH server configured successfully"
info "Connect with: ssh -p ${SSHD_PORT} $(whoami)@$(hostname -I | awk '{print $1}')"
