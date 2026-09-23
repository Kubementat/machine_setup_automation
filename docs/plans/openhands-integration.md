# OpenHands Docker Integration Plan

> Status: **Reviewed** — implementation plan finalized after review against repo conventions and current OpenHands documentation.
> Date: 2026-08-13
> Review Date: 2026-08-13

## Executive Summary

This plan outlines how to integrate OpenHands (AI coding agent platform) into our machine setup automation scripts. OpenHands runs AI agents that can write code, run commands, and interact with repositories in sandboxed Docker containers. The setup will follow our existing patterns: environment-variable-driven configuration, Traefik reverse proxy integration, template-based docker-compose generation, and idempotent scripts.

## What is OpenHands?

OpenHands is an open-source AI software developer agent that can:
- Read, write, and edit code in mounted project directories
- Execute shell commands in sandboxed containers
- Browse the web, use MCP tools, and interact with Git
- Run as a web UI with real-time conversation interface

**Key architecture insight**: OpenHands has two deployment models:
1. **Agent Canvas** (newer): All-in-one container with client + backend + agent server. Port 8000. Uses `ghcr.io/openhands/agent-canvas`.
2. **Traditional OpenHands Web App** (V1): Separate app container + dynamically spawned agent-server sandbox containers. Port 3001. Uses `docker.openhands.dev/openhands/openhands`.

For our use case, we use the **Traditional OpenHands Web App** approach because:
- Matches our repo pattern: a docker-compose service fronted by Traefik on port 3001, with the app spawning ephemeral sandbox containers via the Docker socket
- Uses docker-compose.yml generation consistent with our other services (`setup-omnigent.sh`, `setup-openwebui.sh`)
- The web app model is the one our Traefik + UFW + host-networking setup can proxy cleanly
- Agent Canvas is a distinct "control center" product and would be a larger divergence from our conventions

> **Decision (Open Question 1 — Agent Canvas vs Traditional):** Use the **Traditional Web App**. It is the best fit for a docker-compose + Traefik service in this repo. Agent Canvas is documented as an alternative in Appendix A but is out of scope for this task.

## Research Sources (Summary)

See **Appendix B** for the complete list of all URLs consulted during research.

| Source | URL | Notes |
|--------|-----|-------|
| Agent Canvas Docker docs | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/docker | Official Docker setup |
| VM/Self-Hosted docs | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/vm | Remote deployment patterns |
| Docker Sandbox docs | https://docs.openhands.dev/openhands/usage/sandboxes/docker | Reverse proxy configuration |
| Environment Variables | https://docs.openhands.dev/openhands/usage/environment-variables | Complete env var reference (V1) |
| Configuration Options | https://docs.openhands.dev/openhands/usage/advanced/configuration-options | V1 configuration model |
| GitHub repo | https://github.com/OpenHands/OpenHands | Source code, docker-compose.yml |
| CORS fix PR #12489 | https://github.com/OpenHands/OpenHands/pull/12489 | Remote access fixes (v1.3.0+) |
| Remote deployment PR #12660 | https://github.com/OpenHands/OpenHands/pull/12660 | WebSocket/URL fixes |

---

## Architecture Overview

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Reverse Proxy                            │
│                         (Traefik)                               │
│                                                                 │
│  https://openhands.example.com ──► Port 3001 (app web UI)       │
└────────────────────────┬────────────────────────────────────────┘
                         │
          ┌──────────────┴──────────────┐
          │                             │
┌─────────▼─────────┐      ┌───────────▼───────────┐
│  OpenHands App    │      │  Docker Host          │
│  Container        │──────►  Socket               │
│  (Port 3001)      │      │  /var/run/docker.sock │
│                   │      └───────────┬───────────┘
│  - Web UI         │                  │
│  - Backend API    │      ┌───────────▼───────────┐
│  - Conversation   │      │  Agent-Server         │
│    Management     │      │  Sandbox Containers   │
│  - Sandbox Mgr    │      │  (per conversation)   │
└───────────────────┘      │                     │
                           │  - Port 8000 (agent) │
        Volumes:           │  - Port 8001 (VSCode)│
  ${OPENHANDS_HOME}/data ──► /.openhands          │  - Port 8011 (worker)  │
                           │  - Port 8012 (worker) │
                           └───────────────────────┘
```

### Critical Design Decision: Docker Socket Mount

OpenHands **requires** mounting `/var/run/docker.sock` into the app container because:
- It spawns isolated agent-server sandbox containers for each conversation
- Each sandbox runs the actual AI agent executing commands
- Sandboxes are ephemeral — created per conversation, destroyed on completion

**Security implication**: The OpenHands container has full Docker host access. This is by design — the agent executes arbitrary commands. Treat the host as trusted infrastructure.

---

## Configuration Strategy

### Directory Layout

Following our conventions (base dir `/srv/openhands`):
```
/srv/openhands/
├── docker-compose.yml       # Generated compose file
├── .env                     # Secrets and sensitive config (mode 600)
├── data/                    # Persistent OpenHands data -> mounted to /.openhands
└── workspace/               # Host workspace mounted into agent sandboxes (read-write)
```

### Environment Variables

Naming follows the repo convention: `OPENHANDS_*` for OpenHands-specific config, `PROXY_NETWORK` for the shared Traefik network, matching `OMNIGENT_*`/`OPENWEBUI_*` style.

#### Core Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENHANDS_HOME` | `/srv/openhands` | Base directory for OpenHands data |
| `OPENHANDS_PORT` | `3001` | Host port for direct access mode (maps to container port 3001) |
| `OPENHANDS_IMAGE` | `docker.openhands.dev/openhands/openhands` | App container image repository |
| `OPENHANDS_IMAGE_TAG` | `latest` | App image tag — **pin to the current stable release at implementation time** (docs recommend a pinned release, not `latest`) |
| `OPENHANDS_WORKSPACE` | `/srv/openhands/workspace` | Host directory mounted into agent sandboxes |

#### Agent Server (Sandbox) Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_SERVER_IMAGE_REPOSITORY` | `ghcr.io/openhands/agent-server` | Agent sandbox image repo |
| `AGENT_SERVER_IMAGE_TAG` | *(empty = auto-select)* | Agent sandbox image tag. **Leave empty** so the app auto-selects the matching SDK release (docs/issue #12867 recommend NOT pinning, or pointing at the latest SDK tag) |
| `AGENT_SERVER_USE_HOST_NETWORK` | `true` | Use host networking (fixed ports 8000/8001/8011/8012). See Reverse Proxy section |

#### Reverse Proxy / Remote Access

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENHANDS_TRAEFIK` | `false` | Enable Traefik integration |
| `OPENHANDS_DOMAIN` | *(required if traefik)* | Public domain for OpenHands |
| `OH_WEB_URL` | *(derived)* | Externally reachable URL. **CORS origin + callbacks only** — it does NOT control sandbox URLs |
| `SANDBOX_CONTAINER_URL_PATTERN` | `http://localhost:{port}` | URL pattern the browser uses to reach each sandbox. Recommended V1 form: `OH_SANDBOX_CONTAINER_URL_PATTERN` (both are accepted; use the legacy `SANDBOX_CONTAINER_URL_PATTERN` for compatibility) |

#### Security

| Variable | Default | Description |
|----------|---------|-------------|
| `OH_SECRET_KEY` | *(auto-generated)* | Encrypts stored settings/secrets at rest |
| `LOCAL_BACKEND_API_KEY` | *(auto-generated)* | API key for backend access (required for remote/public backend auth) |
| `JWT_SECRET` | *(auto-generated by app)* | App auth secret — auto-generated; not set explicitly |

> **Correction vs. earlier draft:** `WORKSPACE_BASE` and `WORKSPACE_MOUNT_PATH` are **deprecated** in current OpenHands. The workspace must be mounted via `SANDBOX_VOLUMES` (`host_path:container_path:mode`), not `WORKSPACE_MOUNT_PATH`. The plan now uses `SANDBOX_VOLUMES=${OPENHANDS_WORKSPACE}:/workspace:rw` and mounts the workspace into each *sandbox* (not the app container).

---

## Reverse Proxy Integration — The Hard Part

### The Problem

OpenHands spawns agent-server sandbox containers with **randomly assigned host ports**. The frontend connects to these sandboxes via WebSocket using URLs from `container_url_pattern` (default `http://localhost:{port}`). Behind a reverse proxy, this breaks because:

1. `localhost` is wrong — the browser needs the public domain / host.
2. Random ports can't be statically routed in Traefik.

**Key fact:** `OH_WEB_URL` does **not** control sandbox URLs — it only adds the origin to the sandbox's CORS allow-list. The sandbox URL host is set by `SANDBOX_CONTAINER_URL_PATTERN` / `OH_SANDBOX_CONTAINER_URL_PATTERN`.

### Solution: Host Networking (Default, single-sandbox)

Set `AGENT_SERVER_USE_HOST_NETWORK=true`. Agent-server sandbox containers use **fixed host ports** instead of random ports:

| Port | Service |
|------|---------|
| 8000 | Agent server (main) |
| 8001 | VS Code server |
| 8011 | Worker 1 |
| 8012 | Worker 2 |

**Pros**: Simple static routing, predictable networking, works behind Traefik for the UI.
**Cons**: Only ONE sandbox at a time (ports collide). OpenHands logs a warning when host networking is used with `max_num_sandboxes > 1`. Multi-sandbox remote access requires a regex-based proxy (e.g. nginx) and dynamic ports — out of scope for this repo.

### Our Recommendation (Hybrid)

1. OpenHands UI behind Traefik at `https://openhands.example.com` (traefik mode) or `http://host:3001` (direct mode).
2. Agent-server sandboxes use host networking (`AGENT_SERVER_USE_HOST_NETWORK=true`).
3. Document the single-conversation limitation.
4. Sandboxes are reached on their fixed host ports (8000–8012). In direct mode, open these in UFW. In Traefik mode, the UI is proxied; sandbox access on the fixed host ports is documented as an advanced configuration (Traefik's Docker provider cannot discover host-networked ephemeral sandbox containers, so sandbox ports are exposed directly on the host).

> **Note:** Multi-sandbox dynamic-port access via `SANDBOX_CONTAINER_URL_PATTERN=https://domain:{port}` requires a regex-capable proxy (nginx) and a firewall allowing a dynamic port range. Documented as a future extension; **not** implemented in this task.

---

## Implementation Plan

### Script: `tasks/setup-openhands.sh`

Follow the `setup-omnigent.sh` structure exactly (set -euo pipefail, cleanup trap, `lib/helpers.sh`, template-based compose generation, idempotent .env with `set_or_replace_kv`).

#### Steps

1. **Pre-flight checks**
   - `run_preflight_checks` (docker, daemon, openssl, curl)
   - When `OPENHANDS_TRAEFIK=true`: `ensure_proxy_network`, `ensure_traefik_running`, and require `OPENHANDS_DOMAIN`
   - Direct mode: check port `OPENHANDS_PORT` is free (ss/netstat), like setup-omnigent.sh

2. **Check for existing stack**
   - If `docker-compose.yml` exists, prompt to tear down & re-create (data volumes preserved), identical to setup-omnigent.sh

3. **Create persistent host directories**
   - `sudo mkdir -p "${OPENHANDS_HOME}/data" "${OPENHANDS_WORKSPACE}"`; chown to the user

4. **Generate `.env` file** (only on first run — never overwrite existing secrets)
   - Use `set_or_replace_kv` awk pattern from setup-omnigent.sh
   - Auto-generate: `OH_SECRET_KEY="$(openssl rand -hex 32)"`, `LOCAL_BACKEND_API_KEY="$(openssl rand -hex 32)"`
   - Set derived: `OH_WEB_URL` (`https://${OPENHANDS_DOMAIN}` if traefik, else `http://localhost:${OPENHANDS_PORT}`), `SANDBOX_CONTAINER_URL_PATTERN`
   - Set non-secret config: `OPENHANDS_IMAGE`, `OPENHANDS_IMAGE_TAG`, `OPENHANDS_PORT`, `OPENHANDS_WORKSPACE`, `AGENT_SERVER_IMAGE_REPOSITORY`, `AGENT_SERVER_IMAGE_TAG`, `AGENT_SERVER_USE_HOST_NETWORK`
   - `chmod 600` the .env

5. **Generate docker-compose.yml from template**
   - Copy `templates/openhands/docker-compose.direct.yml` or `docker-compose.traefik.yml` (never inline heredoc — repo convention)
   - Only write if not already present (preserve user modifications), like setup-omnigent.sh

6. **Teardown & start**
   - `docker compose down --remove-orphans 2>/dev/null || true` (preserve volumes)
   - `docker compose up -d --pull always`

7. **Verify container running**
   - `docker ps` shows `openhands` container; check restart count (restart-loop detection like setup-omnigent.sh)

8. **Health check**
   - Direct mode: poll `http://localhost:${OPENHANDS_PORT}` for 200/302/303 up to 120s
   - Traefik mode: skip direct health check (TLS via domain), verify container is running

9. **UFW rules (direct mode only)**
   - `ufw_add_rule "$OPENHANDS_PORT" tcp "OpenHands Web UI"`
   - If remote sandbox access is needed: `ufw_add_rule 8000/tcp`, `8001/tcp`, `8011:8012/tcp` (agent server ports). Optional, documented in summary.

10. **Summary output**
    - Access URL, data dir, compose file, .env path, management commands, security notice (docker.sock + secrets), single-conversation limitation note

### Templates: `templates/openhands/`

Two templates, matching the omnigent pattern (`# yamllint disable rule:line-length`, `name:` top-level key, `.env`-sourced variables). Both mount the workspace into sandboxes via `SANDBOX_VOLUMES` (not into the app container).

#### `docker-compose.direct.yml`

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
      - "${OPENHANDS_PORT}:3001"
    environment:
      - AGENT_SERVER_IMAGE_REPOSITORY=${AGENT_SERVER_IMAGE_REPOSITORY:-ghcr.io/openhands/agent-server}
      - AGENT_SERVER_IMAGE_TAG=${AGENT_SERVER_IMAGE_TAG:-}
      - AGENT_SERVER_USE_HOST_NETWORK=true
      - SANDBOX_VOLUMES=${OPENHANDS_WORKSPACE}:/workspace:rw
      - OH_SECRET_KEY=${OH_SECRET_KEY:?set OH_SECRET_KEY in .env}
      - LOCAL_BACKEND_API_KEY=${LOCAL_BACKEND_API_KEY:?set LOCAL_BACKEND_API_KEY in .env}
      - OH_WEB_URL=${OH_WEB_URL:-http://localhost:3001}
      - SANDBOX_CONTAINER_URL_PATTERN=${SANDBOX_CONTAINER_URL_PATTERN:-http://localhost:{port}}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${OPENHANDS_HOME}/data:/.openhands
    extra_hosts:
      - "host.docker.internal:host-gateway"
    stdin_open: true
    tty: true
    networks:
      - openhands

networks:
  openhands:
    external: false
```

#### `docker-compose.traefik.yml`

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
      - AGENT_SERVER_IMAGE_REPOSITORY=${AGENT_SERVER_IMAGE_REPOSITORY:-ghcr.io/openhands/agent-server}
      - AGENT_SERVER_IMAGE_TAG=${AGENT_SERVER_IMAGE_TAG:-}
      - AGENT_SERVER_USE_HOST_NETWORK=true
      - SANDBOX_VOLUMES=${OPENHANDS_WORKSPACE}:/workspace:rw
      - OH_SECRET_KEY=${OH_SECRET_KEY:?set OH_SECRET_KEY in .env}
      - LOCAL_BACKEND_API_KEY=${LOCAL_BACKEND_API_KEY:?set LOCAL_BACKEND_API_KEY in .env}
      - OH_WEB_URL=https://${OPENHANDS_DOMAIN}
      - SANDBOX_CONTAINER_URL_PATTERN=https://${OPENHANDS_DOMAIN}:{port}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${OPENHANDS_HOME}/data:/.openhands
    extra_hosts:
      - "host.docker.internal:host-gateway"
    stdin_open: true
    tty: true
    labels:
      - 'traefik.enable=true'
      - 'traefik.docker.network=${PROXY_NETWORK}'
      - 'traefik.http.routers.openhands.rule=Host(`${OPENHANDS_DOMAIN}`)'
      - 'traefik.http.routers.openhands.entrypoints=websecure'
      - 'traefik.http.routers.openhands.tls.certresolver=letsencrypt'
      - 'traefik.http.services.openhands.loadbalancer.server.port=3001'
    networks:
      - openhands
      - ${PROXY_NETWORK}

networks:
  openhands:
    external: false
  ${PROXY_NETWORK}:
    external: true
```

### UFW Rules

Direct mode (via `ufw_add_rule` helper from `lib/helpers.sh`):
```bash
ufw_add_rule "$OPENHANDS_PORT" tcp "OpenHands Web UI"
```

Optional — remote browser access to host-networked sandbox ports:
```bash
ufw_add_rule 8000 tcp "OpenHands Agent Server"
ufw_add_rule 8001 tcp "OpenHands VS Code Server"
ufw_add_rule 8011:8012 tcp "OpenHands Worker Ports"
```

---

## Security Considerations

### Critical Risks

1. **Docker socket mount**: Full host Docker access. Mitigation: Run OpenHands on a trusted server only.

2. **Agent executes arbitrary commands**: The AI agent can run any command in its sandbox. Mitigation:
   - Use host networking only for trusted deployments
   - Consider running OpenHands on a dedicated machine

3. **Stored secrets/API keys**: Stored encrypted in `/.openhands` volume, protected by `OH_SECRET_KEY`. Mitigation:
   - Use a strong auto-generated `OH_SECRET_KEY`
   - Restrict access to `${OPENHANDS_HOME}/data` (mode 600 .env, private data dir)

4. **Workspace access**: Agent can read/write all files in the mounted workspace (`SANDBOX_VOLUMES=${OPENHANDS_WORKSPACE}:/workspace:rw`). Mitigation:
   - Only mount directories you trust the agent to access
   - Use a dedicated workspace directory (`/srv/openhands/workspace`)

### Security Checklist

- [ ] Run on trusted infrastructure only
- [ ] Use strong `OH_SECRET_KEY` (auto-generated by script, stored in mode-600 .env)
- [ ] Use strong `LOCAL_BACKEND_API_KEY` (auto-generated by script)
- [ ] Enable HTTPS via Traefik for remote access
- [ ] Restrict SSH access to the host
- [ ] Keep Docker and OpenHands images updated
- [ ] Review agent actions in conversations
- [ ] Do not expose `SANDBOX_CONTAINER_URL_PATTERN` with a public domain unless sandbox ports are firewalled to trusted clients

---

## Known Limitations & Decisions on Open Questions

### Limitations

1. **Single conversation with host networking**: When `AGENT_SERVER_USE_HOST_NETWORK=true`, only one sandbox can run at a time (fixed-port collisions).
2. **Docker socket requirement**: Cannot run without Docker socket mount — no fully isolated deployment option.
3. **Sandbox proxy limitation**: Traefik's Docker provider cannot discover host-networked ephemeral sandbox containers; sandbox ports (8000–8012) are exposed directly on the host.
4. **Remote browser access requires config**: `OH_WEB_URL` (CORS) and `SANDBOX_CONTAINER_URL_PATTERN` (sandbox URL hostname) must be set to reach sandboxes from a non-local browser.

### Open Questions — Decisions

1. **Agent Canvas vs Traditional?** → **Traditional Web App (V1)**. Best fit for a docker-compose + Traefik service; Agent Canvas is a separate control-center product and out of scope.

2. **GPU support?** → **No, defer.** Keep the initial implementation CPU-only. GPU support is a one-line future extension (`SANDBOX_ENABLE_GPU=true` + `SANDBOX_CUDA_VISIBLE_DEVICES` + nvidia runtime). Noted in the plan as a documented extension; not added to the first implementation (karpathy: no speculative features).

3. **Multiple workspace directories?** → **No, single workspace.** One host workspace (`OPENHANDS_WORKSPACE` → mounted at `/workspace:rw` in every sandbox). Multiple workspaces can be layered later via comma-separated `SANDBOX_VOLUMES` entries. Keep it simple for v1.

4. **LLM provider pre-configuration?** → **Leave to the UI.** OpenHands stores LLM provider/model/key via its Settings UI (encrypted with `OH_SECRET_KEY`). We do not pre-configure providers via env vars. Document that users configure their provider in the web UI after first login.

---

## Next Steps

1. **Create templates** — `templates/openhands/docker-compose.direct.yml` and `docker-compose.traefik.yml` (contents above).
2. **Implement script** — `tasks/setup-openhands.sh` following `setup-omnigent.sh` patterns (env-driven, idempotent, template-based, UFW direct-mode, health check).
3. **Verify image tags** — confirm the current stable `docker.openhands.dev/openhands/openhands` release tag at implementation time; leave `AGENT_SERVER_IMAGE_TAG` empty (auto-select).
4. **Lint** — `shellcheck` on the script, `yamllint` on both templates, `docker compose config` to validate.
5. **Test locally** — verify direct mode and Traefik mode; confirm the app spawns a sandbox and a conversation works end-to-end.
6. **Test remote access** — verify CORS (`OH_WEB_URL`) and sandbox URL (`SANDBOX_CONTAINER_URL_PATTERN`) work from an external browser.
7. **Register in the repo** (documentation updates):
   - `machine-config.yml.example` — add a `setup-openhands:` entry (`enabled: false`, description, `env: OPENHANDS_HOME`, `OPENHANDS_PORT`, `OPENHANDS_TRAEFIK`)
   - `README.md` — add a `#### setup-openhands.sh` section describing the task and its environment variables
   - `CONTEXT.md` — add **openhands** to the Services terms list
   - `skills/kwisatz-assistant/SKILL.md` — add `setup-openhands` to the **AI Agents** task table (line ~134)

---

## Appendix A: Quick Reference

### Minimal Docker Run Command (for testing, Traditional Web App)

```bash
mkdir -p ~/.openhands ~/projects

docker run -it --rm \
  -p 3001:3001 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  --add-host host.docker.internal:host-gateway \
  -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
  -e SANDBOX_VOLUMES="$HOME/projects:/workspace:rw" \
  -e AGENT_SERVER_USE_HOST_NETWORK=true \
  docker.openhands.dev/openhands/openhands:<stable-tag>
```

Access at `http://localhost:3001`.

### Agent Canvas Alternative (simpler, port 8000 — NOT our target)

```bash
mkdir -p ~/.openhands ~/projects

docker run -it --rm \
  -p 8000:8000 \
  -v ~/.openhands:/home/openhands/.openhands \
  -v ~/projects:/projects \
  -e OH_SECRET_KEY="$(openssl rand -hex 32)" \
  -e LOCAL_BACKEND_API_KEY="$(openssl rand -hex 32)" \
  ghcr.io/openhands/agent-canvas:latest
```

Access at `http://localhost:8000/canvas`.

---

## Appendix B: Complete Source URLs

All URLs consulted during research for this plan, organized by category.

### Official Documentation (docs.openhands.dev)

| Topic | URL |
|-------|-----|
| Agent Canvas Docker setup | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/docker |
| VM / Self-Hosted Installation | https://docs.openhands.dev/openhands/usage/agent-canvas/backend-setup/vm |
| Docker Sandbox (reverse proxy guide) | https://docs.openhands.dev/openhands/usage/sandboxes/docker |
| Environment Variables Reference | https://docs.openhands.dev/openhands/usage/environment-variables |
| Configuration Options | https://docs.openhands.dev/openhands/usage/advanced/configuration-options |
| Local Setup (run-openhands) | https://docs.openhands.dev/openhands/usage/run-openhands/local-setup |
| Documentation Index (llms.txt) | https://docs.openhands.dev/llms.txt |

### GitHub — OpenHands/OpenHands Repository

| Resource | URL |
|----------|-----|
| Main repository | https://github.com/OpenHands/OpenHands |
| README.md (main branch) | https://github.com/OpenHands/OpenHands/blob/main/README.md |
| docker-compose.yml (main) | https://github.com/OpenHands/OpenHands/blob/main/docker-compose.yml |
| docker-compose.yml (commit 11d4ecf2) | https://github.com/OpenHands/OpenHands/blob/11d4ecf2/docker-compose.yml |
| docker-compose.yml (commit 3059ac42) | https://github.com/OpenHands/OpenHands/blob/3059ac42/docker-compose.yml |
| docker-compose.yml (commit 15423fbe) | https://github.com/OpenHands/OpenHands/blob/15423fbe/docker-compose.yml |
| docker-compose.yml (commit 3ec999e8) | https://github.com/OpenHands/OpenHands/blob/3ec999e8/docker-compose.yml |
| config.template.toml | https://github.com/OpenHands/OpenHands/blob/main/config.template.toml |
| containers/app/Dockerfile | Referenced via docker-compose.yml |
| .env.sample | https://github.com/OpenHands/OpenHands/blob/main/.env.sample |

### GitHub — Pull Requests

| PR | URL | Relevance |
|----|-----|-----------|
| #12489: Add CORS origins support | https://github.com/OpenHands/OpenHands/pull/12489 | CORS fix for remote browser access (v1.3.0+) |
| #12660: Fix remote deployment issues | https://github.com/OpenHands/OpenHands/pull/12660 | WebSocket, agent URLs, workspace isolation fixes |
| #12527: Use correct agent-server image | https://github.com/OpenHands/OpenHands/pull/12527 | Fixed AGENT_SERVER_IMAGE_REPOSITORY default |
| #12236: host.docker.internal support | Referenced in issues | Required for sandbox networking |
| #12445: Host networking mode | Referenced in release notes | AGENT_SERVER_USE_HOST_NETWORK support |
| agent-canvas #790: auth modes | https://github.com/OpenHands/agent-canvas/pull/790 | LOCAL_BACKEND_API_KEY replaces SESSION_API_KEY |

### GitHub — Issues

| Issue | URL | Relevance |
|-------|-----|-----------|
| #12560: WebSocket localhost bug | https://github.com/OpenHands/OpenHands/issues/12560 | Hardcoded localhost URLs for remote access |
| #12581: "Disconnected" / localhost | https://github.com/OpenHands/OpenHands/issues/12581 | Traefik setup with host networking workaround |
| #12500: Sandbox container connection | https://github.com/OpenHands/OpenHands/issues/12500 | host.docker.internal connectivity issues |
| #12502: GUI "Disconnected" | https://github.com/OpenHands/OpenHands/issues/12502 | Remote access configuration |
| #12519: WebSocket localhost bug | Referenced as duplicate | Same as #12560 |
| #12679: Cannot use from different machine | Referenced as duplicate | Same as #12560 |
| #12561: WEB_HOST CORS origin bug | https://github.com/OpenHands/OpenHands/issues/12561 | OH_WEB_URL / SANDBOX_CONTAINER_URL_PATTERN remote access |
| #12867: Remote sandbox connection | https://github.com/OpenHands/OpenHands/issues/12867 | OH_WEB_URL + SANDBOX_CONTAINER_URL_PATTERN for remote browsers; pin release not `latest` |
| #8422: Docker Runtime URL localhost | https://github.com/OpenHands/OpenHands/issues/8422 | DOCKER_HOST_ADDR not used for browser connections |
| #5392: Provide docker-compose.yml | https://github.com/OpenHands/OpenHands/issues/5392 | Original request for docker-compose.yml |

### GitHub — Releases

| Release | URL | Relevance |
|---------|-----|-----------|
| v1.3.0 (2026-02-02) | https://github.com/OpenHands/OpenHands/releases/tag/1.3.0 | Added CORS support, host networking mode |

### Third-Party Documentation / Analysis

| Source | URL | Relevance |
|--------|-----|-----------|
| DeepWiki: Installation | https://deepwiki.com/OpenHands/OpenHands/2.1-installation | Dependency versions, installation methods |
| DeepWiki: Deployment Options | https://deepwiki.com/OpenHands/OpenHands/3.6-deployment-options | Docker Compose, Kubernetes, dev container details |

### Web Search Queries Used

| Query | Purpose |
|-------|---------|
| "openhands docker installation setup 2026" | General setup documentation |
| "openhands self-hosted docker-compose configuration" | Production docker-compose patterns |
| "openhands reverse proxy traefik nginx self-hosted remote access SANDBOX_CONTAINER_URL_PATTERN" | Reverse proxy integration specifics |
| "OpenHands docker-compose.yml OH_SECRET_KEY LOCAL_BACKEND_API_KEY OH_WEB_URL example" | Verify env vars against current docs |
| "OpenHands LOCAL_BACKEND_API_KEY docker openhands image environment" | Confirm LOCAL_BACKEND_API_KEY semantics |

### Internal Codebase References

| File | Purpose |
|------|---------|
| tasks/setup-omnigent.sh | Primary reference — template-based compose, .env with set_or_replace_kv, UFW, health check, idempotency |
| tasks/setup-openwebui.sh | Reference for script structure, Traefik integration pattern |
| tasks/setup-forgejo.sh | Reference for docker-compose generation pattern |
| tasks/setup-traefik.sh | Reference for proxy network setup |
| lib/helpers.sh | Shared utility functions (preflight checks, UFW, etc.) |
| templates/omnigent/docker-compose.traefik.yml | Reference for template-based compose generation |
| templates/omnigent/docker-compose.direct.yml | Reference for direct-mode template |
| machine-config.yml.example | Registration entry for new tasks |
| skills/kwisatz-assistant/SKILL.md | Task table to update (AI Agents category) |
