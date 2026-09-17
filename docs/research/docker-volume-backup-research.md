# Docker Volume & Database Backup with Borg — Research Document

Research date: 2026-09
Goal: solve the open item in `specification/features/setup-backup-server.md` (Future Work 5):
how to back up Docker container data/volumes **consistently** — in particular the databases of
the managed deployments (Forgejo, Planka, Kestra, Nextcloud, n8n, Concourse, …).

Precondition reviewed: the existing, working borg solution in
`/home/verfeinerer/dev/os_projects/script_collection/backup_utils/`
(`borg_backup.sh`, `check_backup_state.sh`, `borg_restore.sh`, `install_borg.sh`, timer units).

Sources verified:
- Borg docs: https://borgbackup.readthedocs.io/en/stable/quickstart.html ("Borg does not do
  anything about the internal consistency of the data it backs up")
- Borgmatic: https://torsion.org/borgmatic/how-to/backup-your-databases/ (best-practice
  statement, container DB dumping, `docker exec … pg_dump` pattern, streaming dumps)
- BorgBase: https://docs.borgbase.com/setup/borg/containers, /setup/borg/databases
- Forgejo: https://forgejo.org/docs/v15.0/admin/command-line/ (`forgejo dump`), admin upgrade guide
- SQLite: `sqlite3 .backup` online backup API (multiple sources; plain `cp` of a live DB is unsafe)
- PostgreSQL/docker: docker-library/postgres issues #1207, #184 (SIGTERM stop = graceful fast
  shutdown; SIGKILL leaves crash-recoverable state via WAL replay)
- n8n: https://docs.n8n.io/deploy/host-n8n/configure-n8n/choose-n8ns-database (SQLite default,
  Postgres optional, `/home/node/.n8n` must always be persisted incl. encryption key)

---

## 1. What the existing backup_utils already solves

The `backup_utils` solution already implements, and works in production:

| Concern | Status |
|---|---|
| Client-push over SSH (`ssh://user@host:port/...`), `BORG_RSH` fixed | done |
| Per-machine repo naming (`<hostname>-main`), local + remote mode | done |
| `borg init -e repokey`, create/prune/list, retention 7/4/12 | done |
| Passphrase via `BORG_PASSPHRASE`/`BORG_NEW_PASSPHRASE` env (no history leak) | done |
| systemd timer + service template, `Persistent=true` + jitter | done |
| Read-only health check (freshness, retention, sizes, scheduler, log errors, opt-in `borg check`) | done (`check_backup_state.sh`) |
| Restore wrapper (`borg extract` into target dir) | done (`borg_restore.sh`) |
| Append-only mode option | done |

Gaps vs. the spec / open problem:

1. **No consistency handling for databases / live volumes** — `BACKUP_DIRS` is a flat path list;
   backing up `/var/lib/docker/volumes` or `/srv` copies DB files mid-write.
2. Passphrase file on disk is env-file based (`borg_backup.env.local`); the spec's
   `~/.config/borg/<client>.pass` + `BORG_PASSPHRASE_FILE` is slightly cleaner but equivalent.
3. No `--one-file-system` / default excludes (would matter if `/srv` or `/` is in `BACKUP_DIRS`).
4. Restore has no per-file / per-service sub-selection (borg supports path filters; not wired).

**Conclusion:** the transport/scheduling/retention layer is solved and should be the base for the
new feature scripts. The only real open problem is consistent Docker/DB backup.

---

## 2. The core problem (what the web research confirms)

- Borg is a **file-level** archiver. Official docs: *"Borg does not do anything about the internal
  consistency of the data it backs up. It just reads and backs up each file in whatever state
  that file is in when Borg gets to it."*
- Relational DB files (Postgres, MySQL) and SQLite files are **not safe to `cp` while the engine
  writes**. The consistent alternatives, in order of preference found in the sources:
  1. **Logical dump** produced by the engine itself (`pg_dump`, `sqlite3 .backup`, `forgejo dump`)
     — consistent snapshot, compact, version-tolerant at restore. This is the borgmatic/BorgBase
     best-practice recommendation: *"backup an exported database dump, rather than backing up your
     database's internal file storage."*
  2. **Clean quiesce** (stop container → raw copy → start): `docker stop` sends SIGTERM; the
     official postgres entrypoint performs a graceful fast shutdown, after which the raw data dir
     is consistent. Downside: downtime window; note docker-library/postgres#1207 (stop during
     startup can SIGKILL → corruption) — stop only after health/ready.
  3. **Raw copy while running** — acceptable *only* for crash-consistent data (Prometheus TSDB,
     plain file storage, git repos at rest, config files). Postgres technically crash-recoverable
     (WAL replay on next start) but not recommended as primary strategy.

- **Ordering matters**: dump DBs *first*, then run `borg create` over the files. That way file
  states in the archive are ≥ the dump's point-in-time (a DB referencing a file that exists in the
  archive). borgmatic achieves the same by streaming dumps into the same archive.

- **Borg-specific plumbing note**: borgmatic streams dumps via `--read-special` fakes; in plain
  bash the simpler, equally valid pattern is *dump-to-staging-dir*, where the staging dir is one
  of the `borg create` source paths. Staging files then live inside the archive next to the rest
  of the data, and are deleted after a successful create. (No `--read-special`, no hang risk.)

---

## 3. Service-by-service matrix (this repo's deployments)

Data layout as produced by the current `tasks/setup-*.sh` + `templates/*`:

| Service | Data location | Engine | Recommended strategy | Restore |
|---|---|---|---|---|
| **Forgejo** | `/srv/forgejo/data` (repos + LFS + attachments + sqlite/postgres per `DB_TYPE`), optional `/srv/forgejo/postgres` | SQLite (default) or Postgres | **`forgejo dump`** (official CLI: DB + repos + config + LFS + packages in one zip/tar) → staging. `docker exec -u git <forgejo-c> forgejo dump --type zip --file /data/tmp-dump/forgejo-<ts>.zip`, then move to staging. Works for both DB types; handles the sqlite/postgres split itself. | `forgejo restore` (or extract zip + `pg_restore`/sqlite copy into fresh stack) |
| **Planka** | `$PLANKA_HOME/data` (board files/attachments), `$PLANKA_HOME/postgres` | Postgres | `pg_dump -Fc` from the postgres container + raw `data` dir (file storage; raw ok). Optional: stop planka app container for a few seconds for perfect file consistency. | `pg_restore -Fc` into recreated db container + files back |
| **Kestra** | named vols `kestra-postgres-data`, `kestra-data:/app/storage` | Postgres + file storage | `pg_dump -Fc` + raw `/app/storage` (flows/executions files; raw ok) | same pattern |
| **Nextcloud** | `/srv/nextcloud/{html,data,db}` | Postgres (or SQLite) + user files | `pg_dump -Fc` + raw `data` dir. Nextcloud file locking: safest with app container stopped during the copy window (short); raw copy while running is common practice and acceptable if dumps are fresh. | `pg_restore` + data dir back, run `occ:filesystem:check` after |
| **n8n** | named vols `n8n_data` (`/home/node/.n8n`), `pg_data` | Postgres (per template) — SQLite if `DB_TYPE=sqlite3` | `pg_dump -Fc` (or `sqlite3 .backup` on `database.sqlite` for sqlite mode) + raw `.n8n` dir. **Critical: `.n8n` holds the encryption key for credentials — never back up only the DB.** | `pg_restore` + `.n8n` back (key must match) |
| **Concourse** | named vol `concourse-db-data` | Postgres | `pg_dump -Fc` (web+worker share it) | `pg_restore` |
| **Open WebUI** | named vol `openwebui_data:/app/backend/data` | SQLite (in `data`) + uploads | `sqlite3 .backup` of the db file from the container (or stop container briefly) + raw uploads | copy db file + uploads back |
| **Monitoring** | `${PROMETHEUS_HOME}/data` (TSDB), `${GRAFANA_HOME}/data` (grafana.db sqlite + dashboards) | TSDB / SQLite | Prometheus TSDB: **raw copy ok** (crash-consistent design). Grafana: raw copy ok for low traffic; optionally stop grafana container for the window. | raw restore |
| **NetBird** | named vols `netbird-data`, `netbird-client` | state/config | raw copy ok | raw restore |
| **Omnigent** | named vols `postgres-data`, `artifact-data` | Postgres + artifacts | `pg_dump -Fc` + raw artifacts | same |
| **Dagu** | `${DAGU_DATA_DIR}` | SQLite + definitions | raw copy ok (low churn) or stop container | raw restore |
| **Hermes / host tools** | `/srv/hermes` (bind mount) | files | raw copy (part of `/srv`) | raw restore |

Pattern: **every stateful service needs at most one engine-level dump; everything else is plain
files that borg already handles.**

---

## 4. Recommended design (fits spec Decision 1: plain borg, bash)

Extend the client-side wrapper with a **pre-create dump staging** step:

```
create =
  1. mkdir -p $BACKUP_STAGING_DIR/dumps      (default: /srv/backup-staging)
  2. run each configured service dumper      (drop-ins, see below)
  3. borg create <repo>:<client>-<ts> <BACKUP_PATHS...> $BACKUP_STAGING_DIR
  4. borg prune --prefix <client>- --keep-...
  5. rm -rf $BACKUP_STAGING_DIR/dumps/*      (trap: keep on failure for debugging)
```

Configuration (env vars, repo convention):

| Variable | Default | Description |
|---|---|---|
| `BACKUP_SERVICES` | *(empty)* | Comma-separated list, e.g. `forgejo,kestra,n8n`. Empty = no dumps (plain file backup, current behavior). |
| `BACKUP_STAGING_DIR` | `/srv/backup-staging` | Host dir holding dumps before `create`; must not itself be inside a backed-up path (it is appended as an explicit path, not discovered). |
| `BACKUP_STOP_SERVICES` | *(empty)* | Optional: services to `docker compose stop`/`up -d` around the whole run (quiesce mode, e.g. `nextcloud`) — short downtime, guarantees file-level consistency where raw-copy-mid-write is unacceptable. |

Implementation (repo conventions):

1. **`lib/docker-backup.sh`** — shared primitives, sourced by the wrapper (matches "check `lib/`
   first" rule):
   - `db_pg_dump <compose-file> <db-service> <dbname> <out>` →
     `docker compose -f … exec -T <db-service> pg_dump -Fc <dbname> > <out>`
     (no host psql client needed; streams out).
   - `db_sqlite_backup <container> <db-path-in-container> <out>` →
     `docker exec -T <c> sqlite3 <db-path> ".backup /tmp/b"` + `docker cp` (`.backup` = online
     backup API, safe while running; never plain `cp`).
   - `stack_quiesce <compose-dir> [svc…]` / `stack_resume …` with health-wait before stop
     (avoids the postgres#1207 start-window SIGKILL trap).
   - `staging_dir`/`staging_clean` helpers.
2. **Per-service dumper drop-ins**: `/srv/<service>/backup.d/dump.sh` (or a single
   `lib/service-dump.sh` with a `case $service in` dispatcher — prefer the dispatcher in v1 for
   simplicity; drop-ins win once services need bespoke logic). The dispatcher knows per-service:
   compose file location (already a per-service `_HOME` default in each `setup-*.sh`), db service
   name, db name, extra raw paths. The dump *definitions* live next to the service setup script's
   knowledge — no machine-specific values hardcoded in the wrapper.
3. **Wrapper `create` subcommand** calls the dumper loop before `borg create` (step 2 above).
   Failure of any dumper aborts the run before `create` (never create an archive with partial
   dumps).
4. **Restore path**: `restore <snapshot> [paths…]` already extracts into a scratch dir; dumps land
   under `<dest>/…/backup-staging/dumps/…`. Add `restore-db <snapshot> <service>` to the wrapper:
   extract the dump, then per-service restore command (e.g. `docker compose exec -T db pg_restore
   --clean --if-exists -d <db> - < dump`), clearly documented as destructive, with `--yes` gate.
5. **Idempotency**: staging dir is transient and always wiped; dumps are derived data — safe to
   regenerate on re-run (same rule as units).

### Alternatives considered & rejected (v1)

| Alternative | Why not |
|---|---|
| Per-service **borgmatic** (built-in DB hooks, streaming) | Spec Decision 1 chose plain borg (bash-only, apt version-pairing). borgmatic's `postgresql_databases` + `pg_dump_command: docker exec …` would be a drop-in *future* upgrade path (spec Future Work already anticipates it). |
| **Stop everything, raw-copy volumes** | Fully consistent and simplest, but daily downtime for all stateful services; overkill where a 2-line logical dump suffices. Kept as opt-in `BACKUP_STOP_SERVICES` for the 1–2 services where raw-copy is genuinely risky. |
| `--read-special` fake-file streaming (borgmatic trick) | Requires faking special files + hang risk; staging dir achieves the same archive layout with plain files. |
| `docker commit` / `docker export` | Captures container *filesystem* (incl. image layers), not a supported backup format; restore is opaque. Rejected. |
| Back up `/var/lib/docker/volumes` raw only | Inconsistent DBs (the exact open problem). Rejected as sole strategy; raw is used for non-DB volumes. |

---

## 5. Open questions / decisions for the spec update

1. **Spec change**: promote Future Work 5 from "out of scope" to a first-class section
   ("Docker service backup") with `BACKUP_SERVICES`/`BACKUP_STAGING_DIR`/`BACKUP_STOP_SERVICES`
   and the lib primitives — or ship as follow-up feature after the base scripts land.
   *Recommendation: follow-up feature (keeps v1 scope tight; base scripts unchanged — they already
   accept `/srv` + explicit staging path as `BACKUP_PATHS`).*
2. Per-service default dump definitions (which compose file, which db service/db name) — need to be
   read from each `setup-<svc>.sh` defaults (already there: `_HOME` dirs, container names).
3. Retention of raw volume copies: if a service uses both a dump *and* its raw volume is inside
   `BACKUP_PATHS`, decide whether to exclude the raw DB dir from the file backup to avoid
   storing inconsistent copies (e.g. exclude `/srv/planka/postgres` when a `pg_dump` exists).
4. Staging disk headroom check before running dumps (forgejo dump of big repo sets can be GBs).
5. n8n: verify `DB_TYPE` actually in use per host (template supports both) → dispatcher branches.
