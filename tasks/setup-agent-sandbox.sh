#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-agent-sandbox.sh — bwrap sandbox prerequisites + asb wrapper
# =============================================================================
#
# Description:
#   Configures the bubblewrap (bwrap) sandboxing prerequisites on the host so
#   that sandboxed coding-agent runs (asb pi ..., asb opencode ...) work out
#   of the box on Ubuntu 24.04+:
#
#     1. installs the apt packages (default: bubblewrap)
#     2. lifts the AppArmor "unprivileged userns" restriction for bwrap ONLY,
#        via a one-file AppArmor profile (/etc/apparmor.d/bwrap) — the
#        documented Ubuntu 24.04+ blocker; skipped when AppArmor is not
#        active (no restriction to lift there)
#     3. verifies bwrap with a hard smoke test (bounded, non-zero exit on
#        failure with an actionable hint)
#     4. installs the asb wrapper (templates/agent-sandbox/asb) to
#        /usr/local/bin/asb (root-owned, mode 755)
#     5. verifies asb with a real sandboxed one-shot (hard failure on error)
#
# Idempotent: re-runs skip already-installed packages and only touch the
# AppArmor profile and the asb file when their content actually changed.
#
# Out of scope (deliberate): egress allowlist proxy (v2), seccomp, Landlock,
# dotfile masking, audit log, herdr server-side detection tuning.
#
# Environment Variables (optional):
#   SANDBOX_APT_PACKAGES   space/comma-separated apt packages (default: bubblewrap)
#   BWRAP_VERIFY_TIMEOUT   seconds allowed for the bwrap smoke test (default: 15)
#
# Usage:
#   ./setup-agent-sandbox.sh
#   ./setup-agent-sandbox.sh --help
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

Configures the bubblewrap (bwrap) sandboxing prerequisites on the host so
sandboxed coding-agent runs work out of the box on Ubuntu 24.04+:

  1. installs the apt packages (default: bubblewrap)
  2. lifts the AppArmor "unprivileged userns" restriction for bwrap ONLY
     (one-file profile /etc/apparmor.d/bwrap, the documented Ubuntu 24.04+
     blocker); skipped when AppArmor is not active
  3. verifies bwrap with a hard smoke test (bounded; non-zero exit on
     failure with an actionable hint)
  4. installs the asb wrapper (templates/agent-sandbox/asb) to
     /usr/local/bin/asb (root-owned, mode 755)
  5. verifies asb with a real sandboxed one-shot (hard failure on error)

Idempotent: re-runs skip installed packages and only touch the AppArmor
profile / asb file when their content changed.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  SANDBOX_APT_PACKAGES   Space/comma-separated apt packages for the sandbox
                         step (default: bubblewrap)
  BWRAP_VERIFY_TIMEOUT   Seconds allowed for the bwrap smoke test
                         (default: 15)

${BOLD}Result:${RESET} after a successful run, agents can be launched
sandboxed with:  asb pi [workspace] [args...] / asb opencode [workspace] [args...]
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
SANDBOX_APT_PACKAGES="${SANDBOX_APT_PACKAGES:-bubblewrap}"
BWRAP_VERIFY_TIMEOUT="${BWRAP_VERIFY_TIMEOUT:-15}"

TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/agent-sandbox")"
[[ -d "$TEMPLATE_DIR" ]] || error "template directory not found: ${TEMPLATE_DIR}"

# Temp files to clean up on exit
TMP_FILES=()
cleanup() { rm -rf "${TMP_FILES[@]:-}" 2>/dev/null || true; }
trap cleanup EXIT

# =============================================================================
# Main
# =============================================================================

step "Setting up agent sandbox (bwrap)"

# ---------------------------------------------------------------------------
# 1. apt packages
# ---------------------------------------------------------------------------

step "Installing apt packages"

# Accept space- and/or comma-separated package lists
read -ra SANDBOX_PKGS <<< "${SANDBOX_APT_PACKAGES//,/ }"

needs_install=0
for pkg in "${SANDBOX_PKGS[@]}"; do
  [[ -n "$pkg" ]] || continue
  if is_apt_package_installed "$pkg"; then
    info "$pkg already installed"
  else
    info "$pkg missing"
    needs_install=1
  fi
done

if [[ "$needs_install" -eq 1 ]]; then
  sudo apt update
  for pkg in "${SANDBOX_PKGS[@]}"; do
    [[ -n "$pkg" ]] || continue
    if ! is_apt_package_installed "$pkg"; then
      info "Installing $pkg"
      sudo apt install -y "$pkg"
    fi
  done
else
  info "all packages already installed"
fi

command -v bwrap &>/dev/null || error "bwrap binary not found after package install"
info "bwrap: $(bwrap --version 2>/dev/null | head -n 1)"

# ---------------------------------------------------------------------------
# 2. AppArmor profile (Ubuntu 24.04+ blocks unprivileged user namespaces,
#    which bwrap needs when run unprivileged — lift the restriction for
#    bwrap only, per the profile the Claude Code docs prescribe)
# ---------------------------------------------------------------------------

step "Installing AppArmor profile for bwrap"

if ! systemctl is-active --quiet apparmor 2>/dev/null; then
  info "AppArmor is not active — no unprivileged-userns restriction to lift, skipping profile"
else
  aa_tmp="$(mktemp)"
  TMP_FILES+=("$aa_tmp")
  cp "${TEMPLATE_DIR}/bwrap-apparmor" "$aa_tmp"

  if [[ -f /etc/apparmor.d/bwrap ]] && diff -q "$aa_tmp" /etc/apparmor.d/bwrap >/dev/null 2>&1; then
    info "AppArmor profile unchanged: /etc/apparmor.d/bwrap"
  else
    sudo install -m 644 "$aa_tmp" /etc/apparmor.d/bwrap
    # Reload only this profile (no full daemon reload, no service restart)
    sudo apparmor_parser -r /etc/apparmor.d/bwrap
    success "installed and loaded AppArmor profile: /etc/apparmor.d/bwrap"
  fi
fi

# ---------------------------------------------------------------------------
# 3. bwrap smoke test (hard verification)
# ---------------------------------------------------------------------------

step "Verifying bwrap (smoke test)"

if bwrap_out="$(timeout "${BWRAP_VERIFY_TIMEOUT}" bwrap \
    --ro-bind / / --dev /dev --proc /proc \
    --unshare-pid --unshare-uts --unshare-ipc --die-with-parent \
    sh -c 'echo sandbox OK' 2>&1)" && grep -q "sandbox OK" <<< "$bwrap_out"; then
  success "bwrap smoke test passed"
else
  err_msg "bwrap smoke test failed: ${bwrap_out}"
  warn "bwrap userns is blocked — on Ubuntu 24.04+ check the AppArmor profile /etc/apparmor.d/bwrap and reload it with: sudo apparmor_parser -r /etc/apparmor.d/bwrap"
  warn "stopgap (not the target state): sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. asb wrapper
# ---------------------------------------------------------------------------

step "Installing asb wrapper to /usr/local/bin/asb"

asb_tmp="$(mktemp)"
TMP_FILES+=("$asb_tmp")
cp "${TEMPLATE_DIR}/asb" "$asb_tmp"

if [[ -f /usr/local/bin/asb ]] && diff -q "$asb_tmp" /usr/local/bin/asb >/dev/null 2>&1; then
  info "asb unchanged: /usr/local/bin/asb"
else
  sudo install -m 755 "$asb_tmp" /usr/local/bin/asb
  success "installed /usr/local/bin/asb"
fi

# ---------------------------------------------------------------------------
# 5. asb smoke test (hard verification)
# ---------------------------------------------------------------------------

step "Verifying asb (smoke test)"

/usr/local/bin/asb --help >/dev/null || error "asb --help failed"
info "asb --help OK"

# Real sandboxed processes executed via asb (exit 0 + expected output),
# covering both the default workspace and an explicit workspace bind.
asb_scratch="$(mktemp -d)"
TMP_FILES+=("$asb_scratch")

if asb_out="$(timeout 30 /usr/local/bin/asb sh -c 'echo sandboxed-asb OK' 2>&1)" \
    && grep -q "sandboxed-asb OK" <<< "$asb_out"; then
  success "asb smoke test passed (default workspace)"
else
  err_msg "asb smoke test failed (default workspace): ${asb_out}"
  exit 1
fi

if asb_out="$(timeout 30 /usr/local/bin/asb sh "$asb_scratch" -c 'echo sandboxed-asb OK' 2>&1)" \
    && grep -q "sandboxed-asb OK" <<< "$asb_out"; then
  success "asb smoke test passed (explicit workspace)"
else
  err_msg "asb smoke test failed (explicit workspace): ${asb_out}"
  exit 1
fi

success "Agent sandbox (bwrap + asb) is ready"
info "Run agents sandboxed with:  asb pi [workspace] [args...]   /   asb opencode [workspace] [args...]"
