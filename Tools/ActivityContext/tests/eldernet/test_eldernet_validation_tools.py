"""Validation tooling: crosswalk truth, run splitting, dataset windows, VAL-only fit and the once-only TEST vault."""

import json
import os

import numpy as np
import pytest

from activity_context.eldernet.datasets import (GAIT, MASK, NON_GAIT, RUNNING, recording_windows, split_runs,
                                                truth_of_mask)

from ._helpers import synth_g

LOCO = ("stationary", "walking", "brisk_walking", "running", "stairs", "cycling", "vehicle_motion", "other")
B = {c: 1 << i for i, c in enumerate(LOCO)}


def test_truth_categories_from_locomotion_masks():
    assert truth_of_mask(0) == MASK
    assert truth_of_mask(B["walking"] | B["brisk_walking"]) == GAIT
    assert truth_of_mask(B["stairs"]) == GAIT
    assert truth_of_mask(B["stationary"]) == NON_GAIT and truth_of_mask(B["cycling"]) == NON_GAIT
    assert truth_of_mask(B["vehicle_motion"]) == NON_GAIT
    assert truth_of_mask(B["running"]) == RUNNING
    assert truth_of_mask(B["walking"] | B["stationary"]) == MASK          # mixed set -> ambiguous
    assert truth_of_mask(B["other"]) == MASK


def test_split_runs_on_gaps_resets_and_repaired_samples():
    t = np.array([0, .01, .02, .5, .51, .52, .53, .54, .53, .54])
    bad = np.zeros(len(t), bool)
    bad[5] = True
    assert split_runs(t, 0.015) == [slice(0, 3), slice(3, 8), slice(8, 10)]
    assert split_runs(t, 0.015, bad) == [slice(0, 3), slice(3, 5), slice(6, 8), slice(8, 10)]


def _rec(labels_per_s, fs=100.0):
    from activity_context.inertia.datasets import Recording
    n = len(labels_per_s)
    acc = np.concatenate([synth_g(1, "walk" if lab == "walk" else "still", seed=i) for i, lab in enumerate(labels_per_s)])
    names = sorted(set(labels_per_s))
    codes = np.repeat([names.index(lab) for lab in labels_per_s], int(fs)).astype(np.int32)
    t = 100.0 + np.arange(n * int(fs)) / fs
    return Recording(dataset="synthetic", subject="synthetic:1", session="synthetic:1:a", placement="wrist",
                     device="x", wrist_side="unknown", axis_frame="x", source_hz=fs, t=t, xyz_g=acc, labels=codes,
                     label_names=names, uniform=True)


def test_recording_windows_truth_purity_and_grid():
    rec = _rec(["sit"] * 20 + ["walk"] * 20)
    tt = np.array([GAIT if n == "walk" else NON_GAIT for n in rec.label_names], np.int8)
    ws = recording_windows(rec, tt, hop_s=5)
    assert ws.data.shape[1:] == (300, 3)
    assert ws.s.tolist() == [100.0 + 5 * k for k in range(7)]
    assert ws.truth.tolist() == [NON_GAIT, NON_GAIT, NON_GAIT, MASK, GAIT, GAIT, GAIT]   # 15-25 s is half/half
    assert ws.label[0] == "sit" and ws.label[-1] == "walk"


def _write_parts(work, dataset, split, subjects, rng, shift):
    from activity_context.eldernet.extract import part_path
    for s in subjects:
        n = 400
        y = rng.random(n) < 0.3
        z = 3.0 * (np.where(y, 2.0, -2.0) * shift + rng.normal(0, 2.0, n))      # log-odds x3: over-confident
        cols = {"s": np.arange(n) * 5.0, "e": np.arange(n) * 5.0 + 10, "truth": np.where(y, GAIT, NON_GAIT).astype(np.int8),
                "prefiltered": np.zeros(n, bool), "logit_diff": z, "gait_prob": 1 / (1 + np.exp(-z)),
                "is_gait": z >= 0, "finite": np.ones(n, bool), "subject": np.array([f"{dataset}:{s}"] * n),
                "session": np.array([f"{dataset}:{s}:a"] * n), "purity": np.ones(n)}
        p = part_path(work, dataset, split, s)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        np.savez(p, **cols)


def test_fit_on_val_then_test_once(tmp_path, monkeypatch):
    pytest.importorskip("scipy")
    from activity_context.eldernet import validate as V
    from activity_context.inertia.integrity import SplitLeakError
    rng = np.random.default_rng(0)
    work, out = str(tmp_path / "work"), str(tmp_path / "eval")
    subj = {"val": [f"v{i}" for i in range(6)], "test": [f"t{i}" for i in range(6)]}
    for split, ss in subj.items():
        _write_parts(work, "toyds", split, ss, rng, shift=1.0)
    monkeypatch.setattr(V, "DATASETS", ("toyds",))
    monkeypatch.setattr("activity_context.eldernet.extract.split_subjects", lambda d, s: subj[s])
    monkeypatch.setattr(V, "load_split", lambda w, s, datasets=("toyds",): {
        "toyds": __import__("activity_context.eldernet.extract", fromlist=["x"]).load_split_parts(w, "toyds", s, subj[s])})
    cal = V.fit(work, out)
    assert cal["gait_prob"]["fit"] == "val" and cal["fit"]["split"] == "val"
    assert 2.0 < cal["gait_prob"]["T"] < 4.0                                # recovers the x3 over-confidence
    rep = V.test(work, out)
    assert rep["integrity"]["n_test_evaluations"] == 1
    assert 0.0 <= rep["pooled"]["upstream_default"]["f1"] <= 1.0
    with pytest.raises(SplitLeakError):
        V.test(work, out)                                                   # TEST once
    with open(os.path.join(out, "test_ledger.jsonl")) as f:
        assert len(f.read().strip().splitlines()) == 1
    json.load(open(os.path.join(out, "VALIDATION_TEST.json")))
