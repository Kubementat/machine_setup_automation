# Plan: ComfyUI MCP server as a llama-swap model, with safe updates

**Date:** 2026-09-15 (revision 3)
**Status:** Decisions made, target facts collected. Implementation step 1 (C1) in
progress.
**Scope:** An own MCP server that wraps `comfy-cli`, runs as a **llama-swap model**
next to `comfyui_auto`, is reached through llama-swap's `/upstream` passthrough with
the **same bearer token as the LLMs**, can download models, and can update ComfyUI
**through `tasks/setup-comfyui.sh`**, never through `comfy update`.

History: revision 1 used an own systemd service behind a separate proxy route with
its own token — dropped, llama-swap manages everything. Revision 2 left the
decisions open.

## Goal

- llama-swap manages ComfyUI (`comfyui_auto`, already working) **and** the MCP server.
- One MCP endpoint: `https://llm.manuelspoerer.de/upstream/comfyui-mcp/mcp`,
  authenticated exactly like `/v1/*`.
- Tools to discover nodes/models, run workflows, download models, and see, update
  and roll back the ComfyUI release with the guarantees of a manual
  `COMFYUI_REF=vX ./tasks/setup-comfyui.sh` run.

## Decisions

| # | Decision |
|---|---|
| D1 | The MCP model is part of `setup-comfyui.sh` (`COMFYUI_MCP=true`, only valid with `COMFYUI_SUPERVISOR=llama-swap`). It already owns the fragment, the llama-swap discovery, `COMFYUI_USER` and the `setpriv` prefix. |
| D2 | The operator maintains the matrix in `config.yaml`. The task never edits it; `--check` verifies it. |
| D3 | The MCP server gets **its own llama-swap API key**, added by the fragment. It is used for waking ComfyUI and by the update helper to unload an outdated `comfyui_auto`. |
| D4 | The update helper writes the new `COMFYUI_REF` into `machine-config.yml` (line-targeted edit, `.bak` kept). |
| D5 | Model download is part of version 1, with limits (C2). |

## Verified facts this plan rests on

### Target server (operator / measured 2026-09-15)

| Fact | Source |
|---|---|
| `llm.manuelspoerer.de` → Cloudflare → Caddy on the VPS → llama-swap. A request **with** `Authorization: Bearer …` passes Caddy and is checked by llama-swap (a bogus token gets llama-swap's `401`, realm `llama-swap`); a request **without** it gets Caddy's `basic_auth` (realm `restricted`). | measured |
| LLM clients send a bearer token (a llama-swap API key). | operator |
| `apiKeys` are configured (two keys, top-level in `config.yaml`). | operator |
| The installed llama-swap uses the **top-level `matrix:`** syntax (as in `templates/llama-swap/config.yaml`), not `routing.router.settings.matrix` from the current upstream docs. | operator |
| `COMFYUI_MODELS_DIR` is not set → default `${COMFYUI_DIR}/ComfyUI/models`, inside the ComfyUI workspace; no `extra_model_paths.yaml`. | operator, `tasks/setup-comfyui.sh` |
| The repo checkout that holds `machine-config.yml` is on the server (the workstation checkout has none). | operator, workstation |

### Request path and auth (llama-swap)

| Fact | Source |
|---|---|
| `/upstream/{path...}` is wrapped by `apiChain` like `/v1/models`. Keys are accepted as `Authorization: Bearer`, Basic password, or `x-api-key`. | llama-swap `internal/server/server.go`, `internal/server/auth.go` |
| `/upstream/<model>/<path>` strips the prefix and starts the model for any path not in `upstream.ignorePaths` (default: static file extensions, `^/ws$`, `^/api/jobs$`). | llama-swap `internal/server/api.go`, `docs/config.example.yaml` |
| `/comfyui/{path}` only starts `comfyui_auto` on `/comfyui/` itself; other paths get `409` while it is unloaded. | llama-swap `internal/server/api.go` |
| Cloudflare cuts origin responses after ~100 s (`524`). | Cloudflare proxy limit |

### Config merge and secrets

| Fact | Source |
|---|---|
| `config.yaml` and every file in `--config-dir` are merged, then validated as one config. Lists (e.g. `apiKeys`) are appended; the same model ID twice or a different scalar value is an error. See `docs/research/llama-swap-config-fragments.md`. | llama-swap `internal/config/merge.go` |
| `${env.VAR}` is substituted per source file, fragments included (tested: `apiKeys: [${env.TEST_API_KEY}]` in a config-dir file). **A referenced but unset variable is a load error.** | llama-swap `internal/config/macros.go`, `merge.go`, `merge_test.go`, `config_test.go` |
| Matrix `vars` referencing an unknown model is a load error. | llama-swap `internal/config/matrix.go` |
| llama-swap's own `get_config` output redacts env entries whose name contains `key`/`token`/`secret`. | llama-swap `internal/config/redact.go` |
| `setpriv --reuid … --init-groups --` keeps the environment of llama-swap, including `HOME` (root's). | `tasks/setup-comfyui.sh` `llama_swap_cmd_prefix` |
| The systemd drop-in `llama-swap.service.d/50-comfyui.conf` is managed by `setup-comfyui.sh`; changing it or the fragment makes the task restart llama-swap once, which unloads every model. | `templates/comfyui/llama-swap-dropin.conf`, `tasks/setup-comfyui.sh` |

### Scheduling

| Fact | Source |
|---|---|
| Matrix solver: if the requested model runs, forward; else pick the lowest-`evict_costs` set containing it, evict every running model outside it, start only the requested model. "A model in no set can only run alone." (Documented for current llama-swap; confirm on the installed release.) | llama-swap `docs/kb/guides/routing/groups-and-matrix.md` |
| Unloading does not wait for in-flight requests: "Stop kills the upstream". | llama-swap `internal/router/base.go` |
| Per-model `concurrencyLimit` defaults to 10; excess requests get `429`. | llama-swap `docs/config.example.yaml` |
| `${PORT}` is assigned alphabetically from `startPort`, so `comfyui_auto`'s port moves when models change. | llama-swap `internal/config/macros.go` |
| `sync_models` never touches the matrix. | `sync_models/llama_swap.py:5` |

### comfy-cli and the ComfyUI install

| Fact | Source |
|---|---|
| `comfy-cli` addresses ComfyUI only as `http://host:port`. | `comfy-cli` `comfy_cli/local_address.py` |
| `comfy model download --url … --relative-path <dir relative to workspace> --filename …`; `..`, separators and absolute components in remote-supplied names are rejected. Without `--relative-path` it asks interactively for CivitAI models. | `comfy-cli` `comfy_cli/command/models/models.py` |
| Tokens come from `HF_API_TOKEN` / `CIVITAI_API_TOKEN` (env); `--set-hf-api-token` would **persist** the token in comfy-cli's config. Tokens are only sent to `huggingface.co`, `huggingface.com`, `hf.co` / `civitai.com`, `civitai.red`. | `comfy-cli` `comfy_cli/constants.py`, `models.py` |
| The httpx downloader writes to a temp file and removes it when the download fails. | `comfy-cli` `comfy_cli/file_utils.py` |
| `comfy update comfy` = `git pull` + unconstrained `pip install -r requirements.txt` — breaks the pinned tag, torch constraints and Model Resolver patch managed by `setup-comfyui.sh`. | `comfy-cli` `comfy_cli/cmdline.py`; `tasks/setup-comfyui.sh` |
| `COMFYUI_REF` lives in `machine-config.yml` (gitignored) under `.scripts.setup-comfyui.env`; `run-setup.sh` has no single-task run. Host `yq` (apt) drops comments on write-back. | `run-setup.sh`, `tasks/setup-basics.sh` |
| `COMFYUI_USER` defaults to `${SUDO_USER:-${USER}}` — `root` when run from a root unit. | `tasks/setup-comfyui.sh` |

## Architecture

```
MCP client ─▶ https://llm.manuelspoerer.de/upstream/comfyui-mcp/mcp   (Authorization: Bearer <llama-swap key>)
               ─▶ Cloudflare ─▶ Caddy (bearer passes, like /v1)
               ─▶ llama-swap :9292 /upstream (same apiKeys as /v1)
               ─▶ comfyui-mcp  (llama-swap model, ${PORT}, runs as COMFYUI_USER)
                    ├─ ensure_loaded: GET http://127.0.0.1:9292/comfyui/  (own key, D3)
                    ├─ comfy --json --where local --workspace=… …
                    │     COMFY_LOCAL_URL=http://127.0.0.1:${COMFYUI_PORT}
                    └─ update tools: systemctl start comfyui-update@<ref>.service (polkit)
               ─▶ ComfyUI  (comfyui_auto, fixed COMFYUI_PORT)

secrets: /srv/comfyui-mcp/.env ─(EnvironmentFile in llama-swap drop-in)─▶ llama-swap env
         ─▶ ${env.COMFYUI_MCP_API_KEY} in apiKeys (fragment) + inherited by comfyui-mcp
matrix (operator):  comfy: "c & m"   llms: "(<every LLM>) & m"   m = comfyui-mcp
```

## Components

### C1 — Fixed ComfyUI port in llama-swap mode

`comfy-cli` talks to ComfyUI directly and needs a stable `host:port`.

- Fragment template: `--port ${COMFYUI_PORT}` and
  `proxy: http://127.0.0.1:${COMFYUI_PORT}` instead of `${PORT}`; add
  `COMFYUI_PORT` to the `envsubst` list.
- Update `--help` and `AUTOMATIONS.md` (llama-swap mode no longer ignores
  `COMFYUI_PORT`); `--check` probes `127.0.0.1:${COMFYUI_PORT}` when ComfyUI is loaded.
- The changed fragment makes the next run restart llama-swap once.

### C2 — MCP server code (`comfyui_mcp/`, next to `sync_models/`)

- Python, official MCP SDK, **stateless streamable HTTP** at `/mcp`, `GET /health`
  for `checkEndpoint`. Stateless because llama-swap may restart or unload it.
- No own client authentication — llama-swap checks the bearer token first. Binds
  `127.0.0.1`.
- Every `comfy` call passes `--workspace=${COMFYUI_DIR}/ComfyUI` explicitly (no
  reliance on `set-default`, whose config would live under the inherited `HOME`).
- Every ComfyUI-facing tool calls `ensure_loaded()` first.
- Long operations return a job id immediately (Cloudflare 100 s limit); one
  in-process job table, lost on restart (the tools say so).

Implemented in step 2a (`comfyui_mcp/`, mcp 2.2.0 `MCPServer`, stateless + JSON
responses, DNS-rebinding protection off because llama-swap forwards the client's
Host header; tested against fake llama-swap/ComfyUI/comfy-cli with protocol
revisions 2025-11-25 and 2026-07-28):

| Tool | Does | Changes state |
|---|---|---|
| `search_nodes(query)`, `show_node(name)` | `comfy nodes search -- <query>` / `comfy nodes show -- <name>` | no |
| `list_model_folders()`, `list_models(folder)` | `comfy models list-folders` / `list-folder -- <folder>` (`comfy model list` has no JSON output) | no |
| `run_workflow(workflow)` → `prompt_id` | writes the API-format JSON to `work/`, `comfy run --workflow <file>` (non-blocking; paid partner nodes are refused because `--allow-spend` is never passed) | ComfyUI queue |
| `job_status(prompt_id)` | `comfy jobs status <id>` — works without loading ComfyUI | no |
| `comfyui_status()` | manifest, release tags (`git ls-remote --tags --refs`), whether ComfyUI answers on its port — does not load it. `setup-comfyui.sh --check` is not run: it needs sudo | no |
| `fetch_outputs` | **deferred** until the `jobs status` output format is checked on the target | — |

Every comfy call: `comfy --json --skip-prompt --where local --workspace=<checkout> …`
with `COMFY_NO_WATCH=1`, `DO_NOT_TRACK=1`, stdin closed. comfy-cli ignores
`XDG_CONFIG_HOME`; its config follows `HOME`, so the fragment must set `HOME`.

Planned for later steps:

| Tool | Does | Changes state |
|---|---|---|
| `download_model(url, category, filename?, confirm)` → job id | see "Download limits" | model directory |
| `download_status(job)` | progress / result | no |
| `comfyui_update(ref, confirm)` → returns immediately | validates, starts `comfyui-update@<ref>` (C5) | yes |
| `comfyui_update_log(ref)` | journal of the update unit + post-update `--check` | no |
| `comfyui_rollback(confirm)` | update to the previous ref from `state/update-history` | yes |

Never exposed: `comfy install`, `comfy update *`, `comfy launch`/`stop`,
`comfy node install/update`, `comfy model remove`, any `--set-*-api-token`.

**Download limits** (defaults, all configurable via env):

- `url` host must be `huggingface.co`, `hf.co` or `civitai.com` (same hosts comfy-cli
  sends tokens to).
- `category` must be one of `checkpoints`, `clip_vision`, `controlnet`,
  `diffusion_models`, `embeddings`, `loras`, `text_encoders`, `upscale_models`, `vae`;
  the target is always `--relative-path models/<category>` — never a caller-supplied
  path.
- Size known before the download starts (HTTP `HEAD` / HF or CivitAI API) and below
  `COMFYUI_MCP_DOWNLOAD_MAX_GB` (default `50`); unknown size is refused.
- Free space after the download stays above `COMFYUI_MCP_DISK_RESERVE_GB`
  (default `100`).
- One download at a time; an existing file is never overwritten.
- `confirm: true` required.
- Tokens only via `HF_API_TOKEN` / `CIVITAI_API_TOKEN` from the `.env`.
- Files are created as `COMFYUI_USER` (the process already runs as that user).

### C3 — `comfyui-mcp` model, key and secrets (`setup-comfyui.sh`, `COMFYUI_MCP=true`)

Implemented in step 2b as **own files** next to the ComfyUI ones, so each stays
valid YAML and can be installed or removed on its own:

| File | Template | Content |
|---|---|---|
| `<config-dir>/51-comfyui-mcp.yaml` | `llama-swap-mcp-fragment.yaml` | `apiKeys: ["${env.COMFYUI_MCP_API_KEY}"]` (appended to the operator's keys) and model `comfyui-mcp`: `cmd` = `setpriv` prefix + `bin/comfyui-mcp --listen 127.0.0.1 --port ${PORT}`, `checkEndpoint: /health`, `unlisted: true`, `concurrencyLimit: 50` |
| `llama-swap.service.d/51-comfyui-mcp.conf` | `llama-swap-mcp-dropin.conf` | `EnvironmentFile=${COMFYUI_MCP_DIR}/.env` |
| `${COMFYUI_MCP_DIR}/bin/comfyui-mcp` (root, 755) | `comfyui-mcp-launch.sh` | exports `HOME`, `COMFY_BIN`, `COMFYUI_WORKSPACE`, `COMFY_LOCAL_URL`, `LLAMA_SWAP_URL`, manifest, repo URL, work dir; runs `python -m comfyui_mcp` |
| `${COMFYUI_MCP_DIR}/app/comfyui_mcp/` (root, 644) | `comfyui_mcp/` in the repo | server code and `requirements.txt` |
| `${COMFYUI_MCP_DIR}/.venv` (`COMFYUI_USER`) | — | pinned `mcp` and `comfy-cli` |
| `${COMFYUI_MCP_DIR}/.env` (mode 600) | — | `COMFYUI_MCP_API_KEY=sk-comfyui-mcp-<48 hex>`, generated once, read back on re-runs |

- No secret is written into a rendered file; the key reaches `llama-swap -validate`
  and `curl` through the environment / curl's stdin config, never a command line.
- **apiKeys are required.** Pre-flight refuses `COMFYUI_MCP=true` when `config.yaml`
  has no `apiKeys`: the fragment would otherwise switch on authentication for every
  client, and the MCP tools must never be reachable without a key.
- Every llama-swap child inherits the key from the drop-in; `comfyui-launch` unsets
  it before ComfyUI starts, so custom nodes do not get it from the environment.
  (Code running as `COMFYUI_USER` can still read the MCP process environment — same
  user.)
- **Validation covers switching off:** the ComfyUI fragment and the MCP fragment
  (or its absence) are validated together before anything in llama-swap changes. A
  matrix that still names `comfyui-mcp` after `COMFYUI_MCP=false` stops the run.
  `COMFYUI_SUPERVISOR=systemd` validates the config without both fragments before
  removing them (closes the gap noted in `docs/research/llama-swap-config-fragments.md`).
- A new drop-in, fragment or key restarts llama-swap once; changed server code or
  launcher only unloads a running `comfyui-mcp` (with the MCP key).
- `COMFYUI_MCP=false` removes fragment and drop-in; files in `COMFYUI_MCP_DIR` stay.

### C4 — Matrix membership (operator, `config.yaml`)

```yaml
matrix:
  vars:
    m: comfyui-mcp
    c: comfyui_auto
  evict_costs:
    m: 100
  sets:
    comfy: "c & m"
    llms:  "(<every LLM>) & m"
```

1. **`m` shares a set with `c`** — otherwise waking ComfyUI kills the MCP server
   mid-call.
2. **`m` is in every set, and every model is in a set** — otherwise connecting an
   MCP client evicts the LLM, and every LLM request kills the MCP server.
3. **Accepted limitation:** an LLM request selects `llms` (without `c`) and kills a
   running ComfyUI job; the MCP server reports the job as lost.

`setup-comfyui.sh --check` fails when `comfyui-mcp` is missing from a set or a model
is in no set.

### C5 — Update path (the only way the MCP server changes the installation)

- `comfyui-update@.service` (oneshot, root) runs `${COMFYUI_MCP_DIR}/bin/comfyui-update %i`.
- A **polkit rule** lets `COMFYUI_USER` run only verb `start` on units matching
  `^comfyui-update@v[0-9]+\.[0-9]+\.[0-9]+\.service$` (not sudoers: a `*` wildcard
  there also matches spaces and further unit names).
- `comfyui-update <ref>`:
  1. Re-validate `ref` (`^v\d+\.\d+\.\d+$`, present in `git ls-remote --tags`).
  2. Refuse while ComfyUI is loaded and its queue is not empty (`GET /queue`) or a
     download job runs.
  3. Append `from=<manifest comfyui_ref> to=<ref> at=<date>` to `state/update-history`.
  4. Write `COMFYUI_REF` into `machine-config.yml` (D4): line-targeted inside the
     `setup-comfyui:` block, `.bak` kept. The repo path is recorded by
     `setup-comfyui.sh` from its own location when it installs the helper.
  5. Run `tasks/setup-comfyui.sh` with the task's env from `machine-config.yml`
     (same `yq` expression as `run-setup.sh` `get_script_env`), `INTERACTIVE=false`,
     explicit `COMFYUI_USER` (config, else owner of `${COMFYUI_DIR}/ComfyUI`), and
     `COMFYUI_MCP_API_KEY` from the `.env` so the task can unload `comfyui_auto`.
  6. Run `tasks/setup-comfyui.sh --check`; exit non-zero if it fails.
- Detached from the MCP process: if the update restarts llama-swap or unloads
  `comfyui-mcp`, it continues; `comfyui_update_log` shows the outcome later.
- Rollback = same unit with the `from` of the last successful history entry.

## Implementation steps

Each step is tested in the VM suite (`tests/README.md`) before the next.

1. **C1** fixed port.
2. **C3 + C2 read-only:** model, key, secrets, enable/disable order; tools `nodes`,
   `discover`, `list_models`, `run_workflow`, `job_status`, `fetch_outputs`,
   `comfyui_status`.
3. **C4 check** in `--check`.
4. **C2 download** with its limits.
5. **C5** update and rollback.

## Acceptance criteria

1. `claude mcp add --transport http comfyui https://llm.manuelspoerer.de/upstream/comfyui-mcp/mcp --header "Authorization: Bearer <llama-swap key>"`
   lists the tools; without the header Caddy answers `401`, with a wrong key
   llama-swap answers `401`.
2. With an LLM loaded, connecting the MCP client does **not** unload the LLM.
3. With `comfyui_auto` unloaded, `run_workflow` loads ComfyUI, evicts the LLM, keeps
   `comfyui-mcp` running, and the job completes.
4. Requesting an LLM afterwards keeps `comfyui-mcp` running.
5. 20 concurrent MCP requests get no `429`.
6. The operator's two API keys keep working; the MCP key works for `/comfyui/`;
   `get_config` does not show the MCP key.
7. `download_model` stores a Hugging Face file in `models/<category>/` owned by
   `COMFYUI_USER`; it is refused for another host, an unknown category, a size above
   the limit or unknown, too little free space, an existing file, and without
   `confirm`.
8. `comfyui_update(ref=<newer tag>, confirm=true)` leaves `machine-config.yml` (with
   comments intact), the manifest and the running ComfyUI on the new tag; `--check`
   passes; torch still reports CUDA 13. A later `run-setup.sh apply` keeps that ref.
9. `comfyui_update` is refused for a non-tag ref, an unknown tag, while a job runs, and
   while a download runs.
10. `comfyui_rollback(confirm=true)` returns to the previous tag with `--check` passing.
11. `COMFYUI_USER` cannot start any other systemd unit.
12. `--check` fails when `comfyui-mcp` is missing from a matrix set.
13. `COMFYUI_MCP=false` with `m` still in the matrix stops before removing anything and
    names the entries; after removing them it cleans up and llama-swap loads.
14. Re-running `setup-comfyui.sh` converges without rotating the key.

## VERIFY ON TARGET

- Installed llama-swap release (top-level `matrix:`): solver behaviour as described,
  `/upstream` behaviour, `concurrencyLimit` default, `${env.…}` in config-dir files.
- Whether a `--watch-config` reload after a matrix edit unloads running models.
- polkit support for `action.lookup("unit")` / `("verb")` on
  `org.freedesktop.systemd1.manage-units`.
- Streamable HTTP through Cloudflare + Caddy + llama-swap: idle streams are cut after
  ~100 s — clients must reconnect cleanly.

## Out of scope

- The MCP server in `COMFYUI_SUPERVISOR=systemd` mode.
- Custom node management via MCP.
- Deleting models via MCP.
- Updating llama-swap or the MCP server itself via MCP.
- Changes to Caddy on the VPS.
