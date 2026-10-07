"""Subprocess hygiene for the offline tooling (G-20a): explicit environment allowlists and output filters.

Nothing here ever hands the full ``os.environ`` to a child process — the parent environment of a research
machine can hold credentials (database URLs, tokens) that a crashing tool would echo into a log. Children
get :data:`BASE_ENV_ALLOWLIST` (only the variables that are set) plus the explicit extras the caller names.
Child output is filtered before it is logged or raised: :func:`failure_lines` keeps only diagnostic lines
of xctest / swift runs, :func:`redact` masks ``KEY=value`` environment dumps and credential-looking values.
"""

from __future__ import annotations

import os
import re
from typing import Iterable, Mapping, Optional

BASE_ENV_ALLOWLIST = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "DEVELOPER_DIR")
PYTHON_ENV_ALLOWLIST = BASE_ENV_ALLOWLIST + ("PYTHONPATH", "VIRTUAL_ENV", "OMP_NUM_THREADS",
                                             "INERTIA1_CKPT_PATH")


def safe_env(extra: Optional[Mapping[str, str]] = None, allow: Iterable[str] = BASE_ENV_ALLOWLIST) -> dict:
    """A child environment: the allowlisted parent variables that are set, plus ``extra`` (explicit)."""
    env = {k: os.environ[k] for k in allow if k in os.environ}
    for k, v in (extra or {}).items():
        env[str(k)] = str(v)
    return env


_ENV_LINE = re.compile(r"^\s*(export\s+)?[A-Z_][A-Z0-9_]*=")
_SECRET = re.compile(r"(?i)\b(token|secret|password|passwd|api[_-]?key|authorization|bearer|cookie|"
                     r"database_url|db_url|dsn)\b(\s*[:=]\s*|\s+)(\S+)")
_URL_CRED = re.compile(r"([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@", re.I)


def redact(text: str, limit: int = 4000) -> str:
    """Drop ``KEY=value`` lines (environment dumps), mask credential-looking values and URL passwords."""
    keep = []
    for ln in (text or "").splitlines():
        if _ENV_LINE.match(ln):
            continue
        ln = _SECRET.sub(lambda m: f"{m.group(1)}{m.group(2)}<redacted>", ln)
        ln = _URL_CRED.sub(r"\1<redacted>@", ln)
        keep.append(ln)
    out = "\n".join(keep)
    return out[-limit:] if len(out) > limit else out


_FAILURE_KEYS = ("error:", "Fatal error", "failed", "XCTAssert", "Thrown", "caught", "signal", "Restarting",
                 "Swift/", "Killed", "Traceback", "Error", "Exception")


def failure_lines(text: str, limit: int = 1500) -> str:
    """Only the failure lines of a child run (xctest can dump the whole environment on a crash)."""
    keep = [ln for ln in (text or "").splitlines()
            if any(k in ln for k in _FAILURE_KEYS) and "=" not in ln.split(":")[0]]
    out = redact(" | ".join(keep), limit)
    return out[:limit] if out else "(no failure lines; raw output withheld: it may contain the environment)"


__all__ = ["BASE_ENV_ALLOWLIST", "PYTHON_ENV_ALLOWLIST", "safe_env", "redact", "failure_lines"]
