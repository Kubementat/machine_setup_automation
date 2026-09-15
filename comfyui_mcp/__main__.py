"""Entrypoint: ``python -m comfyui_mcp --listen 127.0.0.1 --port <port>``."""

from __future__ import annotations

import argparse
import sys

import uvicorn

from .server import create_app
from .settings import load_settings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="comfyui-mcp", description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1", help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, required=True, help="port (llama-swap's ${PORT})")
    args = parser.parse_args(argv)
    uvicorn.run(create_app(load_settings()), host=args.listen, port=args.port, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
