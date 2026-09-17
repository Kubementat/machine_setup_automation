# Feature: setup-backup-server — Central Borg Backup Infrastructure

> **Status:** v1 implemented — `tasks/setup-backup-server.sh`, `tasks/setup-backup-client.sh`, `lib/docker-backup.sh`, `templates/backup-client/` (Docker/DB layer included, see *Docker service backup* below)
> **Target:** Any Ubuntu server machine (this repo's normal target), plus any other machine as a backup client
> **Zero-config:** a standard user can run `./tasks/setup-backup-server.sh` with no arguments and get a working self-backup (auto-detected scope + services, local-disk storage, initial full backup). See *Convenience defaults* below.
> **Defaults grounded in:** a working reference deployment — see Appendix A

## Overview

Turn **one machine** into the central backup server of a fleet and provide a repeatable, automated
way for **other machines** to push **encrypted, deduplicated, incremental backups** into it.

The engine is **BorgBackup** (plain `borg` — see Design Decision 1). Each client machine holds a
*client-side* repo URI pointing at a directory on the server's backup drive (or a local path) and a
systemd timer that runs `borg create` + `borg prune` daily. The server only runs `borg serve`
implicitly through SSH — it is a **dumb storage host**: no scheduling, no plaintext data, no
passphrases ever stored there. Adding a machine to the fleet is one client-side script run; the
server needs no changes.

**Convenience defaults (zero-config).** The scripts are designed so that a standard user can run
`./tasks/setup-backup-server.sh` (no arguments) and end up with a **working self-backup**:
- storage defaults to a local directory on the main filesystem (`/var/backups`) when no separate
  drive is mounted (*local-disk mode* — guards against software corruption, not disk failure; a
  mounted drive switches to *drive mode* automatically),
- the backup scope and Docker services are **auto-detected** from the box's layout,
- the server then runs the client in **local mode** (`--initial`) so a real snapshot exists at the
  end. Everything is overridable (env vars / flags) and printed. Both scripts escalate per-command
  with `sudo` (no hard root gate), so they run whether invoked as root or as a sudo-capable user.

This feature delivers two idempotent task scripts, following the repo's one-script-per-component
pattern:

| Script | Role | Runs on |
|--------|------|---------|
| `tasks/setup-backup-server.sh` | Storage host: install borg, prepare storage (a mounted drive *or* a local directory), create the repo directory layout, fix group/ownership, then run a local-mode self-backup | the designated server machine |
| `tasks/setup-backup-client.sh` | Backup client: install borg, init its repo (over SSH or local), generate passphrase, install wrapper + systemd timer/service (rendered from `templates/backup-client/`), run the initial full backup | any client machine (and the server itself, in local mode) |

## Requirements

**Server machine**
- Ubuntu 22.04+ (amd64 or arm64) with systemd; verified against `borgbackup` 1.4.x from apt
  (the feature targets the **borg 1.x CLI** — see Implementation notes)
- A storage location: either a backup drive **already mounted and fstab-persistent** at a chosen
  path (*drive mode* — the script verifies, it never formats or edits fstab), or **nothing** — in
  which case it falls back to a local directory on the main filesystem (`/var/backups` by default;
  *local-disk mode*)
- A regular (non-root) user that may write the repos (default: the sudo caller / invoking user);
  the scripts escalate per-command with `sudo`, so the invoking user needs passwordless sudo
- SSH reachable by clients on a chosen port with **key-based, passwordless** auth for that user

**Client machine**
- Ubuntu 22.04+ with systemd (any other OS is out of scope, see Future Work)
- Key-based, BatchMode-able SSH access to the server port (remote mode), or local access to the
  repo path (local mode — e.g. the server backing up itself)
- Same borg major.minor as the server (apt on the same Ubuntu release satisfies this by
  construction; the script warns on mismatch)
- Source paths chosen by the operator, or **auto-detected** from the box's layout when `--paths`
  is omitted (the detected scope is printed; see Design Decision 10)

## Architecture

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐
│  client machine  │  │  client machine  │  │  more clients (later)│
│  (server, dev    │  │  (e.g. laptop)   │  │                      │
│   box, arm64/    │  │                  │  │                      │
│   amd64, ...)    │  │                  │  │                      │
│                  │  │                  │  │                      │
│ borg client      │  │ borg client      │  │  same client script  │
│ systemd timer    │  │ systemd timer    │  │                      │
└──────┬───────────┘  └──────┬───────────┘  └──────────┬───────────┘
       │  encrypted, deduplicated, incremental (only changed chunks after run 1)
       ▼                     ▼                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  backup server  ("dumb" storage host)                              │
│  sshd :<port> → borg serve (implicit)                              │
│  <mount>/               ← backup drive (ext4/xfs/btrfs), fstab     │
│    ├─ <repo-root>/                          ← per-client borg repos│
│    │    ├─ <client-a>/        (repo A)                        │    │
│    │    ├─ <client-b>/        (repo B)                        │    │
│    │    └─ <server-self>/     (repo C, local mode)            │    │
│    └─ <manual-dir>/                           ← manual full dumps  │
└────────────────────────────────────────────────────────────────────┘
```

- **One Borg repository per client** under `<repo-root>/<client>/`. Per-client repos keep keys
  independent (one lost passphrase never endangers another machine's data) and make restores
  self-contained.
- Data is **encrypted client-side** (repokey, AES-256) before leaving the machine; the server
  never sees plaintext, and the passphrase never touches the server.
- After the initial full run, each daily run transfers only new/changed chunks (dedup + `lz4`).
- `<manual-dir>` is reserved for **manual** full dumps (monthly tarballs, raw clones) — a separate,
  non-deduplicated safety net. Not touched by any script in this feature.
- The server can back up its **own** state (home, /srv, docker volumes) into a **local** repo
  using the same client script in local mode (protects against software corruption; drive
  failure needs the offsite copy — see Future Work).

## Files Delivered

| File | Purpose |
|------|---------|
| `tasks/setup-backup-server.sh` | New — server (storage-host) setup + local-mode self-backup |
| `tasks/setup-backup-client.sh` | New — client setup (remote-over-SSH *and* local repo support) |
| `lib/docker-backup.sh` | New — Docker/DB dump + restore layer (sourced by the wrapper) |
| `templates/backup-client/borg-backup-wrapper.sh` | New — wrapper template, rendered with `envsubst` into `/usr/local/bin/borg-backup-<client>` |
| `templates/backup-client/borg-backup.service` | New — one-shot systemd unit template (rendered per client) |
| `templates/backup-client/borg-backup.timer` | New — daily systemd timer template (rendered per client) |
| `machine-config.yml.example` | Add `setup-backup-server:` and `setup-backup-client:` entries, both `enabled: false` |
| `README.md` | Document both scripts under a new "Backups" section (evolution: server → clients) |
| `CONTEXT.md` | Add "backup-server" / "backup-client" domain terms |
| `skills/machine-setup-automation-assistant/SKILL.md` | Add both scripts to the service-category table |

Generated at runtime on the target host (not committed):

*Client role:*
| Path | Purpose |
|------|---------|
| `~/.config/borg/<client>.pass` | Repo passphrase (mode 0600, owned by backup user; dir 0700) |
| `/usr/local/lib/borg-backup/docker-backup.sh` | Installed copy of `lib/docker-backup.sh` (sourced by the wrapper for the Docker/DB dumps) |
| `/usr/local/bin/borg-backup-<client>` | Wrapper: `create`, `list`, `check [--full]`, `restore`, `restore-db --yes`; carries repo URI, paths, exclusions, retention, services, and `REPO_MOUNT_SOURCE` (local mode: the create-time mount guard) |
| `<BACKUP_STAGING_DIR>` (default `/var/backup-staging`) | Dump staging dir, mode 0700 owned by the backup user (created when `--services` is set; the wrapper creates `dumps/` inside it). Default sits outside the typical `/etc /srv /home` scope to avoid the nesting collision. |
| `/etc/systemd/system/borg-backup-<client>.service` | One-shot service running the wrapper as the backup user |
| `/etc/systemd/system/borg-backup-<client>.timer` | Daily, `Persistent=true`, `RandomizedDelaySec=15m`, `[Install] WantedBy=timers.target` (without it the unit stays `static` and never survives a reboot) |

*Server role:*
| Path | Purpose |
|------|---------|
| `<repo-root>/`, `<manual-dir>/` | Directory layout (created if missing; existing contents never modified) |

## Design Decisions

| # | Decision | Choice & rationale |
|---|----------|--------------------|
| 1 | Backup engine | **Plain Borg from apt** (`borgbackup`), *not* borgmatic. Rationale: keeps the feature in bash (repo conventions: shellcheck, `lib/helpers.sh`); no extra Python dependency; apt on the same Ubuntu release gives identical borg versions on client and server (the version-pairing constraint is satisfied by construction). borgmatic's main extra value (DB pre-dump hooks) is not needed for a typical Ubuntu-server fleet in v1. |
| 2 | Topology | **Client-push over SSH** (repo URI `ssh://user@server:port/<repo-root>/<client>`, or a local path). Server stays stateless w.r.t. scheduling; a new machine = one client-side script run, zero server changes. |
| 3 | SSH endpoint | Host, port, and user are **configuration** (`BACKUP_SERVER_HOST/PORT/USER`), default port **22**. Use whichever key-based port is reachable on the target network (some machines only expose a non-standard or internet-forwarded port — set `BACKUP_SERVER_PORT` accordingly). |
| 4 | Encryption | `repokey` (key stored with the repo) + `lz4` compression. `repokey` keeps the key with the data (one passphrase to remember) — the right trade-off for personal/small fleets where the repo host is trusted LAN infrastructure. |
| 5 | Passphrase handling | Generated by the client script (32 chars from `/dev/urandom`), written **only** to `~/.config/borg/<client>.pass` (0600), read into `BORG_PASSPHRASE` at run time (apt borg 1.x has no `BORG_PASSPHRASE_FILE` support — see Implementation notes). **Never printed** by default (opt-in `--show-passphrase`), never logged to the journal, never transmitted. The operator is instructed to move it to a password manager. The passphrase file must not be placed inside any backed-up path. |
| 6 | Scheduling | **System-level systemd timer** (not user unit, not cron): runs without login, `Persistent=true` fires a missed run (machine off/lid closed) after boot, `RandomizedDelaySec=15m` spreads load. Service unit runs as the regular backup user (`User=`), not root. |
| 7 | Unit/wrapper generation | **Template files rendered with `envsubst`** (repo templating convention, precedent: `setup-vllm-omni.sh` / `setup-opencode.sh`): `templates/backup-client/{borg-backup-wrapper.sh,borg-backup.service,borg-backup.timer}` are substituted per client (repo URI, paths, exclusions, retention, client name, retention) and installed into place. `envsubst` uses an **explicit variable list**, so the wrapper's *runtime* bash variables (and `${VAR//…}` / `${arr[@]}` forms) stay literal — only the named render-time values are baked in. The unit stays trivial (`ExecStart=/usr/local/bin/borg-backup-<client> create`). |
| 8 | Retention (prune) | `--keep-daily=7 --keep-weekly=4 --keep-monthly=12` default, all overridable. Prune runs immediately after each successful create, same archive-name prefix. |
| 9 | Archive naming | `<client>-%Y-%m-%dT%H:%M:%S` — sortable, unique, prunable by prefix. |
| 10 | Paths / scope | **Auto-detect, never guess.** When `--paths` is omitted, the script inspects the box and picks `/home/<user>` (if present) + `/etc` + `/srv` (if non-empty) + `/var/lib/docker/volumes` (if Docker is running), **printing the chosen scope**. An explicit `--paths` always wins. This keeps the zero-config path useful while never silently backing up an arbitrary whole-disk scope (the detected set is shown and re-runnable with the printed values). Recommended scopes per machine type live in the Rollout section. |
| 11 | `--one-file-system` | On by default (skip bind mounts / `/snap` / docker overlay mounts under the paths), overridable off. `--exclude-caches` always on. |
| 12 | Local repo support | The client script accepts a plain local path as repo location (used for the server backing up itself, or any machine with its own spare drive): `BACKUP_SERVER_HOST` empty → local mode. |
| 13 | Server script scope | Install + prepare storage + layout + group/ownership + **local-mode self-backup**. It never formats or edits fstab: a mounted drive is verified present (drive mode); otherwise it uses/creates a local directory on the main fs (local-disk mode) and warns it is same-disk. After storage is ready it runs `setup-backup-client.sh` in local mode (`--initial` by default) so the machine is self-backing up; `--no-self-backup` / `--no-initial` opt out. It never deletes data. |
| 14 | Idempotency | Re-runs skip completed work: borg present → skip; drive mounted → verify only; repo exists → do **not** re-init, instead verify the stored passphrase opens it (`borg list`); passphrase file exists → keep; units exist → regenerate + `daemon-reload` (config is derived, safe to overwrite); timer enabled → leave. |
| 15 | `--check` mode | Both scripts get `--check`: report status (install, mount, repo health, timer state, last run result, latest snapshot) and exit non-zero on problems. Intended for future monitoring integration. |

## Environment Variables

All tunables are env vars with defaults at the top of the script (repo convention); CLI flags
mirror them (`--help` lists both).

### `setup-backup-server.sh`

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_MOUNT` | `/var/backups` | Where repos live. A separate mounted drive = *drive mode* (must be fstab-persistent); the main fs = *local-disk mode* (created if missing; warns same-disk) |
| `BACKUP_REPO_ROOT` | `${BACKUP_MOUNT}/automatic` | Root for per-client borg repos |
| `BACKUP_MANUAL_DIR` | `${BACKUP_MOUNT}/manual` | Manual-dump dir (created if missing, never modified) |
| `BACKUP_GROUP` | `backups` | Group with write access to the storage; `BACKUP_USER` is added to it (created if missing) |
| `BACKUP_USER` | invoking user | Regular user that must be able to write repos (default: sudo caller / invoking user) |
| `BACKUP_MIN_FREE_GB` | `100` | Warn if the storage has less free space |
| `BACKUP_PATHS` / `BACKUP_SERVICES` / `BACKUP_KEEP_*` / `BACKUP_COMPRESSION` | *(empty)* | Self-backup scope, forwarded to the client. Empty = the client auto-detects (see client table). Flags `--no-self-backup` / `--no-initial` disable the self-backup / initial run |

### `setup-backup-client.sh`

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_CLIENT_NAME` | `$(hostname)` (lowercased, `[a-z0-9-]`) | Repo dir name & archive prefix (`[a-z0-9-]` only) |
| `BACKUP_USER` | invoking user | **Local** user the timer/service runs as (`--local-user`) |
| `BACKUP_SERVER_HOST` | *(empty)* | Server address. **Empty = local repo mode** (Decision 12); non-empty = remote SSH mode |
| `BACKUP_SERVER_PORT` | `22` | SSH port on the server (Decision 3) |
| `BACKUP_SERVER_USER` | invoking user | SSH user on the server (must have key-based, passwordless SSH from the client) |
| `BACKUP_SSH_KEY` | `~<BACKUP_USER>/.ssh/id_ed25519` | Key used for remote mode (preflight, `borg serve`, wrapper `BORG_RSH`) |
| `BACKUP_REPO_PATH` | `/var/backups/automatic` | Parent dir for the repo; final repo = `<BACKUP_REPO_PATH>/<client>/`. Should match the server's `BACKUP_REPO_ROOT` |
| `BACKUP_PATHS` | *(empty → auto-detect)* | Space-separated source paths. Omit to auto-detect `/home/<user>`, `/etc`, `/srv` (if non-empty), `+ /var/lib/docker/volumes` (if Docker running) — the choice is printed (Decision 10) |
| `BACKUP_SERVICES` | *(empty → auto-detect)* | Comma list of Docker services to dump. Omit to auto-detect installed/running ones (each `/srv/<svc>` dir or matching running container). Empty result = plain file backup |
| `BACKUP_STAGING_DIR` | `/var/backup-staging` | Host dir for engine dumps; must not be inside `BACKUP_PATHS` (the default sits outside the typical scope) |
| `BACKUP_EXCLUDE_REGEXES` | see below | Newline/space-separated borg `--exclude` regexes, appended to built-ins |
| `BACKUP_KEEP_DAILY` / `BACKUP_KEEP_WEEKLY` / `BACKUP_KEEP_MONTHLY` | `7` / `4` / `12` | Prune retention |
| `BACKUP_COMPRESSION` | `lz4` | `lz4` or `zstd` |
| `BACKUP_ONE_FILE_SYSTEM` | `true` | Pass `--one-file-system` to create |
| `BACKUP_RUN_INITIAL` | `false` | `true`/`--initial`: run the first (full) backup synchronously at setup time |

Default `BACKUP_EXCLUDE_REGEXES` (re-downloadable / regenerable on a typical Ubuntu machine):

```
(^|/)snap/
(^|/)node_modules/
(^|/)\.cache/
(^|/)\.npm/
(^|/)\.cargo/registry/
(^|/)\.rustup/
```

Always on (not in the regex list): `--exclude-caches`. Append machine-specific regexes via
`BACKUP_EXCLUDE_REGEXES` (example in Appendix A).

## Behaviors

### Behavior 1: Server setup (`setup-backup-server.sh`)

Happy path (privileged ops escalate per-command with `sudo`; runs as root **or** a sudo-capable
user — no hard root gate):
1. Install `borgbackup` if not installed (`apt-get`), report version.
2. **Prepare storage** at `${BACKUP_MOUNT}`:
   - *drive mode* (a separate mounted filesystem, i.e. `findmnt SOURCE` of the path ≠ the `/`
     device): verify it is ext4/xfs/btrfs and fstab-persistent (`findmnt --fstab`); print size /
     free space.
   - *local-disk mode* (path is on the main fs, e.g. the `/var/backups` default): create the dir
     if missing and **warn** it is same-disk (guards software corruption, not disk failure).
   - **warn** in both if free < `BACKUP_MIN_FREE_GB`.
3. Ensure `${BACKUP_GROUP}` exists (create if missing) and add `BACKUP_USER` to it
   (`usermod -aG`).
4. Create `${BACKUP_REPO_ROOT}` and `${BACKUP_MANUAL_DIR}` if missing; chown to
   `BACKUP_USER:${BACKUP_GROUP}` mode `775`; verify `BACKUP_USER` can `stat` (and write a
   temp file into) `${BACKUP_REPO_ROOT}` — covers both `root:group` and `user:user` mount
   ownership layouts.
5. **Self-backup** (unless `--no-self-backup`): run `setup-backup-client.sh` in **local mode**
   with `BACKUP_REPO_PATH=${BACKUP_REPO_ROOT}` and the forwarded scope (`--paths` / `--services` /
   retention / compression; empty ⇒ the client auto-detects), plus `--initial` (unless
   `--no-initial`) so a real snapshot exists. Fails the run if the client fails. Otherwise print
   the exact command to add a client.
6. Print summary.

Error cases:
| Case | Behavior |
|------|----------|
| Drive mode: mount missing / not in fstab | **Abort** with message: mount the drive & add fstab entry first (script never does this itself) |
| Local-disk mode: `${BACKUP_MOUNT}` not writable by `BACKUP_USER` | Abort at the write probe with an ownership/options hint |
| `BACKUP_REPO_ROOT` exists with unexpected ownership | Warn + chown to `BACKUP_USER:${BACKUP_GROUP}` (never delete) |
| Client/self-backup step fails | Abort (non-zero exit) with the client's error output |

`--check`: report install/version, storage (drive or local) + free space, group membership, dir
layout; exit 0 only if all green. `--check` needs only passwordless sudo (uses `blkid` and a
`sudo -u` write probe), not a root session.

### Behavior 2: Client setup (`setup-backup-client.sh`)

Happy path (first client run; privileged ops escalate per-command with `sudo`):
1. **Auto-detect** `BACKUP_PATHS` (Decision 10) and `BACKUP_SERVICES` (installed/running supported
   services) when omitted, printing the result; then verify `BACKUP_CLIENT_NAME` charset and that
   every path exists.
2. Install `borgbackup` (and `gettext-base` for `envsubst`) if missing.
3. **SSH preflight** (remote mode, executed **as the backup user** — the timer user — so host-key
   acceptance lands in the right `~/.ssh/known_hosts`):
   `ssh -o BatchMode=yes -o ConnectTimeout=10 -p PORT USER@HOST true`. On failure **abort** with
   instructions (copy key / `ssh-copy-id`, check port). Additionally verify the server's borg
   version (`ssh ... 'borg --version'`); on major.minor mismatch abort unless
   `--force-version-mismatch`.
4. Resolve repo URI: remote → `ssh://USER@HOST:PORT/REPO_PATH/CLIENT/`; local mode →
   `REPO_PATH/CLIENT/` (a freshly created local repo parent is chowned to the backup user).
5. **Passphrase + repo init** (idempotent, borg commands run **as the backup user**
   via `sudo -H -u <user> sh -c '…'` — the passphrase is read from its file *inside*
   the target user's shell; never via `sudo --preserve-env`, which sudo-rs drops
   silently and classic sudo gates behind a `setenv` policy): passphrase file exists → keep, else generate →
   `~/.config/borg/<client>.pass` (0600), `chmod 700 ~/.config/borg`. Then: if `borg list`
   succeeds with the stored passphrase → skip. Else if `borg init -e repokey <repo-uri>`
   succeeds → done. Else (repo already exists but passphrase is wrong/missing) → **abort**
   with explicit message: "repo exists but stored passphrase does not open it — restore the
   passphrase file from your password manager, then re-run".
 6. Render the wrapper `/usr/local/bin/borg-backup-<client>` (0755) from
    `templates/backup-client/borg-backup-wrapper.sh` via `envsubst` (Decision 7) containing: repo
    URI, passphrase-file path, paths, excludes, compression, retention, services; subcommands:
    - `create` — optional Docker dumps first (see *Docker service backup*), then
      `borg create --one-file-system --exclude-caches --exclude ... --stats
      <repo>::<client>-%Y-%m-%dT%H:%M:%S <paths... [staging dir]>` and finally
      `borg prune --glob-archives '<client>-*' --keep-...`
    - `list` — `borg list --short <repo>` (latest 20 snapshots)
    - `check [--full]` — `borg check <repo>` (metadata; `--verify-data` if `--full` — borg 1.x
      name for a full read-data check)
    - `restore <snapshot> [--dest DIR] [paths...]` — `borg extract <repo>::<snapshot> ...` into a
      destination dir (default `./restore-<client>-<ts>`); **never extracts in place by default**
    - `restore-db <snapshot> <service> --yes` — **destructive** restore of one service's database
      from its dump inside the snapshot (see *Docker service backup*)
 7. Render `.service` (`User=`, `ExecStart=... create`, `Nice=10`,
    `IOSchedulingClass=best-effort`) and `.timer` (`OnCalendar=daily`, `Persistent=true`,
    `RandomizedDelaySec=15m`) from `templates/backup-client/{borg-backup.service,borg-backup.timer}`
    via `envsubst` (Decision 7); `systemctl daemon-reload`; `systemctl enable --now
    borg-backup-<client>.timer`.
8. Print summary: repo URI, passphrase file path (with "move to password manager" warning), timer
   state, and the exact restore command for the latest snapshot.
9. If `--initial`: run the wrapper `create` in the foreground (for large source sets this takes a
   long time — print a warning before starting) and fail setup on error.

Error cases:
| Case | Behavior |
|------|----------|
| A configured path missing, or auto-detection found nothing to back up | Abort with a hint to pass `--paths` |
| SSH BatchMode fails | Abort + key-setup instructions (for the configured port) |
| Repo exists, passphrase missing/wrong | Abort with restore-the-passphrase message (step 5) |
| Client/server borg major version mismatch | Warn loudly, proceed only with `--force-version-mismatch` |
| Timer already active from older setup | Regenerate units, `daemon-reload`, keep timer state |
| Local mode + repo parent missing | Create parent dir (local drive is the operator's own; allowed) |

### Behavior 3: Daily runtime (wrapper `create`)

- Runs as `BACKUP_USER` via the system service (no root needed).
- Success = archive created **and** prune completed. Journal output via systemd
  (`journalctl -u borg-backup-<client>`). `borg create` exit 1 means **warnings**
  (unreadable/changed files — e.g. a non-root user backing up `/etc`): the archive
  is complete, the wrapper logs a warning and continues to `prune`; exit ≥ 2
  (lock, ENOSPC, I/O, remote) fails the run.
- Failure modes handled by Borg itself (remote lock held by another run → exit with error;
  journal shows it). Docker dump failures abort **before** `borg create` (exit 2, no archive
  written, quiesced services resumed via the wrapper's EXIT trap). The wrapper adds:
  non-zero exit on any failure, no `--progress` (systemd context).
- Stale locks: documented `borg break-lock` recovery in the wrapper header comment (manual, not
  automated — break-lock on a *live* server is dangerous).

### Behavior 4: Verification / `--check` (client)

Runs unprivileged (warns when not root; timer/service checks are most useful with sudo).
Report, exit non-zero on first failure:
1. borg installed (version); 2. passphrase file exists (0600); 3. repo reachable —
   `borg list` works; 4. timer `active` + `systemctl list-timers` next elapse; 5. last service
   run status (most recent result); 6. latest snapshot name/size/time;
   7. (optional `--full`) `borg check --verify-data` (slow — reads all data; borg 1.x name
   for the full read-data check).

## Testing

Repo has no bash unit-test framework (parity with other features): verification =
`shellcheck` + `bash -n` + `--help`/`--check` smoke runs + the manual scenario table below +
live fleet validation (≥ 2 clean daily timer runs per client, `journalctl` reviewed).
A manual local-mode loopback flow against a virt-runner VM (pre-step: tmpfs "backup
drive" + fstab entry; exact command sequence in
[docs/plans/backup-feature-review-fixes.md](../../docs/plans/backup-feature-review-fixes.md)
§T2) validates T1.1 / T1.3 / T2.2 / T2.3 / T2.5 / T2.6.

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T1.1 | Server script on a machine with a mounted, fstab-persistent drive | Installs borg, creates/verifies layout, green summary, exit 0 |
| T1.2 | Server script with `BACKUP_MOUNT` pointing at an unmounted dir | Abort with fstab/mount instruction, no changes made |
| T1.3 | Re-run server script | All steps "already present/skipped", exit 0 |
| T1.4 | Server script with `BACKUP_USER` set to a different existing user | That user is added to the group, layout owned accordingly |
| T2.1 | Client script where key auth to server:port is not set up | Abort at SSH preflight with ssh-copy-id instructions, no repo created |
| T2.2 | Client script, correct keys, fresh repo | Repo initialized, passphrase file 0600, timer active, exit 0 |
| T2.3 | Re-run client script (repo exists, passphrase present) | Repo skip, units regenerated, timer untouched, passphrase file **not** rewritten |
| T2.4 | Re-run client script after `rm ~/.config/borg/<client>.pass` | Abort with "restore passphrase" message, repo untouched |
| T2.5 | `--initial` with a small path set | Full run completes in foreground, 1 snapshot listed |
| T2.6 | Local mode: repo on a local path, no host configured | Repo created locally, same wrapper/timer behavior |
| T3.1 | Small file change + manual `create` | Second snapshot; transferred bytes ≪ snapshot size (dedup working) |
| T3.2 | Two overlapping runs (lock) | Second run fails cleanly with lock message in journal; first completes |
| T3.3 | `prune` after > 8 `create` runs (shortened retention for test) | Retention honored (test values applied) |
| T4.1 | `restore` of 3 files incl. one only present in an older snapshot | Files match source byte-for-byte (sha256sum) |
| T4.2 | `--check` after all of the above | All green, exit 0 |
| T4.3 | `--check` with timer disabled | Non-zero exit, clear line pointing at the timer |

## Out of Scope / Future Work

Explicitly **not** in v1 (each is a candidate follow-up feature):

1. **Append-only / immutability mode** on the server repos (ransomware hardening: server-side
   read-only repo dir after init, `--append-only` creates; trade-off: `prune` must be handled
   via a scheduled privilege bump or a separate pruning repo layout).
2. **Dead-man's-switch monitoring** — Healthchecks.io ping from the wrapper (alert if a backup
   stops firing, not just errors); the `--check` modes are the hook for this.
3. **Offsite copy (the "1" of 3-2-1)** — the server is typically LAN-only; consider a nightly
   `borg replicate` to a cold drive or a remote S3/B2 target. Until then the strategy is
   effectively 2-2-0.
4. **Web GUI / fleet dashboard** — BorgBackup Server (BBS) if > 5 machines or non-Linux clients
   appear.
5. ~~**Docker-volume consistency**~~ — implemented in v1 as the *Docker service backup*
   section below (`BACKUP_SERVICES` / `BACKUP_STAGING_DIR` / `BACKUP_STOP_SERVICES` +
   `lib/docker-backup.sh`).
6. **Windows/macOS clients** — Borg runs on both (Windows natively, macOS via Homebrew); the
   client script would need a port, or a restic/kopia sibling feature.
7. **Server drive failure / replacement runbook** — re-init drive, `borg init` each repo, restore
   latest snapshot per client; document when the offsite copy exists.

8. **Drop-in per-service dump overrides** — `/srv/<svc>/backup.d/dump.sh`; the v1
   dispatcher (`bk_dump_service` in `lib/docker-backup.sh`) covers every in-repo
   service, drop-ins win once a service needs bespoke logic outside the dispatcher.
9. **Staging disk headroom check** before running dumps (a forgejo dump of large repo
   sets can be GBs); v1 relies on the drive's free-space warning.

## Docker service backup (v1, `lib/docker-backup.sh`)

Consistent backup of stateful Docker services (research:
docs/research/docker-volume-backup-research.md). Borg is file-level only — database
files copied mid-write are corrupt. The client wrapper therefore runs engine-level
dumps **before** `borg create`, staged into the same archive:

```
create =
  1. optional quiesce:  BACKUP_STOP_SERVICES -> docker compose stop (short window)
  2. staging clean/init: BACKUP_STAGING_DIR/dumps   (default /srv/backup-staging)
  3. per service in BACKUP_SERVICES: bk_dump_service (any failure aborts BEFORE create)
  4. borg create <BACKUP_PATHS...> <BACKUP_STAGING_DIR>
  5. borg prune --glob-archives '<client>-*'
  6. staging clean (success only; on failure dumps are kept for debugging)
  7. resume quiesced services
```

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_SERVICES` | *(empty)* | Comma list: `forgejo, planka, kestra, nextcloud, n8n, concourse, openwebui, omnigent`. Empty = plain file backup. |
| `BACKUP_STAGING_DIR` | `/srv/backup-staging` | Host dir holding dumps; must not be inside `BACKUP_PATHS` (appended as an explicit extra source). |
| `BACKUP_STOP_SERVICES` | *(empty)* | Services to `docker compose stop` / `up -d` around the whole run (opt-in raw-copy safety, e.g. `nextcloud`). |

Per-service dump/restore (implemented in `lib/docker-backup.sh`; DB names/credentials
are read back at run time — from each service's `.env` where the setup scripts write
them there, otherwise from the container env; the postgres DB names for
kestra/n8n/concourse come from the compose default (their compose uses the service
name as DB name) — nothing machine-specific is hardcoded):

| service | dump | restore (`restore-db <snap> <svc> --yes`) |
|---------|------|-------------------------------------------|
| forgejo | `forgejo dump --type zip` (DB + repos + LFS + config; works for sqlite **and** postgres) | zip → container, `forgejo restore` (container stopped for the window) |
| planka / kestra / n8n / concourse / omnigent | `pg_dump -Fc` from the service's postgres container (role/password from container env) | `pg_restore --clean --if-exists --no-owner -d <db>` |
| nextcloud | mariadb: `mysqldump --single-transaction`; postgres: `pg_dump -Fc`; sqlite: `sqlite3 .backup` (backend from `.env DB_TYPE` if present, else inferred from `.env` credentials / the `${CONTAINER}-db` image) | matching `mysql` / `pg_restore` / sqlite copy-back + restart |
| openwebui | `sqlite3 .backup` of the SQLite DB under `/app/backend/data` (`webui.db` by default; resolved via container `DATABASE_URL` / directory detection; fallback: brief stop → cp → start when the container lacks the sqlite3 CLI) | copy-back + restart |

Container names default to `<svc>` and are overridable for the backup side via
`<SVC>_CONTAINER` (`FORGEJO_CONTAINER`, `PLANKA_CONTAINER`, `NEXTCLOUD_CONTAINER`,
`OPENWEBUI_CONTAINER`). The service setup scripts bake their own `CONTAINER_NAME`
into the rendered compose, which is not recoverable at dump time — installs that
customized `CONTAINER_NAME` must mirror it into the matching `<SVC>_CONTAINER`.

Not in the dispatcher (raw file backup is sufficient — crash-consistent or low churn,
per research §3): monitoring (Prometheus TSDB, Grafana), netbird, dagu, hermes, etc.

**Restore** is never in-place: `restore <snap> [--dest DIR] [paths…]` extracts into a
fresh directory (borg 1.x extracts into the CWD). borg 1.x stores sources **without
the leading `/`** (`/etc` → `etc/…` in the archive): `paths…` are archive paths, and
the wrapper strips a leading `/` from the arguments; `restore-db` extracts the dumps
with the stripped pattern as well. `restore-db` is destructive and requires `--yes`.

### Implementation notes learned while building v1

- apt borg 1.x reads **`BORG_PASSPHRASE`** only (`*_FILE` variants and `--read-data`
  are borg 2.x): the wrapper reads `~/.config/borg/<client>.pass` into the env at run
  time; full integrity checks use `--verify-data`; `prune` uses `--glob-archives`.
- everything the **timer user** needs is prepared in its home: SSH preflight, repo
  init and the `--check` repo probes run as `BACKUP_USER` via
  `sudo -H -u <user> sh -c '…'` (passphrase read from its own file inside that
  shell — `sudo --preserve-env` is not portable: sudo-rs drops it silently, so
  `borg init` would fall into interactive prompts), so known_hosts acceptance and
  the borg chunk-cache live in the same home the daily service runs as (BatchMode
  would reject the first unattended run otherwise).
 - the staging dir (`/var/backup-staging` default) is created `sudo install -d -m 700
   -o <BACKUP_USER>` at setup: the wrapper creates only `dumps/` inside it —
   the timer user cannot create `/var/<dir>` itself. The default sits outside the
   typical `/etc /srv /home` scope so it never trips the "staging inside BACKUP_PATHS" guard.
- `docker exec` has no `-T` on Docker ≥ 29 (TTY is opt-in via `-t`) — the lib does not
  use it.
- `pg_dump` inside a container must connect as the container's `POSTGRES_USER` (some
  images run as root, e.g. kestra-postgres): the lib reads the role/password from the
  container env and connects over `127.0.0.1`.
- failed engine dumps delete their partial/0-byte output file (`bk_pg_dump`,
  `bk_mariadb_dump`, the `docker cp` paths) — `restore-db`'s newest-file glob can
  never pick up a broken dump.
- local-mode `create()` has a **mount guard**: setup bakes `REPO_MOUNT_SOURCE` (the
  device `findmnt` reports under the repo path at setup time) into the wrapper and
  aborts when it no longer matches, so an unmounted backup drive after a reboot
  cannot silently fill the root filesystem with borg chunks; re-run
  `setup-backup-client.sh` after fixing (or replacing) the mount.

## Rollout

Order: **server first, then clients** (any machine, in any order afterwards).

1. **Server machine**: `./tasks/setup-backup-server.sh` (no args) gives a working self-backup in
   local-disk mode with an auto-detected scope. For a real external drive, mount it first (or point
   `BACKUP_MOUNT`/`--mount` at an already-mounted, fstab-persistent path → drive mode). Verify with
   `--check`.
2. **Each client machine**: ensure key-based SSH to the server's backup port, then
   `sudo ./tasks/setup-backup-client.sh --host <server> --port <port> --user <user>
   --paths "<paths>" [--initial]` (omit `--paths`/`--services` to auto-detect). Move the generated
   passphrase to a password manager.
3. **Server self-backup** happens automatically in step 1 (local mode); `--no-self-backup` skips
   it if you want a storage-only host.
4. **Restore test** (scenario T4.1 in *Testing*) before declaring the setup done.

Recommended `BACKUP_PATHS` per machine type (the auto-detect already picks a close default; refine
with `--paths` as needed):

| Machine type | Recommended paths |
|--------------|-------------------|
| Ubuntu server (services) | `/home/<user> /etc /srv /var/lib/docker/volumes` (include docker volumes only if Docker is in use; volumes are not quiesced — Future Work 5) |
| Developer workstation | `/home/<user>` with the default excludes; add re-downloadable toolchain/model-binary dirs to `BACKUP_EXCLUDE_REGEXES` |
| Laptop | `/home/<user>` with the default excludes (first run can be large — use `--initial` deliberately) |

## References

- Borg docs: https://www.borgbackup.org/docs/usage.html (`borg init/create/prune/check/extract`,
  remote repositories, `BORG_PASSPHRASE`, `--one-file-system`, `--append-only`)
- Repo conventions: `specification/project/conventions.md`; pattern precedents:
  `specification/features/vllm-omni-setup/`, `tasks/setup-llama-swap.sh`
