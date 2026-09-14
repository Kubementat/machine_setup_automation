"""Argparse CLI + run orchestration + exit codes.

Pipeline: parse args → validate --agents (custom, exit 1) → read env →
pre-flight (Behavior 1) → placeholder warning → downloads (Behavior 2) →
llama-swap sync (Behavior 3) → agent sync (Behavior 4) → verification +
summary (Behavior 5) → exit 0 (all good, incl. no-op) / 2 (any component
failed or verification failed).
"""

from __future__ import annotations

import argparse
import os
import shutil
from pathlib import Path

from sync_models import PreflightError, error, info, step, warning
from sync_models.agents import select_agents, validate_agents_flag
from sync_models.catalog import (
    Catalog,
    load_catalog,
    resolve_catalog_path,
    validate_catalog,
)
from sync_models.download import download_model
from sync_models.expand import expand_env_entries
from sync_models.llama_swap import preflight as llama_preflight
from sync_models.llama_swap import sync as llama_sync
from sync_models.verify import ComponentResult, print_summary, verify

DEFAULT_LLAMA_SWAP_CONFIG = "/srv/llama-swap/config/config.yaml"
DEFAULT_HEALTH_TIMEOUT = 500

_ENV_HELP = """\
environment variables:
  MODELS_YML                  explicit catalog path (must exist if set);
                              default: <repo>/models.yml, then models.yml.default
  LLAMA_SWAP_CONFIG           default: /srv/llama-swap/config/config.yaml
  PI_MODELS_JSON              default: $HOME/.pi/agent/models.json
  OPENCODE_CONFIG             default: $HOME/.config/opencode/opencode.json
  LLAMA_SWAP_HEALTH_TIMEOUT   post-restart health poll timeout, seconds
                              (default: 500)

exit codes: 0 = success (incl. no-op), 1 = pre-flight failure,
2 = mutation/verification failure"""


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="sync-models.py",
        description=(
            "Sync the declarative model catalog: download local model weights "
            "(hf CLI), additively merge llama-swap model entries, and wire "
            "catalog providers/models into the coding agents' model configs."
        ),
        epilog=_ENV_HELP,
    )
    parser.add_argument(
        "--no-restart",
        action="store_true",
        help="do not restart llama-swap even if its config changed",
    )
    parser.add_argument(
        "--agents",
        metavar="LIST",
        default=None,
        help="restrict agent sync to a comma-separated list of supported "
        "agents (default: auto-detect all present)",
    )
    parser.add_argument(
        "--agents-only",
        action="store_true",
        help="only configure agent model configs; skip model downloads and "
        "llama-swap sync",
    )
    return parser.parse_args(argv)


def parse_health_timeout(raw: str | None) -> int:
    """LLAMA_SWAP_HEALTH_TIMEOUT; invalid value → warning + default 500."""
    if raw is None:
        return DEFAULT_HEALTH_TIMEOUT
    try:
        return int(raw)
    except ValueError:
        warning(
            f"invalid LLAMA_SWAP_HEALTH_TIMEOUT '{raw}' — using default {DEFAULT_HEALTH_TIMEOUT}"
        )
        return DEFAULT_HEALTH_TIMEOUT


def fail1(exc: PreflightError) -> int:
    """Print every message line as ERROR (stdout + stderr); return 1."""
    for message in exc.messages:
        error(message)
    return 1


def main(argv: list[str] | None = None, *, repo_root: Path | None = None) -> int:
    args = parse_args(argv)
    try:
        requested = validate_agents_flag(args.agents)
    except PreflightError as exc:
        return fail1(exc)

    if repo_root is None:
        repo_root = Path(__file__).resolve().parent.parent

    # Environment (read once at startup).
    models_yml = os.environ.get("MODELS_YML")
    llama_config = Path(os.environ.get("LLAMA_SWAP_CONFIG") or DEFAULT_LLAMA_SWAP_CONFIG)
    health_timeout = parse_health_timeout(os.environ.get("LLAMA_SWAP_HEALTH_TIMEOUT"))

    # Pre-flight: PyYAML importable.
    try:
        import yaml  # noqa: F401
    except ImportError:
        return fail1(
            PreflightError(
                "PyYAML is not installed. Install it (e.g. "
                "`sudo apt install python3-yaml`) and re-run."
            )
        )

    # Catalog resolution + parse + schema validation (all violations).
    try:
        catalog_path = resolve_catalog_path(repo_root, models_yml)
        data = load_catalog(catalog_path)
        catalog: Catalog = validate_catalog(data, catalog_path)
    except PreflightError as exc:
        return fail1(exc)
    info(f"Using catalog: {catalog_path}")

    # Env expansion pre-flight: all env values known before any mutation.
    try:
        for model in catalog.all_models():
            model.effective_env = expand_env_entries(catalog.env + model.env)
    except PreflightError as exc:  # CircularEnvError
        return fail1(exc)

    agents_only = args.agents_only

    has_local = bool(catalog.local_models())
    if has_local and not agents_only:
        try:
            llama_preflight(llama_config)
        except PreflightError as exc:
            return fail1(exc)

    if (
        not agents_only
        and any(m.download for m in catalog.local_models())
        and shutil.which("hf") is None
    ):
        return fail1(
            PreflightError(
                "hf CLI is not installed. Run ./tasks/setup-basics.sh first."
            )
        )

    # Placeholder apiKey warning (before any agent write, once per run).
    for provider in catalog.providers:
        if provider.api_key and "PLACEHOLDER" in provider.api_key:
            warning(
                f"apiKey of catalog provider '{provider.name}' looks like a "
                f"placeholder (contains 'PLACEHOLDER') — it is written to "
                f"agent configs as-is; replace it in models.yml"
            )

    results: list[ComponentResult] = []

    # Behavior 2: downloads.
    downloads_result = ComponentResult(name="downloads")
    if has_local and not agents_only:
        step("Downloading model weights")
        for model in catalog.local_models():
            for cr in download_model(model):
                entry = f"{cr.model_name} (cmd {cr.command_index})"
                if cr.status == "present":
                    downloads_result.present.append(entry)
                elif cr.status == "downloaded":
                    downloads_result.added.append(entry)
                else:
                    downloads_result.failed.append(f"{entry}: {cr.detail}")
    else:
        downloads_result.notes.append(
            "--agents-only — skipped"
            if agents_only
            else "no local models in catalog — skipped"
        )
    results.append(downloads_result)

    # Behavior 3: llama-swap sync.
    if has_local and not agents_only:
        step("llama-swap configuration sync")
        llama_result = llama_sync(
            llama_config,
            catalog,
            no_restart=args.no_restart,
            health_timeout=health_timeout,
        )
        results.append(llama_result)
        llama_attempted = True
    else:
        reason = "--agents-only" if agents_only else "no local models in catalog"
        info(f"llama-swap: {reason} — skipped")
        llama_result = ComponentResult(name="llama-swap")
        llama_result.skipped.append(reason)
        results.append(llama_result)
        llama_attempted = False

    # Behavior 4: agent sync (independent per agent).
    step("Agent configuration sync")
    synced_agent_paths: list[tuple[str, Path]] = []
    for adapter, explicit in select_agents(requested):
        outcome = adapter.run(catalog, explicitly_requested=explicit)
        results.append(outcome.result)
        if outcome.status == "synced":
            synced_agent_paths.append((adapter.name, adapter.config_path()))

    # Behavior 5: verification (config state only) + summary.
    verify_result = verify(
        catalog,
        llama_config if (has_local and llama_attempted) else None,
        synced_agent_paths,
    )
    for failure in verify_result.failed:
        error(failure)
    results.append(verify_result)
    print_summary(results)

    failed = any(r.failed for r in results)
    return 2 if failed else 0
