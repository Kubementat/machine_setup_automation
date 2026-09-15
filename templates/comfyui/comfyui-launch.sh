#!/usr/bin/env bash
# Managed by tasks/setup-comfyui.sh — re-run the task instead of editing this.
#
# Starts ComfyUI with the flags configured for this machine. Arguments given
# to this script are appended, so a supervisor can override a flag such as
# --port (ComfyUI's argparse keeps the last occurrence).
#
# Deliberately NOT set:
#   --gpu-only        disables DynamicVRAM, the allocator you want on unified memory
#   --disable-mmap, --force-fp16 and the global --fp16-* / --bf16-* flags
#   async offload and pinned memory are already on by default on NVIDIA;
#   the only supported knob is opting out (COMFYUI_DISABLE_PINNED_MEMORY)
set -euo pipefail

# The systemd unit runs with ProtectHome=read-only, so every cache that would
# land below $HOME is moved under the service directory.
export XDG_CACHE_HOME="${COMFYUI_DIR}/cache"
export XDG_CONFIG_HOME="${COMFYUI_DIR}/config"
export CUDA_CACHE_PATH="${COMFYUI_DIR}/cache/nv"
export TRITON_CACHE_DIR="${COMFYUI_DIR}/cache/triton"

# Under llama-swap with COMFYUI_MCP=true, every child inherits the MCP server's
# API key. Custom nodes are arbitrary code; they do not get it from here.
unset COMFYUI_MCP_API_KEY

cd "${COMFYUI_APP_DIR}"
# The argument list is substituted as literal text at render time.
# shellcheck disable=SC2086
exec "${COMFYUI_DIR}/.venv/bin/python" main.py ${COMFYUI_LAUNCH_ARGS} "$@"
