"""MCP server for the ComfyUI that llama-swap manages on this machine.

Runs as the llama-swap model ``comfyui-mcp`` next to ``comfyui_auto`` (see
docs/plans/comfyui-mcp-server.md). It wraps ``comfy-cli`` with ``--json`` and
talks to ComfyUI on its fixed local port. llama-swap authenticates every client
request before it reaches this process, so the server has no auth of its own
and listens on loopback only.

No module performs I/O at import time.
"""
