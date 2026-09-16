"""Checks a model download before comfy-cli starts it.

comfy-cli already refuses an existing destination, a destination another
download is writing, and unsafe file names. What it cannot do before the
transfer is know the size, so the limits below need their own lookup:

- only Hugging Face ``/resolve/`` file URLs and CivitAI ``/api/download/models/<id>``
- only the known model categories, never a caller-supplied path
- size known up front and below the limit, enough free disk left afterwards
"""

from __future__ import annotations

import json
import re
import shutil
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .settings import Settings

CATEGORIES = (
    "checkpoints",
    "clip_vision",
    "controlnet",
    "diffusion_models",
    "embeddings",
    "loras",
    "text_encoders",
    "upscale_models",
    "vae",
)
HF_HOSTS = ("huggingface.co", "hf.co")
CIVITAI_HOST = "civitai.com"

_HF_RESOLVE = re.compile(r"^/[^/]+/[^/]+/resolve/[^/]+/.+$")
_CIVITAI_DOWNLOAD = re.compile(r"^/api/download/models/(\d+)/?$")
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ +()-]{0,199}$")
_GB = 1024**3


class DownloadRefused(Exception):
    """The download breaks one of the limits; the message says which."""


@dataclass(frozen=True)
class DownloadPlan:
    url: str
    category: str
    filename: str
    size_bytes: int

    @property
    def relative_path(self) -> str:
        return f"models/{self.category}"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep a HEAD on Hugging Face: the redirect goes to a CDN, and the
    Authorization header must not follow it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _hf_size(url: str, token: str | None) -> int:
    request = urllib.request.Request(url, method="HEAD")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        response = opener.open(request, timeout=20)
        status, headers = response.status, response.headers
    except urllib.error.HTTPError as exc:
        status, headers = exc.code, exc.headers
    except OSError as exc:  # URLError and timeouts
        raise DownloadRefused(f"Hugging Face did not answer: {exc}") from None
    if status in (401, 403):
        raise DownloadRefused(
            "Hugging Face refused access — the model is gated or private; put HF_API_TOKEN into the MCP server's .env"
        )
    if status == 404:
        raise DownloadRefused("Hugging Face has no such file (check repo, revision and path)")
    # LFS files answer with a redirect that names the size; small files answer directly.
    size = headers.get("X-Linked-Size") or (headers.get("Content-Length") if status == 200 else None)
    if not size or not str(size).isdigit():
        raise DownloadRefused(f"Hugging Face did not report the file size (HTTP {status})")
    return int(size)


def _civitai_file(url: str, version_id: str, token: str | None) -> tuple[str, int]:
    """Name and size of the file the download URL selects, from the versions API."""
    request = urllib.request.Request(f"https://{CIVITAI_HOST}/api/v1/model-versions/{version_id}")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=20) as resp:
            version = json.load(resp)
    except urllib.error.HTTPError as exc:
        raise DownloadRefused(f"CivitAI answered HTTP {exc.code} for model version {version_id}") from None
    except (OSError, ValueError) as exc:  # URLError, timeouts, invalid JSON
        raise DownloadRefused(f"CivitAI did not answer: {exc}") from None
    files = version.get("files") or []
    if not files:
        raise DownloadRefused(f"CivitAI model version {version_id} has no files")
    query = urllib.parse.urlsplit(url).query
    chosen = None
    if query:
        chosen = next((f for f in files if urllib.parse.urlsplit(f.get("downloadUrl", "")).query == query), None)
    if chosen is None:
        chosen = next((f for f in files if f.get("primary")), files[0])
    size_kb = chosen.get("sizeKB")
    if not isinstance(size_kb, (int, float)) or size_kb <= 0:
        raise DownloadRefused(f"CivitAI did not report the size of model version {version_id}")
    return str(chosen.get("name") or ""), int(size_kb * 1024)


def plan_download(settings: Settings, url: str, category: str, filename: str | None) -> DownloadPlan:
    """Validate source, category and name, and look up the size."""
    if category not in CATEGORIES:
        raise DownloadRefused(f"category must be one of: {', '.join(CATEGORIES)}")
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.username or parts.password:
        raise DownloadRefused("only plain https URLs are allowed")
    host = (parts.hostname or "").lower()

    if host in HF_HOSTS:
        if not _HF_RESOLVE.match(parts.path):
            raise DownloadRefused("Hugging Face URLs must point at a file: https://huggingface.co/<org>/<repo>/resolve/<revision>/<path>")
        name = filename or urllib.parse.unquote(parts.path.rsplit("/", 1)[-1])
        size = _hf_size(url, settings.hf_token)
    elif host == CIVITAI_HOST:
        match = _CIVITAI_DOWNLOAD.match(parts.path)
        if not match:
            raise DownloadRefused("CivitAI URLs must be download links: https://civitai.com/api/download/models/<version-id>")
        api_name, size = _civitai_file(url, match.group(1), settings.civitai_token)
        name = filename or api_name
    else:
        raise DownloadRefused(f"downloads are only allowed from {', '.join(HF_HOSTS)} and {CIVITAI_HOST}")

    if not _SAFE_NAME.match(name or "") or name in (".", ".."):
        raise DownloadRefused(f"not a plain file name: {name!r} — pass filename")
    return DownloadPlan(url=url, category=category, filename=name, size_bytes=size)


def check_capacity(settings: Settings, plan: DownloadPlan) -> None:
    """Refuse an existing file, a file above the limit, or too little free disk."""
    folder = Path(settings.workspace) / plan.relative_path
    if (folder / plan.filename).exists():
        raise DownloadRefused(f"{plan.relative_path}/{plan.filename} already exists")
    if plan.size_bytes > settings.download_max_bytes:
        raise DownloadRefused(
            f"the file has {plan.size_bytes / _GB:.1f} GB, the limit is {settings.download_max_bytes / _GB:.0f} GB"
        )
    free = shutil.disk_usage(folder if folder.is_dir() else Path(settings.workspace)).free
    if free - plan.size_bytes < settings.disk_reserve_bytes:
        raise DownloadRefused(
            f"only {free / _GB:.0f} GB free; after this download less than "
            f"{settings.disk_reserve_bytes / _GB:.0f} GB would be left"
        )
