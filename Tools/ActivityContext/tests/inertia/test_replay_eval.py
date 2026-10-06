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


def test_replay_test_decode_is_ledgered(monkeypatch, tmp_path):
    """G-16: the replay's TEST decode goes through a TestVault with its own ledger: the test recordings are
    loaded only inside the vault, and a completed decode cannot be silently repeated."""
    from activity_context.inertia.integrity import SplitLeakError
    loads = []
    recs = [_rec("r1", "1605", 30, "walking"), _rec("r2", "1607", 30, "stationary")]

    def fake_load(path):
        loads.append(path)
        return recs
    monkeypatch.setattr(rd, "replay_root", lambda: str(tmp_path))
    monkeypatch.setattr(rx, "load_recordings", fake_load)
    arms = {"A0s": object(), "A0": object(), "A1": object()}
    monkeypatch.setattr(ev, "baseline_tables", lambda dataset, split, r, jobs=4: (dict(arms), {"split": split}))
    monkeypatch.setattr(ev, "val_operating_points", lambda tb, h: {})
    monkeypatch.setattr(ev, "score_arm", lambda tb, r, ops=None, with_events=False: {"scored": True})
    monkeypatch.setattr(ev, "paired_bootstrap", lambda a, b, ops=None, n_boot=1000: {"diff": 0.0})
    monkeypatch.setattr(ev, "xctest_fingerprint", lambda bundle=None: "e" * 64)
    out = tmp_path / "out"
    r = ev.run_baseline("wisdm", str(out), ledger_dir=str(tmp_path))
    assert r["integrity"]["experiment"] == "replay-baseline/wisdm" and r["integrity"]["bundle_sha256"] == "e" * 64
    assert any(p.endswith("recordings_wisdm_test.npz") for p in loads)
    n_test_loads = sum(p.endswith("_test.npz") for p in loads)
    with pytest.raises(SplitLeakError):
        ev.run_baseline("wisdm", str(out), ledger_dir=str(tmp_path))
    assert sum(p.endswith("_test.npz") for p in loads) == n_test_loads        # refused before loading test
    r2 = ev.run_baseline("wisdm", str(out), ledger_dir=str(tmp_path), rerun_reason="evaluator_bug_fix",
                         rerun_detail="unit test")
    assert r2["integrity"]["n_test_evaluations"] == 2
    lines = (tmp_path / ev.REPLAY_LEDGER).read_text().strip().splitlines()
    assert len(lines) == 2


def test_replay_finals_are_preregistered():
    from activity_context.inertia.experiments import REPLAY_DECLARED
    assert "replay-final/wisdm/shadow-primary-hc" in REPLAY_DECLARED
    assert "replay-final/capture24/shadow-primary-art" in REPLAY_DECLARED and "replay-baseline/capture24" in REPLAY_DECLARED
