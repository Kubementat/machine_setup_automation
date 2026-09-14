"""Post-run verification + per-component summary table (spec *Behavior 5*).

Verification checks **config state only** (re-read from disk): every local
model key exists in the llama-swap config, and every synced agent contains
all catalog providers/models. It does not check weight-file presence — a
failed download leaves its config entry in place (declarative) and surfaces
in the downloads summary.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from sync_models import info
from sync_models.catalog import Catalog

_CATEGORIES = ("added", "updated", "present", "skipped", "failed")
_CATEGORY_LABELS = {
    "added": "added",
    "updated": "updated",
    "present": "already present",
    "skipped": "skipped",
    "failed": "failed",
}


@dataclass
class ComponentResult:
    """Per-component outcome counts for the summary."""

    name: str  # "downloads" | "llama-swap" | agent name | "verification"
    added: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)
    present: list[str] = field(default_factory=list)  # "already present"
    skipped: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def get(self, category: str) -> list[str]:
        """Access a count category by name (added/updated/present/skipped/failed)."""
        return getattr(self, category)


def verify(
    catalog: Catalog,
    llama_config_path: Path | None,
    synced_agents: list[tuple[str, Path]],
) -> ComponentResult:
    """Re-read config files from disk and check catalog coverage.

    *llama_config_path*: None when the catalog has no local models.
    *synced_agents*: (agent_name, config_path) rows that finished synced.
    """
    import yaml  # function-local

    result = ComponentResult(name="verification")
    local_models = catalog.local_models()

    if llama_config_path is not None and local_models:
        try:
            data = yaml.safe_load(llama_config_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or not isinstance(data.get("models"), dict):
                result.failed.append(
                    f"llama-swap: config structure unexpected: {llama_config_path}"
                )
            else:
                models_map = data["models"]
                for model in local_models:
                    if model.name not in models_map:
                        result.failed.append(
                            f"llama-swap: model '{model.name}' missing from "
                            f"{llama_config_path} models:"
                        )
        except Exception as exc:
            result.failed.append(
                f"llama-swap: cannot re-read {llama_config_path}: {exc}"
            )

    for agent_name, config_path in synced_agents:
        try:
            data = json.loads(config_path.read_text(encoding="utf-8"))
        except Exception as exc:
            result.failed.append(
                f"{agent_name}: cannot re-read {config_path}: {exc}"
            )
            continue
        if not isinstance(data, dict):
            result.failed.append(
                f"{agent_name}: config is not a JSON object: {config_path}"
            )
            continue
        for provider in catalog.providers:
            if agent_name == "pi":
                providers = data.get("providers")
                block = (
                    providers.get(provider.name)
                    if isinstance(providers, dict)
                    else None
                )
                if not isinstance(block, dict):
                    result.failed.append(
                        f"pi: provider '{provider.name}' missing from {config_path}"
                    )
                    continue
                models_list = block.get("models")
                ids = (
                    {m.get("id") for m in models_list}
                    if isinstance(models_list, list)
                    else set()
                )
                for model in provider.models:
                    if model.name not in ids:
                        result.failed.append(
                            f"pi: provider '{provider.name}' / model "
                            f"'{model.name}' missing from {config_path}"
                        )
            else:  # opencode
                providers = data.get("provider")
                block = (
                    providers.get(provider.name)
                    if isinstance(providers, dict)
                    else None
                )
                if not isinstance(block, dict):
                    result.failed.append(
                        f"opencode: provider '{provider.name}' missing from "
                        f"{config_path}"
                    )
                    continue
                models_map = block.get("models")
                if not isinstance(models_map, dict):
                    result.failed.append(
                        f"opencode: provider '{provider.name}' / models "
                        f"missing from {config_path}"
                    )
                    continue
                for model in provider.models:
                    if model.name not in models_map:
                        result.failed.append(
                            f"opencode: provider '{provider.name}' / model "
                            f"'{model.name}' missing from {config_path}"
                        )
    return result


def print_summary(results: list[ComponentResult]) -> None:
    """Plain-text summary table (no ANSI), one section per component."""
    info("─" * 42)
    info("Summary")
    info("─" * 42)
    for result in results:
        if not any(result.get(cat) for cat in _CATEGORIES) and not result.notes:
            if result.name == "verification":
                info("verification: OK")
            continue
        counts = [
            f"{len(result.get(cat))} {label}"
            for cat in _CATEGORIES
            if result.get(cat)
            for label in [_CATEGORY_LABELS[cat]]
        ]
        info(f"{result.name:<13}: {', '.join(counts) if counts else ''}")
        for cat in _CATEGORIES:
            for item in result.get(cat):
                if cat == "skipped":  # items already carry the full reason
                    info(f"    - {item}")
                else:
                    info(f"    - {_CATEGORY_LABELS[cat]}: {item}")
        for note in result.notes:
            info(f"    - note: {note}")
