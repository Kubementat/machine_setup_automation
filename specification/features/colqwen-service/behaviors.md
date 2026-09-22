# Feature: ColQwen Service

## Overview

A setup task script `tasks/setup-colqwen.sh` that generates a complete, immediately buildable Docker project for a **ColQwen2.5 embedding service** under `/srv/colqwen`.

The generated project bundles a small FastAPI app that loads a ColQwen2.5 model **once at startup** (via `colpali-engine`) and serves multi-vector embeddings for images and text queries. Models are mounted read-only from a host directory — they are **never** baked into the Docker image and are **never** downloaded at runtime (fully offline operation).

The script **only generates** the project. The user builds and starts the service afterwards:

```bash
cd /srv/colqwen
docker compose build
docker compose up -d
```

The script is deliberately **configurable instead of auto-detecting**: the user is responsible for choosing compatible versions (NGC PyTorch tag, colpali-engine version). No validation of version compatibility takes place.

---

## Configuration

All tunable values are environment variables with sensible defaults, each with a CLI flag equivalent (non-interactive by default, per project conventions):

| Env Var | Flag | Default | Purpose |
|---------|------|---------|---------|
| `PROJECT_DIR` | `--dir <path>` | `/srv/colqwen` | Target directory for the generated project |
| `COLQWEN_MODEL_DIR` | `--model-dir <path>` | `$HOME/.cache/huggingface` | Host directory containing the models — typically the Hugging Face cache (`hub/models--vidore--colqwen2.5-v0.2/…`), but any directory with model folders works |
| `COLQWEN_MODEL` | `--model <id-or-path>` | `vidore/colqwen2.5-v0.2` | Model the service loads: a HF model ID (resolved **offline** from the mounted cache) or an absolute path to a model directory inside the mount |
| `COLPALI_VERSION` | `--colpali-version <ver>` | `0.3.13` | `colpali-engine` version installed into the image (last transformers-4.x release; 0.3.14+ pull transformers 5.x, which drops the vidore LoRA adapter weights) |
| `NGC_PYTORCH_TAG` | `--ngc-tag <tag>` | `25.10-py3` | NVIDIA NGC PyTorch base image tag (`nvcr.io/nvidia/pytorch:<tag>`); torch 2.9 / CUDA 13.0.2, satisfies the colpali-engine 0.3.13 torch pin and runs on driver 580.x |
| `COLQWEN_PORT` | `--port <n>` | `8100` | Host port mapped to the service |

Additional flags: `--force` (re-generate over an existing installation), `--check` (status only, no changes), `--help`.

---

## Generated Project Layout

All generated files originate from static template files in `templates/colqwen/` (no inline templates in the bash script, per project conventions). The script renders them by substituting configuration values.

```text
/srv/colqwen/
├── Dockerfile            # FROM nvcr.io/nvidia/pytorch:${NGC_PYTORCH_TAG} (via build arg)
├── docker-compose.yml    # build args, model volume, GPU reservation, port mapping
├── requirements.txt      # static app dependencies (fastapi, uvicorn, pillow, ...)
├── .env                  # single source of configuration for the generated project
├── test.sh               # post-install smoke test (run once the service is up)
├── test.png              # fixture image for test.sh
└── app/
    └── main.py           # FastAPI embedding service
```

Key characteristics:

- **`.env` is the single configuration source.** `docker-compose.yml` reads all values (`NGC_PYTORCH_TAG`, `COLPALI_VERSION`, `COLQWEN_MODEL_DIR`, `COLQWEN_MODEL`, `COLQWEN_PORT`) from `.env`. The `Dockerfile` receives `NGC_PYTORCH_TAG` and `COLPALI_VERSION` as build args. Changing a version means editing `.env` and rebuilding — no file regeneration required.
- **`colpali-engine==${COLPALI_VERSION}`** is installed via build arg (not pinned in `requirements.txt`), so a version switch only requires an `.env` edit plus `docker compose build`. `requirements.txt` holds the static dependencies only.
- **Model volume:** `${COLQWEN_MODEL_DIR}` is mounted read-only at the **identical absolute path** inside the container. Rationale: adapter models carry an absolute `base_model_name_or_path` in their `adapter_config.json` (pointing into the host's HF cache); with an identical-path mount these paths resolve inside the container without modifying `adapter_config.json` (which is out of scope). `HF_HOME` points at the mount so HF model IDs resolve offline from the cache.
- **Offline enforcement:** the container sets `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`. No weights are downloaded at build or runtime.
- **GPU:** the compose file requests the CDI device `nvidia.com/gpu=all` via `devices:` — deliberately *not*
  `deploy.resources.reservations.devices`, whose prestart-hook injection is undone by a later
  `systemctl daemon-reload` on the running container. Requires a CDI spec on the host
  (`setup-nvidia-container.sh`); the pre-flight fails when `nvidia.com/gpu=all` is not listed.
  `restart: unless-stopped`.
- Template placeholders must keep the templates lintable (hadolint for the Dockerfile, yamllint for the compose file).

---

## Behavior 1: Pre-Flight Checks & Argument Parsing

### Description
The script validates its environment and inputs before generating anything. It never prompts interactively.

### Happy Path
1. Script sources `lib/helpers.sh` and uses its logging helpers (`step`, `info`, `success`, `warn`, `error`).
2. Parses CLI flags; each flag overrides the corresponding environment variable.
3. Validates inputs:
   - `COLQWEN_PORT` is numeric and within 1–65535.
   - `COLPALI_VERSION` and `NGC_PYTORCH_TAG` contain only safe characters (`[A-Za-z0-9._-]`), preventing template injection.
   - `COLQWEN_MODEL` contains only safe characters plus `/` and no `..` segments.
   - `PROJECT_DIR` and `COLQWEN_MODEL_DIR` are absolute paths.
4. Verifies Docker is installed and the daemon is running; warns if Docker Compose is older than v2.
5. Proceeds to generation.

### Error Cases
- **Unknown flag:** exit non-zero with usage hint (`--help`).
- **Invalid port / version string / relative path:** exit non-zero with a clear message naming the offending variable.
- **Docker not installed:** exit non-zero suggesting `setup-docker.sh`.
- **Docker daemon not running:** exit non-zero suggesting `sudo systemctl start docker`.

### Edge Cases
- **No GPU / no CUDA on host:** not checked — GPU, CUDA, and BF16 validation are explicitly out of scope. Generation succeeds regardless.
- **Port already in use:** not treated as an error at generation time (the service is not started by this script); the port is only validated syntactically.

---

## Behavior 2: Idempotent Project Generation

### Description
The script can be run repeatedly without destroying an existing installation or its configuration.

### Happy Path (fresh install)
1. Creates `PROJECT_DIR` (via sudo if required, then chowns to the invoking user) and `app/`.
2. Renders all templates from `templates/colqwen/` into `PROJECT_DIR`: `Dockerfile`, `docker-compose.yml`, `requirements.txt`, `.env`, `app/main.py`, `test.sh` (executable), `test.png`.
3. Sets `.env` permissions to `600`.
4. Prints the summary (see Behavior 6) and exits 0.

### Happy Path (existing install)
1. If `PROJECT_DIR/docker-compose.yml` already exists, the script prints the installation status (config location, whether the compose stack is running) and exits 0 **without modifying anything**.
2. With `--check`, the script only ever prints this status and exits 0 (works for both fresh and existing state).
3. With `--force`, the script backs up an existing `.env` to `.env.bak`, then re-renders all files.

### Error Cases
- **`PROJECT_DIR` not writable and sudo unavailable:** exit non-zero with a clear message.

### Edge Cases
- **Partial previous generation** (e.g. `Dockerfile` exists but `docker-compose.yml` missing): treated as fresh install; files are (re-)rendered.
- **User-modified generated files:** without `--force` nothing is touched; with `--force` all files are overwritten (only `.env` gets a backup).

---

## Behavior 3: Central Configuration via .env

### Description
All user-supplied settings are persisted in `PROJECT_DIR/.env`; the generated Docker files read their configuration exclusively from it.

### Happy Path
1. The rendered `.env` contains: `NGC_PYTORCH_TAG`, `COLPALI_VERSION`, `COLQWEN_MODEL_DIR`, `COLQWEN_MODEL`, `COLQWEN_PORT` — each with a short explanatory comment.
2. `docker compose` automatically loads `.env` from the project directory; the compose file forwards `NGC_PYTORCH_TAG` and `COLPALI_VERSION` as build args and uses the remaining values for volume, environment, and port configuration.
3. The user changes a value (e.g. `COLPALI_VERSION`), runs `docker compose build && docker compose up -d`, and the service uses the new configuration — without re-running the setup script.

### Error Cases
- None at generation time. Invalid values edited into `.env` later surface as `docker compose` build/start errors (user responsibility, consistent with the configurable-not-validating design).

### Edge Cases
- **Re-run with different flags but without `--force`:** the existing `.env` is preserved untouched (see Behavior 2); the new values are **not** silently merged. The status output points this out.

---

## Behavior 4: Model Volume Integration

### Description
Models live outside the image and outside the generated project files; they are provided by the user and mounted as a read-only volume.

### Happy Path
1. `COLQWEN_MODEL_DIR` points to the host directory containing the models — typically the Hugging Face cache (`$HOME/.cache/huggingface`, with models under `hub/models--vidore--colqwen2.5-v0.2/snapshots/<hash>/`), populated e.g. via `hf download`.
2. The compose file mounts it read-only at the **identical absolute path** inside the container and sets `HF_HOME` to it.
3. The service receives `COLQWEN_MODEL` via the container environment — either a HF model ID (e.g. `vidore/colqwen2.5-v0.2`, resolved offline from the mounted cache) or an absolute path to a model directory inside the mount.
4. Adapter models whose `adapter_config.json` carries an absolute `base_model_name_or_path` into the host's HF cache resolve without modification, because host path and container path are identical.
5. No model download happens at any point — not by the script, not by the container.

### Error Cases
- None fatal at generation time (missing models block the *service*, not the *generation*).

### Edge Cases
- **Default model dir does not exist:** the script creates `$HOME/.cache/huggingface` (empty) and warns that models must be placed there before starting the service.
- **Explicitly given `COLQWEN_MODEL_DIR` does not exist:** the script warns (possible typo) but does **not** create it and continues generating.
- **Configured model not found:** for a path-form `COLQWEN_MODEL` the script warns when the directory is missing; for an ID-form model it warns when `COLQWEN_MODEL_DIR/hub/models--<org>--<name>` is absent. Warning only — generation continues.
- **Flat model layout:** users with plain model directories (e.g. `/srv/models/colqwen2.5-v0.2/`) set `COLQWEN_MODEL_DIR=/srv/models` and `COLQWEN_MODEL=/srv/models/colqwen2.5-v0.2` (path form); the identical-path mount makes this work unchanged.

---

## Behavior 5: ColQwen Embedding Service (app)

### Description
The generated `app/main.py` is a FastAPI service that loads the ColQwen2.5 model once and serves multi-vector embeddings for the lifetime of the container.

### Happy Path
1. On startup the app loads model and processor via `colpali-engine` (`ColQwen2_5` / `ColQwen2_5_Processor`), on CUDA with `bfloat16`, from `COLQWEN_MODEL` — a HF model ID resolved offline from the mounted cache, or an absolute model directory path.
2. The model stays loaded for the entire container lifetime; requests never trigger a (re-)load.
3. `POST /embed/images` — accepts one or more images as multipart file uploads; responds with `{"embeddings": [...]}` containing one multi-vector embedding (list of vectors) per image, in input order.
4. `POST /embed/queries` — accepts JSON `{"queries": ["...", ...]}`; responds with `{"embeddings": [...]}` containing one multi-vector embedding per query, in input order.
5. `GET /health` — responds `200 {"status": "ok"}`. Requests are only served after startup (= model load) completed, so a 200 implies the model is ready; usable as readiness probe by reverse proxies such as llama-swap (default `checkEndpoint: /health`).
6. The app listens on container port 8000 (mapped to `COLQWEN_PORT` on the host).

### Error Cases
- **Configured model missing or unloadable at startup:** the app logs a clear error naming the configured model reference and exits non-zero (container stops; visible via `docker compose logs`). No silent retry loop, no download attempt.
- **LoRA adapter weights silently dropped at load** (key-mapping mismatch between checkpoint and installed transformers version — all `lora_B` weights still zero after loading): the app logs a clear error pointing at the `COLPALI_VERSION` / `NGC_PYTORCH_TAG` combination and exits non-zero. The service must never silently serve base-model embeddings for an adapter model.
- **Empty request** (no files / empty query list): HTTP 400 with a descriptive message.
- **Non-image upload on `/embed/images`:** HTTP 400 naming the offending file.

### Edge Cases
- **Concurrent requests:** requests are processed sequentially against the single loaded model instance; correctness over throughput (no batching/queueing logic beyond what FastAPI provides).
- **Large batches:** no artificial limit imposed by the app; GPU memory is the natural bound (user responsibility).

---

## Behavior 6: Summary Output & Next Steps

### Description
The script ends with a colourful, expressive summary so the user sees at a glance what was generated and what to do next.

### Happy Path
1. Prints (colour-coded via `lib/helpers.sh`): project directory, model directory (noting the identical-path mount), configured model, NGC PyTorch tag, colpali-engine version, host port, and `.env` location.
2. Prints the next steps verbatim:
   ```bash
   cd /srv/colqwen
   docker compose build
   docker compose up -d
   ./test.sh    # smoke test, once the log shows 'Application startup complete'
   ```
3. Prints example `curl` calls for `POST /embed/queries` and `POST /embed/images`.
4. Repeats any warnings raised during generation (e.g. model directory empty).

### Error Cases
- None.

### Edge Cases
- **`--check` / existing-install status output** uses the same summary style but clearly states that nothing was changed.

---

## Out of Scope

Explicitly **not** part of this feature (from the original ticket, plus repo-specific additions):

- automatic download of Hugging Face models
- automatic discovery or validation of NGC PyTorch tags
- automatic detection of the installed CUDA version
- automatic compatibility checks between NGC, PyTorch, and colpali-engine versions
- automatic adjustment of `adapter_config.json`
- LlamaSwap integration
- health checks in the setup script or compose file, and integration tests (the app itself exposes `GET /health`, see Behavior 5)
- automatic GPU or BF16 validation
- Traefik reverse-proxy integration and ufw firewall rules
- building or starting the service from the setup script (`docker compose build`/`up` remain user steps)
