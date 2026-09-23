# Behaviors — Model Auto-Configuration (Model Catalog Sync) — Python Implementation

> **Design basis:** Python rewrite (2026-08-27) of an old specification for shell script implementation
> The catalog format, model semantics, files touched, and exit codes are
> **unchanged**; the implementation moves from bash + `jq`/`yq` subprocesses to CPython 3
> (stdlib + PyYAML) for readability, maintainability, and future extensibility.
> **This spec supersedes the shell spec.** Deliberate Python-era behavior deltas are
> listed as Design Decisions 26–30 (llama-swap entry env scope, download subprocess env,
> execution context/permissions, opencode.jsonc handling, log routing).
>
> **Updated (2026-09-04), post-review:** Design Decisions 31–32 (default catalog is
> local-only with no real API keys; post-restart health poll), pinned default catalog
> contents (new *Default Catalog* section), schema example fix (remote models moved to
> their own upstream provider), disk-space warning in Behavior 2, sole-writer ownership
> rule. Download syntax (`hf://` URI form, `[dry-run]` output lines incl. the `N == 0`
> case) re-verified against `hf` 1.22.0 on the target host.
>
> Grounded in the actual on-disk state of `tasks/setup-llama-swap.sh`,
> `tasks/setup-pi.sh`, `tasks/setup-opencode.sh`,
> `/srv/llama-swap/config/config.yaml`, `~/.pi/agent/models.json`,
> `~/.config/opencode/opencode.json`, and the HuggingFace CLI (`hf` 1.22.0 — download
> behavior verified empirically on the target host).

## Overview

This feature adds a **declarative model catalog** (`models.yml`) and a **sync tool**
(`tasks/sync-models.py`, implemented as a Python package) that configure LLMs on an
already-provisioned inference server:

1. Download model weight files that are not already present (via the `hf` CLI).
2. Add missing model entries to the **llama-swap** configuration (strictly additive).
3. Wire every catalog model into the **coding agents'** model configuration files
   (**pi**, **opencode**, and future agents via pluggable adapters) — add missing entries,
   fix misconfigured fields.

The tool is **idempotent** and **strictly additive** with respect to state it does not
own: it never removes or rewrites entries that were not created from the catalog, and
re-running after a successful run is a no-op.

**Scope boundary:** the tool does **not** install llama-swap, pi, or opencode. Those are
assumed to be set up by `tasks/setup-llama-swap.sh`, `tasks/setup-pi.sh`, and
`tasks/setup-opencode.sh` respectively. It does not install `hf` (installed by
`tasks/setup-basics.sh`) and does not install Python 3 or PyYAML (assumed present;
checked in pre-flight with an actionable error).

**Ownership rule:** this tool is the **sole writer** of provider and model entries in the
agent config files. `setup-pi.sh` / `setup-opencode.sh` only install the agents
and must not write provider/model content themselves; "the agents are connected to
llama-swap" is achieved by running this tool (see Decision 31).

### Files Delivered

| File | Purpose |
|------|---------|
| `tasks/sync-models.py` | Executable entrypoint (new): `#!/usr/bin/env python3` shebang, committed with the executable bit; bootstraps the repo root onto `sys.path` and calls `sync_models.cli.main()` |
| `sync_models/__init__.py` | Package marker (new) |
| `sync_models/cli.py` | Argparse CLI (`--no-restart`, `--agents`, `--help`), run orchestration, exit codes (new) |
| `sync_models/catalog.py` | Catalog resolution, YAML load, schema validation — collects **all** violations (new) |
| `sync_models/expand.py` | `${VAR}` placeholder expansion: catalog env + process env, fixed-point (new) |
| `sync_models/download.py` | Download orchestration: `--dry-run` probe, output parsing, streaming execution (new) |
| `sync_models/llama_swap.py` | llama-swap `config.yaml` sync: additive merge, atomic write, restart (new) |
| `sync_models/atomicio.py` | Shared `atomic_write_text()`: temp file + parse validation + `os.replace` (new) |
| `sync_models/agents/__init__.py` | Adapter registry, agent auto-detection, `--agents` validation (new) |
| `sync_models/agents/base.py` | `AgentAdapter` interface + shared JSON merge/write helpers (new) |
| `sync_models/agents/pi.py` | Pi agent adapter: config path + `models.json` merge logic (new) |
| `sync_models/agents/opencode.py` | Opencode agent adapter: config path + `opencode.json` merge logic (new) |
| `sync_models/verify.py` | Post-run verification + per-component summary table (new) |
| `models.yml.default` | Committed default model catalog in repo root — **local models only, no real API keys** (Decision 31); contents pinned in *Default Catalog* (new). Also the **fallback catalog** when `models.yml` is absent (Catalog Resolution), so it is intentionally a real, runnable model set — a first run on a fresh machine downloads its local model(s) |
| `.gitignore` | Add `models.yml` (contains API keys) (edit) |
| `README.md` | Document catalog workflow (copy `.default` → `models.yml`, edit, run; the committed default catalog is a real, downloadable local model set) plus the two-stage story (fresh box: the local model works out of the box; remote providers with real keys are added to `models.yml` and the tool re-run) and the deprovisioning note (removing a model from the catalog does **not** remove its entries from agent/llama-swap configs — edit those manually) (edit) |
| `CONTEXT.md` | Add "model catalog" domain term (edit) |
| `skills/kwisatz-assistant/SKILL.md` | Mention `sync-models` in the task list (edit) |
| `AUTOMATIONS.md` | Add a `sync-models.py` entry under "AI & LLM Services" (edit) |
| `AGENTS.md` | Add the Python lint gate (`ruff`, fallback `python3 -m py_compile`) to the Linting section (edit) |
| `machine-config.yml.example` | Add `sync-models` with `enabled: false` and a comment that orchestrator dispatch of the `.py` entrypoint is a separate follow-up (edit) |

Generated/modified at runtime on the target host (not committed): `models.yml` (repo
root), `/srv/llama-swap/config/config.yaml` (additive), `~/.pi/agent/models.json`
(additive), `~/.config/opencode/opencode.json` (additive).

**Code layout constraints:** the `sync_models/` package is self-contained (no imports
from `lib/*.sh`, no shell helpers). Every external process is spawned via
`subprocess` with an explicit argument list; the catalog's `download:` commands are the
only ones executed through a shell (explicit `bash -c` subprocess, Decision 23 —
`shell=True` is never used). The package must be importable without
side effects so the pure logic (validation, expansion, merging) is unit-testable.

### Design Decisions

Numbered to match the shell spec where the decision is unchanged; new Python-specific
decisions are 21–32.

| # | Decision | Choice |
|---|----------|--------|
| 1 | Prerequisites | llama-swap, pi, opencode assumed already set up by existing `tasks/` scripts. Python 3 + PyYAML assumed present (pre-flight checked); `hf` installed by `tasks/setup-basics.sh` |
| 2 | Model types | Both **local** (gguf weights downloaded, served by llama-swap) and **remote** (external OpenAI-compatible provider) |
| 3 | Provider grouping | Several models can live under one provider/baseUrl; the catalog has a `providers:` section, each provider with `name`, `baseUrl`, `apiKey`, `models:` |
| 4 | Download mechanism | Always the `hf` CLI; per-model `download:` is a free-form **list of shell commands** (supports multi-file large models). Commands are executed by the tool via `bash -c` (Decision 23) |
| 5 | llama-swap serving command | **Raw `serve.cmd` fully owned by the user** in the catalog (no templating, no default generation) |
| 6 | Template variables | `env:` as `name`/`value` arrays, both **top-level** (inherited by all models) and **per-model** (add/override). Placeholders like `${HOME}`, `${MODEL_DIR}` expanded **at execution time** |
| 7 | Model data location | No dedicated `modelDataDir` key — controlled through `env` (e.g. `MODEL_DIR=${HOME}/.cache/huggingface/hub`, the default in `models.yml.default`) |
| 8 | Agent config mutation | **Merge/additive**: ensure provider exists, add missing models, leave pre-existing entries untouched |
| 9 | llama-swap mutation | **Merge/additive**: add missing model entries only; existing entries and all non-model sections (`macros`, `matrix`, `hooks`, `apiKeys`, global settings) are never touched |
| 10 | Download-once guarantee | `hf download ... --local-dir ${MODEL_DIR}/<repo>` mode: stable authorable paths + built-in idempotency via in-dir `.cache/huggingface/` metadata (default `--no-force-download`). In-dir metadata must be kept. The tool runs `--dry-run` first per command to report "already present" vs. "downloading N files (X)" |
| 11 | Agent model metadata | Explicit per-model `agent:` block; optional fields with defaults: `contextWindow: 200000`, `maxTokens: 16000`, `reasoning: true`, `input: [text]`; optional `thinkingLevelMap` |
| 12 | Model identity | One canonical `name` per model, used verbatim as llama-swap model key, agent model id, and display name. For `remote` models, `name` is the upstream model id, used as-is |
| 13 | Agent targeting | **Auto-detect** supported agents by config-file presence (missing agent → skipped with note) **plus optional override** to restrict the set. One **Python module per agent** in `sync_models/agents/` (`pi.py`, `opencode.py`); adding a future agent = adding one new module registered in `sync_models/agents/__init__.py` |
| 14 | Tool & catalog location | Entrypoint `tasks/sync-models.py` (executable). Catalog resolution: `MODELS_YML` env override → `<repo root>/models.yml` → `<repo root>/models.yml.default`. `models.yml` is gitignored (contains API keys); README instructs copying `.default` → `models.yml` to customize |
| 15 | llama-swap restart | **Only if the config actually changed**; `--no-restart` flag to skip. If the service is not running, the restart starts it |
| 16 | Missing llama-swap + local models | **Fail hard** with message: run `./tasks/setup-llama-swap.sh` first |
| 17 | Missing `hf` + downloads needed | **Fail hard** with message: run `./tasks/setup-basics.sh` first |
| 18 | llama-swap not running | Proceed: download, configure, restart (restart starts the service) |
| 19 | "Well configured" scope | Agent configs: add missing **and** fix managed fields that differ from the catalog. llama-swap: **add-only** — an existing model entry is never modified |
| 20 | Provider matching in agent configs | Existing provider blocks matched **by name** |
| 21 | Implementation language & dependencies | CPython 3, no features beyond Python 3.10 (target host: Ubuntu 24.04, Python 3.12). Dependencies: **stdlib + PyYAML only**. No `jq`/`yq` subprocesses, no other third-party imports. All JSON/YAML parsing, validation, and serialization is in-process |
| 22 | Code layout | `sync_models/` package at the repo root; `tasks/sync-models.py` is a thin executable entrypoint (~20 lines). The package never reads `sys.stdin` and never prompts (non-interactive project convention) |
| 23 | Download command execution | Each `download:` command runs via `subprocess.run(["bash", "-c", cmd])`, inheriting the tool's process environment (this is how plain env vars like `HF_TOKEN` stay available without catalog declaration). `--dry-run` is appended to the command string **after** placeholder expansion. The real download streams its output (stdout+stderr merged, line-buffered) to the tool's stdout; the dry-run probe captures output for parsing |
| 24 | Atomic config writes | One shared helper (`sync_models/atomicio.py`): serialize to a temp file **in the target directory** → re-parse the temp file (`yaml.safe_load` / `json.loads`) → `os.replace` over the original. On parse failure: temp file removed, original untouched, run fails (exit 2). A file is only rewritten when the merged data actually differs from the parsed on-disk data (no-op runs touch no file) |
| 25 | Static analysis | Python files are linted with `ruff` (minimum fallback gate: `python3 -m py_compile` on every new/changed `.py` file). The YAML catalog keeps `yamllint` as in the shell spec. Replaces the shell spec's `shellcheck` gate |
| 26 | llama-swap entry env scope | Only the model's **per-model** `env` (values placeholder-expanded) is written into the new llama-swap model entry. Top-level `env` is expansion-only and is **never** written to `config.yaml` (it is plumbing for `${...}` expansion; writing it would leak top-level declarations — potentially secrets — into the shared config and could clobber the serve process environment with global variables such as `PATH`). A serve-time variable needed by every local model is expressed by repeating it in each model's `env`. *Deliberate deviation from the shell spec's "effective env" rule* |
| 27 | Download subprocess environment | Each `download:` command (dry-run probe and real run) inherits the tool's process environment **plus** the model's effective env (top-level merged with per-model, expanded; catalog values win on conflict). Catalog-declared variables (e.g. `HF_TOKEN` for gated models) are thus available to `hf` without being spelled inline in the command |
| 28 | Execution context & permissions | The tool runs as the user whose agent configs should be updated (its `$HOME`), and that user must have **write access** to `LLAMA_SWAP_CONFIG` (checked in pre-flight; exit 1 with an actionable message otherwise — e.g. fix ownership/permissions or run as a user with write access). The tool's only privileged operation is the `sudo systemctl restart llama-swap` in Behavior 3 step 5; the config write itself is a plain user-space `os.replace` |
| 29 | Opencode config file handling | The opencode adapter manages `~/.config/opencode/opencode.json` only (or the path in `OPENCODE_CONFIG`, which is **opencode's own** env var for a custom config path — honored with the same semantics). If `opencode.json` is missing but a sibling `opencode.jsonc` exists, the agent is **skipped with a warning** (JSONC is not managed; creating a parallel `opencode.json` next to the user's `opencode.jsonc` would produce an ambiguous merged config) |
| 30 | Log routing & format | Informational logs, the summary, and `WARNING:`/`ERROR:`-prefixed lines all go to **stdout**; error messages that accompany exit 1/2 additionally go to **stderr** (project convention: `error()` in `lib/helpers.sh` writes to stderr). **No ANSI colors** — deliberate deviation from the project's colourful-output convention: the tool's output is meant to be machine-readable and pipe-safe |
| 31 | Default catalog content | `models.yml.default` contains **local models only** (served by llama-swap) — no remote providers, no real API keys. The local provider uses the literal `apiKey: not-required` (llama-swap has no auth by default; the value is written into agent provider blocks so agents that require the field work out of the box). Remote providers (with real keys) are opt-in via the gitignored `models.yml`; when the user adds an `apiKey` there, Behavior 4 updates the agent provider blocks on the next run (convergence) |
| 32 | Post-restart health poll | After a successful llama-swap restart (Behavior 3 step 5), the tool polls `http://localhost:<port>/health` (stdlib `urllib`, 2 s interval, 5 s per-request timeout) until HTTP 200, bounded by `LLAMA_SWAP_HEALTH_TIMEOUT` seconds (default **500** — same name and default as `setup-llama-swap.sh`). `<port>` = the top-level `port` key of `LLAMA_SWAP_CONFIG` if present, else `9292`. On timeout: `ERROR:` with a hint to run `sudo systemctl status llama-swap`; the run ends with exit 2 (the config was written). No poll when the config was unchanged, `--no-restart` was used, or the catalog has no local models |

### CLI & Environment

```
./tasks/sync-models.py [--no-restart] [--agents pi,opencode] [--help]
```

Parsed with `argparse`.

| Flag | Description |
|------|-------------|
| `--no-restart` | Do not restart llama-swap even if its config changed |
| `--agents <list>` | Restrict agent sync to a comma-separated list of supported agents (default: auto-detect all present) |
| `--help` | Usage; exit 0, no side effects |

| Variable | Default | Description |
|----------|---------|-------------|
| `MODELS_YML` | *(unset)* | Explicit path to the catalog. If set, it is used and **must exist** |
| `LLAMA_SWAP_CONFIG` | `/srv/llama-swap/config/config.yaml` | llama-swap config path (matches `setup-llama-swap.sh` default `LLAMA_SWAP_DIR`) |
| `PI_MODELS_JSON` | `$HOME/.pi/agent/models.json` | Pi model config path |
| `OPENCODE_CONFIG` | `$HOME/.config/opencode/opencode.json` | Opencode config path. Same name and semantics as opencode's own `OPENCODE_CONFIG` env var (custom config path): if set, the tool targets that file; if set but the file is missing → agent skipped with a note (Decision 29) |
| `LLAMA_SWAP_HEALTH_TIMEOUT` | `500` | Post-restart health poll timeout in seconds (Decision 32); same name and default as `setup-llama-swap.sh` |

All are read via `os.environ.get` at startup.

### Catalog Resolution

1. If `MODELS_YML` is set → use it; **error** if the file does not exist.
2. Else if `<repo root>/models.yml` exists → use it.
3. Else use `<repo root>/models.yml.default`.

If none of the three resolves (no `MODELS_YML`, no `models.yml`, no
`models.yml.default`): exit 1 with a message listing the paths tried.

`<repo root>` = the parent directory of `tasks/`, computed at startup from the
entrypoint's own path (`Path(__file__).resolve()` of `tasks/sync-models.py`).
The chosen file is logged on start.

`models.yml.default` is committed and must contain **no real secrets** — local models
only, no remote providers, and no `apiKey` values beyond the literal `not-required`
(Decision 31). `models.yml` is added to `.gitignore`.

---

## Model Catalog Schema

Unchanged from the shell spec — the catalog format is intentionally identical so that
existing `models.yml` files work with both implementations.

```yaml
# Top-level env: inherited by all models. Placeholders in env values are
# expanded (env vars may reference earlier-defined env vars and shell env).
env:
  - name: MODEL_DIR
    value: ${HOME}/.cache/huggingface/hub

providers:
  # ── Local provider: the llama-swap proxy. The committed models.yml.default
  #    contains only this provider (Decision 31) ──
  - name: evo                       # provider name; used for matching in agent configs
    baseUrl: http://localhost:9292/v1
    apiKey: not-required            # optional; literal for auth-less llama-swap
    models:
      # ── Local model: weights downloaded, served by llama-swap ──
      - name: qwen3.8-27b           # canonical id: llama-swap key + agent model id
        type: local
        env:                        # optional; adds/overrides top-level env for this model
          - name: CUDA_VISIBLE_DEVICES
            value: "0"
        download:                   # required for local; list of shell commands
          - "hf download hf://unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf --local-dir ${MODEL_DIR}/unsloth/Qwen3.8-27B-GGUF"
        serve:
          cmd: |                    # required for local; raw llama-swap cmd, user-owned
            ${llama-server-bin}
            --port ${PORT}
            -m ${MODEL_DIR}/unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf
            --ctx-size 128000
            --jinja
        agent:                      # optional; all fields optional (defaults apply)
          contextWindow: 262144     # default: 200000
          maxTokens: 32000          # default: 16000
          reasoning: true           # default: true
          input: [text, image]      # default: [text]
          thinkingLevelMap:         # optional
            minimal: null
            low: low
            medium: medium
            high: null
            xhigh: xhigh
            max: null

  # ── Remote provider: external OpenAI-compatible upstream. Opt-in via
  #    models.yml with a real apiKey (Decision 31). A remote model must live
  #    under a provider whose baseUrl points at that upstream (never under
  #    the llama-swap provider) ──
  - name: openrouter
    baseUrl: https://openrouter.ai/api/v1
    apiKey: sk-PLACEHOLDER          # illustrative; triggers the placeholder warning
    models:
      # ── Remote model: no download, no serve; name = upstream model id ──
      - name: meta-llama/llama-3.1-8b-instruct
        type: remote
        agent:
          contextWindow: 131072
```

> The example is illustrative of the full schema. The committed
> `models.yml.default` contains only the `evo` provider and its local model
> (see *Default Catalog* below, Decision 31).

### Schema Rules

- `env` (top-level and per-model): list of `{name, value}`. Names must be valid shell-style
  identifiers and must not repeat within one `env` list (violation). Values must be YAML
  scalars (non-string scalars such as `0` are coerced to strings). **Reserved names
  rejected:** `PORT`, `MODEL_ID`, `PID` (llama-swap reserved macros) — a reserved name
  defined in catalog env would be **expanded by the tool at write time**, e.g. replacing
  `${PORT}` in `serve.cmd` with a fixed value and bypassing llama-swap's per-model port
  assignment. For `type: local` models, the model's **per-model** `env` (values
  placeholder-expanded) is written into the new llama-swap entry's `env:` list (Behavior 3,
  Decision 26).
- The top-level `providers` list must be present and non-empty.
- `providers[]`: `name` (non-empty, **unique across the catalog** — agent configs match
  providers by name), `baseUrl` (valid `http`/`https` URL with non-empty host), `apiKey`
  (optional; if absent, agent provider blocks are created without `apiKey` and existing
  `apiKey` values are never cleared — see Behavior 4), `models` (non-empty list).
- `models[]`: `name` (non-empty; charset `[A-Za-z0-9._/-]` — it becomes a llama-swap key and a
  JSON model id), `type` (`local` | `remote`).
- `type: local` requires non-empty `download` (list of strings) and non-empty `serve.cmd`.
  `download`/`serve` must **not** be present for `type: remote`.
- **Uniqueness:** `name` must be unique **across all local models** (they share the llama-swap
  `models:` namespace). The same `name` may repeat across different providers and remote models
  (agent configs allow the same model id under multiple providers).
- `agent` fields: `contextWindow` (positive int), `maxTokens` (positive int),
  `reasoning` (bool), `input` (non-empty list of `text`/`image`), `thinkingLevelMap`
  (map of thinking level → level-or-null; keys are free-form strings).

Schema validation collects **all** violations and reports them together (exit 1), not just
the first.

### Placeholder Expansion

Applied to `download` commands and `serve.cmd`, implemented in `sync_models/expand.py`:

1. Catalog env vars (top-level, in listed order, then per-model) are available.
2. A variable is substituted **only if** it is defined in the catalog env or in the current
   process environment (`os.environ`) (this is how `${HOME}` works without declaring it).
3. Anything else — llama-swap macros such as `${PORT}`, `${MODEL_ID}`, `${llama-server-bin}`,
   `${models-dir}` — is left **untouched** for llama-swap to expand at serve time.
4. Env values may reference earlier-defined env vars and process env; expansion runs to a
   fixed point (bounded passes, max 10). Non-converging (circular) references are detected
   **in pre-flight** (exit 1, naming the involved variables) — all env values are known
   before any mutation.
5. `download` commands are executed in a shell (`bash -c`), so plain process environment
   (e.g. `HF_TOKEN` for gated models) is available without catalog declaration.
6. For `type: local` models, the effective env (top-level merged with per-model, expanded)
   is additionally exported into the download subprocess environment, overriding the
   process env on conflict (Decision 27).

Matching is on the shell syntax `${NAME}` where `NAME` is `[A-Za-z_][A-Za-z0-9_]*`; any other
`${...}` form (e.g. llama-swap macros with non-identifier names) is never matched.

### Default Catalog (`models.yml.default`)

Contents pinned (verified 2026-09-04 against `hf` 1.22.0: repository and file exist;
`hf://` URI form, `--local-dir` mode, and the `[dry-run]` output lines — including the
`N == 0` already-present case — verified on the target host):

```yaml
---
# Committed default model catalog (local models only — Decision 31).
# Customize by copying to models.yml (gitignored) and editing:
#   cp models.yml.default models.yml
# Then (re-)run:  ./tasks/sync-models.py

env:
  - name: MODEL_DIR
    value: ${HOME}/.cache/huggingface/hub

providers:
  - name: evo
    baseUrl: http://localhost:9292/v1
    apiKey: not-required
    models:
      - name: qwen3.8-27b
        type: local
        # Folded scalar: the command value is the single line
        #   hf download hf://unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf
        #   --local-dir ${MODEL_DIR}/unsloth/Qwen3.8-27B-GGUF
        # (wrapped here only to keep lines <= 80 chars for yamllint)
        download:
          - >-
            hf download hf://unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf
            --local-dir ${MODEL_DIR}/unsloth/Qwen3.8-27B-GGUF
        serve:
          # ${llama-server-bin} is a llama-swap macro defined in the config
          # generated by setup-llama-swap.sh (/usr/local/bin/llama-server).
          cmd: |
            ${llama-server-bin}
            --port ${PORT}
            -m ${MODEL_DIR}/unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf
            --ctx-size 128000
            --jinja
        agent:
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

Notes:

- Single-file model (16.5 GB, `Q4_K_M`) — the default exercises no multi-file handling.
- `input: [text, image]` — the repository ships an `mmproj` vision projector.
- No per-model `env` on the model → nothing extra is written into the llama-swap entry
  (Decision 26).
- Remote providers and real API keys are added by the user in `models.yml` (two-stage
  flow, README; Decision 31).

---

## Behaviors

### Behavior 1: Pre-flight Checks

**When:** before any mutation, on every run.

| Check | On failure |
|-------|-----------|
| PyYAML importable (`import yaml`) | Exit 1: "PyYAML is not installed. Install it (e.g. `sudo apt install python3-yaml`) and re-run." |
| Catalog file resolves (see Catalog Resolution) | Exit 1, clear message (`MODELS_YML` set but missing → explicit "file not found" with the path) |
| Catalog parses as valid YAML (`yaml.safe_load`) | Exit 1, print the parse error |
| Schema rules valid (see Schema Rules) | Exit 1, print **all** schema violations (not just the first) |
| Catalog contains `local` models **and** `LLAMA_SWAP_CONFIG` missing | Exit 1: "llama-swap is not set up. Run `./tasks/setup-llama-swap.sh` first." |
| Catalog contains `local` models **and** `LLAMA_SWAP_CONFIG` does not parse as YAML | Exit 1: existing config is corrupt; no mutation attempted |
| Catalog contains `local` models **and** `LLAMA_SWAP_CONFIG` (or its `models:` section, if present) is not a YAML mapping | Exit 1: unexpected config structure; no mutation attempted |
| Catalog contains `local` models **and** `LLAMA_SWAP_CONFIG` or its directory is not writable by the invoking user | Exit 1: config not writable — fix ownership/permissions or run as a user with write access (Decision 28); no download, no mutation |
| Catalog env expansion does not converge (circular reference) | Exit 1: name the involved variables; no mutation attempted |
| Catalog has `download:` commands **and** `hf` not on PATH (`shutil.which("hf")`) | Exit 1: "hf CLI is not installed. Run `./tasks/setup-basics.sh` first." |
| Agent config file missing (per adapter) | **Skip** that agent with a note (not an error) |

The shell spec's `jq`/`yq` PATH check is **removed** — the tool has no `jq`/`yq`
dependency (Decision 21).

Remote-only catalogs run fine on a machine without llama-swap.

### Behavior 2: Download Model Weights

**When:** after pre-flight, for each `type: local` model, in document order (top to
bottom through `providers[]` and each provider's `models[]`).

For each command in the model's `download` list:

1. Run the command with ` --dry-run` appended (after placeholder expansion), via
   `bash -c`, capturing merged stdout+stderr.
2. Parse the line `[dry-run] Will download N files (out of M) totalling SIZE.` to obtain the
   file count `N`. If the line is present and `N == 0`, log `already present, skipping` and
   do not run the real download (dry-run exits 0 in that case).
3. Otherwise (N > 0, the line cannot be parsed, or the dry-run exits nonzero) → log
   `downloading <N> files (<size>)` (or `downloading (dry-run output unparseable)` when
   N/size are unknown) and run the real command via `bash -c`, streaming its merged output
   line-buffered to the tool's stdout.
   (Conservative: never skip a download on ambiguity.)
4. A failing command aborts the model's download with an error (exit 2 at the end — see
   "Failure Handling"); remaining models are still attempted.

Notes:

- Both the dry-run probe and the real run execute with the process environment **plus**
  the model's effective env (Decision 27), so catalog-declared variables are visible to
  `hf` without being spelled inline in the command.
- The ` --dry-run` suffix is only meaningful when a list entry is a **single** `hf`
  command. A compound entry (`cmd1 && cmd2`) receives the suffix on its last element, so
  the probe says nothing about the `hf` part; the conservative fallback then always runs
  the real command (correct, but the "already present" fast path is lost for that entry).
  `models.yml.default` keeps one `hf download` command per list entry.

Guarantees:

- **Download-once** is provided by the `hf` CLI in `--local-dir` mode: the in-dir
  `.cache/huggingface/` metadata ledger + default `--no-force-download` prevent re-downloads.
  The tool never deletes this metadata.
- Interrupted/partial files are re-fetched/resumed by `hf` on the next run.
- The canonical download form (documented in `models.yml.default`) is
  `hf download <hf-uri> [files...] --local-dir ${MODEL_DIR}/<repo>`; per-repo subdirectories
  are recommended to avoid filename collisions across repos in a shared `MODEL_DIR`.
- **Disk-space warning:** when the dry-run line yields a total size, the tool compares it
  against the free space of the file system that will receive the download
  (`shutil.disk_usage` at the deepest existing ancestor of the command's `--local-dir`
  path; check silently skipped when the command has no `--local-dir`). If free space is
  below the total size: log `WARNING: not enough free space for <model> (need ~<SIZE>,
  have <FREE>)` and continue anyway — informational only, never a failure.

### Behavior 3: llama-swap Configuration Sync

**When:** after downloads, if the catalog has local models.

1. Read `LLAMA_SWAP_CONFIG` (`/srv/llama-swap/config/config.yaml` default) with
   `yaml.safe_load` into a dict.
2. For each local model (in document order, as in Behavior 2):
   - If the model key (= `name`) **does not exist** under `models:` → add the entry:
     key = `name`, `cmd` = the expanded `serve.cmd`, and — if the model's
     **per-model** `env` (values placeholder-expanded) is non-empty — `env:` = that list
     in `NAME=value` form. Top-level `env` is expansion-only and is **not** written
     (Decision 26).
   - If the key **exists** → leave it **completely untouched**; log `already present, unchanged`.
     (Decision 19: the user hand-tunes serving commands; the tool never modifies them.)

   Local models whose download **failed** still get an entry — the config is declarative
   and mirrors the catalog. The failed download is reported in the summary and the run
   ends with exit 2 (the model simply cannot be served until the download succeeds).
3. Never touch: `macros`, `matrix`, `hooks`, `apiKeys`, `peers`, and all top-level global
   settings — in practice the tool only ever writes the `models:` mapping.
4. If (and only if) entries were added: serialize with `yaml.safe_dump(sort_keys=False)`,
   write via the atomic-write helper (Decision 24: temp file → `yaml.safe_load` the temp
   file → `os.replace`). If temp-file validation fails, the temp file is removed, the
   original was never touched, and the run fails (exit 2).

   **Important note:** a PyYAML round-trip rewrites the *entire* YAML document, so comments
   and manual reformatting are **not preserved** when the file is rewritten. The tool MUST
   log a warning the first time it modifies `config.yaml`.
5. **Restart:** if the config file changed → `subprocess.run(["sudo", "systemctl",
   "restart", "llama-swap"])` (this also starts the service if it was stopped). Log the
   restart. If unchanged → no restart. `--no-restart` suppresses the restart (and prints
   the manual command `sudo systemctl restart llama-swap`). If the restart command fails
   (nonzero exit, e.g. no sudo rights): log an `ERROR:` with the manual command and the
   run ends with exit 2 (the config was written; the service state is unknown).

   After a successful restart the tool performs the post-restart health poll
   (Decision 32) and logs the outcome (`llama-swap healthy` / timeout `ERROR:` with the
   `sudo systemctl status llama-swap` hint); on timeout the run ends with exit 2 as for
   a restart failure.

A run that adds nothing does not rewrite `config.yaml` at all (byte-identical guarantee).

**Execution context (Decision 28):** the tool must be run as the user whose agent configs
should be updated, and that user must have write access to `LLAMA_SWAP_CONFIG`
(pre-flight, exit 1 otherwise). The config write is a plain user-space `os.replace`;
`sudo` is used only for the restart above.

### Behavior 4: Agent Configuration Sync

**When:** after llama-swap sync, for each **selected** agent (auto-detected by config-file
presence, optionally restricted by `--agents`).

Each agent is an adapter module (`sync_models/agents/<name>.py`) implementing the
`AgentAdapter` interface from `sync_models/agents/base.py`:

- the config file path (from `PI_MODELS_JSON` / `OPENCODE_CONFIG` env with the documented
  defaults),
- `detected()`: config file exists,
- `sync(providers, ctx)`: the in-memory merge for its specific JSON structure; performs the
  write (only when the merged data differs) and returns the per-model results.

The registry in `sync_models/agents/__init__.py` maps agent name → adapter class and is the
single source of truth for "supported agents".

`--agents` values are validated **after** argparse parsing: an unsupported name → exit 1
with a message listing the supported agents and the offending names (custom message, not
argparse's default exit 2). A supported agent whose config is missing is skipped with a
`WARNING:` and marked `skipped (not detected)` in the summary — an explicit request does
not error (consistent with auto-detection).

For each selected agent:

0. **Read & parse guard:** load the existing config with `json.loads` and require the
   result to be a JSON **object**; also require the file to be **writable** by the
   invoking user. If the file exists but fails any check → **skip that agent with an
   error** (its state is unknown or not writable; it is never overwritten), mark it
   `failed` in the summary; other agents continue; the run ends with exit 2.
1. **Provider block:**
   - If a provider with the same **name** exists → keep it. If its `baseUrl` differs from the
     catalog → update it and warn. `apiKey` is updated only if the catalog provides one.
   - If no such provider exists → create it with `name`/`baseUrl`, `apiKey` **only if the
     catalog provides one**, and an empty model list. A catalog without `apiKey` never
     clears or overwrites an existing `apiKey`.

   **WARNING:** If any catalog `apiKey` value looks like a placeholder (contains the
   substring `PLACEHOLDER`, e.g. `sk-PLACEHOLDER`), log a warning before writing it to any
   agent config; the placeholder is still written (user responsibility to replace it in
   `models.yml`).
2. **Models** (for the provider's catalog models), using the `agent:` metadata with defaults
   (Decision 11):
   - Model id (= catalog `name`) **missing** in the provider → add the full entry with
     defaults applied; log `added`.
   - Model id **present** → compare the **managed fields** (`name`, `contextWindow`,
     `maxTokens`, `reasoning`, `input`, `thinkingLevelMap`) with the catalog; update any that
     differ and log `updated <fields>`; untouched fields of the existing entry are preserved
     (Decision 19). Unmanaged fields (e.g. `cost`) are never written by the tool.
3. Models/providers in the agent config that are **not** in the catalog are never removed or
   modified (Decision 8).
4. After merging: if the data changed → serialize with `json.dumps(data, indent=2)` plus a
   trailing newline and write via the atomic-write helper (Decision 24: temp file →
   `json.loads` the temp file → `os.replace`); on validation failure the original is never
   touched and the run fails (exit 2). If unchanged → no write, no temp file.

**Adapters delivered:**
- `sync_models/agents/pi.py` — `~/.pi/agent/models.json`.
  - Provider block: `providers.<name>` with `baseUrl`, `api: "openai-completions"`
    (written when the provider is created), `apiKey` (only if the catalog provides one),
    `models: []`. Existing provider blocks: only `baseUrl`/`apiKey` managed (Behavior 4).
  - Model entry (list item): `id` = catalog `name`, `name`, `reasoning`, `input`,
    `contextWindow`, `maxTokens`, optional `thinkingLevelMap` (written as-is, nulls
    preserved). `cost` is unmanaged: omitted on new entries, never modified on existing.
- `sync_models/agents/opencode.py` — `~/.config/opencode/opencode.json` (or the
  `OPENCODE_CONFIG` override). Reference: opencode custom-provider config
  (opencode.ai/docs/providers, "Custom provider"; schema: opencode.ai/config.json →
  `ProviderConfig`). **`opencode.json` only (Decision 29):** if `opencode.json` is missing
  but a sibling `opencode.jsonc` exists, skip the agent with a `WARNING:` (opencode
  supports both filenames; creating a parallel `opencode.json` next to the user's
  `opencode.jsonc` would produce an ambiguous merged config).
  - Provider block: `provider.<name>` with `name`, `npm: "@ai-sdk/openai-compatible"`
    (written when the provider is created), `options.baseURL` = catalog `baseUrl`,
    `options.apiKey` (only if the catalog provides one), `models: {}`.
  - Model entry: object keyed by catalog `name` under `provider.<name>.models`.
    Managed field mapping:

  | Catalog | opencode | Notes |
  |---------|----------|-------|
  | `name` | `name` | |
  | `contextWindow` | `limit.context` | `limit` requires both fields, both always written |
  | `maxTokens` | `limit.output` | |
  | `reasoning` | `reasoning` | |
  | `input` | `modalities.input` | plus `attachment` = `true` iff `input` contains `image` |
  | `thinkingLevelMap` | — | no opencode equivalent; **not written** (model objects reject unknown fields) |

    Creation-time defaults for new entries (written once, never managed afterwards):
    `tool_call: true`, `modalities.output: ["text"]`. Existing entries: managed fields
    updated if different; all other fields (`tool_call`, `modalities.output`, `cost`,
    …) never touched.

### Behavior 5: Verification & Summary

**When:** at the end of every run, before exiting.

1. **Verify** (re-read from disk with `yaml.safe_load` / `json.loads`):
   - Every local model key exists in `LLAMA_SWAP_CONFIG` under `models:`.
   - For every synced agent: every catalog provider (by name) exists, and every catalog model
     id exists under it.

   Verification checks **config state only** — it does not check weight-file presence. A
   failed download leaves its config entry in place (declarative, Behavior 3) and surfaces
   as `failed` in the downloads summary.
2. **Summary** table per component (llama-swap, each agent, downloads):
   `added` / `updated` / `already present` / `skipped` / `failed` counts with model names.
3. Exit code: `0` all good (including pure no-op), `1` pre-flight failure,
   `2` partial/complete failure during mutation or verification (`sys.exit`).

Informational logs, warnings, and the summary go to stdout; error messages accompanying
exit 1/2 go to **stderr** as well (Decision 30; matches `error()` in `lib/helpers.sh`).
Warnings are prefixed `WARNING:`, errors `ERROR:`. No ANSI colors (deliberate deviation
from the project's colourful-output convention — output is machine-readable and
pipe-safe), no prompts, no `stdin` reads.

### Failure Handling

- Pre-flight failures exit immediately (1) with an actionable message (Decision 16/17).
- A download failure does not stop other models' downloads, but the run ends with exit 2 and
  the summary reports the failure.
- Mutation failures are **independent per component**: a failed component (a llama-swap
  write failure, an agent write failure) is marked `failed` in the summary; the other
  components still run to completion (their files are independent); the run ends with
  exit 2.
- A llama-swap restart failure **or a post-restart health-poll timeout** (Decision 32;
  config was written) is not fatal to the other components: manual
  `sudo systemctl restart llama-swap` and `sudo systemctl status llama-swap` hints
  printed, run ends with exit 2 (Behavior 3 step 5).
- Pre-existing unparseable / non-object / non-writable configs: llama-swap `config.yaml`
  → pre-flight exit 1 (Behavior 1); an agent config → that agent skipped with an error,
  exit 2 (Behavior 4 step 0).
- Config writes are all-or-nothing per file: temp-write + parse validation + `os.replace`
  (Decision 24) — on failure the original is never touched.
- The tool is non-interactive (project convention): no prompts, ever.

### Idempotency

Running `sync-models.py` twice in a row with an unchanged catalog:

- Downloads: every `--dry-run` reports 0 files → nothing downloaded.
- llama-swap: no new keys → merged data equals on-disk data → file **not rewritten** →
  **no service restart** → no health poll.
- Agents: all providers/models present with matching managed fields → files not rewritten.
- Exit 0, summary shows all "already present".

### Out of Scope

- Installing/updating llama-swap, pi, opencode, or the `hf` CLI (existing tasks).
- Installing Python 3, PyYAML, or `ruff`.
- Orchestrator (`run-setup.sh`) dispatch of the `.py` entrypoint — `run-setup.sh` currently
  maps task names to `tasks/<name>.sh`; adapting it (or providing a wrapper) is a separate
  follow-up and explicitly out of focus for this spec.
- Managing llama-swap `matrix:`/`hooks:`/`apiKeys:` or any global llama-swap settings.
- Removing models from any config (no deprovisioning).
- Comment-preserving YAML editing of `config.yaml` (e.g. `ruamel.yaml`) — the first-modification
  warning is the mitigation.
- Managing `opencode.jsonc` (JSONC) files — the opencode adapter manages `opencode.json`
  only and skips with a warning when only the `.jsonc` exists (Decision 29).
- vLLM/LM-Studio serving paths for local models (the user writes the raw `serve.cmd`, so any
  backend is possible, but no first-class support/templating).
- Synchronizing the catalog *from* the machine back to the YAML (one-way only).
- Automated test coverage (see `tests.md` — manual scenarios; automated tests deferred per
  project test strategy).
