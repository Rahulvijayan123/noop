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
"""

from __future__ import annotations

import hashlib
import json
import os
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
        return self.status in ("missing", "sha256_mismatch", "size_mismatch", "no_sha256")

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
                    "size_bytes": a.get("size_bytes"),
                    "sha256": a.get("sha256"),
                }
                for a in (entry.get("artifacts") or [])
            ],
        })
    return out


def default_manifest_path(package_root: str | None = None) -> str:
    """``<repo>/Tools/InferenceWorker/models/manifest.json`` from the package path."""
    here = package_root or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(here, DEFAULT_MANIFEST_RELPATH)
