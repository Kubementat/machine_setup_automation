# Plan: `tasks/setup-agent-sandbox.sh` — bwrap sandbox prerequisites + `asb` wrapper

Date: 2026-09-22 (revised draft for review — not yet implemented)
Source: `~/vault/research/agent-sandbox-bwrap-minimal-implementation-2026-09-22.md`

## Goal

New task script `tasks/setup-agent-sandbox.sh` that configures the **bwrap
sandboxing prerequisites** on the host, so sandboxed agent runs (pi, opencode, …)
work out of the box on Ubuntu 24.04+:

1. `bubblewrap` (bwrap) installed via apt (no `socat` for now — v2 egress proxy only).
2. AppArmor "unprivileged userns" restriction lifted **for bwrap only** via a one-file
   AppArmor profile (research doc §2, Option A — the profile the Claude Code docs prescribe).
3. Hard **smoke-test verification** that bwrap actually works (bounded, non-zero exit on failure).
4. The **`asb` wrapper** (research doc §3.1 + herdr deltas D1–D3) installed to
   `/usr/local/bin/asb`, so `asb pi …` / `asb opencode …` work from any shell (incl. herdr panes).

Out of scope (deliberate, per research doc §3/§3.4): egress allowlist proxy (v2),
seccomp, Landlock, dotfile masking (v1.5), audit log, herdr server-side
`HERDR_PROCESS_DETECTION` tuning. All listed as follow-ups below.

## Decisions (refined 2026-09-22)

| # | Decision |
|---|---|
| 1 | **Separate task** `tasks/setup-agent-sandbox.sh`, not merged into `setup-pi.sh`. `setup-pi.sh` stays untouched; the sandbox task is independent and reusable for all agents. |
| 2 | **No `socat`** install for now (only needed for the v2 egress proxy). |
| 3 | **`asb` wrapper included**, installed to **`/usr/local/bin/asb`** (root-owned, `sudo install -m 755`). |
| 4 | **Hard error** when the bwrap smoke test fails (non-zero exit, actionable hint). |
| 5 | **VM test suite**: add `setup-agent-sandbox` to `tests/machine-config.test.yml`. |

## Design

### Task script structure

```
step "Setting up agent sandbox (bwrap)"
  1. ensure apt packages            (idempotent)
  2. install AppArmor profile       (only if AppArmor is active on the host)
  3. smoke-test bwrap               (hard failure on error)
  4. install asb wrapper            (template → /usr/local/bin/asb)
  5. smoke-test asb                 (hard failure on error)
```

### 1. Package install

- Existing lib helper `is_apt_package_installed` + `sudo apt install -y`
  (same pattern as `setup-basics.sh`).
- Default package list: `bubblewrap` — overridable via `SANDBOX_APT_PACKAGES`.

### 2. AppArmor profile

- Profile as static template file `templates/agent-sandbox/bwrap-apparmor`
  (repo convention: no inline templates). Static file (no variables → plain copy,
  `sudo install -m 644`), content per research doc Option A:

  ```
  abi <abi/4.0>,
  include <tunables/global>

  profile bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,
    include if exists <local/bwrap>
  }
  ```

- **Gate on AppArmor:** if the `apparmor` service is not active → `info`
  "AppArmor not active — bwrap works unprivileged, skipping profile" and skip.
  (The sysctl restriction only exists with AppArmor enforcing, e.g. Ubuntu 24.04+;
  VMs without the kernel module and other distros don't need the profile.
  The step-3 smoke test is the real gate in all cases.)
- **Idempotency:** `diff` rendered template against installed `/etc/apparmor.d/bwrap`;
  only on change → install + `sudo apparmor_parser -r` (reload that one profile,
  no full daemon reload, no service restart).
- Render to `mktemp` as invoking user, install with `sudo install -m 644`
  (profile is not a secret — no `.env` involved).

### 3. bwrap smoke test (hard verification)

- Exactly the command from research doc §2, under `timeout ${BWRAP_VERIFY_TIMEOUT}`:

  ```
  bwrap --ro-bind / / --dev /dev --proc /proc \
        --unshare-pid --unshare-uts --unshare-ipc --die-with-parent \
        sh -c 'echo sandbox OK'
  ```

  Asserting output contains `sandbox OK`.
- On failure: `error` (non-zero exit) with actionable hint:
  *"bwrap userns blocked — on Ubuntu 24.04+ check the AppArmor profile
  `/etc/apparmor.d/bwrap` and run `sudo apparmor_parser -r`; for one-off testing:
  `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (stopgap, not the target state)."*

### 4. `asb` wrapper (research doc §3.1 + §3.3 deltas D1–D3)

- Template: `templates/agent-sandbox/asb` (static — no variables, plain copy via
  `sudo install -m 755` to `/usr/local/bin/asb`). Diff-before-install for convergent
  re-runs (same pattern as the AppArmor profile).

- **Scope (v1):**
  - Usage: `asb pi [workspace] [args…]` / `asb opencode [workspace] [args…]`,
    plus `--env KEY=VALUE` passthrough for extra task-scoped vars and `--help`.
  - bwrap argv per research doc §3.1 contract:
    - ro-bind: `/usr /lib /lib64 /bin /sbin`, per-file `/etc` (resolv.conf, hosts,
      passwd, group, /etc/ssl), `--proc`, `--dev`, `--tmpfs /tmp`
    - Agent state ro: `$HOME/.pi`, `$HOME/.config/opencode`,
      `$HOME/.local/share/opencode`, `$HOME/.local/bin`
    - `--bind` the workspace (only general writable path), defaulting to `$PWD`
    - **Herdr deltas (D1–D3):** bind `~/.config/herdr/herdr.sock` (bind-try, rw);
      forward **all `HERDR_*`** env vars into the sandbox; `asb` exports
      `HERDR_AGENT=<kind>` on itself (host side) before exec'ing bwrap
    - Namespaces: `--unshare-uts --unshare-ipc` only — **no** `--unshare-pid`,
      **no** `--new-session` (D4: keeps herdr foreground detection + Ctrl-C working)
    - Lifecycle: `--die-with-parent`; env: `--clearenv` + explicit allowlist
      (`HOME`, `PATH`, `TERM`, `LANG/LC_*`, `HERDR_*`, user `--env` vars)
  - `--help` documents usage and the current guarantees/limits.
  - Missing optional mounts (e.g. no herdr socket, no opencode state) → skip the
    bind (bwrap `--bind-try`), not an error.

- **Deliberately not in v1** (follow-ups, research doc §3.4 / build-order steps 6/7):
  dotfile/dotdir masking in the workspace (GhostApproval class), audit log
  (`~/.local/state/agent-sandbox/audit.log`), herdr pane template.

### 5. asb smoke test (hard verification)

- Run `asb pi --help` (no sandbox needed for help) **and** a real sandboxed
  one-shot: `asb sh -- echo sandboxed-asb OK` style check if `asb` supports a
  bare-shell target, else `timeout 30 asb pi -p 'reply with: sandboxed asb OK'`
  is too heavy for a setup test → use the lighter check:
  `bwrap`-equivalent invocation produced by `asb --debug argv` (print-only mode)
  + one `asb` execution of `sh -c 'echo sandboxed-asb OK'` if a shell agent is
  included. *(Refinement note: final exact check chosen during implementation;
  the requirement is "at least one real sandboxed process executed via asb and
  exit 0".)*

### Configuration (env vars, all optional)

| Var | Default | Meaning |
|---|---|---|
| `SANDBOX_APT_PACKAGES` | `bubblewrap` | Space/comma-separated apt packages for the sandbox step |
| `BWRAP_VERIFY_TIMEOUT` | `15` | Seconds allowed for the bwrap smoke test |

`--help` documents the whole flow + both variables.

## Files touched / added

| File | Change |
|---|---|
| `tasks/setup-agent-sandbox.sh` | **new** task script (shellcheck-clean, `--help`, idempotent) |
| `templates/agent-sandbox/bwrap-apparmor` | **new** static AppArmor profile |
| `templates/agent-sandbox/asb` | **new** asb wrapper (v1 scope above) |
| `AUTOMATIONS.md` | **new** entry for `setup-agent-sandbox.sh` |
| `tests/machine-config.test.yml` | add `setup-agent-sandbox` (after `setup-basics`) |
| `docs/plans/…` | this plan |

`tasks/setup-pi.sh`: **unchanged**.

## Testing (VM suite — decision 5)

- Add `setup-agent-sandbox` to `tests/machine-config.test.yml` → suite gives
  precheck + integration (clean VM) + idempotency (second run) automatically.
- Expected on the default test VM: apt install works; AppArmor profile path
  taken when AppArmor is active in the VM, else the documented skip path; smoke
  tests pass in both cases.
- Run `tests/run-vm-tests.sh` (full or `--scripts setup-agent-sandbox`) before merge.
- Additionally manual sanity on this dev host (bwrap installed but currently
  blocked — verifies the AppArmor profile actually unblocks it).

## Repo conventions followed

- Idempotent, converging re-runs (package skip, diff-gated profile & asb installs,
  re-runnable smoke tests).
- Templates in `templates/agent-sandbox/`, not inline in the script.
- `--help` kept up to date; config via env vars with defaults.
- `shellcheck` on the new script (and `asb` template, which is bash).
- `AUTOMATIONS.md` updated.
- Feature branch via `git worktree`, merge to `develop` per workflow.
- Karpathy guidelines: standalone addition, no changes to existing scripts.

## Follow-ups (not part of this change)

1. `asb` dotfile masking (v1.5) + audit log (research doc build order step 6).
2. v2 egress allowlist proxy (`socat`/tinyproxy, `--unshare-net`) — research doc §3.2.
3. Herdr hardening: socket shim allowing only `report-agent` (research doc §3.3).
4. `herdr integration install pi` (v6 → v8 state extension) — separate manual step,
   candidate for `setup-pi.sh` or the herdr task.
5. Revisit `--unshare-pid` in v2 once `HERDR_PROCESS_DETECTION=child-groups` is
   proven on this host.
