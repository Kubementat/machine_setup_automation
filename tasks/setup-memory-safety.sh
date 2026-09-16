#!/usr/bin/env bash
# shellcheck disable=SC2086,SC1091,SC2016
# =============================================================================
# setup-memory-safety.sh — Guard against silent unified-memory freezes
# =============================================================================
#
# DESCRIPTION:
#   On unified-memory hardware (NVIDIA DGX Spark / GB10) host RAM and GPU
#   memory are the same physical pool. When that pool is exhausted the machine
#   does not produce a clean OOM kill: the CUDA allocator keeps requesting
#   memory, the system falls back to swap and thrashes, and the kernel itself
#   becomes too starved to run the OOM killer. SSH stops responding, nothing
#   is written to the logs, and the only way out is a hard power cycle.
#
#   This script applies the three host-level mitigations that are independent
#   of any single service, so it should run BEFORE the GPU workloads
#   (llama-swap, vLLM, ComfyUI) rather than as part of any one of them.
#
# KEY ACTIONS:
#   1. Pre-flight checks: systemd, root privileges, platform detection
#   2. Disables swap and removes it from /etc/fstab (see WHY SWAP OFF below)
#   3. Installs and configures earlyoom as a userspace OOM guard
#   4. Optionally caps GPU clocks via a systemd unit (opt-in, see below)
#   5. Reports the resulting state
#
# WHY NO cgroup MemoryMax= ON GPU SERVICES:
#   Measured on GB10 / driver 580.142: a 4 GB cudaMalloc is charged to the
#   cgroup as 71 MiB, i.e. classic device allocations escape memcg accounting
#   entirely, while the same 4 GB is plainly visible as a drop in MemFree.
#   cudaMallocManaged IS accounted correctly, but vLLM, llama.cpp and PyTorch
#   allocate model weights through cudaMalloc. A MemoryMax= on those services
#   would constrain only their host-side heap and give false assurance, so this
#   script deliberately does not set one. earlyoom, which watches /proc/meminfo,
#   does see the GPU pressure and is the effective guard.
#
# WHY SWAP OFF (this looks backwards, and is deliberate):
#   Swap does not add safety here, it removes it. With swap present the system
#   degrades into thrashing and hangs with no diagnostics. Without swap the
#   kernel reaches its OOM condition promptly and kills a single process —
#   you lose one inference job instead of the machine. Corroborated by
#   pytorch#174358, NVIDIA forum threads 360336 and 362769, and ComfyUI#11106.
#
# PLATFORM BEHAVIOUR:
#   The swap and GPU measures are specific to unified-memory NVIDIA hardware
#   and are SKIPPED on anything else — disabling swap on an ordinary server
#   with discrete VRAM is bad advice, not a safety measure. earlyoom is
#   installed on every platform. Use --check to see which path applies.
#
# IMPORTANT VARIABLES:
#   MEMSAFETY_DISABLE_SWAP      - Disable swap permanently (default: true)
#   MEMSAFETY_REMOVE_SWAPFILE   - Also delete the swap file (default: false)
#   MEMSAFETY_EARLYOOM          - Install/configure earlyoom (default: true)
#   MEMSAFETY_EARLYOOM_MEM_PCT  - Free-memory trigger, percent (default: 5)
#   MEMSAFETY_EARLYOOM_SWAP_PCT - Free-swap trigger, percent (default: 10)
#   MEMSAFETY_GPU_CLOCK_CAP     - Cap GPU clocks at boot (default: false)
#   MEMSAFETY_GPU_CLOCK_MIN     - Min GPU clock in MHz (default: 300)
#   MEMSAFETY_GPU_CLOCK_MAX     - Max GPU clock in MHz (default: 2100)
#   FORCE                       - Re-apply even if already configured (default: 0)
#
# DEPENDENCIES:
#   - systemctl: systemd management
#   - apt-get:   earlyoom installation (Debian/Ubuntu)
#   - envsubst:  template rendering (package: gettext-base)
#   - nvidia-smi: only required when MEMSAFETY_GPU_CLOCK_CAP=true
#
# OUTPUTS:
#   - /etc/default/earlyoom                       - earlyoom configuration
#   - /etc/systemd/system/earlyoom.service.d/     - OOMScoreAdjust drop-in
#   - /etc/systemd/system/nvidia-clock-cap.service - GPU clock cap (opt-in)
#   - /etc/fstab.bak.<timestamp>                  - fstab backup before edit
#
# USAGE:
#   sudo ./setup-memory-safety.sh                 # apply defaults
#   ./setup-memory-safety.sh --check              # report state, change nothing
#   sudo ./setup-memory-safety.sh --force         # re-apply unconditionally
#   sudo MEMSAFETY_GPU_CLOCK_CAP=true ./setup-memory-safety.sh
#   ./setup-memory-safety.sh --help
#
# REFERENCE:
#   https://github.com/pytorch/pytorch/issues/174358
#   https://forums.developer.nvidia.com/t/mitigating-oom-system-freezes-on-uma-based-single-board-computers/362769
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/memory-safety")"

# shellcheck source=lib/helpers.sh
source "${LIB_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

MEMSAFETY_DISABLE_SWAP="${MEMSAFETY_DISABLE_SWAP:-true}"
MEMSAFETY_REMOVE_SWAPFILE="${MEMSAFETY_REMOVE_SWAPFILE:-false}"
MEMSAFETY_EARLYOOM="${MEMSAFETY_EARLYOOM:-true}"
MEMSAFETY_EARLYOOM_MEM_PCT="${MEMSAFETY_EARLYOOM_MEM_PCT:-5}"
MEMSAFETY_EARLYOOM_SWAP_PCT="${MEMSAFETY_EARLYOOM_SWAP_PCT:-10}"
MEMSAFETY_GPU_CLOCK_CAP="${MEMSAFETY_GPU_CLOCK_CAP:-false}"
MEMSAFETY_GPU_CLOCK_MIN="${MEMSAFETY_GPU_CLOCK_MIN:-300}"
MEMSAFETY_GPU_CLOCK_MAX="${MEMSAFETY_GPU_CLOCK_MAX:-2100}"
FORCE="${FORCE:-0}"

# ─────────────────────────────────────────────────────────────────────────────
# COMPUTED VALUES
# ─────────────────────────────────────────────────────────────────────────────

EARLYOOM_DEFAULTS="/etc/default/earlyoom"
EARLYOOM_DROPIN_DIR="/etc/systemd/system/earlyoom.service.d"
EARLYOOM_DROPIN="${EARLYOOM_DROPIN_DIR}/10-memory-safety.conf"
CLOCK_CAP_UNIT="/etc/systemd/system/nvidia-clock-cap.service"
FSTAB="/etc/fstab"
CHECK_ONLY=0
IS_UNIFIED_MEMORY=0
CHECK_FAILED=0

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Applies host-level mitigations against silent whole-system freezes caused by
unified-memory exhaustion on NVIDIA DGX Spark (GB10) hardware: disables swap,
installs earlyoom as a userspace OOM guard, and optionally caps GPU clocks.

Swap and GPU measures are skipped on non-unified-memory hardware.

${BOLD}Options:${RESET}
  --check     Report current state only (no changes); non-zero exit if unsafe
  --force     Re-apply configuration even if already present
  -h, --help  Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  MEMSAFETY_DISABLE_SWAP       Disable swap permanently (default: true)
  MEMSAFETY_REMOVE_SWAPFILE    Also delete the swap file itself (default: false)
  MEMSAFETY_EARLYOOM           Install and configure earlyoom (default: true)
  MEMSAFETY_EARLYOOM_MEM_PCT   Free-memory trigger threshold, percent (default: 5)
  MEMSAFETY_EARLYOOM_SWAP_PCT  Free-swap trigger threshold, percent (default: 10)
  MEMSAFETY_GPU_CLOCK_CAP      Cap GPU clocks at boot (default: false)
  MEMSAFETY_GPU_CLOCK_MIN      Minimum GPU clock in MHz (default: 300)
  MEMSAFETY_GPU_CLOCK_MAX      Maximum GPU clock in MHz (default: 2100)
  FORCE                        Re-apply even if already configured (default: 0)

${BOLD}Note:${RESET} The GPU clock cap is opt-in because it trades sustained peak
performance for protection against a power-spike shutdown path. Enable it if
you see unexplained hard resets under load.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# Returns 0 when running as root; used to gate every mutating action.
is_root() { [[ "$(id -u)" -eq 0 ]]; }

# Detects unified-memory NVIDIA hardware (DGX Spark GB10 and relatives).
# Sets IS_UNIFIED_MEMORY. Deliberately conservative: anything we cannot
# positively identify is treated as ordinary discrete-GPU hardware.
detect_unified_memory() {
  local arch gpu_name
  arch="$(uname -m)"
  if [[ "$arch" != "aarch64" ]]; then
    IS_UNIFIED_MEMORY=0
    return
  fi
  if ! command -v nvidia-smi &>/dev/null; then
    IS_UNIFIED_MEMORY=0
    return
  fi
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  if [[ "$gpu_name" == *GB10* ]]; then
    IS_UNIFIED_MEMORY=1
  else
    IS_UNIFIED_MEMORY=0
  fi
}

# Marks the --check run as failed without aborting, so a single pass can
# report every problem instead of stopping at the first one.
check_fail() {
  warn "$1"
  CHECK_FAILED=1
}

# True when /etc/fstab still contains an uncommented swap entry.
fstab_has_active_swap() {
  grep -qE '^[^#]*[[:space:]]swap[[:space:]]' "$FSTAB" 2>/dev/null
}

# True when any swap device is currently online.
swap_is_active() {
  [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

if ! command -v systemctl &>/dev/null; then
  error "systemctl is not available. This script requires systemd."
fi

if [[ $CHECK_ONLY -eq 0 ]] && ! is_root; then
  error "This script must be run as root (use sudo). Use --check to inspect without changes."
fi

detect_unified_memory
if [[ $IS_UNIFIED_MEMORY -eq 1 ]]; then
  success "Unified-memory platform detected (aarch64 + GB10) — full mitigation path"
else
  info "Not a unified-memory NVIDIA platform — swap and GPU measures will be skipped"
  info "earlyoom is still applicable and will be handled"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK MODE — report and exit
# ─────────────────────────────────────────────────────────────────────────────

if [[ $CHECK_ONLY -eq 1 ]]; then
  step "Memory safety status"

  echo "  Platform:  $(uname -m) / $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo 'no NVIDIA GPU')"
  echo "  Path:      $([[ $IS_UNIFIED_MEMORY -eq 1 ]] && echo 'unified memory (full)' || echo 'generic (earlyoom only)')"

  if [[ $IS_UNIFIED_MEMORY -eq 1 ]]; then
    if swap_is_active; then
      check_fail "Swap is ACTIVE — a memory exhaustion event will freeze this machine"
      swapon --show 2>/dev/null | sed 's/^/    /'
    else
      success "Swap is off"
    fi

    if fstab_has_active_swap; then
      check_fail "/etc/fstab still enables swap at boot"
    else
      success "/etc/fstab has no active swap entry"
    fi
  fi

  if systemctl is-active --quiet earlyoom 2>/dev/null; then
    success "earlyoom is running"
  else
    check_fail "earlyoom is not running — no userspace OOM guard in place"
  fi

  if [[ "$MEMSAFETY_GPU_CLOCK_CAP" == "true" ]]; then
    if systemctl is-enabled --quiet nvidia-clock-cap 2>/dev/null; then
      success "GPU clock cap unit is enabled"
    else
      check_fail "GPU clock cap requested but nvidia-clock-cap is not enabled"
    fi
  else
    info "GPU clock cap not requested (MEMSAFETY_GPU_CLOCK_CAP=false)"
  fi

  echo ""
  if [[ $CHECK_FAILED -eq 1 ]]; then
    warn "Memory safety is INCOMPLETE — run without --check to apply"
    exit 1
  fi
  success "All memory safety measures are in place"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — DISABLE SWAP
# ─────────────────────────────────────────────────────────────────────────────

if [[ $IS_UNIFIED_MEMORY -eq 1 && "$MEMSAFETY_DISABLE_SWAP" == "true" ]]; then
  step "Disabling swap"

  if ! swap_is_active && ! fstab_has_active_swap && [[ $FORCE -eq 0 ]]; then
    success "Swap already disabled and absent from ${FSTAB} — nothing to do"
  else
    # Turning swap off writes its pages back into RAM. Refuse if they would
    # not fit, otherwise we would trigger the very freeze we are preventing.
    local_swap_used_kb="$(awk '/^SwapTotal|^SwapFree/ {t[$1]=$2} END {print (t["SwapTotal:"]-t["SwapFree:"])}' /proc/meminfo)"
    local_mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    if [[ "$local_swap_used_kb" -gt "$local_mem_avail_kb" ]]; then
      error "Cannot disable swap safely: $((local_swap_used_kb / 1024)) MB in use but only $((local_mem_avail_kb / 1024)) MB available. Stop some workloads first."
    fi
    info "Swap in use: $((local_swap_used_kb / 1024)) MB — will move back into RAM ($((local_mem_avail_kb / 1024)) MB available)"

    if swap_is_active; then
      swapoff -a
      success "Swap disabled for the running system"
    fi

    if fstab_has_active_swap; then
      cp -a "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
      # Comment out rather than delete, so the change is obvious and reversible.
      sed -i -E 's|^([^#]*[[:space:]]swap[[:space:]].*)$|# disabled by setup-memory-safety.sh: \1|' "$FSTAB"
      success "Swap entry commented out in ${FSTAB} (backup written)"
    fi

    if [[ "$MEMSAFETY_REMOVE_SWAPFILE" == "true" ]]; then
      for swapfile in /swap.img /swapfile; do
        if [[ -f "$swapfile" ]]; then
          rm -f "$swapfile"
          success "Removed ${swapfile}"
        fi
      done
    else
      info "Swap file left in place (MEMSAFETY_REMOVE_SWAPFILE=false) — re-enable by restoring the fstab line"
    fi
  fi
elif [[ $IS_UNIFIED_MEMORY -eq 0 ]]; then
  info "Skipping swap changes — not a unified-memory platform"
else
  info "Skipping swap changes (MEMSAFETY_DISABLE_SWAP=false)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — EARLYOOM
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$MEMSAFETY_EARLYOOM" == "true" ]]; then
  step "Configuring earlyoom"

  if ! command -v earlyoom &>/dev/null; then
    if ! command -v apt-get &>/dev/null; then
      error "earlyoom is not installed and apt-get is unavailable. Install earlyoom manually or set MEMSAFETY_EARLYOOM=false."
    fi
    info "Installing earlyoom via apt"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq earlyoom
    success "earlyoom installed"
  else
    success "earlyoom already installed"
  fi

  if ! command -v envsubst &>/dev/null; then
    error "envsubst is not installed. Install it with: apt-get install -y gettext-base"
  fi

  export MEMSAFETY_EARLYOOM_MEM_PCT MEMSAFETY_EARLYOOM_SWAP_PCT
  rendered="$(mktempfile)"
  envsubst '${MEMSAFETY_EARLYOOM_MEM_PCT} ${MEMSAFETY_EARLYOOM_SWAP_PCT}' \
    < "${TEMPLATE_DIR}/earlyoom.default" > "$rendered"

  if [[ -f "$EARLYOOM_DEFAULTS" ]] && cmp -s "$rendered" "$EARLYOOM_DEFAULTS" && [[ $FORCE -eq 0 ]]; then
    success "${EARLYOOM_DEFAULTS} already up to date"
    rm -f "$rendered"
  else
    install -m 0644 "$rendered" "$EARLYOOM_DEFAULTS"
    rm -f "$rendered"
    success "Wrote ${EARLYOOM_DEFAULTS}"
  fi

  # earlyoom must never be the process that gets killed when memory runs out.
  mkdir -p "$EARLYOOM_DROPIN_DIR"
  cat > "$EARLYOOM_DROPIN" <<'DROPIN'
# Managed by tasks/setup-memory-safety.sh
# Make earlyoom effectively unkillable by the kernel OOM killer — it is the
# component that is supposed to act first, so it must outlive its targets.
[Service]
OOMScoreAdjust=-1000
DROPIN
  success "Wrote ${EARLYOOM_DROPIN}"

  systemctl daemon-reload
  systemctl enable --now earlyoom >/dev/null 2>&1 || error "Failed to enable earlyoom"
  systemctl restart earlyoom
  if systemctl is-active --quiet earlyoom; then
    success "earlyoom is running"
  else
    error "earlyoom failed to start — check: journalctl -u earlyoom -n 50"
  fi
else
  info "Skipping earlyoom (MEMSAFETY_EARLYOOM=false)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — GPU CLOCK CAP (opt-in)
# ─────────────────────────────────────────────────────────────────────────────

if [[ $IS_UNIFIED_MEMORY -eq 1 && "$MEMSAFETY_GPU_CLOCK_CAP" == "true" ]]; then
  step "Installing GPU clock cap unit"

  if ! command -v nvidia-smi &>/dev/null; then
    error "nvidia-smi not found but MEMSAFETY_GPU_CLOCK_CAP=true"
  fi

  export MEMSAFETY_GPU_CLOCK_MIN MEMSAFETY_GPU_CLOCK_MAX
  rendered="$(mktempfile)"
  envsubst '${MEMSAFETY_GPU_CLOCK_MIN} ${MEMSAFETY_GPU_CLOCK_MAX}' \
    < "${TEMPLATE_DIR}/nvidia-clock-cap.service" > "$rendered"

  if [[ -f "$CLOCK_CAP_UNIT" ]] && cmp -s "$rendered" "$CLOCK_CAP_UNIT" && [[ $FORCE -eq 0 ]]; then
    success "${CLOCK_CAP_UNIT} already up to date"
    rm -f "$rendered"
  else
    install -m 0644 "$rendered" "$CLOCK_CAP_UNIT"
    rm -f "$rendered"
    systemctl daemon-reload
    success "Wrote ${CLOCK_CAP_UNIT}"
  fi

  systemctl enable --now nvidia-clock-cap >/dev/null 2>&1 || error "Failed to enable nvidia-clock-cap"
  success "GPU clocks capped to ${MEMSAFETY_GPU_CLOCK_MIN}-${MEMSAFETY_GPU_CLOCK_MAX} MHz"
elif [[ $IS_UNIFIED_MEMORY -eq 1 ]]; then
  info "GPU clock cap not enabled (MEMSAFETY_GPU_CLOCK_CAP=false)"
  info "Enable it if you observe unexplained hard resets under sustained load"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

step "Memory safety configured"

echo ""
echo "  Swap:        $(swap_is_active && echo 'ACTIVE (!)' || echo 'off')"
echo "  earlyoom:    $(systemctl is-active earlyoom 2>/dev/null || echo 'inactive')"
echo "  Clock cap:   $(systemctl is-enabled nvidia-clock-cap 2>/dev/null || echo 'not installed')"
echo ""
info "Verify at any time with: $0 --check"
info "earlyoom activity:       journalctl -u earlyoom -f"

if [[ $IS_UNIFIED_MEMORY -eq 1 ]]; then
  echo ""
  warn "This reduces the blast radius but does not make memory exhaustion safe."
  warn "Do not enable GPU services to autostart if they can run concurrently"
  warn "with a loaded LLM — sizing the workloads is still your responsibility."
fi
