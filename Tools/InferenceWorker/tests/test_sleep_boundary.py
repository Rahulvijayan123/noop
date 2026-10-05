"""Spec section 8 "Sleep" row for the sleep-boundary provider (HypnosPy HR algorithm).

Covers: quiet awake-in-bed, elevated nighttime HR, fragmented sleep, off-wrist (wear gap),
naps, shift schedule (search-window re-parameterisation), midnight/DST day boundaries,
user-edited bounds, missing epochs.
"""

import pytest

import sleep_fixtures as F
from frwhoop_inference.frwhoop_sleep.providers.sleep_boundary import (
    DEFAULT_CONFIG,
    DEFAULT_PARAMS,
    LABEL_SPACE,
    PROVIDER_ID,
    PROVIDER,
)


def call(fixture, *, config=None, params=None, window=None, wake_ts=None, interval=None,
         user_edit=None):
    data = fixture.build()
    gt = data["ground_truth"]
    ctx = {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "device_id": "device-a",
        "interval_start_utc": (interval or gt["in_bed_utc"])[0],
        "interval_end_utc": (interval or gt["in_bed_utc"])[1],
        "iana_timezone": fixture.tz,
        "profile_version": "p1",
        "config_version": "c1",
        "corrections_version": "k1",
    }
    payload = {"hr": data["hr"]}
    merged_params = dict(DEFAULT_PARAMS)
    merged_params.update(data["params"] or {})
    if params:
        merged_params.update(params)
    payload["params"] = merged_params
    if config:
        payload["config"] = config
    if wake_ts is not None:
        payload["wake_ts_utc"] = wake_ts
    edit = user_edit if user_edit is not None else data["user_edit"]
    if edit:
        payload["user_edit"] = edit
    return PROVIDER.infer(input=payload, context=ctx), data


def onset_and_wake(response):
    result = response["result"]
    onset = [i for i in result["intervals"] if i["kind"] == "sleep_onset"][0]
    wake = [i for i in result["intervals"] if i["kind"] == "final_wake"][0]
    return onset, wake


def test_manifest_and_readiness():
    manifest = PROVIDER.manifest()
    assert manifest["provider_id"] == PROVIDER_ID
    assert manifest["metric"] == "sleep_boundary"
    assert manifest["label_space"] == LABEL_SPACE
    assert manifest["retrospective_or_causal"] == "retrospective"
    assert manifest["eligibility"]["state"] == "shadow_eligible"
    assert "license_reconciliation" in manifest["eligibility"]["promotion_blocked_by"]
    ready = PROVIDER.readiness()
    assert ready["ready"] is True


def test_normal_night_boundary_matches_declared_ground_truth():
    response, data = call(F.normal_night())
    assert response["status"] == "ok"
    onset, wake = onset_and_wake(response)
    gt = data["ground_truth"]
    assert abs(onset["start_utc"] - gt["onset_utc"]) <= 1800
    assert abs(wake["end_utc"] - gt["wake_utc"]) <= 1800
    # in-bed is reported separately and never counted as asleep
    in_bed = [i for i in response["result"]["intervals"] if i["kind"] == "in_bed"][0]
    assert in_bed["start_utc"] <= onset["start_utc"] < wake["end_utc"] <= in_bed["end_utc"]
    assert response["raw_scores"] is None
    assert response["coverage"]["hr_coverage_fraction"] > 0.95


def test_quiet_awake_in_bed_is_withheld_not_labelled_sleep():
    """A quiet but awake night must not produce a sleep period."""
    response, _ = call(F.quiet_awake_in_bed())
    assert response["status"] == "withheld"
    assert response["withheld_reason"] in {"insufficient_coverage", "artifact_fraction"}
    assert response["result"] is None


def test_elevated_nighttime_hr_never_reports_a_large_dip():
    """Elevated, flat night HR: the relative threshold must be reported, not trusted."""
    response, _ = call(F.elevated_nighttime_hr())
    diagnostics = response["diagnostics"]
    assert diagnostics["in_bed_dip_bpm"] is not None
    assert diagnostics["in_bed_dip_bpm"] < DEFAULT_CONFIG["flat_night_dip_bpm"]
    assert diagnostics["flat_night"] is True


def test_elevated_nighttime_hr_withheld_when_dip_required():
    response, _ = call(F.elevated_nighttime_hr(), config={"require_hr_dip_bpm": 5.0})
    assert response["status"] == "withheld"
    assert response["withheld_reason"] == "insufficient_coverage"
    assert response["diagnostics"]["reason_detail"] == "no_hr_dip"


def test_fragmented_sleep_reports_real_waso_spanning_the_awake_bands():
    """F2 regression: a fragmented night must report WASO, not 0.

    The fixture declares three 45-minute awake-in-bed bands inside the in-bed window. The sleep
    period is now bounded by the first and last sleep piece *inside the selected in-bed
    interval*, so those bands are wake-after-sleep-onset instead of being excluded (which made
    ``waso_seconds`` structurally 0 when the span was the longest gap-free piece).
    """
    response, data = call(F.fragmented_sleep(), params={"merge_gap_minutes": 30})
    assert response["status"] == "ok"
    onset, wake = onset_and_wake(response)
    gt = data["ground_truth"]
    assert abs(onset["start_utc"] - gt["onset_utc"]) <= 1800
    assert abs(wake["end_utc"] - gt["wake_utc"]) <= 1800
    diagnostics = response["diagnostics"]
    assert diagnostics["sleep_span_source"] in {"in_bed_span", "single_candidate_spanning_gaps"}
    assert len(diagnostics["sleep_pieces"]) >= 3

    waso = [i for i in response["result"]["intervals"] if i["kind"] == "waso"]
    assert waso, "the awake bands must be reported as WASO"
    assert diagnostics["waso_seconds"] > 0
    # every WASO interval lies inside the sleep period and covers declared awake time
    expected_awake = gt["expected_awake_in_bed_utc"]
    for interval in waso:
        assert onset["start_utc"] <= interval["start_utc"] < interval["end_utc"] <= wake["end_utc"]
    overlaps = []
    for band_start, band_end in expected_awake:
        overlap = sum(max(0, min(i["end_utc"], band_end) - max(i["start_utc"], band_start))
                      for i in waso)
        overlaps.append(overlap)
    # The onset/wake estimates are allowed to shift by up to 30 minutes, so the band that
    # touches an edge may fall outside the selected span. Require that at least two of the
    # three declared bands are reported and that most of the declared awake time is covered.
    assert sum(1 for overlap in overlaps if overlap >= 1800) >= 2, overlaps
    covered = sum(overlaps)
    assert covered >= 3 * 45 * 60 * 0.6, overlaps


def test_contiguous_night_reports_zero_waso():
    """The counterpart of F2: a night with no scored awakening has WASO 0."""
    response, _ = call(F.normal_night())
    assert response["status"] == "ok"
    assert response["diagnostics"]["waso_seconds"] == 0
    assert [i for i in response["result"]["intervals"] if i["kind"] == "waso"] == []


def test_merged_sleep_period_is_contiguous_and_gap_free():
    response, _ = call(F.fragmented_sleep())
    onset, wake = onset_and_wake(response)
    for unscored in response["result"]["unscored"]:
        assert not (onset["start_utc"] < unscored["start_utc"] < wake["end_utc"]), \
            "a gap must never sit inside the reported sleep period"
