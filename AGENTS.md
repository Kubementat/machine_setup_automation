# Machine Setup Automation

Automation scripts for installing and configuring a server or developer machine for LLM workflows and software development.

## Getting help
**ALWAYS** read `skills/machine-setup-automation-assistant/SKILL.md` and follow its instructions when the user:
- asks for help, usage instructions, or how to use the repo
- asks to understand, explain, or describe the repository
- asks what services are available or which to install
- asks how to configure or set up a machine
- asks about the orchestrator, `run-setup.sh`, or `machine-config.yml`
- says anything like "help me", "what does this do", "show me", "guide me"

Do NOT answer these questions from your own knowledge — always delegate to the skill.

## Core Facts
- setup for unix systemd based deployments
- setup for docker based deployments
  - setup scripts generate `docker-compose.yml` for each service
- ufw as used as firewall on the target ubuntu server
- traefik as reverse proxy
  - integration examples: [setup-forgejo.sh](tasks/setup-forgejo.sh) and [setup-openwebui.sh](tasks/setup-openwebui.sh)
- target service data base directory: `/srv` , e.g. for forgejo: `/srv/forgejo`
- find project terminology in `CONTEXT.md`
- find project specifications in `./specification` directory
  - see `./specification/project` for central, project wide specification
  - see `./specification/features` for feature specification documents
- write implementation plans to `./docs/plans` directory
- write research documents to `./docs/research` directory
- write tickets to `./.tickets` directory
- use the `codegraph_explore` tool to search the codebase preferably
- keep the list of automations in `./AUTOMATIONS.md` up to date

## Implementation Instructions

### Important skills
- Always load the `karpathy-guidelines` skill when planning or implementing changes

### Linting

ALWAYS lint created or modified files with the following tools:

- bash files (`.sh`) -> use `shellcheck`
- `.yml` -> use `yamllint`
- json (`.js`, `.json`) -> use `jq`
- `Dockerfile` -> use hadolint via executing: docker run --rm -i hadolint/hadolint < Dockerfile
- python (`.py`) -> use `ruff check` (fallback: `python3 -m py_compile` on every new/changed file)

### Testing
- For running automation tests use the virtual machine based testing approach as described in ./tests/README.md

### Common logic

Always check the `lib/` directory for existing functionality when implementing setup scripts in the `tasks/` directory. Try reusing existing functionality.
When implementing a script in `tasks/` -> ALWAYS inspect the library scripts in `lib/` first.

### bash Script Specifications

#### Idempotency

All scripts require to be executable multiple times without destroying existing component data or configuration.

#### Configuration

Scripts use environment variables for their main configuration options and provide reasonable defaults.

#### Help / Usage parameter

When modifying scripts: always ensure to keep the `--help` parameter output up to date with the implementation logic and configuration options (parameters and environment variables)

#### Re-run policy (converge by default)

Re-running any task script against an existing stack must converge it (render templates, reuse secrets, `docker compose up -d`, verify health) — see *Re-run policy: converge by default* in `specification/project/conventions.md`.

#### Configuration Paths

- For scripts that setup services/software that is run as daemon/server or within docker containers: use the `/srv/<service-name>` directory for configuration files
- For scripts that setup tools for the user on the host directly: use the appropriate default directory for the tool in the user's `$HOME`

#### Stack health verification

- A task script that starts a docker stack must prove the stack is up before
  reporting success: `wait_for_healthy` (from `lib/helpers.sh`, or an HTTP
  readiness poll where one already exists) after every `docker compose up -d`,
  with a bounded timeout and a non-zero exit on failure. See
  `specification/project/conventions.md` → *Stack health verification*.

#### Templating

If you need to use templating (e.g. for creating configuration files) you require to put template files in the according `templates/<component-name>` directory. DO NOT put inline templates into the bash scripts except this is explicitly required.

#### Secrets and templating

- Secrets (passwords, keys, tokens, URLs containing credentials) are **never**
  substituted into a generated file. Keep `${VAR}` literal in
  `templates/<component>/*` and resolve at runtime from
  `/srv/<service>/.env` (mode 600) via `docker compose --env-file` or
  `env_file:` in the service section.
- Non-secret layout values (ports, paths, host names, network names) may be
  `envsubst`ed at render time.
- Every secret must be **read back** from the service `.env` before generating
  a new value, so re-runs never rotate credentials a persisted volume depends
  on (see `setup-monitoring.sh` / `setup-concourse.sh`).
- `envsubst` reads its **environment**; render as the invoking user into a
  `mktemp` file and install with `sudo install -m 600` (see
  `setup-traefik.sh`), never `sudo envsubst`.
- Shared env-file primitives: `lib/helpers.sh` (`env_file_get`,
  `env_file_write`).
