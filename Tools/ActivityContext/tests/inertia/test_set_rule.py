"""Set targets (abstention.SET_RULE, audit G2 D-1): single-label evidence for set members, families scored as
one class, merges only specific -> general, per-dataset test reuse (G2 D-2)."""

import json
import os

import numpy as np
import pytest

from activity_context.inertia import abstention as A
from activity_context.inertia.integrity import SplitLeakError, TestVault, per_dataset_reuse

LOCO = ["stationary", "walking", "brisk_walking", "running", "stairs", "cycling", "vehicle_motion", "other"]
ST, WK, BR = 0, 1, 2


def _rows(n, truth_classes, pred, q, subj_prefix, n_subj, K=3):
    """n windows with truth set ``truth_classes``, argmax ``pred`` at probability q, the rest spread evenly."""
    P = np.full((n, K), (1.0 - q) / (K - 1))
    P[:, pred] = q
    T = np.zeros((n, K), bool)
    T[:, list(truth_classes)] = True
    S = np.array([f"{subj_prefix}{i % n_subj}" for i in range(n)])
    return P, T, S


def _stack(*parts):
    return tuple(np.concatenate([p[i] for p in parts]) for i in range(3))


def brisk_case():
    """Synthetic reproduction of ncsa-primary-hc VAL: brisk_walking is 'learned' only on pace-unknown walking.

    * 1500 pace-unknown walking windows {walking, brisk_walking} (30 subjects): argmax brisk_walking, q .9;
    * 99 single-label brisk windows (6 subjects): 18 argmax brisk q .9, 50 argmax brisk q .5, 31 argmax walking q .6;
    * 204 single-label walking windows (8 subjects): 160 argmax walking q .9, 9 argmax brisk q .9, 35 argmax
      brisk q .5;
    * 3000 stationary windows (40 subjects): argmax stationary, q .97.
    """
    return _stack(_rows(1500, (WK, BR), BR, 0.90, "c", 30),
                  _rows(18, (BR,), BR, 0.90, "g", 6), _rows(50, (BR,), BR, 0.50, "g", 6),
                  _rows(31, (BR,), WK, 0.60, "g", 6),
                  _rows(160, (WK,), WK, 0.90, "h", 8), _rows(9, (WK,), BR, 0.90, "h", 8),
                  _rows(35, (WK,), BR, 0.50, "h", 8),
                  _rows(3000, (ST,), ST, 0.97, "s", 40))


def test_unambiguous_mask():
    T = np.array([[1, 0, 0], [0, 1, 1], [0, 1, 0], [1, 1, 1], [0, 0, 1]], bool)
    assert A.unambiguous(T, 1).tolist() == [True, False, True, False, True]
    assert A.unambiguous(T, 0).tolist() == [True, True, True, False, True]
    assert A.unambiguous(np.zeros((0, 3), bool), 0).shape == (0,)


def test_brisk_strong_only_through_set_targets_is_abstained():
    P, T, S = brisk_case()
    old = A.select_operating_point(P, T, S, BR, True, set_rule=False)
    new = A.select_operating_point(P, T, S, BR, True)
    assert old["status"] == "strong"                       # the flaw: set windows count as correct for brisk
    assert new["status"] == "abstain"                      # single-label brisk precision 18/27 at tau > .5
    assert new["scoring"]["n_set_windows_excluded"] == 1500 and new["n_val_class"] == 99
    walk = A.select_operating_point(P, T, S, WK, True)
    assert walk["status"] in ("weak", "strong") and walk["n_val_class"] == 204   # single-label walking evidence
    fam = A.family_operating_points(P, T, S, ["stationary", "walking", "brisk_walking"], [True, True, True])
    assert list(fam) == ["walking+brisk_walking"]
    f = fam["walking+brisk_walking"]
    assert f["status"] == "strong" and f["members"] == ["walking", "brisk_walking"]
    assert f["n_windows_with_exactly_this_set"] == 1500
    # the decoder's merge goes brisk -> walking (specific -> general), never walking -> brisk
    st = {"stationary": "strong", "walking": walk["status"], "brisk_walking": new["status"]}
    assert A.merge_partners(st, ["stationary", "walking", "brisk_walking"], "locomotion") == {"brisk_walking": "walking"}


def test_non_member_classes_are_unchanged():
    P, T, S = brisk_case()
    a = A.select_operating_point(P, T, S, ST, True)
    b = A.select_operating_point(P, T, S, ST, True, set_rule=False)
    assert (a["status"], a["tau"]) == (b["status"], b["tau"]) and a["scoring"]["n_set_windows_excluded"] == 0


def test_gate_uses_single_label_evidence_pooled_and_per_dataset():
    """TEST as in ncsa-primary-hc: Capture-24 brisk acceptances are pace-unknown walking (+ a few wrong single-label
    windows); the one fast GOTOV walker is called walking."""
    c24 = _stack(_rows(2000, (WK, BR), BR, 0.9, "c", 20), _rows(35, (ST,), BR, 0.9, "c", 20))
    gt = _rows(19, (BR,), WK, 0.9, "g", 1)
    P, T, _ = _stack(c24, gt)
    ds = np.array(["capture24"] * 2035 + ["gotov"] * 19)
    old = A.check_gate(P, T, BR, 0.8, set_rule=False)
    new = A.check_gate(P, T, BR, 0.8)
    assert old["level"] == "strong" and old["n_acc"] == 2035          # 2000 set windows "correct"
    assert (new["n_acc"], new["tp"], new["level"], new["n_set_windows_excluded"]) == (35, 0, "abstain", 2000)
    per = {d: A.check_gate(P[ds == d], T[ds == d], BR, 0.8, dataset_level=True) for d in ("capture24", "gotov")}
    per_old = {d: A.check_gate(P[ds == d], T[ds == d], BR, 0.8, dataset_level=True, set_rule=False)
               for d in ("capture24", "gotov")}
    assert per["capture24"]["decisive"] and per["capture24"]["level"] == "abstain"     # single-label evidence
    assert per_old["capture24"]["level"] == "strong"
    assert per["gotov"]["n_acc"] == 0 and not per["gotov"]["decisive"]
    assert A.final_status("strong", old, per_old)[0] == "strong"       # the old rule kept it strong
    final, reasons = A.final_status("strong", new, per)
    assert final == "abstain" and reasons[0].startswith("pooled")
    # per-dataset demotion uses single-label evidence on its own (pooled gate passing)
    final, reasons = A.final_status("strong", old, per)
    assert final == "abstain" and reasons == [r for r in reasons if r.startswith("capture24")] and reasons


def test_family_view_partial_overlap_is_excluded():
    T = np.array([[0, 1, 1], [1, 1, 1], [0, 1, 0], [1, 0, 0]], bool)    # {w,b}, {s,w,b}, {w}, {s}
    P = np.array([[0.1, 0.3, 0.6], [0.1, 0.3, 0.6], [0.2, 0.7, 0.1], [0.9, 0.05, 0.05]])
    Pf, Tf = A.family_view(P, T, (WK, BR))
    assert np.allclose(Pf[:, 0], [0.9, 0.9, 0.8, 0.1]) and np.allclose(Pf[:, 1], P[:, 0])
    assert A.unambiguous(Tf, 0).tolist() == [True, False, True, True]
    g = A.check_gate(Pf, Tf, 0, 0.5)
    assert (g["n_acc"], g["tp"]) == (2, 2)
    assert A.observed_families(T) == [(0, 1, 2), (1, 2)]
    assert A.family_key((1, 2), ["stationary", "walking", "brisk_walking"]) == "walking+brisk_walking"


def test_merges_only_specific_to_general():
    K = len(LOCO)
    sym = [[0] * K for _ in range(K)]
    base = {c: "abstain" for c in LOCO}
    # brisk abstains, walking live -> brisk merges into walking
    assert A.merge_partners(dict(base, walking="weak"), LOCO, "locomotion", sym) == {
        "brisk_walking": "walking", "stairs": "walking"}
    # walking abstains, brisk / stairs live -> walking is NOT merged into either (was walking -> brisk / stairs)
    st = dict(base, brisk_walking="strong", stairs="weak")
    assert A.merge_partners(st, LOCO, "locomotion", sym) == {}
    assert A.merge_partners(st, LOCO, "locomotion", sym, directed=False) == {"walking": "brisk_walking"}
    assert "walking" not in A.MERGE_COMPAT["locomotion"]
    # posture / arm pairs have no specificity order and stay symmetric
    assert A.MERGE_COMPAT["arm_behavior"] == {"quiet": ("desk_like",), "desk_like": ("quiet",)}
    assert A.MERGE_COMPAT["posture"]["upright_stationary"] == ("postural_transition",)


def test_schema_refuses_general_into_specific_merge():
    from activity_context.inertia.bundle_schema import BundleError, validate_merge
    sup = ["stationary", "walking", "brisk_walking"]
    validate_merge("locomotion", {"brisk_walking": "walking"}, {"stationary": "strong", "walking": "weak",
                                                                "brisk_walking": "abstain"}, sup)
    with pytest.raises(BundleError):
        validate_merge("locomotion", {"walking": "brisk_walking"}, {"stationary": "strong", "walking": "abstain",
                                                                    "brisk_walking": "strong"}, sup)


def test_family_gate_only_demotes():
    P, T, S = brisk_case()
    ds = np.array(["x"] * len(P))
    g = A.family_gates(P, T, (WK, BR), 0.8, "weak", ds)
    assert g["final_status"] == "weak"                    # never promoted above the VAL family status
    assert A.family_gates(P, T, (WK, BR), 0.8, "abstain", ds)["test"] is None


def test_vault_counts_reuse_per_dataset_split(tmp_path):
    ledger = str(tmp_path / "ledger.jsonl")
    hist = {"old-6": {"a": "sa", "b": "sb"}}
    with open(ledger, "w") as fh:
        fh.write(json.dumps({"experiment": "old-6", "bundle_sha256": "x", "test_sha256": "t6"}) + "\n")

    def vault(ids):
        return TestVault(lambda: {"ids": np.array(ids)}, lambda p: [p["ids"]], ledger)

    rep = vault(["1", "2", "3"]).evaluate_once("new-8", "b1", lambda p: {"n": len(p["ids"])}, ["new-8"],
                                              dataset_splits={"a": "sa", "b": "sb", "c": "sc"},
                                              history=lambda e: hist.get(e["experiment"], {}))
    st = rep["integrity"]
    assert st["n_evaluations_on_this_test_split"] == 1          # a new combined split ...
    assert st["n_evaluations_per_dataset_split"] == {"a": 2, "b": 2, "c": 1}   # ... re-opens a and b
    with open(ledger) as fh:
        rows = [json.loads(x) for x in fh]
    assert rows[-1]["per_dataset_split_sha256"] == {"a": "sa", "b": "sb", "c": "sc"}
    assert per_dataset_reuse(rows, lambda e: hist.get(e["experiment"], {})) == {("a", "sa"): 2, ("b", "sb"): 2,
                                                                               ("c", "sc"): 1}
    with pytest.raises(SplitLeakError):
        vault(["1"]).evaluate_once("new-8", "b2", lambda p: {}, ["new-8"])
