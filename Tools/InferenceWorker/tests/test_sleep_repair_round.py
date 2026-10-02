"""Repair-round regression tests (review ledger findings F5, F6, F9, F11 and the E2E seam).

Each test pins a defect the independent review found unverified by the suite.
"""

from __future__ import annotations

import json
import os

import numpy as np
import pytest

import sleep_fixtures as F
from frwhoop_inference.contract import WithheldReason
from frwhoop_inference.frwhoop_sleep.registry_adapter import wrap_stage
from frwhoop_inference.frwhoop_sleep.providers.sleep_boundary import PROVIDER as BOUNDARY
from frwhoop_inference.frwhoop_sleep.providers.sleep_stage import PROVIDER as STAGE

VENDORED = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "src", "frwhoop_inference", "frwhoop_sleep", "hypnospy_vendored")


def _boundary_call(fixture, *, window=None, config=None, params=None, interval=None):
    data = fixture.build()
    gt = data["ground_truth"]
    context = {
        "user_id": "u", "device_id": "d", "iana_timezone": fixture.tz,
        "interval_start_utc": (interval or gt["in_bed_utc"])[0],
        "interval_end_utc": (interval or gt["in_bed_utc"])[1],
    }
    payload = {"hr": data["hr"]}
    if params or data["params"]:
        merged = dict(data["params"] or {})
        merged.update(params or {})
        payload["params"] = merged
    if config:
        payload["config"] = config
    if window:
        payload["window"] = window
    return BOUNDARY.infer(input=payload, context=context), data


# --------------------------------------------------------------------------- F5
def test_nan_free_window_precheck_withholds_instead_of_raising():
    """F5: the rule real ECG data triggers.

    Every 8th RR interval is replaced by 2500 ms, which is above the checkpoint's
    ``max_rri = 2.0`` s, so the RRI series is dense with NaN and NO 270 s analysis window is
    free of them. The adapter must withhold. Directly calling the pinned SleepECG feature
    extractor on the same record raises instead:

        ValueError: shape mismatch: value array of shape (0,1080) could not be broadcast to
        indexing result of shape (0,541)

    (``sleepecg/feature_extraction.py:170``, the empty NaN-free row selection handed to
    ``scipy.signal.periodogram``).
    """
    series = F.rr_series_from_fixture(F.normal_night())
    poisoned = [(ts, 2500 if i % 8 == 7 else rr, seq, order, suspect)
                for i, (ts, rr, seq, order, suspect) in enumerate(series["rr"])]
    context = {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
               "interval_start_utc": series["window"]["start_utc"],
               "interval_end_utc": series["window"]["end_utc"]}
    response = STAGE.infer(input={"rr": poisoned, "window": series["window"],
                                  "age": series["age"], "gender": series["gender"]},
                           context=context)
    assert response["status"] == "withheld"
    assert response["withheld_reason"] == "insufficient_coverage"
    assert response["diagnostics"]["reason_detail"] == "no_finite_feature_window"
    precheck = response["diagnostics"]["precheck"][0]
    assert precheck["nan_free_windows"] == 0
    assert precheck["rri_nan_fraction"] > 0.1

    # and the upstream extractor really does raise on the same record (the pre-check's purpose)
    import datetime

    import sleepecg
    from sleepecg.io.sleep_readers import SleepRecord, SubjectData

    heartbeat_times = np.cumsum([rr / 1000.0 for _, rr, _, _, _ in poisoned])
    record = SleepRecord(heartbeat_times=heartbeat_times,
                         recording_start_time=datetime.time(22, 45),
                         subject_data=SubjectData(age=series["age"], gender=series["gender"]))
    with pytest.raises(ValueError) as excinfo:
        sleepecg.extract_features(records=[record], feature_selection=["hrv-frequency"],
                                  lookback=120, lookforward=150, min_rri=0.3, max_rri=2.0,
                                  max_nans=0.5)
    assert "shape mismatch" in str(excinfo.value)


def test_stage_artifact_error_maps_to_blocked_artifact(tmp_path):
    """F9: a missing checkpoint is an artifact fault, not a provider fault."""
    shim = wrap_stage()
    series = F.rr_series_from_fixture(F.normal_night())
    request = type("Req", (), {
        "input": {"rr": series["rr"], "window": series["window"],
                  "config": {"classifier_zip": str(tmp_path / "gone.zip")}},
        "context": {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
                    "interval_start_utc": series["window"]["start_utc"],
                    "interval_end_utc": series["window"]["end_utc"]},
        "provider_id": None})()
    result = shim.infer(request)
    assert result.status == "withheld"
    assert result.withheld_reason == "blocked_artifact"
    assert result.diagnostics["reason_detail"] == "checkpoint_missing"


def test_stage_artifact_sha256_mismatch_maps_to_blocked_artifact():
    shim = wrap_stage()
    series = F.rr_series_from_fixture(F.normal_night())
    request = type("Req", (), {
        "input": {"rr": series["rr"], "window": series["window"],
                  "config": {"model_sha256": "0" * 64}},
        "context": {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
                    "interval_start_utc": series["window"]["start_utc"],
                    "interval_end_utc": series["window"]["end_utc"]},
        "provider_id": None})()
    result = shim.infer(request)
    assert result.withheld_reason == "blocked_artifact"
    assert result.diagnostics["reason_detail"] == "artifact_mismatch"


# --------------------------------------------------------------------------- F6
def test_upstream_nan_to_sleep_defect_is_reproduced_and_blocked():
    """F6: the D1 defect (NaN HR -> SLEEP) reproduced on the vendored code, then blocked.

    The vendored detector is driven directly on a frame whose heart rate is NaN for a whole
    three-hour run inside the sleep search window. Upstream binarises with
    ``np.where((hr - threshold) > 0, 0, 1)`` (``sleep_boundary_detector.py:48``) and
    ``NaN > 0`` is False, so the NaN run is labelled SLEEP. The adapter's sentinel fill
    (250 bpm) plus the post-call gap mask prevents that.
    """
    import pandas as pd

    from frwhoop_inference.frwhoop_sleep.hypnospy_vendored import SleepBoudaryDetector, Wearable
    from frwhoop_inference.frwhoop_sleep import timebase

    fixture = F.normal_night_with_gaps()
    data = fixture.build()
    gt = data["ground_truth"]
    gap_start, gap_end = gt["gap_utc"][1]

    zone = timebase.parse_zone(fixture.tz)
    wake_day = timebase.local_day(gt["in_bed_utc"][1], zone)
    block_start, block_end = timebase.analysis_block(wake_day, zone, 20, 12)
    epoch_times, values, _ = timebase.resample_to_grid(
        [(ts, v) for ts, v in data["hr"] if block_start <= ts < block_end],
        block_start, block_end, 60)
    frame = pd.DataFrame({
        "hyp_time_col": pd.to_datetime(epoch_times, unit="s", utc=True).tz_convert(zone),
        "hr": values,   # NaN where the samples are absent: NO sentinel fill
    })
    wearable = Wearable(frame, "hyp_time_col", "hr", pid="p", freq_in_secs=60)
    wearable.set_frequency_in_secs(60)
    SleepBoudaryDetector(wearable).detect_sleep_boundaries(
        strategy="hr", hr_sleep_search_window=(20, 12),
        hr_sleep_only_in_sleep_search_window=True)

    upstream = wearable.data.sort_values("hyp_time_col")
    ts = np.array([int(x.timestamp()) for x in upstream["hyp_time_col"]])
    labelled = upstream["hyp_sleep_period"].astype(bool).to_numpy()
    gap_epochs = (ts > gap_start) & (ts < gap_end)
    assert gap_epochs.sum() > 100
    # the upstream defect: the removed-sample run is reported as sleep
    assert labelled[gap_epochs].all(), "the upstream defect was not reproduced"

    # the adapter on the same input must not label the gap as sleep
    response, _ = _boundary_call(fixture)
    assert response["status"] == "ok"
    assert response["diagnostics"]["sentinel_epochs"] > 0
    waso = [i for i in response["result"]["intervals"] if i["kind"] == "waso"]
    for interval in waso:
        assert not (interval["start_utc"] < gap_start and interval["end_utc"] > gap_end)
    for unscored in response["result"]["unscored"]:
        assert not (unscored["start_utc"] < gap_start < unscored["end_utc"] < gap_end)
    # the gap is retained as unscored, and no scored interval claims sleep across it
    assert any(u["start_utc"] <= gap_start and gap_end <= u["end_utc"]
               for u in response["result"]["unscored"])


# --------------------------------------------------------------------------- F11
def test_upstream_diff_covers_the_wearable_rewrite():
    """F11: the provenance record must cover every vendored file, including the rewrite."""
    record = json.load(open(os.path.join(VENDORED, "UPSTREAM_DIFF.json")))
    assert set(record["files"]) == {"sleep_boundary_detector.py", "misc.py",
                                    "wearable_minimal.py"}
    wearable = record["files"]["wearable_minimal.py"]
    assert wearable["kind"] == "rewrite"
    assert wearable["upstream_path"] == "hypnospy/wearable.py"
    assert wearable["upstream_sha256"] == \
        "74abb515fa7f8cc663d616c6a6fc9764d4fb3d0881ce5c0cdbffc56ea7635cc0"
    assert wearable["vendored_sha256"] == \
        "4e100b202117dc6fae080317794cea6875647abc6ccb86ac09c146d5647f950f"
    assert {d["id"] for d in wearable["deviations"]} == {
        "no_frequency_inference", "constructor_signature",
        "timedelta_instead_of_dateoffset"}
    assert wearable["unified_diff"].strip(), "the rewrite diff must be recorded"
    # the vendored file on disk still matches the recorded hash
    import hashlib

    path = os.path.join(VENDORED, "wearable_minimal.py")
    assert hashlib.sha256(open(path, "rb").read()).hexdigest() == wearable["vendored_sha256"]


# --------------------------------------------------------------------------- E2E seam
def test_input_window_overrides_the_context_interval():
    """The worker's accepted session bounds win over the coarse context interval."""
    fixture = F.normal_night()
    data = fixture.build()
    gt = data["ground_truth"]
    context_interval = (gt["in_bed_utc"][0] - 4 * 3600, gt["in_bed_utc"][1] + 4 * 3600)
    response, _ = _boundary_call(fixture, interval=context_interval)
    assert response["diagnostics"]["in_bed_source"] == "context.interval"
    wide = [i for i in response["result"]["intervals"] if i["kind"] == "in_bed"][0]
    assert wide["start_utc"] == context_interval[0]

    narrow = {"start_utc": gt["in_bed_utc"][0], "end_utc": gt["in_bed_utc"][1]}
    response2, _ = _boundary_call(fixture, window=narrow, interval=context_interval)
    assert response2["diagnostics"]["in_bed_source"] == "input.window"
    tight = [i for i in response2["result"]["intervals"] if i["kind"] == "in_bed"][0]
    assert tight["start_utc"] == narrow["start_utc"]
    assert tight["end_utc"] == narrow["end_utc"]
    assert response2["coverage"]["epochs"] <= response["coverage"]["epochs"]


def test_input_window_shape_is_rejected_clearly():
    fixture = F.normal_night()
    response, _ = _boundary_call(fixture, window="not-an-object")
    assert response["status"] == "error"
    assert response["diagnostics"]["reason_detail"] == "invalid_interval_window"


def test_unknown_config_key_is_rejected_not_ignored():
    """The seam decision: ``input.config`` is honoured, and an unknown key is a typed error."""
    fixture = F.normal_night()
    ok, _ = _boundary_call(fixture, config={"min_coverage_fraction": 0.4})
    assert ok["status"] == "ok"
    bad, _ = _boundary_call(fixture, config={"no_such_option": 1})
    assert bad["status"] == "error"
    assert bad["diagnostics"]["reason_detail"] == "unknown_config"

    series = F.rr_series_from_fixture(F.normal_night())
    context = {"user_id": "u", "device_id": "d", "iana_timezone": F.DEFAULT_TZ,
               "interval_start_utc": series["window"]["start_utc"],
               "interval_end_utc": series["window"]["end_utc"]}
    stage_ok = STAGE.infer(input={"rr": series["rr"], "window": series["window"],
                                  "config": {"min_run_seconds": 600}}, context=context)
    assert stage_ok["status"] in {"ok", "withheld"}
    stage_bad = STAGE.infer(input={"rr": series["rr"], "window": series["window"],
                                   "config": {"no_such_option": 1}}, context=context)
    assert stage_bad["status"] == "error"
    assert stage_bad["diagnostics"]["reason_detail"] == "unknown_config"
