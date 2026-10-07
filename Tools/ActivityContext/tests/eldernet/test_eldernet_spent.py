"""Spent experiments stay binding when their ledger line is gone (audit G2-3): the frozen-split TEST and the two
external sets refuse to run again without an enumerated rerun reason — before any payload is loaded — and a
permitted rerun is recorded as one. The committed ledger is never touched (every test writes to tmp_path)."""

import json
import os
import shutil

import numpy as np
import pytest

from activity_context.eldernet import integrity_ext as X
from activity_context.eldernet import validate as V
from activity_context.inertia.integrity import RERUN_REASONS, SplitLeakError

EVAL = os.path.normpath(V.EVAL_DIR)
LEDGER = os.path.join(EVAL, "test_ledger.jsonl")


def _payload():
    return {"capture24": {"subject": np.array(["capture24:PX"]), "session": np.array(["s"]), "s": np.array([0.0])}}


@pytest.fixture()
def out_dir(tmp_path):
    shutil.copyfile(os.path.join(EVAL, "calibration.json"), tmp_path / "calibration.json")
    return tmp_path


def _never(*a, **k):
    raise AssertionError("the TEST payload must not be loaded")


def test_the_spent_list_is_the_reviewed_one():
    assert set(X.SPENT_EXPERIMENTS) == {V.EXPERIMENT, *X.EXTERNAL_EXPERIMENTS}
    frozen = X.SPENT_EXPERIMENTS[V.EXPERIMENT]
    assert frozen["ledger"] == "lost" and frozen["opened_unix"] == 1791310368
    assert frozen["bundle_sha256"] == "eldernet-437a38b+cal:16191350862fb8de"
    assert frozen["test_sha256_prefix"] == "677165e7"
    with open(LEDGER) as f:                                       # the guard is needed: the line really is gone
        lines = [json.loads(x) for x in f if x.strip()]
    assert not [e for e in lines if e["experiment"] == V.EXPERIMENT]
    for exp in X.EXTERNAL_EXPERIMENTS:                              # the other two are in the ledger
        spent = X.SPENT_EXPERIMENTS[exp]
        hits = [e for e in lines if e["experiment"] == exp]
        assert spent["ledger"] == "present" and len(hits) == 1
        assert hits[0]["time"] == spent["opened_unix"] and hits[0]["test_sha256"].startswith(spent["test_sha256_prefix"])


@pytest.mark.parametrize("reason,detail", [(None, None), ("because", "x"), ("artifact_lost_identical_rebuild", ""),
                                           (None, "detail without a reason")])
def test_frozen_test_refuses_before_loading(out_dir, monkeypatch, reason, detail):
    monkeypatch.setattr(V, "load_split", _never)
    with pytest.raises(SplitLeakError):
        V.test("/nonexistent-work", str(out_dir), reason, detail)
    assert not (out_dir / "test_ledger.jsonl").exists()


def test_refusal_names_the_spent_opening(out_dir, monkeypatch):
    monkeypatch.setattr(V, "load_split", _never)
    with pytest.raises(SplitLeakError) as e:
        V.test("/nonexistent-work", str(out_dir))
    msg = str(e.value)
    assert "spent" in msg and "2026-10-06T18:12:48Z" in msg and "lost" in msg
    assert all(r in msg for r in RERUN_REASONS)


def test_a_permitted_rerun_is_recorded_as_one(out_dir, monkeypatch):
    monkeypatch.setattr(V, "load_split", lambda work, split, *a: _payload())
    monkeypatch.setattr(V, "evaluate_payload", lambda payload, cal: {"pooled": {"upstream_default": {}}})
    rep = V.test("/w", str(out_dir), "artifact_lost_identical_rebuild", "report lost in the SSD disconnect")
    with open(out_dir / "test_ledger.jsonl") as f:
        (stamp,) = [json.loads(x) for x in f if x.strip()]
    assert stamp["experiment"] == V.EXPERIMENT and stamp["rerun_reason"] == "artifact_lost_identical_rebuild"
    assert stamp["rerun_reason_text"] == RERUN_REASONS["artifact_lost_identical_rebuild"]
    assert "report lost in the SSD disconnect" in stamp["rerun_detail"]
    assert "rerun of spent eldernet_frozen_detection_v1" in stamp["rerun_detail"]
    assert "original ledger line lost" in stamp["rerun_detail"]
    assert rep["spent_before"] == X.SPENT_EXPERIMENTS[V.EXPERIMENT]
    assert json.load(open(out_dir / "VALIDATION_TEST.json"))["integrity"]["rerun_reason"] == stamp["rerun_reason"]


def test_external_sets_are_spent_too(out_dir):
    calls = []

    def loader():
        calls.append(1)
        return {"subject": np.array(["g:1"]), "session": np.array(["s"]), "s": np.array([0.0])}
    for exp in X.EXTERNAL_EXPERIMENTS:
        with pytest.raises(SplitLeakError):
            X.evaluate_external_once(exp, loader, lambda p, cal: {}, str(out_dir), "r.json")
    assert not calls
    rep = X.evaluate_external_once(X.EXTERNAL_EXPERIMENTS[0], loader, lambda p, cal: {}, str(out_dir), "r.json",
                                   rerun_reason="evaluator_bug_fix", rerun_detail="metric fixed")
    assert calls == [1] and rep["integrity"]["rerun_reason"] == "evaluator_bug_fix"
    assert "rerun of spent " + X.EXTERNAL_EXPERIMENTS[0] in rep["integrity"]["rerun_detail"]


def test_an_unlisted_experiment_is_unaffected():
    assert X.spent_rerun_detail("some_new_experiment_v1", None, None) is None
    assert X.spent_rerun_detail("some_new_experiment_v1", "evaluator_bug_fix", "d") == "d"
