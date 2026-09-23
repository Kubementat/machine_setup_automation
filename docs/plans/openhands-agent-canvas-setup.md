# OpenHands → Agent Canvas Refactor Plan

> Status: **Draft for review** — refactor plan for migrating the `setup-openhands.sh` integration from the legacy V1 "Traditional Web App" to the Agent Canvas Docker deployment.
> Date: 2026-08-17
> Supersedes: `docs/plans/openhands-integration.md` (V1 integration plan)

## Executive Summary

The `setup-openhands.sh` task deploys the **legacy V1 OpenHands Web App**: image `docker.openhands.dev/openhands/openhands`, UI on port 3001, a **mounted `/var/run/docker.sock`**, and `AGENT_SERVER_*` / `SANDBOX_*` env machinery to spawn ephemeral per-conversation sandbox containers on fixed host ports (8000–8012).

OpenHands has since been rebranded around **Agent Canvas** — a single all-in-one container (`ghcr.io/openhands/agent-canvas`) that embeds the frontend, Agent Server, and Automation Server behind **one ingress port (8000)** with the UI at `/canvas`. It requires **no docker.sock** (the container itself is the execution boundary), uses only **two meaningful env vars** (`OH_SECRET_KEY`, `LOCAL_BACKEND_API_KEY`), and persists everything to two mounts (`/home/openhands/.openhands` and `/projects`).

This refactor swaps the image, port, mounts, and env surface in `tasks/setup-openhands.sh` and the two compose templates, keeps **all repo conventions** (`/srv/openhands`, `templates/openhands/*.yml`, `lib/helpers.sh` helpers, Traefik opt-in pattern, idempotent `.env`), and adds a **migration path for existing V1 installs** (legacy data dir is incompatible and will be backed up and replaced).

> **Decision (filename):** Keep the script name `tasks/setup-openhands.sh` and the `setup-openhands` machine-config key.
> - `run-setup.sh` resolves tasks by `machine-config.yml` key → filename; renaming would silently break every existing `machine-config.yml` entry and require a migration story in the orchestrator for zero benefit.
> - The product is still "OpenHands" — Agent Canvas is its current frontend, and the repo `CONTEXT.md` / README terms keep working.
> - No rename, no migration story, zero churn (Karpathy: minimal changes).

> **Decision (beta status):** Agent Canvas is beta/incubator (npm: "may be vibecoded, untested, or out of date"). We proceed anyway because the V1 app is demoted to "Local GUI (Legacy)" in current docs and the Canvas all-in-one model is a strict simplification of what we run (no sandbox-orchestration edge cases, no docker.sock, no fixed-port single-conversation limit).

## What Changes: V1 → Agent Canvas

| Aspect | V1 (current script) | Agent Canvas (new) |
|---|---|---|
| Image | `docker.openhands.dev/openhands/openhands` | `ghcr.io/openhands/agent-canvas` |
| Image tag | `latest` | pinned release `1.13.0` (overridable) |
| Ingress port | host `3001` → container `3001`, UI at `/` | host `8000` → container `8000`, UI at `/canvas` |
| Architecture | app container + spawned sandbox containers | single all-in-one container (frontend + Agent Server :18000 + Automation Server :18001, internal only) |
| docker.sock | **mounted** (full host Docker access) | **not mounted** |
| Sandbox machinery | `AGENT_SERVER_IMAGE_REPOSITORY/TAG`, `AGENT_SERVER_USE_HOST_NETWORK=true`, `SANDBOX_VOLUMES`, `SANDBOX_CONTAINER_URL_PATTERN` | **all removed** — agent runs inside the container; workspaces = `/projects` mount |
| Data mount | `${OPENHANDS_HOME}/data` → `/.openhands` | `${OPENHANDS_HOME}/data` → `/home/openhands/.openhands` |
| Workspace mount | `${OPENHANDS_WORKSPACE}` → `:/workspace` in each sandbox | `${OPENHANDS_HOME}/projects` → `/projects` |
| `OH_WEB_URL` | set (CORS origin) | **removed** (no such variable in Canvas) |
| New env | — | `AUTOMATION_BASE_URL` (automation callbacks), `VITE_DO_NOT_TRACK` (telemetry off) |
| Kept env | `OH_SECRET_KEY`, `LOCAL_BACKEND_API_KEY`, `OPENHANDS_IMAGE[_TAG]`, `OPENHANDS_PORT`, `OPENHANDS_HOME`, `OPENHANDS_TRAEFIK/_DOMAIN`, `PROXY_NETWORK` | same (identical names/semantics for the two secrets) |
| Container user | root in V1 app image | non-root `openhands` user (UID undocumented — see §Permissions) |
| `tty`/`stdin_open` | set | removed (headless daemon service) |
| Traefik | router → port 3001 | router → port **8000**, + `loadbalancer.response.timeout=3600s`; WebSocket auto-upgrade |
| UFW | port 3001 (+ advisory sandbox ports 8000–8012) | port 8000 only |
| Health check | `GET /` (200/302/303) | `GET /canvas` (200/302/303) |
| Data compatibility | V1 `data/` layout (config.toml, V1 file store) | **incompatible** — Canvas layout (`agent-canvas/conversations`, `automation/automations.db`, …); V1 data backed up on migration |

## Architecture

```
   direct mode:         ┌────────────────────────────┐
   http://host:8000 ───►│  (or Traefik: websecure,   │
                        │   letsencrypt, Host label) │
                        └─────────────┬──────────────┘
                                      │  (direct mode: host port 8000, UFW-gated)
                        ┌─────────────▼──────────────┐
                        │  container: openhands       │
                        │  ghcr.io/openhands/         │
                        │  agent-canvas:1.13.0        │
                        │                             │
                        │  ingress :8000              │
                        │   /canvas   → static UI     │
                        │   /api/*    → Agent Server  │
                        │   /sockets  → WS (Agent Srv)│
                        │   /api/automation/* → :18001│
                        │                             │
                        │  NO /var/run/docker.sock    │
                        │  runs as user: openhands    │
                        └──────┬──────────────┬───────┘
                               │              │
                 /srv/openhands/data   /srv/openhands/projects
                 → /home/openhands/    → /projects
                   .openhands
```

Key points:
- **Single container, single ingress.** Port 8000 is a path-based ingress (see §Health Checks for the route table). Internal ports 18000/18001 are never published.
- **No host-port side effects.** The V1 single-conversation limit (fixed host ports 8000/8001/8011/8012) disappears entirely — no UFW range, no `AGENT_SERVER_USE_HOST_NETWORK` note.
- **Proxy model unchanged.** Traefik mode passes `Host(<OPENHANDS_DOMAIN>) → openhands:8000` with **no path stripping** (the ingress itself routes `/canvas`, `/api`, `/sockets`).

## Configuration Strategy

### Directory layout

```
/srv/openhands/
├── docker-compose.yml       # copied from templates/openhands/ (only if absent)
├── .env                     # secrets + config (mode 600, never overwritten)
├── data/                    # → /home/openhands/.openhands (settings, secrets,
│                            #   conversations, automations DB, workspaces, storage)
├── projects/                # → /projects (dirs the agent can read & edit)
└── data.v1.bak/             # (migration only) legacy V1 data, renamed on upgrade
```

### Env vars — `.env` generation

| Variable | V1 script | New script | Notes |
|---|---|---|---|
| `OH_SECRET_KEY` | generated | **kept** | Encrypts stored settings/secrets. Existing V1 value stays valid (same name/role). |
| `LOCAL_BACKEND_API_KEY` | generated | **kept** | Session API key (`X-Session-API-Key`). Existing value stays valid. |
| `OPENHANDS_IMAGE` | `docker.openhands.dev/openhands/openhands` | **changed** default → `ghcr.io/openhands/agent-canvas` | |
| `OPENHANDS_IMAGE_TAG` | `latest` | **changed** default → `1.13.0` | Pin release (docs use `latest`, README pins `1.13.0`; beta product ⇒ reproducibility). Verify tag exists at implementation time. |
| `OPENHANDS_PORT` | `3001` | **changed** default → `8000` | Host port (maps to fixed container port 8000). Old `3001` still *works* if explicitly set (host-port override, like the docs' port-conflict variant). |
| `OPENHANDS_HOME` | `/srv/openhands` | kept | |
| `OPENHANDS_TRAEFIK` | `false` | kept | |
| `OPENHANDS_DOMAIN` | required-if-traefik | kept | |
| `PROXY_NETWORK` | `proxy` | kept | |
| `AUTOMATION_BASE_URL` | — | **added** | Derived: `https://${OPENHANDS_DOMAIN}` (traefik) / `http://localhost:${OPENHANDS_PORT}` (direct). Internal default is `http://127.0.0.1:8000` (container-local) — wrong for webhooks through a proxy. Undocumented in public docs; from `docker/entrypoint.sh`. |
| `VITE_DO_NOT_TRACK` | — | **added**, default `1` | Disables baked-in PostHog telemetry (on by default in image). |
| `OPENHANDS_PROJECTS` | — | **added**, default `${OPENHANDS_HOME}/projects` | Host dir mounted at `/projects`. |
| `OPENHANDS_WORKSPACE` | default `/srv/openhands/workspace` | **removed** | V1 sandbox mount; replaced by `OPENHANDS_PROJECTS`. |
| `OH_WEB_URL` | derived | **removed** | No equivalent in Canvas. |
| `SANDBOX_CONTAINER_URL_PATTERN` | derived | **removed** | No per-conversation sandbox containers. |
| `AGENT_SERVER_IMAGE_REPOSITORY` | `ghcr.io/openhands/agent-server` | **removed** | Baked into Canvas image (pinned at build). |
| `AGENT_SERVER_IMAGE_TAG` | empty | **removed** | |
| `AGENT_SERVER_USE_HOST_NETWORK` | `true` | **removed** | |

Stale V1 keys left in an existing `.env` on migration are inert (the new compose file references none of them); we do not rewrite the file (never-overwrite rule).

### Script env vars (process-level)

| Variable | Default | Description |
|---|---|---|
| `OPENHANDS_HOME` | `/srv/openhands` | Base directory |
| `OPENHANDS_IMAGE` | `ghcr.io/openhands/agent-canvas` | Image repository |
| `OPENHANDS_IMAGE_TAG` | `1.13.0` | Image tag (override for `latest` or other releases) |
| `OPENHANDS_PORT` | `8000` | Host port (direct mode) |
| `OPENHANDS_PROJECTS` | `${OPENHANDS_HOME}/projects` | Host dir → `/projects` |
| `OPENHANDS_TRAEFIK` | `false` | Enable Traefik routing |
| `OPENHANDS_DOMAIN` | *(required if traefik)* | Public domain |
| `PROXY_NETWORK` | `proxy` | Traefik external network |

Removed from the script: `OPENHANDS_WORKSPACE`, `AGENT_SERVER_IMAGE_REPOSITORY`, `AGENT_SERVER_IMAGE_TAG`, `AGENT_SERVER_USE_HOST_NETWORK`.

## Compose Templates (new content)

### `templates/openhands/docker-compose.direct.yml`

```yaml
# yamllint disable rule:line-length
---
name: openhands

services:
  openhands:
    image: ${OPENHANDS_IMAGE}:${OPENHANDS_IMAGE_TAG}
    container_name: openhands
    restart: unless-stopped
    ports:
      - "${OPENHANDS_PORT}:8000"
    environment:
      - OH_SECRET_KEY=${OH_SECRET_KEY:?set OH_SECRET_KEY in .env}
      - LOCAL_BACKEND_API_KEY=${LOCAL_BACKEND_API_KEY:?set LOCAL_BACKEND_API_KEY in .env}
      - AUTOMATION_BASE_URL=${AUTOMATION_BASE_URL:-http://localhost:8000}
      - VITE_DO_NOT_TRACK=${VITE_DO_NOT_TRACK:-1}
    volumes:
      - ${OPENHANDS_HOME}/data:/home/openhands/.openhands
      - ${OPENHANDS_HOME}/projects:/projects
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Notes vs V1 template:
- No `/var/run/docker.sock` volume.
- No `environment` sandbox block; no `SANDBOX_VOLUMES`.
- `tty`/`stdin_open` removed — headless daemon (the docs' `-it` is for interactive `docker run --rm` testing, not a `restart: unless-stopped` service).
- Private `openhands` network removed (no inter-container traffic; default bridge / proxy network suffices).
- `extra_hosts` kept (one line) because the documented local-LLM reachability path requires `http://host.docker.internal:<port>/v1` from the backend.

### `templates/openhands/docker-compose.traefik.yml`

```yaml
# yamllint disable rule:line-length
---
name: openhands

services:
  openhands:
    image: ${OPENHANDS_IMAGE}:${OPENHANDS_IMAGE_TAG}
    container_name: openhands
    restart: unless-stopped
    environment:
      - OH_SECRET_KEY=${OH_SECRET_KEY:?set OH_SECRET_KEY in .env}
      - LOCAL_BACKEND_API_KEY=${LOCAL_BACKEND_API_KEY:?set LOCAL_BACKEND_API_KEY in .env}
      - AUTOMATION_BASE_URL=https://${OPENHANDS_DOMAIN}
      - VITE_DO_NOT_TRACK=${VITE_DO_NOT_TRACK:-1}
    volumes:
      - ${OPENHANDS_HOME}/data:/home/openhands/.openhands
      - ${OPENHANDS_HOME}/projects:/projects
    extra_hosts:
      - "host.docker.internal:host-gateway"
    labels:
      - 'traefik.enable=true'
      - 'traefik.docker.network=${PROXY_NETWORK}'
      - 'traefik.http.routers.openhands.rule=Host(`${OPENHANDS_DOMAIN}`)'
      - 'traefik.http.routers.openhands.entrypoints=websecure'
      - 'traefik.http.routers.openhands.tls.certresolver=letsencrypt'
      - 'traefik.http.services.openhands.loadbalancer.server.port=8000'
      - 'traefik.http.services.openhands.loadbalancer.response.timeout=3600s'
    networks:
      - ${PROXY_NETWORK}

networks:
  ${PROXY_NETWORK}:
    external: true
```

Same labels as every other service in this repo (`traefik.enable`, `docker.network`, `Host()` rule, `websecure`, `letsencrypt`, `loadbalancer.server.port`) — only the port (8000) and the response-timeout label are new.

## Traefik Specifics

1. **WebSocket upgrade**: live agent events stream over WebSocket/SSE at `/sockets`. Traefik upgrades automatically when it sees the `Upgrade` header (HTTP/1.1, Docker provider default) — **no extra label needed**; do NOT add `Connection "upgrade"` pinning or path rewrites.
2. **Long idle timeouts**: agent sessions stream for hours; the docs' nginx reference uses `proxy_read/send_timeout 3600s`.
   - Per-service (what *we* can control from the template): `traefik.http.services.openhands.loadbalancer.response.timeout=3600s` (Traefik default response timeout is 100s).
   - **Global (Traefik-side, out of this template's scope)**: `entrypoints.websecure.http.transport.respondingTimeouts.idle=3600s` must be set in the Traefik entrypoint config (default idle is 180s). Action: add this line to `tasks/setup-traefik.sh`'s Traefik config (one-line follow-up edit, same PR) **and** note it in the summary output for existing Traefik installs. Flagged as a cross-task touch — if the PR is to stay strictly openhands-scoped, document it as a manual step instead. Decision: include the one-line edit in `setup-traefik.sh`.
3. **No path stripping**: router passes everything to port 8000; the container ingress owns `/canvas`, `/api`, `/sockets`, `/api/automation`.
4. `AUTOMATION_BASE_URL=https://${OPENHANDS_DOMAIN}` so automation webhook callbacks resolve through the public domain.

## Health Checks

Container ingress route table (from `docker/entrypoint.sh` / `SELF_HOSTING.md`):

| Path | Target |
|---|---|
| `/*` (default) | static frontend, served under base path `/canvas` (image bakes `VITE_BASE_PATH=/canvas`) |
| `/api/*`, `/sockets` | Agent Server (`:18000`) |
| `/api/automation/*` | Automation Server (`:18001`) |
| `/alive`, `/health`, `/ready` | Agent Server |
| `/docs`, `/openapi.json` | Agent Server (FastAPI) |

**Decision: primary readiness poll = `GET /canvas`**, accepting `200|302|303`, max 120s @ 5s (same loop shape as today, new URL `http://localhost:${OPENHANDS_PORT}/canvas`). This is the documented UI path and verifies both ingress and static-frontend serving.

`/health` **exists in the image entrypoint but is undocumented in the public docs** (no documented response shape). We deliberately do NOT wire it into pass/fail logic; in direct mode the script may additionally `curl -s -o /dev/null -w "%{http_code}" http://localhost:${OPENHANDS_PORT}/health` once, after the UI check passes, and log the code at `info` level as a diagnostic only (never fails the script). If it consistently returns 200 in testing, a follow-up can promote it — not in this PR.

Traefik mode: unchanged — skip the HTTP check (TLS/DNS not guaranteed at script time), verify container is running.

## Migration Story (existing V1 installs)

V1 and Canvas data are **incompatible**: V1 `data/` (mounted at `/.openhands`) holds `config.toml` + the V1 file store; Canvas expects `agent-canvas/conversations/`, `automation/automations.db`, `secret-key.txt`, etc. There is no format conversion — this is a product replacement, not an upgrade.

Script behavior in the existing-stack section (replacing the current single prompt):

1. If `docker-compose.yml` exists, detect its generation:
   - **Legacy V1 marker** = file contains `docker.openhands.dev` or `SANDBOX_VOLUMES` or `docker.sock`.
   - **Canvas marker** = file contains `agent-canvas`.
2. **Canvas marker (re-run / same-gen idempotency):** existing behavior — prompt "Tear down existing stack and re-create? [y/N]"; `docker compose down`; data in `data/` preserved and re-mounted; `.env` untouched; template copied only if the compose file is (re)written by the script. No behavior change.
3. **Legacy V1 marker (migration):**
   - Explain: "Legacy V1 OpenHands stack detected. V1 data is NOT compatible with Agent Canvas and will be preserved at `data.v1.bak/`."
   - Prompt `y/N` (default N; N ⇒ exit 0, nothing touched).
   - On `y`:
     a. `docker compose down --remove-orphans` (stops/removes V1 containers).
     b. If `$OPENHANDS_HOME/data` exists and is non-empty: `mv "$OPENHANDS_HOME/data" "$OPENHANDS_HOME/data.v1.bak"` (rename, not copy — no double disk use, trivially reversible).
     c. `rm -f "$OPENHANDS_HOME/docker-compose.yml"` so the new template is written fresh (the V1 compose file must not survive — it references the old image and docker.sock).
   - `.env` is **kept as-is**: `OH_SECRET_KEY` and `LOCAL_BACKEND_API_KEY` have identical names and compatible semantics in Canvas, so the new container starts with the existing keys (no forced secret rotation). Stale V1 keys (`OH_WEB_URL`, `AGENT_SERVER_*`, …) are inert. If the user wants fresh keys, they edit `.env` by hand (documented in the migration message).
   - Continue the normal flow (dirs → compose copy → up). `projects/` is created fresh.
4. **Idempotency invariants** (unchanged repo rules): `.env` never overwritten; compose file only written if absent; secrets generated once; re-run of a finished Canvas install is a no-op teardown/recreate with data intact.
5. Port note: a leftover V1 UFW rule on 3001 is *not* auto-removed (no safe auto-removal of an unidentified rule); the migration message tells the operator to run `sudo ufw delete allow 3001/tcp` if they no longer need V1 access. (Adding `ufw_delete_rule 3001` automatically is tempting but destructive if something else owns 3001 — manual, documented.)

## Permissions / chown & UID

- The Canvas image runs as non-root user `openhands`; its **UID is not documented** (research gap). The Dockerfile does `chown -R openhands:openhands` on the persistence dirs at build time, but our bind mounts shadow those paths with host ownership.
- **Plan (minimal):** reuse the existing pattern — `sudo chown "${USER:-$(whoami)}"` on `data/` and `projects/`. On the standard target (Ubuntu, single admin user with UID 1000, and the image's `openhands` user almost certainly 1000) this works.
- **Verify at implementation time:** `docker pull ghcr.io/openhands/agent-canvas:1.13.0 && docker run --rm --entrypoint id ghcr.io/openhands/agent-canvas:1.13.0`. If the UID ≠ 1000, add `sudo chown <uid>:<gid>` for the two dirs (one-line change) — decided at test time, no env var added now (no speculative `OPENHANDS_UID`).
- If writes fail on a real box, the summary's "known issue" pointer tells the operator: `sudo chown 1000:1000 /srv/openhands/data /srv/openhands/projects`.

## UFW Rules

Direct mode only (via `ufw_add_rule` from `lib/helpers.sh`), unchanged shape:

```bash
ufw_add_rule "$OPENHANDS_PORT" tcp "OpenHands Agent Canvas"   # default port 8000
```

- The V1 advisory block (open 8000/8001/8011:8012 for host-networked sandboxes) is **deleted** — no sandbox host ports exist anymore.
- Traefik mode: no UFW change (80/443 handled by the Traefik task).

## Security Considerations

### What improves vs V1
- **No `/var/run/docker.sock`** — the container no longer has full host Docker control. The execution boundary is the container itself.
- **No fixed sandbox host ports** — 4 fewer potentially exposed ports; nothing listening besides 8000.

### Remaining risks
1. **Agent = untrusted code inside the container.** "Agent Canvas is the client and does not provide isolation." The agent can read/write everything under `data/` and `projects/` and execute shell as the `openhands` user. Treat the host as trusted infrastructure; mount only directories the agent may touch.
2. **API key = full backend access.** "Anyone who can talk to the agent server can read/write the filesystem, run shell, reach the network." Protect `.env` (600), never log the key, rotate on suspicion.
3. **Direct mode on 0.0.0.0:** port 8000 on the LAN means any LAN client that can reach the port can use the UI. UFW gates it to allowed networks; for stronger isolation bind `127.0.0.1` and SSH-tunnel (`ssh -L 8000:127.0.0.1:8000 host`) — see Decision Points.
4. **Stored secrets** in `data/` are encrypted with `OH_SECRET_KEY`; losing `data/` = losing LLM keys/conversations. Backup = `tar czf openhands-backup.tgz -C /srv/openhands data .env`.
5. **Beta product**: no SLA; pin the tag; re-test after bumps.
6. **LLM reachability**: local model servers must be reachable from the *container* (`http://host.docker.internal:<port>/v1`, not `127.0.0.1`) — hence `extra_hosts` is kept.

### Summary-output changes
- Security notice: replace the docker.sock warning with the container-boundary + API-key wording above.
- Delete the "single conversation (fixed ports 8000/8001/8011/8012)" note and the sandbox UFW hint entirely.
- Add: backup one-liner; migration hint for V1 machines; `projects/` location.

## Decision Points (surfaced for review)

| # | Decision | Chosen | Rationale / alternative |
|---|---|---|---|
| 1 | Image tag: `latest` vs `1.13.0` | **Pin `1.13.0`** (default; overridable via `OPENHANDS_IMAGE_TAG`) | Beta product, docs say `latest` but README pins a release; automation should be reproducible. `--pull always` still refreshes within the tag. Verify `docker pull ...:1.13.0` succeeds at implementation time (GHCR tag list not enumerable anonymously). Alt: `latest` for auto-updates — rejected (surprise breakage on beta). |
| 2 | Direct-mode bind: `0.0.0.0:8000` vs `127.0.0.1:8000` | **`0.0.0.0` (default) + UFW rule** | Matches V1 script behavior and repo convention (omnigent 8008, forgejo all bind all-interfaces + UFW); preserves remote-LAN access. Alt: `127.0.0.1:8000:8000` + SSH tunnel is strictly safer; one-line template change if reviewers prefer — noted, not adopted. |
| 3 | `AUTOMATION_BASE_URL` | **Set (derived)**: `https://domain` (traefik) / `http://localhost:<port>` (direct) | Undocumented in public docs but read by the entrypoint; the container-local default `http://127.0.0.1:8000` breaks webhook callbacks through a proxy. Low risk: only used by the Automation Server. |
| 4 | `VITE_DO_NOT_TRACK` | **Default `1`** (telemetry off), overridable | Image ships a baked PostHog key; this is a server-side automation — opt out by default. Compose has `${VITE_DO_NOT_TRACK:-1}` so operators can force `0`. |
| 5 | Container/stack/project name | **Keep `openhands`** (`container_name`, compose `name:`) | Script's `docker ps \| grep openhands` and `docker inspect openhands` checks keep working unchanged; matches the stable service name in `machine-config.yml`, README, `CONTEXT.md`. Alt: `agent-canvas` — more accurate but forces touching every grep/inspect/log command and operator muscle memory; rejected (minimal change). |
| 6 | Projects dir location | **`${OPENHANDS_HOME}/projects` = `/srv/openhands/projects`** | Keeps *all* service data under `/srv/openhands` (repo convention); single backup path; the docs' `~/projects` is just a convention ("any host dir"). `OPENHANDS_PROJECTS` overrides it. |
| 7 | chown / container UID | **`chown` to invoking user (UID 1000); verify image UID at test time** | See §Permissions. No `OPENHANDS_UID` env var added (speculative). |
| 8 | Script filename | **Keep `setup-openhands.sh`** | See Executive Summary decision — config-key stability. |
| 9 | V1 data on migration | **Rename to `data.v1.bak/`** (incompatible; no conversion exists) | Non-destructive, reversible, no disk doubling. Alt: tar-then-delete (worse: slow, disk) or delete (destructive — rejected). |
| 10 | `/health` in pass/fail logic | **No** — poll `/canvas`; log `/health` code as diagnostic | `/health` is undocumented in public docs; don't gate on undocumented behavior. |

## Script Section-by-Section Changes (`tasks/setup-openhands.sh`)

1. **Header doc block** — rewrite: "Deploys OpenHands Agent Canvas (all-in-one container)"; update KEY ACTIONS (health check now on `/canvas`), env var docs (new table from §Configuration Strategy), remove AGENT SERVER VARIABLES section, replace docker.sock SECURITY note with container-boundary note, update OUTPUTS (`data/` → `/home/openhands/.openhands`, `projects/` → `/projects`), update REFERENCE URLs to Agent Canvas docs.
2. **`usage()`** — update env var list and defaults (port 8000, image, `OPENHANDS_PROJECTS`, remove `OPENHANDS_WORKSPACE`/`AGENT_SERVER_*`); update examples/reference URL.
3. **Arg parsing, helpers source** — unchanged.
4. **CONFIGURATION block** — new defaults: `OPENHANDS_IMAGE=ghcr.io/openhands/agent-canvas`, `OPENHANDS_IMAGE_TAG=1.13.0`, `OPENHANDS_PORT=8000`, `OPENHANDS_PROJECTS=${OPENHANDS_PROJECTS:-${OPENHANDS_HOME}/projects}`; delete `OPENHANDS_WORKSPACE`, `AGENT_SERVER_IMAGE_REPOSITORY`, `AGENT_SERVER_IMAGE_TAG`, `AGENT_SERVER_USE_HOST_NETWORK`; keep Traefik trio.
5. **Cleanup trap** — unchanged.
6. **Pre-flight** — unchanged (`run_preflight_checks`, `ensure_proxy_network`, `ensure_traefik_running`, domain check).
7. **Existing-stack check** — **changed**: add generation detection + migration flow per §Migration Story (legacy markers `docker.openhands.dev`/`SANDBOX_VOLUMES`/`docker.sock`; `data` → `data.v1.bak` rename; `rm -f` old compose file). Port-conflict check unchanged (now default 8000).
8. **Directory creation** — `mkdir -p "${OPENHANDS_HOME}/data" "${OPENHANDS_PROJECTS}"`; chown both (pattern unchanged).
9. **`.env` helpers** — `sed_inplace` / `set_or_replace_kv` unchanged (note: `sed_inplace` remains defined-but-unused as today — out of scope).
10. **`.env` generation** — keep secrets + `OPENHANDS_IMAGE[_TAG]`/`PORT`/`HOME`/`PROXY_NETWORK`/`DOMAIN`; **add** `AUTOMATION_BASE_URL` (derived on `OPENHANDS_TRAEFIK`) and `VITE_DO_NOT_TRACK` (default `1`, only written if user didn't pre-set — use `: ${VITE_DO_NOT_TRACK:=1}` in the CONFIGURATION block); **remove** `OH_WEB_URL`, `SANDBOX_CONTAINER_URL_PATTERN`, `OPENHANDS_WORKSPACE`, `AGENT_SERVER_*`.
11. **Compose generation** — unchanged logic (copy the selected template if target absent); templates themselves replaced.
12. **Teardown & start** — unchanged (`down --remove-orphans`, `up -d --pull always`).
13. **Container verification** — unchanged (container name still `openhands`).
14. **Health check** — direct-mode URL → `http://localhost:${OPENHANDS_PORT}/canvas`; same 200/302/303 / 120s / 5s loop; add non-fatal `info` log of `GET /health` HTTP code after success (direct mode only). Traefik mode path unchanged.
15. **UFW** — `ufw_add_rule "$OPENHANDS_PORT" tcp "OpenHands Agent Canvas"`.
16. **Summary** — new access URLs (direct: `http://<host>:8000/canvas`; traefik: `https://<domain>/canvas`); data/projects paths; security notice rewrite; remove single-conversation + sandbox-port paragraphs; add backup one-liner and (on migrated machines) a "V1 data preserved at data.v1.bak/" line.

## One-line cross-task edit

- `tasks/setup-traefik.sh` — add `entrypoints.websecure.http.transport.respondingTimeouts.idle=3600s` (and `.read/.write` if the file already sets them) so live agent streams survive >180s idle behind Traefik.

## Documentation Updates

| File | Change |
|---|---|
| `docs/plans/openhands-integration.md` | Add blockquote at top: "⚠️ **Superseded** (2026-08-17) by `docs/plans/openhands-agent-canvas-setup.md` — the V1 Traditional Web App approach was replaced by Agent Canvas." No other edits. |
| `docs/plans/openhands-agent-canvas-setup.md` | **New file** — this plan. |
| `machine-config.yml.example` (`setup-openhands:` entry) | `description: Install OpenHands Agent Canvas (AI coding agent control center)`; `env:` → `OPENHANDS_HOME: /srv/openhands`, `OPENHANDS_PORT: '8000'`, `OPENHANDS_TRAEFIK: 'false'`. |
| `README.md` (`#### setup-openhands.sh`) | Rewrite: "Deploys OpenHands Agent Canvas — all-in-one container (UI at `/canvas`, port 8000), no docker.sock"; new env var list (`OPENHANDS_IMAGE` default `ghcr.io/openhands/agent-canvas`, `OPENHANDS_IMAGE_TAG` default `1.13.0`, `OPENHANDS_PORT` 8000, `OPENHANDS_PROJECTS`); features: no docker.sock, `/projects` mount, automations, health check on `/canvas`, UFW (direct), V1-migration note. |
| `CONTEXT.md` (Services) | "openhands — AI software developer agent (Agent Canvas: all-in-one Docker container with web UI at `/canvas`, agent execution, and scheduled automations)". |
| `skills/kwisatz-assistant/SKILL.md` (task table, ~line 134) | Keep `setup-openhands` row; update its one-line description to mention Agent Canvas / port 8000. |

## Verification / Testing Checklist

1. **Lint**: `shellcheck tasks/setup-openhands.sh` (and `tasks/setup-traefik.sh` if touched); `yamllint templates/openhands/*.yml`.
2. **Static validate**: stage a temp dir, write a throwaway `.env` with dummy keys, `docker compose -f templates/openhands/docker-compose.direct.yml config` (and traefik variant with `PROXY_NETWORK=proxy OPENHANDS_DOMAIN=x.test`) — interpolation must resolve.
3. **Image checks** (before committing defaults):
   - `docker pull ghcr.io/openhands/agent-canvas:1.13.0` succeeds (confirms tag exists).
   - `docker run --rm --entrypoint id ghcr.io/openhands/agent-canvas:1.13.0` → record UID/GID; confirm `chown 1000:1000` assumption or adjust §Permissions.
4. **Fresh install, direct mode** (test VM or `OPENHANDS_HOME=/tmp/oh-test`): script runs clean; `curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/canvas` → 200/302; UFW shows the 8000 rule; `.env` mode 600; `docker inspect openhands --format '{{.Mounts}}'` shows no docker.sock.
5. **Functional smoke (direct)**: open UI in browser → configure an LLM profile (Settings → LLM) → start a conversation → have the agent create/edit a file inside `projects/` → confirm persistence files appear under `data/agent-canvas/` → restart container (`docker compose restart`) → conversation still present.
6. **Idempotency**: re-run script on the finished install → prompt path, data intact, `.env` byte-identical (checksum before/after), compose file unchanged.
7. **Migration**: on a box with the V1 stack (or a fabricated V1 `docker-compose.yml` + `data/`): run script → legacy detected → `y` → V1 stack down, `data` renamed to `data.v1.bak`, new stack up, `/canvas` responds, no docker.sock in mounts; run again → Canvas-gen prompt path (not migration path).
8. **Traefik mode** (domain + Let's Encrypt): cert issued; `curl -sk https://<domain>/canvas` → 200; **WebSocket test** — open UI, run a long agent task, keep it running ≥ 200 s (past Traefik's default 180 s idle) with the new `respondingTimeouts.idle=3600s` in place → stream stays connected; check `docker logs traefik | grep <domain>` for upgrades.
9. **Automation sanity (optional, low-cost)**: create one scheduled automation; confirm `AUTOMATION_BASE_URL` value matches the access URL; confirm `automations.db` lives under `data/automation/`.
10. **Docs**: `grep -rn "docker.openhands.dev\|SANDBOX_VOLUMES\|AGENT_SERVER_\|:3001" README.md CONTEXT.md machine-config.yml.example skills/` returns nothing stale outside the "Superseded" plan.

## Open Questions (research gaps to resolve during implementation)

1. **GHCR tag list not enumerable anonymously** — only `latest` (docs) and `1.13.0` (README) are referenced. Confirm `1.13.0` pulls; if the tag scheme differs, pin whatever the README pins at that time.
2. **`/health`, `/ready`, `/alive` semantics undocumented** — we only log; verify response shape via `/openapi.json` (port 8000) before any future promotion to pass/fail.
3. **No official compose/systemd-for-Docker example** — our templates are derived from the documented `docker run` flags; treat as reference-quality, validate in step 4–8.
4. **Is Agent Canvas officially the default frontend?** Strongly implied (repo rebranded; legacy app labeled "Local GUI (Legacy)") but no explicit deprecation statement for V1. Doesn't block the refactor.
5. **Container `openhands` UID** — resolve in checklist step 3.
6. **`OH_AGENT_SERVER_VERSION`** — documented with a bogus example value (`0.1.0`); we do not set it (image pins its agent server at build). Do not add.
7. **Docker-image "public mode" (API-key entry screen) behavior** — npm `--public` has no documented Docker equivalent; we always set `LOCAL_BACKEND_API_KEY` explicitly, which is the documented safe path regardless.

## Implementation Checklist (execute in order)

- [ ] 1. `docker pull ghcr.io/openhands/agent-canvas:1.13.0`; record image UID/GID (`--entrypoint id`); confirm tag & chown assumption.
- [ ] 2. Replace `templates/openhands/docker-compose.direct.yml` with the new content (§Compose Templates).
- [ ] 3. Replace `templates/openhands/docker-compose.traefik.yml` with the new content.
- [ ] 4. Apply the `tasks/setup-openhands.sh` section changes (§Script Section-by-Section Changes), including the migration detection flow.
- [ ] 5. One-line `respondingTimeouts.idle=3600s` edit in `tasks/setup-traefik.sh`.
- [ ] 6. `shellcheck` both scripts; `yamllint` both templates; `docker compose config` both templates with a scratch `.env`.
- [ ] 7. Docs: supersede blockquote in `openhands-integration.md`; update `README.md`, `CONTEXT.md`, `machine-config.yml.example`, `SKILL.md`.
- [ ] 8. Save this plan as `docs/plans/openhands-agent-canvas-setup.md`.
- [ ] 9. Run the verification checklist (steps 4–10) on a test machine; fix the UID handling if step 1 revealed non-1000.
- [ ] 10. Mark this plan's status blockquote **Reviewed/Implemented** with the implementation date.

## Appendix A: Agent Canvas Quick Reference

Official minimal run (from docs; our templates encode this plus `restart`, secrets, and proxy labels):

```bash
mkdir -p ~/projects ~/.openhands

docker run -it --rm \
  -p 8000:8000 \
  -v ~/.openhands:/home/openhands/.openhands \
  -v ~/projects:/projects \
  ghcr.io/openhands/agent-canvas:latest
```

UI: `http://localhost:8000/canvas` · env: `PORT` (8000), `OH_SECRET_KEY`, `LOCAL_BACKEND_API_KEY` · sizing: 2 vCPU / 4 GB for single user.

## Appendix B: Source URLs

### Official Documentation (docs.openhands.dev)

| Topic | URL |
|---|---|
| Agent Canvas install / env vars / `--public` | https://docs.openhands.dev/openhands/usage/agent-canvas/setup |
| Agent Canvas overview (legacy-GUI designation) | https://docs.openhands.dev/openhands/usage/agent-canvas/overview |
| Agent Canvas Docker guide | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/docker |
| VM / Self-Hosted (firewall plan, nginx WS/SSE config, security checklist) | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/vm |
| Architecture (Agent Server / Automation Server) | https://docs.openhands.dev/openhands/usage/agent-canvas/architecture |
| Remote backend requirements | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/remote |
| First-time setup / onboarding | https://docs.openhands.dev/openhands/usage/agent-canvas/first-time-setup |
| LLM profiles (reachability note) | https://docs.openhands.dev/openhands/usage/agent-canvas/llm-profiles |
| Troubleshooting (keys, ports, mounts) | https://docs.openhands.dev/openhands/usage/agent-canvas/troubleshooting |
| Mobile access (SSH tunnel / Tailscale) | https://docs.openhands.dev/openhands/usage/agent-canvas/mobile-access |
| Kubernetes (Helm) — out of scope | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/kubernetes |
| Legacy V1 local setup | https://docs.openhands.dev/openhands/usage/run-openhands/local-setup |
| V1 environment variables reference | https://docs.openhands.dev/openhands/usage/environment-variables |
| Docs index | https://docs.openhands.dev/llms.txt |

### GitHub — OpenHands/OpenHands

| Resource | URL |
|---|---|
| README (beta badge, pinned `1.13.0` tag) | https://github.com/OpenHands/OpenHands |
| SELF_HOSTING.md (systemd unit, port map 18000/18001/8000, nginx) | https://github.com/OpenHands/OpenHands/blob/main/docs/SELF_HOSTING.md |
| docker/Dockerfile (user `openhands`, VOLUME/EXPOSE 8000) | https://github.com/OpenHands/OpenHands/blob/main/docker/Dockerfile |
| docker/entrypoint.sh (ingress routing, `/health`, key auto-gen, automation env) | https://github.com/OpenHands/OpenHands/blob/main/docker/entrypoint.sh |
| config/defaults.json (version pins, ports, paths) | https://github.com/OpenHands/OpenHands/blob/main/config/defaults.json |
| npm registry (versions, incubator warning) | https://registry.npmjs.org/@openhands/agent-canvas |

### Internal Codebase References

| File | Purpose |
|---|---|
| `tasks/setup-openhands.sh` | Script being refactored |
| `templates/openhands/docker-compose.{direct,traefik}.yml` | Templates being replaced |
| `tasks/setup-omnigent.sh` | Structural pattern reference (template copy, `set_or_replace_kv`, cleanup trap) |
| `lib/helpers.sh` | `run_preflight_checks`, `ensure_proxy_network`, `ensure_traefik_running`, `ufw_add_rule`, logging |
| `tasks/setup-traefik.sh` | Entry point for the `respondingTimeouts.idle` one-liner |
| `docs/plans/openhands-integration.md` | Superseded V1 plan; format model |
| `machine-config.yml.example` | `setup-openhands` registration entry |
