"""Where the offline Inertia pipeline finds data — environment only, no machine-specific defaults.

Nothing under ``activity_context`` hard-codes a local path. The research tree is located by environment
variables (or the matching CLI flags); a path that is needed but not configured fails with a message that
names the variable, it never silently falls back to somebody's disk.

=========================  =====================================================================
``INERTIA_DATA_ROOT``      the research directory; the defaults below are sub-directories of it
``INERTIA_CACHE_DIR``      window/embedding cache          (default ``$INERTIA_DATA_ROOT/inertia-cache``)
``INERTIA_BUNDLES_DIR``    trained head bundles            (default ``$INERTIA_DATA_ROOT/inertia-bundles``)
``INERTIA_HAR_ROOT``       public HAR datasets             (default ``$INERTIA_DATA_ROOT/har-datasets``)
``WISDM_DIR``              WISDM-2019 ``wisdm-dataset`` dir (default ``$INERTIA_HAR_ROOT/wisdm/wisdm-dataset``)
``NARA_REPLAY_DIR``        decoder replay work tree        (default ``$INERTIA_DATA_ROOT/inertia-replay``)
``CAPTURE24_DIR``          Capture-24 parquet mirror       (default ``$INERTIA_HAR_ROOT/capture24/hf_mirror_nz00shuuuu``)
``HART_OUT_DIR``           trained HART head (replay only; no default)
``INERTIA1_UPSTREAM_DIR``  upstream Inertia-1 checkout (vendor parity test only; default
                           ``$INERTIA_DATA_ROOT/inertia1-upstream``)
=========================  =====================================================================

Tests never depend on any of these: data-dependent tests skip when a variable is unset.
"""

from __future__ import annotations

import os
from typing import Optional

DATA_ROOT_ENV = "INERTIA_DATA_ROOT"


class PathNotConfigured(RuntimeError):
    """A data path is needed but neither its variable nor INERTIA_DATA_ROOT is set."""


def _env(name: str) -> str:
    return os.environ.get(name, "").strip()


def under(base: str, *parts: str) -> str:
    """``base/parts`` or "" when ``base`` is unset (unconfigured stays unconfigured)."""
    return os.path.join(base, *parts) if base else ""


def data_root() -> str:
    return _env(DATA_ROOT_ENV)


def env_or_under(name: str, base: str, *parts: str) -> str:
    return _env(name) or under(base, *parts)


def cache_root() -> str:
    return env_or_under("INERTIA_CACHE_DIR", data_root(), "inertia-cache")


def bundles_root() -> str:
    return env_or_under("INERTIA_BUNDLES_DIR", data_root(), "inertia-bundles")


def har_root() -> str:
    return env_or_under("INERTIA_HAR_ROOT", data_root(), "har-datasets")


def wisdm_dir() -> str:
    return env_or_under("WISDM_DIR", har_root(), "wisdm", "wisdm-dataset")


def replay_dir() -> str:
    return env_or_under("NARA_REPLAY_DIR", data_root(), "inertia-replay")


def capture24_dir() -> str:
    return env_or_under("CAPTURE24_DIR", har_root(), "capture24", "hf_mirror_nz00shuuuu")


def upstream_dir() -> str:
    return env_or_under("INERTIA1_UPSTREAM_DIR", data_root(), "inertia1-upstream")


def require_dir(path: Optional[str], what: str) -> str:
    """``path`` if configured (non-empty), else :class:`PathNotConfigured` naming the variable(s)."""
    if not path:
        raise PathNotConfigured(f"{what} is not configured: set the environment variable (or pass the CLI flag)")
    return path


__all__ = ["DATA_ROOT_ENV", "PathNotConfigured", "data_root", "cache_root", "bundles_root", "har_root", "wisdm_dir",
           "replay_dir", "capture24_dir", "upstream_dir", "require_dir", "under", "env_or_under"]
