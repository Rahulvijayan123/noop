"""Window-local detection: static pre-filter, probability, calibration, quality only on gait, nonfinite omission."""

import numpy as np
import pytest

from activity_context.eldernet import QUALITY_HEADS, STATIC_VARIANCE_CEILING
from activity_context.eldernet.gait import (CALIBRATION_SCHEMA, GaitCalibration, gait_probability, prefilter_mask,
                                            score_windows, window_variance, wire_windows)
from activity_context.eldernet.preprocess import stack_windows, windows_from_array

from ._helpers import FakeHeads, synth_g


def _batch(kinds, seed=0):
    acc = np.concatenate([synth_g(10, k, seed=seed + i) for i, k in enumerate(kinds)])
    w = windows_from_array(acc, 100, hop_s=10)
    return w, stack_windows(w)


def test_prefilter_is_the_upstream_ceiling_statistic():
    w, b = _batch(["still", "walk", "fidget"])
    v = window_variance(b)
    assert np.allclose(v, np.var(b, axis=1).mean(axis=1))
    assert prefilter_mask(b).tolist() == (v <= STATIC_VARIANCE_CEILING).tolist() == [True, False, True]


def test_prefilter_depends_only_on_the_window():
    _, b = _batch(["still", "walk", "still", "walk"])
    alone = [prefilter_mask(b[i:i + 1])[0] for i in range(len(b))]
    assert alone == prefilter_mask(b).tolist()


def test_probability_is_softmax_and_temperature_scales_the_logit_gap():
    z = np.array([[0.0, 2.0], [1.0, -3.0], [5.0, 5.0], [-800.0, 800.0]])
    sm = np.exp(z - z.max(1, keepdims=True))
    sm = sm[:, 1] / sm.sum(1)
    assert np.allclose(gait_probability(z), sm)
    assert np.allclose(gait_probability(z, 2.0), 1 / (1 + np.exp(-(z[:, 1] - z[:, 0]) / 2.0)))
    assert np.isfinite(gait_probability(z)).all()


def test_scores_prefiltered_windows_never_reach_the_model_and_quality_only_on_gait():
    w, b = _batch(["still", "walk", "fidget", "walk"])
    heads = FakeHeads()
    sc = score_windows(heads, b)
    assert sc.prefiltered.tolist() == [True, False, True, False]
    assert heads.calls[0] == ("detect", 2)
    assert sc.gait_prob[sc.prefiltered].tolist() == [0.0, 0.0]
    assert sc.is_gait.tolist() == [False, True, False, True]
    assert heads.calls[1] == ("quality", 2)
    for name in QUALITY_HEADS:
        assert np.isnan(sc.metrics[name][~sc.is_gait]).all()
        assert np.isfinite(sc.metrics[name][sc.is_gait]).all()


def test_wire_windows_shape_and_clipping():
    w, b = _batch(["still", "walk"])
    sc = score_windows(FakeHeads(), b)
    items, dropped = wire_windows(w, sc)
    assert dropped == 0
    assert items[0] == {"s": 0.0, "e": 10.0, "gait_prob": 0.0, "is_gait": False, "prefiltered": True}
    g = items[1]
    assert g["is_gait"] and "prefiltered" not in g
    assert set(g) == {"s", "e", "gait_prob", "is_gait", "speed_mps", "cadence_spm", "stride_m", "regularity", "steps"}
    assert 0 <= g["speed_mps"] <= 2.0 and 0 <= g["regularity"] <= 1.0 and 0 <= g["cadence_spm"] <= 150


class _FixedLogit(FakeHeads):
    def detect(self, batch):
        return np.tile([0.0, 0.5], (len(batch), 1))                 # p = 0.6225


def test_threshold_from_calibration_decides_is_gait():
    w, b = _batch(["walk"])
    assert abs(score_windows(_FixedLogit(), b).gait_prob[0] - 0.622459) < 1e-6
    assert not score_windows(_FixedLogit(), b, GaitCalibration(threshold=0.7)).is_gait[0]
    assert score_windows(_FixedLogit(), b, GaitCalibration(threshold=0.6)).is_gait[0]
    assert abs(score_windows(_FixedLogit(), b, GaitCalibration(T=0.5)).gait_prob[0] - 0.731059) < 1e-6
    assert GaitCalibration(T=2.0).wire() == {"gait_prob": {"method": "temperature", "T": 2.0, "fit": "val"}}


@pytest.mark.parametrize("which", ["detect", "quality"])
def test_nonfinite_outputs_are_omitted_and_counted(which):
    w, b = _batch(["walk", "walk"])
    heads = FakeHeads(nonfinite_detect=which == "detect", nonfinite_quality=which == "quality")
    items, dropped = wire_windows(w, score_windows(heads, b))
    assert dropped == 1 and len(items) == 1 and items[0]["s"] == 10.0


def test_calibration_doc_validation():
    good = {"schema": CALIBRATION_SCHEMA, "gait_prob": {"method": "temperature", "T": 1.3, "fit": "val"},
            "gait_threshold": 0.7}
    assert GaitCalibration.from_doc(good).T == 1.3
    for bad in ({**good, "schema": "x"}, {**good, "gait_prob": {"method": "platt", "T": 1, "fit": "val"}},
                {**good, "gait_prob": {"method": "temperature", "T": 1, "fit": "test"}},
                {**good, "gait_threshold": 1.5}, {**good, "gait_prob": {"method": "temperature", "T": -1, "fit": "val"}}):
        with pytest.raises(ValueError):
            GaitCalibration.from_doc(bad)
