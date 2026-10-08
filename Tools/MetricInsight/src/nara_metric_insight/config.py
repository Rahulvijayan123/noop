"""Worker configuration. Environment variables carry names and paths only; secrets are read from files.

Secrets never travel in this process's environment: a same-uid process can read another's environment, and
Prime Agent's model-written code must never see the database URL or the LLM key. With systemd they arrive as
credentials (`LoadCredential=db_url:...`, `LoadCredential=llm_api_key:...` → $CREDENTIALS_DIRECTORY/<name>);
otherwise NARA_DB_URL_FILE / NARA_LLM_API_KEY_FILE name the files. See deploy/metric-insight.env.example.
"""

from __future__ import annotations

import os
import socket
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(RuntimeError):
    pass


def _secret(name: str, file_var: str, env: dict[str, str]) -> str:
    credentials = env.get("CREDENTIALS_DIRECTORY")
    path = Path(credentials) / name if credentials and (Path(credentials) / name).is_file() else None
    if path is None and env.get(file_var):
        path = Path(env[file_var])
    if path is None:
        raise ConfigError(f"{name}: set {file_var} or provide the systemd credential {name!r}")
    try:
        value = path.read_text().strip()
    except OSError as exc:
        raise ConfigError(f"{name}: cannot read {path}: {exc.strerror}") from None
    if not value:
        raise ConfigError(f"{name}: {path} is empty")
    return value


def _remote(raw: str | None) -> tuple[str, ...]:
    if raw is None or not raw.strip():
        return ("pubmed", "europepmc")
    if raw.strip().lower() == "none":
        return ()
    return tuple(s.strip() for s in raw.split(",") if s.strip())


def _paths(raw: str | None) -> tuple[str, ...]:
    return tuple(p for p in (raw or "").split(os.pathsep) if p)


def _choice(env: dict[str, str], name: str, allowed: tuple[str, ...]) -> str | None:
    value = (env.get(name) or "").strip()
    if value and value not in allowed:
        raise ValueError(f"{name} must be one of: {', '.join(allowed)}")
    return value or None


@dataclass(frozen=True)
class Config:
    db_url: str = field(repr=False)
    llm_base_url: str
    llm_model: str
    llm_api_key: str = field(repr=False)
    prime_bin: str
    kernel_python: str
    work_root: str
    worker_id: str
    sandbox: str = "auto"                      # auto | macos | linux | none (tests only, see README)
    sandbox_deny_read: tuple[str, ...] = ()
    curated_harness: str | None = None
    # Peer-reviewed fallback when the curated corpus has no strong hit; NARA_LITERATURE_REMOTE=none turns it off.
    literature_remote: tuple[str, ...] = ("pubmed", "europepmc")
    literature_cache: str | None = None
    lease_seconds: int = 300
    poll_seconds: float = 5.0
    # Background pre-generation: how often an idle worker asks the database to queue the explanations that are
    # missing (0 turns it off) and how many it may queue per ask.
    sweep_seconds: float = 600.0
    sweep_limit: int = 60
    turn_timeout_s: float = 120.0
    max_turns: int = 16
    max_llm_requests: int = 24
    max_completion_tokens: int = 2048
    # Provider quirks (llm_proxy): the token-limit field it requires and a pinned reasoning effort. Unset: as sent.
    llm_max_tokens_field: str | None = None
    llm_reasoning_effort: str | None = None
    secret_paths: tuple[str, ...] = ()

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Config":
        env = dict(os.environ if env is None else env)
        required = {name: env.get(name, "").strip() for name in
                    ("NARA_LLM_BASE_URL", "NARA_LLM_MODEL", "NARA_PRIME_BIN", "NARA_KERNEL_PYTHON", "NARA_WORK_ROOT")}
        missing = [name for name, value in required.items() if not value]
        if missing:
            raise ConfigError("missing settings: " + ", ".join(missing))
        secret_paths = tuple(str(Path(p).resolve().parent) for p in
                             (env.get("NARA_DB_URL_FILE"), env.get("NARA_LLM_API_KEY_FILE"),
                              env.get("CREDENTIALS_DIRECTORY") and Path(env["CREDENTIALS_DIRECTORY"]) / "x") if p)
        return cls(
            db_url=_secret("db_url", "NARA_DB_URL_FILE", env),
            llm_base_url=required["NARA_LLM_BASE_URL"].rstrip("/"),
            llm_model=required["NARA_LLM_MODEL"],
            llm_api_key=_secret("llm_api_key", "NARA_LLM_API_KEY_FILE", env),
            prime_bin=required["NARA_PRIME_BIN"],
            kernel_python=required["NARA_KERNEL_PYTHON"],
            work_root=str(Path(required["NARA_WORK_ROOT"]).resolve()),
            worker_id=env.get("NARA_WORKER_ID") or f"metric-insight@{socket.gethostname()}",
            sandbox=env.get("NARA_SANDBOX", "auto"),
            sandbox_deny_read=_paths(env.get("NARA_SANDBOX_DENY_READ")),
            curated_harness=env.get("NARA_CURATED_HARNESS") or None,
            literature_remote=_remote(env.get("NARA_LITERATURE_REMOTE")),
            # The cache holds only sanitized, user-free queries and public records: one per host is shared.
            literature_cache=env.get("NARA_LITERATURE_CACHE")
            or str(Path(required["NARA_WORK_ROOT"]).resolve().parent / "litsearch.sqlite3"),
            lease_seconds=int(env.get("NARA_LEASE_SECONDS", "300")),
            poll_seconds=float(env.get("NARA_POLL_SECONDS", "5")),
            sweep_seconds=float(env.get("NARA_SWEEP_SECONDS", "600")),
            sweep_limit=int(env.get("NARA_SWEEP_LIMIT", "60")),
            turn_timeout_s=float(env.get("NARA_TURN_TIMEOUT_S", "120")),
            max_turns=int(env.get("NARA_MAX_TURNS", "16")),
            max_llm_requests=int(env.get("NARA_MAX_LLM_REQUESTS", "24")),
            max_completion_tokens=int(env.get("NARA_MAX_COMPLETION_TOKENS", "2048")),
            llm_max_tokens_field=_choice(env, "NARA_LLM_MAX_TOKENS_FIELD", ("max_tokens", "max_completion_tokens")),
            llm_reasoning_effort=_choice(env, "NARA_LLM_REASONING_EFFORT",
                                         ("none", "minimal", "low", "medium", "high", "xhigh")),
            secret_paths=secret_paths,
        )
