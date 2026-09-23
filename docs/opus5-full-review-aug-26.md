# Full Code Review — kwisatz

**Reviewer:** Claude Opus 5
**Date:** 2026-08-02
**Commit:** `dd783aa` (branch `main`)
**Scope:** `run-setup.sh`, `lib/helpers.sh`, all 32 scripts in `tasks/`, `utilities/`, `templates/`, `machine-config.yml{,.example}`, `AGENTS.md`, `README*.md`

---

## 1. Executive summary

The repository is a bash-based machine provisioning system: a YAML-driven orchestrator (`run-setup.sh`)
dispatches to independent, idempotent task scripts (`tasks/*.sh`) that install host software or generate
Docker Compose stacks under `/srv/<service>`. The code is unusually disciplined for a shell codebase —
consistent headers, `set -euo pipefail` in all 32 task scripts, a shared helper library, guarded
re-sourcing, and a **clean baseline `shellcheck` run (0 warnings, 0 errors, 5 informational notes)**.

The problems are not style problems. They are in three areas:

1. **The orchestrator's execution model does not match what the task scripts need.** There is no
   dependency ordering (execution is alphabetical) and no non-interactive mode, yet 9 scripts hard-require
   Traefik to already be running and 14 scripts block on `read -rp` prompts. `./run-setup.sh apply` with a
   realistic selection of services cannot complete unattended.
2. **Three confirmed functional bugs** that silently produce broken configuration or a guaranteed
   non-zero exit — most severely `setup-fail2ban.sh`, which writes a jail file with every value blanked.
3. **Remote-lockout risk** in the SSH/firewall scripts, which is the highest-consequence category here
   given the target is a remote Ubuntu server.

Severity counts: **3 High**, **7 Medium**, **9 Low**, plus consistency/documentation observations.

### Verification performed

| Check | Result |
|---|---|
| `shellcheck` (default) on all shell files | 5 notes, no warnings/errors |
| `shellcheck -o all` (optional checks) | 57 warnings, 880 notes (mostly `SC2312`/`SC2248` pedantry) |
| `yamllint` on configs + templates | 4 warnings in configs, 5 issues in `templates/concourse/` |
| `./run-setup.sh status` executed end-to-end | Runs; output defect found (see M-6) |
| Config keys ↔ task scripts cross-check | 2 mismatches found (M-5) |
| `envsubst` export semantics reproduced in shell | Confirms H-2 |

---

## 2. Architecture assessment

**What works well.** The separation is genuinely good: `run-setup.sh` knows nothing about individual
services, task scripts know nothing about the orchestrator, and each task script is independently runnable
with plain environment variables. That property is worth protecting — it is why the scripts are testable at
all. `lib/helpers.sh` guards every definition (`if ! declare -F name`), so re-sourcing and user overrides
are safe. Secret material is consistently generated with `openssl rand` and written to `.env` files at mode
`600` rather than being embedded in compose files. Idempotency is taken seriously — nearly every script
checks for its own prior state before acting.

**The structural gap.** The orchestrator models "which scripts to run" but not "in what order". It
discovers scripts from disk with `discover_scripts | sort` (`run-setup.sh:88-105`) and executes in that
order. Meanwhile the task layer has a real dependency graph encoded implicitly in `lib/helpers.sh`
(`ensure_proxy_network`, `ensure_traefik_running`) that the orchestrator cannot see. This is the root cause
of H-1 and it is the single most valuable thing to fix.

**Convention drift.** `AGENTS.md:60-62` mandates that templating live in `templates/<component>/`. Of the
12 scripts that generate compose files, only 3 use `templates/` (omnigent, hermes, nanobot); the other 9
inline multi-hundred-line heredocs. `setup-traefik.sh` is 59 KB and `setup-omnigent.sh` is 41 KB largely
because of this. The convention is right; the codebase has drifted from it.

---

## 3. High severity

### H-1 — `apply` cannot install Traefik-dependent services: alphabetical ordering guarantees failure

**Files:** `run-setup.sh:88-105`, `run-setup.sh:368-402`; `lib/helpers.sh:95-123`

Nine scripts call `ensure_proxy_network` / `ensure_traefik_running`, both of which `exit 1` when Traefik is
absent:

```
setup-concourse.sh  setup-excalidraw.sh  setup-forgejo.sh   setup-nextcloud.sh  setup-omnigent.sh
setup-opencode-server.sh  setup-openwebui.sh  setup-planka.sh  setup-vllm.sh
```

`setup-traefik` sorts **after** every one of them. Executing:

```
$ printf '%s\n' setup-traefik setup-forgejo setup-openwebui | sort
setup-forgejo
setup-openwebui
setup-traefik
```

**Failure scenario:** a user enables `setup-traefik` and `setup-forgejo` in `machine-config.yml` and runs
`./run-setup.sh apply`. `setup-forgejo.sh` runs first, `ensure_proxy_network` finds no `proxy` network and
exits 1. The orchestrator records a failure and continues; Traefik is then installed. The user must run
`apply` a second time. With `setup-docker` also enabled the first run is worse — every Docker service fails
before Docker exists (`setup-docker` sorts before `setup-forgejo` but after `configure-firewall`, so it is
partially lucky, not correct).

The README overstates the current behaviour at line 48: *"runs them in order"*. There is no ordering
concept in the code.

**Recommendation:** add an optional `after: [<script>, ...]` key per script in `machine-config.yml` and
topologically sort in `run-setup.sh`; fall back to alphabetical when absent. A cheaper stopgap: a hardcoded
priority list (`setup-basics`, `setup-docker`, `setup-traefik` first).

---

### H-2 — `setup-fail2ban.sh` writes a jail file with all values blank

**File:** `tasks/setup-fail2ban.sh:42-45, 156-158`

```bash
: "${FAIL2BAN_SSHD_PORT:=${SSHD_PORT:-2224}}"     # assigned, never exported
...
sudo envsubst '${FAIL2BAN_SSHD_PORT} ${FAIL2BAN_MAXRETRY} ...' \
  < "${TEMPLATE_DIR}/jail.local" | sudo tee "${JAIL_LOCAL}" > /dev/null
```

`:=` assigns a **shell** variable, not an environment variable. `envsubst` reads the environment only, and
`sudo` additionally scrubs the environment by default. Reproduced directly:

```
$ bash -c ': "${FOO:=bar}"; envsubst "\${FOO}" <<< "val=\${FOO}"'
val=
```

**Failure scenario:** `/etc/fail2ban/jail.local` is written as

```ini
[sshd]
enabled = true
port = ,ssh
maxretry =
bantime =
findtime =
```

`fail2ban-client reload` then either errors on the empty values or falls back to defaults, and the custom
SSH port (2224) is **not monitored at all** — which is the entire point of the script. The script
nonetheless prints `success "fail2ban configured"`, because the `|| systemctl restart` on line 163 swallows
the reload failure.

This is an isolated defect, not a systemic one: `setup-llama-swap.sh:325` and `:341` and
`setup-whispering.sh:124` all export correctly. Sibling scripts show the intended pattern.

**Fix:** `export FAIL2BAN_SSHD_PORT FAIL2BAN_MAXRETRY FAIL2BAN_BANTIME FAIL2BAN_FINDTIME GENERATED_DATE`
before the call, and drop `sudo` from `envsubst` (only `tee` needs it) — exactly as `setup-llama-swap.sh`
does.

---

### H-3 — Remote SSH lockout risk across the SSH/firewall trio

Three independent contributors, all in scripts that run against a remote server:

**(a) `configure-firewall.sh` is `enabled: true` by default** (`machine-config.yml:5-9`) and never opens
port 22. It allows `${SSHD_PORT}` (default **2224**) then calls `ufw_enable` → `ufw --force enable`
(`lib/helpers.sh:212-222`), which applies default-deny inbound.

*Failure scenario:* user clones the repo onto a fresh Ubuntu box, connects over SSH on the standard port
22, runs `./run-setup.sh apply` with the shipped defaults. UFW comes up denying 22. The session is
terminated and the box is unreachable. The header comment at lines 12-13 warns about this, but a warning in
a comment does not protect a default-enabled script.

**(b) `setup-sshd.sh` restarts sshd without validating the config** (`tasks/setup-sshd.sh:59-75`). It
appends directives with `tee -a` and immediately runs `systemctl restart ssh`. There is no `sshd -t`, and
no backup of `/etc/ssh/sshd_config`. `setup-ssh-tunnel-user.sh:126` gets this right — it validates before
restarting. `setup-sshd.sh` should do the same.

**(c) Appending to `sshd_config` is order-fragile.** `setup-sshd.sh` appends global keywords
(`Port`, `PasswordAuthentication`) to the **end** of the file, while `setup-ssh-tunnel-user.sh:118` appends
a `Match User` block to the same place. In OpenSSH every keyword after a `Match` belongs to that block, and
`Port` is **not permitted** inside one. Under the current glibc collation `setup-sshd` happens to sort
before `setup-ssh-tunnel-user`, so the accident is avoided; under `LC_ALL=C` the order reverses
(`-` = 0x2D < `d` = 0x64) and `sshd -t` fails, taking SSH down with it on the next restart.

There is a second correctness issue in (c) independent of ordering: on Ubuntu, `sshd_config` begins with
`Include /etc/ssh/sshd_config.d/*.conf`, and sshd honours the **first** occurrence of most keywords. A
cloud-init drop-in setting `PasswordAuthentication yes` wins over the appended `PasswordAuthentication no`,
so the hardening silently does not apply.

**Recommendation:** write to `/etc/ssh/sshd_config.d/60-machine-setup.conf` instead of appending; run
`sshd -t` before every restart; back up the original; and either default `configure-firewall` to
`enabled: false` or have it detect the live SSH port (`ss -tlnp` / `sshd -T | grep ^port`) and allow it
before enabling UFW.

---

## 4. Medium severity

### M-4 — `setup-docker.sh` exits non-zero on a successful first install

**File:** `tasks/setup-docker.sh:127-138`

```bash
sudo usermod -aG docker "${USER}"
if id -nG | grep -q docker; then ... else newgrp docker >/dev/null 2>&1 || true; fi
...
docker run hello-world
```

`usermod -aG` does not affect the current process's group set, and `newgrp` in a non-interactive script
starts a subshell that immediately exits — it is a no-op here. So on a first install `docker run
hello-world` runs without docker-group membership, fails with `permission denied on
/var/run/docker.sock`, and `set -e` aborts the script with a non-zero exit.

**Failure scenario:** first-ever `apply` on a clean machine. Docker is fully installed and working, but the
orchestrator reports `Failed: setup-docker.sh` and every Docker-dependent script that follows also fails.
The final message at line 142 ("You may need to log out and back in") is printed only on the path that is
never reached.

**Fix:** run the smoke test as `sudo docker run hello-world`, or guard it with
`if docker info &>/dev/null; then ... else warn "re-login required"; fi`.

---

### M-5 — `machine-config.yml` and `tasks/` have drifted apart in both directions

Cross-check of config keys against scripts on disk:

| Key | Status |
|---|---|
| `setup-obsidian-livesync` | in **both** `machine-config.yml` and `.example`; **no script exists** |
| `setup-omnigent` | script exists, in `.example`; **missing from `machine-config.yml`** |

Two consequences:

- `setup-obsidian-livesync` is unreachable. Because `cmd_apply` iterates over scripts found **on disk**
  (`run-setup.sh:384`), a config-only entry is never visited — so the "Configured script not found"
  branch at lines 388-392 is **dead code** and `skipped_count` can never be incremented. If the user
  enables it, `enabled_count` (computed from config, line 359) exceeds the number of scripts actually run,
  and the summary at line 410 silently under-reports: `success_count = enabled - failed - skipped` yields a
  number lower than reality with no explanation.
- `setup-omnigent` cannot be enabled via the live config at all without hand-editing.

**Fix:** delete the `setup-obsidian-livesync` entry (or add the script), add `setup-omnigent` to
`machine-config.yml`, and add a config↔disk consistency check to `cmd_status`.

---

### M-6 — `status` prints literal `\n` instead of indenting env vars and args

**File:** `run-setup.sh:280, 288`

```bash
echo "${env_vars//$'\n'/\n      }"
```

The replacement text `\n` is a two-character literal, and `echo` without `-e` does not interpret it.
Reproduced in the live run of `./run-setup.sh status`: multi-value `env:` blocks render as
`LLAMA_SWAP_PORT=9292\n      LLAMA_SWAP_DIR=/srv/llama-swap` on one line. Use
`sed 's/^/      /' <<< "$env_vars"` or a `while read` loop.

---

### M-7 — `setup-n8n.sh` generates a stack whose Postgres and Traefik wiring are both non-functional

**File:** `tasks/setup-n8n.sh:70-170`

Four defects in one generated compose file:

1. **Hardcoded credential:** `POSTGRES_PASSWORD=changeme` (line 152), written into the compose file
   itself, not overridable — the only script in the repo that does this. Compare `setup-nextcloud.sh:103`
   which generates a random password.
2. **The database is never used.** No `DB_TYPE=postgresdb` / `DB_POSTGRESDB_*` variables are set on the
   n8n service (`grep DB_TYPE` returns nothing), so n8n silently falls back to SQLite. The Postgres
   container runs, consumes resources, and holds no data.
3. **The `proxy` network is declared but attached to nothing.** Lines 164-167 emit
   `networks: proxy: {external: true}`, but neither service has a `networks:` key — so the
   `traefik.docker.network=proxy` label on line 82 points at a network the container is not on, and
   routing cannot work.
4. **A second Traefik instance** (line 100) binds `:80`/`:443` and sets `--api.insecure=true`, exposing
   the unauthenticated Traefik API. This directly conflicts with the repo's own `setup-traefik.sh`, which
   is the documented reverse proxy (`AGENTS.md:21`). If both are deployed the second `docker compose up`
   fails on port binding.

This script appears not to have been exercised end-to-end. It needs a rewrite against the
`setup-forgejo.sh` / `setup-openwebui.sh` pattern that `AGENTS.md:22` names as the reference integration.

---

### M-8 — 14 scripts block on interactive prompts under unattended `apply`

`read -rp` appears in `setup-concourse.sh` (×4), `setup-excalidraw.sh` (×4), `setup-traefik.sh` (×2),
`setup-llama-swap.sh` (×2), `setup-planka.sh` (×3), `setup-forgejo.sh` (×2), `setup-upstream-kernel.sh`
(×2), `setup-nextcloud.sh`, `setup-omnigent.sh`, `setup-openwebui.sh`. `setup-samba.sh:138` additionally
calls `sudo smbpasswd -a`, which is unconditionally interactive.

`run_script` (`run-setup.sh:303-340`) passes stdin straight through and supplies no `--yes`/`--force`
signal. Two failure modes:

- **With a TTY:** `apply` stops and waits, defeating the purpose of a batch runner.
- **Without a TTY** (cron, `ssh host './run-setup.sh apply'`, CI): `read` hits EOF and returns non-zero;
  under `set -euo pipefail` the script aborts mid-provision, potentially after partial changes.

**Fix:** a repo-wide `ASSUME_YES`/`NONINTERACTIVE` convention — `if [[ -t 0 && "${ASSUME_YES:-false}" != true ]]; then read -rp ...; else answer=N; fi` — with `run-setup.sh` exporting it during `apply`.

---

### M-9 — Secrets are written before the file is locked down

**Files:** `tasks/setup-omnigent.sh:285-348`, `tasks/setup-openwebui.sh:217-222`,
`tasks/setup-opencode-server.sh:256-270`, `tasks/setup-traefik.sh:1002-1008`

The pattern throughout is `touch`/`cat >` the file, write the secrets, **then** `chmod 600`. Between those
two steps the file carries the default umask mode (0644 typically), so any local user can read the
generated Postgres password, cookie secrets, and admin password. `setup-omnigent.sh` is the widest window —
lines 285 through 348 include ~10 subprocess spawns (`openssl`, `awk`, `mv`) with the file world-readable
throughout.

Since `set_or_replace_kv` writes to `${ENV_FILE}.tmp` and `mv`s it into place, the temp file has the same
exposure.

**Fix:** `touch "$ENV_FILE" && chmod 600 "$ENV_FILE"` before writing anything, and set
`umask 077` at the top of the secret-generation section so the `.tmp` files inherit it.

---

### M-10 — `setup-opencode-server.sh` puts a password in a systemd unit file

**File:** `tasks/setup-opencode-server.sh:427`

```
Environment="OPENCODE_SERVER_PASSWORD=$OPENCODE_SERVER_PASSWORD"
```

Unit files under `/etc/systemd/system/` are mode 0644 by convention, and the value is additionally exposed
to every local user via `systemctl show <unit>`. The script already writes a mode-600 `.env` at line 270 —
it should use `EnvironmentFile=` pointing at that file instead.

---

## 5. Low severity

**L-11 — `run-setup.sh` colours are permanently disabled.** `readonly RED="${RED:-}"` etc.
(`run-setup.sh:35-40`) default to empty and the script never sources `lib/helpers.sh`, so no colour is ever
set — while `printf '%b'` still emits the empty-arg padding. All the `${GREEN}`/`${RESET}` interpolation
through the file is inert. Either source the helpers or drop the variables.

**L-12 — Doubled `[ERROR]` prefix on unknown subcommand.** `run-setup.sh:515` prints
`printf '%b %b %b %s\n' "${RED}[ERROR]${RESET}" "${RED}[ERROR]${RESET}" ...` — the first argument is
duplicated. Should be `log_error "Unknown subcommand: $subcommand"`.

**L-13 — `--config` is only accepted before the subcommand.** `main` (`run-setup.sh:472-486`) breaks out of
option parsing at the first non-option token, so `./run-setup.sh apply --config foo.yml` silently ignores
the flag and passes it to `cmd_apply` as an unused positional. The help text at line 455 only documents the
working form, but the asymmetry will surprise users. Also `-h`/`--help` are handled only in the subcommand
position, not as options.

**L-14 — `apply` exits silently when nothing is enabled.** `run-setup.sh:361-363` does a bare `exit 0` with
no message. A user who forgot to flip an `enabled:` flag gets no feedback at all.

**L-15 — `discover_scripts`'s failure fallback is unreachable.** The `|| { log_warn ...; yq keys ... }`
blocks at lines 213 and 372 can never fire: `TASKS_DIR` existence is already enforced by
`check_dependencies`, and the subshell's only other failure path (`cd`) is dominated by it. Dead code.

**L-16 — `validate_port` has unreachable `exit 1`.** `configure-firewall.sh:50-57` calls `error`, which
already exits (`lib/helpers.sh:54`). Harmless, but it suggests uncertainty about the helper's contract —
worth a comment in `helpers.sh` that `error` terminates.

**L-17 — Three declared ports in `configure-firewall.sh` are dead configuration.** `OPENWEBUI_PORT`,
`KUBERNETES_API_PORT`, `GNOME_REMOTE_PORT` are defaulted (lines 42-44) and **printed as "Current
configuration"** (lines 74-76), but their rules are commented out (lines 99-104). The script reports
configuration it does not apply.

**L-18 — Container images are largely unpinned.** `concourse/concourse:latest`,
`ghcr.io/anomalyco/opencode:latest`, `ghcr.io/open-webui/open-webui:main`,
`nousresearch/hermes-agent:latest`, `ghcr.io/tecnativa/docker-socket-proxy:latest`,
`docker.n8n.io/n8nio/n8n` (implicit `:latest`), `traefik` (implicit `:latest`), `nanobot-extended` (no
tag). This undercuts the reproducibility the YAML-config design is aiming for; a rebuild months apart
produces different stacks. `setup-planka.sh`, `setup-vllm.sh`, `setup-forgejo.sh`, and the omnigent
templates get this right with a `${..._IMAGE}` variable — extend that pattern.

**L-19 — `export $(grep -v '^#' .env | xargs)` is fragile.** `setup-openwebui.sh:335` (inside the generated
`start_openwebui.sh`). `xargs` performs quote and backslash processing, and unquoted `$(...)` word-splits,
so any value containing a space, quote, or `#` corrupts the environment. Generated hex keys survive;
user-supplied `WEBUI_SECRET_KEY` values may not. Use `set -a; . ./.env; set +a`.

**L-20 — `setup-neovim.sh` is the only task script that does not source `lib/helpers.sh`,** and
`setup-hermes.sh:1` is the only one using `#!/bin/bash` rather than `#!/usr/bin/env bash`. Both are
one-line consistency fixes.

---

## 6. Linting and tooling

**Baseline `shellcheck` is clean** — that is a real achievement for ~350 KB of shell and reflects the
`AGENTS.md:33-38` linting policy being followed. The 5 remaining notes are all defensible:

| Location | Note |
|---|---|
| `setup-fail2ban.sh:104` | SC1091 — sourcing `/etc/os-release` (unavoidable) |
| `setup-fail2ban.sh:157` | SC2024 — `sudo` doesn't affect redirects (**real**, and related to H-2) |
| `setup-planka.sh:319,329` | SC2015 — `A && B \|\| C` is not if-then-else |
| `utilities/ssh-port-forward.sh:42` | SC2181 — checking `$?` indirectly |

`yamllint` findings are cosmetic except `templates/concourse/hello-world-pipeline.yml`, which has 3 errors
including a missing trailing newline. `machine-config.yml` is missing the `---` document start that
`.example` has.

**Undocumented hard dependency on a specific `yq`.** `run-setup.sh` uses `yq --arg name ... '.scripts[$name]'`
(lines 117, 129, 143, 157) — `--arg` and jq-style filters are **python-yq** (kislyuk) syntax. The far more
common Go `yq` (mikefarah) does not accept `--arg` and every one of those calls would fail. It works here
because `setup-basics.sh:43` installs Ubuntu's `yq` package, which is python-yq. This is load-bearing and
undocumented; `check_dependencies` (line 56) should assert the flavour, e.g.
`yq --help 2>&1 | grep -q -- --arg || log_error "requires python-yq (apt install yq), not mikefarah/yq"`.

---

## 7. Documentation

- **`README.md:48` overstates ordering** — "runs them in order" implies dependency awareness that does not
  exist (see H-1). Should read "in alphabetical order" until H-1 is addressed.
- **`AGENTS.md:60-62` templating rule is not followed by 9 of 12 compose-generating scripts.** Either
  migrate the heredocs to `templates/` or amend the rule to describe reality. Leaving the gap makes the
  file less trustworthy as agent instructions.
- **`README.md` does not mention `setup-omnigent`** in its service list despite 3 passing references, and
  documents no `setup-obsidian-livesync` (consistent with M-5 — the script doesn't exist).
- `README_TRAEFIK.md` (14 KB) and `specification/traefik-v3-advanced-reference.md` (69 KB) are substantial
  and appear accurate, but nothing links them from `README.md`'s Traefik section.

---

## 8. Prioritised recommendations

**Fix first (correctness / lockout):**

1. `setup-fail2ban.sh` — export the template variables, drop `sudo` from `envsubst` (H-2). One line.
2. `setup-sshd.sh` — add `sshd -t` before restart, back up the config, move to a
   `sshd_config.d/` drop-in (H-3b, H-3c).
3. `configure-firewall.sh` — detect the live SSH port before `ufw_enable`, or default the script to
   `enabled: false` (H-3a).
4. `setup-docker.sh` — run the smoke test under `sudo` (M-4).

**Fix next (usability):**

5. Dependency ordering in `run-setup.sh` — `after:` key + topological sort (H-1).
6. `ASSUME_YES` convention across the prompting scripts, exported by `apply` (M-8).
7. Reconcile `machine-config.yml` with `tasks/` and add a drift check to `status` (M-5).
8. `setup-n8n.sh` — rewrite against the forgejo/openwebui pattern (M-7).

**Then (hygiene):**

9. `chmod 600` before writing secrets; `umask 077` in secret sections (M-9, M-10).
10. Pin container image tags behind `${*_IMAGE}` variables (L-18).
11. `run-setup.sh` cosmetics: `\n` rendering (M-6), colours (L-11), doubled prefix (L-12), silent
    no-op exit (L-14).
12. Assert the `yq` flavour in `check_dependencies`; document it in `README.md`.

**Worth considering:** the codebase has no automated tests. `specification/project/test-strategy.md`
exists, but nothing executes. Given that these scripts run as root against remote servers, even a shallow
harness — `bash -n` on every script, a `shellcheck` gate, and a `status`-parses-config smoke test in CI —
would catch most of the class of defects found above (H-2 and M-6 would both have been caught by a single
golden-output test of the generated files).
