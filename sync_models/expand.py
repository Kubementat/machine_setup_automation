"""${VAR} placeholder expansion (spec *Placeholder Expansion*).

Matching is on the shell syntax ``${NAME}`` where NAME is
``[A-Za-z_][A-Za-z_]*``; any other ``${...}`` form (llama-swap macros such as
``${llama-server-bin}``, ``${models-dir}`` — non-identifier names) is never
matched and is left untouched for llama-swap to expand at serve time.

A variable is substituted only if it is defined in the catalog env or in the
current process environment (``os.environ``) — this is how ``${HOME}`` works
without declaring it.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping

from sync_models import CircularEnvError
from sync_models.catalog import EnvEntry

PLACEHOLDER_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
MAX_EXPANSION_PASSES = 10


def expand_env_entries(
    entries: list[EnvEntry],
    environ: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Expand catalog env *entries* to a fixed point.

    *entries* = catalog top-level env (listed order) + per-model env; a
    per-model entry overrides a same-named top-level one. ``environ``
    defaults to ``os.environ``. Returns ``{name: fully-expanded value}`` for
    the catalog-defined variables only. Raises
    :class:`~sync_models.CircularEnvError` if no fixed point is reached
    within :data:`MAX_EXPANSION_PASSES` passes.
    """
    if environ is None:
        environ = os.environ
    # Per-model entries override same-named top-level ones.
    values: dict[str, str] = {}
    for entry in entries:
        values[entry.name] = entry.value
    names = set(values)

    for _ in range(MAX_EXPANSION_PASSES):
        changed = False
        for entry in entries:
            name = entry.name
            if name not in values:
                continue

            def repl(match: re.Match[str]) -> str:
                var = match.group(1)
                if var in values:
                    return values[var]  # catalog variable (may be mid-expansion)
                if var in environ:
                    return environ[var]  # process env (how ${HOME} works)
                return match.group(0)  # llama-swap macro — left verbatim

            new = PLACEHOLDER_RE.sub(repl, values[name])
            if new != values[name]:
                values[name] = new
                changed = True
        if not changed:
            break
    # Catalog-variable placeholders still present after a fixed point mean
    # self-reference (A=${A}) or a cycle (A=${B}, B=${A}) — those settle into
    # garbage instead of diverging, so they must be detected explicitly.
    involved: set[str] = set()
    for name in values:
        refs = [m.group(1) for m in PLACEHOLDER_RE.finditer(values[name]) if m.group(1) in names]
        if refs:
            involved.add(name)
            involved.update(refs)
    if involved:
        raise CircularEnvError(sorted(involved))
    return values


def expand_text(text: str, variables: Mapping[str, str]) -> str:
    """Substitute ``${NAME}`` in *text*.

    ``NAME`` resolves from *variables* (expanded catalog env), else from
    ``os.environ``; anything else (llama-swap macros) is left verbatim.
    """
    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        if name in variables:
            return variables[name]
        if name in os.environ:
            return os.environ[name]
        return match.group(0)

    return PLACEHOLDER_RE.sub(repl, text)
