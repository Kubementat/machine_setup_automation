"""Catalog resolution, YAML load, and schema validation.

Resolution order (spec *Catalog Resolution*): ``MODELS_YML`` env override →
``<repo root>/models.yml`` → ``<repo root>/models.yml.default``.

Schema validation collects **all** violations and reports them together
(each violation is one :class:`~sync_models.PreflightError` message line,
exit 1). ``import yaml`` is function-local so the entrypoint's PyYAML
pre-flight check fires first with the actionable install message.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

from sync_models import PreflightError

RESERVED_ENV_NAMES = {"PORT", "MODEL_ID", "PID"}
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MODEL_NAME_RE = re.compile(r"^[A-Za-z0-9._/-]+$")

AGENT_DEFAULTS = {
    "contextWindow": 200000,
    "maxTokens": 16000,
    "reasoning": True,
    "input": ["text"],
}
AGENT_FIELDS = (
    "contextWindow",
    "maxTokens",
    "reasoning",
    "input",
    "thinkingLevelMap",
)
TOP_LEVEL_KEYS = {"env", "providers"}
PROVIDER_KEYS = {"name", "baseUrl", "apiKey", "models"}
MODEL_KEYS = {"name", "type", "env", "download", "serve", "agent"}


@dataclass
class EnvEntry:
    """One ``env:`` entry (name/value pair)."""

    name: str
    value: str  # YAML scalar coerced to str


@dataclass
class ModelSpec:
    """One catalog model (normalized, defaults applied)."""

    name: str  # canonical id (charset [A-Za-z0-9._/-])
    type: str  # "local" | "remote"
    provider: "ProviderSpec"  # back-reference to owning provider
    env: list[EnvEntry] = field(default_factory=list)  # per-model env
    download: list[str] = field(default_factory=list)  # non-empty for local
    serve_cmd: str = ""  # non-empty for local
    # Agent metadata with defaults applied (Decision 11):
    context_window: int = AGENT_DEFAULTS["contextWindow"]
    max_tokens: int = AGENT_DEFAULTS["maxTokens"]
    reasoning: bool = AGENT_DEFAULTS["reasoning"]
    input: list[str] = field(default_factory=list)
    # None when absent in the catalog (managed only when present).
    thinking_level_map: dict[str, str | None] | None = None
    # Fully-expanded effective env (top-level + per-model); filled during
    # pre-flight, None until then.
    effective_env: dict[str, str] | None = None

    def __post_init__(self) -> None:
        if not self.input:
            self.input = list(AGENT_DEFAULTS["input"])


@dataclass
class ProviderSpec:
    """One catalog provider (normalized)."""

    name: str
    base_url: str
    api_key: str | None  # None when catalog omits apiKey
    models: list[ModelSpec] = field(default_factory=list)


@dataclass
class Catalog:
    """Normalized catalog with document-order accessors."""

    path: Path
    env: list[EnvEntry]
    providers: list[ProviderSpec]

    def all_models(self) -> list[ModelSpec]:
        """All models in document order (providers[] top→bottom, models[])."""
        return [m for p in self.providers for m in p.models]

    def local_models(self) -> list[ModelSpec]:
        """Local models in document order."""
        return [m for m in self.all_models() if m.type == "local"]


def resolve_catalog_path(repo_root: Path, models_yml_override: str | None) -> Path:
    """Resolve the catalog path per the Catalog Resolution rules.

    Raises :class:`~sync_models.PreflightError` when nothing resolves or the
    ``MODELS_YML`` override does not exist.
    """
    if models_yml_override:
        override = Path(models_yml_override)
        if not override.is_file():
            raise PreflightError(f"catalog file not found: {override} (MODELS_YML)")
        return override
    models_yml = repo_root / "models.yml"
    if models_yml.is_file():
        return models_yml
    models_yml_default = repo_root / "models.yml.default"
    if models_yml_default.is_file():
        return models_yml_default
    raise PreflightError(
        "no model catalog found; tried: "
        f"$MODELS_YML (not set), {models_yml}, {models_yml_default}"
    )


def load_catalog(path: Path) -> dict:
    """Parse the catalog YAML; the top-level result must be a mapping."""
    import yaml  # function-local: entrypoint pre-flight must fire first

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise PreflightError(
            f"catalog is not valid YAML ({path}): {exc}".replace("\n", " ")
        ) from exc
    if not isinstance(data, dict):
        raise PreflightError(f"catalog top-level is not a mapping: {path}")
    return data


def _scalar_to_str(value: object) -> str | None:
    """Coerce a YAML scalar to str; None when not a scalar."""
    if isinstance(value, bool) or isinstance(value, (str, int, float)):
        return str(value)
    return None


def _validate_env_list(
    env: object, context: str
) -> tuple[list[EnvEntry], list[str]]:
    """Validate one env list; returns (entries, violations).

    Rules: list of mappings with exactly keys name/value; name a valid
    identifier; no reserved names; no duplicates within the list; values YAML
    scalars (coerced to str).
    """
    violations: list[str] = []
    entries: list[EnvEntry] = []
    if env is None:
        return entries, violations
    if not isinstance(env, list):
        violations.append(f"{context}: must be a list of name/value entries")
        return entries, violations
    seen: set[str] = set()
    for i, item in enumerate(env):
        if not isinstance(item, dict):
            violations.append(f"{context} [{i}]: entry is not a mapping")
            continue
        if set(item) != {"name", "value"}:
            violations.append(
                f"{context} [{i}]: entry must have exactly keys name/value"
            )
            continue
        name = item["name"]
        value = item["value"]
        if not isinstance(name, str) or not IDENTIFIER_RE.match(name):
            violations.append(f"{context}: name '{name}' is not a valid identifier")
            continue
        if name in RESERVED_ENV_NAMES:
            violations.append(
                f"{context}: name '{name}' is a reserved llama-swap macro"
            )
            continue
        if name in seen:
            violations.append(f"{context}: duplicate name '{name}'")
            continue
        seen.add(name)
        coerced = _scalar_to_str(value)
        if coerced is None:
            violations.append(
                f"{context}: value of '{name}' must be a YAML scalar"
            )
            continue
        entries.append(EnvEntry(name=name, value=coerced))
    return entries, violations


def _validate_agent_block(
    agent: object, where: str
) -> tuple[dict[str, object], list[str]]:
    """Validate the optional ``agent:`` block; applies defaults on success."""
    violations: list[str] = []
    meta: dict[str, object] = {}
    if agent is None:
        meta.update(AGENT_DEFAULTS)
        meta["thinkingLevelMap"] = None
        return meta, violations
    if not isinstance(agent, dict):
        violations.append(f"{where}: agent block is not a mapping")
        return meta, violations
    unknown = set(agent) - set(AGENT_FIELDS)
    for key in sorted(unknown):
        violations.append(f"{where}: unknown agent field '{key}'")
    cw = agent.get("contextWindow", AGENT_DEFAULTS["contextWindow"])
    if not isinstance(cw, int) or isinstance(cw, bool) or cw <= 0:
        violations.append(f"{where}: contextWindow must be a positive integer")
    mt = agent.get("maxTokens", AGENT_DEFAULTS["maxTokens"])
    if not isinstance(mt, int) or isinstance(mt, bool) or mt <= 0:
        violations.append(f"{where}: maxTokens must be a positive integer")
    reasoning = agent.get("reasoning", AGENT_DEFAULTS["reasoning"])
    if not isinstance(reasoning, bool):
        violations.append(f"{where}: reasoning must be a boolean")
    input_list = agent.get("input", AGENT_DEFAULTS["input"])
    if (
        not isinstance(input_list, list)
        or not input_list
        or not all(isinstance(x, str) and x in ("text", "image") for x in input_list)
    ):
        violations.append(
            f"{where}: input must be a non-empty list of 'text'/'image'"
        )
    tlm = agent.get("thinkingLevelMap")
    if tlm is not None:
        if not isinstance(tlm, dict):
            violations.append(f"{where}: thinkingLevelMap must be a mapping")
        else:
            for key, val in tlm.items():
                if not isinstance(key, str) or (val is not None and not isinstance(val, str)):
                    violations.append(
                        f"{where}: thinkingLevelMap value for '{key}' must be a string or null"
                    )
    meta["contextWindow"] = cw
    meta["maxTokens"] = mt
    meta["reasoning"] = reasoning
    meta["input"] = input_list
    meta["thinkingLevelMap"] = tlm
    return meta, violations


def validate_catalog(data: dict, path: Path) -> Catalog:
    """Validate the parsed catalog; returns the normalized Catalog.

    Collects **all** violations; when any exist raises
    :class:`~sync_models.PreflightError` with each violation as its own
    message line.
    """
    violations: list[str] = []

    unknown_top = set(data) - TOP_LEVEL_KEYS
    for key in sorted(unknown_top):
        violations.append(f"unknown top-level catalog key '{key}'")

    # ── top-level env ──
    env_entries, env_violations = _validate_env_list(data.get("env"), "catalog env")
    violations.extend(env_violations)

    # ── providers ──
    providers_raw = data.get("providers")
    if not isinstance(providers_raw, list) or not providers_raw:
        violations.append("providers: missing or empty")
        providers_raw = []

    providers: list[ProviderSpec] = []
    provider_names: set[str] = set()
    local_model_names: dict[str, str] = {}  # name → provider (first occurrence)

    for i, prov in enumerate(providers_raw):
        where = f"provider [{i}]"
        if not isinstance(prov, dict):
            violations.append(f"provider [{i}]: entry is not a mapping")
            continue
        unknown = set(prov) - PROVIDER_KEYS
        for key in sorted(unknown):
            violations.append(f"{where}: unknown provider key '{key}'")

        name = prov.get("name")
        if not isinstance(name, str) or not name:
            violations.append(f"{where}: name must be a non-empty string")
            name = None
        else:
            if name in provider_names:
                violations.append(f"provider [{i}]: duplicate provider name '{name}'")
            provider_names.add(name)

        base_url = prov.get("baseUrl")
        if isinstance(base_url, str):
            parts = urlsplit(base_url)
            if parts.scheme not in ("http", "https") or not parts.hostname:
                violations.append(
                    f"provider '{name}': baseUrl '{base_url}' is not a valid "
                    f"http(s) URL with a host"
                )
                base_url = None
        else:
            violations.append(f"{where}: baseUrl must be a non-empty string")
            base_url = None

        api_key_raw = prov.get("apiKey")
        api_key: str | None = None
        if api_key_raw is not None:
            api_key = _scalar_to_str(api_key_raw)
            if api_key is None:
                violations.append(f"{where}: apiKey must be a YAML scalar")

        models_raw = prov.get("models")
        if not isinstance(models_raw, list) or not models_raw:
            violations.append(f"{where}: models must be a non-empty list")
            models_raw = []

        prov_spec = ProviderSpec(
            name=name or f"<provider-{i}>",
            base_url=base_url or "",
            api_key=api_key,
        )
        providers.append(prov_spec)

        for j, model in enumerate(models_raw):
            mwhere = f"provider '{prov_spec.name}' model [{j}]"
            if not isinstance(model, dict):
                violations.append(f"{mwhere}: entry is not a mapping")
                continue
            unknown = set(model) - MODEL_KEYS
            for key in sorted(unknown):
                violations.append(f"{mwhere}: unknown model key '{key}'")

            mname = model.get("name")
            if not isinstance(mname, str) or not MODEL_NAME_RE.fullmatch(mname):
                violations.append(f"{mwhere}: invalid name '{mname}'")
                mname = None

            mtype = model.get("type")
            if mtype not in ("local", "remote"):
                violations.append(
                    f"{mwhere}: type must be 'local' or 'remote' (got '{mtype}')"
                )

            model_env, menv_violations = _validate_env_list(
                model.get("env"), f"provider '{prov_spec.name}' model '{mname}' env"
            )
            violations.extend(menv_violations)

            download: list[str] = []
            serve_cmd = ""
            if mtype == "local":
                dl = model.get("download")
                if not (
                    isinstance(dl, list)
                    and dl
                    and all(isinstance(c, str) and c for c in dl)
                ):
                    violations.append(
                        f"provider '{prov_spec.name}' model '{mname}': "
                        f"local model requires non-empty download"
                    )
                elif dl:
                    download = list(dl)
                serve = model.get("serve")
                if not (
                    isinstance(serve, dict)
                    and isinstance(serve.get("cmd"), str)
                    and serve.get("cmd")
                ):
                    violations.append(
                        f"provider '{prov_spec.name}' model '{mname}': "
                        f"local model requires non-empty serve.cmd"
                    )
                elif isinstance(serve, dict):
                    serve_cmd = serve["cmd"]
            elif mtype == "remote":
                extra = [k for k in ("download", "serve") if k in model]
                if extra:
                    violations.append(
                        f"provider '{prov_spec.name}' model '{mname}': "
                        f"remote model must not define download/serve"
                    )

            if mtype == "local" and mname:
                if mname in local_model_names:
                    violations.append(
                        f"duplicate local model name '{mname}' "
                        f"(llama-swap models namespace)"
                    )
                else:
                    local_model_names[mname] = prov_spec.name

            mwhere_name = f"provider '{prov_spec.name}' model '{mname}'"
            agent_meta, agent_violations = _validate_agent_block(
                model.get("agent"), mwhere_name
            )
            violations.extend(agent_violations)

            prov_spec.models.append(
                ModelSpec(
                    name=mname or "",
                    type=mtype if mtype in ("local", "remote") else "",
                    provider=prov_spec,
                    env=model_env,
                    download=download,
                    serve_cmd=serve_cmd,
                    context_window=agent_meta["contextWindow"],
                    max_tokens=agent_meta["maxTokens"],
                    reasoning=agent_meta["reasoning"],
                    input=agent_meta["input"],
                    thinking_level_map=agent_meta["thinkingLevelMap"],
                )
            )

    if violations:
        raise PreflightError(*violations)
    return Catalog(path=path, env=env_entries, providers=providers)
