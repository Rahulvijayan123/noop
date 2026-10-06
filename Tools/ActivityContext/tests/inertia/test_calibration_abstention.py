"""Calibration (val only, round-trip through the bundle), operating points / test gate, events."""

import numpy as np
import pytest

from activity_context.inertia import abstention as A
from activity_context.inertia import calibrate as C
from activity_context.inertia import events as Ev
from activity_context.inertia import metrics as M


def _logits(n=3000, K=3, T=2.5, seed=0):
    rng = np.random.default_rng(seed)
    y = rng.integers(0, K, n)
    z = rng.standard_normal((n, K)) + 2.0 * np.eye(K)[y]
    z_true = z.copy()
    p = np.exp(z_true - z_true.max(1, keepdims=True))
    p /= p.sum(1, keepdims=True)
    y = np.array([rng.choice(K, p=pi) for pi in p])
    return z * T, np.eye(K, dtype=bool)[y], np.array([f"s{i % 10}" for i in range(n)])


def test_temperature_recovers_known_T():
    z, truth, _ = _logits()
    assert abs(C.fit_temperature(z, truth)["T"] - 2.5) < 0.2


def test_fit_softmax_refuses_non_val_and_records_provenance():
    z, truth, subj = _logits()
    sup = np.array([True, True, True])
    with pytest.raises(C.CalibrationLeak):
        C.fit_softmax("test", z, truth, subj, sup, ["a", "b", "c"], "x" * 64)
    e = C.fit_softmax("val", z, truth, subj, sup, ["a", "b", "c"], "v" * 64)
    assert e["fit"]["split"] == "val" and e["fit"]["val_split_sha256"] == "v" * 64
    assert e["method"] in C.METHODS and abs(sum(e["class_prior"].values()) - 1) < 1e-9
    p = C.apply_supported(z, {**e, **({"bias": np.array(e["bias"])} if e.get("bias") else {}),
                              **({"weight": np.array(e["weight"])} if e.get("weight") else {})})
    raw = np.exp(z - z.max(1, keepdims=True))
    raw /= raw.sum(1, keepdims=True)
    assert M.nll(p, truth) < M.nll(raw, truth)


def test_set_truth_nll():
    p = np.array([[0.5, 0.3, 0.2]])
    truth = np.array([[False, True, True]])
    assert abs(M.nll(p, truth) + np.log(0.5)) < 1e-12
    assert abs(M.brier(p, truth) - (0.25 + 0.25)) < 1e-12


def test_per_event_temperature_val_only():
    rng = np.random.default_rng(1)
    y = rng.integers(0, 2, (2000, 2)).astype(np.int8)
    z = (2 * y - 1) * 3.0 + rng.standard_normal((2000, 2))
    y[:100, 1] = -1
    with pytest.raises(C.CalibrationLeak):
        C.fit_per_event("train", z, y, np.array([True, False]), ["e1", "e2"], "x")
    e = C.fit_per_event("val", z, y, np.array([True, False]), ["e1", "e2"], "v")
    assert e["T"][1] is None and e["T"][0] > 0 and list(e["class_prior"]) == ["e1"]


def _ops_data(prec, n=600, seed=0):
    rng = np.random.default_rng(seed)
    truth = np.zeros((n, 2), bool)
    correct = rng.random(n) < prec
    truth[np.arange(n), np.where(correct, 0, 1)] = True
    q = 0.96 + 0.03 * rng.random(n)
    return np.column_stack([q, 1 - q]), truth, np.array([f"s{i % 5}" for i in range(n)])


def test_operating_point_strong_weak_abstain():
    for prec, want in ((0.995, "strong"), (0.88, "weak"), (0.5, "abstain")):
        p, t, s = _ops_data(prec)
        assert A.select_operating_point(p, t, s, 0, True)["status"] == want
    assert A.select_operating_point(*_ops_data(0.99), 0, False)["status"] == "abstain"


def test_gate_only_demotes():
    p, t, s = _ops_data(0.6)
    g = A.check_gate(p, t, 0, 0.5)
    assert not g["pass"] and A.apply_gate("strong", g) == "weak"
    assert A.apply_gate("weak", {"pass": True}) == "weak" and A.apply_gate("abstain", {"pass": True}) == "abstain"


def test_risk_coverage_and_aurc():
    conf = np.array([0.9, 0.8, 0.7, 0.6])
    correct = np.array([True, True, False, False])
    rc = A.risk_coverage(conf, correct)
    assert rc["coverage"][-1] == 1.0 and rc["risk"][0] == 0.0
    assert A.aurc(conf, correct)["aurc"] == pytest.approx((0 + 0 + 1 / 3 + 0.5) / 4)


def test_event_extraction_and_matching():
    t = np.arange(0, 100, 2.0)
    p = np.zeros_like(t)
    p[[10, 11, 30]] = [0.8, 0.9, 0.7]
    pred = Ev.extract_events(t, p, 0.5, refractory_s=10)
    assert list(pred) == [22.0, 60.0]
    m = Ev.event_metrics([{"pred": pred, "true": np.array([20.0, 80.0])}], 5.0)
    assert (m["tp"], m["fp"], m["fn"]) == (1, 1, 1) and m["abs_err_median_s"] == 2.0
