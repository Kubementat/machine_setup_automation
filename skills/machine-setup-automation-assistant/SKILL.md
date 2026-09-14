---
name: machine-setup-automation-assistant
description: Assistant for the machine_setup_automation repository. Guides users through the YAML-configured orchestrator (run-setup.sh) to provision machines for LLM workflows. Helps select services, configure machine-config.yml, and run setups. Use when someone asks how to set up a machine, which service to install, or how to configure any task in this repo.
Invoke this skill when the users asks for usage instructions or repository introduction.
---

# Machine Setup Automation Assistant

On activation, orient yourself immediately:

```bash
cat README.md
ls tasks/ utilities/
```

## Core Concept

This repo uses **two YAML configuration files**, each governing a different concern:

| File | Controls |
|------|----------|
| `machine-config.yml` | Which **services** to install, their env vars & args (infrastructure) |
| `models.yml` | Which **LLMs** to download, serve, and wire into coding agents (model catalog) |

The **orchestrator** (`run-setup.sh`) drives `machine-config.yml`. The **sync tool** (`tasks/sync-models.py`) drives `models.yml`. Together they turn a fresh Ubuntu box into a working local-LLM inference server.

## Workflow

### 1. Understand the User's Goal

Ask (or infer from context):
- **What kind of machine?** (server, dev workstation, laptop, cloud VM) — this influences which services to enable, not which script to run
- **Which services are needed?** — helps you recommend which entries to set `enabled: true` in the config

### 2. Bootstrap the Configuration

Guide the user through these steps:

```bash
# Step 1: Copy the example config
cp machine-config.yml.example machine-config.yml

# Or use the pre-configured inference stack:
# cp machine-config-inference.yml.example machine-config.yml

# Step 2: Preview what's available
./run-setup.sh status
```

Explain the output: it shows every script, whether it's enabled, and any configured env vars/args.

### 3. Help Select & Configure Services

#### Step A: Infrastructure (`machine-config.yml`)

Edit `machine-config.yml` to enable the services the user needs. The YAML format:

#### Step B: Model Catalog (`models.yml`) — optional, after inference stack

```yaml
version: 1

scripts:
  setup-docker:
    enabled: true
    env: {}
    args: []
  setup-llama-cpp:
    enabled: true
    env:
      BACKEND: 'nvidia'
      FORCE: '1'
      JOBS: '8'
    args: []
  setup-traefik:
    enabled: true
    env:
      ACME_EMAIL: user@example.com
      TRAEFIK_DOMAIN: myserver.example.com
    args: []
```

**Key rules to communicate:**
- `version` is the config format version — always set to `1`
- All scripts are **disabled by default** — enable only what you need
- `setup-basics` should almost always be enabled first (installs `yq`, `git`, `curl`, etc.)
- `description` is optional and informational — shown in `./run-setup.sh status` output
- `env` values are strings — use quotes for numbers/booleans: `'true'`, `'8080'`
- `args` are passed as CLI flags to the script
- Use `./run-setup.sh status` after editing to verify before applying

### 4. Preview and Apply

```bash
# Preview what will run
./run-setup.sh status

# Execute all enabled scripts
./run-setup.sh apply
```

The orchestrator runs scripts alphabetically. It continues executing all remaining scripts even if one fails. A summary of successes, failures, and skips is printed at the end (exit code 1 if any failed).

### 5. Custom Config File (optional)

```bash
./run-setup.sh --config path/to/other-config.yml status
./run-setup.sh -c path/to/other-config.yml apply
```

### 6. Model Catalog (optional, after inference stack)

```bash
# Use a custom catalog path
cp models.yml.example models.yml   # or models.yml.default
# edit models.yml
MODELS_YML=/path/to/custom.yml ./tasks/sync-models.py

# Or only update agent configs (skip llama-swap + downloads)
./tasks/sync-models.py --agents-only
```

## Running Individual Scripts

Every task script is standalone and idempotent — safe to run directly:

```bash
bash tasks/setup-docker.sh
bash tasks/setup-traefik.sh
```

This is useful for:
- Testing a single service before adding it to the config
- Re-running a failed script after fixing configuration
- Adding a service that's not yet in `machine-config.yml`

## Model Catalog Configuration (`models.yml`)

After the inference stack is installed (`setup-llama-swap`, `setup-pi`, `setup-opencode-server`), use the model catalog to download and serve LLMs. This is a **separate concern** from `machine-config.yml` — it manages model content, not infrastructure.

### Workflow

```bash
# 1. Copy the default catalog (contains a real, downloadable model)
cp models.yml.default models.yml

# 2. Edit models.yml — add/remove models, change apiKey, adjust serve params
#    See the schema below for the full format.

# 3. Run the sync tool
./tasks/sync-models.py

# 4. Verify: llama-swap should list the model, agents should see it
```

**Catalog resolution order:** `$MODELS_YML` → `models.yml` → `models.yml.default`

`models.yml` is **gitignored**. Use `models.yml.example` for a fully annotated reference with schema documentation.

### Catalog Schema

```yaml
env:
  - name: MODEL_DIR
    value: ${HOME}/.cache/huggingface/hub

providers:
  - name: local
    baseUrl: http://localhost:9292/v1
    apiKey: sk-your-key
    models:
      - name: qwen3.8-27b
        type: local
        env:           # optional per-model env
          - name: F
            value: "-v"
        download:      # shell commands to download weights
          - >-
            hf download hf://org/Model/Path.gguf
            --local-dir ${MODEL_DIR}/org/Model
        serve:         # llama-swap serve command
          cmd: |
            ${llama-server-bin}
            --port ${PORT}
            -m ${MODEL_DIR}/org/Model/Path.gguf
            --ctx-size 128000
            --jinja
        agent:         # optional agent metadata
          contextWindow: 262144
          maxTokens: 32000
          reasoning: true
          input: [text, image]
          thinkingLevelMap:
            minimal: null
            low: low
            medium: medium
            high: null
            xhigh: xhigh
            max: null
```

**Key rules:**
- `type: local` — requires `download` + `serve.cmd`. Sync downloads weights and merges serve cmd into llama-swap.
- `type: remote` — must NOT have `download`/`serve`. Only agent metadata is consumed.
- `env:` at top-level is shared across all models; per-model `env:` extends it.
- Agent metadata fields are all optional: defaults are `contextWindow: 200000`, `maxTokens: 16000`, `reasoning: true`, `input: [text]`.
- Variable expansion: `${MODEL_DIR}`, `${PORT}`, `${llama-server-bin}` (llama-swap macro).

### Sync flags

| Flag | Purpose |
|------|---------|
| `--no-restart` | Do not restart llama-swap even if config changed |
| `--agents pi,opencode` | Restrict agent sync to listed agents |
| `--agents-only` | Only update agent configs (skip llama-swap + downloads) |

### Sync environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MODELS_YML` | — | Explicit catalog path |
| `LLAMA_SWAP_CONFIG` | `/srv/llama-swap/config/config.yaml` | llama-swap config path |
| `PI_MODELS_JSON` | `$HOME/.pi/agent/models.json` | pi model config path |
| `OPENCODE_CONFIG` | `$HOME/.config/opencode/opencode.json` | opencode config path |
| `LLAMA_SWAP_HEALTH_TIMEOUT` | `500` | Post-restart health poll timeout |

> **Idempotency:** re-runs are no-ops — strictly additive, never removes or rewrites entries it does not own.

## Discovering Available Scripts

Always discover dynamically — never assume what's in the repo:

```bash
# See all task scripts
ls tasks/

# Read README for service descriptions and env vars
cat README.md

# Inspect a specific script for its env vars
head -60 tasks/setup-<name>.sh
```

## Service Categories (from README.md)

When recommending services, group them logically:

| Category | Typical Scripts |
|----------|----------------|
| **System & Infra** | setup-basics, setup-docker, setup-sshd, configure-firewall, setup-traefik, setup-fail2ban, setup-upstream-kernel, setup-ssh-tunnel-user |
| **AI / LLM** | setup-llama-cpp, setup-llama-swap, setup-vllm, setup-vllm-omni, setup-lm-studio, setup-openwebui, sync-models |
| **AI Agents** | setup-omnigent, setup-opencode-server, setup-nanobot, setup-hermes, setup-pi, setup-agent-docker-runner, setup-deepseek-harness |
| **Dev Tools** | setup-neovim, setup-zed |
| **Project Mgmt** | setup-forgejo, setup-planka |
| **Storage / Files** | setup-nextcloud, setup-samba |
| **Automation** | setup-n8n |
| **CI/CD** | setup-concourse |
| **Remote Access** | setup-anydesk, setup-virtualization |
| **Speech** | setup-whispering |
| **Browser** | setup-brave |
| **Whiteboarding** | setup-excalidraw |

## Utility Scripts

Located in `utilities/`:

- **`utilities/run-llama-server.sh`** — Launch llama-server with auto flash-attention. Run without `--model` to list available `.gguf` models in `~/.lmstudio/models/`.
- **`utilities/ssh-port-forward.sh`** — SSH tunnel wrapper: `./ssh-port-forward.sh <local_port> <remote_host> <remote_port> <ssh_user> [ssh_port]`
- **`utilities/sync-server-files.sh`** — Incrementally sync a directory from the AI server to a local machine via rsync/SSH (e.g. repos, hermes workspaces). Config via `SYNC_REMOTE_USER`, `SYNC_REMOTE_HOST`, `SYNC_SSH_PORT` (default 2224), `SYNC_DELETE`, `SYNC_SUDO`; options `--source-directory`, `--target-directory`, `--dry-run`, `--verbose`, `--sudo`. See README.md "Utility Scripts" for full docs.

## Common Recommendations by Use Case

### Minimal LLM Server
Enable: `setup-basics`, `setup-docker`, `setup-sshd`, `configure-firewall`, `setup-llama-cpp`, `setup-llama-swap`

After setup, configure models:
```bash
cp models.yml.default models.yml
./tasks/sync-models.py
```

### Full LLM Dev Station
Enable: `setup-basics`, `setup-docker`, `setup-sshd`, `configure-firewall`, `setup-llama-cpp`, `setup-llama-swap`, `setup-openwebui`, `setup-pi`, `setup-opencode-server`

After setup, configure models:
```bash
cp models.yml.default models.yml
# edit models.yml to add models, adjust serve params
./tasks/sync-models.py
```

### Self-Hosted Service Stack
Enable: `setup-basics`, `setup-docker`, `setup-sshd`, `configure-firewall`, `setup-traefik`, `setup-forgejo`, `setup-nextcloud`, `setup-n8n`

## Troubleshooting Tips

- **`yq not found`**: Run `setup-basics` first — it installs `yq`
- **Config file not found**: Copy `machine-config.yml.example` to `machine-config.yml`
- **Docker group not active after install**: Run `newgrp docker` or log out/in
- **Port conflict**: Change the port in `machine-config.yml` env vars for the affected service
- **Traefik TLS not working**: Ensure `ACME_EMAIL` is set and ports 80/443 are open in UFW and your cloud firewall
- **llama-server not found**: Enable `setup-llama-cpp` in the config and run `./run-setup.sh apply`
- **Script fails mid-run**: The orchestrator continues; check the summary. Re-run with `./run-setup.sh apply` — scripts are idempotent
- **Secure Boot blocks kernel modules**: Disable Secure Boot in BIOS/UEFI (affects upstream kernel, NVIDIA drivers)
- **`models.yml not found`**: Copy `models.yml.default` or `models.yml.example` to `models.yml`
- **Sync fails with schema error**: Run `./tasks/sync-models.py --agents-only` to skip llama-swap and isolate agent config issues; check YAML indentation and required fields (`name`, `type`, `baseUrl`)
- **Model not appearing in llama-swap**: Verify `type: local` has both `download` and `serve.cmd`; check that `${MODEL_DIR}` resolves correctly; ensure `setup-llama-cpp` ran first
