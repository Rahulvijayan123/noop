"""What this sidecar process actually runs, measured rather than claimed.

``GET /healthz`` and ``GET /v1/providers`` carry this block under ``identity``.
Every digest here is computed from bytes on disk by this process; an
environment variable naming a revision is reported only as a claim
(docs/model-integration/README.md, "Runtime identity").

The block puts together what an operator needs to tell whether the code, the
lock, the manifest and the weights in use belong to one release:

* ``source``: a digest over the imported ``frwhoop_inference`` package files,
  measured once when this module is imported (at server startup);
* ``release``: the release stamp written by ``deploy/package_release.py``
  (``RELEASE.json``), found beside the code or through ``FRWHOOP_RELEASE_STAMP``,
  and whether the measured source, ``uv.lock`` and manifest match it;
* ``model_revision``: the selected revision's ``revision.json``
  (``scripts/materialize_model_root.py``);
* ``artifacts``: the startup verification verdict and digest of every artifact;
* ``providers``: readiness, plus what a provider reports it has loaded when it
  implements ``loaded_identity()`` (the warm worker's report, when the server
  publishes one as ``worker_loaded_identity``, wins over this process's copy).

Everything is cached by path, size and mtime, so a request costs a few ``stat``
calls (docs/model-integration/provisioning.md).
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
import stat
from datetime import datetime, timezone
from typing import Any, Mapping

from .artifacts import pinned_model_root
from .contract import CONTRACT_VERSION, PACKAGE_VERSION

#: Version of the ``identity`` block's shape. Members are only ever added.
IDENTITY_SCHEMA = "runtime-identity/1"

#: Release stamp file name and the variable that names it explicitly.
RELEASE_STAMP_NAME = "RELEASE.json"
RELEASE_STAMP_ENV = "FRWHOOP_RELEASE_STAMP"
#: The stamp's ``trees`` key for this package's source (deploy/package_release.py).
SOURCE_TREE_KEY = "Tools/InferenceWorker/src/frwhoop_inference"
#: Directory levels searched above the package for a release stamp.
STAMP_SEARCH_DEPTH = 6
#: Written by scripts/materialize_model_root.py into every staged revision.
REVISION_FILE = "revision.json"

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
        stat_result = os.stat(path)
    except OSError:
        return None
    if not os.path.isfile(path):
        return None
    try:
        return _sha256_cached(os.path.realpath(path), stat_result.st_mtime_ns, stat_result.st_size)
    except OSError:
        return None


def _package_root() -> str:
    """``Tools/InferenceWorker`` (the directory holding ``pyproject.toml``)."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _utc_now() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# Source tree digest (shared definition with deploy/package_release.py)
# --------------------------------------------------------------------------


def tree_lines(root: str) -> list[str]:
    """``"<sha256>  <relative path>\\n"`` for every regular file under ``root``, sorted by path.

    ``__pycache__`` directories and ``*.pyc`` files are left out (the interpreter writes them at
    run time), and so is anything that is not a regular file. ``deploy/package_release.py``
    writes the same lines into ``RELEASE.files``, so a digest over a subtree of the release is
    comparable with this one.
    """
    lines: list[tuple[str, str]] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
        for name in filenames:
            if name.endswith(".pyc"):
                continue
            path = os.path.join(dirpath, name)
            try:
                mode = os.lstat(path).st_mode
            except OSError:
                continue
            if not stat.S_ISREG(mode):
                continue
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            digest = hashlib.sha256()
            with open(path, "rb") as handle:
                for block in iter(lambda: handle.read(_HASH_CHUNK), b""):
                    digest.update(block)
            lines.append((relative, f"{digest.hexdigest()}  {relative}\n"))
    lines.sort(key=lambda item: item[0].encode("utf-8"))
    return [line for _, line in lines]


def tree_sha256(root: str) -> tuple[str, int]:
    """(digest over ``tree_lines(root)``, number of files)."""
    lines = tree_lines(root)
    return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest(), len(lines)


def _measure_source() -> dict[str, Any]:
    package_dir = os.path.dirname(os.path.abspath(__file__))
    try:
        digest, count = tree_sha256(package_dir)
        return {"path": package_dir, "sha256": digest, "files": count,
                "measured_at_utc": _utc_now()}
    except OSError as exc:  # identity must never stop the sidecar from starting
        return {"path": package_dir, "sha256": None, "files": None,
                "measured_at_utc": _utc_now(), "error": str(exc)}


#: Measured when the server imports this module, i.e. at process startup.
_SOURCE = _measure_source()


def source_identity() -> dict[str, Any]:
    """Digest of the ``frwhoop_inference`` files this process imported, measured at startup."""
    return dict(_SOURCE)


# --------------------------------------------------------------------------
# Release stamp and model revision
# --------------------------------------------------------------------------


@functools.lru_cache(maxsize=16)
def _search_stamp(start: str) -> str | None:
    directory = os.path.abspath(start)
    for _ in range(STAMP_SEARCH_DEPTH + 1):
        candidate = os.path.join(directory, RELEASE_STAMP_NAME)
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    return None


def find_release_stamp(start: str, environ: Mapping[str, str]) -> str | None:
    """The release stamp for code at ``start``: ``FRWHOOP_RELEASE_STAMP``, else the nearest
    ``RELEASE.json`` at most ``STAMP_SEARCH_DEPTH`` levels up, else None."""
    explicit = environ.get(RELEASE_STAMP_ENV)
    if explicit:
        return explicit
    return _search_stamp(start)


@functools.lru_cache(maxsize=16)
def _read_json_cached(path: str, mtime_ns: int, size: int) -> tuple[dict[str, Any] | None, str | None]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as exc:
        return None, f"unreadable: {exc}"
    if not isinstance(document, dict):
        return None, "not a JSON object"
    return document, None


def _read_json(path: str) -> tuple[dict[str, Any] | None, str | None]:
    try:
        stat_result = os.stat(path)
    except OSError as exc:
        return None, f"missing: {exc.strerror or exc}"
    return _read_json_cached(os.path.realpath(path), stat_result.st_mtime_ns, stat_result.st_size)


def release_summary(path: str | None) -> dict[str, Any] | None:
    """The stamp's identifying fields plus its measured digest, or None when there is no path."""
    if not path:
        return None
    document, error = _read_json(path)
    if document is None:
        return {"path": path, "error": error}
    trees = document.get("trees") if isinstance(document.get("trees"), dict) else {}
    files = document.get("files") if isinstance(document.get("files"), dict) else {}
    return {
        "path": path,
        "stamp_sha256": file_sha256(path),
        "schema": document.get("schema"),
        "release_id": document.get("release_id"),
        "git_commit": document.get("git_commit"),
        "git_tree": document.get("git_tree"),
        "dirty": document.get("dirty"),
        "created_at_utc": document.get("created_at_utc"),
        "uv_lock_sha256": document.get("uv_lock_sha256"),
        "manifest_sha256": document.get("manifest_sha256"),
        "package_resolved_sha256": document.get("package_resolved_sha256"),
        "files_sha256": files.get("sha256"),
        "source_tree_sha256": trees.get(SOURCE_TREE_KEY),
    }


def model_revision_summary(model_root: str | None) -> dict[str, Any] | None:
    """The selected revision's ``revision.json`` (summary), or None for a root without one."""
    if not model_root:
        return None
    path = os.path.join(model_root, REVISION_FILE)
    if not os.path.isfile(path):
        return None
    document, error = _read_json(path)
    if document is None:
        return {"path": path, "error": error}
    manifest = document.get("manifest") if isinstance(document.get("manifest"), dict) else {}
    staged_by = document.get("staged_by") if isinstance(document.get("staged_by"), dict) else {}
    probe = document.get("probe") if isinstance(document.get("probe"), dict) else {}
    return {
        "path": path,
        "sha256": file_sha256(path),
        "revision_id": document.get("revision_id"),
        "created_at_utc": document.get("created_at_utc"),
        "manifest_sha256": manifest.get("sha256"),
        "staged_by": {k: staged_by.get(k) for k in ("commit", "dirty", "source")},
        "withheld": [w.get("provider_id") for w in document.get("withheld") or []
                     if isinstance(w, dict)],
        "probe_process_ready": probe.get("process_ready"),
    }


def _equal_or_none(a: Any, b: Any) -> bool | None:
    if not a or not b:
        return None
    return str(a).lower() == str(b).lower()


def _bounded_loaded(reported: Any) -> dict[str, str] | None:
    if isinstance(reported, Mapping) and reported:
        return {str(k): str(v)[:200] for k, v in list(reported.items())[:32]}
    return None


def _provider_identity(state: Any, worker_loaded: Any = None) -> dict[str, Any]:
    """Readiness plus what the provider reports it loaded.

    Checkpoints are loaded in the warm infer worker, not in this process, so a report the
    worker sent (``app.worker_loaded_identity``, keyed by provider id) wins over asking this
    process's copy of the provider, which only knows what it can tell without loading."""
    out: dict[str, Any] = {"ready": bool(getattr(state, "ready", False)),
                           "reason": getattr(state, "reason", None)}
    from_worker = _bounded_loaded(worker_loaded)
    if from_worker is not None:
        out["loaded"] = from_worker
        out["loaded_source"] = "worker"
        return out
    loaded = getattr(getattr(state, "provider", None), "loaded_identity", None)
    if callable(loaded):
        try:
            reported = _bounded_loaded(loaded())
            if reported is not None:
                out["loaded"] = reported
                out["loaded_source"] = "process"
        except Exception as exc:  # a provider's report must never break the health route
            out["loaded"] = {"error": f"{type(exc).__name__}: {exc}"[:200]}
            out["loaded_source"] = "process"
    return out


def runtime_identity(app: Any) -> dict[str, Any]:
    """The identity block for ``app`` (a ``server.Application``)."""
    manifest = app.manifest
    root = manifest.model_root
    pinned = pinned_model_root()
    manifest_sha = file_sha256(manifest.path)
    uv_lock_sha = file_sha256(os.path.join(_package_root(), "uv.lock"))
    release = release_summary(find_release_stamp(_package_root(), os.environ))
    source = source_identity()
    revision = model_revision_summary(root)
    stamp = release if release and not release.get("error") else None
    worker_loaded = getattr(app, "worker_loaded_identity", None)
    if not isinstance(worker_loaded, Mapping):
        worker_loaded = {}
    return {
        "schema": IDENTITY_SCHEMA,
        "package_version": PACKAGE_VERSION,
        "contract_version": CONTRACT_VERSION,
        "claimed_source_revision": os.environ.get("FRWHOOP_SOURCE_REVISION") or None,
        "code_revision": {
            "commit": stamp.get("git_commit") if stamp else None,
            "dirty": stamp.get("dirty") if stamp else None,
            "source_matches_release": _equal_or_none(source.get("sha256"),
                                                     stamp.get("source_tree_sha256") if stamp else None),
            "uv_lock_matches_release": _equal_or_none(uv_lock_sha,
                                                      stamp.get("uv_lock_sha256") if stamp else None),
        },
        "source": source,
        "uv_lock_sha256": uv_lock_sha,
        "release": release,
        "manifest": {
            "path": manifest.path,
            "sha256": manifest_sha,
            "manifest_version": manifest.manifest_version,
            "verified_at_utc": manifest.verified_at_utc,
            "model_root": root,
            "model_root_resolved": os.path.realpath(root) if root else None,
            "configured_model_root": pinned.configured_root if pinned else None,
            "revision": pinned.revision if pinned else None,
            "matches_release": _equal_or_none(manifest_sha,
                                              stamp.get("manifest_sha256") if stamp else None),
            "matches_revision": _equal_or_none(manifest_sha,
                                               revision.get("manifest_sha256") if revision else None),
        },
        "model_revision": revision,
        "artifacts": [
            {"entry_id": c.entry_id, "name": c.artifact_name, "status": c.status,
             "sha256": c.expected_sha256 if c.status == "verified" else None}
            for c in manifest.checks
        ],
        "providers": {pid: _provider_identity(state, worker_loaded.get(pid))
                      for pid, state in getattr(app, "provider_states", {}).items()},
    }
