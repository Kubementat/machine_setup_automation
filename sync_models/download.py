"""Download orchestration (spec *Behavior 2*).

Per ``download:`` command (document order): a ``--dry-run`` probe (appended
**after** placeholder expansion, Decision 23) is run via ``bash -c`` with
captured output; the line ``[dry-run] Will download N files (out of M)
totalling SIZE.`` is parsed. ``N == 0`` → "already present, skipping" and no
real run. Otherwise (N > 0, unparseable, or probe failure) the real command
runs via ``bash -c`` with merged output streamed line-buffered to the tool's
stdout. Conservative: never skip a download on ambiguity.

Both probe and real run inherit the process environment plus the model's
effective env (catalog values win on conflict, Decision 27).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from sync_models import error, info, warning
from sync_models.catalog import ModelSpec
from sync_models.expand import expand_text

DRY_RUN_RE = re.compile(
    r"\[dry-run\] Will download (\d+) files \(out of (\d+)\) totalling (.+)\.\s*$",
    re.MULTILINE,
)
LOCAL_DIR_RE = re.compile(r"--local-dir\s+(\S+)")
SIZE_RE = re.compile(r"^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)$")

_SIZE_UNITS = {
    "": 1,
    "B": 1,
    "KB": 10**3,
    "MB": 10**6,
    "GB": 10**9,
    "TB": 10**12,
    "KIB": 1024,
    "MIB": 1024**2,
    "GIB": 1024**3,
    "TIB": 1024**4,
}


@dataclass
class CommandResult:
    """Outcome of one download command."""

    model_name: str
    command_index: int  # 1-based
    status: str  # "present" | "downloaded" | "failed"
    detail: str = ""  # e.g. "dry-run exit 3" / "exit 1"


def parse_dry_run(output: str) -> tuple[int, str] | None:
    """First ``[dry-run] Will download ...`` line → (N, size_string) or None."""
    match = DRY_RUN_RE.search(output)
    if not match:
        return None
    return int(match.group(1)), match.group(3).strip()


def parse_size_bytes(size: str) -> int | None:
    """Parse a size string like ``12.5GB`` to bytes; None when unparseable."""
    match = SIZE_RE.match(size.strip())
    if not match:
        return None
    number = float(match.group(1))
    unit = match.group(2).upper()
    if unit not in _SIZE_UNITS:
        return None
    return int(number * _SIZE_UNITS[unit])


def free_space_for(local_dir: str) -> int | None:
    """Free bytes on the file system receiving the download.

    Uses ``shutil.disk_usage`` at the deepest existing ancestor of
    ``local_dir``; None when no ancestor exists.
    """
    path = Path(local_dir).expanduser()
    while not path.exists():
        if path.parent == path:
            return None
        path = path.parent
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return None


def human_size(n: int) -> str:
    """Decimal units, 1 decimal place (e.g. ``12.5GB``)."""
    value = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1000 or unit == "TB":
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1000
    return f"{value:.1f}PB"


def download_model(model: ModelSpec) -> list[CommandResult]:
    """Run all download commands for one model (document order).

    A failing command aborts this model's remaining commands; the caller
    continues with the next model.
    """
    results: list[CommandResult] = []
    variables = model.effective_env or {}
    sub_env = {**os.environ, **variables}  # catalog values win (Decision 27)
    for index, command in enumerate(model.download, start=1):
        expanded = expand_text(command, variables)
        probe = subprocess.run(
            ["bash", "-c", expanded + " --dry-run"],
            env=sub_env,
            capture_output=True,
            text=True,
        )
        probe_output = probe.stdout + probe.stderr
        parsed = parse_dry_run(probe_output)
        if parsed is not None and parsed[0] == 0:
            info(f"{model.name}: already present, skipping")
            results.append(
                CommandResult(model.name, index, "present")
            )
            continue

        # Conservative path: N > 0, unparseable, or probe failure.
        if probe.returncode != 0:
            print(probe_output, end="")
        if parsed is not None:
            count, size = parsed
            info(f"{model.name}: downloading {count} files ({size})")
            _disk_space_warning(model.name, size, expanded)
        else:
            info(f"{model.name}: downloading (dry-run output unparseable)")

        proc = subprocess.Popen(
            ["bash", "-c", expanded],
            env=sub_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")
        rc = proc.wait()
        if rc == 0:
            results.append(CommandResult(model.name, index, "downloaded"))
        else:
            error(
                f"download command failed for {model.name} (exit {rc}): {expanded}"
            )
            results.append(
                CommandResult(model.name, index, "failed", detail=f"exit {rc}")
            )
            break  # abort this model's remaining commands
    return results


def _disk_space_warning(model_name: str, size: str, expanded_cmd: str) -> None:
    """Informational disk-space check (Behavior 2); never a failure."""
    needed = parse_size_bytes(size)
    if needed is None:
        return
    match = LOCAL_DIR_RE.search(expanded_cmd)
    if not match:
        return
    free = free_space_for(match.group(1))
    if free is not None and free < needed:
        warning(
            f"not enough free space for {model_name} "
            f"(need ~{size}, have {human_size(free)})"
        )
