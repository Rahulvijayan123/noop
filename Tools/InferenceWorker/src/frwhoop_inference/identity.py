"""What this sidecar process actually runs, measured rather than claimed.

``GET /healthz`` and ``GET /v1/providers`` carry this block under ``identity``.
Every digest here is computed from bytes on disk by this process; an
environment variable naming a revision is reported only as a claim
(docs/model-integration/README.md, "Runtime identity").
"""

from __future__ import annotations

import functools
import hashlib
import os
from typing import Any

from .artifacts import pinned_model_root
from .contract import CONTRACT_VERSION, PACKAGE_VERSION

#: Version of the ``identity`` block's shape.
IDENTITY_SCHEMA = "runtime-identity/1"

_HASH_CHUNK = 1024 * 1024


@functools.lru_cache(maxsize=64)
def _sha256_cached(path: str, mtime_ns: int, size: int) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(_HASH_CHUNK)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_sha256(path: str | None) -> str | None:
    """sha256 of ``path``, or None when it is not a readable file."""
    if not path:
        return None
    try:
        stat = os.stat(path)
    except OSError:
        return None
    if not os.path.isfile(path):
        return None
    try:
        return _sha256_cached(os.path.realpath(path), stat.st_mtime_ns, stat.st_size)
    except OSError:
        return None


def _package_root() -> str:
    """``Tools/InferenceWorker`` (the directory holding ``pyproject.toml``)."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def runtime_identity(app: Any) -> dict[str, Any]:
    """The identity block for ``app`` (a ``server.Application``)."""
    manifest = app.manifest
    root = manifest.model_root
    pinned = pinned_model_root()
    return {
        "schema": IDENTITY_SCHEMA,
        "package_version": PACKAGE_VERSION,
        "contract_version": CONTRACT_VERSION,
        "claimed_source_revision": os.environ.get("FRWHOOP_SOURCE_REVISION") or None,
        "uv_lock_sha256": file_sha256(os.path.join(_package_root(), "uv.lock")),
        "manifest": {
            "path": manifest.path,
            "sha256": file_sha256(manifest.path),
            "model_root": root,
            "model_root_resolved": os.path.realpath(root) if root else None,
            "configured_model_root": pinned.configured_root if pinned else None,
            "revision": pinned.revision if pinned else None,
        },
    }
