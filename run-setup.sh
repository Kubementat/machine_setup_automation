#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# run-setup.sh — Orchestrator for kwisatz machine setup
# =============================================================================
#
# DESCRIPTION:
#   Reads machine-config.yml to determine which setup scripts to run,
#   with their configured environment variables and command-line arguments.
#   All apply/status output is additionally logged to ./logs/ (see
#   setup_logging, LOG_DIR).
#
# SUBCOMMANDS:
#   apply    Run all enabled setup scripts
#   status   Show which scripts are enabled/disabled (read-only, never installs)
#
# USAGE:
#   ./run-setup.sh [options] <subcommand>
#   ./run-setup.sh <subcommand> [options]
#
# Options may appear before OR after the subcommand:
#   -c/--config <file>, --non-interactive, --interactive, -h/--help
#
# Run without arguments (or with -h/--help) for the full usage text.
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/machine-config.yml"
TASKS_DIR="${SCRIPT_DIR}/tasks"
CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
LOG_PREFIX="[RUN-SETUP]"

# Process log (see setup_logging): all output of apply/status is additionally
# written to ${LOG_DIR:-<repo>/logs}/run-setup-<timestamp>-<pid>.log.
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
LOG_FILE=""

# Prompt policy for all child tasks. Tasks default to INTERACTIVE=false (see
# specification/project/conventions.md); the orchestrator makes the intent explicit
# and strips stdin from children in non-interactive mode, so a stray 'read' fails
# immediately instead of hanging an unattended run.
: "${INTERACTIVE:=false}"
NON_INTERACTIVE=false      # set by --non-interactive; --interactive clears it

# Colour only when stdout is a terminal and NO_COLOR is not set (https://no-color.org).
# NO_COLOR=1 or a pipe/redirect (e.g. the VM harness capturing logs) gives plain text.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; RESET=$'\e[0m'; RED=$'\e[0;31m'; GREEN=$'\e[0;32m'
  YELLOW=$'\e[1;33m'; CYAN=$'\e[0;36m'
else
  BOLD=; RESET=; RED=; GREEN=; YELLOW=; CYAN=
fi
readonly BOLD RESET RED GREEN YELLOW CYAN

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

log_info()    { printf '%b %b %s\n' "${LOG_PREFIX}" "${CYAN}[INFO]${RESET}   " "$*"; }
log_success() { printf '%b %b %s\n' "${LOG_PREFIX}" "${GREEN}[OK]${RESET}     " "$*"; }
log_warn()    { printf '%b %b %s\n' "${LOG_PREFIX}" "${YELLOW}[WARN]${RESET}  " "$*"; }
log_error()   { printf '%b %b %s\n' "${LOG_PREFIX}" "${RED}[ERROR]${RESET}" "$*" >&2; }
log_step()    { printf '\n%b %s\n'  "${BOLD}${LOG_PREFIX} ▶${RESET}" "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# setup_logging
#   Tees every further stdout/stderr byte (this script's output and all child
#   task output) into LOG_FILE in addition to the terminal. The terminal keeps
#   its colours; the log file gets plain text (the sed branch strips ANSI
#   escapes). If the log directory cannot be created the run continues
#   without a log file — logging must never break a setup run.
# ─────────────────────────────────────────────────────────────────────────────

setup_logging() {
  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    log_warn "Could not create log directory: ${LOG_DIR} — continuing without a log file"
    return 0
  fi

  LOG_FILE="${LOG_DIR}/run-setup-$(date +%Y%m%d-%H%M%S)-$$.log"

  # tee's own stdout is the terminal as it was before the exec (colours
  # intact); the nested sed branch writes the ANSI-stripped stream to the log.
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE")) 2>&1

  log_info "Log file: ${LOG_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Dependency Checks
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# ensure_basic_tools
#   Ensures yq and jq are available. If any are missing, automatically
#   runs tasks/setup-basics.sh to install them, then re-checks.
# ─────────────────────────────────────────────────────────────────────────────

ensure_basic_tools() {
  local missing_tools=()

  command -v yq &>/dev/null || missing_tools+=("yq")
  command -v jq &>/dev/null || missing_tools+=("jq")

  if (( ${#missing_tools[@]} == 0 )); then
    return 0
  fi

  # Unattended runs must not provision the machine: with --non-interactive the
  # operator asked for prompt-free execution, so fail fast instead of running a
  # full apt install. ASSUME_SETUP_BASICS=true opts back into the auto-install.
  if [[ "${NON_INTERACTIVE}" == "true" && "${ASSUME_SETUP_BASICS:-false}" != "true" ]]; then
    log_error "Missing required tool(s): ${missing_tools[*]}."
    log_error "Not auto-installing: --non-interactive unattended runs must not provision the machine."
    log_error "Install them manually (e.g. 'bash tasks/setup-basics.sh'), or re-run with ASSUME_SETUP_BASICS=true."
    return 1
  fi

  log_warn "Missing required tool(s): ${missing_tools[*]}. Running setup-basics.sh to install them..."

  local basics_script="${TASKS_DIR}/setup-basics.sh"
  if [[ ! -f "$basics_script" ]]; then
    log_error "setup-basics.sh not found: $basics_script"
    return 1
  fi

  if ! bash "$basics_script"; then
    log_error "setup-basics.sh failed; cannot continue without: ${missing_tools[*]}"
    return 1
  fi

  # Re-check after setup-basics.sh ran
  local tool
  for tool in yq jq; do
    if ! command -v "$tool" &>/dev/null; then
      log_error "$tool is still not available after running setup-basics.sh"
      return 1
    fi
  done

  log_success "Required tool(s) installed: ${missing_tools[*]}"
}

# check_dependencies <mode>
#   mode = "apply"  -> auto-install missing yq/jq via tasks/setup-basics.sh
#   mode = "status" -> read-only: require yq/jq, never install anything
check_dependencies() {
  local mode="${1:-apply}"
  local missing=0

  if [[ "$mode" == "apply" ]]; then
    if ! ensure_basic_tools; then
      missing=1
    fi
  elif ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
    log_error "yq/jq are required but not installed."
    log_error "Install them (e.g. './run-setup.sh apply' or 'tasks/setup-basics.sh'), then re-run status."
    missing=1
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    log_error "Hint: copy machine-config.yml.example to machine-config.yml"
    missing=1
  elif command -v yq &>/dev/null; then
    # The rest of the run treats .scripts as a mapping; fail early with a clean
    # message for a config that does not parse or has the wrong type (otherwise
    # a later yq error would abort the script under set -e).
    local scripts_type
    if ! scripts_type=$(yq -r '.scripts | type' "$CONFIG_FILE" 2>/dev/null); then
      log_error "Configuration file could not be parsed: $CONFIG_FILE"
      missing=1
    elif [[ -n "$scripts_type" && "$scripts_type" != "object" && "$scripts_type" != "null" ]]; then
      log_error "Invalid configuration: '.scripts' must be a mapping (got ${scripts_type}): $CONFIG_FILE"
      missing=1
    fi
  fi

  if [[ ! -d "$TASKS_DIR" ]]; then
    log_error "Tasks directory not found: $TASKS_DIR"
    missing=1
  fi

  if (( missing )); then
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# discover_scripts
#   Finds all setup scripts in the tasks directory.
#   Returns all script names (without path, sorted alphabetically),
#   regardless of whether they are executable.
# ─────────────────────────────────────────────────────────────────────────────

# shellcheck disable=SC2120  # pattern param unused but kept for extensibility
discover_scripts() {
  local pattern="${1:-*.sh}"

  if [[ ! -d "$TASKS_DIR" ]]; then
    log_error "Tasks directory not found: $TASKS_DIR" >&2
    return 1
  fi

  (
    shopt -s nullglob
    cd "$TASKS_DIR" || exit 1
    for script in $pattern; do
      if [[ -f "$script" ]]; then
        basename "$script"
      fi
    done
  ) | sort
}

# ─────────────────────────────────────────────────────────────────────────────
# config_script_order
#   Prints script names (without .sh suffix) in the order they are
#   defined in the .scripts mapping of the configuration file.
#   Note: yq "keys" sorts alphabetically; "to_entries" preserves
#   document order.
# ─────────────────────────────────────────────────────────────────────────────

config_script_order() {
  yq -r '.scripts | to_entries[] | .key' "$CONFIG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# is_script_enabled
#   Checks if a script is enabled in the config.
#   Returns 0 if enabled, 1 if disabled/not found.
# ─────────────────────────────────────────────────────────────────────────────

is_script_enabled() {
  local script_name="${1%.sh}"

  # shellcheck disable=SC2016  # $name is a jq variable, not bash
  yq --arg name "$script_name" '.scripts[$name].enabled // false' "$CONFIG_FILE" | grep -qx "true"
}

# ─────────────────────────────────────────────────────────────────────────────
# get_script_env
#   Prints environment variables for a script, one per line as KEY=VALUE.
# ─────────────────────────────────────────────────────────────────────────────

get_script_env() {
  local script_name="${1%.sh}"

  # shellcheck disable=SC2016  # $name is a jq variable, not bash
  yq -r --arg name "$script_name" \
    '.scripts[$name].env // {} | to_entries[] | "\(.key)=\(.value)"' \
    "$CONFIG_FILE" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# get_script_args
#   Prints command-line arguments for a script, one per line.
# ─────────────────────────────────────────────────────────────────────────────

get_script_args() {
  local script_name="${1%.sh}"

  # shellcheck disable=SC2016  # $name is a jq variable, not bash
  yq -r --arg name "$script_name" \
    '.scripts[$name].args // [] | .[]' \
    "$CONFIG_FILE" 2>/dev/null | grep -vE '^$|^null$' || true
}

# ─────────────────────────────────────────────────────────────────────────────
# get_script_description
#   Prints the description for a script.
# ─────────────────────────────────────────────────────────────────────────────

get_script_description() {
  local script_name="${1%.sh}"

  # shellcheck disable=SC2016  # $name is a jq variable, not bash
  yq -r --arg name "$script_name" \
    '.scripts[$name].description // ""' \
    "$CONFIG_FILE" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_status
#   Shows which scripts are enabled/disabled.
# ─────────────────────────────────────────────────────────────────────────────

cmd_status() {
  check_dependencies status

  log_step "Checking configuration"
  echo

  printf '%bConfiguration: %s%b\n' "${BOLD}" "$CONFIG_FILE" "${RESET}"
  printf '%bTasks Directory: %s%b\n' "${BOLD}" "$TASKS_DIR" "${RESET}"
  echo

  # Validate config can be read
  local script_count
  script_count=$(yq '(.scripts | length) // 0' "$CONFIG_FILE")
  if [[ ! "$script_count" =~ ^[0-9]+$ ]] || (( script_count == 0)); then
    log_error "No scripts found in configuration"
    exit 1
  fi

  printf 'Scripts in config: %b%s%b\n' "${BOLD}" "$script_count" "${RESET}"
  echo

  local enabled_count=0
  if ! enabled_count=$(yq '.scripts | to_entries | map(select(.value.enabled == true)) | length' "$CONFIG_FILE" 2>/dev/null); then
    log_error "Could not compute the enabled-script count from configuration: $CONFIG_FILE"
    exit 1
  fi
  # Normalise BEFORE any arithmetic: a non-numeric yq result must not reach $(( )).
  [[ "$enabled_count" =~ ^[0-9]+$ ]] || enabled_count=0
  if (( enabled_count > 0 )); then
    printf 'Enabled: %b%s%b\n' "${GREEN}" "$enabled_count" "${RESET}"
  else
    printf 'Enabled: %b%s%b\n' "${YELLOW}" "0" "${RESET}"
  fi

  local disabled_count=$((script_count - enabled_count))
  if (( disabled_count < 0 )); then
    disabled_count=0
  fi
  if (( disabled_count > 0 )); then
    printf 'Disabled: %b%s%b\n' "${CYAN}" "$disabled_count" "${RESET}"
  else
    printf 'Disabled: %b%s%b\n' "${CYAN}" "0" "${RESET}"
  fi

  echo

  # Show all scripts with their status
  printf '%bScript Status:%b\n' "${BOLD}" "${RESET}"
  echo

  # List scripts in the order defined in the config file, then append
  # scripts found on disk that are not in the config (sorted alphabetically)
  local -a scripts_array=()
  local -A seen=()
  local line
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      scripts_array+=("${line}.sh")
      seen["$line"]=1
    fi
  done < <(config_script_order)

  while IFS= read -r line; do
    if [[ -n "$line" && -z "${seen[${line%.sh}]:-}" ]]; then
      scripts_array+=("$line")
    fi
  done < <(discover_scripts)

  if (( ${#scripts_array[@]} == 0 )); then
    log_error "No scripts found"
    exit 1
  fi

  # Compute column width
  local max_len=0
  for script in "${scripts_array[@]}"; do
    local len=${#script}
    if (( len > max_len )); then
      max_len=$len
    fi
  done

  line=$(printf '%.0s─' $(seq 1 $((max_len + 30))))

  echo "$line"

  for script in "${scripts_array[@]}"; do
    local enabled="no"
    local color="${CYAN}"

    if is_script_enabled "$script"; then
      enabled="yes"
      color="${GREEN}"
    fi

    printf "  %-${max_len}s  %s\n" "$script" "$color$enabled$RESET"
  done

  echo "$line"

  echo

  # Show configured env vars and args for enabled scripts
  local first=true
  for script in "${scripts_array[@]}"; do
    if is_script_enabled "$script"; then
      if [[ -f "${TASKS_DIR}/${script}" ]]; then
        if [[ "$first" == "true" ]]; then
          printf '%bConfiguration for enabled scripts:%b\n' "${BOLD}" "${RESET}"
          first=false
        fi

        echo
        printf '%b  %s:%b\n' "${BOLD}" "$script" "${RESET}"

        local desc
        desc=$(get_script_description "$script")
        if [[ -n "$desc" ]]; then
          echo "    ${desc}"
        fi

        # Show env vars
        local env_vars
        env_vars=$(get_script_env "$script")
        if [[ -n "$env_vars" ]]; then
          echo "    Environment:"
          echo "      ${env_vars//$'\n'/$'\n      '}"
        fi

        # Show args
        local args
        args=$(get_script_args "$script")
        if [[ -n "$args" ]]; then
          echo "    Arguments:"
          echo "      ${args//$'\n'/$'\n      '}"
        fi
      fi
    fi
  done

  echo
}

# ─────────────────────────────────────────────────────────────────────────────
# run_script
#   Runs a single script with its configured environment and arguments.
#   Returns the exit code of the script.
# ─────────────────────────────────────────────────────────────────────────────

run_script() {
  local script_name="$1"
  local script_path="${TASKS_DIR}/${script_name}"

  if [[ ! -f "$script_path" ]]; then
    log_error "Script not found: $script_path"
    return 1
  fi

  if [[ ! -x "$script_path" ]]; then
    log_warn "Script not executable: $script_path"
    if ! chmod +x "$script_path"; then
      log_error "Cannot make script executable: $script_path"
      return 1
    fi
  fi

  log_step "Running ${script_name}"

  # Collect environment variables as KEY=VALUE strings
  local env_args=()
  while IFS= read -r env_pair; do
    [[ -n "$env_pair" ]] && env_args+=("$env_pair")
  done < <(get_script_env "$script_name")

  # Collect arguments
  local args=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && args+=("$arg")
  done < <(get_script_args "$script_name")

  # Run the script with the prompt policy and its configured environment.
  # The INTERACTIVE value is placed BEFORE the config env entries so a
  # per-script `env:` entry for INTERACTIVE in the config wins (in `env` the
  # last assignment takes effect) — the config is the more specific declaration.
  # In non-interactive mode stdin is /dev/null, so a stray 'read' fails fast
  # instead of hanging an unattended run.
  if [[ "${INTERACTIVE}" == "true" ]]; then
    if [[ ${#env_args[@]} -gt 0 ]]; then
      env "INTERACTIVE=true" "${env_args[@]}" "$script_path" "${args[@]}"
    else
      env "INTERACTIVE=true" "$script_path" "${args[@]}"
    fi
  else
    if [[ ${#env_args[@]} -gt 0 ]]; then
      env "INTERACTIVE=false" "${env_args[@]}" "$script_path" "${args[@]}" < /dev/null
    else
      env "INTERACTIVE=false" "$script_path" "${args[@]}" < /dev/null
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_apply
#   Runs all enabled setup scripts.
# ─────────────────────────────────────────────────────────────────────────────

cmd_apply() {
  log_step "Applying configuration"

  check_dependencies apply

  echo
  log_info "Reading configuration from: $CONFIG_FILE"
  log_info "Scripts directory: $TASKS_DIR"
  echo

  # Check if any scripts are enabled
  local enabled_count=0
  if ! enabled_count=$(yq '.scripts | to_entries | map(select(.value.enabled == true)) | length' "$CONFIG_FILE" 2>/dev/null); then
    log_error "Could not compute the enabled-script count from configuration: $CONFIG_FILE"
    exit 1
  fi
  # Normalise BEFORE any arithmetic: a non-numeric yq result must not reach $(( )).
  [[ "$enabled_count" =~ ^[0-9]+$ ]] || enabled_count=0

  if (( enabled_count == 0 )); then
    exit 0
  fi

  log_info "Found ${enabled_count} enabled script(s)"
  echo

  # Run scripts in the order they are defined in the config file
  local -a scripts_array=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && scripts_array+=("${line}.sh")
  done < <(config_script_order)

  if (( ${#scripts_array[@]} == 0 )); then
    log_error "No scripts found in configuration"
    exit 1
  fi

  # Run each enabled script
  local failed_count=0
  local skipped_count=0

  for script in "${scripts_array[@]}"; do
    if is_script_enabled "$script"; then
      local script_path="${TASKS_DIR}/${script}"

      if [[ ! -f "$script_path" ]]; then
        log_error "Configured script not found: $script"
        skipped_count=$((skipped_count + 1))
        continue
      fi

      echo
      if run_script "$script"; then
        log_success "Completed: $script"
      else
        log_error "Failed: $script"
        ((++failed_count))
      fi
    fi
  done

  # Report results
  echo
  echo
  log_step "Run Summary"

  local total_enabled=$enabled_count
  local success_count=$((total_enabled - failed_count - skipped_count))

  if (( success_count == total_enabled )) && (( success_count > 0 )); then
    log_success "All $success_count script(s) completed successfully"
  else
    if (( success_count > 0 )); then
      log_info "Succeeded: $success_count/$total_enabled"
    fi

    if (( skipped_count > 0 )); then
      log_warn "Skipped: $skipped_count/$total_enabled (scripts missing from disk)"
    fi

    if (( failed_count > 0 )); then
      log_error "Failed: $failed_count/$total_enabled"
      echo
      log_info "Check logs above for details"
      exit 1
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_help
#   Shows usage information.
# ─────────────────────────────────────────────────────────────────────────────

cmd_help() {
  cat <<'EOF'

  kwisatz Setup Automation Runner

  Usage:
    ./run-setup.sh [options] <subcommand>
    ./run-setup.sh <subcommand> [options]

  Options may appear before OR after the subcommand.

  Subcommands:
    apply    Run all enabled setup scripts
    status   Show which scripts are enabled/disabled (read-only: never installs)

  Options:
    -c, --config <file>  Path to configuration file (default: machine-config.yml)
    -h, --help           Show this help message and exit
    --non-interactive    Run children with INTERACTIVE=false and stdin from
                         /dev/null so a stray prompt fails fast instead of
                         hanging an unattended run (this is the default)
    --interactive        Run children with INTERACTIVE=true on an inherited tty
                         (the only opt-in to prompts)
                         (mutually exclusive with --non-interactive)

  Prompt policy (INTERACTIVE contract):
    Every child is run with INTERACTIVE set explicitly (true or false). In
    non-interactive mode the child's stdin is /dev/null, so a stray 'read'
    fails immediately instead of hanging an unattended run. A per-script
    `env:` entry INTERACTIVE=true in the config overrides the global default
    for that script (config wins).
    Note: --yes / ASSUME_YES is deliberately NOT implemented — auto-answering
    prompts per question is not something the docker tasks can express today.
    --interactive is the only opt-in to prompts.

  Logging:
    apply and status tee all output (this script's messages and every child
    task's stdout/stderr) into a plain-text log file
    <repo>/logs/run-setup-<YYYYmmdd-HHMMSS>-<pid>.log in addition to the
    terminal. The terminal keeps its colours; the log file is ANSI-stripped.
    Override the directory with the LOG_DIR environment variable. If the log
    directory cannot be created the run continues without a log file.
    help/usage output is not logged.

  Dependencies:
    status is read-only: it never installs anything and exits with a hint if
    yq/jq are missing. apply auto-installs missing yq/jq by running
    tasks/setup-basics.sh — except under --non-interactive, where yq/jq must
    already be installed (unattended runs fail fast and do not provision the
    machine; set ASSUME_SETUP_BASICS=true to allow the auto-install).

  Deliberately unimplemented:
    --only <a,b>  (use tests/run-vm-tests.sh --scripts for a subset)
    --dry-run     (apply has no dry-run semantics worth faking)

  Examples:
    ./run-setup.sh status
    ./run-setup.sh apply
    ./run-setup.sh apply --config my-config.yml
    ./run-setup.sh --config my-config.yml apply
    ./run-setup.sh apply --non-interactive

  Configuration:
    Edit machine-config.yml to enable/disable scripts and configure
    their environment variables and command-line arguments.

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Entry Point
# ─────────────────────────────────────────────────────────────────────────────

main() {
  # Two-pass scan: known global options are consumed wherever they appear,
  # exactly one subcommand is taken, and anything else is a hard usage error
  # (exit 2) — never silently dropped.
  local config_file=""
  local subcommand=""
  local saw_interactive=0 saw_non_interactive=0
  local -a positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)
        if [[ -z "${2:-}" ]]; then
          log_error "--config requires a value"
          exit 2
        fi
        if [[ -n "$config_file" ]]; then
          log_error "--config given more than once"
          exit 2
        fi
        config_file="$2"; shift 2 ;;
      -h|--help)
        subcommand="${subcommand:-help}"; shift ;;
      --non-interactive)
        saw_non_interactive=$((saw_non_interactive + 1))
        NON_INTERACTIVE=true; INTERACTIVE=false; shift ;;
      --interactive)
        saw_interactive=$((saw_interactive + 1))
        INTERACTIVE=true; NON_INTERACTIVE=false; shift ;;
      -*)
        log_error "Unknown option: $1"
        cmd_help >&2
        exit 2 ;;
      *)
        positional+=("$1"); shift ;;
    esac
  done

  if (( saw_interactive > 0 && saw_non_interactive > 0 )); then
    log_error "--interactive and --non-interactive are mutually exclusive"
    cmd_help >&2
    exit 2
  fi

  if (( ${#positional[@]} > 1 )); then
    log_error "Unexpected argument: ${positional[1]}"
    cmd_help >&2
    exit 2
  fi

  subcommand="${subcommand:-${positional[0]:-help}}"

  # Resolve config file
  if [[ -n "$config_file" ]]; then
    if [[ "$config_file" != /* ]]; then
      CONFIG_FILE="$(cd "$(pwd)" && cd "$(dirname "$config_file")" && pwd)/$(basename "$config_file")"
    else
      CONFIG_FILE="$config_file"
    fi
  else
    CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
  fi

  case "$subcommand" in
    apply)
      setup_logging
      cmd_apply
      ;;
    status)
      setup_logging
      cmd_status
      ;;
    help)
      cmd_help
      exit 0
      ;;
    *)
      log_error "Unknown subcommand: $subcommand"
      echo
      cmd_help >&2
      exit 1
      ;;
  esac
}

main "$@"
