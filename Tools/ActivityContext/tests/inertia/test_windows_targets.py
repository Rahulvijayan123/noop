"""Windowing (purity, uid, cap, gap handling) and transition-event targets (positive / negative / MASK)."""

import numpy as np
import pandas as pd
import pytest

from activity_context.inertia import HEAD_CLASS_ORDERS
from activity_context.inertia import transition_targets as TT
from activity_context.inertia.datasets import Recording
from activity_context.inertia.mappings import load_mappings
from activity_context.inertia.targets import class_targets, intensity_targets
from activity_context.inertia.windows import SPECS, _cap, window_recording, window_uid

EV = list(HEAD_CLASS_ORDERS["transition"])


@pytest.fixture(scope="module")
def cw():
    return load_mappings()


def _rec(labels_per_s, fs=50.0, dataset="mhealth", names=("1", "2", "4", "0"), gap_at=None):
    codes = np.repeat(np.array(labels_per_s, np.int32), int(fs))
    n = len(codes)
    t = np.arange(n) / fs
    if gap_at is not None:
        t[int(gap_at * fs):] += 5.0
    rng = np.random.default_rng(0)
    x = np.column_stack([rng.normal(0, 0.01, n), rng.normal(0, 0.01, n), 1 + rng.normal(0, 0.01, n)])
    return Recording(dataset=dataset, subject=f"{dataset}:subject6", session=f"{dataset}:subject6", placement="wrist_right",
                     device="synthetic", wrist_side="right", axis_frame="x", source_hz=fs, t=t, xyz_g=x, labels=codes,
                     label_names=list(names))


def test_windows_purity_and_uid(cw):
    rec = _rec([0] * 100 + [2] * 100)                 # 100 s standing then 100 s walking
    out = window_recording(rec, cw, [SPECS["w30"]], "test")["w30"]
    assert out["X"].shape[1:] == (3, 600) and out["X"].dtype == np.float32
    labels = [m["label"] for m in out["meta"]]
    assert set(labels) <= {"1", "4"} and all(m["purity"] >= 0.9 for m in out["meta"])
    m0 = out["meta"][0]
    assert m0["uid"] == window_uid("mhealth", rec.session, m0["t0"], 30) and m0["t0"] == pytest.approx(1.0)
    assert abs(np.median(np.linalg.norm(out["X"][0], axis=0)) - 1.0) < 0.05     # gravity kept, in g
    again = window_recording(rec, cw, [SPECS["w30"]], "test")["w30"]
    assert np.array_equal(out["X"], again["X"])                                   # deterministic


def test_gap_splits_runs_no_window_bridges(cw):
    rec = _rec([0] * 80, gap_at=40.0)
    out = window_recording(rec, cw, [SPECS["w30"]], "test")["w30"]
    for m in out["meta"]:
        assert m["t1"] <= 40.0 - 1.0 + 1e-6 or m["t0"] >= 45.0 + 1.0 - 1e-6


def test_null_label_windows_dropped(cw):
    rec = _rec([3] * 100)                               # all null ('0')
    assert window_recording(rec, cw, [SPECS["w30"]], "test")["w30"]["meta"] == []


def test_capture24_train_cap():
    meta = [{"uid": f"u{i}", "label": "a" if i < 1500 else "b"} for i in range(1600)]
    keep = _cap(meta, 1000)
    labs = [meta[i]["label"] for i in keep]
    assert labs.count("a") == 1000 and labs.count("b") == 100 and list(keep) == sorted(keep)
    assert np.array_equal(keep, _cap(meta, 1000))


def _segs(spec, fs=10.0):
    """spec: [(duration_s, state_or_None)] -> LabelSegments on one clock."""
    states = [s for _, s in spec]
    codes = np.concatenate([np.full(int(d * fs), i) for i, (d, _) in enumerate(spec)])
    t = np.arange(len(codes)) / fs
    return TT.label_segments(t, codes, fs, states), states


def test_direct_switch_event_positive_and_guard():
    segs, states = _segs([(60, "sit"), (60, "stand")])
    rule = {"mode": "direct_switch", "max_null_s": 1.0, "event_intervals_s": {"default": [-2.0, 2.0]}}
    pairs = {("sit", "stand"): ["sit_to_stand_like"]}
    b = TT.derive_boundaries(segs, rule, pairs, 30)
    assert [x.events for x in b if x.events] == [("sit_to_stand_like",)]
    w0 = np.array([45.0, 58.5, 5.0, 75.0])
    y = TT.window_targets(w0, w0 + 30, b, segs, none_ok=np.array([True, True]))
    assert list(y[0]) == [1 if e == "sit_to_stand_like" else 0 for e in EV]       # event inside [w0+1, w1-1]
    assert (y[1] == -1).all()                                                        # event interval cut by the edge
    assert (y[2] == -1).all()                                                        # < 5 s from the run start
    assert (y[3] == 0).all()                                                         # interior negative


def test_null_gap_event_and_negatives_only():
    segs, _ = _segs([(60, "stand"), (8, None), (60, "sit")])
    rule = {"mode": "null_gap", "max_null_s": 10.0, "allowed_pairs": [["stand", "sit"]]}
    pairs = {("stand", "sit"): ["stand_to_sit_like"]}
    b = TT.derive_boundaries(segs, rule, pairs, 30)
    w0 = np.array([50.0, 20.0])
    y = TT.window_targets(w0, w0 + 30, b, segs, np.array([True, True, True]))
    assert y[0, EV.index("stand_to_sit_like")] == 1 and y[0].sum() == 1
    assert (y[1] == 0).all()
    b2 = TT.derive_boundaries(segs, {"mode": "negatives_only"}, pairs, 30)          # e.g. WISDM / MHEALTH
    y2 = TT.window_targets(w0, w0 + 30, b2, segs, np.array([True, True, True]))
    assert (y2[0] == -1).all() and (y2[1] == 0).all()


def test_label_without_none_row_never_negative():
    segs, _ = _segs([(120, "other")])
    b = TT.derive_boundaries(segs, {"mode": "direct_switch"}, {}, 30)
    y = TT.window_targets(np.array([40.0]), np.array([70.0]), b, segs, np.array([False]))
    assert (y == -1).all()


def test_class_targets_mask_not_unknown(cw):
    meta = pd.DataFrame([{"dataset": "wisdm2019_watch", "label": "A", "kind": "cls", "pure": True},
                         {"dataset": "wisdm2019_watch", "label": "D", "kind": "cls", "pure": True},
                         {"dataset": "wisdm2019_watch", "label": "D", "kind": "trn", "pure": False},
                         {"dataset": "gotov", "label": "standing", "kind": "cls", "pure": True}])
    post = class_targets(meta, cw, "posture")
    assert list(post) == [0, 1 << HEAD_CLASS_ORDERS["posture"].index("seated_likely"), 0, 0]
    assert np.isnan(intensity_targets(meta, cw)).all()
    held = class_targets(pd.DataFrame([{"dataset": "pamap2", "label": "24", "kind": "cls", "pure": True}]), cw,
                         "arm_behavior", ood_holdout=True)
    assert list(held) == [0]
