#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# lib/helpers.sh — Shared helper library for kwisatz
# =============================================================================
#
# PURPOSE:
#   Provides common colour variables, logging functions, and pre-flight check
#   helpers that are reused across multiple setup scripts in this project.
#
# USAGE:
#   Source this file at the top of any setup script:
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"
#   or with an absolute path:
#     source /path/to/kwisatz/lib/helpers.sh
#
# NOTES:
#   - This file is designed to be *sourced*, not executed directly.
#   - All definitions are guarded so re-sourcing is safe and user additions
#   - made after the initial source will not be overwritten.
#   - No `set -eu` here; the calling script controls those options.
# =============================================================================

# ---------------------------------------------------------------------------
# Colour variables (guarded — skip if already defined)
# ---------------------------------------------------------------------------
if [[ -z "${RED:-}" ]];    then RED=$'\033[0;31m';    fi
if [[ -z "${GREEN:-}" ]];  then GREEN=$'\033[0;32m';  fi
if [[ -z "${YELLOW:-}" ]]; then YELLOW=$'\033[1;33m'; fi
if [[ -z "${CYAN:-}" ]];   then CYAN=$'\033[0;36m';   fi
if [[ -z "${BOLD:-}" ]];   then BOLD=$'\033[1m';      fi
if [[ -z "${RESET:-}" ]];  then RESET=$'\033[0m';     fi

# ---------------------------------------------------------------------------
# Logging helpers (guarded — skip if already defined)
# ---------------------------------------------------------------------------
if ! declare -F step > /dev/null 2>&1; then
  step() { echo -e "\n${BOLD}▶ $*${RESET}"; }
fi

if ! declare -F info > /dev/null 2>&1; then
  info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
fi

if ! declare -F success > /dev/null 2>&1; then
  success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
fi

if ! declare -F warn > /dev/null 2>&1; then
  warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fi

if ! declare -F error > /dev/null 2>&1; then
  error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Error semantics
#
# RULE: `error` and `die` terminate the process — never call them inside a
#       command substitution that a caller guards with `||` (the exit would
#       only kill the subshell and the guarded fallback would silently take
#       effect). Use `err_msg` + `return` in helpers that must be
#       recoverable, so the caller can decide how to handle the failure.
# ---------------------------------------------------------------------------

# Report an error, do NOT exit. Use inside functions/helpers whose caller decides.
if ! declare -F err_msg > /dev/null 2>&1; then
  err_msg() { echo -e "${RED}[ERROR]${RESET} $*" >&2; return 1; }
fi

# Terminal error: report and exit. Identical semantics to error().
if ! declare -F die > /dev/null 2>&1; then
  die() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# run_preflight_checks
#   Validates all required dependencies are available before setup proceeds.
#   Checks: Docker installation, Docker daemon running, OpenSSL, curl.
# ---------------------------------------------------------------------------
if ! declare -F run_preflight_checks > /dev/null 2>&1; then
  run_preflight_checks() {
    # Check Docker is installed
    if ! command -v docker &>/dev/null; then
      echo -e "${RED}[ERROR]${RESET} Docker is not installed. Please run setup-docker.sh first." >&2
      exit 1
    fi

    # Check Docker daemon is running
    if ! docker info &>/dev/null; then
      echo -e "${RED}[ERROR]${RESET} Docker daemon is not running. Please start Docker." >&2
      exit 1
    fi

    # Check OpenSSL is available
    if ! command -v openssl &>/dev/null; then
      echo -e "${RED}[ERROR]${RESET} OpenSSL is not installed. Required for password and key generation." >&2
      exit 1
    fi

    # Check curl is available
    if ! command -v curl &>/dev/null; then
      echo -e "${RED}[ERROR]${RESET} curl is not installed. Required for health check polling." >&2
      exit 1
    fi
  }
fi

# ---------------------------------------------------------------------------
# ensure_proxy_network
#   Verifies that the Docker network referenced by PROXY_NETWORK exists.
#   Exits 1 if the network is absent.
# ---------------------------------------------------------------------------
if ! declare -F ensure_proxy_network > /dev/null 2>&1; then
  ensure_proxy_network() {
    local network="${PROXY_NETWORK:-proxy}"
    if docker network ls --format '{{.Name}}' | grep -qx "${network}"; then
      success "Docker network '${network}' exists."
    else
      echo -e "${RED}[ERROR]${RESET} Docker network '${network}' not found." >&2
      echo -e "${RED}[ERROR]${RESET} Please run setup-traefik.sh first to create it." >&2
      exit 1
    fi
  }
fi

# ---------------------------------------------------------------------------
# ensure_traefik_running
#   Verifies that a Docker container named 'traefik' is currently running.
#   Exits 1 if the container is not found among running containers.
# ---------------------------------------------------------------------------
if ! declare -F ensure_traefik_running > /dev/null 2>&1; then
  ensure_traefik_running() {
    if docker ps --format '{{.Names}}' | grep -qx 'traefik'; then
      success "Traefik container is running."
    else
      echo -e "${RED}[ERROR]${RESET} Traefik container is not running." >&2
      echo -e "${RED}[ERROR]${RESET} Please start Traefik first before running this script." >&2
      exit 1
    fi
  }
fi

# ---------------------------------------------------------------------------
# detect_arch [fallback]
#   Detects the host architecture and maps it to the standard Go/OS
#   architecture name (amd64 or arm64).
#
#   Prints 'amd64' or 'arm64'. On an unsupported arch: prints an error to
#   stderr and returns 1 (printing [fallback] first, if one was given).
#   Never exits, so callers can decide.
#
#   Callers under `set -euo pipefail` should use the assignment-with-return
#   shape so the failure stays loud (err_msg already printed the reason):
#     ARCH="$(detect_arch)" || exit 1
#   (A bare `ARCH="$(detect_arch)"` also aborts the script on failure, which
#   is fine — but never guard it with `|| <fallback>`, that would hide the
#   error and silently install artifacts for the wrong architecture.)
#
# OUTPUT:
#   Prints 'amd64' or 'arm64' to stdout.
# ---------------------------------------------------------------------------
if ! declare -F detect_arch > /dev/null 2>&1; then
  detect_arch() {
    local fallback="${1:-}" arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64)            echo "amd64"; return 0 ;;
      aarch64|arm64)     echo "arm64"; return 0 ;;
      *)
        err_msg "Unsupported architecture: ${arch}. Only amd64 and arm64 are supported."
        [[ -n "$fallback" ]] && echo "$fallback"
        return 1
        ;;
    esac
  }
fi

# ---------------------------------------------------------------------------
# mktempfile <name>
#   Creates a temporary file and prints its path. Uses mktemp with a
#   predictable naming pattern (suffix of <name>) for easier debugging,
#   falling back to an unnamed temp file.
#
#   Cleanup: files created via mktempfile are removed automatically when the
#   sourcing script exits, and the caller's own EXIT trap is preserved. The
#   cleanup is *chained* onto any EXIT trap the calling script installed, so
#   task-level cleanup (docker compose down on failure) still runs.
#
#   How it works: file names are recorded in a per-process tracking file
#   ($_MKTEMP_TRACK_FILE) rather than a shell variable, because mktempfile is
#   normally called inside a command substitution (f="$(mktempfile x.sh)"),
#   which runs in a subshell — there, neither variable updates nor EXIT
#   traps reach the parent shell. The cleanup trap is armed in the parent
#   (at source time, and on any direct non-subshell call) and reads the
#   tracking file on exit.
#
#   Limitations:
#   - Trap chaining re-reads the existing EXIT trap via `trap -p`, which
#     loses quoting for traps containing single quotes. None of the existing
#     task EXIT traps do (they call `cleanup_on_failure`).
#   - A script that installs its own EXIT trap *after* sourcing this library
#     (plain `trap ... EXIT`) replaces the chained trap. No current task
#     script both does that and uses mktempfile; if one appears, it must
#     include `_mktemp_cleanup` in its own trap.
# ---------------------------------------------------------------------------
if [[ -z "${_MKTEMP_TRACK_FILE:-}" ]]; then
  _MKTEMP_TRACK_FILE="${TMPDIR:-/tmp}/msa-mktempfile-tracker.$$"
fi

if ! declare -F _mktemp_cleanup > /dev/null 2>&1; then
  # Remove every temp file recorded via mktempfile, then the tracker itself.
  _mktemp_cleanup() {
    local _f
    if [[ -f "${_MKTEMP_TRACK_FILE:-}" ]]; then
      while IFS= read -r _f; do
        [[ -n "$_f" ]] && rm -f -- "$_f"
      done < "${_MKTEMP_TRACK_FILE}"
      rm -f -- "${_MKTEMP_TRACK_FILE}"
    fi
    return 0
  }
fi

if ! declare -F _mktemp_arm_exit_trap > /dev/null 2>&1; then
  # Chain _mktemp_cleanup onto the current EXIT trap without overwriting it.
  # No-op when the cleanup is already part of the trap, so repeated
  # mktempfile calls never re-wrap it.
  _mktemp_arm_exit_trap() {
    local _cur _prev
    _cur="$(trap -p EXIT)"
    if [[ "$_cur" == *"_mktemp_cleanup"* ]]; then
      return 0
    fi
    _prev="$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT$/\1/p")"
    if [[ -n "$_prev" ]]; then
      # Expand now on purpose: the handler is composed from the existing
      # handler string extracted above.
      # ORDER MATTERS: the previous handler runs FIRST so it still sees the
      # script's real exit status in $? — the task cleanup handlers capture
      # `local exit_code=$?` on entry, and any command running before them
      # would clobber the code (a _mktemp_cleanup that runs first always
      # returns 0, which silently disabled every failure cleanup that was
      # chained this way; found by ticket improvements-2/09 on a live VM).
      # The current handlers (cleanup_on_failure) return 0 on all paths, so
      # _mktemp_cleanup still runs afterwards. A hypothetical handler that
      # exits itself would skip the temp-file cleanup (no current handler
      # does that).
      # shellcheck disable=SC2064
      trap "${_prev}; _mktemp_cleanup" EXIT
    else
      trap "_mktemp_cleanup" EXIT
    fi
  }
fi

# Arm the cleanup trap in the sourcing (parent) shell. Task scripts that
# install their own EXIT trap later take precedence; see limitations above.
_mktemp_arm_exit_trap

if ! declare -F mktempfile > /dev/null 2>&1; then
  mktempfile() {
    local f
    f="$(mktemp -t "$(basename "$1" | sed 's/$/.XXXXXX/')" 2>/dev/null || mktemp -t "tmp.XXXXXX")" || return 1
    printf '%s\n' "$f" >> "${_MKTEMP_TRACK_FILE}"
    # Re-arm only in the top-level shell: inside a command substitution this
    # function runs in a subshell, where an armed EXIT trap would fire at
    # the end of the substitution — deleting the file before the caller has
    # used it (its output would be captured into the assignment).
    if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
      _mktemp_arm_exit_trap
    fi
    printf '%s\n' "$f"
  }
fi

# ---------------------------------------------------------------------------
# Secret env-file helpers
#
# Repo secret pattern (see AGENTS.md, "Secrets and templating"): secrets live
# in /srv/<service>/.env (mode 600); rendered files keep ${VAR} literal and
# resolve it at runtime (e.g. docker compose --env-file). These helpers read
# and write such files. Never `source` an env file — it may contain
# operator-edited values.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# warn_moving_image <image-ref> <var-name>
#   Warn-only moving-tag check for a docker image reference (does not modify
#   it, never exits). A ref is considered reproducible when it carries a
#   version tag or a digest; `:latest`/`:main`/untagged refs are not.
#
#   Rationale: templates render their image from a script-level `*_IMAGE`
#   default, so a moving *default* makes every generated compose file pull an
#   unpinned reference (ticket improvements-2/17). An operator override that
#   still moves is a decision, not a bug, so this warns instead of failing.
# ---------------------------------------------------------------------------
if ! declare -F warn_moving_image > /dev/null 2>&1; then
  warn_moving_image() {
    local img="${1:-}" name="${2:-image}"
    [[ -n "$img" ]] || return 0
    if [[ "$img" == *:latest || "$img" == *:main || ( "$img" != *:* && "$img" != *@* ) ]]; then
      warn "${name} '${img}' is a moving tag — pulls are not reproducible; pin a release tag (see ticket improvements-2/17)"
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# fetch_and_run <url> <expected_sha256_or_empty>
#   Downloads <url> to a temp file, logs its SHA-256, verifies it against
#   <expected_sha256> when one is given, then runs the file with bash. The
#   download is removed on function return (RETURN trap) *and* on script exit
#   (via mktempfile), so a failed run leaves no half-written installer.
#
#   Why not `curl … | bash`: the pipe executes bytes nobody looked at, with no
#   artifact to re-check and no way to pin content (ticket improvements-2/17).
#   Call sites pass an expected hash when upstream publishes one; where it
#   publishes nothing, pass "" and the digest at least lands in the run log
#   (and can be pinned later via the caller's env-var override).
#
#   Returns non-zero on download/checksum failure so the caller decides how to
#   report it; the installer's own exit status is passed through.
# ---------------------------------------------------------------------------
if ! declare -F fetch_and_run > /dev/null 2>&1; then
  fetch_and_run() {
    local url="${1:-}" sha="${2:-}" tmp actual
    [[ -n "$url" ]] || { err_msg "fetch_and_run: no URL given"; return 1; }

    tmp="$(mktempfile "$(basename "${url%%\?*}").sh")" \
      || { err_msg "fetch_and_run: mktemp failed"; return 1; }
    # shellcheck disable=SC2064  # expand tmp now: it is a local of this function
    trap "rm -f -- '${tmp}'" RETURN

    info "Downloading ${url}"
    if ! curl -fsSL "${url}" -o "${tmp}"; then
      err_msg "download failed: ${url}"
      return 1
    fi

    actual="$(sha256sum "${tmp}" | cut -d' ' -f1)" \
      || { err_msg "fetch_and_run: sha256sum failed for ${tmp}"; return 1; }
    info "Downloaded ${url} sha256=${actual}"

    if [[ -n "${sha}" && "${sha}" != "${actual}" ]]; then
      err_msg "checksum mismatch for ${url}: expected ${sha}, got ${actual} — refusing to execute (update the *_SHA256 constant only after reviewing the new installer)"
      return 1
    fi

    bash "${tmp}"
  }
fi

# env_file_get <file> <KEY>
#   Prints the value of KEY=<value> from an env file (last occurrence wins),
#   or nothing. Values are read literally — no shell evaluation.
#   Returns 1 if the file does not exist, 0 otherwise (also when KEY is absent).
if ! declare -F env_file_get > /dev/null 2>&1; then
  env_file_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    sed -n "s/^[[:space:]]*${key}=//p" "$file" | tail -n1
  }
fi

# env_file_write <file>   (content on stdin)
#   Installs stdin as <file> with mode 600 (mktemp + install), owned by the
#   invoking user. Falls back to a root-owned file when the invoking user
#   cannot install there directly (needs sudo).
if ! declare -F env_file_write > /dev/null 2>&1; then
  env_file_write() {
    local file="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    install -m 600 -o "$(id -un)" -g "$(id -gn)" "$tmp" "$file" 2>/dev/null \
      || { sudo install -m 600 -o root -g root "$tmp" "$file"; }
    rm -f "$tmp"
  }
fi

# ---------------------------------------------------------------------------
# wait_for_healthy <timeout_s> <container_id...>
#   Polls 'docker inspect' until every container is running (and, when it
#   defines a healthcheck, healthy). Exits non-zero with the bad container
#   names + a logs hint.
#   Containers without a healthcheck count as ready once State.Status ==
#   running. A container that exited/dead/restarting is an immediate failure
#   (no point burning the whole timeout on a crash loop).
#
#   Typical use from a task script (pass --env-file/-f exactly as the
#   surrounding 'docker compose up -d' does):
#     mapfile -t _ids < <(docker compose -f "$COMPOSE_FILE" ps -q)
#     wait_for_healthy 180 "${_ids[@]}" \
#       || error "<service> stack did not come up — see the status output above"
#
#   The helper RETURNS non-zero (it never calls error) so each task can
#   decide. Call it under `set -e` — plainly, or with `|| error "..."` for
#   a better message (preferred: the `||` context also keeps every
#   diagnostic line of this function from being cut off by set -e).
#   `docker compose ps -q` returns only the containers of the current
#   project; an empty list is a hard failure, never a vacuous pass.
# ---------------------------------------------------------------------------
if ! declare -F wait_for_healthy > /dev/null 2>&1; then
  wait_for_healthy() {
    local timeout="${1:-120}"; shift
    local -a ids=("$@")
    local waited=0 state health bad line rest name
    if (( ${#ids[@]} == 0 )); then
      err_msg "wait_for_healthy: no containers to check" || return 1
    fi

    local hardfail=0
    while (( waited <= timeout )); do
      bad=""; hardfail=0
      for id in "${ids[@]}"; do
        # Some tasks drive compose with 'sudo docker'; fall back once per query.
        line="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.Name}}' "$id" 2>/dev/null \
             || sudo docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.Name}}' "$id" 2>/dev/null)" \
          || { bad+=" ${id}(uninspectable)"; hardfail=1; continue; }
        state="${line%% *}"; rest="${line#* }"; health="${rest%% *}"; name="${rest#* }"
        case "$state" in
          exited|dead)   bad+=" ${name}(${state})"; hardfail=1; continue ;;
          restarting)    bad+=" ${name}(restarting)"; hardfail=1; continue ;;
        esac
        # Health statuses: starting | healthy | unhealthy ("none" = no healthcheck).
        if [[ "$health" == "unhealthy" ]]; then
          bad+=" ${name}(unhealthy)"
        elif [[ ! ( "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ) ]]; then
          bad+=" ${name}(${state}/${health})"
        fi
      done
      if [[ -z "$bad" ]]; then
        success "All ${#ids[@]} container(s) up and healthy."
        return 0
      fi
      # exited/dead/restarting/uninspectable = immediate failure (crash loop or
      # vanished container): no point burning the whole timeout. (A "created"
      # container is only "not yet ready" — the loop keeps waiting.)
      (( hardfail )) && break
      (( waited == timeout )) && break
      sleep 5; waited=$(( waited + 5 ))
    done

    echo "--- container status ---"
    docker ps -a --filter "id=$(IFS=,; echo "${ids[*]}")" 2>/dev/null || true
    if (( hardfail )); then
      err_msg "Stack not healthy — a container is in a failed state (crash loop?):${bad}" || true
    else
      err_msg "Stack not healthy after ${timeout}s:${bad}" || true
    fi
    err_msg "Inspect with:  docker inspect ${ids[*]}" || true
    err_msg "Logs:          docker compose -f <compose-file> logs" || true
    return 1
  }
fi

# ---------------------------------------------------------------------------
# is_apt_package_installed
#   Returns 0 if the given dpkg package is actually installed (status DB
#   reports 'installed'), 1 otherwise.
#
#   NOTE: Do NOT use `dpkg -l <pkg>` for this — it exits 0 for packages that
#   are merely known to apt (e.g. status 'un', available but not installed),
#   causing false positives.
# ---------------------------------------------------------------------------
if ! declare -F is_apt_package_installed > /dev/null 2>&1; then
  is_apt_package_installed() {
    local pkg="$1"
    dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx 'installed'
  }
fi

# ---------------------------------------------------------------------------
# UFW Firewall Helpers
#   Provides common functions for managing UFW firewall rules.
#
#   `ufw status verbose` is always read through ufw_status_text(), which caches its
#   result in _UFW_STATUS for the lifetime of the shell, so a task with N
#   rules does not shell out N times. The cache is invalidated after every
#   successful rule mutation (ufw allow / ufw delete) so readers never see
#   stale state.
#
#   NOTE: IPv6 rules are rendered differently by `ufw status`; the direction
#   check in ufw_rule_exists only covers the classic IPv4
#   `port/proto  ALLOW IN|OUT` lines.
# ---------------------------------------------------------------------------

# ufw_status_text() result cache (empty _UFW_STATUS_RC = not read yet).
# Guarded so re-sourcing this library is a no-op (does not drop a warm cache).
if [[ -z "${_UFW_STATUS_RC+x}" ]]; then
  _UFW_STATUS=""
  _UFW_STATUS_RC=""
fi

if ! declare -F ufw_available > /dev/null 2>&1; then
  ufw_available() {
    command -v ufw &>/dev/null
  }
fi

if ! declare -F ufw_status_text > /dev/null 2>&1; then
  # ufw_status_text
  #   Prints machine-readable `ufw status verbose` output. Returns:
  #     0 = readable (active or inactive)
  #     1 = ufw binary present but status could not be read (sudo denied, error, ...)
  #     2 = ufw not installed
  #   The verbose format is used deliberately: plain `ufw status` omits the
  #   direction column on ufw >= 0.36 ("22/tcp ALLOW Anywhere"), which would
  #   break the direction-anchored ufw_rule_exists check; verbose always
  #   prints it ("22/tcp ALLOW IN Anywhere"). The first line is the same
  #   "Status: active|inactive" line in both formats.
  #   The result is cached in _UFW_STATUS for the lifetime of the shell;
  #   _ufw_invalidate_status_cache() clears it after rule mutations.
  ufw_status_text() {
    if [[ -n "${_UFW_STATUS_RC}" ]]; then
      if [[ "${_UFW_STATUS_RC}" == "0" ]]; then
        printf '%s\n' "${_UFW_STATUS}"
      fi
      return "${_UFW_STATUS_RC}"
    fi

    if ! command -v ufw &>/dev/null; then
      _UFW_STATUS_RC=2
      return 2
    fi

    local out err err_file
    # Try non-interactive sudo (-n) first so a password prompt can never hang
    # a setup script. On failure, fall back to a possibly-interactive sudo
    # only when the failure was not a password requirement (which would just
    # prompt again or fail the same way).
    err_file="$(mktemp)"
    if out="$(sudo -n ufw status verbose 2>"${err_file}")" && grep -q "^Status:" <<<"$out"; then
      rm -f -- "${err_file}"
      _UFW_STATUS="$out"
      _UFW_STATUS_RC=0
      printf '%s\n' "${_UFW_STATUS}"
      return 0
    fi
    err="$(cat -- "${err_file}")"
    rm -f -- "${err_file}"
    if [[ "${err,,}" == *"password"* ]]; then
      _UFW_STATUS_RC=1
      return 1
    fi
    if out="$(sudo ufw status verbose 2>/dev/null)" && grep -q "^Status:" <<<"$out"; then
      _UFW_STATUS="$out"
      _UFW_STATUS_RC=0
      printf '%s\n' "${_UFW_STATUS}"
      return 0
    fi
    _UFW_STATUS_RC=1
    return 1
  }
fi

if ! declare -F _ufw_invalidate_status_cache > /dev/null 2>&1; then
  # Drop the cached `ufw status` output. Called after a successful rule
  # mutation (ufw allow / ufw delete) so the next read sees the new state.
  _ufw_invalidate_status_cache() {
    _UFW_STATUS=""
    _UFW_STATUS_RC=""
  }
fi

if ! declare -F ufw_active > /dev/null 2>&1; then
  # ufw_active
  #   Returns: 0 = active, 1 = inactive-but-known, 2 = unknown (could not read).
  ufw_active() {
    local status
    if ! status="$(ufw_status_text)"; then
      return 2
    fi
    grep -q "^Status: active" <<<"$status"
  }
fi

if ! declare -F ufw_rule_exists > /dev/null 2>&1; then
  # ufw_rule_exists <port> [proto] [direction]
  #   Returns 0 when a rule for port/proto in the given direction (default IN)
  #   exists. An ALLOW OUT rule never satisfies an ALLOW IN lookup. Returns 1
  #   when the rule is absent or the status could not be read.
  ufw_rule_exists() {
    local port="$1" proto="${2:-tcp}" direction="${3:-IN}"
    local status
    status="$(ufw_status_text)" || return 1
    # Direction-aware: an ALLOW OUT rule must not satisfy an ALLOW IN lookup.
    # Numbered/verbose output prefixes rules with "[  1]", so allow for it.
    grep -qE "^[[:space:]]*(\[[[:space:]]*[0-9]+\][[:space:]]*)?${port}/${proto}[[:space:]]+ALLOW[[:space:]]+${direction}([[:space:]]|$)" <<<"$status"
  }
fi

if ! declare -F ufw_add_rule > /dev/null 2>&1; then
  ufw_add_rule() {
    local port="$1"
    local proto="${2:-tcp}"
    local comment="${3:-}"
    local status_rc=0

    # Unreadable status (sudo denied, ufw error, ...) is a hard failure:
    # refuse to assume the rule is present and name the remedy.
    ufw_status_text >/dev/null || status_rc=$?
    if (( status_rc != 0 )); then
      err_msg "Cannot read 'ufw status' (rc=${status_rc}) — refusing to assume rules are present." || true
      err_msg "Fix passwordless sudo for ufw, or run: sudo ufw allow ${port}/${proto}" || true
      return 1
    fi

    if ufw_rule_exists "$port" "$proto" IN; then
      info "Inbound rule for ${port}/${proto} already exists, skipping."
      return 0
    fi

    if [[ -n "$comment" ]]; then
      sudo ufw allow "${port}/${proto}" comment "${comment}"
    else
      sudo ufw allow "${port}/${proto}"
    fi
    _ufw_invalidate_status_cache
    success "UFW rule added: ${port}/${proto}"
  }
fi

if ! declare -F ufw_delete_rule > /dev/null 2>&1; then
  ufw_delete_rule() {
    local port="$1"
    local proto="${2:-tcp}"

    # `ufw delete allow <port>/<proto>` removes the INBOUND rule only;
    # outbound (ALLOW OUT) rules are not touched.
    sudo ufw delete allow "${port}/${proto}" 2>/dev/null || true
    _ufw_invalidate_status_cache
    success "UFW rule removed: ${port}/${proto}"
  }
fi

if ! declare -F ufw_enable > /dev/null 2>&1; then
  ufw_enable() {
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
      success "UFW is already active."
      return 0
    fi

    sudo ufw --force enable
    success "UFW enabled."
  }
fi

if ! declare -F ufw_show_status > /dev/null 2>&1; then
  ufw_show_status() {
    sudo ufw status
  }
fi

if ! declare -F ufw_firewall_section > /dev/null 2>&1; then
  ufw_firewall_section() {
    local description="${1:-firewall}"
    shift
    # Remaining args are port/proto/comment triples: port proto comment port proto comment ...

    step "Configuring UFW ${description}"

    if ! ufw_available; then
      warn "UFW not installed — skipping ${description} configuration."
      return 0
    fi

    # 0 = active, 1 = inactive-but-known, 2 = unknown (could not read).
    local active=0
    ufw_active || active=$?
    if (( active == 2 )); then
      # Present-but-unreadable UFW is a hard failure: a service task must not
      # silently skip protection.
      error "UFW is installed but its status could not be read — cannot verify that ${description} ports are open. Fix sudo access to ufw (passwordless 'sudo ufw status') and re-run."
    fi
    if (( active == 1 )); then
      warn "UFW is inactive — ${description} rules added below will take effect when the firewall is enabled (configure-firewall.sh)."
    fi

    while [[ $# -ge 3 ]]; do
      local port="$1"
      local proto="${2:-tcp}"
      local comment="${3:-}"
      shift 3
      ufw_add_rule "$port" "$proto" "$comment"
    done
  }
fi
