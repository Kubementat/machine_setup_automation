"""Runs comfy-cli with ``--json`` and unwraps its ``envelope/1`` result."""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any

from .settings import Settings

ENVELOPE_SCHEMA = "envelope/1"

# Non-interactive, local-only, no telemetry, no detached job watcher.
_CHILD_ENV = {
    "COMFY_WHERE": "local",
    "COMFY_NO_WATCH": "1",
    "COMFY_USER_AGENT": "comfyui-mcp",
    "DO_NOT_TRACK": "1",
    "PYTHONUTF8": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "PIP_NO_INPUT": "1",
}


class ComfyError(Exception):
    """A comfy-cli call failed; ``code`` is comfy-cli's error code when it gave one."""

    def __init__(self, code: str, message: str, hint: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.hint = hint

    def __str__(self) -> str:
        text = f"{self.code}: {self.message}"
        return f"{text} (hint: {self.hint})" if self.hint else text


def build_argv(settings: Settings, args: list[str]) -> list[str]:
    """Global options must precede the subcommand in comfy-cli."""
    return [
        settings.comfy_bin,
        "--json",
        "--skip-prompt",
        "--where",
        "local",
        f"--workspace={settings.workspace}",
        *args,
    ]


def parse_envelope(stdout: str) -> dict[str, Any] | None:
    """The envelope is the last non-empty stdout line; anything else is noise."""
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            return None
        return value if isinstance(value, dict) else None
    return None


def run_comfy(settings: Settings, args: list[str], timeout: float = 60.0) -> Any:
    """Run ``comfy <args>`` and return the envelope's ``data``; raise ComfyError otherwise."""
    argv = build_argv(settings, args)
    try:
        proc = subprocess.run(
            argv,
            env={**os.environ, **_CHILD_ENV},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        raise ComfyError("comfy_not_found", f"comfy-cli not found: {settings.comfy_bin}") from None
    except subprocess.TimeoutExpired:
        raise ComfyError("timeout", f"comfy {' '.join(args[:2])} did not finish within {timeout:.0f}s") from None

    envelope = parse_envelope(proc.stdout)
    if envelope is None or envelope.get("schema") != ENVELOPE_SCHEMA:
        stderr_tail = proc.stderr.strip().splitlines()[-3:]
        raise ComfyError(
            "unexpected_output",
            f"comfy exited {proc.returncode} without an {ENVELOPE_SCHEMA} result: {' | '.join(stderr_tail)}",
        )
    if not envelope.get("ok"):
        error = envelope.get("error") or {}
        raise ComfyError(
            str(error.get("code") or "unknown_error"),
            str(error.get("message") or f"comfy exited {proc.returncode}"),
            error.get("hint"),
        )
    return envelope.get("data")
