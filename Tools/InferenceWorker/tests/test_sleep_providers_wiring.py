"""End-to-end wiring: the sleep metrics through the real request path.

Goes through ``parse_request`` (the metric gate that used to answer 503 for anything but
HRV), the real registry, ``run_inference`` and the server's result renderer, so it proves the
candidates are actually reachable rather than merely importable.
"""

from __future__ import annotations

from datetime import datetime, timezone

import sleep_fixtures as F
from frwhoop_inference.contract import parse_request
from frwhoop_inference.providers import ProviderRegistry, default_providers
from frwhoop_inference.server import Application, run_inference

BOUNDARY_ID = "hypnospy.hr-boundary.v1"
STAGE_ID = "sleepecg.wrn-gru-mesa.v1"


def _iso(ts: int) -> str:
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _context(interval_start: int, interval_end: int, tz: str = F.DEFAULT_TZ) -> dict:
    return {
        "user_id": "11111111-2222-3333-4444-555555555555",
        "device_id": "whoop5-abcdef",
        "interval_start_utc": _iso(interval_start),
        "interval_end_utc": _iso(interval_end),
        "iana_timezone": tz,
        "profile_version": "profile-1",
        "config_version": "cfg-1",
        "corrections_version": "corr-0",
    }


def _app(model_root=None) -> Application:
    return Application.build(registry=ProviderRegistry(default_providers()),
                             model_root=model_root)


def test_parse_request_accepts_both_sleep_metrics():
    data = F.normal_night().build()
    gt = data["ground_truth"]
    body = {"metric": "sleep_boundary",
            "context": _context(gt["in_bed_utc"][0], gt["in_bed_utc"][1]),
            "input": {"hr": data["hr"]},
            "provider": {}}
    request = parse_request(body)
    assert request.metric == "sleep_boundary"
    assert isinstance(request.input, dict)
    assert request.input_sha256

    series = F.rr_series_from_fixture(F.normal_night())
    body2 = {"metric": "sleep_stage",
             "context": _context(series["window"]["start_utc"], series["window"]["end_utc"]),
             "input": {"rr": series["rr"], "window": series["window"],
                       "age": series["age"], "gender": series["gender"]},
             "provider": {}}
    request2 = parse_request(body2)
    assert request2.metric == "sleep_stage"
    assert any(ref.get("kind") == "rr_intervals" for ref in request2.input_refs)


def test_boundary_inference_renders_stages_over_the_real_path(sleep_model_root):
    data = F.normal_night().build()
    gt = data["ground_truth"]
    request = parse_request({"metric": "sleep_boundary",
                             "context": _context(gt["in_bed_utc"][0], gt["in_bed_utc"][1]),
                             "input": {"hr": data["hr"]}, "provider": {}})
    response = run_inference(_app(sleep_model_root), request)
    assert response["status"] == "ok"
    assert response["provider_id"] == BOUNDARY_ID
    result = response["result"]
    assert result["label_space"] == "in_bed/sleep_onset/final_wake/nap/waso"
    assert result["stages"], "the server must render the structured boundary result"
    assert result["value"] is not None and result["value"] > 0
    kinds = {segment["kind"] for segment in result["stages"]}
    assert "sleep_onset" in kinds and "final_wake" in kinds
    assert response["label_space"] == result["label_space"]
    assert response["publishable"] is False
    assert response["diagnostics"]["result"]["unscored"] == []
    assert response["coverage"]["hr_coverage_fraction"] > 0.9


def test_stage_inference_renders_three_class_stages_over_the_real_path(sleep_model_root):
    series = F.rr_series_from_fixture(F.normal_night())
    request = parse_request({"metric": "sleep_stage",
                             "context": _context(series["window"]["start_utc"],
                                                 series["window"]["end_utc"]),
                             "input": {"rr": series["rr"], "window": series["window"],
                                       "age": series["age"], "gender": series["gender"]},
                             "provider": {}})
    response = run_inference(_app(sleep_model_root), request)
    assert response["status"] == "ok"
    assert response["provider_id"] == STAGE_ID
    result = response["result"]
    assert result["label_space"] == "wake/rem/nrem"
    assert result["stages"]
    assert {segment["stage"] for segment in result["stages"]} <= {"wake", "rem", "nrem"}
    assert response["raw_scores"]["calibrated"] is False
    assert response["publishable"] is False


def test_withheld_sleep_result_has_no_result_payload(sleep_model_root):
    data = F.quiet_awake_in_bed().build()
    gt = data["ground_truth"]
    request = parse_request({"metric": "sleep_boundary",
                             "context": _context(gt["in_bed_utc"][0], gt["in_bed_utc"][1]),
                             "input": {"hr": data["hr"]}, "provider": {}})
    response = run_inference(_app(sleep_model_root), request)
    assert response["status"] == "withheld"
    assert response["result"] is None
    assert response["withheld_reason"]


def test_healthz_and_capability_list_the_sleep_providers(sleep_model_root):
    app = _app(sleep_model_root)
    health = app.healthz()
    providers = health["providers"]
    assert BOUNDARY_ID in providers and STAGE_ID in providers
    assert providers[BOUNDARY_ID]["version"]
    assert providers[STAGE_ID]["version"]
    listing = app.providers_capability()
    ids = {entry["provider_id"] for entry in listing["providers"]}
    assert {BOUNDARY_ID, STAGE_ID} <= ids
    for entry in listing["providers"]:
        if entry["provider_id"] in {BOUNDARY_ID, STAGE_ID}:
            assert entry["metric"] in {"sleep_boundary", "sleep_stage"}
            assert entry["label_space"]
            assert entry["required_signals"]


def test_unknown_provider_for_sleep_metric_is_reported_not_crashed(sleep_model_root):
    """An unknown provider id is a typed 404, never a crash."""
    import pytest

    from frwhoop_inference.contract import ContractError

    data = F.normal_night().build()
    gt = data["ground_truth"]
    request = parse_request({"metric": "sleep_boundary",
                             "context": _context(gt["in_bed_utc"][0], gt["in_bed_utc"][1]),
                             "input": {"hr": data["hr"]},
                             "provider": {"provider_id": "nope.v1"}})
    with pytest.raises(ContractError) as excinfo:
        run_inference(_app(sleep_model_root), request)
    assert excinfo.value.code == "unknown_provider"
    assert excinfo.value.http_status == 404
