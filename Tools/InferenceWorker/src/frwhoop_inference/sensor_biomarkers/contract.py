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
    configuration_known: bool | None = None,
) -> dict[str, Any]:
    """One measurement entry (CONTRACTS.md section 3 / spec section 8).

    Every actual measurement carries a finite value or null, a unit, the
    denominator where relevant, the sample/window/pulse count, the method and
    the native resolution where relevant. ``value`` may be null ONLY for a
    structurally valid measurement whose quantity is genuinely undefined (e.g.
    a median over zero windows); a withheld family carries no measurements at
    all instead of zero-valued ones. ``configuration_known`` says whether the
    transport identified gain, drive and channel for ``configuration``.
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
    if configuration_known is not None:
        entry["configuration_known"] = bool(configuration_known)
    return entry

#: Fixed, documented bin edges per quantile-bearing measurement distribution.
#: These are BOUNDED mergeable summaries (spec section 8: "Summaries and
#: bounded bins belong here"): the day lane merges the counts across the day's
#: chunk requests and recomputes day-level quantiles, so a day median/p95 is a
#: pooled estimate over the whole day's epochs/windows/pulses, never one
#: chunk's value presented as the day's. The edges are part of the provider
#: revision: both sides must agree, and a disagreement makes the lane fall back
#: to its documented best-coverage carry (never a silent mismatch).
DISTRIBUTION_EDGES: dict[str, list[float]] = {
    # ENMO epoch means (mg): fine at the low end where day medians live.
    "enmo": [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 75, 100,
             150, 200, 300, 500, 1000, 2000, 5000],
    # Oscillation band power ((deg/s)^2): log-spaced over the observed domain.
    "oscillation_power": [0, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20,
                          50, 100, 200, 500, 1000, 2000, 5000, 10000],
    # Template similarity: native correlation values 0..1.
    "template_similarity": [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0],
    # Pulse amplitude (arbitrary ADC-derived units): log-spaced over the
    # signed 20-bit domain (never pooled across configurations).
    "pulse_amplitude_au": [0, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000,
                           10000, 25000, 50000, 100000, 250000, 524287],
    # Upstroke / width50 (ms): steps at the scale of the 24 Hz native period.
    "pulse_time_ms": [0, 25, 50, 75, 100, 125, 150, 175, 200, 250, 300, 350,
                      400, 500, 600, 700, 800, 1000, 1250, 1500, 2000, 2500],
    # Normalized pulse area: dimensionless 0..1.
    "pulse_area": [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5,
                   0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0],
}


def distribution_block(key: str, values: "Sequence[float]", edges_key: str, *,
                       configuration: str | None = None) -> dict[str, Any] | None:
    """One mergeable bounded-bin distribution for a quantile-bearing metric.

    ``edges_key`` names a fixed edge set in :data:`DISTRIBUTION_EDGES`. Returns
    None when there are no values (a withheld family carries no distribution).
    ``configuration`` tags an amplitude distribution with its optical
    configuration identity, so a merge can keep identities apart.
    """
    import math as _math
    from typing import Sequence as _Sequence  # noqa: F401

    vals = [float(v) for v in values if v is not None and _math.isfinite(float(v))]
    if not vals:
        return None
    edges = DISTRIBUTION_EDGES[edges_key]
    counts = [0] * (len(edges) - 1)
    above = 0
    for v in vals:
        placed = False
        for i in range(len(edges) - 1):
            if edges[i] <= v < edges[i + 1]:
                counts[i] += 1
                placed = True
                break
        if not placed:
            # values at/above the top edge (or below the first, impossible
            # for these metrics) land in the last bin.
            if v >= edges[-1]:
                counts[-1] += 1
            else:
                counts[0] += 1
    block: dict[str, Any] = {"key": key, "edges": edges, "counts": counts, "n": len(vals)}
    if configuration is not None:
        block["configuration"] = configuration
    return block
