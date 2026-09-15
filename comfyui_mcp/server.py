"""MCP tools and the ASGI app (stateless streamable HTTP at /mcp, GET /health)."""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Annotated, Any

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import Field
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from . import comfyui
from .comfy import ComfyError, run_comfy
from .settings import Settings

_PROMPT_ID = re.compile(r"^[0-9A-Za-z][0-9A-Za-z_-]{0,127}$")
_RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
_WORKFLOW_MAX_AGE_SECONDS = 7 * 24 * 3600

INSTRUCTIONS = """\
Tools for the ComfyUI on this server. ComfyUI is loaded on demand by llama-swap:
the first call that needs it may unload a running LLM, and may ask you to retry
while ComfyUI starts. A later LLM request unloads ComfyUI again and cancels a
running job. Workflows must be in ComfyUI's API format."""


def _read_manifest(path: str) -> dict[str, str] | None:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return None
    return {key: value for key, sep, value in (line.partition("=") for line in text.splitlines()) if sep}


def _release_tags(repo_url: str) -> list[str]:
    """Release tags (vX.Y.Z) of the ComfyUI remote, newest first."""
    proc = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", repo_url],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        check=False,
    )
    if proc.returncode != 0:
        raise ToolError(f"git ls-remote failed: {proc.stderr.strip()}")
    tags = [line.rsplit("refs/tags/", 1)[-1] for line in proc.stdout.splitlines()]
    releases = [t for t in tags if _RELEASE_TAG.match(t)]
    return sorted(releases, key=lambda t: tuple(int(n) for n in _RELEASE_TAG.match(t).groups()), reverse=True)


def _write_workflow(work_dir: Path, workflow: dict[str, Any]) -> str:
    """Store the workflow for ``comfy run --workflow``; drop files older than a week."""
    work_dir.mkdir(parents=True, exist_ok=True)
    cutoff = time.time() - _WORKFLOW_MAX_AGE_SECONDS
    for old in work_dir.glob("workflow-*.json"):
        if old.stat().st_mtime < cutoff:
            old.unlink(missing_ok=True)
    fd, path = tempfile.mkstemp(prefix="workflow-", suffix=".json", dir=work_dir)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(workflow, fh)
    return path


def build_server(settings: Settings) -> MCPServer:
    mcp = MCPServer("comfyui", instructions=INSTRUCTIONS)

    async def comfy(args: list[str], *, needs_comfyui: bool = True, timeout: float = 60.0) -> Any:
        try:
            if needs_comfyui:
                await asyncio.to_thread(comfyui.ensure_loaded, settings)
            return await asyncio.to_thread(run_comfy, settings, args, timeout)
        except (ComfyError, comfyui.ComfyUINotReady) as exc:
            raise ToolError(str(exc)) from None

    @mcp.tool()
    async def search_nodes(
        query: Annotated[str, Field(min_length=1, description="Text to search node names and descriptions for.")],
    ) -> Any:
        """Search the node types installed in ComfyUI."""
        return await comfy(["nodes", "search", "--", query])

    @mcp.tool()
    async def show_node(
        name: Annotated[str, Field(min_length=1, description="Node class name, e.g. KSampler.")],
    ) -> Any:
        """Full schema of one node type: inputs, outputs, defaults and constraints."""
        return await comfy(["nodes", "show", "--", name])

    @mcp.tool()
    async def list_model_folders() -> Any:
        """Model folders ComfyUI knows (checkpoints, loras, vae, ...)."""
        return await comfy(["models", "list-folders"])

    @mcp.tool()
    async def list_models(
        folder: Annotated[str, Field(min_length=1, description="A folder from list_model_folders, e.g. checkpoints.")],
    ) -> Any:
        """Model files ComfyUI sees in one folder."""
        return await comfy(["models", "list-folder", "--", folder])

    @mcp.tool()
    async def run_workflow(
        workflow: Annotated[dict[str, Any], Field(description="Workflow in ComfyUI API format (node id -> node).")],
    ) -> Any:
        """Queue a workflow and return immediately with its prompt_id; poll job_status for the result.

        Workflows with paid partner-API nodes are refused."""
        path = await asyncio.to_thread(_write_workflow, Path(settings.work_dir), workflow)
        return await comfy(["run", "--workflow", path], timeout=120.0)

    @mcp.tool()
    async def job_status(
        prompt_id: Annotated[str, Field(description="prompt_id returned by run_workflow.")],
    ) -> Any:
        """Status and outputs of a queued workflow. Does not load ComfyUI."""
        if not _PROMPT_ID.match(prompt_id):
            raise ToolError("prompt_id has an unexpected format")
        return await comfy(["jobs", "status", prompt_id], needs_comfyui=False)

    @mcp.tool()
    async def comfyui_status() -> dict[str, Any]:
        """Installed ComfyUI release, available releases, and whether ComfyUI is loaded. Does not load it."""
        manifest, stats = await asyncio.gather(
            asyncio.to_thread(_read_manifest, settings.manifest),
            asyncio.to_thread(comfyui.system_stats, settings),
        )
        releases = await asyncio.to_thread(_release_tags, settings.comfyui_repo_url)
        installed = (manifest or {}).get("comfyui_ref")
        return {
            "installed_ref": installed,
            "latest_release": releases[0] if releases else None,
            "update_available": bool(releases and installed and releases[0] != installed),
            "recent_releases": releases[:10],
            "loaded": stats is not None,
            "system_stats": stats,
            "manifest": manifest,
        }

    @mcp.custom_route("/health", methods=["GET"])
    async def health(request: Request) -> Response:
        return JSONResponse({"status": "ok"})

    return mcp


def create_app(settings: Settings) -> Starlette:
    # DNS-rebinding protection is off on purpose: the server listens on loopback
    # and is reached only through llama-swap, which authenticates the request
    # and forwards the client's original Host header (would be rejected as 421).
    return build_server(settings).streamable_http_app(
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
