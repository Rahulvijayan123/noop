"""Three-class isolation, the sidecar response contract, and day-boundary arithmetic."""

import json
import math
import re

import pytest

import sleep_fixtures as F
from frwhoop_inference.frwhoop_sleep import timebase
from frwhoop_inference.frwhoop_sleep.providers.sleep_boundary import PROVIDER as BOUNDARY
from frwhoop_inference.frwhoop_sleep.providers.sleep_stage import PROVIDER as STAGE

from test_sleep_boundary import call as call_boundary
from test_sleep_stage import call as call_stage

FORBIDDEN_STAGE_KEYS = ("light", "deep", "awake")
WITHHELD_REASONS = {
    "blocked_input", "blocked_artifact", "blocked_license", "unverified",
    "insufficient_coverage", "artifact_fraction", "provider_error", "timeout", "not_ready",
}


def _walk_keys(node, out):
    if isinstance(node, dict):
        for key, value in node.items():
            out.add(key)
            _walk_keys(value, out)
    elif isinstance(node, list):
        for item in node:
            _walk_keys(item, out)
    return out


def test_sleep_stage_result_never_exposes_four_stage_fields():
    response, _ = call_stage(F.normal_night())
    keys = _walk_keys(response["result"], set())
    for forbidden in FORBIDDEN_STAGE_KEYS:
        assert forbidden not in keys
    assert response["result"]["label_space"] == "wake/rem/nrem"
    for stage in response["result"]["stages"]:
        assert stage["label"] in {"wake", "rem", "nrem"}


def test_sleep_boundary_result_never_exposes_stage_fields():
    response, _ = call_boundary(F.normal_night())
    keys = _walk_keys(response["result"], set())
    for forbidden in FORBIDDEN_STAGE_KEYS:
        assert forbidden not in keys
    assert response["result"]["label_space"] == "in_bed/sleep_onset/final_wake/nap/waso"
    for interval in response["result"]["intervals"]:
        assert interval["kind"] in {"in_bed", "sleep_onset", "final_wake", "nap", "waso"}


@pytest.mark.parametrize("status_response", [
    call_boundary(F.quiet_awake_in_bed())[0],
    call_boundary(F.user_edited_bounds())[0],
])
def test_boundary_withheld_responses_carry_a_contract_reason(status_response):
    assert status_response["status"] == "withheld"
    assert status_response["withheld_reason"] in WITHHELD_REASONS
    assert status_response["result"] is None
    assert status_response["raw_scores"] is None


def test_responses_are_json_serialisable_and_finite():
    for response in (call_boundary(F.normal_night())[0], call_stage(F.normal_night())[0]):
        encoded = json.dumps(response, allow_nan=False)
        assert encoded
        assert response["runtime_ms"] >= 0
        assert isinstance(response["versions"], dict)
        for key in ("adapter", "preprocessing", "dependency", "config", "model"):
            assert key in response["versions"]


def test_boundary_response_has_no_non_finite_numbers():
    response, _ = call_boundary(F.normal_night_with_gaps())
    text = json.dumps(response, allow_nan=False)
    assert "NaN" not in text and "Infinity" not in text


def test_analysis_block_follows_the_zone_across_a_dst_transition():
    zone = timebase.parse_zone("America/New_York")
    # 2026-11-01 is the US fall-back: the local day is 25 h, so 20:00 -> 12:00 is 17 h
    start, end = timebase.analysis_block(timebase.date(2026, 11, 1), zone, 20, 12)
    assert (end - start) / 3600 == 17.0
    # 2026-03-08 is the US spring-forward: 23 h local day, so the block is 15 h
    start, end = timebase.analysis_block(timebase.date(2026, 3, 8), zone, 20, 12)
    assert (end - start) / 3600 == 15.0
    # an ordinary day is 16 h
    start, end = timebase.analysis_block(timebase.date(2026, 10, 19), zone, 20, 12)
    assert (end - start) / 3600 == 16.0


def test_wake_date_ownership_uses_the_local_calendar_date_of_the_wake_timestamp():
    zone = timebase.parse_zone("America/New_York")
    onset = int(timebase.datetime(2026, 10, 18, 22, 45, tzinfo=zone).timestamp())
    wake = int(timebase.datetime(2026, 10, 19, 7, 5, tzinfo=zone).timestamp())
    assert timebase.local_day(wake, zone).isoformat() == "2026-10-19"
    assert timebase.local_day(onset, zone).isoformat() == "2026-10-18"


def test_daytime_search_window_block_starts_on_the_wake_day():
    zone = timebase.parse_zone("America/New_York")
    start, end = timebase.analysis_block(timebase.date(2026, 10, 19), zone, 5, 16)
    assert timebase.local_datetime(start, zone).hour == 5
    assert timebase.local_datetime(end, zone).hour == 16
    assert timebase.local_datetime(start, zone).date().isoformat() == "2026-10-19"


def test_invalid_timezone_is_rejected_cleanly():
    response, data = call_boundary(F.normal_night())
    ctx = {"iana_timezone": "Mars/Olympus",
           "interval_start_utc": data["ground_truth"]["in_bed_utc"][0],
           "interval_end_utc": data["ground_truth"]["in_bed_utc"][1]}
    out = BOUNDARY.infer(input={"hr": data["hr"]}, context=ctx)
    assert out["status"] == "error"
    assert out["diagnostics"]["reason_detail"] == "invalid_timezone"


def test_malformed_hr_payload_is_rejected_cleanly():
    out = BOUNDARY.infer(input={"hr": "not-a-list"},
                         context={"iana_timezone": F.DEFAULT_TZ,
                                  "interval_start_utc": 1, "interval_end_utc": 2})
    assert out["status"] == "error"
    assert out["diagnostics"]["reason_detail"] == "invalid_hr"


def test_provider_registry_registration():
    from frwhoop_inference.frwhoop_sleep.providers import register_all

    registry = register_all({})
    assert set(registry) == {"sleep_boundary", "sleep_stage"}
    assert registry["sleep_boundary"].provider_id == "hypnospy.hr-boundary.v1"
    assert registry["sleep_stage"].provider_id == "sleepecg.wrn-gru-mesa.v1"
