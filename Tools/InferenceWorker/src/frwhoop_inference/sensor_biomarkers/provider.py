"""The sensor.biomarkers.v1 provider: one request, per-family stage documents.

CONTRACTS.md section 4: the request input carries per-modality verified raw
segments (IMU in g / deg/s at a native rate; PPG as ABSOLUTE reconstructed ADC
counts at a native rate), a families list and placement metadata. The provider
validates, dispatches each family independently, and returns one stage object
per computed family. A failed optional family NEVER discards valid families.

This is the route the worker calls. The deterministic families are computed
here (``imu.py``, ``ppg.py``); the research and shadow families (tremor,
arm_swing: ParaDigMa; rhythm_shadow: DeepBeat/SiamAF) are reached through the
optional-family seam (``optional.py``), which calls the same implementation the
standalone providers use. Every requested family gets a stage: a disabled flag
(``family_disabled``), missing weights or runtime (``artifact_unavailable`` /
``runtime_unavailable``) and a broken adapter (``adapter_broken``) are told
apart, never dropped silently.
"""

from __future__ import annotations

import os
import time
from typing import Any, Mapping

from ..contract import InferRequest, ProviderResult
from . import (
    ANALYSIS_VERSION,
    DETAIL_REASONS,
    FAMILY_TIERS,
    LABEL_SPACE,
    SCHEMA_VERSION,
)
from .contract import family_document
from .optional import (
    DEFAULT_ADAPTER_MODULES,
    OPTIONAL_FAMILY_ADAPTERS,
    compute_optional_families,
    optional_family_capabilities,
    optional_loaded_identity,
)

PROVIDER_ID = "sensor.biomarkers.v1"
METRIC = "sensor_biomarkers"
MODE = "production"
REQUIRED_SIGNALS = ("imu", "ppg")

ADAPTER_VERSION = "sensor-biomarkers.adapter/1.0.0"
INPUT_SCHEMA_VERSION = 1

#: Families this provider computes directly (deterministic, no artifacts), and where.
DETERMINISTIC_FAMILIES = (
    "movement", "oscillation", "ppg_quality", "pulse_shape", "perfusion_research",
)
DETERMINISTIC_IMPLEMENTATIONS = {
    "movement": f"{__package__}.imu", "oscillation": f"{__package__}.imu",
    "ppg_quality": f"{__package__}.ppg", "pulse_shape": f"{__package__}.ppg",
    "perfusion_research": f"{__package__}.ppg",
}

#: The order stages are returned in.
FAMILY_ORDER = ("movement", "oscillation", "ppg_quality", "pulse_shape",
                "perfusion_research", "tremor", "arm_swing", "rhythm_shadow")

#: Share of the sidecar's request budget (``FRWHOOP_REQUEST_TIMEOUT_MS``) the
#: optional families may use. The rest covers the descriptive families and the
#: response, so a slow optional family is withheld ``timeout`` on its own
#: instead of timing out the whole request.
OPTIONAL_BUDGET_FRACTION = 0.6
DEFAULT_REQUEST_BUDGET_S = 20.0


def _request_budget_s() -> float:
    try:
        return max(1.0, float(os.environ.get("FRWHOOP_REQUEST_TIMEOUT_MS", "")) / 1000.0)
    except ValueError:
        return DEFAULT_REQUEST_BUDGET_S


def _err(code: str, message: str, field: str | None = None) -> dict[str, Any]:
    err = {"code": code, "message": message}
    if field:
        err["field"] = field
    return {"status": "error", "error": err}


def parse_sensor_input(raw: Mapping[str, Any]) -> dict[str, Any]:
    """Validate the sensor_biomarkers input payload (CONTRACTS.md section 4).

    Raises ``ValueError`` with a stable code in ``args[0]``; the provider maps
    that to a status="error" result so the server answers 400 with a
    machine-readable reason (same pattern as the sleep providers).
    """
    if not isinstance(raw, Mapping):
        raise ValueError("invalid_input: input must be an object")
    if raw.get("schema_version") != INPUT_SCHEMA_VERSION:
        raise ValueError("invalid_schema_version: input.schema_version must be 1")
    device = raw.get("device")
    if not isinstance(device, Mapping) or not device.get("id"):
        raise ValueError("invalid_device: input.device.id is required")
    families = raw.get("families")
    if not isinstance(families, list) or not families:
        raise ValueError("invalid_families: input.families must be a non-empty list")
    unknown = [f for f in families if f not in FAMILY_TIERS]
    if unknown:
        raise ValueError(f"invalid_families: unknown families {unknown!r}")
    if len(set(families)) != len(families):
        raise ValueError("invalid_families: duplicate families")

    parsed: dict[str, Any] = {
        "device_id": str(device["id"]),
        "device_family": str(device.get("family") or "unknown"),
        "families": [str(f) for f in families],
        # Placement as stated by the request; anything outside the vocabulary is
        # unknown, never guessed (ParaDigMa withholds arm_swing on unknown).
        "watch_side": raw.get("watch_side") if raw.get("watch_side") in ("left", "right") else None,
        "device_orientation": (raw.get("device_orientation")
                               if raw.get("device_orientation") in ("screen_up", "screen_down")
                               else None),
    }

    imu = raw.get("imu")
    if imu is not None:
        if not isinstance(imu, Mapping):
            raise ValueError("invalid_imu: input.imu must be an object")
        rate = imu.get("sampling_rate_hz")
        if not isinstance(rate, (int, float)) or not (25.0 <= float(rate) <= 400.0):
            raise ValueError("invalid_imu: sampling_rate_hz must be 25-400")
        units = imu.get("units")
        if not isinstance(units, Mapping) or units.get("accel") != "g" or units.get("gyro") != "deg/s":
            raise ValueError("invalid_imu: units must be {accel: g, gyro: deg/s}")
        if not isinstance(imu.get("segments"), list) or not imu.get("segments"):
            raise ValueError("invalid_imu: segments must be a non-empty list")
        parsed["imu"] = {"sampling_rate_hz": float(rate), "segments": imu["segments"]}
    else:
        parsed["imu"] = None

    ppg = raw.get("ppg")
    if ppg is not None:
        if not isinstance(ppg, Mapping):
            raise ValueError("invalid_ppg: input.ppg must be an object")
        rate = ppg.get("native_rate_hz")
        if not isinstance(rate, (int, float)) or not (8.0 <= float(rate) <= 250.0):
            raise ValueError("invalid_ppg: native_rate_hz must be 8-250")
        if ppg.get("units") != "adc_counts":
            raise ValueError("invalid_ppg: units must be adc_counts")
        if not isinstance(ppg.get("segments"), list) or not ppg.get("segments"):
            raise ValueError("invalid_ppg: segments must be a non-empty list")
        expected = ppg.get("expected_duration_s")
        if expected is not None and (not isinstance(expected, (int, float)) or expected < 0):
            raise ValueError("invalid_ppg: expected_duration_s must be a non-negative number")
        parsed["ppg"] = {
            "native_rate_hz": float(rate),
            "segments": ppg["segments"],
            "expected_duration_s": (float(expected) if isinstance(expected, (int, float)) else None),
            "optical_dc": ppg.get("optical_dc"),
        }
    else:
        parsed["ppg"] = None

    revision = raw.get("input_revision")
    if not isinstance(revision, str) or not revision:
        raise ValueError("invalid_input_revision: input_revision is required")
    parsed["input_revision"] = revision
    return parsed


class SensorBiomarkersProvider:
    """sensor.biomarkers.v1: tiered sensor-biomarker families (CONTRACTS.md).

    ``optional_adapters`` maps an optional adapter name (``paradigma``,
    ``rhythm``) to the module path or object implementing it; tests inject
    doubles there and a later checkpoint can plug in the same way.
    ``optional_budget_s`` overrides the optional families' time budget.
    """

    provider_id = PROVIDER_ID
    metric = METRIC
    mode = MODE
    label_space = LABEL_SPACE
    required_signals = REQUIRED_SIGNALS
    eligibility_state = "eligible"
    eligibility_reason: str | None = None

    def __init__(self, *, optional_adapters: Mapping[str, Any] | None = None,
                 optional_budget_s: float | None = None):
        self._adapters: dict[str, Any] = {**DEFAULT_ADAPTER_MODULES, **(optional_adapters or {})}
        self._optional_budget_s = optional_budget_s

    def versions(self, request: InferRequest | None = None) -> dict[str, Any]:
        from . import PROVIDER_REVISIONS
        from .imu import MOVEMENT_THRESHOLD_VERSION
        from .ppg import CLEANER, NEUROKIT2_VERSION, PEAK_DETECTOR, QUALITY_METHOD

        return {
            "analysis": ANALYSIS_VERSION,
            "adapter": ADAPTER_VERSION,
            "input_schema": INPUT_SCHEMA_VERSION,
            "neurokit2": NEUROKIT2_VERSION,
            "ppg_cleaner": CLEANER,
            "peak_detector": PEAK_DETECTOR,
            "quality_method": QUALITY_METHOD,
            "movement_thresholds": MOVEMENT_THRESHOLD_VERSION,
            "families": dict(PROVIDER_REVISIONS),
        }

    def readiness(self) -> tuple[bool, str | None]:
        """Readiness of the descriptive core. An optional family's state is
        reported per family in ``capability()["families"]`` and never gates the
        route, so a missing optional artifact cannot take the descriptive
        families down."""
        try:
            import neurokit2  # noqa: F401
        except Exception as exc:  # pragma: no cover - fail closed
            return False, f"blocked_artifact: neurokit2 import failed: {exc}"
        try:
            self._assert_neurokit_api()
        except Exception as exc:
            return False, f"blocked_artifact: neurokit2 API assert failed: {exc}"
        return True, None

    @staticmethod
    def _assert_neurokit_api() -> None:
        """Assert the pinned neurokit2 exposes the verified API at startup."""
        import neurokit2 as nk
        from .ppg import NEUROKIT2_VERSION

        if getattr(nk, "__version__", None) != NEUROKIT2_VERSION:
            raise RuntimeError(
                f"neurokit2 {NEUROKIT2_VERSION} pinned, found {getattr(nk, '__version__', None)!r}")
        sig = str(getattr(nk.ppg_findpeaks, "__doc__", "") or "")
        if "charlton" not in (sig + str(getattr(nk.ppg_findpeaks, "__module__", ""))):
            # cheap structural check: the method must exist in the dispatch
            import inspect
            src = inspect.getsource(nk.ppg_findpeaks)
            if "charlton" not in src:
                raise RuntimeError("ppg_findpeaks does not expose the charlton method")

    def family_capabilities(self) -> dict[str, dict[str, Any]]:
        """Per-family tier, implementation and readiness (``/v1/providers``)."""
        families: dict[str, dict[str, Any]] = {}
        for family in DETERMINISTIC_FAMILIES:
            families[family] = {
                "tier": FAMILY_TIERS[family],
                "publishable": FAMILY_TIERS[family] == "descriptive",
                "implementation": DETERMINISTIC_IMPLEMENTATIONS[family],
                "ready": True, "state": "ready", "reason": None,
            }
        families.update(optional_family_capabilities(self._adapters))
        return {family: families[family] for family in FAMILY_ORDER if family in families}

    def loaded_identity(self) -> dict[str, str]:
        """Checkpoint digests the optional families verified (the descriptive core loads none)."""
        return optional_loaded_identity(self._adapters)

    def capability(self) -> dict[str, Any]:
        return {
            "provider_id": PROVIDER_ID,
            "metric": METRIC,
            "mode": MODE,
            "publishable": True,
            "accuracy_label": "engineering diagnostics; descriptive tier only",
            "tiers": dict(FAMILY_TIERS),
            "canonical_route": PROVIDER_ID,
            "families": self.family_capabilities(),
            "reason_vocabulary": list(DETAIL_REASONS),
        }

    # -- dispatch ---------------------------------------------------------

    def infer(self, request: InferRequest) -> ProviderResult:
        started = time.monotonic()
        try:
            parsed = parse_sensor_input(request.input)
        except ValueError as exc:
            code, _, message = str(exc).partition(":")
            return ProviderResult(
                status="error", value=None,
                diagnostics={"reason_detail": code, "message": message or str(exc)},
                versions=self.versions(request),
                label_space=LABEL_SPACE,
            )

        stages: list[dict[str, Any]] = []
        coverage: dict[str, Any] = {}
        reason_counts: dict[str, int] = {}
        imu_grid = None
        ppg_segments = None

        from .imu import build_epoch_grid, compute_movement, compute_oscillation
        from .ppg import (
            compute_perfusion_research,
            compute_ppg_quality,
            compute_pulse_shape,
            _validate_segments as validate_ppg_segments,
        )

        families = parsed["families"]
        needs_imu = any(f in ("movement", "oscillation") for f in families)
        needs_ppg = any(f in ("ppg_quality", "pulse_shape", "perfusion_research") for f in families)

        if needs_imu:
            if parsed["imu"] is None:
                for fam in ("movement", "oscillation"):
                    if fam in families:
                        stages.append(family_document(
                            family=fam, status="withheld", reason="artifact_unavailable",
                            measurements={}, reason_counts={"no_verified_imu_objects": 1}))
                imu_grid = None
            else:
                try:
                    imu_grid = build_epoch_grid(
                        parsed["imu"]["segments"], parsed["imu"]["sampling_rate_hz"])
                except Exception as exc:
                    imu_grid = None
                    for fam in ("movement", "oscillation"):
                        if fam in families:
                            stages.append(family_document(
                                family=fam, status="withheld", reason="blocked_input",
                                measurements={},
                                reason_counts={"imu_decode_error": 1},
                                extra={"detail": str(exc)[:200]}))
        if needs_ppg:
            if parsed["ppg"] is None:
                for fam in ("ppg_quality", "pulse_shape", "perfusion_research"):
                    if fam in families:
                        stages.append(family_document(
                            family=fam, status="withheld", reason="artifact_unavailable",
                            measurements={}, reason_counts={"no_verified_ppg_objects": 1}))
                ppg_segments = None
            else:
                try:
                    ppg_segments = validate_ppg_segments(
                        parsed["ppg"]["segments"], parsed["ppg"]["native_rate_hz"])
                except Exception as exc:
                    ppg_segments = None
                    for fam in ("ppg_quality", "pulse_shape", "perfusion_research"):
                        if fam in families:
                            stages.append(family_document(
                                family=fam, status="withheld", reason="blocked_input",
                                measurements={}, reason_counts={"ppg_decode_error": 1},
                                extra={"detail": str(exc)[:200]}))

        context = request.context
        interval_start = float(context.start_ts)
        interval_end = float(context.end_ts)

        # Deterministic families: each computed independently; a failure in one
        # never discards the others.
        if imu_grid is not None:
            for fam in ("movement", "oscillation"):
                if fam not in families:
                    continue
                try:
                    if fam == "movement":
                        doc = compute_movement(
                            imu_grid, parsed["imu"]["sampling_rate_hz"],
                            interval_start, interval_end)
                    else:
                        doc = compute_oscillation(imu_grid, parsed["imu"]["sampling_rate_hz"])
                except Exception as exc:
                    doc = family_document(
                        family=fam, status="error", reason="provider_error",
                        measurements={}, reason_counts={"compute_error": 1},
                        extra={"detail": str(exc)[:200]})
                stages.append(doc)

        if ppg_segments is not None:
            rate = parsed["ppg"]["native_rate_hz"]
            for fam in ("ppg_quality", "pulse_shape", "perfusion_research"):
                if fam not in families:
                    continue
                try:
                    if fam == "ppg_quality":
                        doc = compute_ppg_quality(
                            ppg_segments, rate,
                            expected_duration_s=parsed["ppg"]["expected_duration_s"])
                    elif fam == "pulse_shape":
                        doc = compute_pulse_shape(ppg_segments, rate)
                    else:
                        doc = compute_perfusion_research(
                            ppg_segments, rate,
                            optical_dc=parsed["ppg"].get("optical_dc"))
                except Exception as exc:
                    doc = family_document(
                        family=fam, status="error", reason="provider_error",
                        measurements={}, reason_counts={"compute_error": 1},
                        extra={"detail": str(exc)[:200]})
                stages.append(doc)

        # Research and shadow families: their own implementations, reached
        # through the seam. Each adapter fails alone and every requested family
        # comes back with a stage. They get what is left of their share of the
        # request budget.
        optional = [f for f in families if f in OPTIONAL_FAMILY_ADAPTERS]
        if optional:
            budget = (self._optional_budget_s if self._optional_budget_s is not None
                      else OPTIONAL_BUDGET_FRACTION * _request_budget_s())
            stages.extend(compute_optional_families(
                request.input, optional, modules=self._adapters, deadline=started + budget))

        # Order stages by the canonical family order, dedupe by family name.
        order = {name: i for i, name in enumerate(FAMILY_ORDER)}
        seen: dict[str, dict[str, Any]] = {}
        for doc in stages:
            fam = doc.get("family")
            if fam in seen:
                continue  # first verdict wins (e.g. the no-IMU early documents)
            seen[fam] = doc
        ordered = [seen[name] for name in sorted(seen, key=lambda n: order.get(n, 99))]

        for doc in ordered:
            fam = doc.get("family")
            coverage[fam] = {
                "observed_seconds": doc.get("observed_seconds"),
                "eligible_seconds": doc.get("eligible_seconds"),
            }
            for key, count in (doc.get("reason_counts") or {}).items():
                reason_counts[key] = reason_counts.get(key, 0) + int(count)

        return ProviderResult(
            status="ok", value=None, unit=None,
            stages=ordered,
            label_space=LABEL_SPACE,
            coverage=coverage,
            diagnostics={
                "schema_version": SCHEMA_VERSION,
                "analysis_version": ANALYSIS_VERSION,
                "input_revision": parsed["input_revision"],
                "reason_counts": reason_counts,
                "requested_families": families,
                "placement": {
                    "watch_side": parsed["watch_side"] or "unknown",
                    "device_orientation": parsed["device_orientation"] or "unknown",
                },
            },
            versions=self.versions(request),
            publishable=True,
        )


def make_providers() -> list[Any]:
    return [SensorBiomarkersProvider()]
