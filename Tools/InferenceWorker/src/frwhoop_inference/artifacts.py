"""Manifest loading and startup artifact verification.

Spec section 6: "Cache checksum-verified artifacts at deployment preparation
time; normal inference must not download weights or run training. Fail candidate
readiness clearly when an artifact is absent."

This module never downloads anything. It reads ``models/manifest.json``, checks
the sha256 of every artifact marked ``verify_at_startup`` against the bytes in
the artifact root, and reports a per-artifact verdict. Entries marked
``required_for_readiness`` gate the process readiness flag.

An entry marked ``verify_at_startup`` that publishes NO ``sha256`` is a failure
(``no_sha256``), not a by-design skip: without a digest the bytes can never be
verified, so readiness must fail closed (audit DD-4). Only ``verify_at_startup:
false`` entries report the non-blocking ``not_verified`` status.

``plan_manifest`` is the provisioner's reading of the same file: which artifacts
deploy-prep stages, which it only records, and why
(``scripts/materialize_model_root.py``, docs/model-integration/provisioning.md).
"""

from __future__ import annotations

import hashlib
import json
import os
import posixpath
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping

from .contract import CONTRACT_VERSION

DEFAULT_MANIFEST_RELPATH = os.path.join("models", "manifest.json")
DEFAULT_MODEL_ROOT = "/opt/frwhoop-models"

#: Per-artifact verification verdicts.
CHECK_STATUSES = (
    "verified",          # present and the sha256 matches
    "missing",           # not present in the artifact root
    "sha256_mismatch",   # present, wrong bytes
    "size_mismatch",     # present, right hash claimed but the size disagrees
    "not_verified",      # this entry is not verified at startup by design
    "no_sha256",         # no digest published for a verify_at_startup artifact (a failure)
    "invalid_path",      # the declared path is absolute or leaves the artifact root (a failure)
)

#: Machine-readable artifact sources (``artifacts[].source.kind``).
SOURCE_KINDS = (
    "url",                # fetch ``url``; ``sha256`` and ``size_bytes`` are checked before install
    "wheel_resource",     # a file inside an installed distribution: {package, resource, version?}
    "zip_member",         # a member of another artifact of the same entry: {artifact, member}
    "installed_package",  # the distribution itself, installed from uv.lock: {package, version}
    "none",               # no fetchable source; recorded only: {reason}
)

#: Entry statuses whose wired artifacts deploy-prep stages. Every other status
#: (``blocked_license``, ``blocked_input``, ``blocked_artifact``, ``unverified``) is recorded only.
STAGED_ENTRY_STATUSES = ("eligible", "shadow_eligible")

#: What the provisioner does with one artifact.
PLAN_ACTIONS = (
    "stage",            # materialize under the artifact root and verify
    "check_installed",  # confirm the installed distribution version; nothing is copied
    "record",           # recorded in the revision, never staged
    "skip",             # the entry is not staged at all (blocked, unverified or not wired)
)

READ_HASH_CHUNK = 1024 * 1024


@dataclass(frozen=True)
class ArtifactCheck:
    entry_id: str
    artifact_name: str
    path: str | None
    expected_sha256: str | None
    expected_size: int | None
    actual_size: int | None
    status: str
    required_for_readiness: bool
    detail: str | None = None

    @property
    def failed(self) -> bool:
        # ``no_sha256`` is a FAILURE, not a by-design skip: the entry is marked
        # ``verify_at_startup`` but publishes no digest, so the bytes can never be
        # verified and readiness must not depend on them being present. A manifest
        # edited to drop a digest therefore fails closed instead of letting a
        # provider run unverified weights (audit DD-4). Only ``not_verified``
        # (``verify_at_startup: false``) is non-blocking by design.
        return self.status in ("missing", "sha256_mismatch", "size_mismatch", "no_sha256",
                               "invalid_path")

    def to_wire(self) -> dict[str, Any]:
        return {
            "entry_id": self.entry_id,
            "artifact": self.artifact_name,
            "path": self.path,
            "expected_sha256": self.expected_sha256,
            "expected_size": self.expected_size,
            "actual_size": self.actual_size,
            "status": self.status,
            "required_for_readiness": self.required_for_readiness,
            "detail": self.detail,
        }


@dataclass
class ManifestState:
    path: str
    model_root: str
    manifest_version: str
    entries: tuple[Mapping[str, Any], ...]
    checks: tuple[ArtifactCheck, ...]
    ok: bool
    reason: str | None
    verified_at_utc: str
    load_error: str | None = None

    def to_wire(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "model_root": self.model_root,
            "manifest_version": self.manifest_version,
            "verified_at_utc": self.verified_at_utc,
            "ok": self.ok,
            "reason": self.reason,
            "load_error": self.load_error,
            "entries": list(self.entries),
            "checks": [c.to_wire() for c in self.checks],
        }

    def entry(self, entry_id: str) -> Mapping[str, Any] | None:
        for candidate in self.entries:
            if candidate.get("id") == entry_id:
                return candidate
        return None


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(READ_HASH_CHUNK)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _utc_now() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_manifest(path: str) -> Mapping[str, Any]:
    """Load and shape-check the manifest. Raises ``ValueError`` on a bad file."""
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, Mapping):
        raise ValueError("manifest root must be an object")
    entries = data.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("manifest.entries must be a non-empty array")
    for index, entry in enumerate(entries):
        if not isinstance(entry, Mapping):
            raise ValueError(f"manifest.entries[{index}] must be an object")
        if not isinstance(entry.get("id"), str) or not entry.get("id"):
            raise ValueError(f"manifest.entries[{index}].id must be a non-empty string")
    return data


def verify_manifest(
    manifest: Mapping[str, Any],
    model_root: str,
    *,
    manifest_path: str = "",
    now: str | None = None,
) -> ManifestState:
    """Verify every artifact marked ``verify_at_startup`` against ``model_root``."""
    checks: list[ArtifactCheck] = []
    for entry in manifest.get("entries", []):
        entry_id = str(entry.get("id"))
        required = bool(entry.get("required_for_readiness", False))
        for artifact in entry.get("artifacts", []) or []:
            name = str(artifact.get("name") or artifact.get("path") or "artifact")
            rel_path = artifact.get("path")
            expected_sha = artifact.get("sha256")
            expected_size = artifact.get("size_bytes")
            if not artifact.get("verify_at_startup", False):
                checks.append(ArtifactCheck(entry_id, name, rel_path, expected_sha, expected_size,
                                            None, "not_verified", required,
                                            "entry is not verified at startup by design"))
                continue
            if not expected_sha:
                checks.append(ArtifactCheck(entry_id, name, rel_path, None, expected_size, None,
                                            "no_sha256", required, "no digest published"))
                continue
            if not rel_path:
                checks.append(ArtifactCheck(entry_id, name, None, expected_sha, expected_size, None,
                                            "missing", required, "artifact path is not declared"))
                continue
            if safe_relative_path(rel_path) is None:
                # os.path.join would otherwise hash a file outside the root for "/x" or "../x".
                checks.append(ArtifactCheck(entry_id, name, rel_path, expected_sha, expected_size,
                                            None, "invalid_path", required,
                                            "artifact path is absolute or leaves the artifact root"))
                continue
            absolute = os.path.join(model_root, rel_path)
            if not os.path.isfile(absolute):
                checks.append(ArtifactCheck(entry_id, name, rel_path, expected_sha, expected_size,
                                            None, "missing", required,
                                            f"not present under {model_root}"))
                continue
            actual_size = os.path.getsize(absolute)
            if expected_size is not None and int(expected_size) != actual_size:
                checks.append(ArtifactCheck(entry_id, name, rel_path, expected_sha,
                                            int(expected_size), actual_size, "size_mismatch", required,
                                            "cached size differs from the manifest"))
                continue
            actual_sha = sha256_file(absolute)
            if actual_sha.lower() != str(expected_sha).lower():
                checks.append(ArtifactCheck(entry_id, name, rel_path, expected_sha,
                                            expected_size, actual_size, "sha256_mismatch", required,
                                            f"cached sha256 {actual_sha} != manifest"))
                continue
            checks.append(ArtifactCheck(entry_id, name, rel_path, expected_sha, expected_size,
                                        actual_size, "verified", required, None))

    failed = [c for c in checks if c.failed]
    blocking = [c for c in failed if c.required_for_readiness]
    ok = not blocking
    reason = None
    if blocking:
        reason = "blocked_artifact: " + ", ".join(f"{c.entry_id}/{c.artifact_name} ({c.status})"
                                                  for c in blocking)
    elif failed:
        reason = ("optional artifacts failed verification: "
                  + ", ".join(f"{c.entry_id}/{c.artifact_name} ({c.status})" for c in failed))
    return ManifestState(
        path=manifest_path,
        model_root=model_root,
        manifest_version=str(manifest.get("manifest_version", "unknown")),
        entries=tuple(manifest.get("entries", [])),
        checks=tuple(checks),
        ok=ok,
        reason=reason,
        verified_at_utc=now or _utc_now(),
    )


def manifest_summary(state: ManifestState) -> list[dict[str, Any]]:
    """Capability-facing summary of the manifest entries (models, not providers)."""
    out: list[dict[str, Any]] = []
    for entry in state.entries:
        out.append({
            "id": entry.get("id"),
            "kind": entry.get("kind"),
            "name": entry.get("name"),
            "revision": entry.get("revision"),
            "license": entry.get("license"),
            "rights_verdict": entry.get("rights_verdict"),
            "status": entry.get("status"),
            "status_reason": entry.get("status_reason"),
            "provider_id": entry.get("provider_id"),
            "input_contract": entry.get("input_contract"),
            "wired": bool(entry.get("wired", False)),
            "artifacts": [
                {
                    "name": a.get("name"),
                    "path": a.get("path"),
                    "url": a.get("url"),
                    "source": artifact_source(a),
                    "size_bytes": a.get("size_bytes"),
                    "sha256": a.get("sha256"),
                }
                for a in (entry.get("artifacts") or [])
            ],
        })
    return out


# --------------------------------------------------------------------------
# Provisioning plan (deploy-prep only; the sidecar never fetches anything)
# --------------------------------------------------------------------------


def safe_relative_path(path: Any) -> str | None:
    """``path`` as a normalised POSIX path inside the artifact root, or None when it is unsafe.

    Absolute paths, ``..`` components that leave the root, and empty paths are refused, so a
    manifest can never make deploy-prep write (or the verifier read) outside the root.
    """
    if not isinstance(path, str) or not path or "\\" in path or "\x00" in path:
        return None
    if path.startswith("/"):
        return None
    normalised = posixpath.normpath(path)
    if normalised in (".", "") or normalised == ".." or normalised.startswith("../"):
        return None
    return normalised


def artifact_source(artifact: Mapping[str, Any]) -> dict[str, Any]:
    """The artifact's machine-readable source.

    A manifest written before ``source`` existed still reads correctly: an ``https://`` ``url``
    is a ``url`` source and anything else (prose such as "bundled in the wheel") has none.
    """
    source = artifact.get("source")
    if isinstance(source, Mapping) and source.get("kind"):
        return dict(source)
    url = artifact.get("url")
    if isinstance(url, str) and url.startswith("https://"):
        return {"kind": "url"}
    return {"kind": "none", "reason": "no machine-readable source declared"}


def entry_stage_decision(entry: Mapping[str, Any]) -> tuple[bool, str]:
    """Whether deploy-prep stages this entry's artifacts, and why (or why not)."""
    status = str(entry.get("status") or "unknown")
    if status not in STAGED_ENTRY_STATUSES:
        return False, f"entry status {status}: recorded, never fetched"
    if not entry.get("wired", False):
        return False, "entry is not wired to a provider: recorded, never fetched"
    return True, f"wired, {status}"


@dataclass(frozen=True)
class PlannedArtifact:
    """One manifest artifact and what deploy-prep does with it."""

    entry_id: str
    entry_status: str
    provider_id: str | None
    name: str
    path: str | None
    #: The manifest's ``url`` (fetched only for a ``url`` source; prose for other kinds).
    url: str | None
    source: Mapping[str, Any]
    sha256: str | None
    size_bytes: int | None
    verify_at_startup: bool
    #: Entry-level, exactly as ``verify_manifest`` gates readiness.
    required_for_readiness: bool
    action: str
    reason: str

    @property
    def source_kind(self) -> str:
        return str(self.source.get("kind") or "none")

    def to_wire(self) -> dict[str, Any]:
        return {
            "entry_id": self.entry_id,
            "entry_status": self.entry_status,
            "provider_id": self.provider_id,
            "name": self.name,
            "path": self.path,
            "url": self.url,
            "source": dict(self.source),
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
            "verify_at_startup": self.verify_at_startup,
            "required_for_readiness": self.required_for_readiness,
            "action": self.action,
            "reason": self.reason,
        }


def plan_manifest(manifest: Mapping[str, Any]) -> list[PlannedArtifact]:
    """Every artifact in the manifest with the provisioner's action and its reason.

    Only artifacts of wired entries whose status is in ``STAGED_ENTRY_STATUSES`` and that the
    sidecar verifies at startup are staged; an ``installed_package`` artifact is checked against
    the environment instead of copied. Raises ``ValueError`` when a staged artifact declares an
    unsafe path or a ``zip_member`` whose container is not an artifact of the same entry.
    """
    planned: list[PlannedArtifact] = []
    for entry in manifest.get("entries", []):
        entry_id = str(entry.get("id"))
        status = str(entry.get("status") or "unknown")
        provider_id = entry.get("provider_id")
        required = bool(entry.get("required_for_readiness", False))
        stage_entry, entry_reason = entry_stage_decision(entry)
        artifacts = list(entry.get("artifacts") or [])
        names = {str(a.get("name")) for a in artifacts}
        for artifact in artifacts:
            source = artifact_source(artifact)
            kind = str(source.get("kind") or "none")
            if kind not in SOURCE_KINDS:
                raise ValueError(f"{entry_id}/{artifact.get('name')}: unknown source kind {kind!r}")
            verify = bool(artifact.get("verify_at_startup", False))
            if not stage_entry:
                action, reason = "skip", entry_reason
            elif kind == "installed_package":
                action, reason = "check_installed", (
                    f"installed from uv.lock as {source.get('package')}=={source.get('version')}")
            elif not verify:
                action, reason = "record", "verify_at_startup is false: the sidecar never reads it"
            elif kind == "none":
                action, reason = "record", str(source.get("reason") or "no fetchable source")
            else:
                action, reason = "stage", f"{kind} source"
            if action == "stage":
                if safe_relative_path(artifact.get("path")) is None:
                    raise ValueError(f"{entry_id}/{artifact.get('name')}: unsafe artifact path "
                                     f"{artifact.get('path')!r}")
                if kind == "zip_member" and str(source.get("artifact")) not in names:
                    raise ValueError(f"{entry_id}/{artifact.get('name')}: zip_member container "
                                     f"{source.get('artifact')!r} is not an artifact of this entry")
            size = artifact.get("size_bytes")
            planned.append(PlannedArtifact(
                entry_id=entry_id, entry_status=status,
                provider_id=str(provider_id) if provider_id else None,
                name=str(artifact.get("name") or artifact.get("path") or "artifact"),
                path=artifact.get("path"),
                url=artifact.get("url") if isinstance(artifact.get("url"), str) else None,
                source=source, sha256=artifact.get("sha256"),
                size_bytes=int(size) if isinstance(size, int) else None,
                verify_at_startup=verify, required_for_readiness=required,
                action=action, reason=reason))
    return planned


def required_providers(manifest: Mapping[str, Any]) -> list[str]:
    """Providers whose readiness a revision must prove before it is selected.

    These are the providers of wired entries marked ``required_for_readiness``: the same
    entries whose failed checks ``Application.blocking_checks`` turns into a not-ready provider.
    """
    out: list[str] = []
    for entry in manifest.get("entries", []):
        provider_id = entry.get("provider_id")
        if (provider_id and entry.get("wired", False)
                and entry.get("required_for_readiness", False)
                and str(provider_id) not in out):
            out.append(str(provider_id))
    return out


@dataclass(frozen=True)
class PinnedModelRoot:
    """The artifact root a process uses for its whole lifetime.

    ``configured`` is what the operator set (normally ``/opt/frwhoop-models/current``, a symlink);
    ``resolved`` is where it pointed when the process started. A later switch of the symlink takes
    effect only on restart, so the bytes a provider loads are the bytes verified at startup.
    """

    configured_root: str
    resolved_root: str
    configured_manifest: str
    resolved_manifest: str
    #: ``revisions/<id>`` directory name when the resolved root is a staged revision, else None.
    revision: str | None


def pin_model_root(environ: "os._Environ[str] | dict[str, str]") -> PinnedModelRoot:
    """Resolve ``FRWHOOP_MODEL_ROOT``/``FRWHOOP_MANIFEST`` once and write the resolved paths back.

    Called by the sidecar entrypoint before any provider is constructed: the optional providers
    read these variables themselves, so pinning them here keeps every provider on one revision.
    """
    configured_root = environ.get("FRWHOOP_MODEL_ROOT") or DEFAULT_MODEL_ROOT
    configured_manifest = environ.get("FRWHOOP_MANIFEST") or default_manifest_path()
    resolved_root = os.path.realpath(configured_root)
    resolved_manifest = os.path.realpath(configured_manifest)
    revision = None
    if os.path.basename(os.path.dirname(resolved_root)) == "revisions":
        revision = os.path.basename(resolved_root)
    environ["FRWHOOP_MODEL_ROOT"] = resolved_root
    environ["FRWHOOP_MANIFEST"] = resolved_manifest
    global _PINNED
    _PINNED = PinnedModelRoot(configured_root, resolved_root, configured_manifest, resolved_manifest,
                              revision)
    return _PINNED


_PINNED: PinnedModelRoot | None = None


def pinned_model_root() -> PinnedModelRoot | None:
    """What ``pin_model_root`` recorded for this process (None when it never ran, as in tests)."""
    return _PINNED


def default_manifest_path(package_root: str | None = None) -> str:
    """``<repo>/Tools/InferenceWorker/models/manifest.json`` from the package path."""
    here = package_root or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(here, DEFAULT_MANIFEST_RELPATH)
