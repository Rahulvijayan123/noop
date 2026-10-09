#!/usr/bin/env python3
"""Package one git revision of the worker, its packages and its sidecars as a release.

    deploy/package-release.sh --out DIR [--rev REV] [--allow-dirty] [--dry-run]
    deploy/package-release.sh verify RELEASE_DIR

The release holds everything the worker build and its tests read, at ONE revision:
``Tools/CloudWorker``, the local packages its ``Package.swift`` reaches (derived, not listed by
hand), the repository files those packages' tests read by path, ``contracts``, ``deploy``,
``Tools/ActivityContext`` and ``Tools/InferenceWorker``, and the licence files. A tree with
uncommitted changes in those paths is refused unless ``--allow-dirty`` is given; the release is
then built from the working tree and stamped ``dirty: true``.

Output in DIR::

    nara-release-<id>.tar.gz          git archive of the paths, under nara-release-<id>/
    nara-release-<id>.tar.gz.sha256   sha256sum line for the tarball
    nara-release-<id>.release.json    a copy of the stamp, readable before extracting
    release-host.sh                   the host-side install/build/switch script, same revision

Inside the tarball, ``RELEASE.files`` lists ``<sha256>  <path>`` for every file (sha256sum
format, so ``sha256sum -c RELEASE.files`` works on the host) and ``RELEASE.json`` is the stamp:
commit, tree, dirty flag, lock and manifest digests, included paths, the digest of
``RELEASE.files``, and per-path tree digests that the running processes compare with what they
measure (docs/model-integration/provisioning.md). ``verify`` re-checks an extracted release.

Standard library only: this runs on the developer's machine and on the host's system python3.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Sequence

STAMP_SCHEMA = "nara-release-stamp/1"
STAMP_NAME = "RELEASE.json"
FILES_NAME = "RELEASE.files"
#: Written on the host by release-host.sh build; never part of the stamped file list.
BUILD_NAME = "BUILD.json"

#: The package the release is built from; its local dependency closure is derived.
ROOT_PACKAGE = "Tools/CloudWorker"
#: Shipped with every release beside the Swift closure (same revision).
EXTRA_PATHS = ("contracts", "deploy", "Tools/ActivityContext", "Tools/InferenceWorker",
               "LICENSE", "NOTICE", "ATTRIBUTION.md")
#: Digests named in the stamp so the host can check them without unpacking.
DIGEST_FILES = {
    "package_resolved_sha256": "Tools/CloudWorker/Package.resolved",
    "uv_lock_sha256": "Tools/InferenceWorker/uv.lock",
    "manifest_sha256": "Tools/InferenceWorker/models/manifest.json",
}
#: Python package sources whose digest the running process compares with its own measurement
#: (frwhoop_inference/identity.py SOURCE_TREE_KEY; the activity child can do the same).
SOURCE_TREES = ("Tools/InferenceWorker/src/frwhoop_inference",
                "Tools/ActivityContext/activity_context")

#: Paths created on the host after extraction; ``verify`` does not report them as extras.
BUILD_OUTPUT_PARTS = (".build", ".venv", "__pycache__", ".swiftpm")

_PACKAGE_PATH = re.compile(r'\.package\s*\(\s*(?:name\s*:\s*"[^"]*"\s*,\s*)?path\s*:\s*"([^"]+)"')
_LINE_COMMENT = re.compile(r"^\s*//.*$", re.MULTILINE)
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
#: A whole string literal that looks like a repository-relative path ("Tools/x/y.json").
_PATH_LITERAL = re.compile(r'"((?:[A-Za-z0-9_.@+-]+/)+[A-Za-z0-9_.@+-]+)"')


class PackagingError(Exception):
    pass


def _utc_now() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _git(repo: str, *args: str, env: dict[str, str] | None = None) -> str:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True,
                          env={**os.environ, **(env or {})})
    if proc.returncode != 0:
        raise PackagingError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def _git_bytes(repo: str, *args: str) -> bytes | None:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    return proc.stdout if proc.returncode == 0 else None


def _tree_has(repo: str, tree: str, path: str) -> bool:
    return subprocess.run(["git", "-C", repo, "cat-file", "-e", f"{tree}:{path}"],
                          capture_output=True).returncode == 0


def _read_blob(repo: str, tree: str, path: str) -> bytes | None:
    return _git_bytes(repo, "cat-file", "blob", f"{tree}:{path}")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------------------
# What goes into the release
# --------------------------------------------------------------------------


def local_package_closure(repo: str, tree: str, root: str = ROOT_PACKAGE) -> list[dict[str, str]]:
    """Every local package reachable through ``.package(path:)`` from ``root``, in visit order.

    Raises PackagingError when a declared path has no ``Package.swift`` at this revision: such a
    release could only build against whatever an old host still has on disk.
    """
    seen: dict[str, str] = {}
    queue = [(root, "")]
    while queue:
        package, declared_by = queue.pop(0)
        manifest = _read_blob(repo, tree, f"{package}/Package.swift")
        if manifest is None:
            if declared_by:
                raise PackagingError(f"local dependency {package} (declared by {declared_by}/"
                                     f"Package.swift) has no Package.swift at this revision")
            raise PackagingError(f"{package}/Package.swift is missing at this revision")
        if package != root:
            seen[package] = declared_by
        text = _BLOCK_COMMENT.sub("", manifest.decode("utf-8"))
        text = _LINE_COMMENT.sub("", text)
        for relative in _PACKAGE_PATH.findall(text):
            dependency = posixpath.normpath(posixpath.join(package, relative))
            if dependency.startswith("../") or dependency == "..":
                raise PackagingError(f"{package}/Package.swift reaches outside the repository: "
                                     f"{relative}")
            if dependency not in seen and dependency != root:
                seen.setdefault(dependency, package)
                queue.append((dependency, package))
    return [{"path": path, "declared_by": by} for path, by in seen.items()]


def test_fixture_paths(repo: str, tree: str, packages: Iterable[str],
                       covered: Sequence[str]) -> tuple[list[str], list[str]]:
    """Repository paths the packages' tests read through ``#filePath``-relative literals.

    Returns (paths to include, literals that name a top-level directory but do not exist). Only
    whole string literals are considered, and only those whose first component is a top-level
    entry of the repository, so "application/json" and test-local "Resources/x" never match.
    """
    top_level = set(_git(repo, "ls-tree", "--name-only", tree).split())
    found: set[str] = set()
    unresolved: set[str] = set()
    for package in packages:
        listing = _git(repo, "ls-tree", "-r", "--name-only", tree, "--", f"{package}/Tests")
        for path in listing.splitlines():
            if not path.endswith(".swift"):
                continue
            blob = _read_blob(repo, tree, path) or b""
            for literal in _PATH_LITERAL.findall(blob.decode("utf-8", errors="replace")):
                if literal.split("/", 1)[0] not in top_level or _covered(literal, covered):
                    continue
                if _tree_has(repo, tree, literal):
                    found.add(literal)
                else:
                    unresolved.add(literal)
    return sorted(_minimal(found)), sorted(unresolved)


def _covered(path: str, roots: Iterable[str]) -> bool:
    return any(path == root or path.startswith(root + "/") for root in roots)


def _minimal(paths: Iterable[str]) -> list[str]:
    out: list[str] = []
    for path in sorted(set(paths)):
        if not _covered(path, out):
            out.append(path)
    return out


@dataclass
class Source:
    commit: str
    tree: str
    dirty: bool

    @property
    def release_id(self) -> str:
        return self.commit if not self.dirty else f"{self.commit}-dirty-{self.tree[:12]}"


def _release_paths(repo: str, tree: str) -> dict[str, object]:
    closure = local_package_closure(repo, tree)
    packages = [ROOT_PACKAGE] + [p["path"] for p in closure]
    base = _minimal(packages + list(EXTRA_PATHS))
    for path in base:
        if not _tree_has(repo, tree, path):
            raise PackagingError(f"{path} is missing at this revision")
    fixtures, unresolved = test_fixture_paths(repo, tree, packages, base)
    return {"closure": closure, "paths": _minimal(base + fixtures), "fixtures": fixtures,
            "unresolved": unresolved}


def resolve_source(repo: str, rev: str | None, allow_dirty: bool) -> tuple[Source, dict[str, object]]:
    """The revision to package and its paths; refuses uncommitted changes unless allowed."""
    if rev:
        commit = _git(repo, "rev-parse", "--verify", f"{rev}^{{commit}}").strip()
        tree = _git(repo, "rev-parse", f"{commit}^{{tree}}").strip()
        return Source(commit, tree, False), _release_paths(repo, tree)
    commit = _git(repo, "rev-parse", "--verify", "HEAD^{commit}").strip()
    tree = _git(repo, "rev-parse", f"{commit}^{{tree}}").strip()
    plan = _release_paths(repo, tree)
    status = _git(repo, "status", "--porcelain", "--untracked-files=normal", "--",
                  *plan["paths"])  # type: ignore[arg-type]
    if not status.strip():
        return Source(commit, tree, False), plan
    if not allow_dirty:
        lines = [line for line in status.splitlines() if line.strip()]
        raise PackagingError("uncommitted changes in the release paths (commit them, or pass "
                             "--allow-dirty to stamp the release dirty):\n  "
                             + "\n  ".join(lines[:20]) + ("\n  ..." if len(lines) > 20 else ""))
    # Snapshot the working tree through a throwaway index: the real index, the stash and HEAD
    # are untouched, and the tree id names exactly the bytes that are packaged.
    with tempfile.TemporaryDirectory(prefix="nara-release-index-") as scratch:
        env = {"GIT_INDEX_FILE": os.path.join(scratch, "index")}
        _git(repo, "read-tree", commit, env=env)
        _git(repo, "add", "-A", "--", *plan["paths"], env=env)  # type: ignore[arg-type]
        tree = _git(repo, "write-tree", env=env).strip()
    return Source(commit, tree, True), _release_paths(repo, tree)


# --------------------------------------------------------------------------
# Archive and stamp
# --------------------------------------------------------------------------


def _subtree_digest(lines: Sequence[tuple[str, str]], prefix: str) -> str | None:
    """The identity.tree_sha256 of ``prefix`` computed from the release file list."""
    selected = []
    for path, digest in lines:
        if path == prefix:
            selected.append((posixpath.basename(path), digest))
        elif path.startswith(prefix + "/"):
            relative = path[len(prefix) + 1:]
            parts = relative.split("/")
            if "__pycache__" in parts or relative.endswith(".pyc"):
                continue
            selected.append((relative, digest))
    if not selected:
        return None
    selected.sort(key=lambda item: item[0].encode("utf-8"))
    return _sha256("".join(f"{d}  {p}\n" for p, d in selected).encode("utf-8"))


def build_release(repo: str, out_dir: str, source: Source, plan: dict[str, object]) -> dict[str, object]:
    paths: list[str] = plan["paths"]  # type: ignore[assignment]
    release_id = source.release_id
    prefix = f"nara-release-{release_id}"
    os.makedirs(out_dir, exist_ok=True)
    tarball = os.path.join(out_dir, f"{prefix}.tar.gz")
    partial = tarball + ".part"

    archive = subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", f"--prefix={prefix}/",
                                source.tree, "--", *paths], stdout=subprocess.PIPE)
    files: list[tuple[str, str]] = []
    symlinks: dict[str, str] = {}
    assert archive.stdout is not None
    with tarfile.open(partial, "w:gz", format=tarfile.PAX_FORMAT) as out, \
            tarfile.open(fileobj=archive.stdout, mode="r|") as stream:
        for member in stream:
            name = member.name
            if not name.startswith(prefix + "/") and name != prefix:
                continue
            relative = name[len(prefix) + 1:] if name != prefix else ""
            if "\n" in relative or "\\" in relative:
                raise PackagingError(f"unsupported file name in the release: {relative!r}")
            if member.isfile():
                handle = stream.extractfile(member)
                data = handle.read() if handle else b""
                files.append((relative, _sha256(data)))
                out.addfile(member, io.BytesIO(data))
            else:
                if member.issym():
                    symlinks[relative] = member.linkname
                out.addfile(member)
        if archive.wait() != 0:
            raise PackagingError("git archive failed")
        files.sort(key=lambda item: item[0].encode("utf-8"))
        listed = {path for path, _ in files}
        for package in [ROOT_PACKAGE] + [p["path"] for p in plan["closure"]]:  # type: ignore[index]
            if f"{package}/Package.swift" not in listed:
                raise PackagingError(f"{package}/Package.swift is not in the archive")
        files_text = "".join(f"{digest}  {path}\n" for path, digest in files).encode("utf-8")
        by_path = dict(files)
        stamp = {
            "schema": STAMP_SCHEMA,
            "release_id": release_id,
            "git_commit": source.commit,
            "git_tree": source.tree,
            "dirty": source.dirty,
            "created_at_utc": _utc_now(),
            "tool": {"path": "deploy/package_release.py",
                     "sha256": by_path.get("deploy/package_release.py")},
            "included_paths": paths,
            "local_packages": plan["closure"],
            "test_fixture_paths": plan["fixtures"],
            "unresolved_test_paths": plan["unresolved"],
            **{key: by_path.get(path) for key, path in DIGEST_FILES.items()},
            "files": {"name": FILES_NAME, "count": len(files), "sha256": _sha256(files_text)},
            "symlinks": symlinks,
            "trees": {path: _subtree_digest(files, path)
                      for path in sorted(set(paths) | set(SOURCE_TREES))},
        }
        stamp_text = (json.dumps(stamp, indent=2, sort_keys=True) + "\n").encode("utf-8")
        for name, payload in ((FILES_NAME, files_text), (STAMP_NAME, stamp_text)):
            info = tarfile.TarInfo(f"{prefix}/{name}")
            info.size = len(payload)
            info.mode = 0o644
            info.mtime = int(datetime.now(tz=timezone.utc).timestamp())
            out.addfile(info, io.BytesIO(payload))
    os.replace(partial, tarball)

    with open(tarball, "rb") as handle:
        digest = hashlib.sha256()
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    with open(tarball + ".sha256", "w", encoding="utf-8") as handle:
        handle.write(f"{digest.hexdigest()}  {os.path.basename(tarball)}\n")
    with open(os.path.join(out_dir, f"{prefix}.release.json"), "wb") as handle:
        handle.write(stamp_text)
    host_script = _read_blob(repo, source.tree, "deploy/release-host.sh")
    if host_script is not None:
        script_path = os.path.join(out_dir, "release-host.sh")
        with open(script_path, "wb") as handle:
            handle.write(host_script)
        os.chmod(script_path, 0o755)
    return {"tarball": tarball, "tarball_sha256": digest.hexdigest(), "stamp": stamp}


# --------------------------------------------------------------------------
# Verify an extracted release
# --------------------------------------------------------------------------


def verify_release(root: str) -> tuple[bool, list[str], list[str]]:
    """(ok, problems, extra files) for an extracted release directory."""
    problems: list[str] = []
    try:
        with open(os.path.join(root, STAMP_NAME), "r", encoding="utf-8") as handle:
            stamp = json.load(handle)
        with open(os.path.join(root, FILES_NAME), "rb") as handle:
            files_text = handle.read()
    except (OSError, ValueError) as exc:
        return False, [f"cannot read the stamp: {exc}"], []
    expected = (stamp.get("files") or {}).get("sha256")
    if _sha256(files_text) != expected:
        problems.append(f"{FILES_NAME} digest {_sha256(files_text)} != stamped {expected}")
    listed: set[str] = set()
    for line in files_text.decode("utf-8").splitlines():
        digest, _, path = line.partition("  ")
        listed.add(path)
        full = os.path.join(root, path)
        if not os.path.isfile(full) or os.path.islink(full):
            problems.append(f"missing: {path}")
            continue
        sha = hashlib.sha256()
        with open(full, "rb") as handle:
            for block in iter(lambda: handle.read(1 << 20), b""):
                sha.update(block)
        if sha.hexdigest() != digest:
            problems.append(f"changed: {path}")
    if int((stamp.get("files") or {}).get("count") or -1) != len(listed):
        problems.append("the file count differs from the stamp")
    extras: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in BUILD_OUTPUT_PARTS]
        for name in filenames:
            relative = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if relative in listed or relative in (STAMP_NAME, FILES_NAME, BUILD_NAME):
                continue
            if relative.endswith(".pyc") or relative in stamp.get("symlinks", {}):
                continue
            extras.append(relative)
    return not problems, problems, sorted(extras)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _repo_root() -> str:
    here = os.path.dirname(os.path.realpath(__file__))
    return _git(here, "rev-parse", "--show-toplevel").strip()


def main(argv: Sequence[str]) -> int:
    args_in = list(argv[1:])
    if args_in and args_in[0] == "verify":
        if len(args_in) != 2:
            sys.stderr.write("usage: package-release.sh verify RELEASE_DIR\n")
            return 2
        ok, problems, extras = verify_release(args_in[1])
        for problem in problems[:50]:
            print(f"FAIL {problem}")
        if extras:
            print(f"note: {len(extras)} file(s) not in the release list, e.g. {extras[:5]}")
        print("release verified" if ok else f"release does NOT verify ({len(problems)} problem(s))")
        return 0 if ok else 1

    parser = argparse.ArgumentParser(prog="package-release.sh", description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", required=True, help="directory for the tarball and its stamp")
    parser.add_argument("--rev", default=None, help="package this commit instead of HEAD")
    parser.add_argument("--allow-dirty", action="store_true",
                        help="package uncommitted changes and stamp the release dirty")
    parser.add_argument("--dry-run", action="store_true", help="print the paths, write nothing")
    parser.add_argument("--repo", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(args_in)
    try:
        repo = os.path.realpath(args.repo) if args.repo else _repo_root()
        source, plan = resolve_source(repo, args.rev, args.allow_dirty)
        if args.dry_run:
            print(json.dumps({"release_id": source.release_id, "git_commit": source.commit,
                              "git_tree": source.tree, "dirty": source.dirty, **plan}, indent=2))
            return 0
        result = build_release(repo, os.path.abspath(args.out), source, plan)
    except PackagingError as exc:
        sys.stderr.write(f"package-release: {exc}\n")
        return 1
    stamp = result["stamp"]
    print(f"release {stamp['release_id']}{' (DIRTY)' if stamp['dirty'] else ''}")  # type: ignore[index]
    print(f"  tarball  {result['tarball']}")
    print(f"  sha256   {result['tarball_sha256']}")
    print(f"  files    {stamp['files']['count']}  ({stamp['files']['sha256'][:16]}...)")  # type: ignore[index]
    print(f"  packages {', '.join(p['path'] for p in stamp['local_packages'])}")  # type: ignore[index]
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
