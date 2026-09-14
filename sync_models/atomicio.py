"""Shared atomic write helper (Decision 24).

Serialize to a temp file in the target directory, re-parse the temp file and
require it to equal the expected data, then ``os.replace`` over the original.
On any failure the temp file is removed and the original is never touched.

No-op detection is the caller's job: callers compare the merged in-memory
data against the parsed on-disk data and only call :func:`atomic_write_text`
when they differ, so a no-op run touches no file at all (byte-identical).
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Callable, TypeVar

from sync_models import MutationError

T = TypeVar("T")


def atomic_write_text(
    path: Path,
    text: str,
    *,
    validate: Callable[[str], object],
    expected: object,
    label: str,
) -> None:
    """Atomically write *text* to *path* after parse-validating the temp file.

    ``validate`` must parse the temp file content (yaml.safe_load /
    json.loads); the result must equal ``expected``. On parse failure or
    mismatch the temp file is removed and :class:`MutationError` is raised
    (the original file is never touched).
    """
    directory = path.parent
    try:
        fd, tmp_name = tempfile.mkstemp(
            dir=directory, prefix=f".{path.name}.", suffix=".tmp"
        )
    except OSError as exc:
        raise MutationError(
            f"{label}: cannot create temp file in {directory} ({exc}) "
            f"— original untouched"
        ) from exc
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        with open(tmp_name, encoding="utf-8") as fh:
            tmp_text = fh.read()
        try:
            parsed = validate(tmp_text)
        except Exception as exc:  # parse error
            raise MutationError(
                f"{label}: temp file validation failed for {path} "
                f"({exc}) — original untouched"
            ) from exc
        if parsed != expected:
            raise MutationError(
                f"{label}: temp file validation failed for {path} "
                f"(parsed content differs from expected) — original untouched"
            )
        os.replace(tmp_name, path)
    except OSError as exc:
        raise MutationError(
            f"{label}: write failed for {path} ({exc}) — original untouched"
        ) from exc
    finally:
        # If os.replace succeeded the temp name no longer exists; on any
        # earlier failure the temp file is removed so none is left behind.
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
