# Behaviors — vllm-omni-setup

> **Information source:** [`research.md`](./research.md) — vLLM-Omni project research (verified 2026-07-24).
> **Design basis:** This feature deliberately mirrors the existing [`tasks/setup-vllm.sh`](../../../tasks/setup-vllm.sh);
> read that script alongside this spec. Only the image, the `--omni` flag, the default port, and the env-var
> namespace differ.

## Overview

This feature adds `tasks/setup-vllm-omni.sh` — a modular, idempotent Bash script that deploys a Docker-based,
OpenAI-compatible **vLLM-Omni** inference server for omni-modality models (TTS, diffusion, image/video
generation, any-to-any) on Ubuntu. It runs **in parallel** with the existing text-LLM `setup-vllm.sh`
(separate port, separate `/srv/vllm-omni` directory, separate `VLLM_OMNI_*` env namespace). The existing
`setup-vllm.sh` is **not modified**.

### Files Delivered

| File | Purpose |
|------|---------|
| `tasks/setup-vllm-omni.sh` | Core vLLM-Omni setup script (new) |
| `machine-config.yml.example` | Add a `setup-vllm-omni` entry, `enabled: false` (edit) |
| `README.md` | Document the script under "AI & LLM Services" (edit) |
| `skills/kwisatz-assistant/SKILL.md` | Add to the service-category table (edit) |
| `CONTEXT.md` | Add a "vllm-omni" domain term (edit) |

Generated at runtime on the target host (not committed): `/srv/vllm-omni/.env`, `/srv/vllm-omni/docker-compose.yml`.

### Design Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Integration shape | **New standalone task script**, mirroring `setup-vllm.sh` (one script per component) |
| 2 | Image source | **Prebuilt** Docker Hub images — no local build |
| 3 | Default GPU backend | **NVIDIA (CUDA)**; auto-detection of `nvidia`/`amd`/`cpu` retained |
| 4 | Default model | **Model-agnostic** — no default; without a model the container is not started |
| 5 | Firewall | **No UFW code in the script** (parity with `setup-vllm.sh`) |
| 6 | Compose generation | **Inline heredocs** (backend/traefik/arch are strongly conditional) |
| 7 | Env namespace | Dedicated `VLLM_OMNI_*` variables; project dir `/srv/vllm-omni` |
| 8 | Default port | `8091` (from the upstream quickstart; avoids `setup-vllm.sh`'s `8000`) |
| 9 | Shared helpers | Source `lib/helpers.sh` (logging, `ensure_proxy_network`, colours) |
| 10 | Scope | NVIDIA + AMD backends only; XPU/NPU/MUSA out of scope |

### Environment Variables

All variables have sensible defaults and can be overridden before running (or via `machine-config.yml`).

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_DIR` | `/srv/vllm-omni` | Host directory for `.env` and `docker-compose.yml` |
| `HF_CACHE_DIR` | `$HOME/.cache/huggingface` | Host HF cache, mounted into the container |
| `VLLM_OMNI_VERSION` | `latest` | Image tag (e.g. `v0.24.0`); arch suffix applied automatically |
| `VLLM_OMNI_PORT` | `8091` | Host API port (container listens on `8000`) |
| `VLLM_OMNI_MODEL` | *(empty)* | HF model ID or in-container snapshot path. Empty = do not start |
| `HF_TOKEN` | *(empty)* | HuggingFace token for gated models |
| `VLLM_OMNI_GPU_UTIL` | `0.90` | GPU memory utilization fraction (GPU backends only) |
| `VLLM_OMNI_TENSOR_PARALLEL` | `1` | Tensor-parallel degree (# GPUs); GPU backends only |
| `VLLM_OMNI_MAX_MODEL_LEN` | *(empty)* | Cap context length; empty = model default |
| `VLLM_OMNI_SHM_SIZE` | `8g` | Container shared-memory size |
| `VLLM_OMNI_EXTRA_ARGS` | *(empty)* | Extra `vllm serve` arguments appended verbatim |
| `VLLM_OMNI_TRAEFIK` | `false` | Enable Traefik reverse-proxy integration |
| `VLLM_OMNI_DOMAIN` | *(empty)* | Domain for Traefik (**required** when `VLLM_OMNI_TRAEFIK=true`) |
| `PROXY_NETWORK` | `proxy` | Shared Docker network name (Traefik mode) |

CLI flags mirror the env vars, matching `setup-vllm.sh`: `--nvidia`, `--amd`, `--cpu`, `--port`, `--model`,
`--hf-token`, `--hf-cache`, `--gpu-util`, `--tensor-parallel`, `--max-model-len`, `--shm-size`, `--dir`,
`--version`, `--traefik`, `--domain`, `--force`, `--check`, `--help`.

---

## Input Validation

### Happy Path

Before any action, user-controlled values are validated (reusing the validation approach in `setup-vllm.sh`):
model ID charset, extra-args charset (reject `` ` ``, `$`, `;`, `|`, `&`, `<`, `>`), domain, port range,
GPU-util range, tensor-parallel ≥ 1, shm-size format. `VLLM_OMNI_VERSION` is validated against a safe tag
charset (`[A-Za-z0-9._-]`).

### Error Cases

- Any invalid value prints a red error via `error()` and exits 1 before touching the host.

---

## Argument Parsing

### Happy Path

Flags are parsed into the same variables as their env-var equivalents. `--help` prints usage (including
model-selection examples across modalities) and exits 0. Unknown flags are a fatal error (matching
`setup-vllm.sh`, which exits 1 on unknown options).

### Edge Cases

- `--nvidia` / `--amd` / `--cpu` set the backend explicitly and skip auto-detection.
- ROCm on arm64 is rejected with an error (parity with `setup-vllm.sh`).
- `--tensor-parallel > 1` with the `cpu` backend is rejected with an error.

---

## Pre-Flight Validation

### Happy Path

- Warn (non-fatal) if running as root or if the OS is not Ubuntu.
- Verify Docker is installed and the daemon is running; print the detected Docker version.
- Warn if Docker Compose is older than v2.
- **Direct mode only:** verify `VLLM_OMNI_PORT` is free (`ss -tln`); error if in use.
- **Traefik mode:** call `ensure_proxy_network`; error if `VLLM_OMNI_DOMAIN` is empty.

### Error Cases

- Docker not installed → red error naming `setup-docker.sh`, exit 1.
- Docker daemon not running → red error suggesting `sudo systemctl start docker`, exit 1.
- Port in use (direct mode) → red error suggesting a different `VLLM_OMNI_PORT`, exit 1.

---

## Backend Detection & Image Resolution

### Happy Path

If no backend flag is given, auto-detect in this order (reusing the `setup-vllm.sh` `detect_gpu` logic):
`nvidia-smi` → `lspci` → `/dev/dri` + `vulkaninfo` → CPU fallback. On arm64 with an AMD GPU, fall back to CPU
with a warning (ROCm unsupported on arm64).

The Docker image is resolved from the backend, architecture, and `VLLM_OMNI_VERSION`:

| Backend | Arch | Image |
|---------|------|-------|
| `nvidia` | amd64 | `vllm/vllm-omni:${VERSION}` |
| `nvidia` | arm64 | `vllm/vllm-omni:${VERSION}-aarch64` |
| `amd` | amd64 | `vllm/vllm-omni-rocm:${VERSION}` |
| `cpu` | amd64 | `vllm/vllm-omni:${VERSION}` + a warning that generative/diffusion on CPU is impractical |
| `cpu` | arm64 | `vllm/vllm-omni:${VERSION}-aarch64` + the same CPU warning |

The rule: only arm64 gets the `-aarch64` tag suffix; amd64 uses the plain tag (a multi-arch manifest). The
resolved image name is printed via `info()`.

### Edge Cases

- With the default `VLLM_OMNI_VERSION=latest`, arm64 resolves to `vllm/vllm-omni:latest-aarch64`, amd64 to
  `vllm/vllm-omni:latest`.
- CPU backend selection prints a prominent yellow warning but does **not** abort.

---

## Idempotency Handling

### Happy Path — No Existing Installation

If `/srv/vllm-omni/docker-compose.yml` does not exist, proceed with a fresh install. `--check` in this state
prints "not installed" and exits 0.

### Happy Path — Existing Installation

If the compose file exists, print the current stack status (running/stopped, `docker compose ps`). Then:

- `--check` → print status and exit 0.
- No `--force` → print "Nothing to do. Use --force to re-create." and exit 0. Existing data/config untouched.
- `--force` → `docker compose down` on the existing stack, then re-create.

Re-running the script without `--force` never destroys the existing `.env` or model data.

### Edge Cases

- An existing `.env` is backed up to `.env.bak` before being rewritten (matching `setup-vllm.sh`).

---

## Directory & Config Generation

### Happy Path

- Create `PROJECT_DIR` (`sudo mkdir -p` + `chown` to the current user if missing) and `HF_CACHE_DIR`.
- Write `PROJECT_DIR/.env` (mode `600`) containing all `VLLM_OMNI_*` runtime values, with commented
  model-selection examples spanning modalities (text-to-image, TTS, any-to-any Qwen3-Omni).
- Generate `PROJECT_DIR/docker-compose.yml` via inline heredocs:
  - `networks`: internal `vllm-omni`; plus external `${PROXY_NETWORK}` when Traefik is enabled.
  - service `vllm-omni`: resolved image, `restart: unless-stopped`, `env_file: .env`,
    `HF_HOME=/root/.cache/huggingface`, HF cache volume mount, `shm_size`, and `ipc: "host"` for GPU backends.
  - **Direct mode:** publish `"${VLLM_OMNI_PORT}:8000"`.
  - **NVIDIA:** the CDI device `devices: ["nvidia.com/gpu=all"]` — deliberately *not*
    `deploy.resources.reservations.devices`, whose prestart-hook injection is undone by a later
    `systemctl daemon-reload` on the running container. Requires a CDI spec on the host
    (`setup-nvidia-container.sh`); the pre-flight fails when `nvidia.com/gpu=all` is not listed.
  - **AMD:** `/dev/kfd` + `/dev/dri` devices, `group_add: [video]`, `cap_add: [SYS_PTRACE]`,
    `security_opt: [seccomp=unconfined]`.
  - **Traefik mode:** router/service labels on port `8000` (`Host(${VLLM_OMNI_DOMAIN})`, `websecure`,
    `certresolver=letsencrypt`) and attach the `${PROXY_NETWORK}` network; omit the published port.
  - `command`: `vllm serve ${VLLM_OMNI_MODEL} --omni --host 0.0.0.0 --port 8000`, plus
    `--gpu-memory-utilization ${VLLM_OMNI_GPU_UTIL}` (GPU) or `--device cpu` (CPU), and the optional
    `--tensor-parallel-size` / `--max-model-len` / `${VLLM_OMNI_EXTRA_ARGS}` (emitted only when set).
    The model is the **positional** argument of `vllm serve` (not `--model`).

### Edge Cases

- **Empty ENTRYPOINT — the command must start with `vllm serve`.** The `vllm/vllm-omni*` images define
  `ENTRYPOINT []` (verified in the upstream `docker/Dockerfile.cuda` and the official CUDA install docs, which
  run `... vllm/vllm-omni:<tag> vllm serve <model> --omni --port <p>`). Unlike `vllm-openai` (whose entrypoint
  already is the server), the compose `command:` here must supply the **full** `vllm serve … --omni …`
  invocation, or the container exits immediately trying to exec `--model`.
- The `--omni` flag is always present in the command — this is what distinguishes the Omni server.
- The LM Studio models mount from `setup-vllm.sh` is intentionally **omitted** (Omni models are HF diffusion/TTS
  checkpoints, not GGUF).

---

## Stack Startup & Health Check

### Happy Path — Model Configured

If `VLLM_OMNI_MODEL` is set: `docker compose pull`, then `docker compose up -d`. In direct mode, poll
`http://localhost:${VLLM_OMNI_PORT}/health` for up to 120 s (5 s interval); print success when healthy, or a
warning (not a fatal error) if it is still loading. In Traefik mode, skip the direct health check.

### Happy Path — No Model (default)

If `VLLM_OMNI_MODEL` is empty: pull the image but **do not start** the container. Print next-steps:
download a model with `huggingface-cli`, set `VLLM_OMNI_MODEL` in `.env`, then `docker compose up -d`.
This matches `setup-vllm.sh` exactly.

### Error Cases

- `docker compose pull` / `up -d` failure → red error with a pointer to `docker compose logs -f`, exit 1.

---

## Summary Output

### Happy Path

Print a coloured summary block: backend + arch, resolved image, project dir, HF cache mapping, tensor-parallel /
max-model-len (when set), config path, and the API URL (`http://localhost:${VLLM_OMNI_PORT}/v1` or
`https://${VLLM_OMNI_DOMAIN}/v1`). Include useful commands (start/stop/logs/shell/`--check`), how to list models
(`curl .../v1/models`), and a model-download hint. If no model is configured, prominently state that
`VLLM_OMNI_MODEL` must be set before the server will start.

---

## Repository Registration

### Happy Path

- `machine-config.yml.example`: add a `setup-vllm-omni` entry with `enabled: false`, a `description`, and
  commented example env vars (`VLLM_OMNI_PORT`, `VLLM_OMNI_MODEL`).
- `README.md`: add a `setup-vllm-omni.sh` subsection under "AI & LLM Services" describing purpose, the prebuilt
  image, backends, the `--omni` serving model, and the env vars.
- `skills/kwisatz-assistant/SKILL.md`: add `setup-vllm-omni` to the **AI / LLM** row of the
  service-category table.
- `CONTEXT.md`: add a "vllm-omni" entry under AI/ML domain terms.

### Edge Cases

- The orchestrator discovers scripts dynamically, so the new script appears in `./run-setup.sh status`
  automatically once present in `tasks/`; the config entry only sets its enabled state and configuration.

---

## Success Criteria (verifiable)

1. `shellcheck tasks/setup-vllm-omni.sh` passes with no warnings.
2. `yamllint` passes on the edited `machine-config.yml.example`.
3. `bash tasks/setup-vllm-omni.sh --help` prints usage and exits 0 (no Docker interaction).
4. `bash tasks/setup-vllm-omni.sh --check` reports install status and exits 0.
5. `./run-setup.sh status` lists `setup-vllm-omni.sh`.
6. With no `VLLM_OMNI_MODEL`, a run generates `.env` + `docker-compose.yml`, pulls the image, and prints
   next-steps **without** starting a container.
7. Idempotency: a second run without `--force` makes no changes and exits 0.
8. The generated `docker-compose.yml` contains `--omni` in the service command and parses under
   `docker compose config`.

> A full end-to-end GPU serve (loading a real Omni model) is only verifiable on the target NVIDIA server and is
> out of scope for automated verification here.

## Out of Scope

- Local image builds (`docker/Dockerfile.*`) — prebuilt images are used.
- XPU / NPU / MUSA backends.
- Model download/management and per-model tuning recipes.
- Modifying the existing `setup-vllm.sh`.
