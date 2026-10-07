"""Rhythm shadow provider (``sensor.biomarkers.rhythm.v1``).

Disabled-by-default research shadow adapter for the ``rhythm_shadow`` family
(spec 6.6/6.7; CONTRACTS.md sections 1-4). Real weights, real execution, no
clinical outputs, never user-facing.

Gates
-----
* ``FRWHOOP_DEEPBEAT_SHADOW_ENABLED`` / ``FRWHOOP_SIAMAF_SHADOW_ENABLED``
  must each be exactly ``"1"`` (off by default);
* the artifact must exist under the artifact root (``FRWHOOP_MODEL_ROOT`` or
  ``/opt/frwhoop-models``) and match the pinned sha256 before any model is
  loaded;
* missing flags/artifacts yield ``not_ready`` / ``artifact_unavailable`` and
  never affect the other sensor-biomarker families.

The main sensor-biomarker provider calls :func:`compute_rhythm_shadow_document`
directly per request; this module also exposes the full
:class:`frwhoop_inference.providers.Provider` surface so the server can route
an explicit ``provider_id`` request to the shadow lane alone.

Output policy
-------------
* DeepBeat outputs are a tensor-compatibility experiment on UNRESOLVED
  preprocessing: every score is ``preprocessing_unverified`` and
  ``publishable=false``, carried in ``raw_scores`` research logs only; the
  family document is ``withheld`` with reason ``preprocessing_unverified``.
* SiamAF preprocessing is verified from the source repository; its scores are
  computed with ``preprocessing_status=verified_from_source`` but stay
  nonpublishable (WHOOP native-rate domain mismatch + WHOOP/ECG release gate).
* No AF notification, episode count, burden, medication advice or health-score
  contribution is ever produced. Missing/poor/flat/short/mixed-channel or
  unverified-clock input never becomes a reassuring normal classification.
"""

from __future__ import annotations

import os
from typing import Any, Mapping

from ...contract import WithheldReason  # noqa: F401 - wire enum for error mapping
from ..contract import family_document  # W2-owned builder (read-only use)
from .. import (ANALYSIS_VERSION, FAMILY_TIERS,  # noqa: F401 - shared constants
               SCHEMA_VERSION)
from ._common import artifact_root, flag_enabled, parse_ppg_payload
from .deepbeat import PROVIDER_REVISION as DEEPBEAT_REVISION
from .siamaf import PROVIDER_REVISION as SIAMAF_REVISION

ENABLE_DEEPBEAT = "FRWHOOP_DEEPBEAT_SHADOW_ENABLED"
ENABLE_SIAMAF = "FRWHOOP_SIAMAF_SHADOW_ENABLED"

ADAPTER_VERSION = "sensor-biomarkers.rhythm/1.0.0"
PROVIDER_ID = "sensor.biomarkers.rhythm.v1"
METRIC = "sensor_biomarkers"
LABEL_SPACE = "sensor_biomarkers.families/1"

_FAMILY = "rhythm_shadow"
_REASON_NOT_REQUESTED = "not_ready"
_REASON_NOT_ENABLED = "not_ready"
_REASON_NO_PPG = "artifact_unavailable"
_REASON_BAD_PPG = "blocked_input"


#: Family-level detail reason -> wire WithheldReason mapping for the
#: standalone provider. The family document keeps the precise CONTRACTS detail
#: reason (preprocessing_unverified etc.); the wire envelope needs a value from
#: the sidecar WithheldReason enum, so the closest enum member is used and the
#: detail is preserved in diagnostics.reason_detail.
_WIRE_REASON: dict[str, str] = {
    "preprocessing_unverified": "unverified",
    "unverified_sample_clock": "unverified",
    "not_enough_valid_data": "insufficient_coverage",
    "artifact_unavailable": "blocked_artifact",
    "artifact_mismatch": "blocked_artifact",
    "unsupported_native_rate": "blocked_input",
}


def _wire_reason(family_reason: str | None) -> str:
    if family_reason is None:
        return "provider_error"
    if family_reason in {r.value for r in WithheldReason}:
        return family_reason
    return _WIRE_REASON.get(family_reason, "unverified")


def _enabled_flags(*, deepbeat: bool | None = None, siamaf: bool | None = None
                   ) -> tuple[bool, bool]:
    """Resolve the enable flags; an explicit argument wins over the env."""
    deep = flag_enabled(ENABLE_DEEPBEAT) if deepbeat is None else bool(deepbeat)
    siam = flag_enabled(ENABLE_SIAMAF) if siamaf is None else bool(siamaf)
    return deep, siam


def compute_rhythm_shadow_document(
    input_payload: Mapping[str, Any],
    *,
    model_root: str | None = None,
    deepbeat_enabled: bool | None = None,
    siamaf_enabled: bool | None = None,
) -> dict[str, Any] | None:
    """Build the ``rhythm_shadow`` family stage for one request.

    Returns ``None`` when the request does not ask for ``rhythm_shadow`` (the
    main provider simply skips the family). Otherwise returns the family
    document (CONTRACTS.md section 3 shape). Never raises for bad input: a
    malformed payload becomes a withheld family with a machine-readable
    reason. ``model_root`` overrides the artifact root (tests use a staged
    temporary root); the enable flags default to the worker env.

    The main ``sensor.biomarkers.v1`` provider calls this function directly
    per request; the standalone RhythmProvider wraps the same function.
    """
    root = model_root or artifact_root()
    deep_flag, siam_flag = _enabled_flags(deepbeat=deepbeat_enabled,
                                          siamaf=siamaf_enabled)

    families = list((input_payload or {}).get("families") or [])
    if _FAMILY not in families:
        return None

    if not (deep_flag or siam_flag):
        return family_document(family=_FAMILY, status="withheld",
                               reason=_REASON_NOT_ENABLED)

    ppg_raw = (input_payload or {}).get("ppg")
    if ppg_raw is None or (isinstance(ppg_raw, dict) and not ppg_raw.get("segments")):
        return family_document(family=_FAMILY, status="withheld",
                               reason=_REASON_NO_PPG)
    try:
        ppg = parse_ppg_payload(ppg_raw)
    except ValueError as exc:
        return family_document(family=_FAMILY, status="error",
                               reason=_REASON_BAD_PPG, extra={"detail": str(exc)})
    if not ppg.get("clock_verified", False):
        return family_document(family=_FAMILY, status="withheld",
                               reason="unverified_sample_clock")

    # -- run the enabled adapters ------------------------------------------
    deep_result: dict[str, Any] | None = None
    siam_result: dict[str, Any] | None = None
    def _run(builder: Any):
        """Run one adapter; a runtime fault becomes a withheld family detail,
        never an exception out of the provider (fail-closed)."""
        try:
            adapter = builder()
            ok, why = adapter.readiness()
            if not ok:
                return {"status": "error", "reason": why or "artifact_unavailable",
                        "windows": 0}
            return adapter.infer(ppg)
        except Exception as exc:  # noqa: BLE001 - adapter defect is a withheld family
            return {"status": "error", "reason": "provider_error",
                    "detail": f"{type(exc).__name__}: {exc}", "windows": 0}

    if deep_flag:
        from .deepbeat import DeepBeatAdapter, ARTIFACT_RELPATH as DB_RELPATH
        deep_result = _run(lambda: DeepBeatAdapter(os.path.join(root, DB_RELPATH)))
        deep_result.setdefault("quality", None)
        deep_result.setdefault("rhythm", None)
    if siam_flag:
        from .siamaf import SiamAFAdapter, ARTIFACT_RELPATH as SA_RELPATH
        siam_result = _run(lambda: SiamAFAdapter(os.path.join(root, SA_RELPATH)))
        siam_result.setdefault("rhythm", None)

    # -- assemble the family stage -----------------------------------------
    measurements: dict[str, Any] = {}
    raw_scores: dict[str, Any] = {}
    adapters: dict[str, Any] = {}

    if deep_result is not None:
        deep_status = deep_result["status"]
        if deep_result.get("windows", 0) > 0:
            # Compatibility experiment scores: research logs only (never a
            # publishable measurement on unresolved preprocessing).
            raw_scores["deepbeat_quality_scores"] = deep_result["quality"]
            raw_scores["deepbeat_rhythm_scores"] = deep_result["rhythm"]
        adapters["deepbeat"] = {"status": deep_status, "ran": True,
                                "reason": deep_result.get("reason"),
                                "windows": deep_result.get("windows", 0)}
    if siam_result is not None:
        siam_status = siam_result["status"]
        if siam_result.get("windows", 0) > 0:
            # Verified-from-source preprocessing: measurement in the stage,
            # still nonpublishable (WHOOP domain + release gate).
            measurements["siamaf_rhythm_scores"] = siam_result["rhythm"]
            raw_scores["siamaf_rhythm_scores"] = siam_result["rhythm"]
        adapters["siamaf"] = {"status": siam_status, "ran": True,
                              "reason": siam_result.get("reason"),
                              "windows": siam_result.get("windows", 0)}

    # -- family status ------------------------------------------------------
    # The family is "ok" only when a verified-preprocessing adapter produced
    # scores. DeepBeat-only output is withheld (preprocessing_unverified) even
    # though the compatibility scores are preserved in raw_scores.
    if measurements:
        status, reason = "ok", None
    elif raw_scores:
        status, reason = "withheld", "preprocessing_unverified"
    else:
        # Family-level reason uses the CONTRACTS vocabulary: an adapter that
        # reports "artifact_mismatch" is also "artifact_unavailable" at the
        # family level (the precise detail stays in ``adapters``).
        reasons = [a["reason"] for a in adapters.values() if a.get("reason")]
        family_reason = None
        for candidate in reasons:
            if candidate in ("artifact_unavailable", "artifact_mismatch"):
                family_reason = "artifact_unavailable"
                break
            family_reason = family_reason or candidate
        status, reason = "withheld", family_reason or "not_ready"

    extra: dict[str, Any] = {"adapters": adapters, "schema_version": SCHEMA_VERSION}
    if raw_scores:
        extra["raw_scores"] = raw_scores
    # The family's provider_revision names the adapters that actually ran (a
    # SiamAF-only shadow is never labelled deepbeat/1.0.0).
    ran = [a for a in ("deepbeat", "siamaf") if adapters.get(a, {}).get("ran")]
    provider_revision = "+".join(
        {"deepbeat": DEEPBEAT_REVISION, "siamaf": SIAMAF_REVISION}[a] for a in ran) or "rhythm-shadow/none"
    return family_document(
        family=_FAMILY, status=status, reason=reason,
        measurements=measurements, provider_revision=provider_revision, extra=extra)


class RhythmProvider:
    """The standalone rhythm shadow provider (server-routable)."""

    provider_id = PROVIDER_ID
    metric = METRIC
    mode = "shadow"
    label_space = LABEL_SPACE
    required_signals = ("ppg",)
    eligibility_state = "shadow_eligible"
    eligibility_reason = (
        "rhythm shadow only: DeepBeat preprocessing unverified, WHOOP native "
        "rate differs from both training domains, no clinical release")

    def __init__(self, *, model_root: str | None = None,
                 deepbeat_enabled: bool | None = None,
                 siamaf_enabled: bool | None = None):
        self._model_root = model_root
        self._deepbeat_enabled = deepbeat_enabled
        self._siamaf_enabled = siamaf_enabled

    # -- registry surface ---------------------------------------------------
    def versions(self, request: Any = None) -> dict[str, Any]:
        return {"adapter": ADAPTER_VERSION, "deepbeat": DEEPBEAT_REVISION,
                "siamaf": SIAMAF_REVISION, "analysis": ANALYSIS_VERSION}

    def readiness(self) -> tuple[bool, str | None]:
        """Process-level readiness for the optional shadow lane.

        The lane is disabled by default and its artifacts are optional
        (``required_for_readiness: false`` in the manifest), so a disabled lane
        reports READY: it must never flip the process flag or the healthz view
        of the default deployment. When an operator explicitly ENABLES a lane
        whose artifact is missing or mismatched, readiness turns false
        (fail-closed: an enabled-but-unprovisioned lane is a health signal).
        The per-request answer is always authoritative: ``not_ready`` /
        ``artifact_unavailable`` / ``preprocessing_unverified``.
        """
        deep, siam = _enabled_flags(deepbeat=self._deepbeat_enabled,
                                    siamaf=self._siamaf_enabled)
        if not (deep or siam):
            return True, None
        root = self._model_root or artifact_root()
        missing: list[str] = []
        if deep:
            from .deepbeat import DeepBeatAdapter, ARTIFACT_RELPATH as DB
            ok, why = DeepBeatAdapter(os.path.join(root, DB)).readiness()
            if not ok:
                missing.append(f"deepbeat: {why}")
        if siam:
            from .siamaf import SiamAFAdapter, ARTIFACT_RELPATH as SA
            ok, why = SiamAFAdapter(os.path.join(root, SA)).readiness()
            if not ok:
                missing.append(f"siamaf: {why}")
        if missing:
            return False, "artifact_unavailable: " + "; ".join(missing)
        return True, None

    def capability(self) -> dict[str, Any]:
        deep, siam = _enabled_flags(deepbeat=self._deepbeat_enabled,
                                    siamaf=self._siamaf_enabled)
        return {
            "provider_id": self.provider_id,
            "metric": self.metric,
            "mode": self.mode,
            "publishable": False,
            "label_space": self.label_space,
            "required_signals": list(self.required_signals),
            "eligibility_state": self.eligibility_state,
            "eligibility_reason": self.eligibility_reason,
            "accuracy_label": "unverified_accuracy",
            "release_tier": FAMILY_TIERS.get(_FAMILY, "shadow"),
            "versions": self.versions(),
            "families": [_FAMILY],
            "flags": {ENABLE_DEEPBEAT: deep, ENABLE_SIAMAF: siam},
        }

    def infer(self, request: Any) -> Any:
        """Handle an InferRequest; returns a ProviderResult."""
        from ...contract import ProviderResult

        payload = request.input if request is not None else None
        if not isinstance(payload, Mapping):
            payload = {}
        families = list(payload.get("families") or [])
        if _FAMILY not in families:
            return ProviderResult(status="withheld", withheld_reason=_REASON_NOT_REQUESTED,
                                  final_or_provisional="provisional",
                                  label_space=self.label_space,
                                  versions=self.versions(), publishable=False)
        doc = compute_rhythm_shadow_document(
            payload, model_root=self._model_root,
            deepbeat_enabled=self._deepbeat_enabled,
            siamaf_enabled=self._siamaf_enabled)
        if doc is None:  # pragma: no cover - guarded above
            doc = family_document(family=_FAMILY, status="withheld",
                                  reason=_REASON_NOT_REQUESTED)
        stage = dict(doc)
        raw_scores = stage.pop("raw_scores", None)
        if stage["status"] == "withheld":
            return ProviderResult(status="withheld",
                                  withheld_reason=_wire_reason(stage["reason"]),
                                  final_or_provisional="provisional",
                                  label_space=self.label_space, versions=self.versions(),
                                  raw_scores=raw_scores, publishable=False,
                                  diagnostics={"reason_detail": stage["reason"]})
        if stage["status"] == "error":
            reason = stage.get("reason") or "provider_error"
            return ProviderResult(status="withheld",
                                  withheld_reason=_wire_reason(reason),
                                  final_or_provisional="provisional",
                                  label_space=self.label_space, versions=self.versions(),
                                  raw_scores=raw_scores, publishable=False,
                                  diagnostics={"reason_detail": reason,
                                               "detail": stage.get("detail")})
        # ok: the shadow stage travels in stages; value stays None (no scalar
        # is ever derived from shadow scores).
        return ProviderResult(status="ok", stages=[stage],
                              label_space=self.label_space, versions=self.versions(),
                              raw_scores=raw_scores, publishable=False,
                              coverage={"rhythm_shadow": {"windows": stage.get("adapters", {})
                                                          .get("siamaf", {}).get("windows", 0)}})


def make_providers() -> list[Any]:
    """One rhythm shadow provider; the heavy runtimes load lazily on infer."""
    return [RhythmProvider()]


__all__ = [
    "compute_rhythm_shadow_document", "RhythmProvider", "make_providers",
    "PROVIDER_ID", "METRIC", "LABEL_SPACE", "ADAPTER_VERSION",
    "ENABLE_DEEPBEAT", "ENABLE_SIAMAF",
]
