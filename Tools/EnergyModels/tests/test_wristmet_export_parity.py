"""Exported JSON trees evaluated with numpy vs the fitted xgboost / scikit-learn models (build-time libraries)."""

from __future__ import annotations

import hashlib
import json

import numpy as np
import pytest

xgboost = pytest.importorskip("xgboost")
sklearn_ensemble = pytest.importorskip("sklearn.ensemble")

from energy_models.wristmet import WristMetModel, features as F, ood as O  # noqa: E402
from energy_models.wristmet.pipeline import export as E  # noqa: E402
from energy_models.wristmet.testing import synthetic_spec  # noqa: E402


def _training_data(seed: int = 0):
    rng = np.random.default_rng(seed)
    n = 500
    x_clf = rng.normal(size=(n, 42)) * rng.uniform(0.2, 5.0, 42) + rng.uniform(-3, 3, 42)
    x_clf[rng.random(x_clf.shape) < 0.02] = np.nan  # XGBoost trains with missing values; so must the export
    dense = np.nan_to_num(x_clf)
    signal = dense[:, 3] + 0.5 * dense[:, 11] - 0.3 * dense[:, 20] + rng.normal(0, 0.5, n)
    y = (signal > np.median(signal)).astype(int)
    assert 0.4 < y.mean() < 0.6
    x_reg = np.column_stack(
        [
            rng.integers(0, 2, n),
            rng.uniform(25, 64, n),
            rng.uniform(30, 46, n),
            rng.uniform(0.0, 20.0, n),
            rng.uniform(0, 1, n),
            rng.uniform(0, 1, n),
            rng.uniform(0, 1, n),
            rng.uniform(0, 1, n),
            rng.uniform(0.0, 0.5, n),
        ]
    )
    x_reg[:, 4] = x_reg[:, 0] * x_reg[:, 1]
    x_reg[:, 5] = x_reg[:, 0] * x_reg[:, 2]
    x_reg[:, 6] = x_reg[:, 1] * x_reg[:, 2]
    x_reg[:, 7] = x_reg[:, 0] * x_reg[:, 1] * x_reg[:, 2]
    target = 1.0 + 0.1 * x_reg[:, 3] + 6.0 * x_reg[:, 8] + 0.02 * (x_reg[:, 2] - 35) + rng.normal(0, 0.3, n)
    return x_clf, y, x_reg, target


@pytest.fixture(scope="module")
def fitted():
    x_clf, y, x_reg, target = _training_data()
    clf = xgboost.XGBClassifier(random_state=0, n_jobs=1).fit(x_clf, y)
    rf = sklearn_ensemble.RandomForestRegressor(random_state=0, n_jobs=1).fit(x_reg, target)
    return clf, rf, x_clf, x_reg


@pytest.fixture(scope="module")
def exported(fitted):
    clf, rf, _, x_reg = fitted
    base = synthetic_spec()
    envelope = base["training_envelope"]
    spec = E.assemble_spec(
        model_id="wristmet-parity-test",
        clf=clf,
        rf=rf,
        signal_envelope=O.SignalEnvelope.from_dict(envelope["signal"]),
        demographic_envelope=O.DemographicEnvelope.from_dict(envelope["demographic"]),
        regression_envelope=E.regression_feature_envelope(x_reg, n_participants=5),
        frame_reference=[],
        training_summary={"note": "unit test"},
    )
    return spec, WristMetModel(json.loads(E.dumps_canonical(spec)))


def _boundary_rows(trees, n_features: int, rng, *, kind: str) -> np.ndarray:
    """Rows whose features sit exactly on, one float32 ulp below and one above each split threshold."""
    rows = []
    for t in trees:
        thr_key = "split_condition" if kind == "xgboost" else "threshold"
        for f, thr in zip(t["feature"], t[thr_key]):
            if f < 0:
                continue
            base = rng.normal(size=n_features) * 3.0
            for value in (
                np.float32(thr),
                np.nextafter(np.float32(thr), np.float32(np.inf)),
                np.nextafter(np.float32(thr), np.float32(-np.inf)),
            ):
                row = base.copy()
                row[f] = float(value)
                rows.append(row)
    return np.array(rows)


def test_classifier_block_shape_and_base_margin(fitted, exported):
    clf = fitted[0]
    spec, _ = exported
    block = spec["classifier"]
    assert block["n_trees"] == 100 and len(block["trees"]) == 100
    assert block["base_score"] == pytest.approx(float(json.loads(clf.get_booster().save_raw("json"))["learner"]["learner_model_param"]["base_score"].strip("[]")), rel=1e-6)
    assert block["base_margin"] == pytest.approx(np.log(block["base_score"] / (1 - block["base_score"])), abs=1e-6)


def test_xgboost_probabilities_and_decisions_match(fitted, exported):
    clf, _, x_clf, _ = fitted
    _, model = exported
    p_ref = clf.predict_proba(x_clf)[:, 1]
    p = model.classify_features(x_clf)
    assert np.max(np.abs(p.astype(np.float64) - p_ref.astype(np.float64))) <= 1e-5
    np.testing.assert_array_equal(p > 0.5, clf.predict(x_clf).astype(bool))


def test_xgboost_parity_at_thresholds_and_with_missing_values(fitted, exported):
    clf, _, x_clf, _ = fitted
    spec, model = exported
    rng = np.random.default_rng(1)
    rows = _boundary_rows(spec["classifier"]["trees"], 42, rng, kind="xgboost")
    assert rows.shape[0] > 300
    nan_rows = x_clf[:60].copy()
    nan_rows[rng.random(nan_rows.shape) < 0.3] = np.nan
    all_nan = np.full((1, 42), np.nan)
    for x in (rows, nan_rows, all_nan):
        p_ref = clf.predict_proba(x)[:, 1].astype(np.float64)
        p = model.classify_features(x).astype(np.float64)
        assert np.max(np.abs(p - p_ref)) <= 1e-5
        np.testing.assert_array_equal(p > 0.5, p_ref > 0.5)


def test_random_forest_matches_scikit_learn(fitted, exported):
    _, rf, _, x_reg = fitted
    _, model = exported
    assert np.max(np.abs(model.regress_features(x_reg) - rf.predict(x_reg))) <= 1e-6


def test_random_forest_parity_at_thresholds(fitted, exported):
    _, rf, _, x_reg = fitted
    spec, model = exported
    rng = np.random.default_rng(2)
    rows = _boundary_rows(spec["regressor"]["trees"], 9, rng, kind="forest")
    # also probe the float64 thresholds scikit-learn actually holds
    sk_thr = np.concatenate([e.tree_.threshold[e.tree_.children_left != -1] for e in rf.estimators_])
    sk_feat = np.concatenate([e.tree_.feature[e.tree_.children_left != -1] for e in rf.estimators_])
    extra = []
    for f, thr in list(zip(sk_feat, sk_thr))[:400]:
        base = x_reg[rng.integers(0, x_reg.shape[0])].copy()
        for value in (thr, np.nextafter(thr, np.inf), np.nextafter(thr, -np.inf)):
            row = base.copy()
            row[f] = value
            extra.append(row)
    x = np.concatenate([rows, np.array(extra)])
    assert x.shape[0] > 1000
    assert np.max(np.abs(model.regress_features(x) - rf.predict(x))) <= 1e-6


def test_end_to_end_decisions_on_real_feature_code(fitted, exported):
    clf, rf, _, _ = fitted
    spec, model = exported
    # the full numpy pipeline must agree with composing the two libraries by hand
    from energy_models.wristmet.testing import synthetic_windows

    w = np.concatenate([synthetic_windows(3, seed=31), synthetic_windows(3, seed=32, active=True)])
    cf = F.classifier_features(w)
    inten = F.regression_intensity_features(w)
    demo = {"age": 38.0, "sex": "male", "weight_kg": 110.0, "height_cm": 180.0}
    rf_in = F.regressor_features(inten, **demo)
    r = model.predict_windows(w, **demo)
    p_ref = clf.predict_proba(cf)[:, 1].astype(np.float64)
    assert np.max(np.abs(r.p_active - p_ref)) <= 1e-5
    expected = np.where(p_ref > 0.5, np.maximum(rf.predict(rf_in), 1.0), 1.0)
    np.testing.assert_allclose(r.met, expected, rtol=0, atol=1e-6)


def test_float32_floor_properties():
    x = np.array([0.1, -0.1, 1.0, 3.4e38, 1e-45, -2.5, 0.0, np.nextafter(1.0, 2.0)])
    f = E.float32_floor(x)
    assert f.dtype == np.float32
    assert np.all(f.astype(np.float64) <= x)
    below = np.nextafter(f, np.float32(np.inf))
    assert np.all(below.astype(np.float64) > x) or np.any(np.isinf(below))
    # float32(v) <= floor(t)  <=>  float32(v) <= t for every float32 v
    rng = np.random.default_rng(0)
    for t in (0.3, -7.77, 123.456789012345):
        fl = E.float32_floor(np.array([t]))[0]
        v32 = np.concatenate(
            [np.array([fl, np.nextafter(fl, np.float32(np.inf)), np.nextafter(fl, np.float32(-np.inf))]), rng.normal(t, 1e-5, 1000).astype(np.float32)]
        )
        np.testing.assert_array_equal(v32 <= fl, v32.astype(np.float64) <= t)


def test_json_f32_round_trips_exactly():
    rng = np.random.default_rng(3)
    a = np.concatenate([rng.normal(size=1000).astype(np.float32), np.array([0.1, 1e-30, 3e38, -0.0], dtype=np.float32)])
    back = np.array(json.loads(json.dumps(E._json_f32(a))), dtype=np.float32)
    np.testing.assert_array_equal(back, a)


def test_export_is_deterministic_and_contains_no_non_finite_numbers(fitted, exported, tmp_path):
    spec, _ = exported
    a = tmp_path / "a.json.gz"
    b = tmp_path / "sub" / "b.json.gz"
    info_a = E.write_artifact(spec, a)
    info_b = E.write_artifact(json.loads(E.dumps_canonical(spec)), b)
    assert a.read_bytes() == b.read_bytes()
    assert info_a["sha256"] == info_b["sha256"] == hashlib.sha256(a.read_bytes()).hexdigest()
    assert info_a["bytes_gz"] == a.stat().st_size and info_a["bytes_json"] > info_a["bytes_gz"]
    json.loads(E.dumps_canonical(spec))  # allow_nan=False would have raised on NaN/inf

    # refitting with identical seeds reproduces the identical artifact
    x_clf, y, x_reg, target = _training_data()
    clf2 = xgboost.XGBClassifier(random_state=0, n_jobs=1).fit(x_clf, y)
    rf2 = sklearn_ensemble.RandomForestRegressor(random_state=0, n_jobs=1).fit(x_reg, target)
    assert E.classifier_block(clf2) == spec["classifier"]
    assert E.regressor_block(rf2) == spec["regressor"]


def test_loaded_artifact_matches_in_memory_spec(exported, tmp_path):
    spec, model = exported
    path = tmp_path / "m.json.gz"
    info = E.write_artifact(spec, path)
    loaded = WristMetModel.load(path, expected_sha256=info["sha256"])
    x = np.random.default_rng(4).normal(size=(50, 42)) * 3
    np.testing.assert_array_equal(loaded.classify_features(x), model.classify_features(x))
    z = np.random.default_rng(5).normal(size=(50, 9)) * 10
    np.testing.assert_array_equal(loaded.regress_features(z), model.regress_features(z))
