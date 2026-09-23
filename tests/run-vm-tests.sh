#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# run-vm-tests.sh — VM-based integration test orchestrator
# =============================================================================
#
# DESCRIPTION:
#   One-command VM test pipeline for the setup scripts in tasks/
#   (see specification/project/test-strategy.md and
#   docs/plans/vm-integration-tests.md):
#
#     1. Spin up a fresh Ubuntu VM via virt-runner (virt-runner create)
#     2. Copy this repository to the VM (scp)
#     3. Run every enabled script from the test config twice:
#        phase 1 "integration" (clean VM), phase 2 "idempotency" (re-run)
#     4. Destroy the test VM (virt-runner destroy) — unless --keep-vm
#     5. Write a Markdown test report to tests/reports/vmtest-<ts>/report.md
#
# USAGE:
#   tests/run-vm-tests.sh [OPTIONS]
#
#   --name NAME        VM name (default: mas-vmtest-<YYYYmmdd-HHMMSS>)
#   --scripts A,B,C    Test only these scripts (comma-separated; overrides
#                      the enabled set in the test config, env/args for each
#                      script are still taken from the test config)
#   --config FILE      Test config file (default: tests/machine-config.test.yml)
#   --release REL      Ubuntu release codename (default: resolute)
#   --ram GB           VM RAM in GiB (default: 4)
#   --vcpu N           VM vCPU count (default: 2)
#   --disk GB          VM disk in GiB (default: 30)
#   --user USER        VM user name (default: ubuntu)
#   --timeout MIN      Per-script timeout on the VM (default: 30)
#   --keep-vm          Do not destroy the VM after the run (debugging)
#   -h, --help         Show this help
#
# ENVIRONMENT:
#   VIRT_RUNNER   Command to invoke virt-runner
#                 (default: virt-runner, must be on PATH)
#   VM_SSH_KEY    Public SSH key to inject into the VM
#                 (default: $HOME/.ssh/id_ed25519.pub)
#
# EXIT CODES:
#   0 all test cases passed (both phases)
#   1 one or more test cases failed, or the pipeline itself failed
#   2 usage error
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../" && pwd)"
readonly REPO_ROOT

# ---------------------------------------------------------------------------
# Defaults / options
# ---------------------------------------------------------------------------

TS="$(date +%Y%m%d-%H%M%S)"
VM_NAME="mas-vmtest-${TS}"
VIRT_RUNNER="${VIRT_RUNNER:-virt-runner}"
CONFIG="${SCRIPT_DIR}/machine-config.test.yml"
RELEASE="resolute"
RAM=4
VCPUS=2
DISK=30
VM_USER="ubuntu"
TIMEOUT_MIN=30
ONLY_SCRIPTS=""
KEEP_VM=0
REAL_HOME="$HOME"
SSH_KEY="${VM_SSH_KEY:-${REAL_HOME}/.ssh/id_ed25519.pub}"

usage() { sed -n '3,47p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      VM_NAME="$2"; shift 2 ;;
    --scripts)   ONLY_SCRIPTS="$2"; shift 2 ;;
    --config)    CONFIG="$2"; shift 2 ;;
    --release)   RELEASE="$2"; shift 2 ;;
    --ram)       RAM="$2"; shift 2 ;;
    --vcpu)      VCPUS="$2"; shift 2 ;;
    --disk)      DISK="$2"; shift 2 ;;
    --user)      VM_USER="$2"; shift 2 ;;
    --timeout)   TIMEOUT_MIN="$2"; shift 2 ;;
    --keep-vm)   KEEP_VM=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "run-vm-tests.sh: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

log()  { echo "[VM-TEST] $*"; }
fail() { echo "[VM-TEST][ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Report dir & cleanup
# ---------------------------------------------------------------------------

REPORT_DIR="${SCRIPT_DIR}/reports/vmtest-${TS}"
mkdir -p "$REPORT_DIR" || fail "cannot create report dir: $REPORT_DIR"

# Isolated SSH config for this run: the libvirt NAT network re-assigns IPs
# (192.168.122.0/24), so the default known_hosts collides with keys of long
# gone VMs and `accept-new` refuses to override them. A per-run known_hosts
# file avoids touching the user's ~/.ssh/known_hosts and never collides.
cat > "${REPORT_DIR}/ssh_config" <<EOF
Host *
    UserKnownHostsFile ${REPORT_DIR}/ssh-known-hosts
    StrictHostKeyChecking accept-new
    BatchMode yes
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 3
EOF
SSH_OPTS=(-F "${REPORT_DIR}/ssh_config")

# virt-runner create invokes `ssh` internally for its own verification, and
# the default known_hosts collides with stale entries for IPs the NAT network
# re-assigned (accept-new never overrides a conflicting entry). ssh(1)
# ignores the $HOME environment variable on this platform, so we interpose
# an ssh wrapper on PATH for the virt-runner create invocation only. CLI
# options win over any config file, so the isolated known_hosts always applies.
SSH_SHIM_DIR="${REPORT_DIR}/vmhome-bin"
mkdir -p "$SSH_SHIM_DIR"
cat > "${SSH_SHIM_DIR}/ssh" <<EOF
#!/usr/bin/env bash
exec $(command -v ssh) -o UserKnownHostsFile=${REPORT_DIR}/ssh-known-hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes "\$@"
EOF
chmod +x "${SSH_SHIM_DIR}/ssh"

# shellcheck disable=SC2029  # command string is meant to expand on the client
remote_ssh() { ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "$@"; }

VM_CREATED=0

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  if (( VM_CREATED )) && (( ! KEEP_VM )); then
    log "Destroying test VM: ${VM_NAME}"
    if "$VIRT_RUNNER" destroy "$VM_NAME" --json > "$REPORT_DIR/destroy.json" 2> "$REPORT_DIR/destroy-stderr.log"; then
      log "VM destroyed (log: ${REPORT_DIR}/destroy.json)"
    else
      echo "[VM-TEST][ERROR] virt-runner destroy FAILED — manual cleanup: $VIRT_RUNNER destroy $VM_NAME" >&2
      echo "  (see ${REPORT_DIR}/destroy.json)" >&2
    fi
  elif (( VM_CREATED )) && (( KEEP_VM )); then
    log "Keeping VM (as requested): ${VM_NAME}"
    echo "  access:  ssh ${VM_USER}@$(jq -r '.vm.ip // empty' "$REPORT_DIR/create.json")"
    echo "  teardown: $VIRT_RUNNER destroy $VM_NAME"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "Preflight checks"
command -v "$VIRT_RUNNER" &>/dev/null || fail "virt-runner not found or not executable: $VIRT_RUNNER (set VIRT_RUNNER)"
command -v jq &>/dev/null || fail "jq not found (required to parse virt-runner JSON output)"
[[ -f "$SSH_KEY" ]] || fail "SSH public key not found: $SSH_KEY (set VM_SSH_KEY)"
virsh list --all &>/dev/null || fail "libvirt is not reachable (virsh list failed)"
[[ -f "$CONFIG" ]] || fail "test config not found: $CONFIG"
command -v scp &>/dev/null || fail "scp not found"

# Optional: restrict to a subset of scripts -> generate a modified config
GENERATED_CONFIG=""
if [[ -n "$ONLY_SCRIPTS" ]]; then
  command -v yq &>/dev/null || fail "yq is required for --scripts"
  GENERATED_CONFIG="${REPORT_DIR}/config.generated.yml"
  # Read-modify-write style (bare jq-compatible filters) so this works with
  # both mikefarah yq and the Python yq (jq wrapper) that Ubuntu ships.
  yq '.scripts |= with_entries(.value.enabled = false)' "$CONFIG" > "$GENERATED_CONFIG" \
    || fail "cannot generate config from $CONFIG"
  IFS=',' read -ra wanted <<< "$ONLY_SCRIPTS"
  for s in "${wanted[@]}"; do
    s="${s// /}"
    [[ -n "$s" ]] || continue
    if [[ "$(yq -r ".scripts[\"$s\"] // null" "$GENERATED_CONFIG" 2>/dev/null)" == "null" ]]; then
      yq ".scripts[\"$s\"] = {enabled: true, description: \"added via --scripts\", env: {}, args: []}" \
        "$GENERATED_CONFIG" > "${GENERATED_CONFIG}.tmp" \
        || fail "cannot add script to test config: $s"
    else
      yq ".scripts[\"$s\"].enabled = true" "$GENERATED_CONFIG" > "${GENERATED_CONFIG}.tmp" \
        || fail "cannot enable script in test config: $s"
    fi
    mv "${GENERATED_CONFIG}.tmp" "$GENERATED_CONFIG"
  done
  CONFIG="$GENERATED_CONFIG"
fi

# ---------------------------------------------------------------------------
# Step 1 — create the VM
# ---------------------------------------------------------------------------

log "Creating VM '${VM_NAME}' (release=${RELEASE} ram=${RAM}GiB vcpu=${VCPUS} disk=${DISK}GiB)"
# virt-runner create --json: stdout carries exactly one JSON document (also on
# failure, where error.code/message are reported and already-created resources
# remain visible under .vm). stderr is kept separate so the JSON stays parseable.
if ! PATH="${SSH_SHIM_DIR}:${PATH}" "$VIRT_RUNNER" create "$VM_NAME" \
      --ram "$RAM" --vcpu "$VCPUS" --disk "$DISK" \
      --release "$RELEASE" --user "$VM_USER" \
      --ssh-key "${SSH_KEY}" \
      --json > "$REPORT_DIR/create.json" 2> "$REPORT_DIR/create-stderr.log"; then
  # virt-runner's 90s SSH window can expire on slow first boots even when the
  # domain is healthy; the JSON still reports the VM and its IP in that case.
  # Recover: if the domain was created and an IP assigned, give the guest up
  # to 5 more minutes.
  VM_IP="$(jq -r '.vm.ip // empty' "$REPORT_DIR/create.json" 2>/dev/null)"
  if [[ -n "$VM_IP" ]] && virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log "virt-runner create timed out waiting for SSH — waiting up to 5m more (IP: ${VM_IP})"
    for _ in $(seq 1 30); do
      if remote_ssh exit 2>/dev/null; then
        VM_CREATED=1
        log "VM recovered: SSH is up"
        break
      fi
      sleep 10
    done
  fi
  if (( VM_CREATED != 1 )); then
    echo "----- create.json -----" >&2
    tail -n 20 "$REPORT_DIR/create.json" >&2
    if [[ -s "$REPORT_DIR/create-stderr.log" ]]; then
      echo "----- create-stderr.log (tail) -----" >&2
      tail -n 20 "$REPORT_DIR/create-stderr.log" >&2
    fi
    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
      log "Removing half-created VM: ${VM_NAME}"
      "$VIRT_RUNNER" destroy "$VM_NAME" --json > "$REPORT_DIR/destroy.json" 2>&1 || true
    fi
    fail "virt-runner create failed — see ${REPORT_DIR}/create.json"
  fi
else
  VM_IP="$(jq -r '.vm.ip // empty' "$REPORT_DIR/create.json" 2>/dev/null)"
  [[ -n "$VM_IP" ]] || fail "could not parse VM IP from ${REPORT_DIR}/create.json (unexpected virt-runner create output)"
  VM_CREATED=1
fi
log "VM ready: ${VM_NAME} at ${VM_IP}"

# ---------------------------------------------------------------------------
# Step 2 — copy the repository to the VM
# ---------------------------------------------------------------------------

# Resolve the REMOTE user's home (host $HOME would be wrong here)
# shellcheck disable=SC2016  # $HOME must expand on the VM
REMOTE_HOME="$(remote_ssh 'echo "$HOME"')"
[[ -n "$REMOTE_HOME" ]] || fail "cannot determine remote home directory"
REMOTE_DIR="${REMOTE_HOME}/kwisatz"
log "Copying repository to ${VM_USER}@${VM_IP}:${REMOTE_DIR}"
remote_ssh "mkdir -p '${REMOTE_DIR}'" || fail "cannot create remote dir"
if ! scp "${SSH_OPTS[@]}" -r "${REPO_ROOT}/." "${VM_USER}@${VM_IP}:${REMOTE_DIR}/" \
      > "$REPORT_DIR/scp.log" 2>&1; then
  tail -n 10 "$REPORT_DIR/scp.log" >&2
  fail "scp to VM failed — see ${REPORT_DIR/scp.log}"
fi

# Explicit copy of the active test config (may be generated outside the repo)
readonly TEST_CONFIG_REMOTE="/tmp/test-config.yml"
scp "${SSH_OPTS[@]}" "$CONFIG" "${VM_USER}@${VM_IP}:${TEST_CONFIG_REMOTE}" \
  > /dev/null 2>&1 || fail "cannot copy test config to VM"

# ---------------------------------------------------------------------------
# Step 3 — run the tests on the VM
# ---------------------------------------------------------------------------

log "Bootstrapping test prerequisites on the VM (yq, jq)"
if ! remote_ssh "sudo apt-get update -qq && sudo apt-get install -y -qq yq jq" \
      > "$REPORT_DIR/bootstrap.log" 2>&1; then
  tail -n 10 "$REPORT_DIR/bootstrap.log" >&2
  fail "VM bootstrap failed — see ${REPORT_DIR/bootstrap.log}"
fi

log "Running test suite on the VM (timeout ${TIMEOUT_MIN}m per script)"
TEST_RC=0
if ! scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/remote/run-tests.sh" \
      "${VM_USER}@${VM_IP}:/tmp/run-tests.sh" > /dev/null 2>&1; then
  fail "cannot copy run-tests.sh to VM"
fi
remote_ssh "bash /tmp/run-tests.sh \
    --config '${TEST_CONFIG_REMOTE}' \
    --workdir '${REMOTE_DIR}' \
    --out '/tmp/vmtest' \
    --timeout '${TIMEOUT_MIN}'" \
  > "$REPORT_DIR/runner.log" 2>&1 || TEST_RC=$?
# Distinguish "tests failed" (1) from pipeline/SSH errors (anything else)
if (( TEST_RC > 1 )); then
  TEST_RC=1
fi

# ---------------------------------------------------------------------------
# Step 4 — fetch test artifacts
# ---------------------------------------------------------------------------

if scp "${SSH_OPTS[@]}" -r "${VM_USER}@${VM_IP}:/tmp/vmtest" "${REPORT_DIR}/vmtest" \
      > /dev/null 2>&1; then
  log "Test artifacts fetched to ${REPORT_DIR}/vmtest"
else
  echo "[VM-TEST][WARN] could not fetch test artifacts (VM may be down)" >&2
  mkdir -p "$REPORT_DIR/vmtest/logs"
  : > "$REPORT_DIR/vmtest/results.jsonl"
fi

# ---------------------------------------------------------------------------
# Step 5 — write the report
# ---------------------------------------------------------------------------

write_report() {
  local results="${REPORT_DIR}/vmtest/results.jsonl"
  local meta="${REPORT_DIR}/vmtest/meta.json"
  local report="${REPORT_DIR}/report.md"
  local commit
  commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  local guest_os="n/a" guest_host="n/a" guest_kernel="n/a"
  if [[ -f "$meta" ]]; then
    guest_os="$(jq -r '.os // "n/a"' "$meta")"
    guest_host="$(jq -r '.hostname // "n/a"' "$meta")"
    guest_kernel="$(jq -r '.kernel // "n/a"' "$meta")"
  fi

  # Collect all test scripts (config order), plus the precheck pseudo-entry
  local -a all_scripts=()
  if [[ -s "$results" ]]; then
    mapfile -t all_scripts < <(jq -rs '[.[] | select(.phase != "precheck") | .script] | unique | .[]' "$results")
  fi
  # Preserve config order when possible
  local -a ordered=()
  local s
  if command -v yq &>/dev/null; then
    while IFS= read -r s; do
      [[ -n "$s" ]] && ordered+=("$s")
    done < <(yq -r '.scripts | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG" 2>/dev/null)
  fi
  if (( ${#ordered[@]} > 0 )); then
    # Append any script present in results but missing from config order
    for s in "${all_scripts[@]}"; do
      local found=0
      for o in "${ordered[@]}"; do
        if [[ "$o" == "$s" ]]; then found=1; break; fi
      done
      (( found )) || ordered+=("$s")
    done
  else
    ordered=("${all_scripts[@]}")
  fi

  {
    echo "# VM Integration Test Report"
    echo
    echo "- **Date:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "- **Host:** $(hostname)"
    echo "- **Repo commit:** ${commit}"
    echo "- **VM:** \`${VM_NAME}\` (${RELEASE}, ${RAM} GiB RAM, ${VCPUS} vCPU, ${DISK} GiB disk)"
    echo "- **VM IP:** ${VM_IP:-n/a}"
    echo "- **Guest OS:** ${guest_os} (kernel ${guest_kernel}, hostname ${guest_host})"
    echo "- **Test config:** ${CONFIG}"
    echo "- **Per-script timeout:** ${TIMEOUT_MIN}m"
    echo
    echo "## Results"
    echo
    echo "| Script | Integration | Idempotency |"
    echo "|---|---|---|"

    local -a failed=()
    local total=0
    for s in "${ordered[@]}"; do
      local cell1="—" cell2="—"
      local line
      while IFS= read -r line; do
        local phase rc dur
        phase="$(jq -r '.phase' <<< "$line")"
        rc="$(jq -r '.rc' <<< "$line")"
        dur="$(jq -r '.duration_s' <<< "$line")"
        local cell
        if (( rc == 0 )); then
          cell="PASS (${dur}s)"
        elif (( rc == 124 )); then
          cell="TIMEOUT (${TIMEOUT_MIN}m)"
        else
          cell="FAIL (rc=${rc}, ${dur}s)"
        fi
        if [[ "$phase" == "integration" ]]; then cell1="$cell"; else cell2="$cell"; fi
        (( total++ ))
        (( rc == 0 )) || failed+=("$s ($phase, rc=$rc)")
      done < <(jq -c --arg s "$s" 'select(.script == $s)' "$results")
      echo "| \`${s}\` | ${cell1} | ${cell2} |"
    done

    # Precheck line
    local pre_line
    pre_line="$(jq -c 'select(.phase == "precheck")' "$results" | head -n1)"
    if [[ -n "$pre_line" ]]; then
      local pre_rc
      pre_rc="$(jq -r '.rc' <<< "$pre_line")"
      (( total++ ))
      if (( pre_rc == 0 )); then
        echo
        echo "Precheck: \`run-setup.sh status\` — PASS"
      else
        echo
        echo "Precheck: \`run-setup.sh status\` — FAIL (rc=${pre_rc})"
        failed+=("run-setup.sh status (precheck, rc=$pre_rc)")
      fi
    fi

    echo
    echo "## Verdict"
    echo
    if (( ${#failed[@]} == 0 )) && (( total > 0 )); then
      echo "**PASS** — all ${total} test cases succeeded (integration + idempotency)."
    else
      echo "**FAIL** — ${#failed[@]} of ${total} test cases failed:"
      for f in "${failed[@]}"; do
        echo "  - \`${f}\`"
      done
    fi
    echo
    echo "## Artifacts"
    echo
    echo "- [create.json](create.json) — VM creation output (virt-runner create --json)"
    echo "- [runner.log](runner.log) — remote test runner console output"
    echo "- [results.jsonl](vmtest/results.jsonl) — machine-readable results"
    echo "- [meta.json](vmtest/meta.json) — guest VM metadata"
    echo "- [vmtest/logs/](vmtest/logs/) — per-script logs"
    (( KEEP_VM )) || echo "- [destroy.json](destroy.json) — VM teardown output (virt-runner destroy --json)"
  } > "$report"

  log "Report written: ${report}"
}

write_report

# ---------------------------------------------------------------------------
# Summary to stdout
# ---------------------------------------------------------------------------

RESULTS="${REPORT_DIR}/vmtest/results.jsonl"
echo
if [[ -s "$RESULTS" ]]; then
  pass_count="$(jq -s '[.[] | select(.rc == 0)] | length' "$RESULTS")"
  total_count="$(jq -s 'length' "$RESULTS")"
  echo "=============================================="
  if (( pass_count == total_count )); then
    echo "VM TEST SUITE: PASS (${pass_count}/${total_count} test cases)"
  else
    echo "VM TEST SUITE: FAIL (${pass_count}/${total_count} test cases passed)"
    echo "Failed cases:"
    jq -rs '.[] | select(.rc != 0) | "  - \(.script) [\(.phase)] rc=\(.rc)"' "$RESULTS"
  fi
  echo "Report:  ${REPORT_DIR}/report.md"
  echo "=============================================="
else
  echo "VM TEST SUITE: FAIL (no test results — pipeline problem)"
  echo "See: ${REPORT_DIR}/runner.log"
fi

if (( KEEP_VM )) && (( VM_CREATED )); then
  echo "(VM kept for debugging: ${VM_NAME})"
fi

exit "$TEST_RC"
