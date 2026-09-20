# Task: Production-grade `tasks/setup-nextcloud.sh` (Postgres + Redis + cron, Traefik / LAN modes)

**Audience:** an implementation agent picking this up from scratch — every decision is already made here; execute without re-deciding.
**Goal:** rework `tasks/setup-nextcloud.sh` into a repo-conventional, production-grade Nextcloud setup: `nextcloud:<major>-apache` + PostgreSQL + authenticated Redis + cron sidecar, rendered from `templates/nextcloud/` (no inline templates), Traefik mode and LAN(direct) mode, secrets generated once and read back from `/srv/nextcloud/.env` (never rotated), `status.php` readiness gate, post-install `occ` hardening pass, ufw rules in LAN mode.

**Technical basis:** `docs/research/nextcloud-production-setup-research.md` (2026-09). Load the `karpathy-guidelines` skill before implementing. Read `AGENTS.md` (idempotency, templating, secrets, `/srv` layout, lint rules).

---

## 1. Decision: IMPROVE in place (restructure), do not replace

`tasks/setup-nextcloud.sh` (752 lines) has a battle-tested outer shell that matches repo conventions and must be **kept verbatim or near-verbatim**:

- cleanup trap with `STACK_CREATED_THIS_RUN` (lines 92–137),
- `--interactive` / `--help` arg parsing (lines 145–205),
- converge-by-default existing-stack handling incl. the admin-password divergence guard (lines 327–368),
- reuse-first secret resolution `_env_reuse` + `.env` backup-on-change via `sudo cmp` (lines 236–266, 387–428),
- pre-flight shape and `wait_for_healthy` gate (lines 279–321, 660–664),
- summary block layout.

What is **wrong** and gets rewritten:

1. **Compose generation via ~12 inline heredocs (lines 436–642)** — violates AGENTS.md *Templating* ("put template files in `templates/<component>`; DO NOT put inline templates into the bash scripts"). Replaced by two template files + `envsubst` (openwebui pattern).
2. **Missing pieces vs the research**: no cron sidecar, Redis without password and no `REDIS_HOST_*` wiring, no HSTS/redirectscheme/well-known-redirect fixes on the secure router, no upload/PHP tuning, no `occ` post-install pass, no `status.php` readiness, no ufw step, `NEXTCLOUD_INIT_HTACCESS` missing.
3. **Proxy handling contradicts the research**: current `APACHE_DISABLE_REWRITE_IP=1` + hard-coded `TRUSTED_PROXIES=172.16.0.0/12` is the documented pitfall (§5.3) — removed (see §2).
4. **Three DB backends (mariadb default, sqlite option)** — research §2 recommends PostgreSQL only (repo standard engine, no MariaDB isolation/binlog footguns, one `pg_dump -Fc` strategy). Multi-backend branches are deleted; a **compat guard** protects existing mariadb/sqlite installs (§6).

Why not a full rewrite: the trap/converge/secret machinery is exactly what the repo's re-run policy demands and is already correct (it carries ticket-12 fixes); a rewrite re-introduces risk in the parts that matter most (not destroying `/srv/nextcloud` data). Net diff: same file, same public var names where compatible, new template dir, deleted DB branches.

## 2. Target architecture

Compose stack (project dir `/srv/nextcloud`, compose project name `nextcloud` via directory name — keep it, the backup dispatcher expects the containers below):

| Service | Image (default) | Container name | Networks | Notes |
|---|---|---|---|---|
| `app` | `${NEXTCLOUD_IMAGE}` = `nextcloud:34-apache` | `nextcloud` (`CONTAINER_NAME`) | `nextcloud` (+ `proxy` traefik-mode only) | port 80 internal; the only container that ever touches `proxy` |
| `db` | `${NEXTCLOUD_DB_IMAGE}` = `postgres:16-alpine` (see §3 pin rule) | `nextcloud-db` | `nextcloud` | healthcheck `pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}`; volume `/srv/nextcloud/db:/var/lib/postgresql/data` |
| `redis` | `${NEXTCLOUD_REDIS_IMAGE}` = `redis:7-alpine` | `nextcloud-redis` | `nextcloud` | `command: ["redis-server", "--requirepass", "${REDIS_HOST_PASSWORD}"]` (literal `${VAR}` in the file, compose resolves from `.env` at `up` time — same mechanism as the existing `POSTGRES_PASSWORD` pattern); healthcheck `redis-cli -a "$$REDIS_PASSWORD" ping` with container env `REDIS_PASSWORD=${REDIS_HOST_PASSWORD}` |
| `cron` | `${NEXTCLOUD_IMAGE}` (same var ⇒ tags can never drift, research §9) | `nextcloud-cron` | `nextcloud` | `entrypoint: /cron.sh`, same volume set as `app`, `depends_on: app` |

- **Networks**: `nextcloud` (internal, `external: false`) always; `proxy` (`external: true`, `PROXY_NETWORK=proxy`) only in the traefik template. `db`/`redis`/`cron` publish no ports in either mode.
- **Bind mounts** (keep today's layout — *do not* add separate `config/`/`custom_apps/` mounts, they would shadow existing content on re-run of old installs):
  - `/srv/nextcloud/html:/var/www/html`
  - `/srv/nextcloud/data:/var/www/html/data`
  - plus `/etc/localtime:/etc/localtime:ro` (as today).
  - `html/`, `data/`, `db/` created `sudo mkdir -p`, `html`/`data` chowned to `33:33` (www-data).
- **Traefik mode** (`NEXTCLOUD_TRAEFIK=true`) — labels in the traefik template, `$$`-escaping exactly as noted:
  ```yaml
  - "traefik.enable=true"
  - "traefik.docker.network=${PROXY_NETWORK}"
  - "traefik.http.routers.nextcloud.rule=Host(`${NEXTCLOUD_DOMAIN}`)"
  - "traefik.http.routers.nextcloud.entrypoints=web"
  - "traefik.http.routers.nextcloud.middlewares=nextcloud-redirectscheme@docker,nextcloud-wellknown@docker"
  - "traefik.http.middlewares.nextcloud-redirectscheme.redirectscheme.scheme=https"
  - "traefik.http.middlewares.nextcloud-redirectscheme.redirectscheme.permanent=true"
  - "traefik.http.routers.nextcloud-secure.rule=Host(`${NEXTCLOUD_DOMAIN}`)"
  - "traefik.http.routers.nextcloud-secure.entrypoints=websecure"
  - "traefik.http.routers.nextcloud-secure.tls=true"
  - "traefik.http.routers.nextcloud-secure.tls.certresolver=letsencrypt"
  - "traefik.http.routers.nextcloud-secure.service=nextcloud"
  - "traefik.http.services.nextcloud.loadbalancer.server.port=80"
  - "traefik.http.middlewares.nextcloud-wellknown.redirectregex.regex=^https://(.*)/.well-known/(?:card|cal)dav"
  - "traefik.http.middlewares.nextcloud-wellknown.redirectregex.replacement=https://$${1}/remote.php/dav"
  - "traefik.http.middlewares.nextcloud-wellknown.redirectregex.permanent=true"
  - "traefik.http.middlewares.nextcloud-hsts.headers.stsSeconds=15552000"
  - "traefik.http.middlewares.nextcloud-hsts.headers.stsIncludeSubdomains=true"
  ```
  Attach `nextcloud-wellknown,nextcloud-hsts` to **both** routers is wrong — attach `nextcloud-redirectscheme,nextcloud-wellknown` to `web` and `nextcloud-wellknown,nextcloud-hsts` to `nextcloud-secure` (research §5 pitfall 1: the well-known middleware must be on the secure router). No `buffering`/body-limit/readTimeout middleware (research §5.5 — big uploads).
- **LAN mode** (default, `NEXTCLOUD_TRAEFIK != true`): `ports: - "${NEXTCLOUD_LAN_BIND:+${NEXTCLOUD_LAN_BIND}:}${HTTP_PORT}:80"` (optional bind-IP prefix per research §13; empty default = plain publish like `setup-openwebui.sh`), no labels.
- **Protocol / proxy env per app container**:
  - traefik template: `OVERWRITEPROTOCOL=https`, `OVERWRITECLIURL=https://${NEXTCLOUD_DOMAIN}`, `NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_TRUSTED_DOMAINS}` (computed, §3), `NEXTCLOUD_INIT_HTACCESS=true`. **No** `APACHE_DISABLE_REWRITE_IP` / `TRUSTED_PROXIES` — the apache image's X-Real-IP rewrite for RFC1918 sources works out of the box (research §5.3).
  - LAN template: no `OVERWRITE*` at all (forcing https breaks plain-LAN http, research §13); `NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_TRUSTED_DOMAINS}`, `NEXTCLOUD_INIT_HTACCESS=true`.
- **Common app env** (both templates): `NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}`, `NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}`, `NEXTCLOUD_DATA_DIR=/var/www/html/data`, `POSTGRES_HOST=db`, `POSTGRES_DB=${POSTGRES_DB}`, `POSTGRES_USER=${POSTGRES_USER}`, `POSTGRES_PASSWORD=${POSTGRES_PASSWORD}`, `REDIS_HOST=redis`, `REDIS_HOST_PORT=6379`, `REDIS_HOST_PASSWORD=${REDIS_HOST_PASSWORD}`, `PHP_MEMORY_LIMIT=${NEXTCLOUD_PHP_MEMORY_LIMIT}`, `PHP_UPLOAD_LIMIT=${NEXTCLOUD_UPLOAD_LIMIT}`, `APACHE_BODY_LIMIT=0`, SMTP block (`SMTP_HOST/PORT/SECURE/AUTHTYPE/NAME/PASSWORD`, `MAIL_FROM_ADDRESS`, `MAIL_DOMAIN` — all literal `${VAR}`, empty in `.env` when unset ⇒ image applies nothing).
- `restart: always` on all four services (keep, matches existing script/forgejo).

## 3. Configuration surface (final; `--help` + header must match exactly)

Mode selection stays the repo boolean `NEXTCLOUD_TRAEFIK` (consistent with every sibling script — **no** new `MODE` var; document it as the traefik|lan switch).

| Var | Default | Secret? | Notes |
|---|---|---|---|
| `NEXTCLOUD_HOME` | `/srv/nextcloud` | no | project dir |
| `NEXTCLOUD_TRAEFIK` | `false` | no | `true` ⇒ traefik mode |
| `NEXTCLOUD_DOMAIN` | `` (required with traefik) | no | |
| `NEXTCLOUD_TRUSTED_DOMAINS_EXTRA` | `` | no | space-separated, appended in traefik mode (research open-Q2: **yes**, include it — LAN IP + domain can coexist) |
| `PROXY_NETWORK` | `proxy` | no | |
| `HTTP_PORT` | `8080` | no | LAN mode host port |
| `NEXTCLOUD_LAN_BIND` | `` | no | optional bind IP prefix for the published port |
| `CONTAINER_NAME` | `nextcloud` | no | **do not change** if the backup dispatcher is used (it derives `nextcloud-db`); mention `<SVC>_CONTAINER` mirror note |
| `NEXTCLOUD_IMAGE` | `nextcloud:34-apache` | no | pinned; "update deliberately" comment + `warn_moving_image "${NEXTCLOUD_IMAGE}" NEXTCLOUD_IMAGE`; app+cron share it |
| `NEXTCLOUD_DB_IMAGE` | `postgres:16-alpine` | no | pin rule below |
| `NEXTCLOUD_REDIS_IMAGE` | `redis:7-alpine` | no | research open-Q4: **redis** (repo consistency), not valkey |
| `POSTGRES_DB` | `nextcloud` | no | |
| `POSTGRES_USER` | `nextcloud` | no | |
| `POSTGRES_PASSWORD` | generated 24-char | **secret** | `_env_reuse` read-back from `.env` — never rotated |
| `NEXTCLOUD_ADMIN_USER` | `admin` | no | |
| `NEXTCLOUD_ADMIN_PASSWORD` | generated 24-char | **secret** | `_env_reuse` + existing divergence guard kept |
| `REDIS_HOST_PASSWORD` | generated 24-char | **secret** | new; `_env_reuse` (rotation harmless — cache only — but still generated-once for stable `.env`) |
| `NEXTCLOUD_PHP_MEMORY_LIMIT` | `512M` | no | → `PHP_MEMORY_LIMIT` |
| `NEXTCLOUD_UPLOAD_LIMIT` | `512M` | no | research open-Q1: **512M default** (image default, no `post_max_size`×worker blow-up); → `PHP_UPLOAD_LIMIT`; `APACHE_BODY_LIMIT=0` (unlimited) so the chain never 413s below the PHP limit |
| `NEXTCLOUD_PHONE_REGION` | `DE` | no | occ `default_phone_region` |
| `SMTP_HOST` `SMTP_PORT` `SMTP_SECURE` `SMTP_AUTHTYPE` `SMTP_NAME` `MAIL_FROM_ADDRESS` `MAIL_DOMAIN` | `` | no | optional passthrough |
| `SMTP_PASSWORD` | `` | **secret** | via `.env` only |
| `WAIT_TIMEOUT` | `300` | no | used for both `wait_for_healthy` and the `status.php` poll (first-run install is slow — raised from 180) |

**Removed vars** (list them in `--help` under "Removed" so operators aren't surprised): `DB_TYPE`, `MYSQL_*`, `REDIS_ENABLED` (redis is now mandatory — file locking requires it, research §3).

**`NEXTCLOUD_DB_IMAGE` pin rule** (protects existing postgres-16 installs from a silent major-version datadir break): if `/srv/nextcloud/db/PG_VERSION` exists, default the image to `postgres:<that-major>-alpine`; else default `postgres:17-alpine`. Implement as a 4-line block; an explicit `NEXTCLOUD_DB_IMAGE` always wins.

**`NEXTCLOUD_TRUSTED_DOMAINS` computation** (exported for envsubst; non-secret layout):
- traefik: `"${NEXTCLOUD_DOMAIN} ${NEXTCLOUD_TRUSTED_DOMAINS_EXTRA}"`
- lan: `"${NEXTCLOUD_LAN_HOSTS:-${detected_primary_ip} localhost}"` — detect primary IP like forgejo (`ip route | grep default | awk '{print $2}'`), with optional override var `NEXTCLOUD_LAN_HOSTS` (space-separated: mDNS name, static IP).
Fixes the current bug where LAN-mode installs have no usable `trusted_domains` (image writes only `localhost`).

## 4. Template layout — `templates/nextcloud/` (new directory)

Two files, openwebui dot-style naming (also matches `opencode-server`):

- `templates/nextcloud/docker-compose.traefik.yml`
- `templates/nextcloud/docker-compose.direct.yml`

**envsubst-ed at render time** (non-secret layout only — render as the invoking user into a `mktemp` file, install with `sudo install -m 644`, never `sudo envsubst`; call envsubst with an explicit variable list like `setup-openwebui.sh:346`):
`GENERATED_DATE NEXTCLOUD_HOME CONTAINER_NAME NEXTCLOUD_IMAGE NEXTCLOUD_DB_IMAGE NEXTCLOUD_REDIS_IMAGE PROXY_NETWORK NEXTCLOUD_DOMAIN NEXTCLOUD_TRUSTED_DOMAINS HTTP_PORT NEXTCLOUD_LAN_BIND NEXTCLOUD_PHP_MEMORY_LIMIT NEXTCLOUD_UPLOAD_LIMIT`

**Kept literal `${VAR}`** (resolved at runtime by `docker compose --env-file /srv/nextcloud/.env`):
`NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDIS_HOST_PASSWORD SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_AUTHTYPE SMTP_NAME SMTP_PASSWORD MAIL_FROM_ADDRESS MAIL_DOMAIN`
(The `$$` in the redis healthcheck and the traefik `$${1}` regex are compose-level escapes — do not add them to the envsubst list.)

**No** `env.template` file needed: keep the existing `printf`-based `.env` writer (script lines 393–428) — it is already inline-config-generation in the script but is the established nextcloud pattern; changing it is out of scope. It must be extended per §3 (drop `MYSQL_*`, add `DB_TYPE=postgres` [see §7], `REDIS_HOST_PASSWORD`, SMTP keys) and stays backed-up-on-change / mode 600.

## 5. Script flow (target order, step by step)

Keep section order/colors/trap of the current script. Changes are marked ⇒.

1. `usage` + arg parse (`--interactive`, `-h/--help`) ⇒ full rewrite of help text to §3 surface + upgrade note.
2. Configuration block ⇒ §3 defaults; `_gen_password`, `_env_reuse` unchanged; ⇒ add `_env_reuse REDIS_HOST_PASSWORD REDIS_HOST_PASSWORD`; ⇒ drop MYSQL reuse.
3. Pre-flight: docker installed/daemon, compose v2 warn, `openssl`/`curl` (already implied) ⇒ add `envsubst` check (`gettext-base`, error names the remedy).
4. ⇒ **Backend compat guard (run before anything is modified)**: if `.env` exists and contains `MYSQL_ROOT_PASSWORD=`, or `${NEXTCLOUD_HOME}/data/nextcloud.db` exists ⇒ `error` with explicit text: this script version supports only PostgreSQL; existing MariaDB/SQLite install detected — migrate via Nextcloud's own tooling or pin the previous script revision. Nothing is touched, exit non-zero.
5. Traefik pre-flight (existing): `ensure_proxy_network` + require `NEXTCLOUD_DOMAIN`.
6. LAN pre-flight ⇒ port-in-use check (`ss -tln`) **only when no compose file exists yet** (converge case owns its own port).
7. Existing-stack handling / converge / admin-password divergence guard — unchanged.
8. Directories: `sudo mkdir -p ${NEXTCLOUD_HOME}/{html,data,db}` ⇒ `sudo chown 33:33 html data` (idempotent); db dir left to the postgres image.
9. `.env` write (printf + `cmp` backup + `sudo install -m 600`) per §3; content keys: `DB_TYPE=postgres`, `POSTGRES_DB/USER/PASSWORD`, `NEXTCLOUD_ADMIN_USER/PASSWORD`, `REDIS_HOST_PASSWORD`, `SMTP_*`/`MAIL_*` (possibly empty).
10. Render: pick template by mode; export the §4 layout list; `envsubst '<list>' < tmpl > "$(mktemp)"`; `sudo install -m 644` to `${NEXTCLOUD_HOME}/docker-compose.yml`.
11. `sudo docker compose -f … --env-file "$ENV_FILE" pull`.
12. `STACK_CREATED_THIS_RUN=1`; `… up -d`.
13. `mapfile` + `wait_for_healthy "${WAIT_TIMEOUT}" "${_ids[@]}" || error …` (db/redis healthchecks; app/cron count as ready when running).
14. ⇒ **Readiness gate (new)**: poll every 5s up to `WAIT_TIMEOUT`:
    `sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T app curl -sf http://localhost/status.php | grep -q '"installed":true'`.
    Failure ⇒ `error` (trap still armed ⇒ stack from *this run* torn down; volumes preserved). Only **after** this succeeds: `STACK_CREATED_THIS_RUN=0`.
15. ⇒ **Post-install `occ` pass** (each line `sudo docker compose … exec -T --user www-data app php occ config:system:set <k> --value=<v>`; never as root; failures `[ … ] || warn "occ <k> failed"` — never abort the script):
    `memcache.local '\OC\Memcache\APCu'` · `memcache.distributed '\OC\Memcache\Redis'` · `memcache.locking '\OC\Memcache\Redis'` · `default_phone_region "${NEXTCLOUD_PHONE_REGION}"` · `maintenance_window_start 1` · `loglevel 2`.
    Then best-effort (warn-only): `occ db:add-missing-indices`, `occ db:convert-filecache-bigint` (both `--no-interaction`).
    Idempotent by nature of `config:system:set`; runs on every converge (occ values win, research §6).
16. ⇒ **UFW** (new): traefik mode → nothing (no published ports). LAN mode → `ufw_firewall_section "Nextcloud" "${HTTP_PORT}" tcp "Nextcloud (LAN mode)"` (helpers.sh). Print the Docker/ufw FORWARD-chain caveat from research §13 (published ports bypass ufw INPUT; recommend `NEXTCLOUD_LAN_BIND`).
17. `trap - EXIT`; summary ⇒ extend: URL per mode, admin user + `sudo grep NEXTCLOUD_ADMIN_PASSWORD` hint, `curl -I <url>/.well-known/caldav` → 301 verification hint (traefik mode), HSTS hint, occ command hint, `pg_dump`/backup hint (`setup-backup-server.sh --services nextcloud`), upgrade policy note (§6 below).

## 6. Idempotency & upgrade behavior

- **Re-run converge**: same secret read-back (`.env` is source of truth; no rotation), re-render, `up -d`, health+readiness gates. All `/srv/nextcloud` data dirs reused, never deleted. The existing-stack section text ("your data is PRESERVED") stays true — the mount layout is unchanged, so nothing shadows existing content.
- **Mode switch** (lan → traefik or back) = re-run with the other `NEXTCLOUD_TRAEFIK` value: compose file re-rendered (ports↔labels), `NEXTCLOUD_TRUSTED_DOMAINS` and `OVERWRITEPROTOCOL` change. Known limitation, document in `--help`: env/occ-written values are **merged, never removed** — a stale `overwriteprotocol=https` from a previous traefik run persists in `config.php` and breaks plain-LAN access until manually fixed (`occ config:system:delete overwriteprotocol`); print this warning when switching traefik→lan (detect `OVERWRITEPROTOCOL`-era config via existing compose file containing `traefik.enable`).
- **Version pinning**: `NEXTCLOUD_IMAGE` default pinned to `nextcloud:34-apache` (research: stable = 34.0.4 as of 2026-09; `stable`/`latest` aliases risk skipping majors). `warn_moving_image` on override. Cron shares the var. **One-major-at-a-time** (33→34→35, never 33→35) + "backup before bump (`--services nextcloud`)" documented in `--help` header and final output. Script never auto-bumps.
- **Postgres datadir**: protected by the `PG_VERSION`-match rule in §3 (a re-run can never start a newer-major postgres against an older datadir by default).
- Secrets: `POSTGRES_PASSWORD`/`NEXTCLOUD_ADMIN_PASSWORD` read back before generation (existing `_env_reuse`); admin-password explicit-change guard preserved (exit 0 + remedy).

## 7. Backup integration (`lib/docker-backup.sh` — no dispatcher changes)

The dispatcher (`lib/docker-backup.sh:441–479`, `529–563`) expects: `${NEXTCLOUD_CONTAINER:-nextcloud}` and `${NEXTCLOUD_CONTAINER:-nextcloud}-db`, `POSTGRES_DB` in `/srv/nextcloud/.env` (fallback `nextcloud`), and writes/reads `.dump` for postgres. Our defaults satisfy all of it: `CONTAINER_NAME=nextcloud`, db container `${CONTAINER_NAME}-db`, `POSTGRES_DB` in `.env`.
**One required addition:** write `DB_TYPE=postgres` into `.env` (line 446–465: dispatcher reads `DB_TYPE` first; today it infers via image inspect, and the *comment* claims "setup-nextcloud.sh writes no DB_TYPE" — after this change it does, making the dump deterministic; if `NEXTCLOUD_DB_IMAGE` is overridden to a non-postgres image, the honest `DB_TYPE=postgres` + image-inspect fallback still behaves sanely).
Quiesce note (document in `--help` summary): for a crash-consistent window use `--stop-services nextcloud` (compose stop halts app **and** cron — cron must be stopped too or it keeps writing, research §12); logical `pg_dump -Fc` runs against the running `nextcloud-db` container.

## 8. Documentation updates

- `AUTOMATIONS.md` §"setup-nextcloud.sh" (line ~250): rewrite the one-liner — Postgres backend, Redis (locking/caching), cron sidecar, Traefik/LAN modes, secrets in `/srv/nextcloud/.env`, pinned `nextcloud:34-apache` "update one major at a time". Follow the `setup-n8n.sh` entry's bullet style.
- `README.md`: only the generic mention on line 41 exists — **no change** (matches cadvisor-plan minimalism).
- `machine-config.yml.example`: entry exists with `env: {}` — **no change** (image pins live in script headers only, repo convention).
- `tests/machine-config.test.yml`: add a **disabled** entry `setup-nextcloud: {enabled: false, env: {NEXTCLOUD_TRAEFIK: "false"}}` so `--scripts setup-nextcloud` picks up LAN-mode env (unknown scripts get empty env — the entry makes the ad-hoc run deterministic and documents the mode).

## 9. Testing plan

Static (host, all mandatory):
```bash
shellcheck tasks/setup-nextcloud.sh                     # clean
yamllint templates/nextcloud/                           # no findings (add .yamllint ignores only if the repo already has any for ${VAR} templates — check existing templates pass first)
bash -n tasks/setup-nextcloud.sh
bash tasks/setup-nextcloud.sh --help                    # exits 0, no side effects, text matches §3
```
Render/parse smoke (needs docker CLI only; no stack):
```bash
# LAN template parses + interpolates with a throwaway env
tmp=$(mktemp); NEXTCLOUD_HOME=/tmp/nc-test HTTP_PORT=8080 CONTAINER_NAME=nextcloud \
  NEXTCLOUD_IMAGE=nextcloud:34-apache NEXTCLOUD_DB_IMAGE=postgres:16-alpine \
  NEXTCLOUD_REDIS_IMAGE=redis:7-alpine NEXTCLOUD_TRUSTED_DOMAINS="127.0.0.1 localhost" \
  NEXTCLOUD_PHP_MEMORY_LIMIT=512M NEXTCLOUD_UPLOAD_LIMIT=512M GENERATED_DATE=x \
  envsubst '<exact §4 list>' < templates/nextcloud/docker-compose.direct.yml > "$tmp"
printf 'POSTGRES_PASSWORD=x\nREDIS_HOST_PASSWORD=x\nNEXTCLOUD_ADMIN_USER=admin\nNEXTCLOUD_ADMIN_PASSWORD=x\n' | \
  docker compose -f "$tmp" --env-file /dev/stdin config -q          # parse-ok, secrets stay ${VAR}
grep -q '\${POSTGRES_PASSWORD}' "$tmp"                              # literal kept in file
```
VM suite (`./tests/README.md` — fresh Ubuntu VM, every enabled script runs twice: integration + idempotency):
```bash
tests/run-vm-tests.sh --scripts setup-docker,setup-traefik,setup-nextcloud \
  --ram 6 --disk 40 --timeout 60 --keep-vm
```
(`setup-traefik` runs but nextcloud here is LAN-mode via the test-config env; `--keep-vm` for the manual checks.)
On the kept VM (`ssh ubuntu@<ip>`):
1. `docker ps` → exactly `nextcloud`, `nextcloud-db`, `nextcloud-redis`, `nextcloud-cron` running/healthy.
2. `curl -s http://<vm-ip>:8080/status.php` → `"installed":true`; login as `admin` with `sudo grep NEXTCLOUD_ADMIN_PASSWORD /srv/nextcloud/.env`.
3. Idempotency already covered by phase 2; additionally verify the `.env` and `docker-compose.yml` are byte-identical after phase 2 (`sha256sum` before/after) and the admin password still logs in.
4. `occ config:list system` (via `docker compose exec -T --user www-data app php occ config:list system --output=json | jq`) shows memcache.* set, `default_phone_region`, `maintenance_window_start: 1`.
5. `docker logs nextcloud-cron | grep -i cron` shows the 5-min loop.
6. `sudo ufw status verbose | grep 8080` → rule present.
Traefik mode (cannot run on the NAT VM — no DNS for the resolver): verify manually on the staging box with real DNS + shared traefik:
`NEXTCLOUD_TRAEFIK=true NEXTCLOUD_DOMAIN=cloud.<dom> ./tasks/setup-nextcloud.sh` then
`curl -I https://cloud.<dom>/.well-known/caldav` → `301 … /remote.php/dav`, `curl -I` shows `Strict-Transport-Security`, Nextcloud admin overview has no warnings, and the second (LAN) install above is *not* touched (separate project check: `docker compose ls`).

## 10. Verifiable success criteria

- [ ] `shellcheck`, `yamllint templates/nextcloud/`, `bash -n`, `--help` smoke all clean.
- [ ] Generated `/srv/nextcloud/docker-compose.yml` contains **no** secret values (grep: no `POSTGRES_PASSWORD=<literal>`), 4 services, correct mode (labels xor ports).
- [ ] `/srv/nextcloud/.env` mode 600, holds `DB_TYPE=postgres`, all §3 secrets; re-run byte-identical.
- [ ] Fresh LAN install: script exits 0, all 4 containers healthy, `status.php` `installed:true`, admin login works.
- [ ] Idempotent re-run: exits 0, no data loss, no secret rotation, no container duplication.
- [ ] `occ config:list system` shows the §5.15 settings; redis password active (`redis-cli -a … ping` → PONG, unauthenticated → error).
- [ ] LAN mode ufw rule present; traefik mode adds no ufw rule.
- [ ] Traefik mode on staging: `.well-known/caldav` → 301 to `/remote.php/dav`, HSTS header present, HTTP→HTTPS 301.
- [ ] Compat guard: seeded `.env` with `MYSQL_ROOT_PASSWORD` ⇒ script aborts before modifying anything.
- [ ] `setup-backup-server.sh --dump/--services nextcloud` (or direct `bk_dump_service nextcloud`) produces `nextcloud-<ts>.dump` on a running stack.
- [ ] `AUTOMATIONS.md` updated; diff touches only: `tasks/setup-nextcloud.sh`, `templates/nextcloud/*`, `AUTOMATIONS.md`, `tests/machine-config.test.yml` (this plan file aside).

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Breaking an existing mariadb/sqlite install | §5.4 hard compat guard **before** any modification; re-runs of an existing **postgres** install keep datadir + secrets; `PG_VERSION` image rule prevents postgres-major-vs-datadir mismatch |
| `trusted_domains` / `overwriteprotocol` drift when switching modes | §6: domains are merged never removed; explicit warning + `occ config:system:delete` remedy printed on traefik→lan switch |
| Big uploads 413 behind the chain | `APACHE_BODY_LIMIT=0` + single `NEXTCLOUD_UPLOAD_LIMIT` knob; no Traefik body/buffering middleware (research §7) |
| First-run install exceeds readiness window (slow VMs) | `WAIT_TIMEOUT=300` for both gates; failure tears down only this run's stack, volumes intact; timeout configurable |
| Readiness via `exec … curl` fails if app container restarts mid-install | poll loop tolerates transient exec failures (`|| true` per iteration), only the final timeout errors |
| `occ` pass fails on a healthy-but-still-installing instance | runs strictly after `installed:true`; every occ line warn-only |
| HSTS preload/long max-age surprises operators | `stsSeconds=15552000` (180 d), `stsIncludeSubdomains=true`, **no** `stsPreload` |
| Redis password in container spec via `command` | file keeps `${REDIS_HOST_PASSWORD}` literal (policy satisfied); network is internal, password is defence-in-depth (research §3) |
| Image pin drifts silently (repo "moving tag" trap) | pinned defaults + `warn_moving_image` + "update deliberately / one major at a time" comments like `setup-openwebui.sh:112–118` |
| Backup dispatcher infers wrong backend | deterministic `DB_TYPE=postgres` in `.env` (§7) |

**Assumptions** (stated per karpathy-guidelines): (a) no critical production Nextcloud deployment exists on target machines yet — mariadb mode was the default and the research treats this as greenfield; the compat guard protects anything that does exist. (b) The `letsencrypt` certresolver name is repo-fixed (all templates use it). (c) `nextcloud:34-apache` is verified current at implementation time via `docker buildx imagetools inspect nextcloud` — bump the default then, not later.

---

## Test results (2026-09-18, implementation run)

Host: dev workstation (Linux, docker CLI + daemon available, **no passwordless
sudo**). VM suite NOT run — `virsh`/`virt-runner` respond but every libvirt
pool is empty (a `virt-runner create` would download the Ubuntu base image —
outside the 10-min/no-heavy-setup budget), so the strongest feasible local
verification was performed instead, incl. a shimmed full-script dry-run.

### Static (all PASS)

| Command | Result |
|---|---|
| `bash -n tasks/setup-nextcloud.sh` | clean |
| `shellcheck tasks/setup-nextcloud.sh` | clean |
| `yamllint -c templates/.yamllint templates/nextcloud/` | no findings (also plain `yamllint templates/nextcloud/` — templates carry `---`) |
| `yamllint tests/machine-config.test.yml` | clean |
| `bash tests/lint.sh` (template hardening guards) | PASS |
| `bash tasks/setup-nextcloud.sh --help` | exit 0, no side effects (`/srv/nextcloud` untouched); unknown option → exit 1 |
| `docker buildx imagetools inspect` `nextcloud:34-apache` (34.0.4), `postgres:17-alpine`, `redis:7-alpine` | all resolve — assumption (c) confirmed |

### Template render / compose parse (PASS)

Rendered both templates with the script's exact envsubst variable list;
`docker compose -f <rendered> --env-file <fake .env> config -q` → rc=0 for
traefik variant, direct variant with **empty** `NEXTCLOUD_LAN_BIND`
(port `":18080:80"` accepted by compose) and with a set bind. Resolved
output verified: `$$REDIS_PASSWORD` healthcheck, `--requirepass` value
interpolated only at runtime, traefik replacement label resolves to
`https://${1}/remote.php/dav` (Go-expand `$1` form, as the official docs),
routers/middlewares attached per §2. Secret greps: rendered files contain
zero literal secret values, `${POSTGRES_PASSWORD}`/`${REDIS_HOST_PASSWORD}`
kept literal.

### Full-script dry-run with `sudo`/`docker`/`ufw` shims, `NEXTCLOUD_HOME=/tmp/nc-sandbox` (all PASS)

| Scenario | Result |
|---|---|
| A fresh LAN install (`HTTP_PORT=18080`) | exit 0; `.env` mode 600 with `DB_TYPE=postgres` + 3 generated 24-char secrets + SMTP passthrough keys; compose rendered (4 services, `:18080:80`, `NEXTCLOUD_TRUSTED_DOMAINS=<detected-ip> localhost`, no labels); `docker compose config` on the generated pair OK |
| A occ pass | 8 calls, all `exec -T --user www-data … php occ` (6× `config:system:set`, `db:add-missing-indices`, `db:convert-filecache-bigint --no-interaction`) |
| A ufw | `ufw allow 18080/tcp comment Nextcloud (LAN mode)` invoked |
| B converge re-run | exit 0, `.env` byte-identical, **no** spurious `.env.bak`, no secret rotation |
| C compat guard (`.env` seeded with `MYSQL_ROOT_PASSWORD=`) | exit 1 **before any modification** (compose sha256 unchanged) |
| D admin-password divergence guard | exit 0 + first-install remedy, `.env` untouched |
| E Traefik mode (`NEXTCLOUD_DOMAIN=cloud.test` + extra domain) | exit 0; labels (secure router, HSTS, redirectregex) present, **no** `ports:`, `NEXTCLOUD_TRUSTED_DOMAINS=cloud.test 10.0.0.5`, compose config OK; **no** ufw rule added |
| traefik→lan switch | warn printed with the `occ config:system:delete overwriteprotocol` remedy |
| F `db/PG_VERSION=16` → default follows (`postgres:16-alpine`); explicit `NEXTCLOUD_DB_IMAGE` wins | PASS |
| G readiness gate (`status.php` stuck at `installed:false`, `WAIT_TIMEOUT=6`) | exit 1 after bound; cleanup trap tore down **this run's** stack (`compose down --remove-orphans` logged) |
| H compat guard (`data/nextcloud.db` present) | exit 1 before modification |

### Deviations from the plan (recorded)

1. **`NEXTCLOUD_DB_IMAGE` default** = `postgres:17-alpine` per §3 (the §2
   table's `16` defers to the §3 pin rule).
2. **LAN IP detection**: the §3 recipe `ip route | grep default | awk
   '{print $2}'` (forgejo's) yields the literal string `via`, not an IP —
   replaced with `ip route get 1` → token after `src`.
3. **Port bind**: envsubst cannot express `${VAR:+…}`; template renders
   `"${NEXTCLOUD_LAN_BIND}:${HTTP_PORT}:80"` — verified compose accepts the
   empty-host form (both binds tested), envsubst list unchanged.
4. **app `depends_on`** uses `condition: service_healthy` for db/redis so
   the first install cannot race the DB into a crash-loop (plan only
   mandated the healthchecks).
5. Mode-switch detection greps the 644 compose file without `sudo` (§6 said
   `sudo grep`; the file is world-readable).
6. Summary backup hint uses only `--services nextcloud` — no
   `--stop-services` flag exists in this repo; `lib/docker-backup.sh`
   already quiesces via `docker compose stop`.
7. Templates include a `---` document start (zero yamllint findings
   requirement); occ integer settings use `--type=integer`.

### Review pass (2026-09-18, senior review)

Re-reviewed the full diff against `lib/helpers.sh`, `lib/docker-backup.sh`,
`specification/project/conventions.md` and the openwebui/forgejo references.
Traefik labels (`$${1}` escaping, secure+web routers, redirectscheme, HSTS
180d, wellknown on both routers per official recipe), per-mode
overwriteprotocol/trusted_domains, Postgres-only guards, secret handling
(`${VAR}` literal, `.env` 600, no `sudo envsubst`, mktemp render), readiness
gate (bounded, non-zero exit), ufw-per-mode and the backup dispatcher
(`nextcloud`/`nextcloud-db`, `DB_TYPE=postgres`, `POSTGRES_DB` in `.env`) all
verified correct.

**Fixed:**

1. (medium) **SMTP config-loss on re-run**: only `SMTP_PASSWORD` was reused
   from `.env`; a re-run without SMTP env vars silently blanked
   `SMTP_HOST`/`PORT`/… in `.env`, disabling a configured mail relay —
   violating converge-by-default. All eight `SMTP_*`/`MAIL_*` keys now
   reuse-first (explicit env wins, else stored, else empty). `--help`
   updated.
2. (low) **Wrong backup mechanism in docs**: `--help`/header claimed the
   dispatcher "derives `${CONTAINER_NAME}-db`" — it actually uses
   `NEXTCLOUD_CONTAINER` (default `nextcloud`), never `CONTAINER_NAME`
   (`lib/docker-backup.sh:442`, spec `setup-backup-server.md:418`). Reworded
   both spots so a custom `CONTAINER_NAME` isn't silently unbacked-up.
3. (low) **False quiesce claim in summary**: "the backup runner quiesces app
   AND cron" is wrong — quiesce is a separate opt-in (`--stop-services`),
   and `bk_stack_quiesce nextcloud` stops the *whole* stack incl. the db
   container, which would break the pg_dump. Summary now names the real
   behaviour and warns against `--stop-services nextcloud`.
4. (low) **Misleading trap message** after a late failure (ufw/occ era):
   "No stack was started by this run" — it may have been started AND
   proven healthy; reworded (no behaviour change).
5. (cosmetic) Traefik template comment on the wellknown middleware was
   self-contradictory (attaching an `https://`-anchored regex to the web
   router is a no-op kept for the official recipe); reworded.

**Deliberately left alone:**

- db/redis/app env duplication between the two compose templates — repo
  pattern (openwebui/kestra/opencode-server); a shared base file would
  complicate every single-`-f` compose invocation.
- `sudo cat` + grep for `.env` read-back instead of `env_file_get` — the
  file is root:root 600; `env_file_get` reads as the invoking user and
  would fail (precedent: `setup-traefik.sh` `sudo cat`).
- `exec app curl` for the status.php gate — ships with the apache image;
  already flagged for VM confirmation below.
- Pre-existing, outside this diff: `BACKUP_STOP_SERVICES: nextcloud`
  (spec example, `machine-config.yml` comment) is unusable with
  `BACKUP_SERVICES: nextcloud` — quiesce stops the db before its own
  dump; fix belongs in the backup spec/dispatcher, not here.

**Post-review verification (all PASS):** `bash -n`, `shellcheck` clean;
`yamllint -c templates/.yamllint templates/nextcloud/` + plain
`yamllint tests/machine-config.test.yml` clean; `tests/lint.sh` PASS;
envsubst render of both templates (bind empty + set) → `docker compose
config -q` rc=0 ×3, secrets still literal, replacement resolves to
`https://${1}/remote.php/dav`; SMTP reuse unit-checked (explicit wins /
stored reused / absent stays empty); `--help` exit 0, unknown option exit 1.

### Not verified locally (needs VM/staging)

Real container lifecycle (pull, first-run install duration, healthy status
of the 4 real containers, admin login, redis `requirepass` PONG, cron loop,
real `ufw status`), Traefik runtime behaviour (301 `.well-known/caldav`,
HSTS header), and the `exec app curl` assumption (base `php:8.5-apache`
full image ships `curl`; confirm on the VM run:
`tests/run-vm-tests.sh --scripts setup-docker,setup-traefik,setup-nextcloud --ram 6 --disk 40 --timeout 60 --keep-vm`
— the disabled `setup-nextcloud` entry in `tests/machine-config.test.yml`
makes that ad-hoc run LAN-deterministic).
