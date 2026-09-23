# Automations

The list of all automated software components in this repository.
For each of the scripts you can run the script with the `--help` parameter to display all environment configuration and script parameters.
E.g. `./tasks/setup-basics.sh --help`

### System & Infrastructure

#### `setup-basics.sh`
Installs common system packages (curl, git, python3, etc.), **uv** Python package manager, **herdr** CLI tool, Node.js/npm, and the **huggingface-cli**.

#### `setup-docker.sh`
Installs Docker Engine from the official Docker repository, adds the current user to the `docker` group and verifies the installation.

#### `setup-nvidia-container.sh`
Makes an existing GPU usable from containers via **CDI** (Container Device Interface). Installs the NVIDIA Container Toolkit when missing, generates `/etc/cdi/nvidia.yaml`, and installs an apt hook that regenerates the spec after a driver upgrade. Prerequisite for every GPU task (`setup-colqwen.sh`, `setup-vllm.sh`, `setup-vllm-omni.sh`). Does **not** install the GPU driver itself.

**Why CDI and not `deploy.resources.reservations.devices`:**
- The legacy path injects `/dev/nvidia*` from an OCI prestart hook, *after* runc created the container's systemd scope, so systemd never learns about those device nodes
- A later `systemctl daemon-reload` (snapd triggers one every few hours) then rebuilds the scope's cgroup device filter and silently revokes GPU access from the **running** container — CUDA fails while the container keeps answering `/health` with 200
- CDI injects the devices into the OCI spec *before* container creation, so a reload re-applies them

**Why the apt hook:**
- A CDI spec pins version-suffixed driver libraries (`libcuda.so.580.142`); a driver upgrade renames them and containers fail to start with `unresolvable CDI devices nvidia.com/gpu=all`
- The hook regenerates the spec in the same apt transaction that replaced the driver
- Manual equivalent: `sudo nvidia-cdi-refresh` (`--check` reports staleness without writing, `--force` regenerates unconditionally)

#### `setup-traefik.sh`
Deploys production-ready Traefik v3 reverse proxy with Docker Compose, TLS via Let's Encrypt, security headers, rate limiting, and optional protected dashboard.

**See also:** [README_TRAEFIK.md](README_TRAEFIK.md) for full documentation

#### `setup-upstream-kernel.sh`
Prepares the Zabbly mainline kernel apt repository on Ubuntu 22.04/24.04 LTS, providing access to the latest stable Linux kernels.

**Notes:**
- Requires Secure Boot to be disabled in BIOS/UEFI
- May require DKMS rebuild for NVIDIA proprietary drivers
- Officially supports Ubuntu Noble (24.04) and Jammy (22.04)

#### `setup-sshd.sh`
Installs OpenSSH server and configures it through the managed drop-in
`/etc/ssh/sshd_config.d/99-machine-setup.conf` (the main `sshd_config` is never
touched). Lockout-safe: `PasswordAuthentication no` only when a usable key is
in `~/.ssh/authorized_keys`; when moving the port, the old/live port keeps
listening; the new port is allowed in UFW before the restart; on
socket-activated systems (Ubuntu 24.04+ default, `ssh.socket`) the socket is
disabled for a port move — a socket-activated sshd would not bind the new
port; `sshd -t` validates before any restart (invalid drop-in is reverted) and
the effective config is proven with `sshd -T` afterwards. An unchanged
drop-in does not trigger a restart.

#### `configure-firewall.sh`
Sets up **UFW** rules for the SSH port plus any explicitly requested ports —
each service's own setup script opens its port (no speculative rules).
Lockout-safe: over SSH it refuses to enable UFW while the live session's port
would be cut, and the first remote enable arms the
`machine-setup-ufw-rollback` timer (see below).

#### `setup-fail2ban.sh`
Installs **fail2ban** (including the Python 3.12 `pyasynchat` compatibility fix) and configures the jail to monitor the custom SSH port, protecting SSH from brute-force attacks.

---

### AI & LLM Services

#### `setup-lm-studio.sh`
Downloads the specified LM Studio AppImage, creates a desktop entry, an optional start script, and optionally installs the **llmster** CLI (`lms`).

#### `setup-llama-cpp.sh`
Builds and installs llama.cpp from source with auto or manual GPU backend selection. Skips install if binaries are already present.

#### `setup-openwebui.sh`
Deploys Open WebUI using Docker Compose, connecting to an external LM Studio instance for AI model inference. Supports both direct access mode and Traefik reverse-proxy integration.

**Features:**
- Direct mode: Accessible at `http://localhost:3333`
- Traefik mode: Accessible via custom domain with TLS
- Secure secret key: generated on first run, stored in `.env` (mode 600), reused on re-runs (never rotated); `docker-compose.yml` keeps only a literal `${WEBUI_SECRET_KEY}` placeholder resolved from the project `.env`
- Creates convenience start script

#### `setup-opencode.sh`
Installs the Opencode AI coding agent. By default only the CLI is installed (npm). `OPENCODE_SERVICE=true` additionally installs the `opencode` systemd service; `USE_DOCKER=true` deploys the Opencode server as a Docker Compose stack (direct or Traefik mode).

#### `setup-llama-swap.sh`
Deploys llama-swap, a multi-model LLM proxy with hot-swap support, as a native systemd service. Downloads the Go binary from GitHub releases and generates a comprehensive `config.yaml` with all available options documented.

**Features:**
- Hot-swap between multiple LLM models without restarting
- OpenAI-compatible API at `/v1/chat/completions`
- Web UI at `/ui`
- Health check endpoint at `/health`
- Comprehensive config with all options documented

#### `setup-colqwen.sh`
Generates a ColQwen2.5 embedding-service Docker project (FastAPI + colpali-engine on an NVIDIA NGC PyTorch base image). Serves multi-vector embeddings (dim 128) for document images and text queries — the retrieval side of visual document RAG. The script only generates the project; build and start it yourself. Models are mounted read-only from the HF cache at the identical path (adapter `base_model_name_or_path` entries resolve) and are never downloaded (fully offline: `HF_HUB_OFFLINE=1`).

**Features:**
- `POST /embed/queries` and `POST /embed/images` (multi-vector, one embedding per input, in order)
- `GET /health` readiness probe (200 only after the model is loaded)
- Fails loudly instead of serving wrong data: build aborts if pip replaced the NGC CUDA torch; startup aborts if LoRA adapter weights were silently dropped
- Generated `./test.sh` smoke test (health, embeddings incl. dim check, error cases)
- Tested combination for CUDA 13.0 / driver 580.x hosts (e.g. DGX Spark): NGC `25.10-py3` + colpali-engine `0.3.13` — see comments in the generated `.env` before changing versions

#### `setup-vllm.sh`
Deploys vLLM as a Docker-based OpenAI-compatible inference server. Supports NVIDIA (CUDA), AMD (ROCm), and CPU backends with auto-detection. Mounts the HuggingFace cache directory so models downloaded via `huggingface-cli` are automatically available.

**Features:**
- Auto-detects GPU backend (NVIDIA, AMD, or CPU fallback)
- Multi-GPU tensor parallelism support
- LM Studio models directory auto-mount
- Optional Traefik reverse-proxy integration
- Input validation for all configuration values
- Supports `--nvidia`, `--amd`, `--cpu`, `--force`, `--check` flags

#### `setup-vllm-omni.sh`
Deploys **vLLM-Omni** — the official vLLM sub-project for omni-modality serving (TTS/speech, diffusion, image/video generation, any-to-any models like Qwen3-Omni / Cosmos3) — as a Docker-based, OpenAI-compatible server. Uses prebuilt Docker Hub images (no local build), auto-detects the GPU backend, and serves via `vllm serve <model> --omni`. Runs alongside `setup-vllm.sh` on its own port and directory.

**Features:**
- Prebuilt images: `vllm/vllm-omni` (NVIDIA, amd64/arm64) and `vllm/vllm-omni-rocm` (AMD)
- Auto-detects NVIDIA / AMD / CPU backend (CPU is impractical for generative models)
- Model-agnostic: without `VLLM_OMNI_MODEL` the container is not started (prints next steps)
- Optional Traefik reverse-proxy integration
- Idempotent; supports `--force` and `--check`

#### `setup-omnivoice.sh`
Builds the OmniVoice.cpp `tts-server` (an OpenAI-compatible text-to-speech HTTP server) from source for the detected GPU backend (Vulkan / CUDA / CPU) and runs it as a native systemd service under a dedicated non-root user. There is no official Docker image, so the single self-contained binary is built from source and installed to `/usr/local/bin`. Models come from the non-gated `Serveurperso/OmniVoice-GGUF` repo (no HF token needed). Defaults to a loopback bind (the server has no TLS/auth); a non-loopback bind adds a UFW rule. A bounded `GET /health` gate proves the stack is up before reporting success.

**Features:**
- Auto-detects the GPU backend (Vulkan / CUDA / CPU) and builds with the matching `buildvulkan.sh` / `buildcuda.sh` / `buildcpu.sh`
- OpenAI-compatible TTS API: `POST /v1/audio/speech`, `POST`/`GET`/`DELETE /v1/audio/voices`, `GET /v1/models`, `GET /health`
- Non-root `omnivoice` service user with GPU (`render`/`video`) group membership for Vulkan
- Models under `/srv/omnivoice/models`, build source kept under `/srv/omnivoice/src` for rebuilds
- Converging re-runs: models never re-downloaded, build skipped unless the binary/ref/backend changed, service restarted only when the rendered unit changed
- `--check`, `--force`, `--interactive`; key env vars: `OMNIVOICE_BACKEND`, `OMNIVOICE_PORT`, `OMNIVOICE_HOST`, `OMNIVOICE_BASE_MODEL`, `OMNIVOICE_TOKENIZER_MODEL`, `OMNIVOICE_REF`

#### `setup-omnigent.sh`
Deploys Omnigent — an open-source meta-harness providing a common orchestration layer over multiple AI coding agents (Claude Code, Codex, Cursor, Pi, etc.) — via Docker Compose with Postgres + FastAPI. Also installs the runner CLI (`omnigent`) on the host for local agent execution.

**Features:**
- Docker Compose deployment with Postgres backend
- Runner CLI installed on host for local agent execution
- Optional Traefik reverse-proxy integration
- Auto-generated secure secrets in `.env` file
- Health check polling (up to 120s)
- UFW firewall rule configuration (direct mode)

#### `setup-agent-docker-runner.sh`
Installs the Agent Docker Runner (ADR) CLI, a tool that runs coding agents inside isolated Docker containers with a single command. Supports multiple agents: pi, opencode, claude, codex.

**Features:**
- Runs any supported agent in isolated Docker containers
- Single CLI command: `adr run <agent> -- <args>`
- Auto-builds container images for all agents
- Configuration examples included
- Supports pi, opencode, claude code, and GitHub Copilot Workspace (codex)

#### `setup-nanobot.sh`
Clones the Nanobot agent repository, builds the Docker image, and runs the onboarding flow.

#### `setup-hermes.sh`
Sets up the Hermes Agent environment using the official prebuilt Docker image. Creates configuration files and provides convenience scripts for management.

**Features:**
- Official Hermes Agent MCP gateway
- Prebuilt Docker image from nousresearch
- Setup wizard for initial configuration
- Hermes Gateway and Chat services
- Data persistence in `.hermes` directory

#### `setup-unsloth.sh`
Installs **Unsloth Studio** (the browser-based web UI for running and training AI models) and optionally the **Unsloth Desktop** native app. Studio is installed by default; Desktop requires `UNSLOTH_INSTALL_DESKTOP=true`. Optionally runs Studio as a systemd service (`UNSLOTH_INSTALL_SERVICE=true`).

**Features:**
- Browser-based web UI accessible at `http://localhost:8888` by default
- Runs and trains LLMs, diffusion image/video, GGUF, and audio models
- Native Desktop app (optional) for macOS, Windows, and Linux
- Optional systemd service (`UNSLOTH_INSTALL_SERVICE=true`) for persistent background operation
- Supports Python version pinning (`UNSLOTH_PYTHON`), GGUF-only mode (`UNSLOTH_NO_TORCH`), and custom install directory (`UNSLOTH_STUDIO_HOME`)
- Downloads installer script to a temp file before execution (never pipes curl to bash directly)

**Environment variables (all optional):**
- `UNSLOTH_INSTALL_DESKTOP` — Install Unsloth Desktop app (`false` by default, set to `true` or `1`)
- `UNSLOTH_INSTALL_SERVICE` — Install Unsloth Studio as systemd service (`false` by default, set to `true`)
- `UNSLOTH_STUDIO_USER` — Runtime user for systemd service (defaults to `$USER`)
- `UNSLOTH_STUDIO_PORT` — Port for Unsloth Studio (`8888` by default)
- `UNSLOTH_STUDIO_BIND` — Bind address (`127.0.0.1` by default)
- `UNSLOTH_STUDIO_HOME` — Custom install directory (`/srv/unsloth` by default)
- `UNSLOTH_PYTHON` — Pin Python version for Unsloth (auto by default)
- `UNSLOTH_NO_TORCH` — Skip PyTorch for GGUF-only mode (`false` by default)

**Usage examples:**
```bash
# Studio only (default)
./tasks/setup-unsloth.sh

# Studio + Desktop
UNSLOTH_INSTALL_DESKTOP=true ./tasks/setup-unsloth.sh

# Studio + systemd service
UNSLOTH_INSTALL_SERVICE=true ./tasks/setup-unsloth.sh

# Studio + Desktop + systemd service
UNSLOTH_INSTALL_DESKTOP=true UNSLOTH_INSTALL_SERVICE=true ./tasks/setup-unsloth.sh

# Custom port, bind to all interfaces
UNSLOTH_STUDIO_PORT=9000 UNSLOTH_STUDIO_BIND=0.0.0.0 ./tasks/setup-unsloth.sh
```

---

#### `setup-pi.sh`
Installs the latest Node.js via nvm and the **Pi coding agent** npm package globally.

#### `setup-agent-sandbox.sh`
Configures the **bubblewrap (bwrap) sandboxing prerequisites** on the host so sandboxed coding-agent runs work out of the box on Ubuntu 24.04+: installs `bubblewrap`, lifts the AppArmor "unprivileged userns" restriction **for bwrap only** (one-file profile `/etc/apparmor.d/bwrap`, skipped when AppArmor is inactive), hard-verifies bwrap with a bounded smoke test, and installs the **`asb` wrapper** to `/usr/local/bin/asb` (verified with a real sandboxed one-shot). `asb` runs `pi`/`opencode` (or a bare `sh`) in a bwrap sandbox where the workspace is the only general writable path (agent state dirs `~/.pi`/`~/.local/share/opencode` are mounted rw because agents write sessions/logs there; `~/.local/bin`, `~/.config/opencode` and system dirs are read-only), env is cleared to an allowlist, herdr integration is preserved (`HERDR_*` forwarding, socket bind, `HERDR_AGENT` hint), and symlinked skills/prompts/commands in the agent's state dirs (pi/opencode/claude/codex, incl. `~/.agents/skills`) get their resolved targets bound read-only so linked skill repos keep working (dangling links are skipped). Idempotent; env: `SANDBOX_APT_PACKAGES` (default `bubblewrap`), `BWRAP_VERIFY_TIMEOUT` (default `15`).

#### `sync-models.py`
Python tool (entrypoint + `sync_models/` package) implementing the declarative **model catalog**: downloads local model weights via the `hf` CLI (`--dry-run` probe, idempotent `--local-dir` mode, disk-space warning), additively appends missing model entries to the llama-swap `config.yaml` (existing entries and all other sections are never modified), restarts llama-swap only when the config changed and polls `/health` afterwards, and merges catalog providers/models into `~/.pi/agent/models.json` and `~/.config/opencode/opencode.json` (add missing, fix managed fields, touch nothing else). Strictly additive and idempotent. Catalog resolution: `MODELS_YML` → `models.yml` (gitignored) → `models.yml.default`; env vars `LLAMA_SWAP_CONFIG`, `PI_MODELS_JSON`, `OPENCODE_CONFIG`, `LLAMA_SWAP_HEALTH_TIMEOUT`; flags `--no-restart`, `--agents pi,opencode`.

#### `setup-deepseek-harness.sh`
Installs **DeepSeek Harness** (`dsh`) — an open-source agent harness from DeepSeek AI with a plugin-first architecture. Ensures NVM + Node.js 22.19+ are available, then installs `dsh` globally. Run `dsh web` afterwards for the Web UI at `http://127.0.0.1:3080`.

---

### Speech & Dictation

#### `setup-whispering.sh`
Downloads the Whispering speech-to-text AppImage, creates a start script (`~/whispering`) and a desktop shortcut. Backs up any existing binary before downloading.

---

### Project Management & Collaboration

#### `setup-forgejo.sh`
Installs Forgejo (a Gitea fork) as a Docker container. Supports optional Traefik reverse-proxy integration via `FORGEJO_TRAEFIK_ENABLED`.

#### `setup-planka.sh`
Installs Planka, a self-hosted Kanban board, via Docker Compose with PostgreSQL. Auto-generates a secret key and supports interactive or headless admin user creation.

---

### CI/CD

#### `setup-concourse.sh`
Deploys **Concourse CI** (web, TSA, worker, PostgreSQL) with Docker Compose, generates TSA/session/worker keys, and configures a `fly` CLI target. Supports direct port exposure or Traefik reverse-proxy integration.

#### `setup-dagu.sh`
Deploys **Dagu** (self-hostable workflow orchestrator) via Docker Compose. The host Docker socket is mounted so workflows can run container steps. No Traefik integration — accessed via configurable bind address.

**Features:**
- DAG-based workflow orchestration (alternative to Airflow/Cron)
- Web UI for managing and monitoring DAGs
- Host Docker socket mounted for container steps
- Shared volume at `./data` including `./data/dags` for workflow definition files (`.dagu.yml`)
- Builtin RBAC authentication with auto-generated credentials
- Data persisted in a named Docker volume

> **Note:** The Docker socket grant means workflows can control the host Docker daemon. Use only for trusted workflows. The admin password is stored in `/srv/dagu/.env` (mode 600).

#### `setup-kestra.sh`
Deploys **Kestra** (event-driven workflow & orchestration platform) in standalone mode via Docker Compose with a dedicated PostgreSQL backend. Supports direct port access (bound to a configurable IP, default `127.0.0.1:8084`) or opt-in Traefik reverse-proxy integration with TLS.

**Features:**
- Standalone Kestra (`server standalone`) with Postgres backend for repository, queue and data
- Pinned immutable images (`kestra/kestra:v2.0.0`, `postgres:16`) — Kestra recommends exact `v<X.X.X>` tags for production; Postgres is pinned to avoid major-version data-dir incompatibility
- Basic-auth credentials and Postgres password auto-generated on first run, stored in `/srv/kestra/.env` (mode 600), reused on re-runs (never rotated); the compose file keeps only literal `${VAR}` placeholders resolved at runtime
- Host Docker socket mounted for Kestra docker script tasks (trusted workflows only)
- Re-runs converge: re-render, reuse secrets, `docker compose up -d`

> **Note:** The Docker socket grant means Kestra workflows can control the host Docker daemon. Use only for trusted workflows.

---

### Storage & File Sharing

#### `setup-nextcloud.sh`
Deploys Nextcloud, a self-hosted file sync and collaboration platform, via Docker Compose. Supports optional Traefik reverse-proxy integration for secure HTTPS access.

**Features:**
- Production stack: `nextcloud:34-apache` + PostgreSQL + authenticated Redis + cron sidecar
- Redis provides distributed caching and transactional file locking (mandatory for production)
- Traefik mode (HTTPS, HTTP→HTTPS redirect, `.well-known` DAV redirect, HSTS) or LAN/direct mode with UFW rule
- Secrets in `/srv/nextcloud/.env` (mode 600), generated once and never rotated; the compose file keeps only literal `${VAR}` tokens
- PostgreSQL-only backend; existing MariaDB/SQLite installs are refused up-front
- Pinned images — update Nextcloud deliberately, one major at a time (33 → 34 → 35)
- Backup integration: `setup-backup-server.sh --services nextcloud` (`pg_dump -Fc` + data copy)

#### `setup-n8n.sh`
Deploys n8n, a workflow automation platform, via Docker Compose with PostgreSQL backend. Supports optional Traefik reverse-proxy integration for secure HTTPS access.

**Features:**
- Visual workflow builder with 200+ integrations
- Self-hosted with full data control
- Supports webhooks, schedules, and triggers
- PostgreSQL backend for persistence
- Optional Traefik reverse-proxy integration

#### `setup-samba.sh`
Installs and configures Samba file sharing.

---

### Graphics & Whiteboarding

#### `setup-excalidraw.sh`
Pulls and runs the Excalidraw virtual whiteboard as a Docker container with an `always` restart policy.

---

### Remote Access & Desktop

#### `setup-anydesk.sh`
Installs AnyDesk remote desktop from the official apt repository.

#### `setup-brave.sh`
Installs the Brave browser from its official apt repository.

#### `setup-netbird.sh`
Deploys self-hosted NetBird (a WireGuard-based mesh VPN) as Docker containers: the combined server (management + signal + relay + embedded STUN + embedded IdP) and the dashboard. Supports direct host ports or Traefik reverse-proxy integration, plus an optional routing-peer client for LAN exposure.

---

### Development Tools

#### `setup-neovim.sh`
Installs Neovim directly on the host machine (Ubuntu/Debian) with lazy.nvim plugin manager, LSP support via nvim-lspconfig, and essential productivity plugins. Installed via official PPA for latest stable version.

**Features:**
- lazy.nvim fast plugin manager with on-demand loading
- nvim-lspconfig for Language Server Protocol support
- telescope.nvim fuzzy finder
- nvim-cmp intelligent code completion
- treesitter advanced syntax highlighting
- gitsigns git integration
- oil.nvim modern file explorer

#### `setup-zed.sh`
Installs the Zed editor on Linux using the official installation script. Supports both stable and preview channels.

---

### Virtualization

#### `setup-virt-runner.sh`
Installs the virt-runner CLI tool and all host prerequisites needed to run the VM-based integration test suite. Clones the virt-runner repository, sets up KVM, libvirt, storage pools, user permissions, and installs the CLI tool via uv.

**Features:**
- Clones the virt-runner repository (default: https://github.com/Kubementat/virt-runner.git)
- Runs `install-prerequisites.sh` for KVM, libvirt, pools, and user permissions
- Installs virt-runner as a uv tool
- Verifies the installation
- Idempotent: safe to re-run on an already-configured system

**Environment variables (all optional):**
- `VIRT_RUNNER_REPO` — URL of the virt-runner repository
- `VIRT_RUNNER_DIR` — Local directory to clone to (default: `~/dev/os_projects/virt-runner`)
- `VIRT_USERNAME` — User to add to libvirt/kvm groups (default: current user)

**Usage:**
```bash
# Automated setup
./tasks/setup-virt-runner.sh

# Custom repository and directory
VIRT_RUNNER_REPO=https://github.com/Kubementat/virt-runner.git \
VIRT_RUNNER_DIR=~/dev/virt-runner ./tasks/setup-virt-runner.sh
```

> **Note:** After installation, you may need to log out and back in for group membership changes to take effect, or run `newgrp libvirt`.

#### `setup-virtualization.sh`
Installs or updates libvirt (virtualization API) and virt-manager (graphical VM manager) on Debian/Ubuntu-based systems. Configures the libvirt daemon, default networks, and adds the user to the libvirt group.

**Features:**
- Installs QEMU/KVM, libvirt-daemon, bridge-utils
- Graphical virt-manager VM management
- Automatic default network configuration
- User permission setup for libvirt access
- Supports both fresh install and update modes

---

### SSH Utilities

#### `setup-ssh-tunnel-user.sh`
Creates a locked-down SSH user with no shell access, configured exclusively for port-forwarding tunnels.

> **Note:** See `utilities/ssh-port-forward.sh` for SSH tunneling utilities.

---

### Monitoring & Observability

#### `setup-monitoring.sh`
Deploys a containerized observability stack (Prometheus, Grafana, Node Exporter, cAdvisor) via Docker Compose. Prometheus auto-discovers containers labeled `prometheus.scrape=true` (and `prometheus.port=<port>`) via Docker service discovery and exposes a hot-reloadable Lifecycle API. **cAdvisor** provides per-container CPU/memory/disk/network metrics. Grafana is pre-provisioned with a Node Exporter and a cAdvisor dashboard (no manual import). Data is persisted under `/srv/monitoring` and re-runs never destroy existing state (no `down -v`).

**Exposure modes:**
- **Direct** (default): Grafana at `http://<server-ip>:3100` (published on `0.0.0.0`, reachable from the local network) and the Prometheus UI at `http://127.0.0.1:9090` (loopback only, since the Prometheus UI has **no authentication**). Only the Grafana port gets an UFW allow rule; if you publish Prometheus beyond loopback (`PROMETHEUS_BIND_ADDRESS`), restrict it manually (e.g. `ufw allow from <subnet> to any port 9090 proto tcp`).
- **Traefik** (`GRAFANA_TRAEFIK=true`): Grafana routed via the shared proxy network at `https://GRAFANA_DOMAIN`; Prometheus stays internal. Requires `GRAFANA_DOMAIN` and a running Traefik stack with the shared `proxy` network.

**Usage examples:**
```bash
# Direct mode (default): Grafana on the LAN (0.0.0.0), Prometheus on 127.0.0.1
./tasks/setup-monitoring.sh

# Direct mode with everything on loopback
GRAFANA_BIND_ADDRESS=127.0.0.1 ./tasks/setup-monitoring.sh

# Traefik mode
GRAFANA_TRAEFIK=true GRAFANA_DOMAIN=grafana.example.com ./tasks/setup-monitoring.sh
```

> **Note:** To monitor a service, label its container `prometheus.scrape=true` and `prometheus.port=<port>`. The Grafana admin password is stored in `/srv/monitoring/grafana/.env` (mode 600). Reload Prometheus config without a restart: `docker compose -f /srv/monitoring/docker-compose.yml exec prometheus wget -q --post-data='' http://localhost:9090/-/reload`.

### Backup

#### `setup-backup-server.sh`
Turns one machine into the central **Borg** backup storage host **and** starts a working self-backup in one step: installs `borgbackup`, prepares storage (a mounted **drive** — verified fstab-persistent — or a **local directory** on the main fs when no drive is present; the script never formats or edits fstab), creates the per-client repo layout (`<mount>/automatic`, `<mount>/manual`) and fixes group/ownership, then runs the client in local mode (`--initial`) so a real snapshot exists. A bare `./tasks/setup-backup-server.sh` with **no arguments** gives a working self-backup (auto-detected scope + services, local-disk storage). The server is a "dumb" storage host — it stores no passphrases and runs no scheduling (`borg serve` is implicit in sshd). Idempotent; `--check` reports status for monitoring. Runs as root or a sudo-capable user (per-command `sudo`).

#### `setup-backup-client.sh`
Adds any machine to the backup fleet: installs `borgbackup`, **auto-detects** the backup scope (`/home/<user>`, `/etc`, `/srv`, `+ /var/lib/docker/volumes` when Docker is running) and the Docker services to dump (installed/running ones) when `--paths`/`--services` are omitted, initializes the machine's repository (remote over SSH **or** local path), generates a 32-char repo passphrase into `~/.config/borg/<client>.pass` (mode 600), and installs the wrapper `/usr/local/bin/borg-backup-<client>` (rendered from `templates/backup-client/` via `envsubst`) plus a daily systemd timer (`Persistent=true`, 15 min jitter). With `--services`, Docker-based databases are dumped **consistently** before each `borg create` (engine-level `pg_dump`/`mysqldump`/`sqlite3 .backup`/`forgejo dump` via `lib/docker-backup.sh`) and staged into the same archive — so an archive never contains a database copied mid-write. Wrapper subcommands: `create`, `list`, `check [--full]`, `restore <snap> [--dest DIR] [paths…]`, `restore-db <snap> <service> --yes` (destructive DB restore).

**Usage examples:**
```bash
# 1. Zero-config: one command → working self-backup (local-disk mode):
./tasks/setup-backup-server.sh
./tasks/setup-backup-server.sh --check

# 2. Storage host with an external drive (already mounted + fstab-persistent):
BACKUP_MOUNT=/mnt/backup ./tasks/setup-backup-server.sh

# 3. Remote client (key-based SSH to the server):
sudo ./tasks/setup-backup-client.sh --client mybox \
     --host backup.example.com --port 22 --user alice \
     --repo-path /var/backups/automatic \
     --paths "/home/alice /etc /srv" \
     --services "forgejo,planka,kestra" --initial

# 4. Manage:
sudo /usr/local/bin/borg-backup-mybox list
sudo /usr/local/bin/borg-backup-mybox restore mybox-2026-09-13T04:29:18 --dest /tmp/restore
```

> **Notes:** Supported `--services` (dump dispatcher in `lib/docker-backup.sh`): `forgejo, planka, kestra, nextcloud, n8n, concourse, openwebui, omnigent`. Services whose raw data must never be copied mid-write can be quiesced around the whole run with `--stop-services` (short `docker compose stop`/`up -d` window). The staging dir (`/var/backup-staging` default) must not be inside `--paths`. Local-disk mode protects against software corruption / accidental deletion but **not** disk failure — mount a separate drive for that. `--no-self-backup` / `--no-initial` on the server script opt out of the automatic self-backup. Installs that customized a service's `CONTAINER_NAME` must mirror it into the backup-side `<SVC>_CONTAINER` override (e.g. `FORGEJO_CONTAINER`). Spec: [specification/features/setup-backup-server.md](specification/features/setup-backup-server.md); research: [docs/research/docker-volume-backup-research.md](docs/research/docker-volume-backup-research.md).

---

## Utility Scripts (`utilities/`)

### `run-llama-server.sh`
A generalized launcher for llama.cpp's llama-server with sensible defaults based on your manual configuration. Automatically enables flash attention, GPU layers, and KV cache settings. When run without `--model`, it lists all available `.gguf` models in `$HOME/.lmstudio/models/`.

**Key features:**
- Uses your default parameters (temperature, context size, GPU layers, etc.)
- Automatically enables `--no-mmap`, `--kv-unified`, and `--flash-attn`
- Lists models on `$HOME/.lmstudio/models/` when `--model` is omitted
- All parameters can be overridden via arguments or environment variables

**Default parameters:**
| Parameter | Default |
|-----------|---------|
| HOST | `0.0.0.0` |
| PORT | `1236` |
| TEMPERATURE | `0.6` |
| TOP_K | `40` |
| TOP_P | `0.95` |
| REPEAT_PENALTY | `1.00` |
| PRESENCE_PENALTY | `0.00` |
| PARALLEL | `1` |
| THREADS_COUNT | `14` |
| PRIO | `1` |
| CONTEXT_SIZE | `100000` |
| BATCH_SIZE | `512` |
| FLASH_ATTENTION | `on` |
| GPU_LAYERS | `all` |
| KV_CACHE_TYPE | `q4_0` |

**Usage examples:**
```bash
# List all available .gguf models in ~/.lmstudio/models/ and exit
./utilities/run-llama-server.sh

# Start server with your default model and parameters
./utilities/run-llama-server.sh

# Start server with a specific model (uses all defaults)
./utilities/run-llama-server.sh --model ~/models/Qwen2.5-7B-Instruct.gguf

# Custom port and host
./utilities/run-llama-server.sh --model ~/models/model.gguf --port 1236 --host 0.0.0.0

# Override specific parameters
./utilities/run-llama-server.sh --model model.gguf --temperature 0.8 --ctx-size 50000

# Disable flash attention (override default)
./utilities/run-llama-server.sh --model model.gguf -fa off

# Set environment variables for customization
export PORT=1237
export TEMPERATURE=0.7
./utilities/run-llama-server.sh --model model.gguf
```

**Environment variables (all optional):**
- `MODEL_PATH` - Default model path
- `HOST`, `PORT` - Server binding
- `TEMPERATURE`, `TOP_K`, `TOP_P`, `REPEAT_PENALTY`, `PRESENCE_PENALTY`, `PARALLEL` - Generation parameters
- `THREADS_COUNT`, `PRIO`, `CONTEXT_SIZE`, `BATCH_SIZE`, `FLASH_ATTENTION`, `GPU_LAYERS`, `KV_CACHE_TYPE` - Performance parameters
- `KV_UNIFIED` - Enable unified KV cache (default: true)

### `ssh-port-forward.sh`
Simple SSH tunnel wrapper for creating secure port forwards from a local machine to a remote server.

**Usage:**
```bash
./ssh-port-forward.sh <local_port> <remote_host> <remote_port> <ssh_user> [ssh_port]
```

**Parameters:**
- `local_port` - Local port to forward from
- `remote_host` - Remote server hostname or IP
- `remote_port` - Port on the remote server to forward to
- `ssh_user` - SSH username for the remote server
- `ssh_port` - SSH port on the remote server (optional, defaults to 22)

**Example:**
```bash
# Forward local port 3333 to remote server 192.168.0.3 port 3333
./ssh-port-forward.sh 3333 192.168.0.3 3333 myuser 2224
```

This creates an SSH tunnel that forwards connections from `localhost:3333` through the SSH connection to `192.168.0.3:3333`. The tunnel remains active until you press Ctrl+C.

### `sync-server-files.sh`
Syncs a directory from a remote AI server to a local machine (laptop, dev machine, ...) using rsync over SSH. Useful for pulling down repositories, agent workspaces (e.g. Hermes), or service data directories from the server.

**Key features:**
- Incremental sync — only changed files are transferred
- Handles Docker volume ownership (UID 10000) gracefully by stripping ownership metadata on the destination
- Pre-flight checks: connectivity to the server, existence of the remote path
- Optional `--delete` mode to mirror the remote directory exactly
- Optional `--sudo` for reading restricted files on the remote side
- Syncs one directory per invocation — invoke once per directory to sync multiple

**Environment variables:**
| Variable | Description | Default |
|----------|-------------|---------|
| `SYNC_REMOTE_USER` | SSH user on the server (**required**) | — |
| `SYNC_REMOTE_HOST` | Server IP or hostname (**required**) | — |
| `SYNC_SSH_PORT` | SSH port | `2224` |
| `SYNC_DELETE` | Delete local files not on remote (`yes` to enable) | `no` |
| `SYNC_SUDO` | Use sudo on remote side (`yes` to enable; also `--sudo` flag) | `no` |

**Options:**
- `--source-directory <path>` — Remote directory on the server to sync (required)
- `--target-directory <path>` — Local directory to sync into (required)
- `--dry-run` — Show what would be transferred without doing it
- `--verbose` — Show rsync output in detail
- `--sudo` — Use sudo on remote side for reading restricted files
- `--help` — Show help and exit

**Usage examples:**
```bash
# Sync the hermes agent workspace from the server
SYNC_REMOTE_USER=alice SYNC_REMOTE_HOST=192.168.1.100 \
  ./utilities/sync-server-files.sh --source-directory /srv/hermes --target-directory ~/backups/hermes

# Mirror a directory (also delete local files removed on the server)
SYNC_REMOTE_HOST=192.168.1.100 SYNC_DELETE=yes \
  ./utilities/sync-server-files.sh --source-directory /srv/openwebui --target-directory ~/backups/openwebui

# Read restricted files with sudo on the remote side
SYNC_REMOTE_HOST=192.168.1.100 SYNC_SUDO=yes \
  ./utilities/sync-server-files.sh --source-directory /srv/forgejo --target-directory ~/backups/forgejo --sudo

# Preview without transferring
SYNC_REMOTE_HOST=192.168.1.100 \
  ./utilities/sync-server-files.sh --source-directory /srv/hermes --target-directory ~/backups/hermes --dry-run --verbose
```

**Sudo configuration (only needed with `--sudo` / `SYNC_SUDO=yes`):**
Since rsync runs over SSH without a tty, sudo cannot prompt for a password. Grant passwordless sudo for rsync on the remote server:

```bash
sudo visudo
# Add (adjust username as needed):
alice ALL=(ALL) NOPASSWD: /usr/bin/rsync
```

This only grants passwordless access to rsync, not to arbitrary commands. For tighter restrictions, limit to specific paths:
```
alice ALL=(ALL) NOPASSWD: /usr/bin/rsync --server * /srv/hermes
```
