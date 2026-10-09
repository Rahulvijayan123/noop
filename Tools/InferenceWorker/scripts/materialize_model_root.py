#!/usr/bin/env python
"""Stage, verify and select the sidecar's model artifact revision (deploy-prep only).

This is the one provisioner for the sidecar's artifact root. ``deploy/provision.sh`` calls it
with the sidecar venv after ``uv sync --frozen``; nothing at inference time ever runs it. It reads
``models/manifest.json`` through ``frwhoop_inference.artifacts`` (``plan_manifest`` decides what
is staged, ``verify_manifest`` is the verifier the sidecar itself runs at startup) and never
parses the manifest on its own.

Layout under the models root (``/opt/frwhoop-models`` in production)::

    revisions/<id>/            one immutable, read-only revision
        manifest.json          the exact manifest bytes it was staged from
        revision.json          what was staged, verified, probed, and by which code revision
        <artifact paths>       the manifest's paths
    current -> revisions/<id>  switched atomically, only after a revision passed every check
    .provision.lock            serialises provisioners

A revision is staged in ``revisions/.staging-*`` (same filesystem, same parent, so the final
rename needs no write permission on the read-only directory), every artifact is materialized
and verified, the sidecar's own ``Application`` is built against the staged root in a child
process with the service's environment, and only then is the revision renamed into place and
``current`` replaced (symlink to a temporary name, then ``os.replace``). A required artifact
that is missing or mismatched, or a required provider that is not ready, rejects the revision:
``current`` is left alone and the staging directory removed. A missing optional artifact is
recorded and withholds only its own provider. The revision id is derived from the manifest
digest and the verified artifact digests, so a re-run with the same manifest and bytes selects
the same revision.

Usage (with the sidecar venv)::

    python scripts/materialize_model_root.py stage --models-root /opt/frwhoop-models \\
        [--manifest M] [--mirror DIR]... [--offline] [--service-unit F] [--service-env F] \\
        [--probe-user U] [--report F]
    python scripts/materialize_model_root.py plan [--manifest M]
    python scripts/materialize_model_root.py list --models-root R
    python scripts/materialize_model_root.py select --models-root R <revision-id>
    python scripts/materialize_model_root.py <dest-root>

The last form is the original one: it materializes the locally available artifacts (the
SleepECG checkpoint from the installed wheel) straight into ``<dest-root>`` with no revision,
for tests and the end-to-end scripts, and prints ``MODEL_ROOT <dest-root>``.

Exit status: 0 selected or unchanged, 1 rejected, 2 usage, 3 another provisioner holds the lock.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.metadata
import importlib.resources
import json
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, BinaryIO, Callable, Iterator, Mapping, Sequence

from frwhoop_inference.artifacts import (
    PlannedArtifact,
    load_manifest,
    plan_manifest,
    required_providers,
    sha256_file,
    verify_manifest,
)

PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_PATH = os.path.join(PACKAGE_ROOT, "models", "manifest.json")
SCRIPT_PATH = os.path.abspath(__file__)

REVISION_SCHEMA = "frwhoop-model-revision/1"
#: Mode of the staging directory until it is sealed 0555: the owner writes, the probe user enters.
STAGING_MODE = 0o755
REVISIONS_DIR = "revisions"
CURRENT_LINK = "current"
LOCK_NAME = ".provision.lock"
STAGING_PREFIX = ".staging-"
REVISION_FILE = "revision.json"
MANIFEST_COPY = "manifest.json"

#: systemd's default PATH for services; the probe gets it unless the unit sets another.
SERVICE_DEFAULT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEFAULT_PROBE_TIMEOUT_S = 600.0
FETCH_TIMEOUT_S = 120.0
FETCH_ATTEMPTS = 2

EXIT_OK, EXIT_REJECTED, EXIT_USAGE, EXIT_BUSY = 0, 1, 2, 3


class FetchError(Exception):
    """A network fetch failed; the artifact is reported missing, never installed."""


class ProvisionBusy(Exception):
    """Another provisioner holds the lock on this models root."""


#: ``fetch(url, out, max_bytes)`` writes the bytes at ``url`` into ``out`` or raises FetchError.
Fetcher = Callable[[str, BinaryIO, int], None]


def _utc_now() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log(message: str) -> None:
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


# --------------------------------------------------------------------------
# Network fetch (production provisioning only; tests inject a fetcher)
# --------------------------------------------------------------------------


def network_fetch(url: str, out: BinaryIO, max_bytes: int, *, timeout_s: float = FETCH_TIMEOUT_S,
                  attempts: int = FETCH_ATTEMPTS) -> None:
    """Download ``url`` into ``out``: https only, bounded size, one retry on a transport error."""
    if not url.startswith("https://"):
        raise FetchError(f"refusing a non-https url: {url}")
    last: Exception | None = None
    for _ in range(max(1, attempts)):
        out.seek(0)
        out.truncate()
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "frwhoop-provision"})
            with urllib.request.urlopen(request, timeout=timeout_s) as response:
                total = 0
                while True:
                    block = response.read(1 << 20)
                    if not block:
                        return
                    total += len(block)
                    if total > max_bytes:
                        # A larger body is never the pinned artifact; do not retry it.
                        raise FetchError(f"{url}: more than the pinned {max_bytes} bytes")
                    out.write(block)
        except FetchError:
            raise
        except (OSError, urllib.error.URLError) as exc:
            last = exc
    raise FetchError(f"{url}: {last}")


# --------------------------------------------------------------------------
# Materialization
# --------------------------------------------------------------------------


def _default_locate_resource(package: str, resource: str) -> str:
    return str(importlib.resources.files(package).joinpath(resource))


def _default_installed_version(package: str) -> str | None:
    try:
        return importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError:
        return None


@dataclass
class MaterializeContext:
    """Where artifact bytes may come from while staging one root."""

    root: str
    #: Directories laid out like an artifact root, tried in order before the network: existing
    #: revisions of this models root, then operator mirrors. Bytes are verified before use.
    local_roots: list[tuple[str, str]] = field(default_factory=list)  # (origin label, path)
    #: None means offline: a url artifact not found locally is reported missing.
    fetcher: Fetcher | None = None
    locate_resource: Callable[[str, str], str] = _default_locate_resource
    installed_version: Callable[[str], str | None] = _default_installed_version


@dataclass
class ArtifactResult:
    planned: PlannedArtifact
    status: str
    sha256: str | None = None
    size_bytes: int | None = None
    origin: str | None = None
    detail: str | None = None

    def to_wire(self) -> dict[str, Any]:
        p = self.planned
        return {
            "entry_id": p.entry_id,
            "name": p.name,
            "path": p.path,
            "provider_id": p.provider_id,
            "source_kind": p.source_kind,
            "action": p.action,
            "required_for_readiness": p.required_for_readiness,
            "status": self.status,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
            "origin": self.origin,
            "detail": self.detail if self.detail is not None else (
                p.reason if p.action in ("skip", "record") else None),
        }


def _install(ctx: MaterializeContext, planned: PlannedArtifact, origin: str,
             writer: Callable[[BinaryIO], None]) -> ArtifactResult:
    """Write the bytes to a temporary file, verify size and sha256, and only then rename."""
    dest = os.path.join(ctx.root, planned.path or "")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    partial = dest + ".part"
    try:
        with open(partial, "wb") as handle:
            writer(handle)
    except Exception as exc:  # any source failure leaves nothing installed
        with contextlib.suppress(OSError):
            os.unlink(partial)
        return ArtifactResult(planned, "missing", origin=origin, detail=f"{origin}: {exc}")
    size = os.path.getsize(partial)
    if planned.size_bytes is not None and size != planned.size_bytes:
        os.unlink(partial)
        return ArtifactResult(planned, "size_mismatch", origin=origin,
                              detail=f"{origin}: {size} bytes, pinned {planned.size_bytes}")
    digest = sha256_file(partial)
    if digest.lower() != str(planned.sha256).lower():
        os.unlink(partial)
        return ArtifactResult(planned, "sha256_mismatch", origin=origin,
                              detail=f"{origin}: sha256 {digest} != pinned {planned.sha256}")
    os.replace(partial, dest)
    return ArtifactResult(planned, "verified", sha256=digest, size_bytes=size, origin=origin)


def _copy_writer(source: str) -> Callable[[BinaryIO], None]:
    def write(handle: BinaryIO) -> None:
        with open(source, "rb") as src:
            shutil.copyfileobj(src, handle, 1 << 20)
    return write


def _stage_url(ctx: MaterializeContext, planned: PlannedArtifact, url: str) -> ArtifactResult:
    tried: list[str] = []
    for label, local_root in ctx.local_roots:
        candidate = os.path.join(local_root, planned.path or "")
        if not os.path.isfile(candidate):
            continue
        if planned.size_bytes is not None and os.path.getsize(candidate) != planned.size_bytes:
            tried.append(f"{label}: size differs")
            continue
        result = _install(ctx, planned, label, _copy_writer(candidate))
        if result.status == "verified":
            return result
        tried.append(result.detail or result.status)
    if ctx.fetcher is None:
        detail = "offline: not found in any local source"
        if tried:
            detail += " (" + "; ".join(tried) + ")"
        return ArtifactResult(planned, "missing", origin=None, detail=detail)
    fetcher = ctx.fetcher
    max_bytes = planned.size_bytes if planned.size_bytes is not None else 0
    result = _install(ctx, planned, "network", lambda handle: fetcher(url, handle, max_bytes))
    if tried and result.status != "verified":
        result.detail = (result.detail or "") + " (local: " + "; ".join(tried) + ")"
    return result


def _stage_wheel_resource(ctx: MaterializeContext, planned: PlannedArtifact) -> ArtifactResult:
    source = planned.source
    package = str(source.get("package") or "")
    resource = str(source.get("resource") or "")
    pinned_version = source.get("version")
    if pinned_version:
        installed = ctx.installed_version(package)
        if installed != str(pinned_version):
            return ArtifactResult(planned, "missing", origin=f"wheel:{package}",
                                  detail=f"installed {package} {installed} != pinned {pinned_version}")
    try:
        path = ctx.locate_resource(package, resource)
    except Exception as exc:  # the distribution is not importable
        return ArtifactResult(planned, "missing", origin=f"wheel:{package}",
                              detail=f"{package} is not importable: {exc}")
    if not os.path.isfile(path):
        return ArtifactResult(planned, "missing", origin=f"wheel:{package}",
                              detail=f"the installed {package} has no {resource}")
    return _install(ctx, planned, f"wheel:{package}/{resource}", _copy_writer(path))


def _stage_zip_member(ctx: MaterializeContext, planned: PlannedArtifact,
                      container: ArtifactResult | None) -> ArtifactResult:
    source = planned.source
    container_name = str(source.get("artifact") or "")
    member = str(source.get("member") or "")
    origin = f"zip:{container_name}!{member}"
    if container is None or container.status != "verified":
        return ArtifactResult(planned, "missing", origin=origin,
                              detail=f"container {container_name} was not staged and verified")
    archive_path = os.path.join(ctx.root, container.planned.path or "")
    try:
        with zipfile.ZipFile(archive_path) as archive:
            info = archive.getinfo(member)
            if planned.size_bytes is not None and info.file_size != planned.size_bytes:
                return ArtifactResult(planned, "size_mismatch", origin=origin,
                                      detail=f"member is {info.file_size} bytes, pinned "
                                             f"{planned.size_bytes}")

            def write(handle: BinaryIO) -> None:
                with archive.open(info) as src:
                    shutil.copyfileobj(src, handle, 1 << 20)

            return _install(ctx, planned, origin, write)
    except (KeyError, zipfile.BadZipFile, OSError) as exc:
        return ArtifactResult(planned, "missing", origin=origin, detail=f"{origin}: {exc}")


def materialize(plan: Sequence[PlannedArtifact], ctx: MaterializeContext) -> list[ArtifactResult]:
    """Materialize every ``stage`` artifact of ``plan`` under ``ctx.root``.

    Containers are staged before the zip members read from them. Nothing is downloaded for an
    artifact the plan skips or records.
    """
    results: dict[int, ArtifactResult] = {}
    by_name: dict[tuple[str, str], ArtifactResult] = {}
    order = sorted(range(len(plan)), key=lambda i: plan[i].source_kind == "zip_member")
    for index in order:
        planned = plan[index]
        if planned.action == "skip":
            result = ArtifactResult(planned, "skipped")
        elif planned.action == "record":
            result = ArtifactResult(planned, "recorded")
        elif planned.action == "check_installed":
            package = str(planned.source.get("package") or "")
            pinned = planned.source.get("version")
            installed = ctx.installed_version(package)
            if installed is None:
                result = ArtifactResult(planned, "not_installed", origin=f"installed:{package}",
                                        detail=f"{package} is not installed")
            elif pinned and installed != str(pinned):
                result = ArtifactResult(planned, "installed_version_mismatch",
                                        origin=f"installed:{package}",
                                        detail=f"installed {installed} != pinned {pinned}")
            else:
                result = ArtifactResult(planned, "installed", origin=f"installed:{package}",
                                        detail=f"{package} {installed}")
        elif not planned.sha256:
            result = ArtifactResult(planned, "no_sha256", detail="no digest published: never fetched")
        elif planned.source_kind == "url":
            result = _stage_url(ctx, planned, planned.url or "")
        elif planned.source_kind == "wheel_resource":
            result = _stage_wheel_resource(ctx, planned)
        elif planned.source_kind == "zip_member":
            container = by_name.get((planned.entry_id, str(planned.source.get("artifact"))))
            result = _stage_zip_member(ctx, planned, container)
        else:
            result = ArtifactResult(planned, "missing", detail=f"cannot stage a {planned.source_kind} source")
        results[index] = result
        by_name[(planned.entry_id, planned.name)] = result
    return [results[i] for i in range(len(plan))]


# --------------------------------------------------------------------------
# Filesystem helpers
# --------------------------------------------------------------------------


def _make_read_only(root: str, *, include_root: bool) -> None:
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                os.chmod(path, 0o444)
    for dirpath, dirnames, _ in os.walk(root, topdown=False):
        for name in dirnames:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                os.chmod(path, 0o555)
    if include_root:
        os.chmod(root, 0o555)


def _force_rmtree(path: str) -> None:
    """Remove a (possibly read-only) staging tree."""
    if not os.path.lexists(path):
        return
    for dirpath, dirnames, _ in os.walk(path):
        with contextlib.suppress(OSError):
            os.chmod(dirpath, 0o755)
        for name in dirnames:
            with contextlib.suppress(OSError):
                os.chmod(os.path.join(dirpath, name), 0o755)
    shutil.rmtree(path, ignore_errors=True)


def _fsync_dir(path: str) -> None:
    with contextlib.suppress(OSError):
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def switch_symlink(link: str, target: str) -> None:
    """Point ``link`` at ``target`` atomically: a new symlink under a temporary name, then rename.

    Readers see either the old target or the new one, never a missing link (``ln -sfn`` unlinks
    first and leaves a window with no link at all).
    """
    parent = os.path.dirname(link)
    temporary = os.path.join(parent, f".{os.path.basename(link)}.tmp-{os.getpid()}-{time.time_ns()}")
    os.symlink(target, temporary)
    try:
        os.replace(temporary, link)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise
    _fsync_dir(parent)


@contextlib.contextmanager
def _locked(models_root: str) -> Iterator[None]:
    path = os.path.join(models_root, LOCK_NAME)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ProvisionBusy(f"another provisioner holds {path}") from exc
        yield
    finally:
        os.close(fd)


def current_revision(models_root: str) -> str | None:
    """The revision id ``current`` selects, or None when nothing is selected yet."""
    link = os.path.join(models_root, CURRENT_LINK)
    if not os.path.islink(link):
        return None
    resolved = os.path.realpath(link)
    if os.path.dirname(resolved) != os.path.realpath(os.path.join(models_root, REVISIONS_DIR)):
        return None
    return os.path.basename(resolved)


# --------------------------------------------------------------------------
# Service environment and readiness probe
# --------------------------------------------------------------------------


def parse_unit_environment(unit_path: str) -> dict[str, str]:
    """The ``Environment=`` assignments of a systemd unit (quoted and multi-assignment forms)."""
    env: dict[str, str] = {}
    with open(unit_path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line.startswith("Environment="):
                continue
            for token in shlex.split(line[len("Environment="):]):
                key, sep, value = token.partition("=")
                if sep and key:
                    env[key] = value
    return env


def parse_environment_file(path: str) -> dict[str, str]:
    """A systemd ``EnvironmentFile=``: ``KEY=VALUE`` lines, ``#``/``;`` comments, optional quotes."""
    env: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith(("#", ";")):
                continue
            key, sep, value = line.partition("=")
            key = key.strip()
            if not sep or not key:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            env[key] = value
    return env


def service_environment(*, unit_path: str | None, env_file: str | None) -> dict[str, str]:
    """The environment the sidecar service starts with (before the model-root overrides)."""
    env = {"PATH": SERVICE_DEFAULT_PATH, "LANG": "C.UTF-8"}
    if unit_path:
        env.update(parse_unit_environment(unit_path))
    if env_file:
        env.update(parse_environment_file(env_file))
    return env


def probe_identity(user: str | None) -> dict[str, Any]:
    """``subprocess.run`` arguments that run the probe as ``user`` with only that user's groups.

    ``user=`` alone keeps the caller's (root's) group and supplementary groups, which can read
    what the service cannot. systemd's ``User=`` gives the service its primary group and the
    user's supplementary groups; the probe gets exactly those."""
    if not user:
        return {}
    import pwd
    entry = pwd.getpwnam(user)
    if entry.pw_uid == os.geteuid() and os.geteuid() != 0:
        return {}  # already that user; changing groups would need privileges it does not have
    return {"user": entry.pw_uid, "group": entry.pw_gid,
            "extra_groups": sorted(set(os.getgrouplist(entry.pw_name, entry.pw_gid)))}


def probe_readiness(root: str, *, service_env: Mapping[str, str], python: str | None = None,
                    user: str | None = None,
                    timeout_s: float = DEFAULT_PROBE_TIMEOUT_S) -> dict[str, Any]:
    """Build the sidecar ``Application`` against ``root`` in a child process and report readiness.

    The child gets the service environment with ``FRWHOOP_MODEL_ROOT``/``FRWHOOP_MANIFEST``
    pointing at ``root``, pins them exactly as ``server.main()`` does, and constructs the same
    registry the service would (the optional providers read their flags and the artifact root
    from that environment). It runs as ``user`` when given (the service user, so a permission
    problem in the revision shows up here) and gets a throwaway ``HOME``.
    """
    home = tempfile.mkdtemp(prefix="frwhoop-probe-")
    out_path = os.path.join(home, "probe.json")
    try:
        env = dict(service_env)
        env["FRWHOOP_MODEL_ROOT"] = root
        env["FRWHOOP_MANIFEST"] = os.path.join(root, MANIFEST_COPY)
        env["HOME"] = home
        if user:
            shutil.chown(home, user=user)
        command = [python or sys.executable, SCRIPT_PATH, "probe", "--out", out_path]
        started = time.monotonic()
        try:
            proc = subprocess.run(command, env=env, cwd=home, capture_output=True, text=True,
                                  timeout=timeout_s, **probe_identity(user))
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": f"readiness probe exceeded {timeout_s:g} s"}
        duration = round(time.monotonic() - started, 3)
        if proc.returncode != 0 or not os.path.isfile(out_path):
            tail = (proc.stderr or "").strip().splitlines()[-5:]
            return {"ok": False, "error": f"readiness probe exited {proc.returncode}",
                    "stderr_tail": tail, "duration_s": duration}
        with open(out_path, "r", encoding="utf-8") as handle:
            result = json.load(handle)
        result["ok"] = True
        result["duration_s"] = duration
        result["user"] = user
        result["flags"] = {k: v for k, v in sorted(env.items())
                           if k.startswith("FRWHOOP_") and k.endswith("_ENABLED")}
        return result
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _probe_child(out_path: str) -> int:
    """Child side of ``probe_readiness``: what the service would report at startup."""
    from frwhoop_inference.artifacts import pin_model_root
    from frwhoop_inference.contract import PACKAGE_VERSION

    pinned = pin_model_root(os.environ)
    from frwhoop_inference.server import Application

    app = Application.build(manifest_path=pinned.resolved_manifest, model_root=pinned.resolved_root)
    document = {
        "process_ready": bool(app.is_ready()),
        "manifest_ok": bool(app.manifest.ok),
        "manifest_reason": app.manifest.reason,
        "providers": {pid: {"ready": bool(s.ready), "reason": s.reason, "version": s.version}
                      for pid, s in app.provider_states.items()},
        "python": sys.version.split()[0],
        "package_version": PACKAGE_VERSION,
    }
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle)
    return 0


# --------------------------------------------------------------------------
# Revisions
# --------------------------------------------------------------------------


def revision_id(manifest_sha256: str, verified: Sequence[tuple[str, str, int]]) -> str:
    """Content id: the manifest digest plus every verified (path, sha256, size)."""
    digest = hashlib.sha256()
    digest.update(f"{REVISION_SCHEMA}\nmanifest {manifest_sha256}\n".encode("utf-8"))
    for path, sha, size in sorted(verified):
        digest.update(f"{path} {sha} {size}\n".encode("utf-8"))
    return "rev-" + digest.hexdigest()[:16]


def code_revision(package_root: str = PACKAGE_ROOT) -> dict[str, Any]:
    """The code revision doing the staging: the release stamp, else git, else unknown."""
    from frwhoop_inference.identity import find_release_stamp, release_summary

    stamp = find_release_stamp(package_root, os.environ)
    if stamp:
        summary = release_summary(stamp)
        if summary and summary.get("git_commit"):
            return {"commit": summary["git_commit"], "dirty": summary.get("dirty"),
                    "source": "release_stamp", "stamp": stamp,
                    "stamp_sha256": summary.get("stamp_sha256")}
    try:
        commit = subprocess.run(["git", "-C", package_root, "rev-parse", "HEAD"], capture_output=True,
                                text=True, timeout=30, check=True).stdout.strip()
        status = subprocess.run(["git", "-C", package_root, "status", "--porcelain", "--", "."],
                                capture_output=True, text=True, timeout=60, check=True).stdout
        return {"commit": commit, "dirty": bool(status.strip()), "source": "git"}
    except (OSError, subprocess.SubprocessError):
        return {"commit": None, "dirty": None, "source": "unknown"}


@dataclass
class StageReport:
    outcome: str                    # selected | unchanged | rejected
    reason: str | None
    models_root: str
    revision_id: str | None = None
    previous: str | None = None
    current: str | None = None
    revision: dict[str, Any] | None = None
    #: This run's readiness probe. A reused revision keeps the probe recorded when it was
    #: created in its revision.json; the fresh one is reported here.
    probe: dict[str, Any] | None = None

    def to_wire(self) -> dict[str, Any]:
        return {"outcome": self.outcome, "reason": self.reason, "models_root": self.models_root,
                "revision_id": self.revision_id, "previous": self.previous,
                "current": self.current, "revision": self.revision, "probe": self.probe}

    @property
    def exit_code(self) -> int:
        return EXIT_OK if self.outcome in ("selected", "unchanged") else EXIT_REJECTED


def _local_revision_roots(revisions: str) -> list[tuple[str, str]]:
    roots: list[tuple[str, str]] = []
    if os.path.isdir(revisions):
        for name in sorted(os.listdir(revisions)):
            path = os.path.join(revisions, name)
            if not name.startswith(".") and os.path.isdir(path) and not os.path.islink(path):
                roots.append((f"revision:{name}", path))
    return roots


def _existing_revision_matches(path: str, manifest: Mapping[str, Any],
                               verified: Mapping[str, str]) -> str | None:
    """None when the revision at ``path`` holds exactly the verified bytes, else why not."""
    if not os.path.isfile(os.path.join(path, REVISION_FILE)):
        return "it has no revision.json"
    state = verify_manifest(manifest, path, manifest_path=os.path.join(path, MANIFEST_COPY))
    actual = {c.path: c.expected_sha256 for c in state.checks if c.status == "verified" and c.path}
    if actual != dict(verified):
        return "its artifacts do not verify against the manifest"
    return None


def stage_revision(
    models_root: str,
    manifest_path: str = MANIFEST_PATH,
    *,
    mirrors: Sequence[str] = (),
    fetcher: Fetcher | None = network_fetch,
    service_env: Mapping[str, str] | None = None,
    probe: Callable[..., dict[str, Any]] = probe_readiness,
    probe_python: str | None = None,
    probe_user: str | None = None,
    probe_timeout_s: float = DEFAULT_PROBE_TIMEOUT_S,
    switch: bool = True,
    code: Mapping[str, Any] | None = None,
    locate_resource: Callable[[str, str], str] = _default_locate_resource,
    installed_version: Callable[[str], str | None] = _default_installed_version,
    log: Callable[[str], None] = _log,
) -> StageReport:
    """Stage, verify and probe one revision, then select it; see the module docstring."""
    models_root = os.path.abspath(models_root)
    revisions = os.path.join(models_root, REVISIONS_DIR)
    current_link = os.path.join(models_root, CURRENT_LINK)
    os.makedirs(revisions, mode=0o755, exist_ok=True)
    if os.path.lexists(current_link) and not os.path.islink(current_link):
        return StageReport("rejected", f"{current_link} exists and is not a symlink; move it aside",
                           models_root)
    with _locked(models_root):
        for name in os.listdir(revisions):
            if name.startswith(STAGING_PREFIX):
                log(f"  removing an interrupted staging directory: {name}")
                _force_rmtree(os.path.join(revisions, name))
        previous = current_revision(models_root)
        try:
            manifest = load_manifest(manifest_path)
            with open(manifest_path, "rb") as handle:
                manifest_bytes = handle.read()
            plan = plan_manifest(manifest)
        except (OSError, ValueError) as exc:
            return StageReport("rejected", f"manifest unusable: {exc}", models_root,
                               previous=previous, current=previous)
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
        staging = tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=revisions)
        # mkdtemp makes it 0700: the probe runs as the service user, which must be able to
        # enter the revision it is asked to prove (owner-writable until it is sealed).
        os.chmod(staging, STAGING_MODE)
        try:
            report = _stage_into(staging, models_root, revisions, manifest, manifest_bytes,
                                 manifest_sha, plan, previous, mirrors=mirrors, fetcher=fetcher,
                                 service_env=service_env, probe=probe, probe_python=probe_python,
                                 probe_user=probe_user, probe_timeout_s=probe_timeout_s,
                                 switch=switch, code=code, locate_resource=locate_resource,
                                 installed_version=installed_version, log=log)
        except BaseException:
            _force_rmtree(staging)
            raise
        if os.path.lexists(staging):
            _force_rmtree(staging)
        return report


def _stage_into(staging: str, models_root: str, revisions: str, manifest: Mapping[str, Any],
                manifest_bytes: bytes, manifest_sha: str, plan: Sequence[PlannedArtifact],
                previous: str | None, *, mirrors: Sequence[str], fetcher: Fetcher | None,
                service_env: Mapping[str, str] | None, probe: Callable[..., dict[str, Any]],
                probe_python: str | None, probe_user: str | None, probe_timeout_s: float,
                switch: bool, code: Mapping[str, Any] | None,
                locate_resource: Callable[[str, str], str],
                installed_version: Callable[[str], str | None],
                log: Callable[[str], None]) -> StageReport:
    def rejected(reason: str, revision: dict[str, Any] | None = None) -> StageReport:
        log(f"REJECTED: {reason}")
        log(f"  current is unchanged: {previous or '(nothing selected)'}")
        return StageReport("rejected", reason, models_root, previous=previous, current=previous,
                           revision=revision)

    local_roots = _local_revision_roots(revisions)
    local_roots += [(f"mirror:{os.path.abspath(m)}", os.path.abspath(m)) for m in mirrors]
    ctx = MaterializeContext(root=staging, local_roots=local_roots, fetcher=fetcher,
                             locate_resource=locate_resource, installed_version=installed_version)
    results = materialize(plan, ctx)
    for result in results:
        if result.planned.action in ("stage", "check_installed"):
            log(f"  {result.status:<26} {result.planned.entry_id}/{result.planned.name}"
                + (f"  [{result.origin}]" if result.origin else "")
                + (f"  {result.detail}" if result.detail and result.status != "verified" else ""))
    with open(os.path.join(staging, MANIFEST_COPY), "wb") as handle:
        handle.write(manifest_bytes)

    # The sidecar's own verifier decides; the materializer's verdicts only explain it.
    state = verify_manifest(manifest, staging, manifest_path=os.path.join(staging, MANIFEST_COPY))
    verified = {c.path: c.expected_sha256 for c in state.checks
                if c.status == "verified" and c.path and c.expected_sha256}
    sizes = {c.path: c.actual_size for c in state.checks if c.status == "verified" and c.path}
    rev_id = revision_id(manifest_sha, [(p, s, int(sizes[p] or 0)) for p, s in verified.items()])
    required = required_providers(manifest)
    artifacts = [r.to_wire() for r in results]
    withheld = _withheld(results, required)
    document: dict[str, Any] = {
        "schema": REVISION_SCHEMA,
        "revision_id": rev_id,
        "created_at_utc": _utc_now(),
        "manifest": {
            "sha256": manifest_sha,
            "manifest_version": str(manifest.get("manifest_version", "unknown")),
            "entries": len(manifest.get("entries", [])),
            "artifacts": len(plan),
        },
        "staged_by": {
            **dict(code or code_revision()),
            "materializer_sha256": sha256_file(SCRIPT_PATH),
            "python": sys.version.split()[0],
        },
        "artifacts": artifacts,
        "verification": {
            "ok": state.ok,
            "reason": state.reason,
            "checks": [c.to_wire() for c in state.checks],
        },
        "required_providers": required,
        "withheld": withheld,
    }
    blocking = [c for c in state.checks if c.failed and c.required_for_readiness]
    if blocking:
        return rejected("required artifact failed verification: " + ", ".join(
            f"{c.entry_id}/{c.artifact_name} ({c.status})" for c in blocking), document)

    # The probe reads the final permissions: everything but the top directory is sealed now, and
    # the top directory is traversable by everyone (STAGING_MODE) so the service user can enter it.
    os.chmod(staging, STAGING_MODE)
    for name in os.listdir(staging):
        path = os.path.join(staging, name)
        if os.path.isdir(path) and not os.path.islink(path):
            _make_read_only(path, include_root=True)
        elif not os.path.islink(path):
            os.chmod(path, 0o444)
    env = dict(service_env) if service_env is not None else service_environment(
        unit_path=None, env_file=None)
    log(f"  probing provider readiness against the staged root (python "
        f"{probe_python or sys.executable}{', user ' + probe_user if probe_user else ''})")
    result = probe(staging, service_env=env, python=probe_python, user=probe_user,
                   timeout_s=probe_timeout_s)
    document["probe"] = result
    if not result.get("ok"):
        return rejected(f"readiness probe failed: {result.get('error')}", document)
    providers = result.get("providers") or {}
    for provider_id, state_doc in sorted(providers.items()):
        log(f"  provider {provider_id}: " + ("ready" if state_doc.get("ready")
                                             else f"NOT ready ({state_doc.get('reason')})"))
    not_ready = [pid for pid in required if not (providers.get(pid) or {}).get("ready")]
    if not_ready:
        return rejected("required provider not ready: " + ", ".join(
            f"{pid} ({(providers.get(pid) or {}).get('reason') or 'not registered'})"
            for pid in not_ready), document)

    with open(os.path.join(staging, REVISION_FILE), "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(os.path.join(staging, REVISION_FILE), 0o444)
    os.chmod(staging, 0o555)

    final = os.path.join(revisions, rev_id)
    if os.path.lexists(final):
        mismatch = _existing_revision_matches(final, manifest, verified)
        if mismatch:
            return rejected(f"revisions/{rev_id} already exists but {mismatch}; move it aside",
                            document)
        log(f"  revisions/{rev_id} already holds these bytes; reusing it")
        with open(os.path.join(final, REVISION_FILE), "r", encoding="utf-8") as handle:
            document = json.load(handle)
    else:
        os.rename(staging, final)
        _fsync_dir(revisions)
    if not switch:
        log(f"STAGED {rev_id} (not selected: --no-switch)")
        return StageReport("unchanged", "not switched (--no-switch)", models_root, rev_id,
                           previous=previous, current=previous, revision=document, probe=result)
    if previous == rev_id:
        log(f"UNCHANGED: current already selects {rev_id}")
        return StageReport("unchanged", None, models_root, rev_id, previous=previous,
                           current=rev_id, revision=document, probe=result)
    switch_symlink(os.path.join(models_root, CURRENT_LINK), os.path.join(REVISIONS_DIR, rev_id))
    log(f"SELECTED {rev_id} (previous: {previous or 'none'})")
    for item in withheld:
        log(f"  withheld (optional): {item['provider_id']} - {item['reason']}")
    return StageReport("selected", None, models_root, rev_id, previous=previous, current=rev_id,
                       revision=document, probe=result)


def _withheld(results: Sequence[ArtifactResult], required: Sequence[str]) -> list[dict[str, Any]]:
    """Optional providers that lose an artifact in this revision (nothing else is affected)."""
    by_provider: dict[tuple[str, str], list[str]] = {}
    for result in results:
        planned = result.planned
        if planned.action != "stage" or result.status == "verified" or planned.required_for_readiness:
            continue
        key = (planned.provider_id or "(none)", planned.entry_id)
        by_provider.setdefault(key, []).append(f"{planned.name} ({result.status})")
    return [{"provider_id": pid, "entry_id": eid, "artifacts": names,
             "required": pid in required,
             "reason": f"optional artifact unavailable: {', '.join(names)}"}
            for (pid, eid), names in sorted(by_provider.items())]


def select_revision(models_root: str, rev_id: str, *, log: Callable[[str], None] = _log) -> StageReport:
    """Point ``current`` at an existing revision after re-verifying it (rollback)."""
    models_root = os.path.abspath(models_root)
    path = os.path.join(models_root, REVISIONS_DIR, rev_id)
    previous = current_revision(models_root)
    if "/" in rev_id or rev_id.startswith(".") or not os.path.isdir(path):
        return StageReport("rejected", f"no revision {rev_id!r} under {models_root}", models_root,
                           previous=previous, current=previous)
    with _locked(models_root):
        try:
            manifest = load_manifest(os.path.join(path, MANIFEST_COPY))
        except (OSError, ValueError) as exc:
            return StageReport("rejected", f"revision manifest unusable: {exc}", models_root,
                               previous=previous, current=previous)
        state = verify_manifest(manifest, path, manifest_path=os.path.join(path, MANIFEST_COPY))
        blocking = [c for c in state.checks if c.failed and c.required_for_readiness]
        if blocking:
            return StageReport("rejected", "required artifact failed verification: " + ", ".join(
                f"{c.entry_id}/{c.artifact_name} ({c.status})" for c in blocking), models_root,
                previous=previous, current=previous)
        if previous == rev_id:
            return StageReport("unchanged", None, models_root, rev_id, previous, rev_id)
        switch_symlink(os.path.join(models_root, CURRENT_LINK), os.path.join(REVISIONS_DIR, rev_id))
        log(f"SELECTED {rev_id} (previous: {previous or 'none'})")
        return StageReport("selected", None, models_root, rev_id, previous, rev_id)


def list_revisions(models_root: str) -> list[dict[str, Any]]:
    models_root = os.path.abspath(models_root)
    current = current_revision(models_root)
    out: list[dict[str, Any]] = []
    for label, path in _local_revision_roots(os.path.join(models_root, REVISIONS_DIR)):
        name = os.path.basename(path)
        row: dict[str, Any] = {"revision_id": name, "current": name == current}
        try:
            with open(os.path.join(path, REVISION_FILE), "r", encoding="utf-8") as handle:
                doc = json.load(handle)
            row.update({"created_at_utc": doc.get("created_at_utc"),
                        "manifest_sha256": (doc.get("manifest") or {}).get("sha256"),
                        "staged_by": (doc.get("staged_by") or {}).get("commit"),
                        "withheld": [w.get("provider_id") for w in doc.get("withheld") or []]})
        except (OSError, ValueError):
            row["legacy"] = True  # a revision staged before revision.json existed
        out.append(row)
    return out


# --------------------------------------------------------------------------
# Original flat mode (tests and the end-to-end scripts)
# --------------------------------------------------------------------------


def materialize_flat(dest: str, manifest_path: str = MANIFEST_PATH) -> int:
    """Materialize the locally available artifacts straight into ``dest`` (offline, no revision)."""
    dest = os.path.abspath(dest)
    manifest = load_manifest(manifest_path)
    plan = plan_manifest(manifest)
    os.makedirs(dest, exist_ok=True)
    results = materialize(plan, MaterializeContext(root=dest, fetcher=None))
    for result in results:
        if result.status == "verified":
            print(f"materialized {result.planned.name} -> "
                  f"{os.path.join(dest, result.planned.path or '')} ({(result.sha256 or '')[:12]}...)")
    state = verify_manifest(manifest, dest, manifest_path=manifest_path)
    if state.ok is not True:
        sys.stderr.write(f"verify_manifest rejected the root: {state.reason}\n")
        return 1
    print(f"MODEL_ROOT {dest}")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="materialize_model_root.py",
                                     description="Stage, verify and select the sidecar model revision.")
    sub = parser.add_subparsers(dest="command", required=True)

    stage = sub.add_parser("stage", help="stage, verify, probe and select a revision")
    stage.add_argument("--models-root", required=True)
    stage.add_argument("--manifest", default=MANIFEST_PATH)
    stage.add_argument("--mirror", action="append", default=[],
                       help="directory laid out like an artifact root, tried before the network")
    stage.add_argument("--offline", action="store_true",
                       help="never use the network; url artifacts come from revisions or mirrors")
    stage.add_argument("--service-unit", default=None,
                       help="systemd unit whose Environment= lines the probe applies")
    stage.add_argument("--service-env", default=None,
                       help="the service's EnvironmentFile (for example /etc/frwhoop/inference.env)")
    stage.add_argument("--probe-python", default=None, help="interpreter for the probe")
    stage.add_argument("--probe-user", default=None, help="run the probe as this (service) user")
    stage.add_argument("--probe-timeout", type=float, default=DEFAULT_PROBE_TIMEOUT_S)
    stage.add_argument("--no-switch", action="store_true", help="stage and verify, leave current")
    stage.add_argument("--report", default=None, help="also write the JSON report here")

    plan = sub.add_parser("plan", help="print what would be staged, recorded or skipped")
    plan.add_argument("--manifest", default=MANIFEST_PATH)

    listing = sub.add_parser("list", help="list the revisions under a models root")
    listing.add_argument("--models-root", required=True)

    select = sub.add_parser("select", help="select an existing revision (rollback)")
    select.add_argument("--models-root", required=True)
    select.add_argument("revision_id")

    probe = sub.add_parser("probe", help=argparse.SUPPRESS)
    probe.add_argument("--out", required=True)
    return parser


def main(argv: Sequence[str]) -> int:
    args_in = list(argv[1:])
    if len(args_in) == 1 and not args_in[0].startswith("-") and args_in[0] not in (
            "stage", "plan", "list", "select", "probe"):
        return materialize_flat(args_in[0])
    args = _build_parser().parse_args(args_in)
    if args.command == "probe":
        return _probe_child(args.out)
    if args.command == "plan":
        manifest = load_manifest(args.manifest)
        planned = plan_manifest(manifest)
        print(json.dumps({"entries": len(manifest.get("entries", [])), "artifacts": len(planned),
                          "plan": [p.to_wire() for p in planned]}, indent=2))
        return EXIT_OK
    if args.command == "list":
        print(json.dumps(list_revisions(args.models_root), indent=2))
        return EXIT_OK
    try:
        if args.command == "select":
            report = select_revision(args.models_root, args.revision_id)
        else:
            env = service_environment(unit_path=args.service_unit, env_file=args.service_env)
            fetcher = None if (args.offline or os.environ.get("FRWHOOP_PROVISION_OFFLINE") == "1") \
                else network_fetch
            report = stage_revision(args.models_root, args.manifest, mirrors=args.mirror,
                                    fetcher=fetcher, service_env=env,
                                    probe_python=args.probe_python, probe_user=args.probe_user,
                                    probe_timeout_s=args.probe_timeout, switch=not args.no_switch)
    except ProvisionBusy as exc:
        sys.stderr.write(f"BUSY: {exc}\n")
        return EXIT_BUSY
    text = json.dumps(report.to_wire(), indent=2, sort_keys=True)
    if getattr(args, "report", None):
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    print(text)
    return report.exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
