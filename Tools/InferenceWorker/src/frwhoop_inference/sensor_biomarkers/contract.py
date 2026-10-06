"""Family document construction/validation for the sensor-biomarkers contract.

Owned by W2. The parent-owned constants (ANALYSIS_VERSION, FAMILY_TIERS, DETAIL_REASONS)
live in ``sensor_biomarkers/__init__.py``; this module owns the document builder used by
every family module so the stored JSONB shape cannot drift between families.
"""

from __future__ import annotations

from typing import Any


def family_document(
    *,
    family: str,
    status: str,
    reason: str | None = None,
    measurements: dict[str, Any] | None = None,
    release_tier: str | None = None,
    provider_revision: str | None = None,
    observed_seconds: float | None = None,
    eligible_seconds: float | None = None,
    contact_state: str = "unknown",
    reason_counts: dict[str, int] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build one family stage document (CONTRACTS.md section 3).

    A withheld family carries NO measurements: null + reason, never a fabricated zero.
    """
    from . import ANALYSIS_VERSION, FAMILY_TIERS, PROVIDER_REVISIONS

    doc: dict[str, Any] = {
        "family": family,
        "status": status,
        "release_tier": release_tier or FAMILY_TIERS.get(family, "research"),
        "provider_revision": provider_revision or PROVIDER_REVISIONS.get(family, ""),
        "measurements": measurements or {},
        "reason_counts": reason_counts or {},
    }
    if observed_seconds is not None:
        doc["observed_seconds"] = observed_seconds
    if eligible_seconds is not None:
        doc["eligible_seconds"] = eligible_seconds
    if family in ("movement", "tremor", "arm_swing"):
        doc["contact_state"] = contact_state
    if reason is not None:
        doc["reason"] = reason
    if extra:
        doc.update(extra)
    return doc
