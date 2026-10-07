"""evaluate.py: calibration diagnostics, temperature fit and the censored transition delay."""

import math

import numpy as np
import pytest

from activity_context import evaluate as E


def test_calibration_of_perfect_and_uniform_predictions():
    y = np.array([0, 1, 2, 3, 0, 1, 2, 3])
    perfect = np.eye(4)[y]
    m = E.calibration_metrics(perfect, y)
    assert m["nll"] == pytest.approx(0.0, abs=1e-9) and m["brier"] == 0.0 and m["ece"] == 0.0
    uniform = np.full((8, 4), 0.25)
    m = E.calibration_metrics(uniform, y)
    assert m["nll"] == pytest.approx(math.log(4), abs=1e-4)
    assert m["brier"] == pytest.approx(0.75, abs=1e-4)
    # argmax of a uniform row is class 0: accuracy 2/8 at confidence 0.25 -> ECE 0
    assert m["ece"] == pytest.approx(0.0, abs=1e-9)


def test_ece_of_an_overconfident_model():
    # confidence 0.9 everywhere, right half of the time -> ECE 0.4
    p = np.tile([0.9, 0.1 / 3, 0.1 / 3, 0.1 / 3], (10, 1))
    y = np.array([0] * 5 + [1] * 5)
    m = E.calibration_metrics(p, y, n_bins=10)
    assert m["ece"] == pytest.approx(0.4, abs=1e-6)
    assert m["accuracy_top1"] == 0.5 and m["mean_confidence"] == pytest.approx(0.9)
    assert sum(b["n"] for b in m["reliability"]) == 10


def test_labels_outside_the_classes_are_ignored():
    p = np.eye(4)[[0, 1, 2]]
    m = E.calibration_metrics(p, np.array([0, -1, 2]))
    assert m["n"] == 2


def test_aggregate_softmax_groups_columns():
    logits = np.log(np.array([[0.1, 0.2, 0.3, 0.4]]))
    q = E.aggregate_softmax(logits, np.array([0, 0, 1, 1]), 2)
    np.testing.assert_allclose(q, [[0.3, 0.7]], atol=1e-12)


def test_fit_temperature_recovers_overconfidence():
    rng = np.random.default_rng(0)
    z = rng.normal(0.0, 1.5, size=(4000, 6))
    p = np.exp(z) / np.exp(z).sum(axis=1, keepdims=True)
    y6 = np.array([rng.choice(6, p=row) for row in p])
    groups = np.array([0, 0, 1, 1, 2, 3])
    y = groups[y6]
    t = E.fit_temperature(3.0 * z, y, groups, 4)      # logits 3x too sharp
    assert t == pytest.approx(3.0, rel=0.1)
    raw = E.calibration_metrics(E.aggregate_softmax(3.0 * z, groups, 4), y)
    fixed = E.calibration_metrics(E.aggregate_softmax(3.0 * z, groups, 4, t), y)
    assert fixed["nll"] < raw["nll"] and fixed["ece"] < raw["ece"]


def test_censored_transition_delay_stops_at_the_next_change():
    y = ["walking"] * 3 + ["running"] * 3 + ["stationary"] * 4
    preds = ["walking", "walking", "walking",
             "unknown", "unknown", "unknown",           # running never recovered -> missed
             "unknown", "stationary", "stationary", "stationary"]
    d = E.transition_delay_censored(y, preds)
    assert d["n_transitions"] == 2 and d["n_missed"] == 1
    assert d["mean_s"] == pytest.approx(E.HOP_SECONDS)
    # the session-aware metric also counts both changes and misses 'running' (censored at the session end)
    assert E._transition_delay(np.asarray(y), preds)["n_transitions"] == 2


def test_accepted_precision_pools_accepted_predictions():
    conf = {"stationary": {"stationary": 8, "walking": 0, "running": 0, "other_movement": 2, "unknown": 5},
            "walking": {"stationary": 0, "walking": 3, "running": 0, "other_movement": 1, "unknown": 0},
            "running": {"stationary": 0, "walking": 0, "running": 0, "other_movement": 0, "unknown": 0},
            "other_movement": {"stationary": 0, "walking": 0, "running": 0, "other_movement": 6, "unknown": 9},
            "unknown": {"stationary": 0, "walking": 0, "running": 0, "other_movement": 0, "unknown": 0}}
    assert E.accepted_precision(conf) == pytest.approx(17 / 20)


def test_evaluate_report_carries_calibration_and_censored_delays():
    rng = np.random.default_rng(1)
    x = rng.normal(0, 0.01, size=(6, 120, 6))
    x[:, :, 2] += 1.0
    y = np.array(["stationary"] * 3 + ["walking"] * 3)

    def pred(_w):
        return "stationary", {"stationary": 0.9, "walking": 0.05, "running": 0.0, "other_movement": 0.05}

    rep = E.evaluate(x, y, pred, {"max_prob": 0.8, "margin": 0.15})
    assert rep["calibration"]["n"] == 6
    assert rep["calibration"]["accuracy_top1"] == 0.5
    assert rep["transition_delay_censored_s"] == {"n_transitions": 1, "n_missed": 1}
    assert rep["accepted_precision"] == 0.5


def test_supported_probs_drops_unknown_mass():
    np.testing.assert_allclose(E.supported_probs({"stationary": 0.5, "walking": 0.5}), [0.5, 0.5, 0, 0])
    np.testing.assert_allclose(E.supported_probs({"unknown": 1.0}), [0.25] * 4)
