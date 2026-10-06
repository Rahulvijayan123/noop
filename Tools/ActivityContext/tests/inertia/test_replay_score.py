"""Replay scorer (agent R): histogram metrics agree with brute force; truth alignment; events; bootstrap."""

import numpy as np
import pytest

pytest.importorskip("scipy")

from activity_context.inertia import replay_data as rd
from activity_context.inertia import replay_export as rx
from activity_context.inertia import replay_score as rs


def _brute_cov_at_precision(score, pos, target=0.95):
    from scipy.stats import beta
    P = pos.sum()
    best = (0.0, None)
    for tau in np.unique(score):
        if tau < 0.001:
            continue
        m = score >= tau
        n = m.sum()
        k = (m & pos).sum()
        lb = beta.ppf(0.05, k, n - k + 1) if k > 0 else 0.0
        if lb >= target and k / P > best[0] + 1e-15:
            best = (k / P, tau)
        elif lb >= target and abs(k / P - best[0]) <= 1e-15 and best[1] is not None and tau > best[1]:
            best = (k / P, tau)
    return best


def test_coverage_at_precision_matches_brute_force():
    rng = np.random.default_rng(0)
    for trial in range(5):
        n = 3000
        pos = rng.random(n) < 0.4
        score = np.clip(np.where(pos, rng.beta(5, 2, n), rng.beta(2, 5, n)), 0, 1)
        score = np.round(score, 3)
        ph, nh = rs.class_histograms(score, pos)
        got = rs.coverage_at_precision_hist(ph, nh)
        cov, tau = _brute_cov_at_precision(score, pos)
        assert got["coverage"] == pytest.approx(cov)
        if tau is not None:
            assert got["tau"] == pytest.approx(tau)
            assert got["cp_lower"] >= 0.95


def test_coverage_infeasible_is_zero():
    score = np.full(100, 0.9)
    pos = np.zeros(100, bool)
    pos[:50] = True
    ph, nh = rs.class_histograms(score, pos)
    r = rs.coverage_at_precision_hist(ph, nh)
    assert r["coverage"] == 0.0 and r["tau"] is None


def test_operating_point():
    score = np.array([0.1, 0.5, 0.9, 0.95])
    pos = np.array([False, True, True, True])
    ph, nh = rs.class_histograms(score, pos)
    op = rs.operating_point_hist(ph, nh, 0.5)
    assert op["claimed"] == 3 and op["precision"] == 1.0 and op["coverage"] == 1.0
    assert op["precision_ci"][1] == 1.0


def test_aurc_matches_brute_force_with_distinct_scores():
    rng = np.random.default_rng(1)
    n = 500
    conf = rng.permutation(np.arange(n)) / 1000.0 + 0.3          # distinct bins
    correct = rng.random(n) < conf
    ch = np.bincount(rs.score_bins(conf[correct]), minlength=rs.NBINS)
    wh = np.bincount(rs.score_bins(conf[~correct]), minlength=rs.NBINS)
    got = rs.risk_coverage_hist(ch, wh)
    order = np.argsort(-conf)
    errs = np.cumsum(~correct[order])
    brute = np.mean(errs / np.arange(1, n + 1))
    assert got["aurc"] == pytest.approx(brute, abs=1e-12)
    assert got["error_rate"] == pytest.approx((~correct).mean())


def test_calibration_terms_set_truth_and_unknown():
    order = rs.DECODER_ORDERS["posture"]                 # 4 known + unknown
    probs = np.array([[0.5, 0.3, 0.1, 0.0, 0.1],       # truth {recumbent, seated} -> mass (.5+.3)/.9
                      [0.0, 0.9, 0.1, 0.0, 0.0],       # truth {seated}
                      [0.2, 0.2, 0.2, 0.2, 0.2]])      # MASK
    rec_b, seat_b = 1 << 0, 1 << 1
    truth = np.array([rec_b | seat_b, seat_b, 0], np.uint16)
    t = rs.calibration_terms(probs, truth)
    assert list(t["has"]) == [True, True, False]
    assert t["nll"][0] == pytest.approx(-np.log(0.8 / 0.9))
    assert t["nll"][1] == pytest.approx(-np.log(0.9))
    assert list(t["single"]) == [False, True, False]
    assert t["brier"][1] == pytest.approx(0.01 + 0.01)
    s = rs.calibration_summary(t)
    assert s["n"] == 2 and s["n_single"] == 1
    assert s["unknown_mass_mean"] == pytest.approx(0.05)


def test_correct_top_uses_known_classes_only():
    probs = np.array([[0.1, 0.2, 0.0, 0.0, 0.7]])     # unknown dominates; top known = seated
    truth = np.array([1 << 1], np.uint16)
    ok, conf = rs.correct_top(probs, truth)
    assert ok[0] and conf[0] == pytest.approx(0.2)


def test_align_truth_with_gaps():
    sec = np.array([0, 1, 2, 10, 11], np.int64)
    loco = np.array([1, 1, 2, 4, 4], np.uint16)
    rec = rx.Recording(recording_id="r", dataset="capture24", subject="P", split="test", t0=1000, sec=sec,
                       gravity=np.zeros((5, 3), np.float32), dyn=np.zeros(5, np.float32),
                       truth_strict={"locomotion": loco}, truth_lenient={"locomotion": loco})
    st = rs.ArmStates(record_id="r|A0", recording_id="r", arm="A0", ts=np.array([1001, 1003, 1005, 1011, 1012]),
                      heads={}, display=np.array([""] * 5), overall_confidence=np.zeros(5))
    t = rs.align_truth(st, rec)
    assert list(t["locomotion"]) == [1, 2, 0, 4, 4]     # ts 1005 -> second 4: not observed -> MASK
    assert list(t["posture"]) == [0, 0, 0, 0, 0]


def test_states_from_json():
    states = [{"ts": 5, "posture": {"seated_likely": 0.6, "unknown": 0.4}, "locomotion": {"stationary": 1.0},
               "arm_behavior": {"quiet": 0.5, "unknown": 0.5}, "display_context": "Sitting quietly",
               "overall_confidence": 0.7},
              {"ts": 10, "posture": {}, "locomotion": {"walking": 0.9, "unknown": 0.1}, "arm_behavior": {},
               "display_context": None, "overall_confidence": 0.2}]
    a = rs.states_from_json("x|A0", "x", "A0", states, [{"kind": "walk_start", "ts": 9, "probability": 0.8}])
    assert a.heads["posture"][0, rs.DECODER_ORDERS["posture"].index("seated_likely")] == 0.6
    assert a.display.tolist() == ["Sitting quietly", ""]
    assert a.events == [("walk_start", 9, 0.8)]


def test_event_matching():
    truth = [rs.TruthEvent("walk_start", 100, 120), rs.TruthEvent("walk_stop", 300, 310)]
    pred = [("walk_start", 125, 0.9), ("walk_start", 500, 0.9), ("walk_stop", 290, 0.9)]
    r5 = rs.match_events(pred, truth, 5)
    assert r5["tp"] == 1 and r5["fp"] == 2 and r5["fn"] == 1
    r10 = rs.match_events(pred, truth, 10)
    assert r10["tp"] == 2 and r10["fp"] == 1 and r10["fn"] == 0
    assert r10["median_abs_err_s"] == pytest.approx(np.median([abs(125 - 110), abs(290 - 305)]))


def test_display_flips():
    st = rs.ArmStates(record_id="r", recording_id="r", arm="A0", ts=np.array([5, 10, 15, 20, 1000, 1005]),
                      heads={}, display=np.array(["a", "a", "b", "a", "c", "c"]), overall_confidence=np.zeros(6))
    flips, hours = rs.display_flips(st)
    assert flips == 2                                   # a->b, b->a; the change across the long gap is not a flip
    assert hours == pytest.approx((5 * 3 + 5) / 3600.0)


def test_cluster_bootstrap_paired_difference():
    rng = np.random.default_rng(3)
    per = {f"s{i}": (rng.normal(0.5, 0.05), rng.normal(0.6, 0.05)) for i in range(20)}
    r = rs.cluster_bootstrap(per, lambda items: float(np.mean([b - a for a, b in items])), n_boot=500)
    assert r["ci95"][0] < r["point"] < r["ci95"][1]
    assert r["ci95"][0] > 0                              # a +0.1 shift is clearly detected
    assert r["n_clusters"] == 20


def test_histogram_coverage_matches_p2_class_curve():
    """The bootstrap's histogram estimator equals P2's abstention.class_curve-based descriptive estimate."""
    from activity_context.inertia.abstention import class_curve
    rng = np.random.default_rng(7)
    n = 4000
    K = 4
    logits = rng.normal(size=(n, K))
    y = rng.integers(0, K, n)
    logits[np.arange(n), y] += rng.gamma(2.0, 1.5, n)
    probs = np.exp(logits) / np.exp(logits).sum(axis=1, keepdims=True)
    truth = np.zeros((n, K), bool)
    truth[np.arange(n), y] = True
    subj = rng.integers(0, 10, n).astype(str)
    for c in range(K):
        rows = class_curve(probs, truth, subj, c)
        ok = [r for r in rows if r["n_acc"] >= 60 and r["cp_lower_95"] >= 0.95]
        want = max(ok, key=lambda r: (r["recall"], r["tau"]))["recall"] if ok else 0.0
        acc = probs.argmax(axis=1) == c
        ph, nh = rs.class_histograms(np.where(acc, probs[:, c], 0.0), truth[:, c])
        # non-argmax states sit in bin 0: counted as positives (recall denominator), never claimed (tau >= .3)
        got = rs.coverage_at_precision_hist(ph, nh, min_bin=300, n_min=60, grid_step=5)["coverage"]
        assert got == pytest.approx(want, abs=1e-12), c
