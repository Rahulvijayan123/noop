"""WristMetModel behaviour on a tiny hand-written model (no dataset, no real artifact, numpy only)."""

from __future__ import annotations

import copy
import gzip
import hashlib
import json

import numpy as np
import pytest

from energy_models.wristmet import AxisMap, WristMetModel, features as F, ood as O, windows_from_raw
from energy_models.wristmet.model import _TreeEnsemble
from energy_models.wristmet.preprocess import interpolate_at, resample_linear, to_dataset_units
from energy_models.wristmet.testing import synthetic_spec, synthetic_windows

DEMO = {"age": 45.0, "sex": "female", "weight_kg": 90.0, "height_cm": 160.0}  # BMI 35.2


@pytest.fixture(scope="module")
def spec():
    return synthetic_spec()


@pytest.fixture(scope="module")
def model(spec):
    return WristMetModel(spec)


def _sigmoid32(x: float) -> float:
    return float(np.float32(1.0) / (np.float32(1.0) + np.exp(-np.float32(x))))


def test_classifier_probability_is_the_sigmoid_of_the_summed_leaves(model):
    cf = np.zeros((4, 42))
    cf[:, F.CLASSIFIER_FEATURE_NAMES.index("std_acc_y")] = [0.1, 0.9, 0.1, 0.9]
    cf[:, F.CLASSIFIER_FEATURE_NAMES.index("range_gyr_x")] = [0.1, 0.1, 0.5, 0.5]
    # base 0.25; tree 1 -3 / +3 around 0.5; tree 2 -0.5 / +0.5 around 0.2
    margins = [0.25 - 3.0 - 0.5, 0.25 + 3.0 - 0.5, 0.25 - 3.0 + 0.5, 0.25 + 3.0 + 0.5]
    p = model.classify_features(cf)
    assert p.dtype == np.float32
    np.testing.assert_allclose(p, [_sigmoid32(m) for m in margins], rtol=0, atol=1e-7)


def test_xgboost_split_is_strictly_less_than_in_float32_and_nan_uses_default_direction(model):
    col = F.CLASSIFIER_FEATURE_NAMES.index("std_acc_y")
    col2 = F.CLASSIFIER_FEATURE_NAMES.index("range_gyr_x")
    thr32 = np.float32(0.5)
    below = np.nextafter(thr32, np.float32(0.0))
    cf = np.zeros((3, 42))
    cf[:, col2] = 0.0  # tree 2 goes left (-0.5)
    cf[0, col] = float(below)  # < threshold -> left
    cf[1, col] = float(thr32)  # == threshold -> right
    cf[2, col] = np.nan  # default_left=1 for tree 1
    p = model.classify_features(cf)
    expected = [_sigmoid32(0.25 - 3.0 - 0.5), _sigmoid32(0.25 + 3.0 - 0.5), _sigmoid32(0.25 - 3.0 - 0.5)]
    np.testing.assert_allclose(p, expected, atol=1e-7)
    # tree 2 has default_left=0: NaN goes right (+0.5)
    cf2 = np.zeros((1, 42))
    cf2[0, col] = float(below)
    cf2[0, col2] = np.nan
    assert model.classify_features(cf2)[0] == pytest.approx(_sigmoid32(0.25 - 3.0 + 0.5), abs=1e-7)


def test_forest_split_is_less_or_equal_and_prediction_is_the_mean_of_leaves(model):
    rf = np.zeros((4, 9))
    rf[:, F.REGRESSOR_FEATURE_NAMES.index("Intensity (RMSSD_l1)")] = [0.05, 0.0500001, 0.01, 0.2]
    rf[:, F.REGRESSOR_FEATURE_NAMES.index("gender")] = [0.0, 0.0, 1.0, 1.0]
    rf[:, F.REGRESSOR_FEATURE_NAMES.index("BMI")] = [29.0, 31.0, 40.0, 25.0]
    # stump: <= 0.05 -> 2.0 else 5.0 ; deeper: female & BMI<=30 -> 1.5, female & BMI>30 -> 2.5, male -> 3.0
    expected = [(2.0 + 1.5) / 2, (5.0 + 2.5) / 2, (2.0 + 3.0) / 2, (5.0 + 3.0) / 2]
    np.testing.assert_allclose(model.regress_features(rf), expected, rtol=0, atol=1e-12)
    # a double just above the float32 threshold still compares as equal after the float32 cast
    rf[0, F.REGRESSOR_FEATURE_NAMES.index("Intensity (RMSSD_l1)")] = float(np.float32(0.05)) + 1e-12
    assert model.regress_features(rf[:1])[0] == pytest.approx((2.0 + 1.5) / 2)


def test_tree_ensemble_handles_a_single_leaf_tree():
    ens = _TreeEnsemble([{"feature": [-1], "threshold": [0.0], "left": [-1], "right": [-1], "value": [4.0]}], kind="forest")
    assert ens.leaves(np.zeros((3, 9), dtype=np.float32)).tolist() == [[4.0, 4.0, 4.0]]


def test_predict_windows_pipeline_and_ranges(model):
    rest = synthetic_windows(3, seed=11)
    swing = synthetic_windows(3, seed=12, active=True)
    w = np.concatenate([rest, swing])
    r = model.predict_windows(w, **DEMO)
    assert r.valid.all() and r.met.shape == (6,)
    assert not r.is_active[:3].any() and r.is_active[3:].all()
    np.testing.assert_array_equal(r.met[:3], 1.0)  # sedentary -> 1.0 MET
    cf = F.classifier_features(w)
    inten = F.regression_intensity_features(w)
    rf_in = F.regressor_features(inten, **{**DEMO, "sex": "female"})
    expected_rf = model.regress_features(rf_in)
    np.testing.assert_array_equal(r.met[3:], np.maximum(expected_rf[3:], 1.0))
    np.testing.assert_allclose(r.p_active, model.classify_features(cf), atol=0)
    assert np.all(r.met >= 1.0) and np.all((r.p_active >= 0) & (r.p_active <= 1))
    assert np.all((r.ood_signal >= 0) & (r.ood_signal <= 1)) and 0.0 <= r.ood_demographic <= 1.0
    assert r.met_if_active.shape == (6,)


def test_batches_and_chunks_give_identical_results(model):
    w = synthetic_windows(7, seed=3, active=True)
    full = model.predict_windows(w, **DEMO)
    single = [model.predict_windows(w[i : i + 1], **DEMO) for i in range(7)]
    np.testing.assert_array_equal(full.met, [s.met[0] for s in single])
    np.testing.assert_array_equal(full.ood_signal, [s.ood_signal[0] for s in single])
    # exercise the internal chunking (2048 rows per traversal batch) on feature matrices
    cf = np.tile(F.classifier_features(w), (400, 1))  # 2800 rows
    p = model.classify_features(cf)
    for i in (0, 2046, 2047, 2048, 2049, 2799):
        np.testing.assert_array_equal(p[i], model.classify_features(cf[i : i + 1])[0])


def test_window_chunking_does_not_change_results(model):
    from energy_models.wristmet import model as model_module

    assert model_module._WINDOW_CHUNK < 600
    w = np.concatenate([synthetic_windows(300, seed=40), synthetic_windows(300, seed=41, active=True)])
    w[17, 3, 3] = np.nan
    w[299, 0, 0] = np.inf
    full = model.predict_windows(w, **DEMO)
    assert full.valid.sum() == 598
    for i in (0, 16, 17, 255, 256, 257, 299, 300, 511, 512, 599):  # around the chunk boundaries and the invalid windows
        one = model.predict_windows(w[i : i + 1], **DEMO)
        for name in ("met", "p_active", "ood_signal", "ood_range", "ood_gravity", "met_if_active"):
            np.testing.assert_array_equal(getattr(one, name), getattr(full, name)[i : i + 1], err_msg=f"{name}[{i}]")
        assert one.worst_feature[0] == full.worst_feature[i]


def test_determinism(model):
    w = synthetic_windows(4, seed=9, active=True)
    a = model.predict_windows(w, **DEMO)
    b = model.predict_windows(w.copy(), **DEMO)
    for name in ("met", "p_active", "ood_signal", "ood_range", "ood_gravity"):
        np.testing.assert_array_equal(getattr(a, name), getattr(b, name))
    assert a.ood_demographic == b.ood_demographic


def test_nan_inf_and_short_windows_give_nan_met_and_maximal_ood(model):
    w = synthetic_windows(4, seed=4, active=True)
    w[1, 10, 2] = np.nan
    w[3, 5, 4] = np.inf
    r = model.predict_windows(w, **DEMO)
    assert r.valid.tolist() == [True, False, True, False]
    assert np.isnan(r.met[[1, 3]]).all() and np.isnan(r.p_active[[1, 3]]).all()
    assert np.isfinite(r.met[[0, 2]]).all()
    np.testing.assert_array_equal(r.ood_signal[[1, 3]], 1.0)
    assert not r.is_active[[1, 3]].any()

    short = model.predict_windows(w[:, :1199], **DEMO)  # one sample too few
    assert np.isnan(short.met).all() and not short.valid.any() and (short.ood_signal == 1.0).all()

    with pytest.raises(ValueError, match="1200"):
        model.predict_windows(np.zeros((1, 1201, 6)), **DEMO)
    with pytest.raises(ValueError):
        model.predict_windows(np.zeros((1, 1200, 5)), **DEMO)
    empty = model.predict_windows(np.zeros((0, 1200, 6)), **DEMO)
    assert empty.met.shape == (0,)


def test_demographic_inputs_are_validated(model):
    w = synthetic_windows(1)
    for bad in (
        {"sex": "unknown"},
        {"age": 0.0},
        {"weight_kg": -5.0},
        {"height_cm": float("nan")},
        {"age": float("inf")},
    ):
        with pytest.raises(ValueError):
            model.predict_windows(w, **{**DEMO, **bad})


def test_demographic_ood_formula(model):
    env = model.demographic_envelope
    assert env.age_min == 30.0 and env.bmi_max == 45.0
    inside = model.ood_demographic(age=45.0, sex="male", weight_kg=90.0, height_cm=160.0)  # BMI 35.2
    assert inside == 0.0
    # BMI exactly one training SD above the maximum, age inside -> 1 - exp(-1)
    bmi = env.bmi_max + env.bmi_sd
    height = 170.0
    weight = bmi * (height / 100.0) ** 2
    out = model.ood_demographic(age=45.0, sex="female", weight_kg=weight, height_cm=height)
    assert out == pytest.approx(1.0 - np.exp(-1.0), abs=1e-12)
    # age and BMI both one SD outside: 1 - exp(-sqrt(2))
    out2 = model.ood_demographic(age=env.age_min - env.age_sd, sex="female", weight_kg=weight, height_cm=height)
    assert out2 == pytest.approx(1.0 - np.exp(-np.sqrt(2.0)), abs=1e-12)
    # far outside saturates below/at 1
    assert 0.9 < model.ood_demographic(age=10.0, sex="male", weight_kg=40.0, height_cm=180.0) <= 1.0


def test_demographic_ood_flags_an_unseen_sex():
    env = O.DemographicEnvelope.fit(np.array([30.0, 40.0]), np.array([30.0, 35.0]), np.array([1, 1]))
    assert env.score(35.0, 32.0, 0.0) == 1.0
    assert env.score(35.0, 32.0, 1.0) == 0.0


def test_signal_ood_reacts_to_gravity_components_outside_the_training_envelope(model):
    base = synthetic_windows(3, seed=21)
    ok = model.predict_windows(base, **DEMO)
    # noise-only descriptors have very narrow training bands in this toy envelope, so allow a small excess
    assert ok.ood_signal.max() < 0.3

    shifted = base.copy()
    shifted[:, :, 3] += 30.0  # acc_x gravity component far above anything in training
    r = model.predict_windows(shifted, **DEMO)
    assert (r.ood_signal > 0.9).all()
    assert r.worst_feature[0] is not None

    in_g = base.copy()
    in_g[:, :, 3:6] /= 9.80665  # accelerometer delivered in g instead of m/s^2
    assert (model.predict_windows(in_g, **DEMO).ood_signal > 0.5).all()

    # gyroscope in deg/s instead of rad/s: only visible when there is motion (rest noise is tiny either way)
    act = synthetic_windows(3, seed=22, active=True)
    act_deg = act.copy()
    act_deg[:, :, 0:3] *= 180.0 / np.pi
    assert model.predict_windows(act_deg, **DEMO).ood_signal.min() > model.predict_windows(act, **DEMO).ood_signal.max()


def test_gravity_direction_component_in_isolation():
    rng = np.random.default_rng(0)
    features = rng.normal(0.0, 1.0, (500, len(O.SIGNAL_FEATURE_NAMES)))  # wide ranges -> no range excess
    gravity = np.tile([0.0, 0.0, 1.0], (50, 1))  # training only ever saw gravity along +z
    env = O.SignalEnvelope.fit(features, gravity, angle_ok_deg=10.0)

    def with_mean_acc(vec):
        row = np.zeros((1, len(O.SIGNAL_FEATURE_NAMES)))
        for axis, col in enumerate(O.ACC_MEAN_COLUMNS):
            row[0, col] = vec[axis]
        return row

    same = env.score(with_mean_acc([0.0, 0.0, 9.8]))
    tilt = env.score(with_mean_acc([9.8 * np.sin(np.radians(25.0)), 0.0, 9.8 * np.cos(np.radians(25.0))]))
    flipped = env.score(with_mean_acc([9.8, 0.0, 0.0]))
    assert same.ood_gravity[0] == 0.0 and same.gravity_angle_deg[0] < 1e-6
    assert tilt.gravity_angle_deg[0] == pytest.approx(25.0, abs=1e-6)
    assert tilt.ood_gravity[0] == pytest.approx((25.0 - 10.0) / 30.0)
    assert flipped.ood_gravity[0] == 1.0 and flipped.ood_signal[0] == 1.0
    # direction undefined (mean acceleration shorter than 1 m/s^2): the gravity component stays 0
    assert env.score(with_mean_acc([0.1, 0.0, 0.1])).ood_gravity[0] == 0.0


def test_signal_range_score_formula():
    f = np.tile(np.arange(101, dtype=float)[:, None], (1, len(O.SIGNAL_FEATURE_NAMES)))  # 0..100 for every descriptor
    env = O.SignalEnvelope.fit(f, np.tile([0.0, 0.0, 1.0], (3, 1)), angle_ok_deg=10.0)
    lo, hi = env.p_low[0], env.p_high[0]
    assert (lo, hi) == (0.5, 99.5)
    row = np.full((1, len(O.SIGNAL_FEATURE_NAMES)), 50.0)
    assert env.score(row).ood_range[0] == 0.0
    row[0, 7] = hi + 0.5 * (hi - lo)  # half a band-width above the 99.5th percentile
    expected = 1.0 - np.exp(-0.5 / env.range_scale)
    got = env.score(row)
    assert got.ood_range[0] == pytest.approx(expected)
    assert got.worst_feature[0] == 7
    row[0, 7] = np.nan
    assert env.score(row).ood_signal[0] == 1.0


def test_envelope_round_trips_through_json(spec):
    d = spec["training_envelope"]["signal"]
    env = O.SignalEnvelope.from_dict(json.loads(json.dumps(d)))
    assert env.names == O.SIGNAL_FEATURE_NAMES and env.gravity_unit_vectors.shape[1] == 3
    again = O.SignalEnvelope.from_dict(env.to_dict())
    np.testing.assert_array_equal(again.p_low, env.p_low)
    np.testing.assert_array_equal(again.gravity_unit_vectors, env.gravity_unit_vectors)


def test_load_from_json_and_gzip_with_checksum(tmp_path, spec):
    raw = json.dumps(spec).encode()
    plain = tmp_path / "m.json"
    plain.write_bytes(raw)
    gz = tmp_path / "m.json.gz"
    gz.write_bytes(gzip.compress(raw))
    w = synthetic_windows(2, seed=5, active=True)
    ref = WristMetModel(spec).predict_windows(w, **DEMO).met
    for p in (plain, gz):
        m = WristMetModel.load(p, expected_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
        np.testing.assert_array_equal(m.predict_windows(w, **DEMO).met, ref)
    with pytest.raises(ValueError, match="sha256"):
        WristMetModel.load(gz, expected_sha256="0" * 64)


def test_schema_and_feature_order_are_checked(spec):
    bad = copy.deepcopy(spec)
    bad["schema"] = "something/else"
    with pytest.raises(ValueError, match="schema"):
        WristMetModel(bad)
    bad = copy.deepcopy(spec)
    bad["features"]["classifier"]["names"][0], bad["features"]["classifier"]["names"][1] = (
        bad["features"]["classifier"]["names"][1],
        bad["features"]["classifier"]["names"][0],
    )
    with pytest.raises(ValueError, match="feature names"):
        WristMetModel(bad)


# ---------------------------------------------------------------- preprocessing helpers

def test_resample_linear_matches_the_upstream_grid_and_interpolation():
    t = np.arange(0, 1001, 10.0)  # 100 Hz, 1 s
    x = np.column_stack([t * 0.5, np.sin(t / 100.0)])
    tt, out = resample_linear(t, x, rate_hz=20.0)
    assert tt[0] == 0.0 and np.allclose(np.diff(tt), 50.0) and tt[-1] == 1000.0
    np.testing.assert_allclose(out[:, 0], tt * 0.5, atol=1e-9)  # linear signal reproduced exactly
    np.testing.assert_array_equal(out[0], x[0])  # first sample is copied


def test_interpolate_at_respects_gap_tolerance():
    t = np.array([0.0, 10.0, 20.0, 1020.0, 1030.0])
    x = np.arange(5, dtype=float)[:, None]
    grid = np.array([5.0, 500.0, 1025.0])
    free = interpolate_at(t, x, grid, None)[:, 0]
    assert free[0] == pytest.approx(0.5) and 2.0 < free[1] < 3.0
    guarded = interpolate_at(t, x, grid, 500.0)[:, 0]
    assert guarded[0] == pytest.approx(0.5) and np.isnan(guarded[1]) and guarded[2] == pytest.approx(3.5)


def test_to_dataset_units_and_axis_map_validation():
    acc, gyr = to_dataset_units(np.array([[1.0, 0.0, -1.0]]), np.array([[180.0, 0.0, 0.0]]))
    np.testing.assert_allclose(acc, [[9.80665, 0.0, -9.80665]])
    np.testing.assert_allclose(gyr, [[np.pi, 0.0, 0.0]])
    with pytest.raises(ValueError):
        to_dataset_units(acc, gyr, acc_unit="mg")
    assert AxisMap().is_identity
    with pytest.raises(ValueError):
        AxisMap(acc_source=(0, 0, 2))
    with pytest.raises(ValueError):
        AxisMap(acc_sign=(1.0, 2.0, 1.0))
    a, g = AxisMap(acc_source=(1, 0, 2), acc_sign=(1.0, -1.0, 1.0)).apply(np.array([[1.0, 2.0, 3.0]]), np.array([[4.0, 5.0, 6.0]]))
    assert a.tolist() == [[2.0, -1.0, 3.0]] and g.tolist() == [[4.0, 5.0, 6.0]]


def _raw_stream(seconds: float, hz: float = 100.0, *, gap: tuple[float, float] | None = None):
    t = np.arange(0.0, seconds * 1000.0, 1000.0 / hz) + 1_700_000_000_000.0
    if gap is not None:
        t = t[(t < t[0] + gap[0] * 1000.0) | (t > t[0] + gap[1] * 1000.0)]
    acc = np.tile([0.1, -0.7, 0.4], (t.size, 1))  # g
    gyr = np.zeros((t.size, 3))
    return t, acc, gyr


def test_windows_from_raw_units_windowing_and_mirroring():
    t, acc, gyr = _raw_stream(130.0)
    gyr[:, 1] = 30.0  # deg/s
    raw = windows_from_raw(t, acc, gyr)
    assert raw.windows.shape == (2, 1200, 6) and raw.valid.all()
    np.testing.assert_allclose(raw.windows[0, :, 3:6], np.tile(np.array([0.1, -0.7, 0.4]) * 9.80665, (1200, 1)), atol=1e-9)
    np.testing.assert_allclose(raw.windows[0, :, 1], np.radians(30.0), atol=1e-12)
    assert raw.start_ms[1] - raw.start_ms[0] == pytest.approx(60_000.0)
    left = windows_from_raw(t, acc, gyr, wrist="left")
    np.testing.assert_allclose(left.windows[..., 3], -raw.windows[..., 3])
    np.testing.assert_allclose(left.windows[..., 4], raw.windows[..., 4])
    np.testing.assert_allclose(left.windows[..., 1], -raw.windows[..., 1])
    assert windows_from_raw(t[:3000], acc[:3000], gyr[:3000]).windows.shape[0] == 0  # 30 s: no full window


def test_windows_with_gaps_longer_than_tolerance_are_invalid_and_yield_nan(model):
    t, acc, gyr = _raw_stream(130.0, gap=(20.0, 22.0))
    raw = windows_from_raw(t, acc, gyr)
    assert raw.valid.tolist() == [False, True]
    r = model.predict_windows(raw.windows, **DEMO)
    assert np.isnan(r.met[0]) and np.isfinite(r.met[1])
    raw_tolerant = windows_from_raw(t, acc, gyr, gap_tolerance_ms=None)
    assert raw_tolerant.valid.all()


def test_predict_raw_end_to_end(model):
    t, acc, gyr = _raw_stream(70.0)
    raw, r = model.predict_raw(t, acc, gyr, **DEMO)
    assert r.met.shape == (1,) and r.met[0] == 1.0  # a perfectly still strap is sedentary
