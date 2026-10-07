"""Bundle provenance (G-7): which code built a bundle, and whether that code was committed.

Every trained bundle records, in ``manifest.training``:

* ``git_commit``                — ``git rev-parse HEAD`` of the checkout this package runs from (no override:
                                  a copy outside git records ``null``);
* ``source_tree_sha256``        — sha256 over ``relpath\\0sha256(file)\\n`` (sorted) of the files that define
                                  the pipeline: every ``*.py`` / ``*.json`` under ``activity_context/`` (the
                                  package, including ``inertia/label_mappings.json``), ``splits/*.json`` and
                                  ``pyproject.toml``; ``source_tree_files`` = how many;
* ``source_dirty`` / ``source_dirty_paths`` — uncommitted (modified, staged or untracked) changes under the
                                  pipeline sources (:data:`SOURCE_PATHS`);
* ``tools_activity_context_dirty`` / ``dirty_paths`` — any uncommitted change anywhere under
                                  ``Tools/ActivityContext`` (code, tests, docs, eval outputs);
* ``allow_dirty``               — whether ``--allow-dirty`` was given.

:func:`check_provenance` refuses a non-smoke bundle built from a dirty ``Tools/ActivityContext`` (or from a
copy outside git) unless ``allow_dirty``; an allowed dirty bundle is capped at ``evidence_tier_max =
"offline"`` (never served). Train every bundle before evaluating any: evaluations write tracked reports
under ``eval/inertia`` and so dirty the tree.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
from typing import Any, Dict, List, Optional, Tuple

from .subproc import safe_env

TOOLS_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SOURCE_PATHS: Tuple[str, ...] = ("activity_context", "splits", "pyproject.toml")


class ProvenanceError(RuntimeError):
    """The bundle would be built from uncommitted / untracked code."""


def _git(args: List[str], timeout: int = 30) -> Optional[str]:
    try:
        r = subprocess.run(["git", *args], cwd=TOOLS_DIR, capture_output=True, text=True, timeout=timeout,
                           env=safe_env())
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def _source_files(root: str = TOOLS_DIR) -> List[str]:
    out: List[str] = []
    pkg = os.path.join(root, "activity_context")
    for d, dirs, files in os.walk(pkg):
        dirs[:] = sorted(x for x in dirs if x != "__pycache__" and not x.startswith("."))
        for f in files:
            if f.endswith((".py", ".json")):
                out.append(os.path.relpath(os.path.join(d, f), root))
    sp = os.path.join(root, "splits")
    if os.path.isdir(sp):
        out += [os.path.join("splits", f) for f in os.listdir(sp) if f.endswith(".json")]
    if os.path.isfile(os.path.join(root, "pyproject.toml")):
        out.append("pyproject.toml")
    return sorted(p.replace(os.sep, "/") for p in out)


def source_tree_sha256(root: str = TOOLS_DIR) -> Tuple[str, int]:
    h = hashlib.sha256()
    files = _source_files(root)
    for rel in files:
        with open(os.path.join(root, rel), "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        h.update(rel.encode("utf-8") + b"\x00" + digest.encode("ascii") + b"\n")
    return h.hexdigest(), len(files)


def _dirty(paths: Tuple[str, ...]) -> Optional[List[str]]:
    out = _git(["status", "--porcelain=v1", "--untracked-files=all", "--", *paths])
    if out is None:
        return None
    return [ln[3:] for ln in out.splitlines() if ln.strip()]


def provenance_info() -> Dict[str, Any]:
    head = (_git(["rev-parse", "HEAD"], timeout=10) or "").strip() or None
    tree, n = source_tree_sha256()
    src = _dirty(SOURCE_PATHS) if head else None
    tools = _dirty((".",)) if head else None
    return {"git_commit": head, "source_tree_sha256": tree, "source_tree_files": n,
            "source_dirty": None if src is None else bool(src), "source_dirty_paths": (src or [])[:50],
            "tools_activity_context_dirty": None if tools is None else bool(tools), "dirty_paths": (tools or [])[:50],
            # legacy key kept for readers of older manifests: Tools/ActivityContext has uncommitted changes
            "git_dirty": None if tools is None else bool(tools)}


def check_provenance(info: Dict[str, Any], allow_dirty: bool = False) -> str:
    """Bundle tier allowed by the provenance: "shadow" if clean and in git; "offline" if ``allow_dirty``;
    otherwise :class:`ProvenanceError`."""
    dirty = info.get("tools_activity_context_dirty", info.get("source_dirty"))
    clean = info.get("git_commit") is not None and dirty is False and info.get("source_dirty") is not True
    if clean:
        return "shadow"
    if not allow_dirty:
        if info.get("git_commit") is None:
            why = "not a git checkout (no commit)"
        elif dirty is None:
            why = "git status of Tools/ActivityContext could not be read"
        else:
            paths = info.get("dirty_paths") or info.get("source_dirty_paths") or []
            why = f"uncommitted changes under Tools/ActivityContext: {paths[:10]}"
        raise ProvenanceError(f"refusing to build a bundle from a dirty source tree ({why}); commit first, or pass "
                              "--allow-dirty (the bundle is then capped at evidence_tier_max 'offline')")
    return "offline"


__all__ = ["ProvenanceError", "provenance_info", "check_provenance", "source_tree_sha256", "SOURCE_PATHS", "TOOLS_DIR"]
