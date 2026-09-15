#!/usr/bin/env bash
# Managed by tasks/setup-comfyui.sh — re-run the task instead of editing this.
#
# Starts the ComfyUI MCP server (COMFYUI_MCP=true) as the llama-swap model
# comfyui-mcp; llama-swap appends --listen and --port. COMFYUI_MCP_API_KEY is
# inherited from llama-swap (EnvironmentFile of its 51-comfyui-mcp.conf drop-in).
set -euo pipefail

# llama-swap.service runs with ProtectHome=read-only and keeps root's HOME;
# comfy-cli stores its config below HOME and ignores XDG_CONFIG_HOME.
export HOME="${COMFYUI_MCP_DIR}/home"
export COMFY_BIN="${COMFYUI_MCP_DIR}/.venv/bin/comfy"
export COMFYUI_WORKSPACE="${COMFYUI_APP_DIR}"
export COMFY_LOCAL_URL="http://127.0.0.1:${COMFYUI_PORT}"
export LLAMA_SWAP_URL="${LS_URL}"
export COMFYUI_MANIFEST="${COMFYUI_MANIFEST}"
export COMFYUI_REPO_URL="${COMFYUI_REPO_URL}"
export COMFYUI_MCP_WORK_DIR="${COMFYUI_MCP_DIR}/work"

cd "${COMFYUI_MCP_DIR}/app"
exec "${COMFYUI_MCP_DIR}/.venv/bin/python" -m comfyui_mcp "$@"
