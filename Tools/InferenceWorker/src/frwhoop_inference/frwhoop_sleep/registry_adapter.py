"""Present the sleep candidates through the ``frwhoop_inference`` registry protocol.

The registry surface is ``provider_id, metric, mode, label_space, required_signals,
eligibility_state, eligibility_reason`` plus ``versions/readiness/capability/infer``
(see ``frwhoop_inference.providers.Provider``).

The providers themselves return the wire-response dict
(``{"status", "metric", "provider_id", "versions", "input", "result", "interval",
"coverage", "raw_scores", "diagnostics", "runtime_ms", ...}``). This adapter maps that dict
onto :class:`frwhoop_inference.contract.ProviderResult`.

Structured results
------------------
Both metrics are structured, and the extended contract now supports them:

* ``sleep_boundary`` -> ``stages`` = the boundary intervals, ``label_space`` =
  ``in_bed/sleep_onset/final_wake/nap/waso``;
* ``sleep_stage``    -> ``stages`` = the three-class hypnogram segments, ``label_space`` =
  ``wake/rem/nrem``.

``value`` carries a finite scalar summary (scored sleep seconds / staged seconds) so that
consumers that only read ``value`` still get a number. ``unit`` is ``"s"``.

Every segment carries ``stage`` (the label, matching the contract's example segment shape)
as well as ``label`` and the ``start_utc``/``end_utc`` bounds, so a consumer can use either
naming. ``withheld`` results never carry ``stages`` (the contract forbids it).
"""

from __future__ import annotations

from typing import Any, Optional

from ..contract import ProviderResult

__all__ = ["RegistryShim", "register_into", "sleep_providers", "wrap_boundary", "wrap_stage"]


def _as_mapping(value: Any) -> dict:
    if value is None:
        return {}
    if isinstance(value, dict):
        return dict(value)
    to_wire = getattr(value, "to_wire", None)
    if callable(to_wire):
        wire = to_wire()
        return dict(wire) if isinstance(wire, dict) else {}
    if isinstance(value, (list, tuple)):
        return {"rr": list(value)}
    return {}


def _segments(result: dict) -> Optional[list]:
    """Structured segments for a provider result, or None when there are none."""
    intervals = result.get("intervals")
    if intervals:
        return [dict(segment) for segment in intervals]
    stages = result.get("stages")
    if stages:
        return [dict(segment) for segment in stages]
    return None


class RegistryShim:
    """Present one sleep provider through the registry protocol."""

    def __init__(self, provider, *, eligibility_state: str = "shadow_eligible",
                 eligibility_reason: Optional[str] = None, publishable: bool = False):
        self._provider = provider
        self.provider_id = provider.provider_id
        self.metric = provider.metric
        self.mode = provider.mode
        self.label_space = provider.label_space
        self.required_signals = tuple(provider.required_signals)
        self.eligibility_state = eligibility_state
        self.eligibility_reason = eligibility_reason
        self.publishable = publishable

    # -- protocol surface ------------------------------------------------------
    def versions(self, request=None) -> dict:
        return dict(self._provider.manifest()["versions"])

    def readiness(self) -> tuple[bool, Optional[str]]:
        report = self._provider.readiness()
        return bool(report.get("ready")), report.get("reason")

    def capability(self) -> dict:
        capability = dict(self._provider.manifest())
        capability["publishable"] = self.publishable
        capability["eligibility_state"] = self.eligibility_state
        capability["eligibility_reason"] = self.eligibility_reason
        capability["accuracy_label"] = "unverified_accuracy"
        return capability

    def infer(self, request) -> ProviderResult:
        payload = _as_mapping(getattr(request, "input", None))
        context = _as_mapping(getattr(request, "context", None))
        provider_id = getattr(request, "provider_id", None)
        response = self._provider.infer(
            input=payload, context=context,
            provider={"provider_id": provider_id} if provider_id else None)
        return self._to_result(response)

    # -- mapping ---------------------------------------------------------------
    def _to_result(self, response: dict) -> ProviderResult:
        result = dict(response.get("result") or {})
        diagnostics = dict(response.get("diagnostics") or {})
        diagnostics["result"] = result
        diagnostics["interval"] = response.get("interval")
        diagnostics["input"] = response.get("input")
        status = response.get("status", "error")
        versions = dict(response.get("versions") or self.versions())

        if status == "ok":
            segments = _segments(result)
            for segment in segments or ():
                # Boundary intervals are labelled by ``kind``; hypnogram segments by
                # ``label``. Expose both as ``stage``/``label`` so a consumer can use one name.
                label = segment.get("label") or segment.get("stage") or segment.get("kind")
                if label is not None:
                    segment["label"] = label
                    segment["stage"] = label
            return ProviderResult(
                status="ok",
                value=self._scalar(result),
                unit="s",
                withheld_reason=None,
                label_space=response.get("label_space") or self.label_space,
                stages=segments,
                final_or_provisional=response.get("final_or_provisional", "final"),
                coverage=dict(response.get("coverage") or {}),
                diagnostics=diagnostics,
                versions=versions,
                raw_scores=response.get("raw_scores"),
                publishable=self.publishable,
            )

        if status == "error":
            # ProviderResult has no "error" status. Report a withheld result with a
            # machine-readable reason; the specific code stays in diagnostics.reason_detail.
            detail = str(diagnostics.get("reason_detail") or "provider_error")
            # Map the specific code to the closest wire reason (review F9): a missing or
            # mismatched checkpoint is an artifact fault, not a provider bug, so an operator can
            # tell "weights absent" from "provider crashed".
            if detail in {
                "invalid_timezone", "invalid_hr", "invalid_rr", "missing_hr", "missing_rr",
                "invalid_interval", "invalid_timestamp", "unknown_params", "unknown_config",
                "invalid_search_window", "invalid_grid", "empty_interval", "no_rr_in_window",
                "analysis_day_mismatch", "provider_id_mismatch", "invalid_interval_window",
                "invalid_config",
            }:
                reason = "blocked_input"
            elif detail in {"checkpoint_missing", "artifact_mismatch"}:
                reason = "blocked_artifact"
            elif detail in {"dependency_missing", "not_ready"}:
                reason = "not_ready"
            else:
                reason = "provider_error"
            return ProviderResult(
                status="withheld",
                value=None, unit=None, withheld_reason=reason,
                label_space=self.label_space, stages=None,
                final_or_provisional="provisional",
                coverage=dict(response.get("coverage") or {}),
                diagnostics=diagnostics, versions=versions,
                raw_scores=None, publishable=self.publishable,
            )

        return ProviderResult(
            status="withheld",
            value=None, unit=None,
            withheld_reason=response.get("withheld_reason") or "provider_error",
            label_space=self.label_space, stages=None,
            final_or_provisional=response.get("final_or_provisional", "provisional"),
            coverage=dict(response.get("coverage") or {}),
            diagnostics=diagnostics, versions=versions,
            raw_scores=None, publishable=self.publishable,
        )

    @staticmethod
    def _scalar(result: dict) -> float:
        """Finite scalar summary; the structured payload travels in ``stages``."""
        if result.get("value") is not None:
            return float(result["value"])
        intervals = result.get("intervals")
        if intervals:
            total = 0
            for entry in intervals:
                if entry.get("kind") in {"sleep_onset", "final_wake"}:
                    total = max(total, int(entry["end_utc"]) - int(entry["start_utc"]))
            return float(total)
        stages = result.get("stages")
        if stages:
            return float(sum(int(segment.get("seconds", 0)) for segment in stages))
        return 0.0


def wrap_boundary(provider=None) -> RegistryShim:
    from .providers.sleep_boundary import PROVIDER

    return RegistryShim(provider or PROVIDER)


def wrap_stage(provider=None) -> RegistryShim:
    from .providers.sleep_stage import PROVIDER

    return RegistryShim(provider or PROVIDER)


def sleep_providers() -> list:
    """The two sleep candidates, ready to register."""
    return [wrap_boundary(), wrap_stage()]


def register_into(registry) -> list:
    """Register both sleep candidates in a ``ProviderRegistry``."""
    shims = sleep_providers()
    for shim in shims:
        registry.register(shim)
    return shims
