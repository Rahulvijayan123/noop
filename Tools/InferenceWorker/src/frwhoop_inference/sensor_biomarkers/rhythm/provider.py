"""Rhythm shadow provider (``sensor.biomarkers.rhythm.v1``).

Disabled-by-default research shadow adapter for the ``rhythm_shadow`` family
(spec 6.6/6.7; CONTRACTS.md sections 1-4). Real weights, real execution, no
clinical outputs, never user-facing.

Gates
-----
* ``FRWHOOP_DEEPBEAT_SHADOW_ENABLED`` / ``FRWHOOP_SIAMAF_SHADOW_ENABLED``
  must each be exactly ``"1"`` (off by default; both off -> ``family_disabled``);
* the artifact must exist under the artifact root (``FRWHOOP_MODEL_ROOT`` or
  ``/opt/frwhoop-models``) and match the pinned sha256 before any model is
  loaded (neither enabled model available -> ``model_unavailable``);
* the request must state its native rate, and its sample clock must pass the
  gate (``_common.parse_ppg_payload``), else ``unverified_sample_clock``;
* none of these ever affects the other sensor-biomarker families.

``sensor.biomarkers.v1`` (the route the worker calls) reaches this family
through ``compute_family_documents`` (the optional-family seam,
``sensor_biomarkers/optional.py``); ``RhythmProvider`` serves an explicit
``provider_id`` request with the same ``compute_rhythm_shadow_document``.

Output policy
-------------
* DeepBeat outputs are a tensor-compatibility experiment on UNRESOLVED
  preprocessing: every score is ``preprocessing_unverified`` and
  ``publishable=false``, carried in ``raw_scores`` research logs only; the
  family document is ``withheld`` with reason ``preprocessing_unverified``.
* SiamAF preprocessing is verified from the source repository; its scores are
  computed with ``preprocessing_status=verified_from_source`` but stay
  nonpublishable (WHOOP native-rate domain mismatch + WHOOP/ECG release gate).
* Model windows come from one run at a time; every score vector records the
  native rate, the rate the model was fed after resampling and each window's
  run and start.
* No AF notification, episode count, burden, medication advice or health-score
  contribution is ever produced. Missing/poor/flat/short/mixed-channel or
  unverified-clock input never becomes a reassuring normal classification.
"""

from __future__ import annotations

import os
import time
from typing import Any, Callable, Mapping, Sequence

from ...contract import WithheldReason  # noqa: F401 - wire enum for error mapping
from ..contract import family_document  # W2-owned builder (read-only use)
from .. import (ANALYSIS_VERSION, FAMILY_TIERS,  # noqa: F401 - shared constants
               SCHEMA_VERSION)
from ..optional import (
    STATE_ARTIFACT_UNAVAILABLE,
    STATE_DISABLED,
    STATE_READY,
    make_state,
    state_documents,
)
from ._common import artifact_root, cached_sha256, flag_enabled, parse_ppg_payload
from .deepbeat import ARTIFACT_RELPATH as DEEPBEAT_RELPATH
from .deepbeat import INPUT_RATE_HZ as DEEPBEAT_INPUT_RATE_HZ
from .deepbeat import PROVIDER_REVISION as DEEPBEAT_REVISION
from .deepbeat import SEGMENT_SECONDS as DEEPBEAT_SEGMENT_SECONDS
from .deepbeat import DeepBeatAdapter
from .siamaf import ARTIFACT_RELPATH as SIAMAF_RELPATH
from .siamaf import INPUT_RATE_HZ as SIAMAF_INPUT_RATE_HZ
from .siamaf import PROVIDER_REVISION as SIAMAF_REVISION
from .siamaf import SEGMENT_SECONDS as SIAMAF_SEGMENT_SECONDS
from .siamaf import SiamAFAdapter

ENABLE_DEEPBEAT = "FRWHOOP_DEEPBEAT_SHADOW_ENABLED"
ENABLE_SIAMAF = "FRWHOOP_SIAMAF_SHADOW_ENABLED"

ADAPTER_VERSION = "sensor-biomarkers.rhythm/1.0.0"
PROVIDER_ID = "sensor.biomarkers.rhythm.v1"
METRIC = "sensor_biomarkers"
LABEL_SPACE = "sensor_biomarkers.families/1"

#: Name of this adapter at the optional-family seam, and the families it serves.
ADAPTER_NAME = "rhythm"
FAMILIES = ("rhythm_shadow",)

_FAMILY = "rhythm_shadow"
_REASON_NOT_REQUESTED = "not_ready"
_REASON_NO_PPG = "no_verified_input"
_REASON_BAD_PPG = "blocked_input"
#: Revision of a rhythm stage no model ran for.
_NO_MODEL_REVISION = "rhythm-shadow/none"

#: The two model adapters. A caller may substitute a factory per model (tests
#: put a stand-in network behind the real windowing and assembly this way).
MODEL_ADAPTERS: dict[str, Callable[[str], Any]] = {
    "deepbeat": DeepBeatAdapter,
    "siamaf": SiamAFAdapter,
}
_RELPATHS = {"deepbeat": DEEPBEAT_RELPATH, "siamaf": SIAMAF_RELPATH}
_REVISIONS = {"deepbeat": DEEPBEAT_REVISION, "siamaf": SIAMAF_REVISION}
_MODEL_RATES = {
    "deepbeat": {"model_input_rate_hz": DEEPBEAT_INPUT_RATE_HZ,
                 "segment_seconds": DEEPBEAT_SEGMENT_SECONDS},
    "siamaf": {"model_input_rate_hz": SIAMAF_INPUT_RATE_HZ,
               "segment_seconds": SIAMAF_SEGMENT_SECONDS},
}

#: Bound on the runs listed in a stage's input provenance.
_MAX_LISTED_RUNS = 12


#: Family-level detail reason -> wire WithheldReason mapping for the
#: standalone provider. The family document keeps the precise CONTRACTS detail
#: reason (preprocessing_unverified etc.); the wire envelope needs a value from
#: the sidecar WithheldReason enum, so the closest enum member is used and the
#: detail is preserved in diagnostics.reason_detail.
_WIRE_REASON: dict[str, str] = {
    "preprocessing_unverified": "unverified",
    "unverified_sample_clock": "unverified",
    "not_enough_valid_data": "insufficient_coverage",
    "no_verified_input": "insufficient_coverage",
    "model_unavailable": "blocked_artifact",
    "artifact_unavailable": "blocked_artifact",       # legacy family reason (stored documents)
    "artifact_mismatch": "blocked_artifact",
    "unsupported_native_rate": "blocked_input",
    "family_disabled": "not_ready",
    "runtime_unavailable": "blocked_artifact",
    "adapter_broken": "provider_error",
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


def _models(*, model_root: str | None, deepbeat_enabled: bool | None,
            siamaf_enabled: bool | None,
            model_adapters: Mapping[str, Callable[[str], Any]] | None) -> dict[str, dict]:
    """Each model's flag, adapter instance and readiness (no weights are loaded here)."""
    root = model_root or artifact_root()
    deep, siam = _enabled_flags(deepbeat=deepbeat_enabled, siamaf=siamaf_enabled)
    factories = {**MODEL_ADAPTERS, **(model_adapters or {})}
    out: dict[str, dict] = {}
    for name, enabled in (("deepbeat", deep), ("siamaf", siam)):
        entry: dict[str, Any] = {"enabled": enabled, "adapter": None, "ready": False,
                                 "reason": None}
        if enabled:
            adapter = factories[name](os.path.join(root, _RELPATHS[name]))
            ready, why = adapter.readiness()
            entry.update(adapter=adapter, ready=bool(ready), reason=None if ready else why)
        out[name] = entry
    return out


def _state_from_models(models: Mapping[str, dict]) -> dict[str, Any]:
    flags = {ENABLE_DEEPBEAT: models["deepbeat"]["enabled"],
             ENABLE_SIAMAF: models["siamaf"]["enabled"]}
    summary = {name: {"enabled": m["enabled"], "ready": m["ready"], "reason": m["reason"],
                      **_MODEL_RATES[name]} for name, m in models.items()}
    if not any(m["enabled"] for m in models.values()):
        return make_state(ADAPTER_NAME, STATE_DISABLED,
                          detail=f"{ENABLE_DEEPBEAT} and {ENABLE_SIAMAF} are not exactly 1",
                          flags=flags, models=summary)
    if not any(m["ready"] for m in models.values()):
        detail = "; ".join(f"{name}: {m['reason']}" for name, m in models.items() if m["enabled"])
        mismatch = any(m["reason"] == "artifact_mismatch" for m in models.values())
        return make_state(ADAPTER_NAME, STATE_ARTIFACT_UNAVAILABLE, detail=detail,
                          detail_code="artifact_mismatch" if mismatch else "artifact_missing",
                          flags=flags, models=summary)
    return make_state(ADAPTER_NAME, STATE_READY, flags=flags, models=summary)


def loaded_identity(*, model_root: str | None = None, deepbeat_enabled: bool | None = None,
                    siamaf_enabled: bool | None = None,
                    model_adapters: Mapping[str, Callable[[str], Any]] | None = None
                    ) -> dict[str, str]:
    """sha256 of each enabled, verified rhythm checkpoint, keyed ``<model>.sha256``.

    The digest is measured from the bytes (cached by size and mtime), never copied from the pin;
    a model loads only after the same check. Disabled or unverified models report nothing.
    """
    models = _models(model_root=model_root, deepbeat_enabled=deepbeat_enabled,
                     siamaf_enabled=siamaf_enabled, model_adapters=model_adapters)
    out: dict[str, str] = {}
    for name, m in sorted(models.items()):
        adapter = m["adapter"]
        if not (m["enabled"] and m["ready"]) or adapter is None:
            continue
        digest = getattr(adapter, "loaded_sha256", None)
        path = getattr(adapter, "checkpoint_path", None)
        if not digest and path:
            digest = cached_sha256(path)
        if digest:
            out[f"{name}.sha256"] = str(digest).lower()
    return out


def adapter_state(*, model_root: str | None = None, deepbeat_enabled: bool | None = None,
                  siamaf_enabled: bool | None = None,
                  model_adapters: Mapping[str, Callable[[str], Any]] | None = None
                  ) -> dict[str, Any]:
    """Whether rhythm_shadow can run here: flags, then the enabled models' artifacts.

    Cheap: artifact hashes are cached by file size and mtime, nothing is loaded.
    """
    return _state_from_models(_models(model_root=model_root, deepbeat_enabled=deepbeat_enabled,
                                      siamaf_enabled=siamaf_enabled,
                                      model_adapters=model_adapters))


def _state_document(state: Mapping[str, Any], models: Mapping[str, dict]) -> dict[str, Any]:
    doc = state_documents([_FAMILY], state)[0]
    doc["provider_revision"] = _NO_MODEL_REVISION
    doc["adapters"] = {name: {"status": "error" if m["enabled"] else "disabled", "ran": False,
                              "reason": m["reason"], "windows": 0}
                       for name, m in models.items()}
    return doc


def _withheld(reason: str, *, counts: dict[str, int] | None = None,
              extra: dict[str, Any] | None = None, status: str = "withheld") -> dict[str, Any]:
    return family_document(family=_FAMILY, status=status, reason=reason,
                           provider_revision=_NO_MODEL_REVISION, reason_counts=counts,
                           extra=extra)


def _input_provenance(ppg: Mapping[str, Any]) -> dict[str, Any]:
    runs = ppg["runs"]
    listed = sorted(runs, key=lambda r: (-r["duration_s"], r["start_unix"]))[:_MAX_LISTED_RUNS]
    listed.sort(key=lambda r: r["start_unix"])
    return {
        "native_rate_hz": ppg["native_rate_hz"],
        "clock_gate": ppg["clock_gate"],
        "runs": len(runs),
        "runs_clock_verified": sum(1 for r in runs if r["clock_verified"]),
        "listed": [{"run": r["key"], "start_unix": r["start_unix"], "duration_s": r["duration_s"],
                    "segments": r["segments"], "clock_verified": r["clock_verified"]}
                   for r in listed],
        "listed_truncated": len(runs) - len(listed),
    }


def _rhythm_document(
    input_payload: Mapping[str, Any],
    *,
    model_root: str | None = None,
    deepbeat_enabled: bool | None = None,
    siamaf_enabled: bool | None = None,
    model_adapters: Mapping[str, Callable[[str], Any]] | None = None,
    deadline_s: float | None = None,
) -> dict[str, Any]:
    """The one implementation of the rhythm_shadow family document."""
    models = _models(model_root=model_root, deepbeat_enabled=deepbeat_enabled,
                     siamaf_enabled=siamaf_enabled, model_adapters=model_adapters)
    state = _state_from_models(models)
    if state["state"] != STATE_READY:
        return _state_document(state, models)

    ppg_raw = (input_payload or {}).get("ppg")
    if ppg_raw is None or (isinstance(ppg_raw, dict) and not ppg_raw.get("segments")):
        return _withheld(_REASON_NO_PPG, counts={"no_verified_ppg_objects": 1})
    try:
        ppg = parse_ppg_payload(ppg_raw)
    except ValueError as exc:
        return _withheld(_REASON_BAD_PPG, status="error", extra={"detail": str(exc)[:300]})
    provenance = _input_provenance(ppg)
    if not ppg["clock_verified"]:
        return _withheld("unverified_sample_clock",
                         counts={"unverified_sample_clock_runs": len(ppg["runs"])},
                         extra={"input_provenance": provenance})

    # -- run the enabled, available adapters on the clock-verified runs ------
    deadline = None if deadline_s is None else time.monotonic() + max(0.0, deadline_s)
    results: dict[str, dict[str, Any]] = {}
    for name, model in models.items():
        if not model["enabled"]:
            continue
        if not model["ready"]:
            results[name] = {"status": "error", "reason": model["reason"] or "artifact_unavailable",
                             "windows": 0, "ran": False}
            continue
        try:
            result = dict(model["adapter"].infer(ppg, deadline=deadline))
        except Exception as exc:  # noqa: BLE001 - one model's defect is its own error
            result = {"status": "error", "reason": "provider_error",
                      "detail": f"{type(exc).__name__}: {exc}"[:300], "windows": 0}
        result["ran"] = True
        results[name] = result

    # -- assemble the family stage -----------------------------------------
    measurements: dict[str, Any] = {}
    raw_scores: dict[str, Any] = {}
    adapters: dict[str, Any] = {}
    for name, result in results.items():
        if result.get("windows", 0) > 0:
            if name == "deepbeat":
                # Compatibility experiment scores: research logs only (never a
                # publishable measurement on unresolved preprocessing).
                raw_scores["deepbeat_quality_scores"] = result.get("quality")
                raw_scores["deepbeat_rhythm_scores"] = result.get("rhythm")
            else:
                # Verified-from-source preprocessing: measurement in the stage,
                # still nonpublishable (WHOOP domain + release gate).
                measurements["siamaf_rhythm_scores"] = result.get("rhythm")
                raw_scores["siamaf_rhythm_scores"] = result.get("rhythm")
        adapters[name] = {"status": result["status"], "ran": result["ran"],
                          "reason": result.get("reason"), "windows": result.get("windows", 0),
                          **_MODEL_RATES[name],
                          **({"detail": result["detail"]} if result.get("detail") else {})}

    # -- family status ------------------------------------------------------
    # The family is "ok" only when a verified-preprocessing adapter produced
    # scores. DeepBeat-only output is withheld (preprocessing_unverified) even
    # though the compatibility scores are preserved in raw_scores.
    if measurements:
        status, reason = "ok", None
    elif raw_scores:
        status, reason = "withheld", "preprocessing_unverified"
    else:
        # Family-level reason uses the canonical vocabulary: an adapter whose
        # weights are missing ("artifact_unavailable") or mismatched
        # ("artifact_mismatch") is "model_unavailable" at the family level (the
        # precise detail stays in ``adapters``).
        family_reason = None
        for adapter in adapters.values():
            candidate = adapter.get("reason")
            if candidate in ("artifact_unavailable", "artifact_mismatch"):
                family_reason = "model_unavailable"
                break
            family_reason = family_reason or candidate
        status, reason = "withheld", family_reason or "not_ready"

    extra: dict[str, Any] = {"adapters": adapters, "schema_version": SCHEMA_VERSION,
                             "input_provenance": provenance}
    if raw_scores:
        extra["raw_scores"] = raw_scores
    counts = dict(ppg["run_counts"])
    unverified = provenance["runs"] - provenance["runs_clock_verified"]
    if unverified:
        counts["unverified_sample_clock_runs"] = unverified
    # The family's provider_revision names the adapters that actually ran (a
    # SiamAF-only shadow is never labelled deepbeat/1.0.0). "_" joins them
    # because the day table accepts only [A-Za-z0-9._/-] in a revision.
    ran = [name for name in ("deepbeat", "siamaf") if adapters.get(name, {}).get("ran")]
    provider_revision = "_".join(_REVISIONS[name] for name in ran) or _NO_MODEL_REVISION
    return family_document(
        family=_FAMILY, status=status, reason=reason, measurements=measurements,
        provider_revision=provider_revision, reason_counts=counts, extra=extra)


def compute_rhythm_shadow_document(
    input_payload: Mapping[str, Any],
    *,
    model_root: str | None = None,
    deepbeat_enabled: bool | None = None,
    siamaf_enabled: bool | None = None,
    model_adapters: Mapping[str, Callable[[str], Any]] | None = None,
    deadline_s: float | None = None,
) -> dict[str, Any] | None:
    """Build the ``rhythm_shadow`` family stage for one request.

    Returns ``None`` when the request does not ask for ``rhythm_shadow``.
    Otherwise returns the family document (CONTRACTS.md section 3 shape).
    Never raises for bad input: a malformed payload becomes a family with a
    machine-readable reason. ``model_root`` overrides the artifact root (tests
    use a staged temporary root); the enable flags default to the worker env;
    ``model_adapters`` substitutes a model adapter factory per model.
    """
    families = list((input_payload or {}).get("families") or [])
    if _FAMILY not in families:
        return None
    return _rhythm_document(input_payload, model_root=model_root,
                            deepbeat_enabled=deepbeat_enabled, siamaf_enabled=siamaf_enabled,
                            model_adapters=model_adapters, deadline_s=deadline_s)


def compute_family_documents(input_payload: Mapping[str, Any], families: Sequence[str], *,
                             deadline_s: float | None = None,
                             model_adapters: Mapping[str, Callable[[str], Any]] | None = None,
                             model_root: str | None = None) -> list[dict[str, Any]]:
    """rhythm_shadow for ``sensor.biomarkers.v1`` (the optional-family seam)."""
    if _FAMILY not in families:
        return []
    payload = input_payload if isinstance(input_payload, Mapping) else {}
    return [_rhythm_document(payload, model_root=model_root, model_adapters=model_adapters,
                             deadline_s=deadline_s)]


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
        The per-request answer is always authoritative: ``family_disabled`` /
        ``artifact_unavailable`` / ``preprocessing_unverified``.
        """
        models = _models(model_root=self._model_root, deepbeat_enabled=self._deepbeat_enabled,
                         siamaf_enabled=self._siamaf_enabled, model_adapters=None)
        if not any(m["enabled"] for m in models.values()):
            return True, None
        missing = [f"{name}: {m['reason']}" for name, m in models.items()
                   if m["enabled"] and not m["ready"]]
        if missing:
            return False, "artifact_unavailable: " + "; ".join(missing)
        return True, None

    def loaded_identity(self) -> dict[str, str]:
        """The verified checkpoint digests of the enabled models (``/healthz`` identity)."""
        return loaded_identity(model_root=self._model_root, deepbeat_enabled=self._deepbeat_enabled,
                               siamaf_enabled=self._siamaf_enabled)

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
            "canonical_route": "sensor.biomarkers.v1",
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
    "compute_rhythm_shadow_document", "compute_family_documents", "adapter_state",
    "RhythmProvider", "make_providers", "PROVIDER_ID", "METRIC", "LABEL_SPACE",
    "ADAPTER_VERSION", "ADAPTER_NAME", "FAMILIES", "ENABLE_DEEPBEAT", "ENABLE_SIAMAF",
    "MODEL_ADAPTERS",
]
