"""OOD scores (held-out activity scores higher, threshold from val, parity with bundle_math) and the
integrity guards (evaluate_once ledger, head inputs, calibration provenance)."""

import json

import numpy as np
import pytest

from activity_context.inertia import bundle_math as bm
from activity_context.inertia import metrics as M
from activity_context.inertia import ood as O
from activity_context.inertia.integrity import (SplitLeakError, SplitView, TestVault, assert_calibration_provenance,
                                                assert_head_inputs)


@pytest.fixture(scope="module")
def ood_data():
    rng = np.random.default_rng(0)
    centers = rng.standard_normal((4, 16)) * 3
    keys = np.repeat([f"d|{i}" for i in range(4)], 300)
    emb = centers[np.repeat(np.arange(4), 300)] + rng.standard_normal((1200, 16))
    uids = np.array([f"u{i}" for i in range(1200)])
    val = centers[rng.integers(0, 4, 400)] + rng.standard_normal((400, 16))
    novel = rng.standard_normal((200, 16)) * 3 + 8.0
    return O.OODModel(emb, keys, uids, n_ref=512), val, novel


def test_heldout_activity_scores_higher(ood_data):
    model, val, novel = ood_data
    for meth in ("maha_min", "maha_global", "knn"):
        s_id, s_ood = model.score(meth, val), model.score(meth, novel)
        assert M.binary_auc(s_id, s_ood) > 0.95, meth


def test_threshold_is_val_quantile_and_bundle_parity(ood_data):
    model, val, _ = ood_data
    s = model.score("knn", val, k=10)
    thr = O.fit_threshold(s)
    assert thr == float(np.quantile(s, 0.95, method="higher"))
    a = model.arrays("knn")
    assert a["reference"].dtype == np.float16
    z = bm.standardize(val, a["mu"], a["sigma"])
    assert np.array_equal(bm.ood_knn(z, a["reference"], 10), s)
    am = model.arrays("maha_min")
    assert np.allclose(bm.ood_maha_min(bm.standardize(val, am["mu"], am["sigma"]), am["class_means"], am["precision"]),
                       model.score("maha_min", val))


def test_select_method_uses_val_only():
    sel = O.select_method({"a": np.zeros(10), "b": np.zeros(10)}, {"a": np.ones(5), "b": np.zeros(5)}, ["a", "b"])
    assert sel["chosen"] == "a" and "VAL" in sel["rule"]


def _vault(ledger, calls):
    def load():
        calls.append("load")
        return {"x": 1, "uids": np.array(["u1", "u2"])}
    return TestVault(load, lambda p: [p["uids"]], ledger)


def test_evaluate_once_refuses_silent_rerun(tmp_path):
    ledger = str(tmp_path / "ledger.jsonl")
    calls = []
    v = _vault(ledger, calls)
    rep = v.evaluate_once("exp-a", "b" * 64, lambda p: {"ok": p["x"]}, declared=["exp-a"])
    assert rep["integrity"]["n_test_evaluations"] == 1 and calls == ["load"]
    with pytest.raises(SplitLeakError):
        v.evaluate_once("exp-a", "b" * 64, lambda p: {}, declared=["exp-a"])
    with pytest.raises(SplitLeakError):
        v.evaluate_once("exp-a", "c" * 64, lambda p: {}, declared=["exp-a"])
    with pytest.raises(SplitLeakError):
        v.evaluate_once("exp-undeclared", "d" * 64, lambda p: {}, declared=["exp-a"])
    with pytest.raises(SplitLeakError):                     # undeclared stays refused even with a reason
        v.evaluate_once("exp-undeclared", "d" * 64, lambda p: {}, declared=["exp-a"],
                        rerun_reason="evaluator_bug_fix", rerun_detail="x")
    assert calls == ["load"]                                # refusals never materialise the test split
    with pytest.raises(SplitLeakError):                     # free text is not a reason
        v.evaluate_once("exp-a", "c" * 64, lambda p: {}, declared=["exp-a"], rerun_reason="bug fix")
    with pytest.raises(SplitLeakError):                     # a reason needs detail
        v.evaluate_once("exp-a", "c" * 64, lambda p: {}, declared=["exp-a"], rerun_reason="post_audit_rule_change")
    rep2 = v.evaluate_once("exp-a", "c" * 64, lambda p: {}, declared=["exp-a"], rerun_reason="post_audit_rule_change",
                           rerun_detail="G-4/G-5 rules changed after the audit")
    assert rep2["integrity"]["n_test_evaluations"] == 2
    assert rep2["integrity"]["rerun_reason"] == "post_audit_rule_change"
    assert rep2["integrity"]["rerun_detail"].startswith("G-4")
    lines = [json.loads(x) for x in open(ledger).read().strip().splitlines()]
    assert len(lines) == 2 and lines[1]["rerun_reason"] == "post_audit_rule_change"


def test_vault_takes_a_loader_not_arrays(tmp_path):
    with pytest.raises(SplitLeakError):
        TestVault({"test": np.zeros(3)}, [np.array(["u"])], str(tmp_path / "l.jsonl"))


def test_vault_runs_prechecks_on_the_test_hash_before_the_evaluator(tmp_path):
    calls = []
    v = _vault(str(tmp_path / "l.jsonl"), calls)
    seen = {}

    def before(sha):
        seen["sha"] = sha
        raise SplitLeakError("calibration fit on test")
    with pytest.raises(SplitLeakError):
        v.evaluate_once("exp-a", "b" * 64, lambda p: calls.append("eval") or {}, declared=["exp-a"], before=before)
    assert "eval" not in calls and len(seen["sha"]) == 64 and not (tmp_path / "l.jsonl").exists()


def test_split_view_never_wraps_test():
    with pytest.raises(SplitLeakError):
        SplitView("test", np.zeros((1, 2)), np.array(["s"]), np.array(["u"]))


def test_head_inputs_exactly_embedding():
    assert_head_inputs(["embedding"])
    for bad in (["embedding", "hr"], ["hart_probs"], []):
        with pytest.raises(SplitLeakError):
            assert_head_inputs(bad)


def test_calibration_provenance():
    cal = {"heads": {"posture": {"method": "temperature", "fit": {"split": "val", "val_split_sha256": "v"}}}}
    assert_calibration_provenance(cal, "t")
    with pytest.raises(SplitLeakError):
        assert_calibration_provenance(cal, "v")
    with pytest.raises(SplitLeakError):
        assert_calibration_provenance({"heads": {"posture": {"method": "temperature", "fit": {"split": "test"}}}}, "t")


def test_fast_mahalanobis_equals_bundle_math():
    rng = np.random.default_rng(3)
    z = rng.standard_normal((50, 9))
    A = rng.standard_normal((9, 9))
    P = A @ A.T + np.eye(9)
    M_ = rng.standard_normal((6, 9))
    assert np.allclose(O.maha_fast(z, M_, P), bm.ood_maha_min(z, M_, P), rtol=1e-9, atol=1e-9)
    assert np.allclose(O.maha_fast(z, M_[:1], P), bm.ood_maha_global(z, M_[0], P), rtol=1e-9, atol=1e-9)
