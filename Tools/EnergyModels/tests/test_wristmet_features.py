"""WristMET feature functions vs the definitions and vs literal copies of the upstream code."""

from __future__ import annotations

import numpy as np
import pytest

from energy_models.wristmet import features as F
from energy_models.wristmet.preprocess import MIRROR_NEGATE_CHANNELS, mirror_to_right_wrist
from energy_models.wristmet.testing import synthetic_windows


def _windows(n: int = 3, seed: int = 5) -> np.ndarray:
    w = synthetic_windows(n, seed=seed, active=True)
    rng = np.random.default_rng(seed)
    return w + rng.normal(0.0, 0.2, w.shape)  # make every statistic non-degenerate


def test_feature_names_are_statistic_major():
    names = F.CLASSIFIER_FEATURE_NAMES
    assert len(names) == 42 and len(set(names)) == 42
    assert names[:6] == ("median_gyr_x", "median_gyr_y", "median_gyr_z", "median_acc_x", "median_acc_y", "median_acc_z")
    assert names[6] == "mean_gyr_x" and names[-1] == "rms_acc_z"
    assert F.REGRESSOR_FEATURE_NAMES == (
        "gender", "age", "BMI", "Intensity (Freq)", "gender_age", "gender_BMI", "age_BMI", "age_gender_BMI",
        "Intensity (RMSSD_l1)",
    )


def test_classifier_features_follow_the_definition():
    w = _windows()
    got = F.classifier_features(w)
    assert got.shape == (3, 42)
    for i in range(3):
        cols = w[i].T  # (6, N)
        expected = np.concatenate(
            [
                np.median(cols, axis=1),
                cols.mean(axis=1),
                cols.max(axis=1),
                cols.min(axis=1),
                cols.max(axis=1) - cols.min(axis=1),
                cols.std(axis=1),  # population std (ddof=0)
                np.sqrt((cols**2).mean(axis=1)),
            ]
        )
        np.testing.assert_allclose(got[i], expected, rtol=1e-12, atol=1e-12)


def test_classifier_features_accept_a_single_window_and_reject_bad_shapes():
    w = _windows(1)
    np.testing.assert_array_equal(F.classifier_features(w[0]), F.classifier_features(w))
    with pytest.raises(ValueError):
        F.classifier_features(np.zeros((2, 100, 5)))


def test_classifier_features_match_upstream_code():
    pytest.importorskip("pandas")
    pytest.importorskip("sklearn")
    from energy_models.wristmet.pipeline import upstream_reference as U

    w = _windows()
    reference = U.extract_features([np.ascontiguousarray(x.T) for x in w])
    np.testing.assert_allclose(F.classifier_features(w), reference, rtol=1e-12, atol=0.0)


def test_rmssd_l1_matches_upstream_code():
    pd = pytest.importorskip("pandas")
    pytest.importorskip("sklearn")
    from energy_models.wristmet.pipeline import upstream_reference as U

    for w in _windows():
        acc = w[:, 3:6]
        df = pd.DataFrame({"accX": acc[:, 0], "accY": acc[:, 1], "accZ": acc[:, 2]})
        assert F.rmssd_l1(acc) == pytest.approx(U.get_rmssd(df, norm="l1"), rel=1e-12)


def test_freq_intensity_matches_the_literal_upstream_function():
    pd = pytest.importorskip("pandas")
    pytest.importorskip("sklearn")
    from energy_models.wristmet.pipeline import upstream_reference as U

    w = _windows(2)[:, :300]  # the literal function is O(N^2 log N); 300 samples keep the test fast
    for win in w:
        acc = win[:, 3:6]
        df = pd.DataFrame({"accX": acc[:, 0], "accY": acc[:, 1], "accZ": acc[:, 2]})
        assert F.freq_intensity(acc) == U.get_freq_intensity(df, 100, 1)


def test_freq_intensity_reports_five_times_the_physical_frequency():
    """Upstream hard-codes fs=100 for 20 Hz data; the quirk is part of what the model was trained on."""
    n = 1200
    t = np.arange(n) / 20.0
    acc = np.zeros((n, 3))
    acc[:, 2] = 9.81 + 2.0 * np.sin(2 * np.pi * 1.0 * t)  # 1 Hz physical
    f = F.freq_intensity(acc)
    assert f == pytest.approx(5.0, abs=0.2)
    assert F.freq_intensity(acc, fs=20.0) == pytest.approx(1.0, abs=0.05)


def test_rmssd_l1_is_zero_for_constant_signal_and_scale_invariant():
    const = np.tile([1.0, -7.0, 4.0], (200, 1))
    assert F.rmssd_l1(const) == 0.0
    x = np.random.default_rng(0).normal(size=(200, 3)) + 5.0
    assert F.rmssd_l1(3.0 * x) == pytest.approx(F.rmssd_l1(x), rel=1e-12)  # per-axis L1 normalisation


def test_demographic_and_regressor_features():
    d = F.demographic_features(40.0, "female", 80.0, 160.0)
    assert d["gender"] == 0.0 and d["BMI"] == pytest.approx(80.0 / 1.6**2)
    assert d["gender_age"] == 0.0 and d["age_BMI"] == pytest.approx(40.0 * d["BMI"])
    m = F.demographic_features(40.0, "male", 80.0, 160.0)
    assert m["gender"] == 1.0 and m["age_gender_BMI"] == pytest.approx(40.0 * m["BMI"])
    x = F.regressor_features(np.array([[1.5, 0.02]]), age=40.0, sex="m", weight_kg=80.0, height_cm=160.0)
    assert x.shape == (1, 9)
    assert x[0, 3] == 1.5 and x[0, 8] == 0.02 and x[0, 0] == 1.0
    for bad in ("other", "", 2, 0.5):
        with pytest.raises(ValueError):
            F.sex_to_gender(bad)


def test_mirror_negates_only_acc_x_gyr_y_gyr_z_and_is_an_involution():
    w = _windows(1)
    mirrored = mirror_to_right_wrist(w)
    assert MIRROR_NEGATE_CHANNELS == (3, 1, 2)
    for c in range(6):
        sign = -1.0 if c in MIRROR_NEGATE_CHANNELS else 1.0
        np.testing.assert_array_equal(mirrored[..., c], sign * w[..., c])
    np.testing.assert_array_equal(mirror_to_right_wrist(mirrored), w)
