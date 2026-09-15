"""Whether ComfyUI is loaded, and loading it through llama-swap."""

from __future__ import annotations

import json
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any

from .settings import Settings

# Loading ComfyUI can take minutes; the wake request stays open that long.
_WAKE_TIMEOUT_SECONDS = 900

_wake_lock = threading.Lock()
_wake_thread: threading.Thread | None = None
_last_wake_error: str | None = None


class ComfyUINotReady(Exception):
    """ComfyUI is still loading; the caller should retry."""


def system_stats(settings: Settings) -> dict[str, Any] | None:
    """ComfyUI's /system_stats, or None when nothing answers on the fixed port."""
    try:
        with urllib.request.urlopen(f"{settings.comfyui_url}/system_stats", timeout=3) as resp:
            return json.load(resp)
    except (urllib.error.URLError, OSError, ValueError):
        return None


def _wake(settings: Settings) -> None:
    """GET /comfyui/ on llama-swap: only the root path loads comfyui_auto."""
    global _last_wake_error
    request = urllib.request.Request(f"{settings.llama_swap_url}/comfyui/")
    if settings.api_key:
        request.add_header("Authorization", f"Bearer {settings.api_key}")
    try:
        with urllib.request.urlopen(request, timeout=_WAKE_TIMEOUT_SECONDS) as resp:
            resp.read(1)
        _last_wake_error = None
    except urllib.error.HTTPError as exc:
        _last_wake_error = f"llama-swap answered HTTP {exc.code} to GET /comfyui/"
    except (urllib.error.URLError, OSError) as exc:
        _last_wake_error = f"llama-swap did not answer GET /comfyui/: {exc}"
    if _last_wake_error:
        print(f"comfyui-mcp: {_last_wake_error}", file=sys.stderr)


def ensure_loaded(settings: Settings) -> None:
    """Return once ComfyUI answers; raise ComfyUINotReady after ``wake_wait_seconds``.

    The wake request runs in its own thread, so it keeps llama-swap loading
    ComfyUI even when this call gives up and the client retries later.
    """
    global _wake_thread
    if system_stats(settings) is not None:
        return
    with _wake_lock:
        if _wake_thread is None or not _wake_thread.is_alive():
            _wake_thread = threading.Thread(target=_wake, args=(settings,), daemon=True)
            _wake_thread.start()
    deadline = time.monotonic() + settings.wake_wait_seconds
    while time.monotonic() < deadline:
        if system_stats(settings) is not None:
            return
        if not _wake_thread.is_alive() and _last_wake_error:
            raise ComfyUINotReady(_last_wake_error)
        time.sleep(2)
    raise ComfyUINotReady("ComfyUI is still loading through llama-swap — retry in about a minute")
