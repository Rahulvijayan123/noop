"""Additive sensor-biomarker families (spec-31; docs/sensor-biomarkers/CONTRACTS.md).

Tiered families computed from verified raw IMU/PPG:

* descriptive: movement (ENMO + low-movement bouts), oscillation (3-7 Hz gyro band
  power), ppg_quality, pulse_shape
* gated research: perfusion_research (AC/DC ratio; withheld until optical DC is verified)
* research: tremor + arm_swing (ParaDigMa pretrained classifiers)
* shadow (never user-facing): rhythm_shadow (DeepBeat; optional SiamAF)

Design rules (CONTRACTS.md sections 3-4, enforced by tests):

* families are independent: a failed optional family never discards valid families;
* every measurement carries value-or-null, unit, denominator, count, method and native
  resolution where relevant; withheld data is null + reason, never a fabricated zero;
* rhythm outputs are model score vectors in shadow logs only; no clinical burden field;
* nothing here touches the HRV/sleep/respiration providers or the canonical scoring path.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:  # pragma: no cover - import cycle guard for type checkers only
    from ..providers import Provider

#: Stable analysis version stamped into every family document (CONTRACTS.md section 3).
ANALYSIS_VERSION = "sensor-biomarkers/1.0.0"

#: Family document schema version.
SCHEMA_VERSION = 1

#: Label space of the structured family stage objects on the wire (CONTRACTS.md section 4).
LABEL_SPACE = "sensor_biomarkers.families/1"

#: Every family this package can compute, with its release tier.
FAMILY_TIERS: dict[str, str] = {
    "movement": "descriptive",
    "oscillation": "descriptive",
    "ppg_quality": "descriptive",
    "pulse_shape": "descriptive",
    "perfusion_research": "research",
    "tremor": "research",
    "arm_swing": "research",
    "rhythm_shadow": "shadow",
}

#: Provider revisions per family (CONTRACTS.md section 1).
PROVIDER_REVISIONS: dict[str, str] = {
    "movement": "imu-biomarkers/1.0.0",
    "oscillation": "imu-biomarkers/1.0.0",
    "ppg_quality": "ppg-biomarkers/1.0.0",
    "pulse_shape": "ppg-biomarkers/1.0.0",
    "perfusion_research": "ppg-biomarkers/1.0.0",
    "tremor": "paradigma/1.0.0",
    "arm_swing": "paradigma/1.0.0",
    "rhythm_shadow": "deepbeat/1.0.0",
}

#: Detailed withheld-reason codes beyond the sidecar enum (CONTRACTS.md section 3).
DETAIL_REASONS: tuple[str, ...] = (
    "unverified_sample_clock",
    "missing_ppg_anchor",
    "saturated_delta",
    "unverified_optical_dc",
    "unknown_wrist_placement",
    "unknown_orientation",
    "insufficient_eligible_time",
    "unsupported_native_rate",
    "preprocessing_unverified",
    # No verified input reached the family / the model or its weights are not available
    # (contracts/reason-codes.json). ``artifact_unavailable`` said either before 2026-10-09: kept so
    # stored documents stay in the vocabulary, never written.
    "no_verified_input",
    "model_unavailable",
    "artifact_unavailable",
    "not_enough_valid_data",
    # Optional-family dispatch (docs/model-integration/sensor-families.md): the
    # sidecar flag is off / the isolated runtime is missing / the adapter could
    # not be imported, does not match the interface or raised.
    "family_disabled",
    "runtime_unavailable",
    "adapter_broken",
)


def family_document_stub(family: str, reason: str) -> dict[str, Any]:
    """A withheld family document with no measurements (never a fabricated zero)."""
    from .contract import family_document  # local import: contract.py is W2-owned

    return family_document(
        family=family,
        status="withheld",
        reason=reason,
        measurements={},
    )


def collect_providers() -> list["Provider"]:
    """Aggregate the per-module providers.

    Each family module exposes ``make_providers() -> list[Provider]``. The heavy
    optional modules (paradigma, rhythm) are imported lazily inside their own
    ``make_providers`` so a missing artifact or dependency can never break startup
    of the descriptive families.
    """
    providers: list["Provider"] = []
    from .imu import make_providers as imu_providers
    from .ppg import make_providers as ppg_providers
    from .provider import make_providers as main_providers

    providers.extend(imu_providers())
    providers.extend(ppg_providers())
    providers.extend(main_providers())
    return providers


def collect_optional_providers() -> list["Provider"]:
    """Heavy research/shadow providers; a broken import registers nothing (fail-closed).

    These standalone providers serve explicit ``provider_id`` requests. The
    route the worker calls is ``sensor.biomarkers.v1``, which reaches the same
    family implementations through ``optional.py`` and reports a broken adapter
    there as ``adapter_broken``; the failure is also written to stderr here.
    """
    import importlib
    import sys

    providers: list["Provider"] = []
    for module_name in ("paradigma", "rhythm"):
        try:
            module = importlib.import_module(f"{__name__}.{module_name}")
            providers.extend(module.make_providers())
        except Exception as exc:  # noqa: BLE001 - optional lane, never startup-fatal
            sys.stderr.write(f"frwhoop-inference: optional provider {module_name} not "
                             f"registered: {type(exc).__name__}: {exc}\n")
    return providers
