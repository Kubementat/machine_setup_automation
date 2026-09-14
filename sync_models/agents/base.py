"""AgentAdapter interface + shared JSON load/merge/write helpers.

``merge`` is a pure function returning events (no logging, no I/O inside the
adapters' merge) so it is unit-testable; all logging and writing happens in
the template method :meth:`AgentAdapter.run` (Behavior 4).
"""

from __future__ import annotations

import copy
import json
import os
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar

from sync_models import AgentReadError, MutationError, error, info, warning
from sync_models.atomicio import atomic_write_text
from sync_models.catalog import Catalog
from sync_models.verify import ComponentResult

Event = tuple[str, str, list[str]]  # ("added"|"updated"|"present"|"warn", subject, [fields]); for "warn", subject is the full message after 'WARNING: '


@dataclass
class AgentSyncOutcome:
    """Outcome of one agent's sync pass."""

    status: str  # "synced" | "skipped" | "failed"
    result: ComponentResult


def load_json_object(path: Path) -> dict:
    """Read *path* as a JSON object that is writable by the invoking user.

    Raises :class:`~sync_models.AgentReadError` when the file is not valid
    JSON, not a JSON object, or not writable.
    """
    if not path.is_file():
        raise AgentReadError(f"{path}: config file not found")
    if not os.access(path, os.W_OK):
        raise AgentReadError(f"{path}: not writable")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise AgentReadError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise AgentReadError(f"{path}: not a JSON object")
    return data


def write_json(path: Path, data: dict, label: str) -> None:
    """Serialize (2-space indent, trailing newline) and write atomically."""
    text = json.dumps(data, indent=2) + "\n"
    atomic_write_text(
        path, text, validate=json.loads, expected=data, label=label
    )


class AgentAdapter(ABC):
    """One coding agent's model-config sync (Behavior 4)."""

    name: ClassVar[str]

    @abstractmethod
    def config_path(self) -> Path:
        """The agent config file path (env override + documented default)."""

    @abstractmethod
    def detect(self) -> tuple[bool, str | None]:
        """Return ``(detected, skip_reason)``."""

    @abstractmethod
    def merge(self, data: dict, catalog: Catalog) -> tuple[dict, list[Event]]:
        """Pure in-memory merge; returns ``(merged_data, events)``."""

    def skip_is_warning(self, reason: str) -> bool:
        """Whether a not-detected skip must be logged as a WARNING.

        Default: only explicit ``--agents`` requests warn. Adapters may
        override for spec-mandated warnings (e.g. opencode JSONC, D29).
        """
        return False

    def run(self, catalog: Catalog, *, explicitly_requested: bool) -> AgentSyncOutcome:
        """Behavior 4 template method: detect, read guard, merge, write."""
        result = ComponentResult(name=self.name)
        detected, reason = self.detect()
        if not detected:
            message = f"{self.name}: skipped (not detected): {reason}"
            if explicitly_requested or self.skip_is_warning(reason or ""):
                warning(message)  # an explicit request is still not an error
            else:
                info(message)
            result.skipped.append(f"skipped (not detected): {reason}")
            return AgentSyncOutcome("skipped", result)

        path = self.config_path()
        try:
            data = load_json_object(path)
        except AgentReadError as exc:
            error(f"{self.name}: {exc} — agent skipped, file not overwritten")
            result.failed.append(str(exc))
            return AgentSyncOutcome("failed", result)

        original = copy.deepcopy(data)
        try:
            merged, events = self.merge(data, catalog)
        except AgentReadError as exc:
            error(f"{self.name}: {exc} — agent skipped, file not overwritten")
            result.failed.append(str(exc))
            return AgentSyncOutcome("failed", result)

        for kind, subject, fields in events:
            if kind == "added":
                info(f"{self.name}: added model {subject}")
                result.added.append(subject)
            elif kind == "updated":
                info(f"{self.name}: updated {subject}: {', '.join(fields)}")
                result.updated.append(f"{subject}: {', '.join(fields)}")
            elif kind == "warn":
                warning(subject)
            elif kind == "info":
                info(subject)
            else:  # "present" events are silent
                result.present.append(subject)

        if merged != original:
            try:
                write_json(path, merged, label=self.name)
            except MutationError as exc:
                error(exc.message)
                result.failed.append(str(exc))
                return AgentSyncOutcome("failed", result)
        else:
            info(f"{self.name}: config unchanged — no write")
        return AgentSyncOutcome("synced", result)
