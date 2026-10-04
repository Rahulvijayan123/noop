"""Digest checks and artifact location shared by the loader and the fetch tool.

Stdlib only, and deliberately free of any network or h5py code, so that ``model.py`` can verify the
converted weights on every load without importing the download/convert tool (``fetch.py``).
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

_CHUNK = 1 << 20


class FetchError(RuntimeError):
    """Download or conversion problem that is not a digest mismatch."""


class DigestMismatchError(FetchError):
    """A file's sha256 (or size) differs from its pin. The file must not be used."""

    def __init__(self, label: str, expected: str, actual: str):
        super().__init__(f"{label}: sha256 mismatch (expected {expected}, got {actual})")
        self.label = label
        self.expected = expected
        self.actual = actual


def default_artifacts_dir() -> Path:
    override = os.environ.get("NARA_WRIST_CNN_DIR")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[2] / "artifacts" / "wrist_cnn"


def sha256_file(path: os.PathLike | str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(_CHUNK):
            h.update(chunk)
    return h.hexdigest()


def verify_file(path: os.PathLike | str, sha256: str, size: int | None = None, label: str | None = None) -> None:
    """Raise ``DigestMismatchError`` unless ``path`` has exactly the pinned size and sha256."""
    path = Path(path)
    label = label or path.name
    if not sha256:
        raise FetchError(f"{label}: no sha256 pin is configured; refusing to trust the file")
    actual_size = path.stat().st_size
    if size is not None and size > 0 and actual_size != size:
        raise DigestMismatchError(f"{label} (size {actual_size} != pinned {size})", sha256, "size-mismatch")
    actual = sha256_file(path)
    if actual != sha256.lower():
        raise DigestMismatchError(label, sha256, actual)
