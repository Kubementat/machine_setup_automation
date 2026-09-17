#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# lib/docker-backup.sh — Consistent Docker/database backup primitives
# =============================================================================
#
# PURPOSE:
#   Engine-level dumps for stateful Docker services, so a borg archive never
#   contains a database copied mid-write (see
#   docs/research/docker-volume-backup-research.md). Plain file data (blobs,
#   configs, TSDB, git repos at rest) is already handled by borg itself —
#   this library only handles the data that needs an engine dump.
#
#   Flow used by the backup wrapper (created by tasks/setup-backup-client.sh):
#     1. bk_staging_init / bk_staging_clean  -> fresh dumps dir
#     2. bk_dump_service <svc> per configured service (fail = abort before
#        'borg create', never archive partial dumps)
#     3. 'borg create' includes the staging dir as an explicit source path
#     4. bk_staging_clean after success (dumps are derived data)
#
# USAGE:
#   source lib/docker-backup.sh            # from the repo (task scripts)
#   source /usr/local/lib/borg-backup/docker-backup.sh   # installed wrapper
#
# NOTES:
#   - SELF-CONTAINED: no dependency on lib/helpers.sh — the installed copy
#     runs unattended under systemd where plain text lines are wanted.
#   - Every function RETURNS non-zero on failure and never exits the caller;
#     the caller decides (abort, retry, ...).
#   - Re-sourcing is safe (guarded definitions).
# =============================================================================

# ---------------------------------------------------------------------------
# Logging (plain, journal-friendly — no colours in unattended context)
# ---------------------------------------------------------------------------
if ! declare -F bk_log >/dev/null 2>&1; then
  bk_log() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
  }
fi

if ! declare -F bk_info  >/dev/null 2>&1; then bk_info()  { bk_log "INFO" "$@"; }; fi
if ! declare -F bk_warn  >/dev/null 2>&1; then bk_warn()  { bk_log "WARN" "$@"; }; fi
if ! declare -F bk_error >/dev/null 2>&1; then bk_error() { bk_log "ERROR" "$@" >&2; return 1; }; fi

# ---------------------------------------------------------------------------
# bk_docker_available
#   Requires docker CLI + a reachable daemon. Returns 1 (with a hint) when
#   unavailable — the caller decides whether docker is actually needed.
# ---------------------------------------------------------------------------
if ! declare -F bk_docker_available >/dev/null 2>&1; then
  bk_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
      bk_error "docker CLI not found — install Docker (tasks/setup-docker.sh) if this machine runs containerized services"
      return 1
    fi
    if ! docker info >/dev/null 2>&1; then
      bk_error "docker daemon is not reachable — try: sudo systemctl start docker"
      return 1
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# bk_service_env <home-dir> <key> <default>
#   Reads KEY=<value> from <home-dir>/.env (last occurrence wins, values
#   literal — same semantics as helpers.sh env_file_get). Prints the value or
#   the default when the file/key is absent.
# ---------------------------------------------------------------------------
if ! declare -F bk_service_env >/dev/null 2>&1; then
  bk_service_env() {
    local file="$1" key="$2" default="$3"
    [[ -f "${file}/.env" ]] || { printf '%s\n' "$default"; return 0; }
    local v
    v="$(sed -n "s/^[[:space:]]*${key}=//p" "${file}/.env" | tail -n1)"
    if [[ -n "$v" ]]; then printf '%s\n' "$v"; else printf '%s\n' "$default"; fi
  }
fi

# ---------------------------------------------------------------------------
# bk_staging_init <staging-dir> / bk_staging_clean <staging-dir>
#   Staging layout: <staging-dir>/dumps/<service>-<timestamp>.*
#   clean removes everything under dumps/ (find -delete: safe on empty dirs).
# ---------------------------------------------------------------------------
if ! declare -F bk_staging_init >/dev/null 2>&1; then
  bk_staging_init() {
    local dir="$1"
    mkdir -p "${dir}/dumps" || return 1
    bk_info "Staging dir: ${dir}/dumps"
    return 0
  }
fi

if ! declare -F bk_staging_clean >/dev/null 2>&1; then
  bk_staging_clean() {
    local dir="$1"
    [[ -d "${dir}/dumps" ]] || return 0
    find "${dir}/dumps" -mindepth 1 -delete || return 1
    return 0
  }
fi

# ---------------------------------------------------------------------------
# bk_wait_running <timeout-s> <container...>
#   Bounded wait until every container State.Status == running. Returns 1
#   (naming the laggards) on timeout or when a container is exited/dead.
# ---------------------------------------------------------------------------
if ! declare -F bk_wait_running >/dev/null 2>&1; then
  bk_wait_running() {
    local timeout="${1:-120}"; shift
    local waited=0 status bad c
    while (( waited <= timeout )); do
      bad=""
      for c in "$@"; do
        status="$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
        case "$status" in
          exited|dead|missing) bad+=" ${c}(${status})" ;;
          running) : ;;
          *) bad+=" ${c}(${status})" ;;
        esac
      done
      [[ -z "$bad" ]] && return 0
      (( waited == timeout )) && break
      sleep 3; waited=$(( waited + 3 ))
    done
    bk_error "Containers not running after ${timeout}s:${bad}"
    return 1
  }
fi

# ---------------------------------------------------------------------------
# Engine dump primitives
#   Each writes the dump file and returns non-zero (file may be partial) on
#   failure. All run inside the target container — no host DB clients needed.
# ---------------------------------------------------------------------------

# bk_pg_dump <container> <db-name> <out-file>
#   'pg_dump -Fc' (custom format) streamed to the host via 'docker exec'
#   (no TTY — output goes to the pipe). Connects as the container's own
#   POSTGRES_USER over localhost TCP with its POSTGRES_PASSWORD (read from
#   the container env) — works whether the container runs as root or as the
#   postgres user. PGPASSWORD is visible in 'ps' for the duration of the
#   dump (standard practice, e.g. borgmatic).
if ! declare -F bk_pg_dump >/dev/null 2>&1; then
  bk_pg_dump() {
    local container="$1" db="$2" out="$3"
    local pguser pgpw envs
    bk_info "pg_dump: ${db} (container: ${container}) -> ${out}"
    envs="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null || true)"
    pguser="$(sed -n 's/^POSTGRES_USER=//p' <<< "$envs" | tail -n1)"
    pgpw="$(sed -n 's/^POSTGRES_PASSWORD=//p' <<< "$envs" | tail -n1)"
    [[ -n "$pguser" ]] || pguser="postgres"
    if [[ -n "$pgpw" ]]; then
      docker exec -e PGPASSWORD="$pgpw" "$container" pg_dump -h 127.0.0.1 -U "$pguser" -Fc "$db" > "$out" || {
        bk_error "pg_dump failed for ${container}/${db}"
        rm -f "$out"
        return 1
      }
    else
      docker exec "$container" pg_dump -U "$pguser" -Fc "$db" > "$out" || {
        bk_error "pg_dump (no POSTGRES_PASSWORD in container env) failed for ${container}/${db}"
        rm -f "$out"
        return 1
      }
    fi
    [[ -s "$out" ]] || { bk_error "pg_dump produced an empty file: ${out}"; rm -f "$out"; return 1; }
    return 0
  }
fi

# bk_mariadb_dump <container> <db-name> <root-password> <out-file>
#   Single-transaction dump of a live MariaDB/MySQL database.
if ! declare -F bk_mariadb_dump >/dev/null 2>&1; then
  bk_mariadb_dump() {
    local container="$1" db="$2" rootpw="$3" out="$4"
    bk_info "mysqldump: ${db} (container: ${container}) -> ${out}"
    if ! docker exec "$container" mysqldump --single-transaction --routines --triggers -uroot -p"$rootpw" "$db" > "$out"; then
      bk_error "mysqldump failed for ${container}/${db}"
      rm -f "$out"
      return 1
    fi
    [[ -s "$out" ]] || { bk_error "mysqldump produced an empty file: ${out}"; rm -f "$out"; return 1; }
    return 0
  }
fi

# bk_sqlite_backup <container> <db-path-in-container> <out-file>
#   Prefers the online backup API: 'sqlite3 <db> ".backup ..."' (safe while
#   the engine writes). When the container has no sqlite3 CLI, falls back to
#   a brief stop -> docker cp -> start (consistent, seconds of downtime).
if ! declare -F bk_sqlite_backup >/dev/null 2>&1; then
  bk_sqlite_backup() {
    local container="$1" dbpath="$2" out="$3"
    bk_info "sqlite backup: ${container}:${dbpath} -> ${out}"
    if docker exec "$container" which sqlite3 >/dev/null 2>&1; then
      if ! docker exec "$container" sqlite3 "$dbpath" ".backup /tmp/bk-restore.sqlite" >/dev/null 2>&1; then
        bk_error "sqlite3 .backup failed in ${container} (${dbpath})"
        return 1
      fi
      docker cp "${container}:/tmp/bk-restore.sqlite" "$out" || {
        rm -f "$out"
        return 1
      }
      docker exec "$container" rm -f /tmp/bk-restore.sqlite || true
    else
      bk_warn "no sqlite3 CLI in ${container} — brief stop/copy/start for consistency"
      docker stop -t 10 "$container" >/dev/null || return 1
      if ! docker cp "${container}:${dbpath}" "$out"; then
        docker start "$container" >/dev/null || true
        bk_error "docker cp failed: ${container}:${dbpath}"
        rm -f "$out"
        return 1
      fi
      if ! docker start "$container" >/dev/null; then
        bk_error "${container} left stopped — start it manually"
        return 1
      fi
      bk_wait_running 60 "$container" || return 1
    fi
    [[ -s "$out" ]] || { bk_error "sqlite backup produced an empty file: ${out}"; rm -f "$out"; return 1; }
    return 0
  }
fi

# bk_sqlite_restore <container> <db-path-in-container> <dump-file>
#   Inverse of bk_sqlite_backup: brief stop, copy the file in, start.
if ! declare -F bk_sqlite_restore >/dev/null 2>&1; then
  bk_sqlite_restore() {
    local container="$1" dbpath="$2" file="$3"
    bk_info "sqlite restore: ${file} -> ${container}:${dbpath}"
    docker stop -t 10 "$container" >/dev/null || return 1
    if ! docker cp "$file" "${container}:${dbpath}"; then
      docker start "$container" >/dev/null || true
      bk_error "docker cp failed: ${container}:${dbpath}"
      return 1
    fi
    if ! docker start "$container" >/dev/null; then
      bk_error "${container} left stopped — start it manually"
      return 1
    fi
    bk_wait_running 60 "$container" || return 1
    return 0
  }
fi

# bk_pg_restore <container> <db-name> <dump-file>
#   Destructive: --clean --if-exists drops and re-creates every object.
#   Connects like bk_pg_dump (container's POSTGRES_USER over localhost).
if ! declare -F bk_pg_restore >/dev/null 2>&1; then
  bk_pg_restore() {
    local container="$1" db="$2" file="$3"
    local pguser pgpw envs
    bk_info "pg_restore: ${file} -> ${container}/${db} (DESTRUCTIVE)"
    envs="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null || true)"
    pguser="$(sed -n 's/^POSTGRES_USER=//p' <<< "$envs" | tail -n1)"
    pgpw="$(sed -n 's/^POSTGRES_PASSWORD=//p' <<< "$envs" | tail -n1)"
    [[ -n "$pguser" ]] || pguser="postgres"
    if [[ -n "$pgpw" ]]; then
      docker exec -e PGPASSWORD="$pgpw" -i "$container" pg_restore --clean --if-exists --no-owner -h 127.0.0.1 -U "$pguser" -d "$db" < "$file" || {
        bk_error "pg_restore failed for ${container}/${db}"
        return 1
      }
    else
      docker exec -i "$container" pg_restore --clean --if-exists --no-owner -U "$pguser" -d "$db" < "$file" || {
        bk_error "pg_restore failed for ${container}/${db}"
        return 1
      }
    fi
    return 0
  }
fi

# bk_mariadb_restore <container> <db-name> <root-password> <dump-file>
#   Destructive: drops and re-creates every table.
if ! declare -F bk_mariadb_restore >/dev/null 2>&1; then
  bk_mariadb_restore() {
    local container="$1" db="$2" rootpw="$3" file="$4"
    bk_info "mysql restore: ${file} -> ${container}/${db} (DESTRUCTIVE)"
    if ! docker exec -i "$container" mysql --force -uroot -p"$rootpw" "$db" < "$file"; then
      bk_error "mysql restore failed for ${container}/${db}"
      return 1
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# bk_openwebui_db <container>
#   Resolves the Open WebUI SQLite DB path INSIDE the container: the
#   DATABASE_URL env wins (sqlite:////abs/path, or sqlite:///relative resolved
#   against /app/backend), else a single *.db/*.sqlite file under
#   /app/backend/data (stock image default: /app/backend/data/webui.db).
#   Fails loudly when nothing can be resolved — dumping a nonexistent path
#   would make sqlite3 .backup silently create an EMPTY db.
# ---------------------------------------------------------------------------
if ! declare -F bk_openwebui_db >/dev/null 2>&1; then
  bk_openwebui_db() {
    local container="$1" envs url path
    envs="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null || true)"
    url="$(sed -n 's/^DATABASE_URL=//p' <<< "$envs" | tail -n1)"
    if [[ "$url" == sqlite:///* ]]; then
      path="${url#sqlite:///}"
      if [[ "$path" != /* ]]; then
        path="/app/backend/${path#./}"
      fi
      printf '%s\n' "$path"
      return 0
    fi
    path="$(docker exec "$container" sh -c 'ls /app/backend/data/*.db /app/backend/data/*.sqlite 2>/dev/null' | head -n1)"
    if [[ -n "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
    bk_error "cannot resolve Open WebUI SQLite DB in ${container}: no sqlite DATABASE_URL and no *.db/*.sqlite in /app/backend/data"
    return 1
  }
fi

# ---------------------------------------------------------------------------
# bk_service_home <service>
#   Home dir of a managed service — same defaults and env var names as the
#   corresponding tasks/setup-<service>.sh. Returns 1 for unknown services.
# ---------------------------------------------------------------------------
if ! declare -F bk_service_home >/dev/null 2>&1; then
  bk_service_home() {
    local svc="$1"
    case "$svc" in
      forgejo)   printf '%s\n' "${FORGEJO_HOME:-/srv/forgejo}" ;;
      planka)    printf '%s\n' "${PLANKA_HOME:-/srv/planka}" ;;
      kestra)    printf '%s\n' "${KESTRA_DIR:-/srv/kestra}" ;;
      nextcloud) printf '%s\n' "${NEXTCLOUD_HOME:-/srv/nextcloud}" ;;
      n8n)       printf '%s\n' "${N8N_DIR:-/srv/n8n}" ;;
      concourse) printf '%s\n' "${CONCOURSE_HOME:-/srv/concourse}" ;;
      openwebui) printf '%s\n' "${OPENWEBUI_HOME:-${PROJECT_DIR:-/srv/openwebui}}" ;;
      omnigent)  printf '%s\n' "${OMNIGENT_HOME:-/srv/omnigent}" ;;
      *) return 1 ;;
    esac
  }
fi

# ---------------------------------------------------------------------------
# bk_stack_quiesce <service> / bk_stack_resume <service>
#   Short-downtime quiesce for services whose raw data must not be copied
#   mid-write (BACKUP_STOP_SERVICES). Uses the service's own compose file.
#   quiesce: 'docker compose stop' (SIGTERM — graceful shutdown for DBs).
#   resume:  'docker compose up -d' + bounded wait for running.
# ---------------------------------------------------------------------------
if ! declare -F bk_stack_quiesce >/dev/null 2>&1; then
  bk_stack_quiesce() {
    local svc="$1" home
    home="$(bk_service_home "$svc")" || { bk_error "unknown service for quiesce: ${svc}"; return 1; }
    bk_docker_available || return 1
    local compose_file="${home}/docker-compose.yml"
    [[ -f "$compose_file" ]] || { bk_error "no compose file: ${compose_file}"; return 1; }
    bk_info "quiescing ${svc} (docker compose stop in ${home})"
    docker compose -f "$compose_file" stop || return 1
    return 0
  }
fi

if ! declare -F bk_stack_resume >/dev/null 2>&1; then
  bk_stack_resume() {
    local svc="$1" home
    home="$(bk_service_home "$svc")" || { bk_warn "unknown service for resume: ${svc}"; return 1; }
    bk_docker_available || return 1
    local compose_file="${home}/docker-compose.yml"
    [[ -f "$compose_file" ]] || { bk_warn "no compose file: ${compose_file} — start ${svc} manually"; return 1; }
    bk_info "resuming ${svc} (docker compose up -d in ${home})"
    docker compose -f "$compose_file" up -d || return 1
    local -a ids
    # -aq: include exited/created containers — wait_running must flag a
    # container that exited instantly after 'up -d', not report resume success.
    mapfile -t ids < <(docker compose -f "$compose_file" ps -aq)
    if (( ${#ids[@]} > 0 )); then
      bk_wait_running 120 "${ids[@]}" || return 1
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# Per-service dump dispatcher
#
# bk_dump_service <service> <staging-dir>
#   Writes <staging-dir>/dumps/<service>-<timestamp>.* . Returns non-zero on
#   any failure; the caller must abort the whole run before 'borg create'.
#
# Home dirs default to the setup-*.sh conventions (/srv/<name>) and can be
# overridden with the same env var names those scripts use. DB names and
# credentials are read back at dump time — from each service's .env where the
# setup scripts write them there, otherwise from the container env; the
# POSTGRES_DB names for kestra/n8n/concourse fall back to the compose-default
# (their compose sets the DB name to the service name).
# ---------------------------------------------------------------------------
if ! declare -F bk_dump_service >/dev/null 2>&1; then
  bk_dump_service() {
    local svc="$1" staging="$2"
    local ts dump
    ts="$(date '+%Y-%m-%dT%H%M%S')"
    dump="${staging}/dumps/${svc}-${ts}"

    case "$svc" in
      forgejo)
        local c="${FORGEJO_CONTAINER:-forgejo}"
        if ! bk_docker_available; then return 1; fi
        # 'forgejo dump' is the official consistent backup: DB (sqlite OR
        # postgres) + git repos + LFS + attachments + config in one archive.
        # /tmp (not /data): the git user is not guaranteed write access to
        # /data on every layout, /tmp is always world-writable.
        bk_info "forgejo dump (container: ${c}) -> ${dump}.zip"
        if ! docker exec -u git "$c" forgejo dump --type zip --file "/tmp/forgejo-${ts}.zip" >/dev/null; then
          bk_error "forgejo dump failed in container ${c}"
          return 1
        fi
        if ! docker cp "${c}:/tmp/forgejo-${ts}.zip" "${dump}.zip"; then
          bk_error "docker cp of forgejo dump failed"
          rm -f "${dump}.zip"
          return 1
        fi
        docker exec -u git "$c" rm -f "/tmp/forgejo-${ts}.zip" || true
        ;;
      planka|kestra|n8n|concourse|omnigent)
        local home container db
        bk_docker_available || return 1
        home="$(bk_service_home "$svc")" || return 1
        case "$svc" in
          planka)    container="${PLANKA_CONTAINER:-planka}-postgres" ;;
          kestra)    container="kestra-postgres" ;;
          n8n)       container="n8n-postgres" ;;
          concourse) container="concourse-db" ;;
          omnigent)  container="omnigent-postgres" ;;
        esac
        # POSTGRES_DB is usually absent from .env: the kestra/n8n/concourse
        # compose files default the DB name to the service name — the "$svc"
        # fallback relies on that compose convention.
        db="$(bk_service_env "$home" POSTGRES_DB "$svc")"
        bk_pg_dump "$container" "$db" "${dump}.dump"
        ;;
      nextcloud)
        local nchome ncc="${NEXTCLOUD_CONTAINER:-nextcloud}"
        bk_docker_available || return 1
        nchome="$(bk_service_home nextcloud)" || return 1
        local dbtype dbnc dbimg
        dbtype="$(bk_service_env "$nchome" DB_TYPE "")"
        if [[ -z "$dbtype" ]]; then
          # setup-nextcloud.sh writes no DB_TYPE: infer the backend from the
          # .env credentials and the db container image.
          if [[ -n "$(bk_service_env "$nchome" MYSQL_ROOT_PASSWORD "")" ]]; then
            dbtype="mariadb"
          else
            dbimg="$(docker inspect --format '{{.Config.Image}}' "${ncc}-db" 2>/dev/null || true)"
            if [[ "$dbimg" == *postgres* ]]; then
              dbtype="postgres"
            elif [[ "$dbimg" == *mariadb* || "$dbimg" == *mysql* ]]; then
              dbtype="mariadb"
            elif [[ -z "$dbimg" ]]; then
              dbtype="sqlite"
            else
              bk_error "cannot infer nextcloud DB backend from image '${dbimg}' — set DB_TYPE in ${nchome}/.env"
              return 1
            fi
          fi
        fi
        dbnc="$(bk_service_env "$nchome" POSTGRES_DB nextcloud)"
        case "$dbtype" in
          postgres) bk_pg_dump "${ncc}-db" "$dbnc" "${dump}.dump" ;;
          mariadb)
            local mwp mdb
            mwp="$(bk_service_env "$nchome" MYSQL_ROOT_PASSWORD "")"
            [[ -n "$mwp" ]] || { bk_error "no MYSQL_ROOT_PASSWORD in ${nchome}/.env — cannot dump nextcloud (mariadb)"; return 1; }
            mdb="$(bk_service_env "$nchome" MYSQL_DATABASE nextcloud)"
            bk_mariadb_dump "${ncc}-db" "$mdb" "$mwp" "${dump}.sql"
            ;;
          sqlite) bk_sqlite_backup "$ncc" "/var/www/html/data/nextcloud.db" "${dump}.sqlite" ;;
          *) bk_error "unsupported nextcloud DB_TYPE: ${dbtype}"; return 1 ;;
        esac
        ;;
      openwebui)
        local owuc="${OPENWEBUI_CONTAINER:-openwebui}" owdb
        bk_docker_available || return 1
        owdb="$(bk_openwebui_db "$owuc")" || return 1
        bk_sqlite_backup "$owuc" "$owdb" "${dump}.sqlite"
        ;;
      *)
        bk_error "unknown service for dumping: ${svc} (supported: forgejo, planka, kestra, nextcloud, n8n, concourse, openwebui, omnigent)"
        return 1
        ;;
    esac
  }
fi

# ---------------------------------------------------------------------------
# Per-service DB restore dispatcher
#
# bk_restore_db <service> <dump-file>
#   Destructive (documented at every call site). The dump file is one of the
#   <service>-<ts>.* files produced by bk_dump_service.
# ---------------------------------------------------------------------------
if ! declare -F bk_restore_db >/dev/null 2>&1; then
  bk_restore_db() {
    local svc="$1" file="$2"
    [[ -f "$file" ]] || { bk_error "dump file not found: ${file}"; return 1; }

    case "$svc" in
      forgejo)
        local home="${FORGEJO_HOME:-/srv/forgejo}" c="${FORGEJO_CONTAINER:-forgejo}"
        bk_docker_available || return 1
        local name ts_part
        name="$(basename "$file")"                 # forgejo-<ts>.zip
        ts_part="${name#forgejo-}"; ts_part="${ts_part%.zip}"
        bk_info "forgejo restore: ${file} (DESTRUCTIVE — stops ${c}, wipes data, re-creates from dump)"
        docker stop -t 10 "$c" >/dev/null || return 1
        if ! docker cp "$file" "${c}:/tmp/forgejo-${ts_part}.zip"; then
          docker start "$c" >/dev/null || true
          bk_error "docker cp of forgejo dump into ${c} failed"
          return 1
        fi
        if ! docker exec -u git "$c" forgejo restore --type zip --file "/tmp/forgejo-${ts_part}.zip" >/dev/null; then
          docker start "$c" >/dev/null || true
          bk_error "forgejo restore failed — container left stopped for inspection"
          return 1
        fi
        docker exec -u git "$c" rm -f "/tmp/forgejo-${ts_part}.zip" || true
        docker start "$c" >/dev/null || return 1
        bk_wait_running 120 "$c" || return 1
        ;;
      planka|kestra|n8n|concourse|omnigent|nextcloud)
        local home container db
        case "$svc" in
          planka)    home="${PLANKA_HOME:-/srv/planka}";    container="${PLANKA_CONTAINER:-planka}-postgres" ;;
          kestra)    home="${KESTRA_DIR:-/srv/kestra}";     container="kestra-postgres" ;;
          n8n)       home="${N8N_DIR:-/srv/n8n}";           container="n8n-postgres" ;;
          concourse) home="${CONCOURSE_HOME:-/srv/concourse}"; container="concourse-db" ;;
          omnigent)  home="${OMNIGENT_HOME:-/srv/omnigent}";   container="omnigent-postgres" ;;
          nextcloud) home="${NEXTCLOUD_HOME:-/srv/nextcloud}"; container="${NEXTCLOUD_CONTAINER:-nextcloud}-db" ;;
        esac
        bk_docker_available || return 1
        case "$file" in
          *.dump)
            db="$(bk_service_env "$home" POSTGRES_DB "$svc")"
            [[ "$svc" == nextcloud ]] && db="$(bk_service_env "$home" POSTGRES_DB nextcloud)"
            bk_pg_restore "$container" "$db" "$file"
            ;;
          *.sql)
            local mwp mdb
            mwp="$(bk_service_env "$home" MYSQL_ROOT_PASSWORD "")"
            [[ -n "$mwp" ]] || { bk_error "no MYSQL_ROOT_PASSWORD in ${home}/.env — cannot restore nextcloud (mariadb)"; return 1; }
            mdb="$(bk_service_env "$home" MYSQL_DATABASE nextcloud)"
            bk_mariadb_restore "$container" "$mdb" "$mwp" "$file"
            ;;
          *.sqlite)
            if [[ "$svc" == nextcloud ]]; then
              bk_sqlite_restore "${NEXTCLOUD_CONTAINER:-nextcloud}" "/var/www/html/data/nextcloud.db" "$file"
            else
              bk_error "sqlite restore not supported for service: ${svc}"
              return 1
            fi
            ;;
          *) bk_error "unrecognized dump file type: ${file}"; return 1 ;;
        esac
        ;;
      openwebui)
        local owuc="${OPENWEBUI_CONTAINER:-openwebui}" owdb
        bk_docker_available || return 1
        owdb="$(bk_openwebui_db "$owuc")" || return 1
        bk_sqlite_restore "$owuc" "$owdb" "$file"
        ;;
      *)
        bk_error "unknown service for restore: ${svc}"
        return 1
        ;;
    esac
  }
fi
