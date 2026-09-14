"""sync_models — declarative model catalog sync.

Downloads local model weights (via the ``hf`` CLI), additively merges catalog
model entries into the llama-swap configuration, and wires every catalog model
into the coding agents' model configuration files (pi, opencode).

Idempotent and strictly additive with respect to state it does not own:
re-running after a successful run is a no-op.

No module in this package performs I/O at import time, so the pure logic
(validation, expansion, merging) stays unit-testable.
"""

from __future__ import annotations

import sys

__version__ = "1.0.0"


def info(msg: str) -> None:
    """Informational log line → stdout (plain text, no prefix, no ANSI)."""
    print(msg)


def step(title: str) -> None:
    """Section header → stdout."""
    print(f"\n{title}")


def warning(msg: str) -> None:
    """Warning line → stdout only (Decision 30)."""
    print(f"WARNING: {msg}")


def error(msg: str) -> None:
    """Error line → stdout AND stderr (Decision 30; matches error() in
    lib/helpers.sh). Does not exit; the caller returns/raises with the right
    code."""
    print(f"ERROR: {msg}")
    sys.stdout.flush()  # keep stdout/stderr order stable when piped
    print(f"ERROR: {msg}", file=sys.stderr)


class PreflightError(Exception):
    """Pre-flight failure → exit 1, no mutation attempted.

    Carries one or more message lines (e.g. all schema violations, each of
    which is printed as its own ERROR line).
    """

    def __init__(self, *messages: str):
        self.messages = list(messages)
        super().__init__("; ".join(self.messages))


class CircularEnvError(PreflightError):
    """Catalog env references do not converge (exit 1, names the variables)."""

    def __init__(self, variables: list[str]):
        self.variables = list(variables)
        super().__init__(
            "circular or non-converging catalog env reference involving: "
            f"{', '.join(self.variables)} (no fixed point after 10 expansion passes)"
        )


class MutationError(Exception):
    """Mutation/write failure → exit 2 (per component)."""

    def __init__(self, message: str):
        self.message = message
        super().__init__(message)


class AgentReadError(Exception):
    """Agent config read/structure/writability guard failure.

    Behavior 4 step 0: the agent is skipped (marked failed), its file is never
    overwritten, and the run ends with exit 2.
    """

    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)
