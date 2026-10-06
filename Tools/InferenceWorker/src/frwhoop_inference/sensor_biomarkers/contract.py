"""Family document construction/validation for the sensor-biomarkers contract.

Owned by W2. The parent-owned constants (ANALYSIS_VERSION, FAMILY_TIERS, DETAIL_REASONS)
live in ``sensor_biomarkers/__init__.py``; this module owns the document builder used by
every family module so the stored JSONB shape cannot drift between families.
"""

from __future__ import annotations

import math
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

def measurement(
    value: float | None,
    unit: str,
    *,
    denominator: str | None = None,
    count: int | None = None,
    method: str | None = None,
    native_resolution: str | None = None,
    configuration: str | None = None,
) -> dict[str, Any]:
    """One measurement entry (CONTRACTS.md section 3 / spec section 8).

    Every actual measurement carries a finite value or null, a unit, the
    denominator where relevant, the sample/window/pulse count, the method and
    the native resolution where relevant. ``value`` may be null ONLY for a
    structurally valid measurement whose quantity is genuinely undefined (e.g.
    a median over zero windows); a withheld family carries no measurements at
    all instead of zero-valued ones.
    """
    if value is not None:
        value = float(value)
        if not math.isfinite(value):
            raise ValueError(f"measurement value must be finite, got {value!r}")
    entry: dict[str, Any] = {"value": value, "unit": unit}
    if denominator is not None:
        entry["denominator"] = denominator
    if count is not None:
        entry["count"] = int(count)
    if method is not None:
        entry["method"] = method
    if native_resolution is not None:
        entry["native_resolution"] = native_resolution
    if configuration is not None:
        entry["configuration"] = configuration
    return entry
