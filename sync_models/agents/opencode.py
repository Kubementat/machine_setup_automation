"""Opencode agent adapter: ``~/.config/opencode/opencode.json``.

``opencode.json`` only (Decision 29): if it is missing but a sibling
``opencode.jsonc`` exists, the agent is skipped with a warning (JSONC is not
managed; a parallel ``opencode.json`` would be an ambiguous merged config).
The ``OPENCODE_CONFIG`` env var (opencode's own custom-config-path variable)
is honored with the same semantics.

Provider block: ``provider.<name>`` with ``name``,
``npm: "@ai-sdk/openai-compatible"`` (written when the provider is created),
``options.baseURL`` = catalog baseUrl, ``options.apiKey`` (only if the
catalog provides one), ``models: {}``.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import ClassVar

from sync_models import AgentReadError
from sync_models.agents.base import AgentAdapter, Event
from sync_models.catalog import Catalog, ModelSpec, ProviderSpec

_MISSING = object()


class OpencodeAdapter(AgentAdapter):
    name: ClassVar[str] = "opencode"

    def config_path(self) -> Path:
        override = os.environ.get("OPENCODE_CONFIG")
        if override:
            return Path(override)
        return Path.home() / ".config" / "opencode" / "opencode.json"

    def detect(self) -> tuple[bool, str | None]:
        path = self.config_path()
        if path.is_file():
            return True, None
        if not os.environ.get("OPENCODE_CONFIG") and (
            path.parent / "opencode.jsonc"
        ).is_file():
            return (
                False,
                "opencode.json missing but sibling opencode.jsonc exists — "
                "JSONC is not managed by this tool",
            )
        return False, f"config file not found at {path}"

    def skip_is_warning(self, reason: str) -> bool:
        # Decision 29: JSONC-only setups are always skipped with a WARNING.
        return reason.startswith("opencode.json missing but sibling")

    def merge(self, data: dict, catalog: Catalog) -> tuple[dict, list[Event]]:
        events: list[Event] = []
        providers = data.get("provider")
        if providers is None:
            providers = {}
            data["provider"] = providers
        if not isinstance(providers, dict):
            raise AgentReadError("'provider' is not a JSON object")

        for provider in catalog.providers:
            existing = providers.get(provider.name)
            if existing is None:
                options: dict = {"baseURL": provider.base_url}
                if provider.api_key is not None:
                    options["apiKey"] = provider.api_key
                block: dict = {
                    "name": provider.name,
                    "npm": "@ai-sdk/openai-compatible",
                    "options": options,
                    "models": {},
                }
                providers[provider.name] = block
                models_map = block["models"]
            else:
                if not isinstance(existing, dict):
                    raise AgentReadError(
                        f"provider '{provider.name}' is not a JSON object"
                    )
                options = existing.get("options")
                if options is None:
                    options = {}
                    existing["options"] = options
                if not isinstance(options, dict):
                    raise AgentReadError(
                        f"provider '{provider.name}' options is not a JSON object"
                    )
                if options.get("baseURL") != provider.base_url:
                    old = options.get("baseURL")
                    options["baseURL"] = provider.base_url
                    events.append(
                        (
                            "warn",
                            f"opencode: provider '{provider.name}' baseURL "
                            f"changed from '{old}' to '{provider.base_url}'",
                            [],
                        )
                    )
                # apiKey is updated only if the catalog provides one; a
                # catalog without apiKey never clears an existing value.
                if (
                    provider.api_key is not None
                    and options.get("apiKey") != provider.api_key
                ):
                    options["apiKey"] = provider.api_key
                    events.append(
                        (
                            "info",
                            f"opencode: provider '{provider.name}': "
                            f"apiKey updated",
                            [],
                        )
                    )
                models_map = existing.get("models")
                if models_map is None:
                    models_map = {}
                    existing["models"] = models_map
                if not isinstance(models_map, dict):
                    raise AgentReadError(
                        f"provider '{provider.name}' models is not a JSON object"
                    )

            for model in provider.models:
                events.extend(self._merge_model(models_map, model, provider))
        return data, events

    @staticmethod
    def _build_variant_config(
        level_key: str, effort_value: str | None
    ) -> dict:
        """Build one opencode variant config from a thinkingLevelMap entry.

        * effort_value ``null`` → ``{"reasoningEffort": "none"}``
        * effort_value ``"low"`` → ``{"reasoningEffort": "low", "reasoning_budget_tokens": 512}``
        * effort_value ``"medium"`` → ``{"reasoningEffort": "medium", "reasoning_budget_tokens": 2048}``
        * effort_value ``"high"`` → ``{"reasoningEffort": "high", "reasoning_budget_tokens": 4096}``
        * effort_value ``"xhigh"`` → ``{"reasoningEffort": "xhigh", "reasoning_budget_tokens": 8192}``
        * effort_value ``"max"`` → ``{"reasoningEffort": "max", "reasoning_budget_tokens": 8192}``
        """
        if effort_value is None:
            return {"reasoningEffort": "none"}
        budget_map: dict[str, int] = {
            "low": 512,
            "medium": 2048,
            "high": 4096,
            "xhigh": 8192,
            "max": 8192,
        }
        cfg: dict = {"reasoningEffort": effort_value}
        budget = budget_map.get(effort_value)
        if budget is not None:
            cfg["reasoning_budget_tokens"] = budget
        return cfg

    def _merge_model(
        self,
        models_map: dict,
        model: ModelSpec,
        provider: ProviderSpec,
    ) -> list[Event]:
        subject = f"'{model.name}' (provider '{provider.name}')"
        entry = models_map.get(model.name)
        if entry is None:
            new_entry: dict = {
                "name": model.name,
                "limit": {"context": model.context_window, "output": model.max_tokens},
                "reasoning": model.reasoning,
                "modalities": {
                    "input": list(model.input),
                    "attachment": "image" in model.input,
                    # Creation-time default, written once, never managed after.
                    "output": ["text"],
                },
                # Creation-time default, written once, never managed after.
                "tool_call": True,
            }
            # ── add variants from thinkingLevelMap ──
            tlm = model.thinking_level_map
            if tlm:
                variants: dict[str, dict] = {}
                for level_key, effort_value in tlm.items():
                    variants[level_key] = self._build_variant_config(
                        level_key, effort_value
                    )
                new_entry["variants"] = variants

            models_map[model.name] = new_entry
            return [("added", subject, [])]

        if not isinstance(entry, dict):
            raise AgentReadError(f"model '{model.name}' is not a JSON object")

        fields: list[str] = []
        if entry.get("name", _MISSING) != model.name:
            entry["name"] = model.name
            fields.append("name")
        for key in ("limit", "modalities"):
            if entry.get(key, _MISSING) is None:
                entry[key] = {}
            if not isinstance(entry.get(key), dict):
                raise AgentReadError(
                    f"model '{model.name}' field '{key}' is not a JSON object"
                )
        limit = entry["limit"]
        # limit requires both fields — both always written (managed).
        if limit.get("context", _MISSING) != model.context_window:
            limit["context"] = model.context_window
            fields.append("limit.context")
        if limit.get("output", _MISSING) != model.max_tokens:
            limit["output"] = model.max_tokens
            fields.append("limit.output")
        if entry.get("reasoning", _MISSING) != model.reasoning:
            entry["reasoning"] = model.reasoning
            fields.append("reasoning")
        modalities = entry["modalities"]
        if modalities.get("input", _MISSING) != model.input:
            modalities["input"] = list(model.input)
            fields.append("modalities.input")
        # attachment is recomputed from the catalog input — managed.
        attachment = "image" in model.input
        if modalities.get("attachment", _MISSING) != attachment:
            modalities["attachment"] = attachment
            fields.append("modalities.attachment")
        # Never touched: tool_call, modalities.output, cost, any other field.

        # ── sync variants from thinkingLevelMap ──
        tlm = model.thinking_level_map
        if tlm is not None and tlm:  # empty dict → clear variants
            new_variants: dict[str, dict] = {}
            for level_key, effort_value in tlm.items():
                new_variants[level_key] = self._build_variant_config(
                    level_key, effort_value
                )
            # Ensure variants object exists
            if "variants" not in entry:
                entry["variants"] = {}
            old_variants = entry["variants"]
            if not isinstance(old_variants, dict):
                old_variants = {}
                entry["variants"] = old_variants
            # Diff: added/updated
            for vk, vc in new_variants.items():
                if old_variants.get(vk) != vc:
                    entry["variants"][vk] = vc
                    fields.append(f"variants.{vk}")
            # Diff: removed
            for vk in list(old_variants):
                if vk not in new_variants:
                    del entry["variants"][vk]
                    fields.append(f"variants.{vk} removed")

        if fields:
            return [("updated", subject, fields)]
        return [("present", subject, [])]
