#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# nvidia-cdi-refresh — regenerate the NVIDIA CDI spec when it went stale
# =============================================================================
#
# Installed by tasks/setup-nvidia-container.sh to NVIDIA_CDI_REFRESH_BIN
# (default /usr/local/sbin/nvidia-cdi-refresh). Runs standalone: it does NOT
# source lib/helpers.sh, because the repo is not guaranteed to be present on
# the host when apt invokes it.
#
# WHY THIS EXISTS:
#   A CDI spec pins the driver's versioned library paths, e.g.
#     hostPath: /usr/lib/aarch64-linux-gnu/libcuda.so.580.142
#   A driver upgrade replaces those files with new version-suffixed names, so
#   every mount in the spec dangles and `docker run --device nvidia.com/gpu=all`
#   fails with "unresolvable CDI devices". Regenerating the spec fixes it.
#
# STALENESS TEST:
#   The spec is stale when any /usr/... hostPath it references is gone. That is
#   the exact failure condition, and it needs no version parsing. Only /usr
#   paths are checked: /run and /dev entries (persistenced socket, /dev/nvidia*)
#   are runtime state that is legitimately absent on an idle host and would
#   produce false positives.
#
# EXIT CODES:
#   0  spec is current, or was regenerated successfully, or nothing to do
#      (no nvidia-ctk / no driver — a host without a GPU is not an error)
#   1  regeneration was needed but failed
#   2  --check only: spec is stale (nothing was written)
#
# USAGE:
#   nvidia-cdi-refresh            # regenerate if stale
#   nvidia-cdi-refresh --force    # regenerate unconditionally
#   nvidia-cdi-refresh --check    # report staleness, change nothing (exit 2)
#   nvidia-cdi-refresh --quiet    # only print when something actually changes
#
# ENVIRONMENT:
#   NVIDIA_CDI_SPEC   Path of the spec to manage (default /etc/cdi/nvidia.yaml)
# =============================================================================

set -euo pipefail

SPEC="${NVIDIA_CDI_SPEC:-/etc/cdi/nvidia.yaml}"
FORCE=false
CHECK_ONLY=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --spec)  SPEC="${2:?--spec needs a path}"; shift 2 ;;
    --help)
      sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "nvidia-cdi-refresh: unknown option: $1" >&2; exit 1 ;;
  esac
done

say()  { [[ "${QUIET}" == true ]] || echo "nvidia-cdi-refresh: $*"; }
loud() { echo "nvidia-cdi-refresh: $*"; }

# --- Nothing to do on a host without the toolkit or without a driver ---------
# Deliberately exit 0: this script runs from an apt hook on every dpkg
# transaction, including on machines that have no GPU at all.
if ! command -v nvidia-ctk &>/dev/null; then
  say "nvidia-ctk not installed — nothing to do."
  exit 0
fi
if ! command -v nvidia-smi &>/dev/null; then
  say "no NVIDIA driver present — nothing to do."
  exit 0
fi

# --- Staleness ---------------------------------------------------------------
stale_reason=""

if [[ ! -f "${SPEC}" ]]; then
  stale_reason="spec does not exist"
else
  missing_path=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ ! -e "$p" ]]; then
      missing_path="$p"
      break
    fi
  done < <(sed -n 's/^[[:space:]]*-[[:space:]]*hostPath:[[:space:]]*\(\/usr\/.*\)$/\1/p' "${SPEC}")

  if [[ -n "${missing_path}" ]]; then
    stale_reason="referenced driver file is gone: ${missing_path}"
  else
    # Secondary check: after a reboot the running kernel module reports the new
    # version while the spec still names the old one. The /usr paths above may
    # all still resolve at that point (old libs not yet purged), so compare the
    # versions too.
    spec_ver="$(sed -n 's/^[[:space:]]*-[[:space:]]*--host-driver-version=\(.*\)$/\1/p' "${SPEC}" | head -n1)"
    host_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    if [[ -n "${spec_ver}" && -n "${host_ver}" && "${spec_ver}" != "${host_ver}" ]]; then
      stale_reason="driver version drift: spec=${spec_ver} host=${host_ver}"
    fi
  fi
fi

if [[ -z "${stale_reason}" && "${FORCE}" != true ]]; then
  say "spec ${SPEC} is current."
  exit 0
fi

if [[ "${CHECK_ONLY}" == true ]]; then
  if [[ -n "${stale_reason}" ]]; then
    loud "STALE: ${stale_reason}"
    exit 2
  fi
  say "spec ${SPEC} is current."
  exit 0
fi

# --- Regenerate --------------------------------------------------------------
loud "regenerating ${SPEC} (${stale_reason:-forced})"

spec_dir="$(dirname "${SPEC}")"
install -d -m 755 "${spec_dir}"

# Generate into a temp file and install over the spec, so a failed or partial
# generate never leaves a truncated spec behind that would break every
# subsequent container start.
#
# The temp file keeps the spec's exact basename inside a temp DIRECTORY rather
# than getting a .XXXXXX suffix: nvidia-ctk picks its output format from the
# file extension, and for an extension it does not recognise it writes NO FILE
# AT ALL and still exits 0 — `--format=yaml` does not override this. A suffixed
# temp name therefore produces a silent no-op. Same directory, so the install
# below stays on one filesystem.
tmpdir="$(mktemp -d "${spec_dir}/.nvidia-cdi-refresh.XXXXXX")"
trap 'rm -rf -- "${tmpdir}"' EXIT
tmp="${tmpdir}/$(basename "${SPEC}")"

# nvidia-ctk logs a wall of info/warning lines to stderr; keep it out of the
# apt transcript and print it only when something actually went wrong.
gen_log="${tmpdir}/generate.log"
if ! nvidia-ctk cdi generate --output="${tmp}" >"${gen_log}" 2>&1; then
  loud "ERROR: nvidia-ctk cdi generate failed — leaving the existing spec untouched."
  cat "${gen_log}" >&2
  exit 1
fi
if [[ ! -s "${tmp}" ]]; then
  loud "ERROR: nvidia-ctk wrote no spec to ${tmp} — leaving the existing spec untouched."
  loud "       (an unrecognised file extension makes nvidia-ctk a silent no-op)"
  cat "${gen_log}" >&2
  exit 1
fi

install -m 644 "${tmp}" "${SPEC}"
loud "wrote ${SPEC}"
