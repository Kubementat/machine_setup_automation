"""llama-swap config.yaml sync (spec *Behavior 3*), restart, health poll.

Strictly additive: missing local-model entries are added (cmd = expanded
serve.cmd; per-model env only, Decision 26); existing entries and every other
section (macros, matrix, hooks, apiKeys, peers, globals) are never touched.
The file is rewritten only when the merged data differs; the restart happens
only when the file was written (unless --no-restart), followed by the
post-restart health poll (Decision 32).
"""

from __future__ import annotations

import os
import subprocess
import time
import urllib.request
from pathlib import Path

from sync_models import (
    MutationError,
    PreflightError,
    error,
    info,
    warning,
)
from sync_models.atomicio import atomic_write_text
from sync_models.catalog import Catalog
from sync_models.expand import expand_text
from sync_models.verify import ComponentResult

DEFAULT_PORT = 9292
HEALTH_POLL_INTERVAL_S = 2
HEALTH_REQUEST_TIMEOUT_S = 5


def preflight(config_path: Path) -> None:
    """Pre-flight checks when the catalog has local models (Behavior 1).

    Only called in that case; raises :class:`PreflightError` on any failure.
    The config data is re-loaded by :func:`sync`; this parse is throw-away.
    """
    import yaml  # function-local

    if not config_path.is_file():
        raise PreflightError(
            "llama-swap is not set up. Run ./tasks/setup-llama-swap.sh first."
        )
    try:
        data = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise PreflightError(
            f"llama-swap config is not valid YAML: {config_path}: "
            f"{exc}".replace("\n", " ")
        ) from exc
    if not isinstance(data, dict):
        raise PreflightError(
            f"llama-swap config is not a YAML mapping: {config_path}"
        )
    if "models" in data and not isinstance(data["models"], dict):
        raise PreflightError(
            f"llama-swap config 'models' section is not a mapping: {config_path}"
        )
    writable = os.access(config_path, os.W_OK) or os.access(config_path.parent, os.W_OK)
    if not writable:
        raise PreflightError(
            f"llama-swap config not writable: {config_path} — fix "
            f"ownership/permissions or run as a user with write access"
        )


def sync(
    config_path: Path,
    catalog: Catalog,
    *,
    no_restart: bool,
    health_timeout: int,
) -> ComponentResult:
    """Behavior 3: add-only merge of local models, atomic write, restart, poll."""
    import copy

    import yaml  # function-local

    result = ComponentResult(name="llama-swap")
    data = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    original = copy.deepcopy(data)
    models_map = data.get("models")
    if models_map is None:
        models_map = {}  # introduced into the document only if something is added
        data["models"] = models_map

    for model in catalog.local_models():
        if model.name in models_map:
            info(f"llama-swap: {model.name}: already present, unchanged")
            result.present.append(model.name)
            continue
        variables = model.effective_env or {}
        entry: dict[str, object] = {
            "cmd": expand_text(model.serve_cmd, variables)
        }
        if model.env:
            # Per-model env only (Decision 26): values placeholder-expanded;
            # top-level env is expansion-only and never written.
            entry["env"] = [f"{e.name}={variables[e.name]}" for e in model.env]
        models_map[model.name] = entry
        info(f"llama-swap: added model {model.name}")
        result.added.append(model.name)

    changed = data != original
    if not changed:
        info("llama-swap config unchanged — no write, no restart")
        return result

    warning(
        f"llama-swap config {config_path} will be rewritten by a YAML "
        f"round-trip — existing comments and manual formatting in this file "
        f"will not be preserved"
    )
    text = yaml.safe_dump(
        data, sort_keys=False, default_flow_style=False, allow_unicode=True
    )
    try:
        atomic_write_text(
            config_path,
            text,
            validate=yaml.safe_load,
            expected=data,
            label="llama-swap",
        )
    except MutationError as exc:
        error(exc.message)
        result.failed.append(str(exc))
        result.notes.append("config write failed")
        return result
    result.notes.append("config written")

    if no_restart:
        info(
            "Config written; --no-restart set — restart manually: "
            "sudo systemctl restart llama-swap"
        )
        return result

    info("Restarting llama-swap: sudo systemctl restart llama-swap")
    rc = restart()
    if rc != 0:
        error(
            f"failed to restart llama-swap (exit {rc}). Run manually: "
            f"sudo systemctl restart llama-swap"
        )
        result.failed.append(f"restart failed (exit {rc})")
        result.notes.append("restart failed")
        return result
    result.notes.append("llama-swap restarted")

    port = read_port(data)
    if poll_health(port, health_timeout):
        info("llama-swap healthy")
        result.notes.append("healthy")
    else:
        error(
            f"llama-swap not healthy within {health_timeout}s after restart. "
            f"Run: sudo systemctl status llama-swap"
        )
        result.failed.append(f"health poll timed out after {health_timeout}s")
        result.notes.append("health poll timed out")
    return result


def restart() -> int:
    """``sudo systemctl restart llama-swap`` (also starts a stopped service)."""
    return subprocess.run(
        ["sudo", "systemctl", "restart", "llama-swap"]
    ).returncode


def read_port(config: dict) -> int:
    """Top-level ``port`` key (int, or numeric string) if present, else 9292."""
    port = config.get("port")
    if isinstance(port, bool):
        return DEFAULT_PORT
    if isinstance(port, int):
        return port
    if isinstance(port, str):
        try:
            return int(port)
        except ValueError:
            return DEFAULT_PORT
    return DEFAULT_PORT


def poll_health(port: int, timeout_s: int) -> bool:
    """Poll ``http://localhost:<port>/health`` until HTTP 200 (Decision 32).

    2 s interval, 5 s per-request timeout, bounded by *timeout_s*.
    """
    url = f"http://localhost:{port}/health"
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            with urllib.request.urlopen(url, timeout=HEALTH_REQUEST_TIMEOUT_S) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass  # HTTPError, URLError, socket.timeout, OSError — keep polling
        if time.monotonic() + HEALTH_POLL_INTERVAL_S > deadline:
            break
        time.sleep(HEALTH_POLL_INTERVAL_S)
    return False
