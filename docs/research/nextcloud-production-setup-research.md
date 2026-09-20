# Nextcloud Production Setup (Docker + Traefik) — Research Document

Research date: 2026-09
Goal: collect the production-grade facts needed to implement a `tasks/setup-nextcloud.sh`
(docker-compose based, Traefik **or** LAN-port mode) so the script ships a stack that passes
Nextcloud's own admin security checks and behaves well under sync clients.

Sources verified:
- Nextcloud Docker image README (Docker Hub / docker-library `nextcloud`): variants, all
  auto-configuration env vars, volume layout, upgrade rules —
  https://hub.docker.com/_/nextcloud (fetched 2026-09; `stable`/`production` = 34.0.4, `latest` = 35.0.0)
- Nextcloud Administration Manual (server 35):
  - System requirements: https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html
  - Reverse proxy (trusted proxies, overwrite*, well-known redirect configs incl. Traefik):
    https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/reverse_proxy_configuration.html
  - Background jobs (AJAX vs Webcron vs cron, `maintenance_window_start`):
    https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/background_jobs_configuration.html
  - Memory caching (APCu / Redis / Memcached, `memcache.*`):
    https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/caching_configuration.html
  - Transactional file locking:
    https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/files_locking_transactional.html
  - Hardening (HTTPS/HSTS, security headers, fail2ban filter+jail, previews, debug):
    https://docs.nextcloud.com/server/stable/admin_manual/installation/harden_server.html
- nextcloud/docker `.examples` (cron via supervisor image / sidecar, proxy examples):
  https://github.com/nextcloud/docker/tree/master/.examples
- Traefik v3 docs, Headers middleware (HSTS via labels):
  https://doc.traefik.io/traefik/v3.3/middlewares/http/headers/
- Community pitfalls (Nextcloud forum / Traefik forum): `.well-known` warning after Traefik 2→3
  migration, plain "404 page not found" behind Traefik, HSTS headers at proxy satisfying the
  Nextcloud check — help.nextcloud.com threads #213093, #120462, community.traefik.io #26550,
  nextcloud/docker issue #1061.

---

## 1. Deployment options

| Option | Assessment |
|---|---|
| **Official `nextcloud` Docker image, `apache` variant** | Full app + Apache web server, exposes :80. Simplest compose topology: one app container behind Traefik, no extra nginx sidecar. Entry point auto-installs (via env vars) and auto-upgrades the app inside the volumes. |
| **Official image, `fpm` / `fpm-alpine` variant** | PHP-FPM only; requires an additional web server container (nginx with the full Nextcloud rewrite rules + `volumes_from` for static files). More moving parts and a bespoke nginx config to maintain — only worth it when Apache is specifically unwanted. Traefik cannot talk FastCGI directly. |
| **Nextcloud All-in-One (AIO)** | Maintained by Nextcloud GmbH, superset of features, but it manages its own proxy/TLS master container; awkward to merge with an existing shared Traefik — it wants to *be* the proxy stack. |
| **Bare snap (`snap install nextcloud`)** | Bundles its own confined nginx/MariaDB/Redis with opaque paths; auto-refresh makes the *one-major-step-at-a-time* upgrade rule uncontrollable from the outside; data layout can't follow `/srv/<service>`; cannot integrate with the repo's shared Traefik. Rejected. |
| **Bare source install** | Full control but manual PHP/MariaDB/Redis/cron/fail2ban management; the repo's model is compose-per-service. Rejected. |

**Why the official image + docker-compose fits this repo:** every service here is a generated
`docker-compose.yml` under `/srv/<service>`, routed via shared Traefik (`proxy` network) or a
direct host port (see `tasks/setup-openwebui.sh` / `tasks/setup-forgejo.sh`), secrets in
`/srv/<service>/.env` (600), pinned image tags, `wait_for_healthy` after `up -d`. The Nextcloud
image's env-var auto-configuration + bind-mountable sub-directories map 1:1 onto this pattern.
The image README itself warns it is "designed for expert use" — the script's job is to encode
that expertise once.

Recommendation: **`nextcloud:<major>-apache`** pinned to the current stable line (34 at research
time; `stable` alias = 34.0.4). Use the `-apache` variant unless a later requirement demands fpm.

## 2. Database

Nextcloud 35 supports (admin manual → System requirements):

- MySQL 8.4 / 9.7
- MariaDB 10.11 / 11.4 / **11.8 (recommended)** / 12.3
- PostgreSQL 14–17, **18 (recommended)**
- SQLite — "only recommended for testing and minimal-instances" → not acceptable for a productiv
  setup script (image default!). The image silently falls back to SQLite unless a full DB env
  var group is set, so the script **must** pass all `POSTGRES_*` (or `MYSQL_*`) vars.

MariaDB/MySQL impose extra server requirements (admin manual + image compose examples):
InnoDB only, `READ COMMITTED` transaction isolation, binary logging disabled or
`BINLOG_FORMAT=ROW` — the official examples pass
`command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW`,
plus 4-byte-utf8 setup for emoji. PostgreSQL has **no** such special requirements.

**Choice for a production script: PostgreSQL** (`postgres:17`/`18`): no isolation/binlog
footguns, and Postgres is already the repo's standard engine (Planka, Kestra, n8n, Concourse,
Forgejo-optional) — one dump strategy (`pg_dump -Fc`) per the existing
`docker-volume-backup-research.md`. The image auto-configures with
`POSTGRES_DB/USER/PASSWORD/HOST` (and supports `POSTGRES_*_FILE`).

## 3. Redis / memcache (locking + caching)

- Without a memcache Nextcloud shows an admin warning and, more importantly,
  **transactional file locking falls back to the database backend**, which "places a significant
  load on your database" (file-locking doc). Redis/Valkey as `memcache.locking` is *the*
  performance fix and prevents locking problems ("The use of Redis is recommended to prevent
  file locking problems" — image README).
- **Memcached is explicitly unsuitable for locking** (data can vanish from cache; locks must
  persist) — it is only for distributed caching. Redis is the best-practice single choice.
- Recommended config per deployment type (caching doc):
  - small/private: `'memcache.local' => '\OC\Memcache\APCu'` only;
  - single-server production: APCu local + Redis distributed + **Redis locking**:
    `memcache.local=APCu`, `memcache.distributed=Redis`, `memcache.locking=Redis`
    (Redis ≥ 4.0 required; Valkey works; since NC 34.0.2 a no-PHP-extension
    `KeyValueCache` backend exists — with the official image the phpredis extension is
    already baked in, so the classic `Redis` backend is the one to use).
- Image env vars: `REDIS_HOST`, `REDIS_HOST_PORT` (default 6379), `REDIS_HOST_PASSWORD`.
  On a compose network without published ports, an unprefixed Redis container is unreachable
  from outside the network already; adding a password (`requirepass` +
  `REDIS_HOST_PASSWORD`) is cheap defence-in-depth.
- APCu sizing note: default `apc.shm_size=32M` is too low; 128M+ is the doc's starting point
  (image default PHP config is adequate; worth knowing when tuning).

## 4. Background jobs: cron, not Ajax

- Three schedulers: **AJAX** (default; a job runs when a user visits the page — "least
  reliable", warning in docs: use cron when multiple users / Activity app / external storages
  are involved), **Webcron** (external HTTP ping, ≤288 runs/day, tiny instances only),
  **cron** — "the preferred method". Running `cron.php` automatically flips the admin setting
  to Cron.
- Classic form: `*/5 * * * * www-data php -f /var/www/html/cron.php` every 5 minutes.
- In Docker the canonical pattern (nextcloud/docker `.examples`): a **cron sidecar service
  from the same image** that shares the Nextcloud volumes and overrides the entrypoint with the
  image's built-in `/cron.sh` (loops `php -f cron.php` every 5 min as www-data):

  ```yaml
  cron:
    image: nextcloud:34-apache          # must always match the app image tag
    restart: unless-stopped
    volumes: [ same set as app ]
    entrypoint: /cron.sh
    depends_on: [ app ]
  ```

  (The alternative `.examples` approach — a derived image with supervisord running app+cron —
  needs a custom Dockerfile; the sidecar keeps the stack plain-image, which matches repo style.)
- `maintenance_window_start` (see §6) is **only honoured in cron mode** — another reason Ajax
  is wrong for production.

## 5. Reverse proxy: Traefik specifics

### How Nextcloud wants to be proxied

- Production Nextcloud requires TLS terminated in front ("we recommend using a reverse proxy …
  HTTPS is mandatory"), HTTP → HTTPS 301 redirect, and real-client-IP + protocol forwarding.
- `config.php` side (reverse-proxy doc):
  - `trusted_proxies`: **array of proxy IPs/CIDRs** — required for Nextcloud to trust
    `X-Forwarded-For`. For a compose stack use the docker network subnet Traefik sits on, or
    rely on the apache image default (below).
  - `forwarded_for_headers` — default `HTTP_X_FORWARDED_FOR` works with Traefik.
  - `overwriteprotocol=https` — fixes protocol auto-detection; without it generated URLs,
    redirects and the WebDAV endpoints use `http://` and sync clients break.
  - `overwritehost` — *not needed in most setups* (Nextcloud reads the forwarded `Host`
    header); set it only to force one canonical host (e.g. instance reachable via LAN name +
    public name → docs' "Multiple trusted domains" example pins `overwritehost` +
    `overwrite.cli.url`).
  - `overwritewebroot` + `overwrite.cli.url` — only when serving from a subdirectory
    (`/nextcloud`).
  - `overwritecondaddr` (regex on proxy remote-addr) — apply overwrites only for
    proxy-arriving requests when the same instance is *also* accessed directly (the
    traefik-mode + LAN-mode hybrid case).
- Apache image behaviour (image README): it rewrites the remote address from `X-Real-IP` if the
  request comes from `10.0.0.0/8`, `172.16.0.0/12` or `192.168.0.0/16` — i.e. a Traefik in the
  same docker network works for client-IP logging **out of the box**. To use the headers
  approach instead: `APACHE_DISABLE_REWRITE_IP=1` + `TRUSTED_PROXIES=<CIDR>` (env vars writing
  the `trusted_proxies` config). Image env vars: `OVERWRITEHOST`, `OVERWRITEPROTOCOL`,
  `OVERWRITECLIURL`, `OVERWRITEWEBROOT`.
- Important merge caveat (image README): env-set overwrite values are written once into
  `config.php` and **removing the env var does not remove the value** — re-runs must keep the
  values consistent (repo rule: read secrets/values back from `.env` before generating).

### Traefik v3 labels (compose) — the shape that works

```yaml
    networks: [proxy, internal]
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      # HTTP -> HTTPS
      - traefik.http.routers.nextcloud.rule=Host(`${NEXTCLOUD_DOMAIN}`)
      - traefik.http.routers.nextcloud.entrypoints=web
      - traefik.http.routers.nextcloud.middlewares=nextcloud-redirectscheme@docker,nextcloud-wellknown@docker
      - traefik.http.middlewares.nextcloud-redirectscheme.redirectscheme.scheme=https
      - traefik.http.middlewares.nextcloud-redirectscheme.redirectscheme.permanent=true
      # HTTPS
      - traefik.http.routers.nextcloud-secure.rule=Host(`${NEXTCLOUD_DOMAIN}`)
      - traefik.http.routers.nextcloud-secure.entrypoints=websecure
      - traefik.http.routers.nextcloud-secure.tls=true
      - traefik.http.routers.nextcloud-secure.tls.certresolver=<repo-resolver>
      - traefik.http.routers.nextcloud-secure.service=nextcloud
      - traefik.http.services.nextcloud.loadbalancer.server.port=80
      # well-known CalDAV/CardDAV redirect (official Nextcloud docs, still valid on v3)
      - traefik.http.middlewares.nextcloud-wellknown.redirectregex.regex=https://(.*)/.well-known/(?:card|cal)dav
      - traefik.http.middlewares.nextcloud-wellknown.redirectregex.replacement=https://$${1}/remote.php/dav
      - traefik.http.middlewares.nextcloud-wellknown.redirectregex.permanent=true
      # security headers incl. HSTS (see §10)
      - traefik.http.middlewares.nextcloud-hsts.headers.stsSeconds=15552000
      - traefik.http.middlewares.nextcloud-hsts.headers.stsIncludeSubdomains=true
```

Attach `nextcloud-wellknown,nextcloud-hsts` to the secure router as well.

### Known Nextcloud + Traefik pitfalls (docs + community threads)

1. **`.well-known/caldav|carddav` warning.** Nextcloud refuses to redirect these itself behind
   a proxy ("the reverse proxy does the redirects" — admin manual). The redirect regex
   middleware above is the official solution. Gotchas: `$$1` escaping in compose
   (`$1` is eaten by compose variable expansion), the middleware must be attached to the
   **websecure** router (the docs' regex matches `https://`), and the Traefik 2→3 migration
   thread #213093 shows the warning reappearing when routers/middlewares are split across
   routers and the well-known middleware is dropped from the new secure router.
   Verify: `curl -I https://host/.well-known/caldav` → `301 … /remote.php/dav`.
   Modern servers also check `webfinger`/`nodeinfo` — the apache image's `.htaccess` handles
   those once proxied correctly (see pitfall 4).
2. **Plain-text "404 page not found" on first run.** That response is *Traefik itself*, not
   Nextcloud: no router matched (docker provider not watching the network, missing
   `traefik.docker.network`, container only attached to `internal`, wrong entrypoint name).
   Community consensus (nextcloud/docker #1061): it means routing, not Nextcloud, is broken.
   A wrong/missing `Host` (`NEXTCLOUD_TRUSTED_DOMAINS`) instead yields a Nextcloud JSON/XML
   "untrusted domain" error — a useful differentiator.
3. **Real client IP.** Leave the apache rewrite-IP default alone when Traefik is inside the
   docker RFC1918 ranges; combining `APACHE_DISABLE_REWRITE_IP=1` with a `TRUSTED_PROXIES`
   that doesn't include Traefik's network shows only the proxy IP in `nextcloud.log` — which
   silently breaks fail2ban (§10) and suspicious-login features (issue #2316).
4. **Keep `passHostHeader` at its default (true)** — trusted-domain checks and URL generation
   depend on the forwarded `Host`. `NEXTCLOUD_INIT_HTACCESS=true` re-runs
   `occ maintenance:update:htaccess` on every container start (recommended by the image docs
   for consistency).
5. **Long sync requests:** don't attach a `buffering`/body-limit middleware; Traefik imposes no
   request-size limit by default, which is exactly what big uploads need (§7). Keep
   `readTimeout` unset/0 (default) so multi-GB chunked uploads aren't severed.

## 6. Production config.php settings

| Key | Production value | Why (source) |
|---|---|---|
| `trusted_domains` | exact list: proxy domain + LAN hostname/IP used | security; wrong host → "untrusted domain" + fail2ban match |
| `trusted_proxies` | CIDR of the proxy/docker network | real client IP, spoofing protection (reverse-proxy doc) |
| `overwriteprotocol` | `https` behind Traefik; unset for plain-LAN-http | generated URLs, redirects, WebDAV (reverse-proxy doc) |
| `overwrite.cli.url` | canonical public URL | CLI/cron/notifications generate correct links — **must be set** since cron runs without HTTP context |
| `overwritehost` / `overwritewebroot` | usually unset; set for canonical-host or subdir cases | see §5 |
| `memcache.local` | `\OC\Memcache\APCu` | local cache (caching doc) |
| `memcache.locking` | `\OC\Memcache\Redis` | takes file locks off the DB (§3) |
| `memcache.distributed` | `\OC\Memcache\Redis` | shared cache |
| `default_phone_region` | e.g. `'DE'` | silences admin warning; needed by birthdays/Talk |
| `maintenance_window_start` | `1` (UTC; jobs 01:00–05:00 UTC) | moves heavy once-a-day jobs out of working hours; **cron mode only** (background-jobs doc) |
| `enable_previews` | `true` for home use (UX) / `false` for high-security | previews are generated by PHP C libs = attack surface (hardening doc); or restrict `enabledPreviewProviders` |
| `debug` | `false` | hardening doc |
| `loglevel` | `2` | fail2ban needs failed-logins logged (hardening doc) |
| `log_type` / `logfile` | `file` → `/var/www/html/data/nextcloud.log` | fail2ban `logpath` |
| `allowed_admin_ranges` | optional LAN CIDR | restrict admin actions (hardening doc) |

All settable idempotently via
`docker compose exec --user www-data app php occ config:system:set <key> --value=…`
(the repo can prefer post-install `occ` calls over env vars for the values not covered by the
image's env auto-config, because `occ` values win on re-runs and are visible via
`occ config:list system`).

## 7. PHP / web tuning env vars (supported by the image, no rebuild)

| Env var | Default | Note |
|---|---|---|
| `PHP_MEMORY_LIMIT` | `512M` | docs: 128 MB minimum *per process*, 512 MB recommended |
| `PHP_UPLOAD_LIMIT` | `512M` | sets both `upload_max_filesize` and `post_max_size` — raise for big syncs (10G for media libs) |
| `APACHE_BODY_LIMIT` | `1073741824` (1 GiB), `0`=unlimited | apache `LimitRequestBody`; must be ≥ `PHP_UPLOAD_LIMIT` or uploads 413 despite PHP config |
| opcache | bundled/enabled | Zend OPcache ships with the image; APCu (`apc.enable=1`) is used via `memcache.local`; `apc.shm_size` 128M+ when customising |

Full env auto-config inventory (image README): `SQLITE_DATABASE`; `MYSQL_DATABASE/USER/PASSWORD/HOST`;
`POSTGRES_DB/USER/PASSWORD/HOST` (+ `_FILE` variants for
`NEXTCLOUD_ADMIN_PASSWORD`, `NEXTCLOUD_ADMIN_USER`, `MYSQL_*`, `POSTGRES_*`,
`REDIS_HOST_PASSWORD`, `SMTP_PASSWORD`); `NEXTCLOUD_ADMIN_USER/PASSWORD`;
`NEXTCLOUD_DATA_DIR` (default `/var/www/html/data`); `NEXTCLOUD_TRUSTED_DOMAINS`
(space-separated, applies after install); `NEXTCLOUD_UPDATE=1` (only with custom CMD);
`NEXTCLOUD_INIT_HTACCESS=true`; `REDIS_HOST[_PORT][_PASSWORD]`;
`SMTP_HOST/PORT/SECURE/AUTHTYPE/NAME/PASSWORD`, `MAIL_FROM_ADDRESS`, `MAIL_DOMAIN`;
`APACHE_DISABLE_REWRITE_IP`, `TRUSTED_PROXIES`, `OVERWRITE{HOST,PROTOCOL,CLIURL,WEBROOT}`;
`OBJECTSTORE_S3_*` / `OBJECTSTORE_SWIFT_*` for S3/Swift primary storage.

Big-file upload chain for sync clients (big-file-upload doc): client → **Traefik (no limit, no
body middleware)** → apache `LimitRequestBody` (`APACHE_BODY_LIMIT`) → PHP
(`PHP_UPLOAD_LIMIT`) → disk quota. All four must agree.

## 8. Volumes / layout

Image-documented mount points (image README "Additional volumes"):

| Container path | Content |
|---|---|
| `/var/www/html` | main folder — **needed for updating**; gets replaced on upgrade except `upgrade.exclude` entries |
| `/var/www/html/data` | user files (the big one) |
| `/var/www/html/config` | `config.php` (+ `config.php.bak`) |
| `/var/www/html/custom_apps` | installed apps |
| `/var/www/html/themes/<name>` | custom themes (optional) |

Rules: mount custom volumes **outside** `/var/www/html` or keep them in `upgrade.exclude`
(image README); hardening doc wants data *outside* the webroot — with the apache image the
practical equivalent is the sub-volume mount (data isn't shipped/updated with the app, and
`.htaccess`/index.php blocks direct access; behind Traefik only routed paths reach it).
www-data (uid 33) must own these host dirs.

Repo-style layout (mirrors the existing `/srv/nextcloud/{html,data,db}` sketch in
`docker-volume-backup-research.md`):

```
/srv/nextcloud/
  docker-compose.yml          # rendered template
  .env                        # 600: DB pwd, redis auth, admin pwd, SMTP pwd (never in compose file)
  html/                       # named volume alternative; app root incl. core
  data/                       # -> /var/www/html/data   (borg: raw-copy + occ/scan)
  config/                     # -> /var/www/html/config
  custom_apps/                # -> /var/www/html/custom_apps
  db/                         # -> postgres /var/lib/postgresql/data (dump-first backup!)
```

Networks: `proxy` (external, traefik) + an `internal` net for app↔db↔redis; only the app
container joins `proxy`; db/redis publish nothing.

## 9. Upgrades

- Image mechanism: new image + same volumes → entrypoint detects version mismatch and runs the
  upgrade automatically (needs default CMD or `NEXTCLOUD_UPDATE=1`). Compose: change tag →
  `docker compose pull && docker compose up -d`.
- **Hard rule (image README + Nextcloud docs): only one major version at a time** (33→34→35,
  never 33→35). Pin the image (`nextcloud:34-apache`) and *bump deliberately* — exactly the
  repo's image-pinning policy (`setup-openwebui.sh` "Update deliberately"). `latest`/bare
  `stable` tags risk skipping majors.
- The cron sidecar image tag **must match** the app tag (it executes code against the same
  volume).
- Maintenance mode: the entrypoint enters maintenance mode itself during its auto-upgrade;
  manual/DB-side prep afterwards: `occ db:add-missing-indices`,
  `occ db:add-missing-columns`, `occ db:add-missing-primary-keys`,
  `occ db:convert-filecache-bigint` (these silence admin warnings and speed up files), then
  `occ maintenance:mode --off` if it was set manually.
- Always backup (§12) before a major bump; the upgrade cannot be rolled back by just
  re-pulling the old image once the DB schema moved.

## 10. Security hardening

- **HTTPS only**: redirect HTTP→HTTPS 301 at Traefik (`redirectscheme`), serve TLS via the
  repo's certresolver; never expose the app port directly in traefik mode.
- **HSTS**: Nextcloud's admin check only looks at the *response header*, so it is satisfied at
  the proxy: `traefik.http.middlewares.<mw>.headers.stsSeconds=15552000` (+
  `stsIncludeSubdomains`, `stsPreload` per Traefik headers-middleware docs; the hardening doc's
  "≥ 15552000" threshold is what the admin page wants — Traefik forum #26550).
- **Security headers**: Nextcloud itself emits `X-Content-Type-Options`, `X-Robots-Tag`,
  `X-Frame-Options SAMEORIGIN`, `Referrer-Policy no-referrer`, CSP on dynamic responses;
  `.htaccess` adds them for static files when apache is allowed to use `.htaccess`
  (`NEXTCLOUD_INIT_HTACCESS=true` keeps it fresh). A proxy `headers` middleware can enforce the
  basics on *all* responses (static included) — belt-and-braces on top, not instead.
- **fail2ban**: relevant even behind Traefik — Nextcloud logs `Login failed` /
  `Two-factor challenge failed` / `Trusted domain error` as JSON into `nextcloud.log`; the
  admin manual provides the exact `filter.d/nextcloud.conf` + `jail.d/nextcloud.local`
  (logpath → `/srv/nextcloud/data/nextcloud.log`, `loglevel ≤ 2`, correct real client IP per
  pitfall §5.3). Ban happens at OS level before PHP/DB pay for it.
- DMZ/SSRF note (hardening doc): external-storage/federation features make Nextcloud probe
  remote hosts by design — on sensitive LANs restrict egress (relevant if the LAN-mode box
  also hosts other services).
- Dedicated subdomain (`cloud.example.com`) recommended; `debug=false`; bcrypt 72-char password
  limit is informational for policy.

## 11. SMTP / email

Image env auto-config (image README; email_configuration doc): `SMTP_HOST`,
`SMTP_SECURE` (`ssl`|`tls`→STARTTLS), `SMTP_PORT` (465 ssl / 587 starttls / 25),
`SMTP_AUTHTYPE` (`LOGIN`, `PLAIN` for no auth, `NTLM`), `SMTP_NAME`, `SMTP_PASSWORD`,
`MAIL_FROM_ADDRESS`, `MAIL_DOMAIN` (sender domain; often must match SMTP account).
**At least `SMTP_HOST` + `MAIL_FROM_ADDRESS` + `MAIL_DOMAIN`** or nothing is applied.
`SMTP_PASSWORD` also supports the `_FILE` (docker secrets) form. Without SMTP: notifications,
share-by-mail, password reset are dead. Test post-setup:
`occ test:email-send-filter`/user-triggered password-reset, or the "Email server" section of
admin settings. Password-less LAN relay: `SMTP_AUTHTYPE=PLAIN` + empty name/password against a
local relay.

## 12. Backup & occ for automation

- Consistent snapshot procedure (matches the Nextcloud row of
  `docker-volume-backup-research.md`):
  1. `occ maintenance:mode --on` (or `docker compose stop app cron` — quiesce; cron sidecar
     must be stopped too or it keeps writing),
  2. logical DB dump **from the db container** (`docker compose exec -T db pg_dump -Fc nextcloud > staging/…`),
  3. raw copy of `data/` + `config/` (file-level copy is only crash-consistent while the app
     runs; short quiesce window is the clean option borgmatic-style),
  4. `occ maintenance:mode --off` / `up -d` — with a trap so maintenance mode can't be left on.
- Restore = db + data + config together, then `occ files:scan --all` and
  `occ integrity:check-core`.
- occ invocation in this image: `docker compose exec --user www-data app php occ …`
  (never run occ as root).
- Automation-relevant commands: `status` (also the readiness endpoint: HTTP GET
  `/status.php` → JSON `installed:true` — use for the script's `wait_for_healthy`),
  `config:system:set/get/delete`, `maintenance:mode --on/--off`,
  `db:add-missing-indices|columns|primary-keys`, `db:convert-filecache-bigint`,
  `files:scan [--all]`, `user:add` / `user:resetpassword`, `app:install/enable/update`,
  `integrity:check-core`, `background:cron`, `maintenance:repair`.

## 13. "Local network mode" (no Traefik, direct LAN access)

For the offline/LAN fallback (repo's direct mode, cf. `OPENWEBUI_PORT` pattern):

- Publish the apache port bound to the LAN interface/IP, not `0.0.0.0`:
  `ports: ["${NEXTCLOUD_LAN_BIND:-}:8080:80"]` style binding or a documented bind default.
- **Plain HTTP** is the only thing the apache image serves (TLS termination would need a
  separate front or self-signed certs at apache = worse than either traefik-mode or plain http).
  Consequences: leave `OVERWRITEPROTOCOL` **unset** (auto-detect = http; forcing `https`
  breaks the LAN mode outright), and warn that sync traffic is unencrypted on the LAN.
- `NEXTCLOUD_TRUSTED_DOMAINS` must cover what users type: LAN IP
  (`192.168.1.10`), mDNS name (`nas.local`), reverse-DNS hostname; the var is
  space-separated and accepts IPs; re-run/re-add when DHCP lease changes — pin a static IP or
  DNS record for production LAN use. (`trusted_domains` entries are exact-match; there is no
  CIDR support in `trusted_domains` — CIDR exists only for `trusted_proxies`.)
- If the box *also* runs Traefik mode later, switching = changing proxy settings only:
  keep the LAN IP in `trusted_domains`, add the domain, and flip
  `OVERWRITEPROTOCOL=https` (+ `overwrite.cli.url`); use `overwritecondaddr` if both access
  paths must stay active simultaneously (§5).
- ufw: `ufw allow from ${LAN_CIDR:-192.168.0.0/16} to any port ${NEXTCLOUD_PORT} proto tcp`
  — and remember the known Docker/ufw interaction: published ports are inserted by Docker into
  the FORWARD/DOCKER chain and bypass ufw INPUT rules, so "LAN-only" exposure additionally
  requires binding the published port to the LAN IP (or a `DOCKER-USER` iptables rule). This
  is an existing repo-wide concern; the script should at least bind, and document the caveat.
- fail2ban in LAN mode: same jail; port var becomes the LAN port.

---

## Recommendations for this repo

Concrete choices for `tasks/setup-nextcloud.sh` + `templates/nextcloud/docker-compose.yml`
(following `setup-forgejo.sh` / `setup-openwebui.sh` conventions: env-var config with defaults,
`--help` kept current, cleanup trap with `STACK_CREATED_THIS_RUN`, secrets read-back from
`.env` 600 and never substituted into the compose file, `wait_for_healthy` before success,
ufw step, idempotent converge on re-run):

- **Image**: `NEXTCLOUD_IMAGE=nextcloud:34-apache` (pinned stable major, "update deliberately"
  comment like `setup-openwebui.sh:112-118`). Cron sidecar reuses `${NEXTCLOUD_IMAGE}` with
  `entrypoint: /cron.sh`. No fpm/nginx sidecar, no AIO, no snap.
- **Stack**: 4 services — `db` (`postgres:17`, `POSTGRES_*` from `.env`, volume
  `/srv/nextcloud/db`), `redis` (pinned `redis:7-alpine` / valkey, `requirepass` from `.env`),
  `app`, `cron`. App↔db/redis on an internal network; `proxy` network only in traefik mode.
- **Layout**: `PROJECT_DIR=/srv/nextcloud`; bind mounts `./config ./data ./custom_apps` onto
  `/var/www/html/{config,data,custom_apps}`, one named/bind volume for `html` root; chown to
  uid 33. `.env` (600) holds `POSTGRES_PASSWORD`, `REDIS_HOST_PASSWORD`,
  `NEXTCLOUD_ADMIN_PASSWORD` (generated on first run, read back on re-runs — never rotated),
  SMTP creds; compose template keeps `${VAR}` literal per repo secrets policy.
- **Two access modes** (openwebui pattern): `NEXTCLOUD_TRAEFIK=true` + `NEXTCLOUD_DOMAIN` →
  labels from §5 (redirectscheme, wellknown redirectregex with `$${1}`, HSTS stsSeconds,
  `certresolver` from a shared var); otherwise direct mode → `ports` bound to
  `NEXTCLOUD_LAN_BIND`/`NEXTCLOUD_PORT` with the ufw-from-LAN-CIDR rule of §13.
- **App config via env at install** (`MYSQL`-style required group fully set → no wizard):
  `POSTGRES_DB/USER/PASSWORD/HOST`, `REDIS_HOST(+PASSWORD)`, `NEXTCLOUD_TRUSTED_DOMAINS`
  (domain + LAN IP), `OVERWRITEPROTOCOL=https` (traefik mode only), `TRUSTED_PROXIES` =
  compose/proxy network subnet, `NEXTCLOUD_INIT_HTACCESS=true`,
  `PHP_MEMORY_LIMIT=512M`, `PHP_UPLOAD_LIMIT` + `APACHE_BODY_LIMIT` from
  `NEXTCLOUD_UPLOAD_LIMIT` (default e.g. `10G`), `SMTP_*` passthrough.
- **Post-install `occ` hardening pass** (idempotent, via `exec --user www-data php
  occ config:system:set`): `memcache.local=APCu`,
  `memcache.distributed/locking=Redis` (env vars only wire `redis.*` connection — the memcache
  switches are not covered by image env vars), `default_phone_region=${NEXTCLOUD_PHONE_REGION:-DE}`,
  `maintenance_window_start=1`, `loglevel=2`, `overwrite.cli.url`, then
  `db:add-missing-indices` + `db:convert-filecache-bigint` (guarded, cheap).
- **Health gate**: poll `https(s)://<url>/status.php` (or `docker inspect` health) until
  `"installed": true` with bounded timeout — replaces a blind `up -d` success claim; failure
  path tears down only this run's stack.
- **Upgrades**: script re-run converges but never auto-bumps majors; document
  one-major-at-a-time + `occ maintenance:mode --on` + borg dump (§12) in `--help`;
  interop hook for `setup-backup-server` dumper dispatcher: `pg_dump -Fc` + raw `data/` with
  maintenance-mode quiesce, per `docker-volume-backup-research.md`.
- **Docs/success output**: print URL, admin user, well-known verification hints
  (`curl -I …/.well-known/caldav` → 301), fail2ban jail pointer (filter/jail snippets →
  logpath `/srv/nextcloud/data/nextcloud.log`), and keep `AUTOMATIONS.md` updated.

Open questions for the implementation ticket:

1. Default upload limit (512M image default vs 10G for a media-oriented box) — env-tunable
   either way; pick a default that doesn't balloon `post_max_size` × worker memory.
2. Whether to expose `NEXTCLOUD_TRUSTED_DOMAINS_EXTRA` so LAN IP + extra names can coexist
   with traefik mode without manual `occ` edits (recommend: yes, space-joined).
3. Previews: ship `enable_previews=true` with a conservative provider list (images/txt) vs the
   hardening-doc `false` default for the "hard" profile flag.
4. Redis vs Valkey as the default image name now that licensing shifted (NC docs treat both;
   repo consistency vs freshness).
