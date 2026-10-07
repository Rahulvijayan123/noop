"""HART test ledger (audit G2 E-2), repair sensitivity helpers (E-1) and bootstrap CIs (E-3). No torch."""

import json
import os

import numpy as np
import pytest

from activity_context import evaluate as E
from activity_context import hart_wisdm_eval as H
from activity_context.inertia.integrity import SplitLeakError

FIXTURES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")


def _npz(path, n=60, seed=0):
    rng = np.random.default_rng(seed)
    subj = np.repeat(np.array(H.TEST_SUBJECTS[:3]), n // 3)
    letters = np.array(["A", "D", "F"] * (n // 3))
    onto = np.array([{"A": "walking", "D": "stationary", "F": "stationary"}[c] for c in letters])
    x = rng.standard_normal((n, 120, 6)).astype(np.float32) * 0.01
    x[:, :, 2] += 1.0
    np.savez_compressed(path, X=x, y_ontology=onto, letters=letters, subjects=subj,
                        sessions=np.arange(n) // 10, y=np.zeros(n, np.int64),
                        n_repaired=(np.arange(n) % 7 == 0).astype(np.int64),
                        n_repaired_pm05s=(np.arange(n) % 5 == 0).astype(np.int64) | (np.arange(n) % 7 == 0))
    return path


def test_macro_f1_counts_abstentions_as_misses():
    y = np.array(["walking"] * 4 + ["stationary"] * 4)
    pred = np.array(["walking", "walking", "unknown", "unknown", "stationary"] * 1 + ["stationary"] * 3)
    m = H.macro_f1_labels(y, pred)
    # walking P 1 R .5 F1 2/3; stationary P 1 R 1 F1 1; running / other F1 0
    assert m == pytest.approx((2 / 3 + 1.0) / 4)


def test_bootstrap_block_pairs_the_difference():
    rng = np.random.default_rng(1)
    y = rng.choice(["walking", "stationary", "running", "other_movement"], 400)
    subj = np.repeat(np.arange(8), 50)
    v0 = np.where(rng.random(400) < 0.6, y, "unknown")
    v1 = np.where(rng.random(400) < 0.8, y, "unknown")
    b = H.bootstrap_block(y, {"v0": v0, "v1": v1}, subj, n_boot=200)
    d = b["v1_minus_v0"]["macro_f1"]
    assert d["point"] == pytest.approx(H.macro_f1_labels(y, v1) - H.macro_f1_labels(y, v0))
    assert d["ci_low"] < d["point"] < d["ci_high"] and d["warning"]          # 8 subjects: under-covers
    assert b["v1"]["coverage"]["point"] == pytest.approx(float(np.mean(v1 != "unknown")))


def test_historical_entries_then_a_rerun_needs_a_reason(tmp_path):
    ledger = str(tmp_path / "hart" / "test_ledger.jsonl")
    v0 = _npz(str(tmp_path / "v0.npz"), n=90, seed=1)              # v0 loader: other windows, other identity
    v1 = _npz(str(tmp_path / "v1.npz"), seed=2)
    ent = H.historical_entries(v0, v1, "a" * 64, "b" * 64)
    assert H.record_historical(ledger, ent) == 2
    rows = [json.loads(x) for x in open(ledger)]
    assert all(r["historical"] and r["recorded_after_the_fact"] == H.HISTORICAL_NOTE for r in rows)
    assert all(r["experiment"] == H.HART_EXPERIMENT and r["per_dataset_split_sha256"] == H.dataset_splits()
               for r in rows)
    with pytest.raises(SystemExit):
        H.record_historical(ledger, ent)                       # recorded once, into an empty ledger only
    vault = H._vault(v1, ledger)
    with pytest.raises(SplitLeakError):                        # the test split was opened before
        vault.evaluate_once(H.HART_EXPERIMENT, "v0:x+v1:y", lambda p: {}, H.HART_DECLARED,
                            dataset_splits=H.dataset_splits(), history=H._ledger_history)
    rep = H._vault(v1, ledger).evaluate_once(H.HART_EXPERIMENT, "v0:x+v1:y", lambda p: {"ok": p["eval_npz"]},
                                             H.HART_DECLARED, "post_audit_rule_change", "repair sensitivity",
                                             dataset_splits=H.dataset_splits(), history=H._ledger_history)
    st = rep["integrity"]
    assert rep["ok"] == v1 and st["n_test_evaluations"] == 2                  # same windows as historical #2
    assert st["n_evaluations_per_dataset_split"] == {"wisdm2019_watch": 3}    # every opening of the subjects
    assert st["rerun_reason"] == "post_audit_rule_change"


def test_dataset_split_is_the_inertia_wisdm_split():
    from activity_context.inertia.splits import load_split
    assert H.dataset_splits() == {"wisdm2019_watch": load_split("wisdm2019_watch")["sha256"]}


def test_protocol_ii_repaired_windows(tmp_path):
    npz = str(tmp_path / "ii.npz")
    np.savez_compressed(npz, block_id=np.array(["w-1605-A-0"] * 3 + ["w-1607-B-0"]),
                        s=np.array([1.0, 3.0, 5.0, 1.0]), e=np.array([5.0, 7.0, 9.0, 5.0]),
                        subject=np.array([1605, 1605, 1605, 1607]))
    js = str(tmp_path / "ii.json")
    json.dump({"blocks": [{"block_id": "w-1605-A-0", "t0_ns": 10**12}, {"block_id": "w-1607-B-0", "t0_ns": 0}]},
              open(js, "w"))
    inst = {1605: np.array([10**12 + 6_000_000_000]), 1607: np.zeros(0, np.int64)}
    assert H.protocol_ii_repaired(npz, js, inst).tolist() == [0, 1, 1, 0]


def test_evaluate_cli_ledger_is_opt_in_and_refuses_silent_reruns(tmp_path):
    data = _npz(str(tmp_path / "eval.npz"))
    man = os.path.join(FIXTURES, "manifest.baseline.json")
    ledger = str(tmp_path / "ledger.jsonl")
    out = str(tmp_path / "rep.json")
    assert E.main(["--manifest", man, "--data", data, "--out", out]) == 0          # no ledger: unchanged
    assert not os.path.exists(ledger)
    assert E.main(["--manifest", man, "--data", data, "--out", out, "--ledger", ledger]) == 0
    assert json.load(open(out))["integrity"]["n_test_evaluations"] == 1
    with pytest.raises(SplitLeakError):
        E.main(["--manifest", man, "--data", data, "--out", out, "--ledger", ledger])
