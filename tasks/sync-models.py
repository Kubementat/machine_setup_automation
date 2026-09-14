#!/usr/bin/env python3
"""sync-models.py — declarative model catalog sync.

Downloads local model weights (hf CLI), additively merges llama-swap model
entries, and wires catalog providers/models into the coding agents' model
configs (pi, opencode). See specification/features/
model-auto-configuration-specification-python/behaviors.md.
"""

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent  # parent of tasks/
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from sync_models.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(repo_root=_REPO_ROOT))
