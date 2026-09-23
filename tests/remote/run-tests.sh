#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# run-tests.sh — In-VM test runner for kwisatz
# =============================================================================
#
# PURPOSE:
#   Runs ON the test VM (invoked over SSH by tests/run-vm-tests.sh).
#   For every enabled script in the test config, runs it twice:
#     1. phase "integration"  — first run on a clean VM
#     2. phase "idempotency"  — second run on the same VM (must not error)
#   Scripts run in the order they appear in the config, with the env vars
#   and arguments configured for them. Failures do NOT stop the run —
#   every configured script is tested.
#
#   Each test case runs under 'sudo -u <vm-user>': this runner is one
#   long-lived SSH session, so group membership changes made by earlier
#   test cases (setup-docker's 'usermod -aG docker') are invisible to it
#   until the next login. 'sudo -u' re-initializes the supplementary groups
#   from the group database — the same effect an operator's re-login has.
#
# OUTPUTS (under --out DIR):
#   results.jsonl   one JSON object per test case
#                   {script, phase, rc, duration_s, log}
#   logs/           one log file per test case (phase-script.log)
#   meta.json       VM metadata (hostname, OS, kernel, date)
#
# USAGE:
#   run-tests.sh --config <config.yml> --workdir <repo-dir> --out <dir> \
#                [--timeout MIN]
#
# REQUIREMENTS:
#   yq, jq (installed by the host orchestrator before this script runs)
#
# EXIT CODES:
#   0 all test cases passed
#   1 one or more test cases failed
#   2 usage error
# =============================================================================

set -uo pipefail

CONFIG=""
WORKDIR=""
OUT=""
TIMEOUT_MIN=30

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --timeout) TIMEOUT_MIN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "run-tests.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CONFIG" || -z "$WORKDIR" || -z "$OUT" ]]; then
  echo "run-tests.sh: --config, --workdir and --out are required" >&2
  exit 2
fi

command -v yq &>/dev/null || { echo "run-tests.sh: yq not found" >&2; exit 1; }
command -v jq &>/dev/null || { echo "run-tests.sh: jq not found" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "run-tests.sh: config not found: $CONFIG" >&2; exit 1; }
[[ -d "$WORKDIR/tasks" ]] || { echo "run-tests.sh: no tasks/ in workdir: $WORKDIR" >&2; exit 1; }

# The VM user this runner runs as (set by sshd; fall back to the uid name).
# Each test case is wrapped in 'sudo -u' so it sees fresh group membership
# (see the header note about the single long-lived SSH session).
VM_USER="${USER:-$(id -un)}"

mkdir -p "$OUT/logs"
: > "$OUT/results.jsonl"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

record() { # <script> <phase> <rc> <duration_s> <log>
  jq -cn \
    --arg script "$1" \
    --arg phase "$2" \
    --argjson rc "$3" \
    --argjson dur "$4" \
    --arg log "$5" \
    '{script: $script, phase: $phase, rc: $rc, duration_s: $dur, log: $log}' \
    >> "$OUT/results.jsonl"
}

# ---------------------------------------------------------------------------
# Setup: collect enabled scripts (config order) and write VM metadata
# ---------------------------------------------------------------------------

mapfile -t SCRIPTS < <(yq -r '.scripts | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG")
if (( ${#SCRIPTS[@]} == 0 )); then
  echo "run-tests.sh: no enabled scripts in config: $CONFIG" >&2
  exit 1
fi

# shellcheck disable=SC1091  # standard os-release file
OS_PRETTY="$(lsb_release -ds 2>/dev/null || { . /etc/os-release; echo "$PRETTY_NAME"; })"
jq -cn \
  --arg hostname "$(hostname)" \
  --arg os "$OS_PRETTY" \
  --arg kernel "$(uname -r)" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{hostname: $hostname, os: $os, kernel: $kernel, date: $date}' > "$OUT/meta.json"

echo "run-tests.sh: testing ${#SCRIPTS[@]} script(s) x 2 phases (timeout ${TIMEOUT_MIN}m each)"

# ---------------------------------------------------------------------------
# Precheck: orchestrator must be able to read the test config
# ---------------------------------------------------------------------------

PRE_LOG="$OUT/logs/precheck-run-setup-status.log"
( cd "$WORKDIR" && ./run-setup.sh -c "$CONFIG" status ) > "$PRE_LOG" 2>&1
PRE_RC=$?
record "run-setup.sh status" "precheck" "$PRE_RC" 0 "$PRE_LOG"
echo "run-tests.sh: [PRECHECK] run-setup.sh status rc=$PRE_RC"

# ---------------------------------------------------------------------------
# Test phases
# ---------------------------------------------------------------------------

OVERALL_RC=0

for phase in integration idempotency; do
  echo "run-tests.sh: ===== phase: $phase ====="

  for script in "${SCRIPTS[@]}"; do
    name="${script%.sh}"
    script_path="$WORKDIR/tasks/${script}.sh"   # config keys carry no .sh suffix
    log="$OUT/logs/${phase}-${script}.log"

    if [[ ! -f "$script_path" ]]; then
      echo "script not found: $script_path" > "$log"
      record "$script" "$phase" 125 0 "$log"
      echo "run-tests.sh: [FAIL] $phase $script (missing on disk)"
      OVERALL_RC=1
      continue
    fi

    # Env vars and args from the config (same values run-setup.sh would apply)
    # shellcheck disable=SC2016  # $n is a yq variable, not bash
    mapfile -t envp < <(yq -r --arg n "$name" \
      '.scripts[$n].env // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG" 2>/dev/null \
      | grep -vE '^$|^null$' || true)
    # shellcheck disable=SC2016  # $n is a yq variable, not bash
    mapfile -t args < <(yq -r --arg n "$name" \
      '.scripts[$n].args // [] | .[]' "$CONFIG" 2>/dev/null \
      | grep -vE '^$|^null$' || true)

    # 'sudo' (below) resets the environment, which would drop the SSH
    # session metadata; scripts that read the live session port
    # (configure-firewall, setup-sshd) must still see it.
    [[ -n "${SSH_CONNECTION:-}" ]] && envp+=("SSH_CONNECTION=${SSH_CONNECTION}")
    [[ -n "${SSH_CLIENT:-}" ]] && envp+=("SSH_CLIENT=${SSH_CLIENT}")

    start=$(date +%s)
    timeout --kill-after=60 "${TIMEOUT_MIN}m" \
      sudo -u "${VM_USER}" env "${envp[@]}" "$script_path" "${args[@]}" > "$log" 2>&1
    rc=$?
    dur=$(( $(date +%s) - start ))

    record "$script" "$phase" "$rc" "$dur" "$log"

    if (( rc == 0 )); then
      echo "run-tests.sh: [PASS] $phase $script (${dur}s)"
    else
      if (( rc == 124 )); then
        echo "run-tests.sh: [TIMEOUT] $phase $script after ${TIMEOUT_MIN}m"
      else
        echo "run-tests.sh: [FAIL] $phase $script rc=$rc (${dur}s) — last log lines:"
        tail -n 5 "$log" | sed 's/^/run-tests.sh:     /'
      fi
      OVERALL_RC=1
    fi
  done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "run-tests.sh: results: $OUT/results.jsonl"
if (( OVERALL_RC == 0 )); then
  echo "run-tests.sh: ALL TESTS PASSED (${#SCRIPTS[@]} scripts x 2 phases + precheck)"
else
  echo "run-tests.sh: SOME TESTS FAILED — see $OUT/results.jsonl"
fi
exit "$OVERALL_RC"
