"""Settings, read once from the environment the llama-swap fragment provides."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    comfy_bin: str
    """comfy-cli executable (the one pinned in this server's venv)."""
    workspace: str
    """ComfyUI checkout, passed as ``--workspace`` on every comfy call."""
    comfyui_url: str
    """ComfyUI on its fixed local port; comfy-cli reads the same COMFY_LOCAL_URL."""
    llama_swap_url: str
    """Local llama-swap; ``GET /comfyui/`` there loads ComfyUI."""
    api_key: str | None
    """This server's own llama-swap API key (COMFYUI_MCP_API_KEY)."""
    manifest: str
    """setup-comfyui.sh install manifest (key=value lines)."""
    comfyui_repo_url: str
    """Git remote to list ComfyUI release tags from."""
    work_dir: str
    """Writable directory for submitted workflow files."""
    wake_wait_seconds: float
    """How long a tool waits for ComfyUI to load before asking to retry."""


def load_settings(env: dict[str, str] | None = None) -> Settings:
    """Build Settings from ``env`` (default: the process environment)."""
    env = dict(os.environ) if env is None else env
    comfyui_dir = env.get("COMFYUI_DIR", "/srv/comfyui")
    mcp_dir = env.get("COMFYUI_MCP_DIR", "/srv/comfyui-mcp")
    return Settings(
        comfy_bin=env.get("COMFY_BIN", "comfy"),
        workspace=env.get("COMFYUI_WORKSPACE", f"{comfyui_dir}/ComfyUI"),
        comfyui_url=env.get("COMFY_LOCAL_URL", "http://127.0.0.1:8188").rstrip("/"),
        llama_swap_url=env.get("LLAMA_SWAP_URL", "http://127.0.0.1:9292").rstrip("/"),
        api_key=env.get("COMFYUI_MCP_API_KEY") or None,
        manifest=env.get("COMFYUI_MANIFEST", f"{comfyui_dir}/state/install-manifest"),
        comfyui_repo_url=env.get("COMFYUI_REPO_URL", "https://github.com/Comfy-Org/ComfyUI.git"),
        work_dir=env.get("COMFYUI_MCP_WORK_DIR", f"{mcp_dir}/work"),
        # Below Cloudflare's ~100 s origin timeout, with room for the tool itself.
        wake_wait_seconds=float(env.get("COMFYUI_MCP_WAKE_WAIT", "60")),
    )
