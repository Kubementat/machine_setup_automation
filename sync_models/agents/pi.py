"""Pi agent adapter: ``~/.pi/agent/models.json``.

Provider block: ``providers.<name>`` with ``baseUrl``,
``api: "openai-completions"`` (written when the provider is created),
``apiKey`` (only if the catalog provides one), ``models: []``.

Model entry (list item): ``id``/``name`` = catalog name, ``reasoning``,
``input``, ``contextWindow``, ``maxTokens``, optional ``thinkingLevelMap``
(written as-is, nulls preserved). ``cost`` is unmanaged: omitted on new
entries, never modified on existing.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import ClassVar

from sync_models import AgentReadError
from sync_models.agents.base import AgentAdapter, Event
from sync_models.catalog import Catalog, ModelSpec, ProviderSpec

# Managed fields: updated when they differ from the catalog.
# ``thinkingLevelMap`` is managed only when present in the catalog.
MANAGED_FIELDS = (
    "id",
    "name",
    "reasoning",
    "input",
    "contextWindow",
    "maxTokens",
    "thinkingLevelMap",
)

_MISSING = object()


class PiAdapter(AgentAdapter):
    name: ClassVar[str] = "pi"

    def config_path(self) -> Path:
        override = os.environ.get("PI_MODELS_JSON")
        if override:
            return Path(override)
        return Path.home() / ".pi" / "agent" / "models.json"

    def detect(self) -> tuple[bool, str | None]:
        path = self.config_path()
        if path.is_file():
            return True, None
        return False, f"config file not found at {path}"

    def merge(self, data: dict, catalog: Catalog) -> tuple[dict, list[Event]]:
        events: list[Event] = []
        providers = data.get("providers")
        if providers is None:
            providers = {}
            data["providers"] = providers
        if not isinstance(providers, dict):
            raise AgentReadError("'providers' is not a JSON object")

        for provider in catalog.providers:
            existing = providers.get(provider.name)
            if existing is None:
                block: dict = {
                    "baseUrl": provider.base_url,
                    "api": "openai-completions",
                }
                if provider.api_key is not None:
                    block["apiKey"] = provider.api_key
                block["models"] = []
                providers[provider.name] = block
                models_list = block["models"]
            else:
                if not isinstance(existing, dict):
                    raise AgentReadError(
                        f"provider '{provider.name}' is not a JSON object"
                    )
                if existing.get("baseUrl") != provider.base_url:
                    old = existing.get("baseUrl")
                    existing["baseUrl"] = provider.base_url
                    events.append(
                        (
                            "warn",
                            f"pi: provider '{provider.name}' baseUrl changed "
                            f"from '{old}' to '{provider.base_url}'",
                            [],
                        )
                    )
                # apiKey is updated only if the catalog provides one; a
                # catalog without apiKey never clears an existing value.
                if (
                    provider.api_key is not None
                    and existing.get("apiKey") != provider.api_key
                ):
                    existing["apiKey"] = provider.api_key
                    events.append(
                        (
                            "info",
                            f"pi: provider '{provider.name}': apiKey updated",
                            [],
                        )
                    )
                models_list = existing.get("models")
                if models_list is None:
                    models_list = []
                    existing["models"] = models_list
                if not isinstance(models_list, list):
                    raise AgentReadError(
                        f"provider '{provider.name}' models is not a list"
                    )

            for model in provider.models:
                events.extend(self._merge_model(models_list, model, provider))
        return data, events

    @staticmethod
    def _managed_value(model: ModelSpec, field_name: str) -> object:
        if field_name in ("id", "name"):
            return model.name
        if field_name == "reasoning":
            return model.reasoning
        if field_name == "input":
            return model.input
        if field_name == "contextWindow":
            return model.context_window
        if field_name == "maxTokens":
            return model.max_tokens
        return model.thinking_level_map

    def _merge_model(
        self,
        models_list: list,
        model: ModelSpec,
        provider: ProviderSpec,
    ) -> list[Event]:
        subject = f"'{model.name}' (provider '{provider.name}')"
        entry = None
        for item in models_list:
            if isinstance(item, dict) and item.get("id") == model.name:
                entry = item
                break
        if entry is None:
            new_entry: dict = {
                "id": model.name,
                "name": model.name,
                "reasoning": model.reasoning,
                "input": list(model.input),
                "contextWindow": model.context_window,
                "maxTokens": model.max_tokens,
            }
            # thinkingLevelMap written as-is, nulls preserved; only when
            # present in the catalog.
            if model.thinking_level_map is not None:
                new_entry["thinkingLevelMap"] = model.thinking_level_map
            models_list.append(new_entry)
            return [("added", subject, [])]

        fields = [
            field
            for field in MANAGED_FIELDS
            if not (field == "thinkingLevelMap" and model.thinking_level_map is None)
            and entry.get(field, _MISSING) != self._managed_value(model, field)
        ]
        for field in fields:
            entry[field] = self._managed_value(model, field)
        if fields:
            return [("updated", subject, fields)]
        return [("present", subject, [])]
