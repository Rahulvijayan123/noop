"""Replay evaluation (agent R): output parsing, truth folding, scoring and the paired subject bootstrap on
synthetic decoder states (no Swift, no datasets)."""

import numpy as np
import pytest

pytest.importorskip("scipy")

from activity_context.inertia import replay_data as rd
from activity_context.inertia import replay_eval as ev
from activity_context.inertia import replay_export as rx
from activity_context.inertia import replay_score as rs

T0 = 1_760_000_000


def _rec(rid, subject, n, loco_label):
    order = rd.HEAD_ORDERS["locomotion"]
    if loco_label == "walking":
        m = (1 << order.index("walking")) | (1 << order.index("brisk_walking"))
    else:
        m = 1 << order.index(loco_label)
    post = np.zeros(n, np.uint16)
    if loco_label == "stationary":
        post[:] = 1 << rd.HEAD_ORDERS["posture"].index("seated_likely")
    return rx.Recording(recording_id=rid, dataset="wisdm", subject=subject, split="test", t0=T0, sec=np.arange(n),
                        gravity=np.zeros((n, 3), np.float32), dyn=np.zeros(n, np.float32),
                        truth_strict={"locomotion": np.full(n, m, np.uint16), "posture": post,
                                      "arm_behavior": np.zeros(n, np.uint16)},
                        truth_lenient={})


def _states(rec, p_walk, rng, noise=0.0):
    ts = np.arange(5, rec.n + 1, 5) + rec.t0
    m = len(ts)
    heads = {}
    lo = np.zeros((m, len(rs.DECODER_ORDERS["locomotion"])))
    pw = np.clip(p_walk + noise * rng.normal(size=m), 0.0, 0.95)
    lo[:, rs.DECODER_ORDERS["locomotion"].index("walking")] = pw * 0.8
    lo[:, rs.DECODER_ORDERS["locomotion"].index("brisk_walking")] = pw * 0.2
    lo[:, rs.DECODER_ORDERS["locomotion"].index("stationary")] = 0.95 - pw
    lo[:, -1] = 0.05
    heads["locomotion"] = lo
    po = np.zeros((m, len(rs.DECODER_ORDERS["posture"])))
    po[:, 1] = 0.6
    po[:, -1] = 0.4
    heads["posture"] = po
    ar = np.zeros((m, len(rs.DECODER_ORDERS["arm_behavior"])))
    ar[:, -1] = 1.0
    heads["arm_behavior"] = ar
    disp = np.array(["Walking" if p > 0.5 else "Sitting (likely)" for p in pw])
    return ev.SeqStates(ts=ts, heads=heads, display=disp, klass=disp, events=[], refusal=None, motion_heads=None)


def _tables(seed=0, shift=0.0):
    rng = np.random.default_rng(seed)
    recs, sa, sb = [], {}, {}
    for i in range(12):
        lab = "walking" if i % 2 == 0 else "stationary"
        r = _rec(f"r{i}", f"s{i // 2}", 300, lab)
        recs.append(r)
        base = 0.7 if lab == "walking" else 0.2
        sa[r.recording_id] = _states(r, base, rng, 0.15)
        sb[r.recording_id] = _states(r, min(0.95, base + (shift if lab == "walking" else -shift)), rng, 0.15)
    return recs, ev.build_table("A", recs, sa), ev.build_table("B", recs, sb)


def test_parse_seq_and_fold():
    entry = {"states": [{"ts": 10, "locomotion": {"walking": 0.5, "brisk_walking": 0.3, "unknown": 0.2},
                         "posture": {"unknown": 1.0}, "arm_behavior": {"quiet": 1.0}, "display": None, "class": "walking"}],
             "events": [{"kind": "walk_start", "ts": 9, "probability": 0.7}], "refusal": None}
    s = ev.parse_seq(entry)
    assert s.display.tolist() == [""] and s.events == [("walk_start", 9, 0.7)]
    f = ev._fold("locomotion", s.heads["locomotion"])
    assert f[0, ev.SCORE_ORDERS["locomotion"].index("walking")] == pytest.approx(0.8)
    tb = ev._truth_bool("locomotion", np.array([(1 << 1) | (1 << 2)], np.uint16))   # {walking, brisk}
    assert tb[0].tolist() == [c == "walking" for c in ev.SCORE_ORDERS["locomotion"]]


def test_build_table_alignment_and_truth():
    recs, ta, tb = _tables()
    ev.check_alignment({"A": ta, "B": tb})
    assert len(ta.ts) == 12 * 60
    # truth at ts = t0 + i + 1 -> second i; a state at ts = t0 + 300 maps to second 299 (in range)
    assert ta.truth["locomotion"].any(axis=1).all()
    tb.ts = tb.ts.copy()
    tb.ts[0] += 1
    with pytest.raises(RuntimeError):
        ev.check_alignment({"A": ta, "B": tb})


def test_score_arm_runs_and_reports_classes():
    recs, ta, _ = _tables()
    sc = ev.score_arm(ta, recs)
    assert set(sc["locomotion"]["classes"]) == {"stationary", "walking"}
    assert sc["locomotion"]["n"] == len(ta.ts)
    assert 0 <= sc["locomotion"]["aurc"]["aurc"] <= 1
    assert sc["display"]["flips_per_hour"] is not None


def test_paired_bootstrap_identical_arms_is_zero():
    recs, ta, _ = _tables()
    tb = ev.ArmTable(arm="B", subject=ta.subject, seq=ta.seq, ts=ta.ts, probs=ta.probs, truth=ta.truth,
                     display=ta.display, klass=ta.klass, events=ta.events, refusals=ta.refusals)
    r = ev.paired_bootstrap(ta, tb, n_boot=50)
    assert r["locomotion"]["nll_known"]["point"] == pytest.approx(0.0)
    assert r["locomotion"]["nll_known"]["ci_low"] == pytest.approx(0.0)
    assert r["locomotion"]["nll_known"]["ci_high"] == pytest.approx(0.0)
    assert r["display_flips_per_hour"]["point"] == pytest.approx(0.0)


def test_paired_bootstrap_point_matches_direct_and_detects_improvement():
    recs, ta, tb = _tables(shift=0.2)
    r = ev.paired_bootstrap(ta, tb, n_boot=200)
    from activity_context.inertia.metrics import nll
    def direct(t):
        keep = t.truth["locomotion"].any(axis=1)
        pk = ev._known("locomotion", t.probs["locomotion"][keep])
        Tk = t.truth["locomotion"][keep][:, :-1]
        return nll(pk, Tk)
    assert r["locomotion"]["nll_known"]["point"] == pytest.approx(direct(tb) - direct(ta), rel=1e-9)
    assert r["locomotion"]["nll_known"]["ci_high"] < 0          # B is clearly better calibrated
    assert r["n_subjects"] == 6


def test_rho_hat_mirrors():
    # HART: a confident walking window favours walk over seated in the decoder's own encoder compat
    lr = ev.hart_loglr({"walking": 0.9, "stationary": 0.05, "running": 0.0, "other_movement": 0.05})
    names = [m[0] for m in ev.DECODER_MODES]
    assert lr[names.index("walk")] > lr[names.index("seated")]
    spec = {"class_order": list(rd.HEAD_ORDERS["locomotion"]),
            "prior": {"stationary": 0.6, "walking": 0.3, "running": 0.1},
            "status": {"stationary": "strong", "walking": "strong", "running": "weak"},
            "merge_into": {}, "covers": {"walking": ["walking", "brisk_walking"]}}
    prep = ev.prepare_inertia_locomotion(spec)
    li = ev.inertia_loglr({"stationary": 0.6, "walking": 0.3, "running": 0.1}, prep)   # q == prior -> r == 1
    np.testing.assert_allclose(li, 0.0, atol=1e-12)
    li = ev.inertia_loglr({"stationary": 0.05, "walking": 0.9, "running": 0.05}, prep)
    assert li[names.index("walk")] > 0 > li[names.index("seated")]
