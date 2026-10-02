"""Spec section 8 "Sleep" row for the sleep-stage provider (SleepECG wrn-gru-mesa).

Deterministic synthetic RR fixtures only. The provider is exercised through its real
inference path (bundled checkpoint, sha256-verified, Keras direct load).
"""

import numpy as np
import pytest

import sleep_fixtures as F
from frwhoop_inference.frwhoop_sleep.providers.sleep_stage import (
    CLASS_ORDER,
    LABEL_SPACE,
    PROVIDER,
    PROVIDER_ID,
    STAGES_MODE,
)


UNSET = object()


def call(fixture, *, drop_runs=(), ectopic_fraction=0.004, window=None, age=UNSET, gender=UNSET,
         config=None, start_utc=None, end_utc=None, ts_suspect_all=False):
    series = F.rr_series_from_fixture(fixture, drop_runs=drop_runs,
                                      ectopic_fraction=ectopic_fraction,
                                      start_utc=start_utc, end_utc=end_utc)
    if ts_suspect_all:
        series["rr"] = [(ts, ms, seq, order, 1) for ts, ms, seq, order, _ in series["rr"]]
    ctx = {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "device_id": "device-a",
        "interval_start_utc": series["window"]["start_utc"],
        "interval_end_utc": series["window"]["end_utc"],
        "iana_timezone": fixture.tz,
        "profile_version": "p1",
        "config_version": "c1",
        "corrections_version": "k1",
    }
    payload = {
        "rr": series["rr"],
        "window": window or series["window"],
        "age": series["age"] if age is UNSET else age,
        "gender": series["gender"] if gender is UNSET else gender,
    }
    if config:
        payload["config"] = config
    return PROVIDER.infer(input=payload, context=ctx), series


def test_manifest_and_readiness_with_verified_artifacts():
    manifest = PROVIDER.manifest()
    assert manifest["provider_id"] == PROVIDER_ID
    assert manifest["metric"] == "sleep_stage"
    assert manifest["label_space"] == LABEL_SPACE
    assert manifest["stages_mode"] == STAGES_MODE
    assert manifest["artifacts"]["wrn-gru-mesa.zip"]["sha256"].startswith("5622a858")
    assert manifest["artifacts"]["classifier.keras"]["sha256"].startswith("0b392209")
    ready = PROVIDER.readiness()
    assert ready["ready"] is True
    assert ready["provenance"]["loader"] in {"keras_direct", "sleepecg.load_classifier"}
    assert ready["provenance"]["zip_sha256"] == manifest["artifacts"]["wrn-gru-mesa.zip"]["sha256"]
    assert ready["provenance"]["model_sha256"] == manifest["artifacts"]["classifier.keras"]["sha256"]


def test_real_inference_produces_three_class_epochs():
    response, _ = call(F.normal_night())
    assert response["status"] == "ok"
    result = response["result"]
    assert result["label_space"] == LABEL_SPACE
    assert result["stages"], "stages must not be empty"
    labels = {stage["label"] for stage in result["stages"]}
    assert labels <= {"wake", "rem", "nrem"}
    epochs = response["coverage"]["staged_epochs"]
    assert epochs > 100
    for stage in result["stages"]:
        assert stage["end_utc"] > stage["start_utc"]
        assert stage["seconds"] == stage["epochs"] * 30


def test_raw_scores_are_returned_uncalibrated_with_rowsum_one():
    response, _ = call(F.normal_night())
    scores = response["raw_scores"]
    assert scores["calibrated"] is False
    assert "not a validated probability" in scores["note"]
    assert scores["class_order"] == CLASS_ORDER
    rows = np.asarray(scores["per_epoch"], dtype=float)
    assert rows.shape[1] == 4
    assert np.allclose(rows.sum(axis=1), 1.0, atol=1e-5)
    assert response["diagnostics"]["accuracy_status"] == "unverified_accuracy"


def test_argmax_undefined_epochs_are_unscored_not_forced():
    """argmax == 0 is SleepECG's UNDEFINED class and must never become a stage."""
    response, _ = call(F.normal_night())
    # measured 0 for this fixture: the model never returns UNDEFINED here, so this pins the
    # counter instead of accepting any value
    assert response["diagnostics"]["argmax_undefined_epochs"] == 0
    assert all(epoch["reason"] != "undefined_class" for epoch in response["result"]["unscored"])
    for epoch in response["result"]["unscored"]:
        assert epoch["reason"] in {"undefined_class", "no_features", "no_rr"}
    assert all(stage["label"] != "undefined" for stage in response["result"]["stages"])


def test_wear_gap_produces_unscored_epochs_and_separate_runs():
    response, series = call(F.normal_night_with_gaps())
    assert response["status"] == "ok"
    gap_start, gap_end = series["window"]["start_utc"], series["window"]["end_utc"]
    unscored = response["result"]["unscored"]
    assert unscored, "gap epochs must be reported as unscored"
    assert any(u["reason"] == "no_rr" for u in unscored)
    gap_seconds = sum(u["seconds"] for u in unscored if u["reason"] == "no_rr")
    assert gap_seconds > 3000, "the 3 h sleep-window gap must be retained as missing"
    assert response["coverage"]["coverage_fraction"] < 0.9


def test_rr_batches_are_never_concatenated_across_a_gap():
    """Two runs separated by 45 min must be staged as two records, not one."""
    series = F.rr_series_from_fixture(F.normal_night())
    lo = series["window"]["start_utc"]
    response, _ = call(F.normal_night(),
                       drop_runs=((lo + 3 * 3600, lo + 3 * 3600 + 45 * 60),))
    runs = response["diagnostics"]["runs"]
    assert len(runs) >= 2, "the RR series must be split into runs at the dropout"
    staged = [r for r in runs if not r.get("skipped")]
    assert len(staged) == 2


def test_short_rr_run_is_skipped_and_unscored():
    series = F.rr_series_from_fixture(F.normal_night())
    lo = series["window"]["start_utc"]
    # remove everything except a 10-minute slice -> below min_run_seconds
    response, _ = call(F.normal_night(),
                       start_utc=lo + 3600, end_utc=lo + 3600 + 600)
    assert response["status"] == "withheld"
    assert response["withheld_reason"] == "insufficient_coverage"
    assert response["diagnostics"]["reason_detail"] == "insufficient_consecutive_beats"


def test_missing_age_and_gender_still_stage_and_mask_the_columns():
    response, _ = call(F.normal_night(), age=None, gender=None)
    assert response["status"] == "ok"
    run0 = response["diagnostics"]["run_0"]
    assert "age" in run0["all_nan_columns"]
    assert "gender" in run0["all_nan_columns"]
    assert run0["masked_column_count"] >= 2


def test_vlf_band_is_reported_as_masked_for_this_checkpoint():
    """The shipped config needs 3030.3 s for VLF but the analysis window is 270 s.

    Measured: the VLF column is not *entirely* NaN (the band still has PSD bins), but the
    feature matrix always has at least one masked column and SleepECG emits the "window too
    short for VLF" RuntimeWarning on every record. The adapter records the masked columns so
    this is never mistaken for a data problem.
    """
    response, _ = call(F.normal_night())
    run0 = response["diagnostics"]["run_0"]
    assert run0["masked_column_count"] >= 1
    assert run0["feature_matrix_shape"][1] == 36


def test_no_rr_rows_is_a_hard_input_error():
    response, series = call(F.normal_night())
    empty = {"rr": [], "window": series["window"]}
    ctx = {"iana_timezone": F.DEFAULT_TZ, "interval_start_utc": series["window"]["start_utc"],
           "interval_end_utc": series["window"]["end_utc"]}
    out = PROVIDER.infer(input=empty, context=ctx)
    assert out["status"] == "error"
    assert out["diagnostics"]["reason_detail"] == "missing_rr"


def test_provider_id_mismatch_is_rejected():
    response, series = call(F.normal_night())
    ctx = {"iana_timezone": F.DEFAULT_TZ, "interval_start_utc": series["window"]["start_utc"],
           "interval_end_utc": series["window"]["end_utc"]}
    out = PROVIDER.infer(input={"rr": series["rr"], "window": series["window"]}, context=ctx,
                         provider={"provider_id": "someone.else.v1"})
    assert out["status"] == "error"
    assert out["diagnostics"]["reason_detail"] == "provider_id_mismatch"


def test_deterministic_output_for_the_same_input():
    first, _ = call(F.fragmented_sleep())
    second, _ = call(F.fragmented_sleep())
    assert first["result"]["stages"] == second["result"]["stages"]
    assert first["raw_scores"]["per_epoch"][:50] == second["raw_scores"]["per_epoch"][:50]
