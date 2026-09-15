# llama-swap config fragments (`conf.d`)

**Date:** 2026-09-15

## What it is

llama-swap can read more than one config file. Next to the main `config.yaml` it
reads every `*.yml` / `*.yaml` file in a second directory and joins everything
into **one** config. This is the common "drop-in directory" pattern (like
`/etc/sudoers.d/` or systemd drop-ins).

- **llama-swap provides the feature:** the `-config-dir` flag, since v230
  (2026-06-25, PR #873).
- **This repo switches it on:** `setup-llama-swap.sh` passes
  `--config-dir ${LLAMA_SWAP_FRAGMENT_DIR}` (default `/srv/llama-swap/conf.d`),
  since commit `b939067` (2026-09-14).

## Why we use it

Every file has one owner:

| File | Owner |
|---|---|
| `config.yaml` | the operator and `sync_models` |
| `conf.d/50-comfyui.yaml` | `tasks/setup-comfyui.sh` (managed marker in the header) |

A task adds its models by writing its own file and removes them by deleting that
file. It never edits `config.yaml`. Before installing a file, the task checks the
joined result with `llama-swap -validate`.

## Rules to know

- Files are read in filename order. The number (`50-…`) only sets that order.
- **Nothing is overwritten.** Unlike systemd drop-ins, a later file does not win:
  - maps are joined,
  - the same model ID in two files is an error,
  - lists (e.g. `apiKeys`, `preload`) are appended,
  - the same setting with a different value is an error.
- So a fragment can **add** things (a model, a matrix var, a new set), but it
  cannot **change** something that is already in `config.yaml` (e.g. add a model
  to an existing matrix set).
- The config is validated after joining. `config.yaml` may refer to a model that
  is only defined in a fragment (e.g. in the matrix). But then the two files depend
  on each other: if the fragment is removed while the matrix still names its
  model, llama-swap no longer loads the config.
- An empty `conf.d` is fine. A missing `conf.d` stops llama-swap from starting.

Sources: llama-swap `internal/config/merge.go`, `internal/config/matrix.go`;
`.tickets/setup-comfyui-llama-swap.md` (section "Config fragments").

## Follow-ups

- **ColQwen should get the same integration.** `tasks/setup-colqwen.sh` only
  generates a standalone Docker Compose project (`restart: unless-stopped`, GPU,
  port 8100). llama-swap does not know it, so ColQwen can hold unified memory next
  to the llama-swap models. Idea: a `COLQWEN_SUPERVISOR=llama-swap` mode that
  writes `conf.d/50-colqwen.yaml`, like ComfyUI. To clarify first:
  - no `restart: unless-stopped` in that mode, or Docker restarts what llama-swap
    stopped;
  - model loading takes up to 600 s, but llama-swap's `healthCheckTimeout`
    (default 120 s) is global, not per model;
  - the llama-swap user needs Docker access (`cmd` / `cmdStop`);
  - how clients reach it: `/v1/embeddings` by model name (not verified that the
    API is OpenAI-compatible) or `/upstream/colqwen/…`;
  - matrix: as a small model it should be in most sets.
- ~~**Removing a fragment is not validated yet.**~~ Done with `COMFYUI_MCP`:
  `remove_llama_swap_integration` in `setup-comfyui.sh` now runs `llama-swap
  -validate` without its fragments first and stops, naming the models to take
  out of `config.yaml`, when the matrix still refers to them.
