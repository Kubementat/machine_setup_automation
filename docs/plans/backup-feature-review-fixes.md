# Task: Backup Feature — Full Review Findings, Bugfixing & Simplification Plan

**Audience:** implementation agent picking this up from scratch.
**Scope:** `tasks/setup-backup-client.sh`, `tasks/setup-backup-server.sh`,
`lib/docker-backup.sh`, `specification/features/setup-backup-server.md`, docs.
**Sources:** two sequential code-review subagents + maintainer verification.
All HIGH findings below were independently re-verified against upstream sources
(borg 1.4.4 docs, Open WebUI docs, the repo's own service setup scripts).

Read `AGENTS.md` first (lint rules, idempotency, secrets, `/srv` layout) and load
the `karpathy-guidelines` skill. Every change must be surgical: each edited line
traces to a numbered finding below.

---

## 0. Spec simplifications & improvements (agreed direction)

These shape the fixes; the spec text itself is updated in Step 3.

1. **fstab check: replace grep logic with `findmnt --fstab`** — the current
   regex-grep (`_check_fstab`) is imprecise (matches any `/dev/` line, breaks on
   multi-line blkid output, false-negatives on `LABEL=` entries) and only warns,
   while the spec's error table promises an abort. `findmnt --fstab -n -o SOURCE
   <mount>` is the precise, simple primitive. Make full-run abort, `--check` FAIL.
2. **Document one container-name override convention** — `bk_*` uses
   `FORGEJO_CONTAINER`/`PLANKA_CONTAINER`/`NEXTCLOUD_CONTAINER` as backup-side
   overrides, but the service setups use `CONTAINER_NAME` (baked into the
   rendered compose at setup time, not recoverable at dump time). Keep the
   backup-side vars (defaults match defaults), document the mirroring
   requirement in spec + AUTOMATIONS notes. No code churn.
3. **State the `--check` privilege contract** in the spec: server `--check`
   needs root (uses blkid + user write-probe); client `--check` runs unprivileged
   with a warning (already true in code).
4. **Document borg 1.x archive-path semantics** (sources stored without the
   leading `/`) — root cause of the two HIGH restore bugs; must be visible in
   the spec's restore description.
5. **Nuance the "credentials/DB names read back from .env" claim** — postgres DB
   names for kestra/n8n/concourse come from compose defaults (`.env` has no
   `POSTGRES_DB`; the `$svc` fallback coincides); nextcloud backend type is not
   in `.env` at all. Fix the claim + make the lib infer (see B4/B5).
6. **Add a local-mode mount guard** to the wrapper (P2 item R7) — the only
   defense against a rebooted machine with an unmounted backup drive silently
   filling the root filesystem with borg chunks.
7. **Local-mode VM smoke test** — spec claims "no bash unit-test framework";
   the virt-runner suite can cover a loopback local-mode repo (Step 4).

Explicitly rejected (YAGNI / out of scope): wrapper template moved to
`templates/` (heredoc precedent stands, refactor risk > benefit), append-only,
Healthchecks.io, repokey→repokey-blake2 change (would orphan existing repos).

---

## 1. P0 bugfixes (B1–B7) — file:line refs are current

**B1 — `restore_db` extract pattern never matches (wrapper).**
`tasks/setup-backup-client.sh:641`: `borg extract ... "${BACKUP_STAGING_DIR}/dumps"`
— borg 1.x stores `/srv/...` as `srv/...`; a leading-slash pattern matches
nothing and **exits 0 silently**. Result: `restore-db` can never find dumps;
misleading "no <svc> dump found in snapshot".
Fix: pattern `"${BACKUP_STAGING_DIR#/}/dumps"` (the glob at line 648 already
expects `${tmp}/srv/...`).

**B2 — `restore` silently no-ops on absolute paths (wrapper).**
`tasks/setup-backup-client.sh:617,625`: trailing `[paths...]` are passed verbatim
to `borg extract`; absolute paths match nothing, exit 0, wrapper prints
"restore complete" with an empty dest.
Fix: strip on collection — `*) paths+=("${1#/}"); shift ;;` — and extend the
wrapper usage line for `restore` to note "paths as stored in the archive
(leading / stripped)".

**B3 — Open WebUI sqlite path wrong → empty DB archived.**
`lib/docker-backup.sh:410,492` use `/app/backend/data/db.sqlite`; the image
default is `/app/backend/data/webui.db` (Open WebUI docs). Worse: `sqlite3
<missing> ".backup x"` **creates an empty DB** → dump "succeeds", every archive
holds an empty Open WebUI database.
Fix: new helper `bk_openwebui_db <container>` in the lib:
1. parse the container env `DATABASE_URL` (`sqlite:////abs/path` or
   relative `sqlite:///./data/x.db` → resolve under `/app/backend`);
2. else detect exactly one `*.db`/`*.sqlite` file in `/app/backend/data`
   (`docker exec ... sh -c 'ls ... | head -n1'`);
3. none/multiple → `bk_error` + return 1.
Use it in both the openwebui dump branch and the openwebui restore branch.
Default outcome for a stock install: `/app/backend/data/webui.db`.

**B4 — nextcloud DB backend detection broken (postgres/sqlite installs).**
`lib/docker-backup.sh:393` reads `DB_TYPE` from `/srv/nextcloud/.env`, but
`tasks/setup-nextcloud.sh:399-412` never writes it → postgres/sqlite installs
fall into the mariadb branch → "no MYSQL_ROOT_PASSWORD" → whole run aborts.
Fix: resolution order: `DB_TYPE` from `.env` → if default-and-no MYSQL_ROOT or
POSTGRES keys, infer from the db container image:
`docker inspect --format '{{.Config.Image}}' "${ncc}-db"` → contains
`mariadb|mysql` → mariadb, `postgres` → postgres; inspect fails → sqlite.
(Minimal shape: check `.env` DB_TYPE first; if `.env` has `MYSQL_ROOT_PASSWORD`
→ mariadb; else if `${ncc}-db` image matches postgres → postgres; else keep
current error paths.)

**B5 — nextcloud mariadb DB name hardcoded.**
`lib/docker-backup.sh:401,476` use `"nextcloud"`; setup writes `MYSQL_DATABASE`
to `.env` (default `nextcloud`). Use `bk_service_env "$nchome" MYSQL_DATABASE
nextcloud` in dump and restore.

**B6 — `--check --full` runs as the invoking user, not the timer user.**
`tasks/setup-backup-client.sh:800-807`: every other repo probe uses the
`as_user` prefix (`sudo -H --preserve-env=... -u "$BACKUP_USER"`); the full
check calls plain `borg check --verify-data` (root's known_hosts/cache).
Fix: `if "${as_user[@]}" borg check --verify-data "$REPO_URI"; then`.

**B7 — `--help` advertises a borg 2.x flag.**
`tasks/setup-backup-client.sh:154`: `'borg check --read-data'` — borg 1.4 has
only `--verify-data` (verified against 1.4.4 docs; implementation is correct).
Fix help text to `--verify-data`.

**B8 — passphrase generation dies under `set -o pipefail` (VM-found).**
`tasks/setup-backup-client.sh:389`: `tr -dc ... /dev/urandom | head -c 32` —
the killed `tr` returns 141 (SIGPIPE) and `pipefail` aborts the script: the
client script could **never** create a passphrase on a fresh machine. Fixed
with `IFS= read -r -n 32 pass < <(tr ...)` (substitution status ignored) +
empty-value guard. Reproduced on bash 5.x (dev + VM): old idiom rc=141.

**B9 — `warn` inside captured `_check_mount` pollutes its stdout contract
(VM-found).**
`tasks/setup-backup-server.sh` `_check_mount` printed the unexpected-fstype
`warn` into its own captured output → summary lines rendered `Mounted: ...
([WARN])` and the uuid/source parsing in `_check_fstab` received garbage.
Fixed: `_check_mount` stays silent; new `_warn_fstype` helper called by both
call sites after the capture.

**B10 — `sudo --preserve-env` drops the passphrase silently → `borg init`
prompts interactively (VM-found, HIGH).**
Ubuntu ≥ 25.10 ships **sudo-rs**, which ignores `--preserve-env` (classic sudo
needs a `setenv`/`SETENV` sudoers policy). `init_repo` and the `--check`
probes relied on it: `borg init -e repokey` entered an interactive
prompt loop and failed ("Exceeded the maximum password retries") on a fresh
machine. Fixed with `run_borg_as_user <probe|init>` — a single
`sudo -H -u <user> sh -c '...'` that reads `PASS_FILE` *inside* the target
user's shell (never ps-visible, no sudo env dependency); `init` mode also
exports `BORG_NEW_PASSPHRASE`. `check_mode` uses it via the `as_user` array.

**B11 — generated `.timer` had no `[Install]` section (VM-found, HIGH).**
Without `WantedBy=timers.target` the unit stays `static`: `systemctl
is-enabled` → static, no symlink, timer does not survive a reboot (and the
"already active → keep state" branch never enabled it). Fixed: `[Install]`
added; `write_units` now always runs `systemctl enable` (idempotent —
converges pre-existing static installs) and only `start`s when inactive.

**B12 — `borg create` exit 1 (warnings) aborted the run and skipped prune
(VM-found, HIGH).**
Backing up `/etc` as the non-root timer user *always* yields unreadable-file
warnings → borg create exits 1 → under `set -e` the wrapper died after
writing the archive: prune never ran (retention broken) and every nightly
run reported failure — with `/etc` in the README-recommended path set.
Fixed per spec's success definition ("archive created **and** prune
completed"): exit 1 is logged as a warning and prune proceeds; exit ≥ 2
(lock, ENOSPC, I/O, remote) remains fatal.

## 2. P1 robustness (R1–R9)

**R1 — dead `parent="/"` fallback can chown the whole root filesystem.**
`tasks/setup-backup-client.sh:338-345`: drop the `[[ -n "$parent" ]] ||
parent="/"` fallback; simply skip the parent chown when empty.

**R2 — failed dumps leave partial files that can be mistaken for good dumps.**
`lib/docker-backup.sh`: `bk_pg_dump` (156/161), `bk_mariadb_dump` (177)
redirect `> "$out"` before the engine runs; on failure a 0-byte/partial file
remains (the `restore_db` glob picks the newest match). Fix: on every failure
path in `bk_pg_dump`/`bk_mariadb_dump`/both `docker cp` paths
(`bk_sqlite_backup`, forgejo) `rm -f "$out"` before returning non-zero.

**R3 — silent stopped container on sqlite start failure.**
`lib/docker-backup.sh:209` and `:229`: `docker start ... || return 1` with no
message. Add `bk_error "${container} left stopped — start it manually"`
before returning.

**R4 — `bk_stack_resume` ignores exited containers.**
`lib/docker-backup.sh:328`: `docker compose ps -q` lists only running
containers → a service that exited instantly after `up -d` still reports
resume success. Fix: `ps -aq` (wait_running then flags exited/created).

**R5 — openwebui home override mismatch.**
`lib/docker-backup.sh:291` `${OPENWEBUI_HOME:-/srv/openwebui}` vs
`tasks/setup-openwebui.sh:110` `PROJECT_DIR`. Fix:
`${OPENWEBUI_HOME:-${PROJECT_DIR:-/srv/openwebui}}`.

**R6 — SSH key readability is only checked as the invoking user.**
`tasks/setup-backup-client.sh` `validate()` (272-279): remote mode later runs
`sudo -u "$BACKUP_USER" ssh -i "$BACKUP_SSH_KEY"` — a root-owned 0600 key fails
BatchMode with a generic message. Add:
`sudo -u "$BACKUP_USER" test -r "$BACKUP_SSH_KEY"` check with a clear error.

**R7 — wrapper single-quote injection via unvalidated values.**
`render_excludes_block` / wrapper heredoc bake `BACKUP_PATHS`,
`BACKUP_STAGING_DIR`, exclude regexes into `'...'`. A value containing `'`
breaks/injects the generated wrapper. Fix in `validate()`: reject
`BACKUP_PATHS`, `BACKUP_STAGING_DIR` and each exclude regex entry containing a
single quote (client name and services are already validated).

**R8 — server fstab check (see spec item 1).**
`tasks/setup-backup-server.sh:148-171,247-262`:
- `_check_mount`: truncate blkid output to first line (`uuid="${uuid%%$'\n'*}"`).
- `_check_fstab`: primary check `findmnt --fstab -n -o SOURCE "$BACKUP_MOUNT"`
  (rc 0 = persistent); fallback to `grep -qsF "$uuid" /etc/fstab ||
  grep -qsF "$source" /etc/fstab` when findmnt unavailable. Drop the loose
  `"(UUID=|PARTUUID=)\"?${uuid}\"?|/dev/"` ERE entirely.
- Full run: not persistent → `error` (abort) with the fstab-instruction
  message; `--check`: count FAIL.

**R9 — local-mode mount guard (spec item 6).**
`resolve_repo_uri()` (full run, local mode): bake
`REPO_MOUNT_SOURCE="$(findmnt -n -o SOURCE --target "$repo_path")"` into the
wrapper (empty when findmnt fails → guard inactive). In wrapper `create()`,
before any dumps: if `REPO_MOUNT_SOURCE` non-empty and
`findmnt -n -o SOURCE --target "${REPO_URI%/*}"` differs → abort (exit 2) with
"backup drive does not appear mounted at the repo path — refusing to write
backups into the root filesystem". Non-secret device identifier; re-run setup
after a drive replacement updates it.

## 3. Spec & doc updates (D1–D5)

**D1 — `specification/features/setup-backup-server.md`:**
- Docker dump table: openwebui row → "`sqlite3 .backup` of the SQLite DB under
  `/app/backend/data` (`webui.db` by default; resolved via container
  `DATABASE_URL` / directory detection)"; nextcloud row → add "backend from
  `.env DB_TYPE` if present, else inferred from the `${CONTAINER}-db` image".
- Add container-name override note under the dump table (spec item 2).
- "Restore is never in-place" paragraph: add archive-path semantics note
  (leading `/` stripped; wrapper strips it from `restore` args).
- Error table Behavior 1: fstab row → now actually aborts (keep wording);
  add explicit `--check` privilege lines for both scripts (spec item 3).
- Implementation notes: add bullet for partial-dump cleanup (R2) and the
  local-mode mount guard (R9); soften the "DB names/credentials are read back
  from each service's .env" claim per spec item 5.
- Generated-files table: wrapper now also carries `REPO_MOUNT_SOURCE`
  (local mode).
- Testing: add a line that a local-mode loopback smoke is automated in the
  virt-runner suite (Step 4).

**D2 — `lib/docker-backup.sh`:** header "DB names and credentials ... read back
from each service's .env" → mention container-env inspection + compose-default
fallback for kestra/n8n/concourse POSTGRES_DB.

**D3 — `AUTOMATIONS.md` (Backup section notes):** add one sentence for the
`<SVC>_CONTAINER` override mirroring custom `CONTAINER_NAME` installs.

**D4 — `README.md` / `skills/.../SKILL.md`:** update only if they restate wrong
facts (check for `db.sqlite`; no known occurrences — verify, otherwise untouched).

**D5 — `machine-config.yml.example`:** no change needed (verified correct).

## 4. Tests (T1–T3)

**T1 — static:** `shellcheck` clean on all three files; `bash -n`;
`--help` of both scripts mentions only borg 1.x flags.

**T2 — VM integration (virt-runner, tests/README.md):**
The `run-vm-tests.sh` harness has **no pre-step hook**, and this feature needs
one (a mountable "backup drive" + fstab entry) → verification is done **manually
against a virt-runner VM** (same tooling the harness uses):

```console
$ virt-runner create --name mas-bktest --json        # note .vm.ip
$ scp -r repo → /home/ubuntu/kwisatz
# pre-step (satisfies mount + fstab checks; tmpfs is a valid findmnt target):
$ sudo mkdir -p /srv/backups
$ sudo mount -t tmpfs -o size=512m tmpfs /srv/backups
$ echo 'tmpfs /srv/backups tmpfs defaults,size=512m 0 0' | sudo tee -a /etc/fstab
# then per spec matrix:
$ sudo tasks/setup-backup-server.sh                  # T1.1, exit 0
$ sudo tasks/setup-backup-server.sh                  # T1.3 idempotent re-run
$ sudo tasks/setup-backup-server.sh --check          # exit 0
$ sudo tasks/setup-backup-client.sh --repo-path /srv/backups/automatic \
      --paths /etc --initial                         # T2.2/T2.5/T2.6 local mode
$ sudo tasks/setup-backup-client.sh --repo-path /srv/backups/automatic \
      --paths /etc                                   # T2.3 idempotent re-run
$ sudo tasks/setup-backup-client.sh --repo-path /srv/backups/automatic \
      --paths /etc --check                           # exit 0, incl. B6 path
$ sudo /usr/local/bin/borg-backup-<host> restore <snap> --dest /tmp/r /etc
      # B2 fix: leading-slash path must actually extract files
$ virt-runner destroy --name mas-bktest
```
Expected: every command exit 0; after `restore`, `/tmp/etc` (or equivalent)
contains `/etc` files byte-identical (spot-check with `diff -r`); passphrase
file `0600`; timer active; second run does **not** rewrite the passphrase file
(and the repo still opens — `borg list`), no re-init.

**T3 — local sanity:** generate the wrapper on the dev machine? No — wrapper
generation is verified inside the VM run; additionally re-derive the generated
wrapper by hand (`bash -n` on a rendered copy) if the VM run is blocked.

## 5. Execution order

1. B1–B3 (restore-critical), then B4–B7.
2. R1–R9.
3. D1–D4.
4. T1, then VM run (manual virt-runner flow per T2 — harness has no pre-step hook).
5. Fix fallout, re-run until PASS; then a final full-repo `shellcheck`.

## 6. VM test results (2026-09-15, Ubuntu 26.04 "resolute", borgbackup 1.4.4, sudo-rs)

VM `mas-bktest-01` (virt-runner, 2 GiB/2 vCPU), backup "drive" = tmpfs at
`/srv/backups` with fstab entry; local-mode repo, `BACKUP_PATHS=/etc`,
`BACKUP_KEEP_DAILY=1`, then destroyed.

| Case | Result |
|---|---|
| T1.2 server, unmounted/nonexistent mount | PASS — abort, no changes, rc=1 |
| T1.1 server fresh run | PASS — rc=0 (tmpfs → expected fstype *warning*, group/layout/write-probe OK) |
| T1.3 server idempotent re-run | PASS — rc=0, all "exists/skipped" |
| server `--check` | PASS — rc=0 |
| T2.2/T2.5/T2.6 client fresh `--initial` (local mode) | PASS — repo init w/o prompts (B10), passphrase 0600 ubuntu, initial archive created (warnings tolerated per B12), rc=0 |
| T2.3 client idempotent re-run | PASS — repo reused, passphrase SHA256 unchanged, units regenerated, rc=0 |
| client `--check` (incl. B6 as-timer-user path) | PASS — all green, rc=0 |
| wrapper `list` | PASS |
| wrapper `restore <snap> --dest /tmp/r /etc/hostname /etc/passwd` (B2) | PASS — files extracted, byte-identical (diff clean) |
| B1 pattern (generated) | VERIFIED statically: extract arg renders `srv/backup-staging/dumps` (live dump/restore needs an installed Docker service — covered statically + lib review) |
| R9 mount guard | PASS — after `umount`, wrapper `create` aborts rc=2 with the refuse-to-write message |
| timer persistence | PASS — `is-enabled`=enabled, `is-active`=active (B11) |
| borg prune keep-daily semantics | note: prune keeps archives younger than 1 h (borg built-in safety margin, not a bug) |

Static gates after all fixes: `shellcheck` clean on both task scripts +
`lib/docker-backup.sh`; `bash -n` clean; generated wrapper (local + remote)
`bash -n` + `shellcheck` clean; both `--help` exit 0.
