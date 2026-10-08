"""What a serve process actually loaded, measured from the bytes it read (docs/model-integration/activity-authority.md).

Every serve process (HART ``activity_context.serve``, ``inertia.serve``, ``eldernet.serve``) answers ``ping`` with a
flat ``loaded`` map of strings — the sha256 of every artifact it loaded and of the package code it runs, and its
thread settings — plus ``loaded_digest``, the sha256 of that map's canonical text. The worker keys its answer caches
by these measured digests (never by a version label alone, so changed bytes under a reused label invalidate prior
answers) and reports them in its heartbeat (``meta.lanes[].identity``). Only what is loaded is listed: a model that
failed to load reports no checkpoint digest. A configured path or a version string is never reported as proof.
"""

from __future__ import annotations

import hashlib
import os
from typing import Dict, Mapping, Optional

LOADED_SCHEMA = "activity-loaded-1"
PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
_CODE_SUFFIXES = (".py", ".json")
_code_digest: Optional[str] = None


def file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def code_sha256(package_dir: str = PACKAGE_DIR) -> str:
    """sha256 over every ``.py`` / ``.json`` file of the package (relative path, NUL, file sha256, newline, in path
    order), so any code change — preprocessing, a head's math, a label map — changes the identity even when no
    version string moved. Computed once per process for the installed package."""
    global _code_digest
    if package_dir == PACKAGE_DIR and _code_digest is not None:
        return _code_digest
    entries = []
    for root, dirs, files in os.walk(package_dir):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for name in files:
            if name.endswith(_CODE_SUFFIXES):
                path = os.path.join(root, name)
                entries.append((os.path.relpath(path, package_dir).replace(os.sep, "/"), path))
    h = hashlib.sha256()
    for rel, path in sorted(entries):
        h.update(f"{rel}\0{file_sha256(path)}\n".encode("utf-8"))
    digest = h.hexdigest()
    if package_dir == PACKAGE_DIR:
        _code_digest = digest
    return digest


def loaded_digest(loaded: Mapping[str, str]) -> str:
    """sha256 of ``activity-loaded-1\\n`` then ``key=value\\n`` per entry in key order (the worker computes the same
    text: ``ActivityPythonService.loadedDigest``)."""
    text = LOADED_SCHEMA + "\n" + "".join(f"{k}={loaded[k]}\n" for k in sorted(loaded))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def base_loaded(threads: Optional[int]) -> Dict[str, str]:
    """The entries every serve process reports: the schema, the code digest and the thread settings it runs with."""
    out = {"schema": LOADED_SCHEMA, "code_sha256": code_sha256()}
    if threads is not None:
        out["threads"] = str(int(threads))
    for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
        value = os.environ.get(key)
        if value:
            out[f"env.{key}"] = value
    return out


def configure_torch_threads(threads: Optional[int]) -> Optional[int]:
    """Cap torch's intra-op threads at ``threads`` and its inter-op pool at one, before any model runs. Every activity
    child shares the scoring worker's cgroup, so none may spin a thread per core. Returns the intra-op count torch
    reports, or None when torch is not importable (the numpy-only baseline never imports it)."""
    try:
        import torch
    except Exception:
        return None
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass  # already set (or parallel work already started): the intra-op cap below still applies
    if threads is not None and threads > 0:
        torch.set_num_threads(int(threads))
    return int(torch.get_num_threads())


def no_nnpack():
    """``torch.backends.nnpack.flags(enabled=False)`` where this torch build has it, else a no-op. NNPACK's
    convolutions are 24-44x slower than the default path for these small 1-d CNNs on one thread (ElderNet,
    ELDERNET.md §8; the ActiNet harnet30 encoder, activity-authority.md "Resources") at outputs within ~1e-5."""
    import contextlib
    try:
        import torch.backends.nnpack as nnpack
    except ImportError:                    # pragma: no cover - older torch builds
        return contextlib.nullcontext()
    return nnpack.flags(enabled=False)
