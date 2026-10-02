"""The sleep candidates behind the real registry and the extended contract.

These tests run against the landed package (no path hacks, no stubs): the registry built by
``default_providers()``, the real ``ProviderResult`` with its new ``stages`` field, and the
real server renderer ``_render_result_payload``.
"""

from __future__ import annotations

import os

import sleep_fixtures as F
from frwhoop_inference.contract import ProviderResult, WithheldReason
from frwhoop_inference.frwhoop_sleep.registry_adapter import (
    RegistryShim,
    register_into,
    sleep_providers,
    wrap_boundary,
    wrap_stage,
)
from frwhoop_inference.providers import ProviderRegistry, default_providers
from frwhoop_inference.server import _render_result_payload

MANIFEST_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                             "models", "manifest.json")

BOUNDARY_ID = "hypnospy.hr-boundary.v1"
STAGE_ID = "sleepecg.wrn-gru-mesa.v1"


def test_default_providers_registers_both_sleep_candidates():
    registry = ProviderRegistry(default_providers())
    ids = [p.provider_id for p in registry.all()]
    assert BOUNDARY_ID in ids and STAGE_ID in ids
    assert [p.provider_id for p in registry.for_metric("sleep_boundary")] == [BOUNDARY_ID]
    assert [p.provider_id for p in registry.for_metric("sleep_stage")] == [STAGE_ID]
    # HRV providers are untouched
    assert [p.provider_id for p in registry.for_metric("hrv")] == [
        "production.runs.v1", "neurokit2.shadow.v1"]


def test_sleepecg_artifacts_verify_from_the_staged_root(sleep_model_root):
    """The readiness gate is exercised with the real bytes, not a stub."""
    from frwhoop_inference.artifacts import load_manifest, verify_manifest

    state = verify_manifest(load_manifest(MANIFEST_PATH), sleep_model_root,
                            manifest_path=MANIFEST_PATH)
    assert state.ok is True
    verified = [c for c in state.checks if c.required_for_readiness]
    assert {c.entry_id for c in verified} == {"sleepecg_wrn_gru_mesa"}
    assert all(c.status == "verified" for c in verified)
    assert all(c.actual_size for c in verified)


def test_sleep_shims_expose_the_registry_protocol():
    for shim in sleep_providers():
        assert isinstance(shim, RegistryShim)
        for attribute in ("provider_id", "metric", "mode", "label_space", "required_signals",
                          "eligibility_state", "eligibility_reason"):
            assert hasattr(shim, attribute), attribute
        ready, reason = shim.readiness()
        assert isinstance(ready, bool)
        assert reason is None or isinstance(reason, str)
        capability = shim.capability()
        assert capability["publishable"] is False
        assert capability["eligibility_state"] == "shadow_eligible"
        assert capability["accuracy_label"] == "unverified_accuracy"
        assert isinstance(shim.versions(), dict)


def test_boundary_ok_result_carries_stages_and_label_space():
    shim = wrap_boundary()
    data = F.normal_night().build()
    gt = data["ground_truth"]
    request = type("Req", (), {
        "input": {"hr": data["hr"]},
        "context": {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
                    "interval_start_utc": gt["in_bed_utc"][0],
                    "interval_end_utc": gt["in_bed_utc"][1]},
        "provider_id": None})()
    result = shim.infer(request)
    assert isinstance(result, ProviderResult)
    assert result.status == "ok"
    assert result.stages and isinstance(result.stages, list)
    assert result.label_space == "in_bed/sleep_onset/final_wake/nap/waso"
    for segment in result.stages:
        assert segment["stage"] == segment["label"]
        assert segment["kind"] in {"in_bed", "sleep_onset", "final_wake", "nap", "waso"}
        assert segment["end_utc"] > segment["start_utc"]
    # the server renders stages + label_space
    payload = _render_result_payload(result)
    assert payload["stages"] == result.stages
    assert payload["label_space"] == result.label_space
    assert payload["value"] is not None and payload["value"] >= 0
    assert result.publishable is False


def test_stage_ok_result_is_three_class_and_rendered():
    shim = wrap_stage()
    series = F.rr_series_from_fixture(F.normal_night())
    request = type("Req", (), {
        "input": {"rr": series["rr"], "window": series["window"],
                  "age": series["age"], "gender": series["gender"]},
        "context": {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
                    "interval_start_utc": series["window"]["start_utc"],
                    "interval_end_utc": series["window"]["end_utc"]},
        "provider_id": None})()
    result = shim.infer(request)
    assert isinstance(result, ProviderResult)
    assert result.status == "ok"
    assert result.label_space == "wake/rem/nrem"
    assert {segment["stage"] for segment in result.stages} <= {"wake", "rem", "nrem"}
    assert result.raw_scores["calibrated"] is False
    payload = _render_result_payload(result)
    assert payload["label_space"] == "wake/rem/nrem"
    assert payload["stages"]


def test_withheld_results_never_carry_stages():
    shim = wrap_boundary()
    data = F.quiet_awake_in_bed().build()
    gt = data["ground_truth"]
    result = shim.infer(type("Req", (), {
        "input": {"hr": data["hr"]},
        "context": {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
                    "interval_start_utc": gt["in_bed_utc"][0],
                    "interval_end_utc": gt["in_bed_utc"][1]},
        "provider_id": None})())
    assert result.status == "withheld"
    assert result.stages is None and result.value is None
    assert result.withheld_reason in {r.value for r in WithheldReason}
    assert _render_result_payload(result) is None


def test_input_error_maps_to_a_valid_withheld_result():
    shim = wrap_boundary()
    result = shim.infer(type("Req", (), {
        "input": {"hr": "not-a-list"},
        "context": {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
                    "interval_start_utc": 1, "interval_end_utc": 2},
        "provider_id": None})())
    assert isinstance(result, ProviderResult)
    assert result.status == "withheld"
    assert result.withheld_reason == "blocked_input"
    assert result.diagnostics["reason_detail"] == "invalid_hr"


def test_register_into_appends_without_disturbing_hrv():
    """``register_into`` is additive: an HRV-only registry keeps its order and gains two."""
    from frwhoop_inference.providers import HrvNeurokitShadowProvider, HrvProductionProvider

    registry = ProviderRegistry([HrvProductionProvider(), HrvNeurokitShadowProvider()])
    before = [p.provider_id for p in registry.all()]
    shims = register_into(registry)
    assert len(shims) == 2
    after = [p.provider_id for p in registry.all()]
    assert after[:len(before)] == before
    assert set(after) - set(before) == {BOUNDARY_ID, STAGE_ID}
    # default_providers() already includes them, so registering again is idempotent by id
    full = ProviderRegistry(default_providers())
    register_into(full)
    assert len(full.all()) == 4
