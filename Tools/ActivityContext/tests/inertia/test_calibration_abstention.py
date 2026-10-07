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
    assert not g["pass"] and g["level"] == "abstain"
    # G-5: test precision < .80 at n_acc >= 30 demotes weak (and strong) to abstain
    assert A.apply_gate("strong", g) == "abstain" and A.apply_gate("weak", g) == "abstain"
    p, t, s = _ops_data(0.88)
    g = A.check_gate(p, t, 0, 0.5)
    assert g["level"] == "weak" and A.apply_gate("strong", g) == "weak" and A.apply_gate("weak", g) == "weak"
    assert A.apply_gate("weak", {"pass": True}) == "weak" and A.apply_gate("abstain", {"pass": True}) == "abstain"
    assert A.apply_gate("abstain", {"level": "strong"}) == "abstain"


def test_gate_needs_30_accepted_to_demote_weak():
    p, t, s = _ops_data(0.3, n=20)
    g = A.check_gate(p, t, 0, 0.5)
    assert g["n_acc"] < 30 and g["level"] == "weak" and not g["decisive"]
    assert A.apply_gate("weak", g) == "weak" and A.apply_gate("strong", g) == "weak"


def test_per_dataset_gate_demotes_a_class_that_passes_pooled():
    """G-5: e.g. stairs passes pooled but fails on one wrist dataset with n_acc >= 30 -> demoted."""
    good = A.check_gate(*_ops_data(0.995, n=3000)[:2], 0, 0.5)
    assert good["pass"]
    bad = A.check_gate(*_ops_data(0.033, n=300, seed=4)[:2], 0, 0.5, dataset_level=True)
    tiny = A.check_gate(*_ops_data(0.0, n=10, seed=5)[:2], 0, 0.5, dataset_level=True)
    final, reasons = A.final_status("strong", good, {"capture24": bad, "mhealth": tiny})
    assert final == "abstain" and len(reasons) == 1 and reasons[0].startswith("capture24")
    assert A.final_status("weak", good, {"mhealth": tiny}) == ("weak", [])
    mid = A.check_gate(*_ops_data(0.9, n=300, seed=6)[:2], 0, 0.5, dataset_level=True)
    assert A.final_status("strong", good, {"wisdm": mid})[0] == "weak"


def _subject_ops(prec_by_subject, n_per=200, seed=0):
    rng = np.random.default_rng(seed)
    P, T, S = [], [], []
    for i, prec in enumerate(prec_by_subject):
        correct = rng.random(n_per) < prec
        tr = np.zeros((n_per, 2), bool)
        tr[np.arange(n_per), np.where(correct, 0, 1)] = True
        q = 0.96 + 0.03 * rng.random(n_per)
        P.append(np.column_stack([q, 1 - q]))
        T.append(tr)
        S += [f"s{i}"] * n_per
    return np.concatenate(P), np.concatenate(T), np.array(S)


def test_strong_survives_subject_clustering_only():
    """G-4: pooled precision ~.97 carried by a mix of perfect and bad subjects is not strong; uniform is."""
    p, t, s = _subject_ops([0.995] * 8)
    op = A.select_operating_point(p, t, s, 0, True)
    assert op["status"] == "strong" and op["evidence"]["cluster_q05"] >= 0.95 and op["evidence"]["n_subjects_acc"] >= 5
    p, t, s = _subject_ops([1.0] * 6 + [0.80, 0.82])
    op = A.select_operating_point(p, t, s, 0, True)
    assert op["status"] != "strong" and op["evidence"]["cluster_q05"] < 0.95


def test_fewer_than_five_subjects_is_at_most_weak():
    p, t, s = _subject_ops([0.999] * 4, n_per=400)
    op = A.select_operating_point(p, t, s, 0, True)
    assert op["status"] == "weak" and op["n_val_subjects_class"] == 4 and "strong_ineligible" in op


def test_weak_needs_cluster_quantile():
    p, t, s = _subject_ops([0.98] * 4 + [0.30] * 2, n_per=200)
    op = A.select_operating_point(p, t, s, 0, True)
    assert op["status"] == "abstain"                         # cluster q05 < .70 although pooled precision ~.75-.8


def test_cluster_quantile_matches_a_naive_bootstrap():
    p, t, s = _subject_ops([0.99, 0.9, 0.7, 1.0, 0.95], n_per=50, seed=3)
    grid = np.array([0.5, 0.97])
    q = A.cluster_precision_quantile(p, t, s, 0, grid, n_boot=300, seed=7)
    rng = np.random.default_rng(7)
    subs = np.unique(s)
    W = [np.bincount(rng.integers(0, len(subs), len(subs)), minlength=len(subs)) for _ in range(300)]
    for g, tau in enumerate(grid):
        acc = (p.argmax(1) == 0) & (p[:, 0] >= tau)
        n_s = np.array([(acc & (s == u)).sum() for u in subs])
        t_s = np.array([(acc & t[:, 0] & (s == u)).sum() for u in subs])
        prec = [((w * t_s).sum() / (w * n_s).sum()) if (w * n_s).sum() else 0.0 for w in W]
        assert abs(np.quantile(prec, 0.05) - q[g]) < 1e-12


def test_merge_only_into_compatible_live_partners():
    order = ["stationary", "walking", "brisk_walking", "running", "stairs", "cycling", "vehicle_motion", "other"]
    st = {"stationary": "strong", "walking": "strong", "running": "weak", "stairs": "abstain", "cycling": "abstain",
          "other": "abstain", "vehicle_motion": "weak"}
    K = len(order)
    sym = [[0] * K for _ in range(K)]
    sym[order.index("cycling")][order.index("stationary")] = 99        # most confused, but not compatible
    sym[order.index("other")][order.index("running")] = 99
    m = A.merge_partners(st, order, "locomotion", sym)
    assert m == {"stairs": "walking"}                                   # cycling / other are dropped
    st2 = dict(st, walking="abstain")
    assert "stairs" not in A.merge_partners(st2, order, "locomotion", sym)   # partner abstained -> dropped
    assert A.merge_partners({"quiet": "abstain", "desk_like": "abstain", "repetitive_hand_motion": "weak"},
                            ["quiet", "desk_like", "fidgeting", "repetitive_hand_motion", "active_gesturing",
                             "exercise_motion", "other"], "arm_behavior") == {}
    assert A.evidence_groups({"quiet": "abstain", "desk_like": "abstain", "repetitive_hand_motion": "weak"}, {}) == [
        "repetitive_hand_motion"]


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
