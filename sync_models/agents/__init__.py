"""Agent adapter registry (single source of truth for supported agents).

Adding a future agent = adding one new module here and one registry entry.
"""

from __future__ import annotations

from sync_models import PreflightError
from sync_models.agents.base import AgentAdapter, AgentSyncOutcome
from sync_models.agents.opencode import OpencodeAdapter
from sync_models.agents.pi import PiAdapter

ADAPTERS: dict[str, type[AgentAdapter]] = {
    "pi": PiAdapter,
    "opencode": OpencodeAdapter,
}
SUPPORTED_AGENTS: tuple[str, ...] = tuple(ADAPTERS)  # registry order


def validate_agents_flag(raw: str | None) -> list[str] | None:
    """Validate the ``--agents`` value (after argparse parsing).

    None → None (auto-detect all present). Otherwise a comma-separated list;
    empty parts are dropped, duplicates removed (order preserved). Any
    unknown name → :class:`PreflightError` (exit 1 with the custom message,
    not argparse's default exit 2).
    """
    if raw is None:
        return None
    names: list[str] = []
    for part in raw.split(","):
        name = part.strip()
        if not name:
            continue
        if name not in names:
            names.append(name)
    unknown = [n for n in names if n not in ADAPTERS]
    if unknown:
        raise PreflightError(
            f"unsupported agent(s): {', '.join(unknown)}. "
            f"Supported agents: {', '.join(SUPPORTED_AGENTS)}"
        )
    return names


def select_agents(
    requested: list[str] | None,
) -> list[tuple[AgentAdapter, bool]]:
    """Return ``(adapter, explicitly_requested)`` pairs.

    None → every registered adapter in registry order (pi, then opencode),
    auto-detected. Otherwise the requested names in the given order.
    """
    if requested is None:
        return [(ADAPTERS[name](), False) for name in ADAPTERS]
    return [(ADAPTERS[name](), True) for name in requested]


__all__ = [
    "ADAPTERS",
    "SUPPORTED_AGENTS",
    "AgentAdapter",
    "AgentSyncOutcome",
    "OpencodeAdapter",
    "PiAdapter",
    "select_agents",
    "validate_agents_flag",
]
